import Foundation
import CoreGraphics

// MARK: - Golf Tracer model types (spec v3)
//
// Canonical coordinate system for this module: orientation-corrected FULL-FRAME pixels,
// origin TOP-LEFT, x increases right, y increases down. Only the renderer may convert to
// display/view coordinates. Detection ROIs are crop-local but every candidate that leaves
// a detector MUST be in full-frame coordinates (see TracerGeometry.cropLocalToFullFrame).
//
// Types are prefixed `Tracer*` to avoid colliding with the legacy `BallCandidate` /
// `ImpactWindow` in the existing pipeline while the new module is built out.

struct TracerFrameInfo {
    let index: Int
    let timestamp: Double
    let image: CGImage      // already orientation-corrected
    let width: Int
    let height: Int
}

enum TracerCandidateSource {
    case mlAddressDetector
    case mlFlightDetector
    case frameDifference
    case brightBlob
    case streakDetector
    case manualTap
    case predictionOnly
}

struct TracerCandidate {
    let frameIndex: Int
    let position: CGPoint       // full-frame, orientation-corrected pixels (top-left origin)
    let radius: CGFloat?
    let boundingBox: CGRect     // full-frame, orientation-corrected pixels
    let visualScore: Double
    let motionScore: Double
    let brightnessScore: Double
    let streakScore: Double
    let source: TracerCandidateSource
}

struct TracerTrackPoint {
    let frameIndex: Int
    let position: CGPoint
    let confidence: Double
    let source: TracerCandidateSource
    let isPredictedOnly: Bool
}

enum TracerState {
    case searching
    case candidateLaunch
    case locked
    case temporarilyLost
    case failed
    case complete
}

struct TracerTrack {
    var points: [TracerTrackPoint]
    var missingFrameCount: Int
    var state: TracerState
    var confidence: Double
}

enum TracerFailureReason: Equatable {
    case noFrames
    case noAddressBall
    case noImpact
    case noLaunchTrack
    case insufficientValidPoints
    case pathTooCircular
    case pathTooShort
    case tooManyPredictedPoints
    case physicallyImpossible
    case trackerConfidenceCollapsed
    case coordinateIntegrityFailed
}

enum TracerResult {
    case success(TracerTrack)
    case failure(TracerFailureReason)
}

enum TracerRejectionReason {
    case frameIndexMismatch
    case cropCoordinateLeak
    case outsidePredictionGate
    case backwardMotion
    case sharpTurn
    case speedJump
    case loopRisk
    case tooLarge
    case tooSmall
    case lowVisualScore
    case lowMotionScore
    case bodyOverlap
    case clubHeadLikely
}
