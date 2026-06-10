import Foundation
import CoreGraphics

struct ImpactWindow {
    let startFrameIndex: Int
    let estimatedFrameIndex: Int
    let endFrameIndex: Int
    let confidence: Float
    let reason: String

    func expanded(by frames: Int, lowerBound: Int, upperBound: Int) -> ImpactWindow {
        ImpactWindow(
            startFrameIndex: max(lowerBound, startFrameIndex - frames),
            estimatedFrameIndex: min(max(estimatedFrameIndex, lowerBound), upperBound),
            endFrameIndex: min(upperBound, endFrameIndex + frames),
            confidence: confidence,
            reason: reason
        )
    }
}

struct BallCandidate {
    let frameIndex: Int
    let centroid: CGPoint
    let boundingBox: CGRect
    let pixelCount: Int
    let whitenessScore: Float
    let motionScore: Float
    let shapeScore: Float
    let stabilityScore: Float
    let totalScore: Float
    let rejectionReason: String?
}

enum AddressFailureReason: String {
    case noPose
    case noCandidatesInROI
    case ambiguous
    case failedPostImpactValidation
    case lowConfidence
}

/// Structured result of automatic address-ball detection. Carries the chosen
/// candidate plus a calibrated confidence and the full ranked candidate list so
/// the UI can decide between auto-accept and a one-tap fallback.
struct AddressBallResult {
    let selected: BallCandidate?
    let confidence: Float
    let candidates: [BallCandidate]
    let roi: CGRect
    let wristMidpoint: CGPoint?
    let failureReason: AddressFailureReason?

    var point: CGPoint? { selected?.centroid }

    static func failure(_ reason: AddressFailureReason, candidates: [BallCandidate] = [], roi: CGRect = .init(x: 0, y: 0, width: 1, height: 1), wristMidpoint: CGPoint? = nil) -> AddressBallResult {
        AddressBallResult(selected: nil, confidence: 0, candidates: candidates, roi: roi, wristMidpoint: wristMidpoint, failureReason: reason)
    }
}

struct BallTrackingDebugReport {
    let impactWindow: ImpactWindow?
    let addressCandidates: [BallCandidate]
    let selectedAddressBall: BallCandidate?
    let frames: [BallTrackingDebugFrame]
    let finalPointCount: Int
    let averageConfidence: Float
    let failureReason: String?
}

struct BallTrackingDebugFrame {
    let frameIndex: Int
    let timestamp: TimeInterval
    let candidates: [BallCandidate]
    let selectedCandidate: BallCandidate?
    let prediction: CGPoint?
    let note: String?
}
