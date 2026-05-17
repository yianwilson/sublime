import SwiftUI
import AVFoundation
import AVKit

struct VideoPlayerView: View {
    let session: PracticeSession
    let showOverlays: Bool
    let onFrameChange: ((Int) -> Void)?

    @StateObject private var coordinator = VideoPlayerCoordinator()
    @State private var currentFrameIndex: Int = 0
    @State private var showPoseOverlay: Bool = true
    @State private var showBallTrail: Bool = true

    init(session: PracticeSession, showOverlays: Bool = true, onFrameChange: ((Int) -> Void)? = nil) {
        self.session = session
        self.showOverlays = showOverlays
        self.onFrameChange = onFrameChange
    }

    var body: some View {
        ZStack {
            if let player = coordinator.player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }

                if showOverlays {
                    overlayControls
                }
            } else {
                Rectangle()
                    .fill(Color(.systemGray6))
                    .overlay {
                        Image(systemName: "video.slash.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .onAppear { coordinator.setup(session: session) }
        .onDisappear { coordinator.teardown() }
    }

    private var overlayControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 20) {
                overlayToggle(title: "Pose", icon: "figure.walk", isOn: $showPoseOverlay)
                overlayToggle(title: "Ball", icon: "circle.fill", isOn: $showBallTrail)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 8)
        }
    }

    private func overlayToggle(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn.wrappedValue ? .green : .secondary)
        }
    }
}

@MainActor
final class VideoPlayerCoordinator: ObservableObject {
    @Published var player: AVPlayer?

    func setup(session: PracticeSession) {
        guard let url = VideoStorageService.shared.videoURL(for: session) else { return }
        let player = AVPlayer(url: url)
        self.player = player

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }

    func teardown() {
        player?.pause()
        player = nil
        NotificationCenter.default.removeObserver(self)
    }
}

struct FrameScrubberView: View {
    @Binding var frameIndex: Int
    let totalFrames: Int
    let contactFrameIndex: Int?

    var body: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(
                get: { Double(frameIndex) },
                set: { frameIndex = Int($0) }
            ), in: 0...Double(max(1, totalFrames - 1)), step: 1)
            .tint(.green)

            HStack {
                Text("Frame \(frameIndex)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let contact = contactFrameIndex {
                    Button("Go to Impact") { frameIndex = contact }
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }
}
