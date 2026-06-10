import Foundation
import CoreGraphics

// MARK: - Prediction (spec §15.1: x, y, vx, vy)

struct VelocityPredictor {
    var position: CGPoint
    var velocity: CGVector

    func predicted(dt: CGFloat = 1) -> CGPoint {
        CGPoint(x: position.x + velocity.dx * dt, y: position.y + velocity.dy * dt)
    }

    mutating func update(measurement: CGPoint, dt: CGFloat = 1) {
        let nv = CGVector(dx: (measurement.x - position.x) / dt, dy: (measurement.y - position.y) / dt)
        velocity = CGVector(dx: velocity.dx * 0.4 + nv.dx * 0.6, dy: velocity.dy * 0.4 + nv.dy * 0.6)
        position = measurement
    }

    mutating func coast(dt: CGFloat = 1) {
        position = predicted(dt: dt)
    }
}

// MARK: - Gates + association (spec §13, §14)

enum TracerAssociation {

    /// Hard gates — a candidate failing any of these MUST NOT update the tracker (§13).
    static func passesHardGates(candidate: CGPoint,
                                trackPositions: [CGPoint],
                                launchDirection: CGVector,
                                predicted: CGPoint,
                                searchRadius: CGFloat,
                                locked: Bool,
                                config: GolfTracerConfig) -> Bool {
        guard TracerGeometry.passesPredictionGate(candidate: candidate, predicted: predicted, radius: searchRadius) else {
            return false
        }
        guard let prev = trackPositions.last else { return true }

        if locked, TracerGeometry.norm(launchDirection) > 0 {
            guard TracerGeometry.isMovingForward(previous: prev, candidate: candidate,
                                                 launchDirection: launchDirection,
                                                 minForwardDot: config.minForwardDotLocked) else { return false }
        }
        if trackPositions.count >= 2 {
            let p0 = trackPositions[trackPositions.count - 2]
            let maxAngle = locked ? config.maxAngleChangeDegreesLocked : config.maxAngleChangeDegreesTemporarilyLost
            guard TracerGeometry.passesAngleGate(p0: p0, p1: prev, p2: candidate, maxAngleDegrees: maxAngle) else { return false }
            guard TracerGeometry.passesSpeedGate(p0: p0, p1: prev, p2: candidate,
                                                 minRatio: config.minSpeedRatio, maxRatio: config.maxSpeedRatio) else { return false }
        }
        return true
    }

    static func score(candidate: TracerCandidate,
                      previous: CGPoint,
                      predicted: CGPoint,
                      launchDirection: CGVector,
                      searchRadius: CGFloat) -> Double {
        let d = hypot(candidate.position.x - predicted.x, candidate.position.y - predicted.y)
        let proximity = d > searchRadius ? 0 : max(0, 1 - Double(d / searchRadius))

        let movement = TracerGeometry.vector(from: previous, to: candidate.position)
        let dirDot = Double(TracerGeometry.dot(TracerGeometry.normalized(movement), TracerGeometry.normalized(launchDirection)))
        let direction = max(0, (dirDot + 1) / 2)

        return 0.25 * candidate.visualScore
             + 0.20 * candidate.motionScore
             + 0.15 * candidate.streakScore
             + 0.20 * proximity
             + 0.15 * direction
             + 0.05 * 1.0   // speed-consistency placeholder; gated separately
    }
}

// MARK: - Multi-hypothesis launch selection (spec §11)

enum LaunchTrackSelector {

    static func selectBestLaunchTrack(candidatesByFrame: [Int: [TracerCandidate]],
                                      addressBall: CGPoint,
                                      impactFrame: Int,
                                      width: Int,
                                      height: Int,
                                      fps: Double,
                                      config: GolfTracerConfig) -> TracerTrack? {
        let frames = (1...config.initialLaunchFrameCount).map { impactFrame + $0 }
        var seeds: [TracerCandidate] = []
        for f in frames.prefix(2) { seeds.append(contentsOf: candidatesByFrame[f] ?? []) }
        guard !seeds.isEmpty else { return nil }

        var best: (track: TracerTrack, score: Double)?
        for seed in seeds {
            guard let hyp = buildHypothesis(seed: seed, frames: frames,
                                            candidatesByFrame: candidatesByFrame,
                                            addressBall: addressBall, impactFrame: impactFrame,
                                            width: width, height: height, fps: fps, config: config) else { continue }
            guard isInitialTrackValid(hyp.positions, addressBall: addressBall,
                                      width: width, height: height, config: config) else { continue }
            if best == nil || hyp.score > best!.score { best = (hyp.track, hyp.score) }
        }
        return best?.track
    }

