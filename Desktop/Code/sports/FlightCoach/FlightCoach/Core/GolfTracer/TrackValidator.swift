import Foundation
import CoreGraphics

/// Final gate before rendering (spec §16). A track may only be rendered if this returns
/// `nil` (valid). Otherwise it returns the specific `TracerFailureReason`. The renderer
/// MUST consult this — raw/unvalidated tracks can never reach the screen.
enum TrackValidator {

    /// Returns `nil` when the track is renderable, else the reason it was rejected.
    /// Order matters: cheapest/most-specific structural failures first.
    static func validate(_ track: TracerTrack,
                         config: GolfTracerConfig,
                         width: Int,
                         height: Int) -> TracerFailureReason? {
        let visualPoints = track.points.filter { !$0.isPredictedOnly }
        let positions = visualPoints.map(\.position)
        let scale = TracerGeometry.resolutionScale(width: width, height: height)

        // 1. Enough real (non-predicted) detections.
        guard visualPoints.count >= config.minimumFinalNonPredictedPoints else {
            return .insufficientValidPoints
        }

        // 2. Prediction-only points must not dominate.
        let predictedCount = track.points.filter(\.isPredictedOnly).count
        let predictionRatio = Double(predictedCount) / Double(max(track.points.count, 1))
        guard predictionRatio <= config.maximumPredictionOnlyRatio else {
            return .tooManyPredictedPoints
        }

        // 3. No reversal back toward the start.
        if TracerGeometry.hasImmediateReversal(positions) {
            return .physicallyImpossible
        }

        // 4. Compact / circular loop.
        let loopTotal = config.compactLoopTotalDistancePx4K * scale
        let loopNet = config.compactLoopNetDistancePx4K * scale
        if TracerGeometry.isCompactLoopLike(positions,
                                            totalDistanceThreshold: loopTotal,
                                            netDistanceThreshold: loopNet) {
            return .pathTooCircular
        }

        // 5. Path efficiency (looping / zig-zag).
        guard TracerGeometry.pathEfficiencyRatio(positions) <= config.maxPathEfficiencyRatio else {
            return .pathTooCircular
        }

        // 6. Minimum net displacement.
        let minNet = config.minimumFinalNetDisplacementPx4K * scale
        guard TracerGeometry.netDisplacement(positions) >= minNet else {
            return .pathTooShort
        }

        return nil
    }

    /// Spec §16.2 signature — true only when fully valid.
    static func validateFinalTrack(_ track: TracerTrack,
                                   config: GolfTracerConfig,
                                   width: Int,
                                   height: Int) -> Bool {
        validate(track, config: config, width: width, height: height) == nil
    }
}
