import Foundation
import CoreGraphics
import CoreImage

enum BallDetectorKind: String, Codable, Equatable {
    case heuristic
    case coreML
    case hybrid
}

struct BallDetectionRegion: Equatable {
    let normalizedRect: CGRect

    static let fullFrame = BallDetectionRegion(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
}

struct BallDetectionCandidate: Equatable {
    let frameIndex: Int
    let timestamp: TimeInterval
    let center: CGPoint
    let boundingBox: CGRect
    let confidence: Float
    let source: BallDetectorKind
    let features: [String: Float]
}

struct BallDetectorContext {
    let previousFrame: VideoFrame?

    static let empty = BallDetectorContext(previousFrame: nil)
}

protocol BallDetector {
    var kind: BallDetectorKind { get }

    func detectCandidates(
        in frame: VideoFrame,
        region: BallDetectionRegion,
        context: BallDetectorContext
    ) async -> [BallDetectionCandidate]
}

struct BallDetectorOutputFilter {
    let minimumConfidence: Float
    let maximumCandidates: Int

    static let production = BallDetectorOutputFilter(minimumConfidence: 0.15, maximumCandidates: 16)

    func apply(to candidates: [BallDetectionCandidate]) -> [BallDetectionCandidate] {
        guard maximumCandidates > 0 else {
            return []
        }

        return candidates
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maximumCandidates)
            .map { $0 }
    }
}