    private static func buildHypothesis(seed: TracerCandidate,
                                        frames: [Int],
                                        candidatesByFrame: [Int: [TracerCandidate]],
                                        addressBall: CGPoint,
                                        impactFrame: Int,
                                        width: Int, height: Int, fps: Double,
                                        config: GolfTracerConfig)
    -> (track: TracerTrack, positions: [CGPoint], score: Double)? {

        var points: [TracerTrackPoint] = [
            TracerTrackPoint(frameIndex: impactFrame, position: addressBall, confidence: 1.0, source: .manualTap, isPredictedOnly: false),
            TracerTrackPoint(frameIndex: seed.frameIndex, position: seed.position, confidence: seed.visualScore, source: seed.source, isPredictedOnly: false)
        ]
        var predictor = VelocityPredictor(position: seed.position,
                                          velocity: TracerGeometry.vector(from: addressBall, to: seed.position))
        let launchDir = TracerGeometry.vector(from: addressBall, to: seed.position)
        var missing = 0
        var score = seed.visualScore + Double(TracerGeometry.norm(launchDir)) * 0.001

        for f in frames where f > seed.frameIndex {
            let step = f - impactFrame - 1
            let baseRadius = config.launchSearchRadiiPx4K120[min(max(step, 0), config.launchSearchRadiiPx4K120.count - 1)]
            let radius = TracerGeometry.effectiveRadius(basePx4K120: baseRadius, width: width, height: height, fps: fps)
            let predicted = predictor.predicted()

            let plausible = (candidatesByFrame[f] ?? []).filter {
                TracerAssociation.passesHardGates(candidate: $0.position,
                                                  trackPositions: points.map(\.position),
                                                  launchDirection: launchDir,
                                                  predicted: predicted, searchRadius: radius,
                                                  locked: true, config: config)
            }
            if let pick = plausible.max(by: {
                TracerAssociation.score(candidate: $0, previous: predictor.position, predicted: predicted, launchDirection: launchDir, searchRadius: radius)
                < TracerAssociation.score(candidate: $1, previous: predictor.position, predicted: predicted, launchDirection: launchDir, searchRadius: radius)
            }) {
                predictor.update(measurement: pick.position)
                points.append(TracerTrackPoint(frameIndex: f, position: pick.position, confidence: pick.visualScore, source: pick.source, isPredictedOnly: false))
                score += pick.visualScore + 0.3   // forward-progress reward
                missing = 0
            } else {
                missing += 1
                if missing > config.maxInitialMissingFrames { break }
                predictor.coast()
                score -= 0.2
            }
        }

        let positions = points.map(\.position)
        let track = TracerTrack(points: points, missingFrameCount: missing, state: .locked, confidence: min(1, max(0, score / 5)))
        return (track, positions, score)
    }

    /// Spec §11.5 — reject a bad initial launch (everything downstream depends on it).
    private static func isInitialTrackValid(_ positions: [CGPoint],
                                            addressBall: CGPoint,
                                            width: Int, height: Int,
                                            config: GolfTracerConfig) -> Bool {
        // real post-impact points exclude the address origin
        let postImpact = Array(positions.dropFirst())
        guard postImpact.count >= config.minLaunchRealPoints else { return false }

        let scale = TracerGeometry.resolutionScale(width: width, height: height)
        let net = TracerGeometry.netDisplacement([addressBall] + postImpact)
        guard net >= config.minLaunchNetDisplacementPx4K * scale else { return false }
        // A golf launch always RISES in frame (pixel y decreases) regardless of camera
        // angle. This rejects the club head / shadow sweeping through the hitting area,
        // which otherwise out-scores the ball and produces a ground-level "trace".
        guard let firstPos = positions.first, let lastPos = positions.last,
              lastPos.y < firstPos.y else { return false }
        guard TracerGeometry.pathEfficiencyRatio(positions) <= config.maxPathEfficiencyRatio else { return false }
        guard TracerGeometry.averageDirectionConsistency(positions) >= config.minLaunchDirectionConsistency else { return false }
        guard !TracerGeometry.hasImmediateReversal(positions) else { return false }
        let loopTotal = config.compactLoopTotalDistancePx4K * scale
        let loopNet = config.compactLoopNetDistancePx4K * scale
        guard !TracerGeometry.isCompactLoopLike(positions, totalDistanceThreshold: loopTotal, netDistanceThreshold: loopNet) else { return false }
        return true
    }
}

