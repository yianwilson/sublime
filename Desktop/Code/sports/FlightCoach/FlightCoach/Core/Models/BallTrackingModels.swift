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
