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

    private var lastProgressPublishTime: TimeInterval = 0
    private var lastProgressPhase: String = ""
    private var lastProgressValue: Double = -1
    private let minProgressPublishInterval: TimeInterval = 0.08
    private let minProgressDelta: Double = 0.02

    func run(session: PracticeSession) async {
        guard let videoPath = session.videoLocalPath,
              FileManager.default.fileExists(atPath: videoPath) else {
            publishProgress(.failed("Video file not found."), force: true)
            return
        }

        isRunning = true
        defer { isRunning = false }

        let videoURL = URL(fileURLWithPath: videoPath)

        do {
            // Phase 1: Extract frames
            publishProgress(.extractingFrames(0), force: true)
            let extractor = try await VideoFrameExtractor.make(url: videoURL)
            let stride = max(1, Int(extractor.frameRate / 15.0))
            let frames = try await extractor.extractFrames(stride: stride) { [weak self] p in
                Task { @MainActor in self?.publishProgress(.extractingFrames(p)) }
            }

            // Phase 2: Detect pose on sparse frames
            publishProgress(.detectingPose(0), force: true)
            let poseFrames = try await PoseDetectionService.shared.detectPoses(in: frames) { [weak self] p in
                Task { @MainActor in self?.publishProgress(.detectingPose(p)) }
            }

            let sport = session.sportType
            let result: AnalysisResult

            switch sport {
            case .golf:
                // Phase 3: Estimate impact before launch tracking, then inspect dense frames around it.
                publishProgress(.trackingBall(0), force: true)
                let cameraAngle = session.manualCorrection?.correctedCameraAngle ?? session.cameraAngleEnum
                let impactWindow = GolfImpactWindowEstimator.shared.estimateImpactWindow(
                    frames: frames,
                    poseFrames: poseFrames,
                    manualContactFrame: session.manualCorrection?.correctedContactFrame
                )
                let densePadding = max(12, Int(extractor.frameRate * 0.35))
                let denseRange = max(0, impactWindow.startFrameIndex - densePadding)...min(extractor.totalFrames - 1, impactWindow.endFrameIndex + densePadding)
                let denseFrames = try await extractor.extractFrames(frameRange: denseRange, stride: 1) { [weak self] p in
                    Task { @MainActor in self?.publishProgress(.trackingBall(p * 0.35)) }
                }
                let trackingFrames = mergeFrames(base: frames, dense: denseFrames)
                let expandedWindow = impactWindow.expanded(
                    by: densePadding,
                    lowerBound: trackingFrames.first?.index ?? impactWindow.startFrameIndex,
                    upperBound: trackingFrames.last?.index ?? impactWindow.endFrameIndex
                )
                let ballTrackPoints = await BallTrackingService.shared.trackGolfBall(
                    in: trackingFrames,
                    poseFrames: poseFrames,
                    impactWindow: expandedWindow,
                    cameraAngle: cameraAngle
                ) { [weak self] p in
                    Task { @MainActor in self?.publishProgress(.trackingBall(0.35 + p * 0.65)) }
                }

                // Phase 4: Detect contact
                publishProgress(.detectingContact, force: true)
                let (contactFrame, contactConfidence) = ContactDetectionService.shared.detectGolfImpact(
                    poseFrames: poseFrames,
                    ballTrackPoints: ballTrackPoints,
                    totalFrames: extractor.totalFrames,
                    impactWindow: impactWindow
                )

                // Phase 5: Compute metrics
                publishProgress(.computing, force: true)
                let golfResult = GolfAnalysisService.shared.analyse(
                    poseFrames: poseFrames,
                    ballTrackPoints: ballTrackPoints,
                    contactFrameIndex: contactFrame,
                    contactConfidence: contactConfidence,
                    cameraAngle: cameraAngle
                )
                result = .golf(golfResult)

            case .tennis:
                // Phase 3: Track ball
                publishProgress(.trackingBall(0), force: true)
                let contactHint = session.effectiveContactFrameIndex
                let ballTrackPoints = await BallTrackingService.shared.trackBall(
                    in: frames,
                    poseFrames: poseFrames,
                    contactFrameHint: contactHint
                ) { [weak self] p in
                    Task { @MainActor in self?.publishProgress(.trackingBall(p)) }
                }

                // Phase 4: Detect contact
                publishProgress(.detectingContact, force: true)
                let (contactFrame, contactConfidence) = ContactDetectionService.shared.detectTennisContact(
                    poseFrames: poseFrames,
                    ballTrackPoints: ballTrackPoints,
                    totalFrames: extractor.totalFrames
                )

                publishProgress(.computing, force: true)
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

            publishProgress(.done(result), force: true)

        } catch {
            publishProgress(.failed(error.localizedDescription), force: true)
        }
    }

    private func publishProgress(_ newProgress: AnalysisProgress, force: Bool = false) {
        guard force || shouldPublish(newProgress) else { return }
        progress = newProgress
    }

    private func shouldPublish(_ newProgress: AnalysisProgress) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate

        guard let fraction = progressFraction(newProgress) else {
            lastProgressPhase = progressPhase(newProgress)
            lastProgressValue = -1
            lastProgressPublishTime = now
            return progress != newProgress
        }

        let phase = progressPhase(newProgress)
        let phaseChanged = phase != lastProgressPhase
        let valueChangedEnough = abs(fraction - lastProgressValue) >= minProgressDelta
        let timeElapsed = now - lastProgressPublishTime >= minProgressPublishInterval
        let isBoundary = fraction <= 0 || fraction >= 1

        guard phaseChanged || isBoundary || (valueChangedEnough && timeElapsed) else {
            return false
        }

        lastProgressPhase = phase
        lastProgressValue = fraction
        lastProgressPublishTime = now
        return progress != newProgress
    }

    private func progressFraction(_ progress: AnalysisProgress) -> Double? {
        switch progress {
        case .extractingFrames(let p), .detectingPose(let p), .trackingBall(let p):
            return min(max(p, 0), 1)
        default:
            return nil
        }
    }

    private func progressPhase(_ progress: AnalysisProgress) -> String {
        switch progress {
        case .extractingFrames: return "extractingFrames"
        case .detectingPose: return "detectingPose"
        case .trackingBall: return "trackingBall"
        case .detectingContact: return "detectingContact"
        case .computing: return "computing"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private func mergeFrames(base: [VideoFrame], dense: [VideoFrame]) -> [VideoFrame] {
        var byIndex: [Int: VideoFrame] = [:]
        for frame in base {
            byIndex[frame.index] = frame
        }
        for frame in dense {
            byIndex[frame.index] = frame
        }
        return byIndex.values.sorted { $0.index < $1.index }
    }
}
