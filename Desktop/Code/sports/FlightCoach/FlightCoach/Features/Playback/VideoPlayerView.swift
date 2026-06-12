import SwiftUI
@preconcurrency import AVFoundation
import AVKit

struct VideoPlayerView: View {
    let session: PracticeSession
    let showOverlays: Bool
    let onFrameChange: ((Int) -> Void)?
    let onTimeChange: ((TimeInterval) -> Void)?

    @StateObject private var coordinator = VideoPlayerCoordinator()
    @State private var currentFrameIndex: Int = 0
    @State private var showPoseOverlay: Bool = true
    @State private var showBallTrail: Bool = true

    init(
        session: PracticeSession,
        showOverlays: Bool = true,
        onFrameChange: ((Int) -> Void)? = nil,
        onTimeChange: ((TimeInterval) -> Void)? = nil
    ) {
        self.session = session
        self.showOverlays = showOverlays
        self.onFrameChange = onFrameChange
        self.onTimeChange = onTimeChange
    }

    var body: some View {
        ZStack {
            if let player = coordinator.player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
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
        .onChange(of: coordinator.currentTime) { onTimeChange?(coordinator.currentTime) }
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
    @Published var currentTime: TimeInterval = 0

    private var timeObserver: Any?

    func setup(session: PracticeSession) {
        guard let url = VideoStorageService.shared.videoURL(for: session) else { return }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        // HDR originals render washed-out without tone mapping (always on the
        // simulator); the composition forces SDR output. Applied async — it
        // takes effect live and is nil for SDR sources.
        Task {
            item.videoComposition = await VideoStorageService.sdrDisplayComposition(for: asset)
        }

        let interval = CMTime(seconds: 0.04, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds
            }
        }

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
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
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
