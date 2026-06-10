import SwiftUI
import AVFoundation
import SwiftData

struct CameraRecordingScreen: View {
    let sport: SportType
    let mode: String
    let angle: CameraAngle
    var handedness: Handedness = .rightHanded
    let onComplete: (PracticeSession) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraManager()
    @State private var isSettingUp = true
    @State private var setupError: String?
    @State private var recordingDuration: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isSettingUp {
                ProgressView("Setting up camera…")
                    .foregroundStyle(.white)
            } else if let error = setupError {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill.badge.ellipsis")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text(error)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Dismiss") { dismiss() }
                        .foregroundStyle(.white)
                }
            } else {
                CameraPreviewLayer(camera: camera)
                    .ignoresSafeArea()

                VStack {
                    HStack {
                        Button {
                            camera.stopSession()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                        Spacer()
                        Text(angle.displayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 60)

                    Spacer()

                    cameraPlacementGuide

                    Spacer()

                    recordingControls
                        .padding(.bottom, 48)
                }
            }
        }
        .task { await setupCamera() }
        .onDisappear { camera.stopSession() }
    }

    private var cameraPlacementGuide: some View {
        Group {
            if camera.recordingState == .idle {
                VStack(spacing: 8) {
                    Text("Position Guide")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(placementText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var placementText: String {
        switch angle {
        case .downTheLine:
            return "Place camera directly behind the ball along the target line. Full body in frame."
        case .faceOn:
            return "Place camera facing you directly. Full body visible from head to feet."
        case .behindBallFlight:
            return "Place camera behind you, pointed toward the target. Capture the full ball flight."
        case .unknown:
            return "Set up your camera to capture the full swing."
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 16) {
            if camera.recordingState == .recording {
                Text(formatDuration(recordingDuration))
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.7))
                    .clipShape(Capsule())
            }

            Button {
                Task { await toggleRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(camera.recordingState == .recording ? Color.red : Color.white)
                        .frame(width: 72, height: 72)
                    if camera.recordingState == .recording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white)
                            .frame(width: 28, height: 28)
                    }
                }
            }
            .disabled(camera.recordingState == .preparing || camera.recordingState == .stopping)
        }
    }

    private func setupCamera() async {
        let granted = await camera.requestPermission()
        guard granted else {
            setupError = "Camera permission denied. Enable it in Settings."
            isSettingUp = false
            return
        }
        do {
            try await camera.setupSession()
            camera.startSession()
            isSettingUp = false
        } catch {
            setupError = error.localizedDescription
            isSettingUp = false
        }
    }

    private func toggleRecording() async {
        if camera.recordingState == .idle {
            try? await camera.startRecording()
            recordingDuration = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                recordingDuration += 1
            }
        } else if camera.recordingState == .recording {
            timer?.invalidate()
            timer = nil
            do {
                let videoURL = try await camera.stopRecording()
                await saveRecording(at: videoURL)
            } catch {
                setupError = error.localizedDescription
            }
        }
    }

    private func saveRecording(at url: URL) async {
        do {
            let session = PracticeSession(sport: sport, mode: mode, cameraAngle: angle, handedness: handedness)
            session.durationSeconds = recordingDuration

            let savedURL = try await VideoStorageService.shared.copyVideoToLocal(from: url, sessionId: session.id)
            session.videoLocalPath = savedURL.path

            if let thumbURL = try? await VideoStorageService.shared.generateThumbnail(from: savedURL, sessionId: session.id) {
                session.thumbnailLocalPath = thumbURL.path
            }

            try? FileManager.default.removeItem(at: url)

            let repo = SessionRepository(modelContext: modelContext)
            try repo.save(session)

            camera.stopSession()
            dismiss()
            onComplete(session)
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct CameraPreviewLayer: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        Task { @MainActor in
            if let layer = camera.previewLayer {
                layer.frame = uiView.bounds
                if layer.superlayer == nil {
                    uiView.layer.addSublayer(layer)
                }
            }
        }
    }
}
