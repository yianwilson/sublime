import Foundation
import CoreGraphics

/// End-to-end tracer (spec §22). Address ball and impact frame are supplied by the caller
/// (the app's existing detectors / manual seed), already converted to canonical full-frame
/// pixels. This module owns: expanding-ROI launch candidate detection → multi-hypothesis
/// launch selection → prediction-gated tracking → validation → smoothing.
///
/// It returns `.failure` (with reason) rather than ever producing a wrong trace.
enum GolfTracerPipeline {

    static func trace(frames: [TracerFrameInfo],
                      addressBallFullFrame: CGPoint,
                      impactFrame: Int,
                      fps: Double,
                      config: GolfTracerConfig) -> TracerResult {
        guard !frames.isEmpty else { return .failure(.noFrames) }
        let width = frames[0].width
        let height = frames[0].height
        let byIndex = Dictionary(frames.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })

        // Stage 4 — expanding-ROI launch candidates for impact+1 … impact+N.
        var candidatesByFrame: [Int: [TracerCandidate]] = [:]
        for step in 1...config.initialLaunchFrameCount {
            let f = impactFrame + step
            guard let frame = byIndex[f] else { continue }
            let baseRadius = config.launchSearchRadiiPx4K120[min(step - 1, config.launchSearchRadiiPx4K120.count - 1)]
            let radius = TracerGeometry.effectiveRadius(basePx4K120: baseRadius, width: width, height: height, fps: fps)
            let roi = CGRect(x: addressBallFullFrame.x - radius, y: addressBallFullFrame.y - radius,
                             width: radius * 2, height: radius * 2)
            let previous = byIndex[f - 1]
            candidatesByFrame[f] = TracerCandidateDetector.detect(in: frame, previous: previous, roiFullFrame: roi, config: config)
        }

        // Stage 5 — multi-hypothesis launch track.
        guard let initialTrack = LaunchTrackSelector.selectBestLaunchTrack(
            candidatesByFrame: candidatesByFrame,
            addressBall: addressBallFullFrame,
            impactFrame: impactFrame,
            width: width, height: height, fps: fps, config: config) else {
            return .failure(.noLaunchTrack)
        }

        // Stage 6 — prediction-gated tracking through the rest of the flight.
        let tracked = BallTracker.track(initial: initialTrack, frames: frames,
                                        width: width, height: height, fps: fps, config: config)

        // Final validation — never render a wrong trace.
        if let reason = TrackValidator.validate(tracked, config: config, width: width, height: height) {
            return .failure(reason)
        }

        return .success(TrajectorySmoother.smooth(tracked))
    }
}

/// Light smoothing AFTER validation (spec §17.2). Must never be used to hide bad tracking,
/// so it only runs on an already-validated track and only nudges real points.
enum TrajectorySmoother {

    static func smooth(_ track: TracerTrack) -> TracerTrack {
        let pts = track.points
        guard pts.count > 2 else { return track }

        var smoothed = pts
        for i in 1..<(pts.count - 1) {
            // Don't move endpoints or predicted-only points.
            guard !pts[i].isPredictedOnly else { continue }
            let p0 = pts[i - 1].position, p1 = pts[i].position, p2 = pts[i + 1].position
            let avg = CGPoint(x: p0.x * 0.25 + p1.x * 0.5 + p2.x * 0.25,
                              y: p0.y * 0.25 + p1.y * 0.5 + p2.y * 0.25)
            smoothed[i] = TracerTrackPoint(frameIndex: pts[i].frameIndex, position: avg,
                                           confidence: pts[i].confidence, source: pts[i].source,
                                           isPredictedOnly: pts[i].isPredictedOnly)
        }
        return TracerTrack(points: smoothed, missingFrameCount: track.missingFrameCount,
                           state: track.state, confidence: track.confidence)
    }
}
