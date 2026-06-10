import Foundation
import CoreImage
import CoreGraphics

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
            #if DEBUG
            print(String(format: "AnalysisPipeline: source frameRate=%.1f fps, totalFrames=%d", extractor.frameRate, extractor.totalFrames))
            #endif
            let stride = max(1, Int(extractor.frameRate / 15.0))
            let frames = try await extractor.extractFrames(stride: stride) { [weak self] p in
                Task { @MainActor in self?.publishProgress(.extractingFrames(p)) }
            }

            // Phase 2: Detect pose — 30 fps for better skeleton coverage
            publishProgress(.detectingPose(0), force: true)
            let poseStride = max(1, Int(extractor.frameRate / 30.0))
            let poseFrameInputs = stride == poseStride ? frames : (try await extractor.extractFrames(stride: poseStride) { _ in })
            let (poseFrames, poseDebugResults) = await PoseDetectionService.shared.detectPoses(in: poseFrameInputs) { [weak self] p in
                Task { @MainActor in self?.publishProgress(.detectingPose(p)) }
            }
            let poseSummary = PoseSummary(
                detectedFrames: poseFrames.count,
                totalFrames: poseFrameInputs.count,
                averageConfidence: poseDebugResults.filter { $0.didDetectPose }.map(\.averageConfidence).reduce(0, +) / Float(max(1, poseFrames.count))
            )
            _ = poseDebugResults

            let sport = session.sportType
            let result: AnalysisResult

            switch sport {
            case .golf:
                // Phase 3: Estimate impact before launch tracking, then inspect dense frames around it.
                publishProgress(.trackingBall(0), force: true)
                let cameraAngle = session.manualCorrection?.correctedCameraAngle ?? session.cameraAngleEnum
                let handedness = session.effectiveHandedness
                let impactWindow = GolfImpactWindowEstimator.shared.estimateImpactWindow(
                    frames: frames,
                    poseFrames: poseFrames,
                    manualContactFrame: session.manualCorrection?.correctedContactFrame
                )
                let densePadding = max(12, Int(extractor.frameRate * 0.35))
                // Bound dense extraction to a window around the estimated impact so a
                // low-confidence (broad-fallback) impact window — e.g. when pose
                // detection is unavailable — can't explode into hundreds of frames.
                let maxDenseHalfSpan = max(densePadding, Int(extractor.frameRate * 0.6))
                let denseLower = max(0, max(impactWindow.startFrameIndex - densePadding, impactWindow.estimatedFrameIndex - maxDenseHalfSpan))
                let denseUpper = min(extractor.totalFrames - 1, min(impactWindow.endFrameIndex + densePadding, impactWindow.estimatedFrameIndex + maxDenseHalfSpan))
                let denseRange = denseLower...max(denseLower, denseUpper)
                let denseFrames = try await extractor.extractFrames(frameRange: denseRange, stride: 1) { [weak self] p in
                    Task { @MainActor in self?.publishProgress(.trackingBall(p * 0.35)) }
                }
                let trackingFrames = mergeFrames(base: frames, dense: denseFrames)
                let expandedWindow = impactWindow.expanded(
                    by: densePadding,
                    lowerBound: trackingFrames.first?.index ?? impactWindow.startFrameIndex,
                    upperBound: trackingFrames.last?.index ?? impactWindow.endFrameIndex
                )
                _ = expandedWindow
                let manualBallTrackPoints = normalizedManualTrack(session.manualCorrection?.manualBallTrackPoints)
                let ballTrackPoints: [BallTrackPoint]
                if manualBallTrackPoints.count >= 2 {
                    ballTrackPoints = manualBallTrackPoints
                    publishProgress(.trackingBall(1), force: true)
                } else {
                    // Spec-v3 tracer: address (seed or auto) → expanding-ROI launch candidates
                    // → multi-hypothesis launch selection → prediction-gated tracking → final
                    // validation → smoothing. Returns NO trace rather than a wrong one.
                    let addressNorm: CGPoint?
                    if let seed = manualBallTrackPoints.first {
                        addressNorm = CGPoint(x: CGFloat(seed.x), y: CGFloat(seed.y))
                    } else {
                        addressNorm = await BallTrackingService.shared.detectAddressOnly(
                            in: trackingFrames, poseFrames: poseFrames, impactWindow: impactWindow,
                            cameraAngle: cameraAngle, handedness: handedness)
                    }
                    if let addressNorm {
                        // Apple's trajectory detector first: proven on ground-truth
                        // fixtures where motion heuristics fail. Falls back to the
                        // spec-v3 tracer if no plausible trajectory survives.
                        let impactTime = Double(impactWindow.estimatedFrameIndex) / extractor.frameRate
                        if let vnPoints = await TrajectoryDetectionService.shared.ballFlight(
                            url: videoURL, addressNormalized: addressNorm,
                            frameRate: extractor.frameRate, impactTime: impactTime),
                           vnPoints.count >= 4 {
                            ballTrackPoints = vnPoints
                        } else {
                            ballTrackPoints = await golfTracerTrack(
                                frames: trackingFrames, addressNormalized: addressNorm,
                                impactFrame: impactWindow.estimatedFrameIndex, frameRate: extractor.frameRate)
                        }
                    } else {
                        ballTrackPoints = []
                    }
                    publishProgress(.trackingBall(1), force: true)
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
                    cameraAngle: cameraAngle,
                    poseSummary: poseSummary
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
                    mode: mode,
                    poseSummary: poseSummary
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

    /// Run the spec-v3 GolfTracerPipeline and convert its full-frame-pixel result back into
    /// the app's normalised (y-up) BallTrackPoints. On failure (no valid trace) returns just
    /// the address ball so the UI shows the ball but never a wrong trace.
    private func golfTracerTrack(frames: [VideoFrame], addressNormalized: CGPoint,
                                 impactFrame: Int, frameRate: Double) async -> [BallTrackPoint] {
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        var tracerFrames: [TracerFrameInfo] = []
        for f in frames.sorted(by: { $0.index < $1.index }) {
            let extent = f.image.extent
            guard extent.width > 0, extent.height > 0,
                  let cg = ctx.createCGImage(f.image, from: extent) else { continue }
            tracerFrames.append(TracerFrameInfo(index: f.index, timestamp: f.timestamp,
                                                image: cg, width: cg.width, height: cg.height))
        }
        guard let first = tracerFrames.first else { return [] }
        let w = CGFloat(first.width), h = CGFloat(first.height)
        // normalised (y-up) → full-frame pixels (top-left)
        let addressPx = CGPoint(x: addressNormalized.x * w, y: (1 - addressNormalized.y) * h)

        let result = GolfTracerPipeline.trace(frames: tracerFrames, addressBallFullFrame: addressPx,
                                              impactFrame: impactFrame, fps: frameRate, config: GolfTracerConfig())

        let timestampByIndex = Dictionary(tracerFrames.map { ($0.index, $0.timestamp) }, uniquingKeysWith: { a, _ in a })

        switch result {
        case .success(let track):
            #if DEBUG
            print("GolfTracerPipeline: SUCCESS → \(track.points.count) points")
            #endif
            return track.points.map { p in
                BallTrackPoint(frameIndex: p.frameIndex,
                               timestamp: timestampByIndex[p.frameIndex] ?? 0,
                               x: Float(min(max(p.position.x / w, 0), 1)),
                               y: Float(min(max(1 - p.position.y / h, 0), 1)),
                               confidence: Float(p.confidence))
            }
        case .failure(let reason):
            #if DEBUG
            print("GolfTracerPipeline: NO TRACE — \(reason)")
            #endif
            let ts = tracerFrames.first(where: { $0.index >= impactFrame })?.timestamp ?? first.timestamp
            return [BallTrackPoint(frameIndex: impactFrame, timestamp: ts,
                                   x: Float(addressNormalized.x), y: Float(addressNormalized.y), confidence: 0.5)]
        }
    }

    /// Re-run only the tracer from a manually tapped address ball — no pose required, so it
    /// works on the simulator. Returns the validated trace (or ball-only on failure). Used
    /// for one-tap "trace from this ball".
    func retraceFromSeed(videoPath: String, seedNormalized: CGPoint, manualContactFrame: Int?) async -> [BallTrackPoint] {
        let videoURL = URL(fileURLWithPath: videoPath)
        guard let extractor = try? await VideoFrameExtractor.make(url: videoURL) else { return [] }
        let stride = max(1, Int(extractor.frameRate / 15.0))
        guard let frames = try? await extractor.extractFrames(stride: stride) else { return [] }
        let impactWindow = GolfImpactWindowEstimator.shared.estimateImpactWindow(
            frames: frames, poseFrames: [], manualContactFrame: manualContactFrame)
        let densePadding = max(12, Int(extractor.frameRate * 0.35))
        let maxDenseHalfSpan = max(densePadding, Int(extractor.frameRate * 0.6))
        let denseLower = max(0, max(impactWindow.startFrameIndex - densePadding, impactWindow.estimatedFrameIndex - maxDenseHalfSpan))
        let denseUpper = min(extractor.totalFrames - 1, min(impactWindow.endFrameIndex + densePadding, impactWindow.estimatedFrameIndex + maxDenseHalfSpan))
        let denseRange = denseLower...max(denseLower, denseUpper)
        let denseFrames = (try? await extractor.extractFrames(frameRange: denseRange, stride: 1)) ?? []
        let trackingFrames = mergeFrames(base: frames, dense: denseFrames)
        #if DEBUG
        print("retraceFromSeed: seed=\(seedNormalized) impact=\(impactWindow.estimatedFrameIndex) frames=\(trackingFrames.count)")
        #endif
        return await golfTracerTrack(frames: trackingFrames, addressNormalized: seedNormalized,
                                     impactFrame: impactWindow.estimatedFrameIndex, frameRate: extractor.frameRate)
    }

    /// Replace a raw tracked flight with a fitted ballistic arc (measured launch +
    /// predicted apex/descent). Falls back to the raw points when the launch isn't
    /// cleanly ballistic.
    private func ballisticArc(from raw: [BallTrackPoint], frameRate: Double, impactFrameIndex: Int? = nil) -> [BallTrackPoint] {
        // Keep only the flight (impact onward) so the arc doesn't start during the
        // address/downswing — pre-impact club motion must not become "flight".
        let flight: [BallTrackPoint]
        if let impact = impactFrameIndex {
            let trimmed = raw.filter { $0.frameIndex >= impact }
            flight = trimmed.count >= 3 ? trimmed : raw
        } else {
            flight = raw
        }
        let raw = flight
        guard raw.count >= 3 else { return raw }
        let interval = 1.0 / max(1.0, frameRate)
        if let arc = BallisticTrajectory.fit(points: raw, frameInterval: interval) {
            #if DEBUG
            print("AnalysisPipeline: ballistic arc fitted → \(arc.count) points (from \(raw.count) tracked)")
            #endif
            return arc
        }
        // Fit failed ⇒ the launch wasn't a clean arc (noise/club/body). Don't draw the
        // raw zig-zag — fall back to just the ball so the user can tap-seed instead.
        #if DEBUG
        print("AnalysisPipeline: ballistic fit failed — showing ball only (\(raw.count) raw pts suppressed)")
        #endif
        let earliest = raw.sorted { $0.timestamp < $1.timestamp }.first
        return earliest.map { [$0] } ?? raw
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

    private func normalizedManualTrack(_ points: [BallTrackPoint]?) -> [BallTrackPoint] {
        guard let points else { return [] }
        return points
            .map { point in
                BallTrackPoint(
                    frameIndex: point.frameIndex,
                    timestamp: point.timestamp,
                    x: min(max(point.x, 0), 1),
                    y: min(max(point.y, 0), 1),
                    confidence: max(point.confidence, 0.85)
                )
            }
            .sorted { $0.timestamp < $1.timestamp }
    }
}