// MARK: - Post-launch tracker (spec §15.2 loop + state machine)

enum BallTracker {

    /// Continue tracking from the locked launch track through subsequent frames.
    /// Returns the FULL track (launch + tracked). Missing detections produce prediction-only
    /// points (limited) — never a random snapped point.
    static func track(initial: TracerTrack,
                      frames: [TracerFrameInfo],
                      width: Int, height: Int, fps: Double,
                      config: GolfTracerConfig) -> TracerTrack {
        var points = initial.points
        guard points.count >= 2, let lastReal = points.last else { return initial }

        var predictor = VelocityPredictor(
            position: lastReal.position,
            velocity: TracerGeometry.vector(from: points[points.count - 2].position, to: lastReal.position))
        let launchDir = TracerGeometry.vector(from: points.first!.position, to: lastReal.position)

        var missing = 0
        var state: TracerState = .locked
        let maxMissing = fps >= 90 ? config.maxConsecutiveMissingFrames120fps : config.maxConsecutiveMissingFrames60fps

        let startFrame = lastReal.frameIndex + 1
        var previousFrame = frames.last(where: { $0.index <= lastReal.frameIndex })

        for frame in frames where frame.index >= startFrame {
            defer { previousFrame = frame }
            let predicted = predictor.predicted()
            let baseRadius = state == .locked ? config.lockedSearchRadiusPx4K120 : config.temporarilyLostSearchRadiusPx4K120
            let radius = TracerGeometry.effectiveRadius(basePx4K120: baseRadius, width: width, height: height, fps: fps)
            let roi = CGRect(x: predicted.x - radius, y: predicted.y - radius, width: radius * 2, height: radius * 2)

            let candidates = TracerCandidateDetector.detect(in: frame, previous: previousFrame, roiFullFrame: roi, config: config)
            let plausible = candidates.filter {
                $0.frameIndex == frame.index &&
                TracerAssociation.passesHardGates(candidate: $0.position,
                                                  trackPositions: points.filter { !$0.isPredictedOnly }.map(\.position),
                                                  launchDirection: launchDir, predicted: predicted,
                                                  searchRadius: radius, locked: state == .locked, config: config)
            }

            if let best = plausible.max(by: {
                TracerAssociation.score(candidate: $0, previous: predictor.position, predicted: predicted, launchDirection: launchDir, searchRadius: radius)
                < TracerAssociation.score(candidate: $1, previous: predictor.position, predicted: predicted, launchDirection: launchDir, searchRadius: radius)
            }) {
                predictor.update(measurement: best.position)
                points.append(TracerTrackPoint(frameIndex: frame.index, position: best.position, confidence: best.visualScore, source: best.source, isPredictedOnly: false))
                missing = 0
                state = .locked
                // Loop-risk safety: abort if the recent path collapses.
                let recent = points.filter { !$0.isPredictedOnly }.map(\.position)
                if !TracerGeometry.recentPathIsEfficient(recent, maxRatio: config.maxPathEfficiencyRatio) { state = .failed; break }
            } else {
                missing += 1
                if missing > maxMissing { state = .complete; break }
                predictor.coast()
                state = .temporarilyLost
                points.append(TracerTrackPoint(frameIndex: frame.index, position: predictor.position, confidence: 0.2, source: .predictionOnly, isPredictedOnly: true))
            }
        }

        // Trim trailing prediction-only points (don't render a predicted tail).
        while let last = points.last, last.isPredictedOnly { points.removeLast() }

        return TracerTrack(points: points, missingFrameCount: missing,
                           state: state == .failed ? .failed : .complete,
                           confidence: initial.confidence)
    }
}
