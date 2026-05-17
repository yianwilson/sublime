import Foundation

enum AnalysisProgress: Equatable {
    case extractingFrames(Double)
    case detectingPose(Double)
    case trackingBall(Double)
    case detectingContact
    case computing
    case done(AnalysisResult)
    case failed(String)
}

@MainActor
final class AnalysisPipeline: ObservableObject {
    @Published var progress: AnalysisProgress = .extractingFrames(0)
    @Published var isRunning = false

    func run(session: PracticeSession) async {
        guard let videoPath = session.videoLocalPath,
              FileManager.default.fileExists(atPath: videoPath) else {
            progress = .failed("Video file not found.")
            return
        }

        isRunning = true
        defer { isRunning = false }

        let videoURL = URL(fileURLWithPath: videoPath)

        do {
            // Phase 1: Extract frames
            progress = .extractingFrames(0)
            let extractor = try await VideoFrameExtractor.make(url: videoURL)
            let stride = max(1, Int(extractor.frameRate / 15.0))
            let frames = try await extractor.extractFrames(stride: stride) { [weak self] p in
                Task { @MainActor in self?.progress = .extractingFrames(p) }
            }

            // Phase 2: Detect pose on sparse frames
            progress = .detectingPose(0)
            let poseFrames = try await PoseDetectionService.shared.detectPoses(in: frames) { [weak self] p in
                Task { @MainActor in self?.progress = .detectingPose(p) }
            }

            // Phase 3: Track ball — pre-estimate impact from pose, then extract dense frames
            progress = .trackingBall(0)

            // Use session manual override if available; otherwise estimate from pose alone
            let poseImpact = ContactDetectionService.shared.estimateImpactFromPoseOnly(poseFrames: poseFrames)
            let impactFrameIdx = session.effectiveContactFrameIndex ?? poseImpact.frameIndex
            let impactTime: TimeInterval = poseFrames.first(where: { $0.frameIndex == impactFrameIdx })
                .map(\.timestamp) ?? (Double(impactFrameIdx) / extractor.frameRate)

            // Extract dense frames (up to 60 fps) around the estimated impact window
            let denseFrames = (try? await extractor.extractDenseFrames(
                around: impactTime,
                windowSeconds: 3.5,
                maxFPS: min(extractor.frameRate, 60)
            ) { [weak self] p in
                Task { @MainActor in self?.progress = .trackingBall(p * 0.3) }
            }) ?? []
            let trackingFrames = denseFrames.isEmpty ? frames : denseFrames

            let ballTrackPoints = await BallTrackingService.shared.trackBall(
                in: trackingFrames,
                poseFrames: poseFrames,
                contactFrameHint: impactFrameIdx
            ) { [weak self] p in
                Task { @MainActor in self?.progress = .trackingBall(0.3 + p * 0.7) }
            }

            // Phase 4: Detect contact
            progress = .detectingContact
            let sport = session.sportType
            let result: AnalysisResult

            switch sport {
            case .golf:
                let (contactFrame, contactConfidence) = ContactDetectionService.shared.detectGolfImpact(
                    poseFrames: poseFrames,
                    ballTrackPoints: ballTrackPoints,
                    totalFrames: extractor.totalFrames
                )

                let cameraAngle = session.manualCorrection?.correctedCameraAngle ?? session.cameraAngleEnum

                // Phase 5: Compute metrics
                progress = .computing
                let golfResult = GolfAnalysisService.shared.analyse(
                    poseFrames: poseFrames,
                    ballTrackPoints: ballTrackPoints,
                    contactFrameIndex: contactFrame,
                    contactConfidence: contactConfidence,
                    cameraAngle: cameraAngle
                )
                result = .golf(golfResult)

            case .tennis:
                let (contactFrame, contactConfidence) = ContactDetectionService.shared.detectTennisContact(
                    poseFrames: poseFrames,
                    ballTrackPoints: ballTrackPoints,
                    totalFrames: extractor.totalFrames
                )

                progress = .computing
                let mode = TennisMode(rawValue: session.mode) ?? .forehand
                let tennisResult = TennisAnalysisService.shared.analyse(
                    poseFrames: poseFrames,
                    ballTrackPoints: ballTrackPoints,
                    contactFrameIndex: contactFrame,
                    contactConfidence: contactConfidence,
                    mode: mode
                )
                result = .tennis(tennisResult)
            }

            progress = .done(result)

        } catch {
            progress = .failed(error.localizedDescription)
        }
    }
}
