import Foundation
import CoreGraphics

/// All tracer thresholds live here (spec §5). Magic numbers MUST NOT be scattered through
/// the detection/tracking/validation code — every gate reads from this config.
struct GolfTracerConfig {
    // Address ball (lowered from 0.65 to enable tracing on more videos; validation gates remain strict)
    var minimumAddressConfidence: Double = 0.50
    var minimumStableAddressDetections: Int = 3
    var maxAddressPositionVariancePx: CGFloat = 12

    // Impact
    var minimumImpactConfidence: Double = 0.40
    var impactLocalMotionRoiPx4K: CGFloat = 120

    // Initial launch
    var initialLaunchFrameCount: Int = 8
    var maxInitialMissingFrames: Int = 2
    var maxCandidatesPerFrame: Int = 8

    // Search radii at 4K 120 fps baseline (impact+1 … impact+8)
    var launchSearchRadiiPx4K120: [CGFloat] = [40, 80, 140, 220, 320, 450, 600, 760]
    var lockedSearchRadiusPx4K120: CGFloat = 80
    var temporarilyLostSearchRadiusPx4K120: CGFloat = 180
    var maxLostSearchRadiusPx4K120: CGFloat = 300

    // Physical gates
    var maxAngleChangeDegreesLocked: CGFloat = 60
    var maxAngleChangeDegreesTemporarilyLost: CGFloat = 75
    var minSpeedRatio: CGFloat = 0.25
    var maxSpeedRatio: CGFloat = 2.5
    var minForwardDotLocked: CGFloat = 0.05

    // Path sanity
    var maxPathEfficiencyRatio: CGFloat = 1.8
    var compactLoopTotalDistancePx4K: CGFloat = 80
    var compactLoopNetDistancePx4K: CGFloat = 35
    var minimumFinalNonPredictedPoints: Int = 4
    var minimumFinalNetDisplacementPx4K: CGFloat = 50
    var maximumPredictionOnlyRatio: Double = 0.35

    // Missing frames
    var maxConsecutiveMissingFrames120fps: Int = 6
    var maxConsecutiveMissingFrames60fps: Int = 3

    // Candidate quality (lowered to allow static balls through, ranked later)
    var minCandidateVisualScore: Double = 0.15
    var minCandidateMotionScore: Double = 0.05

    // Initial launch-track rejection (spec §11.5), at 4K baseline
    var minLaunchRealPoints: Int = 3
    var minLaunchNetDisplacementPx4K: CGFloat = 30
    var minLaunchDirectionConsistency: Double = 0.4
}
