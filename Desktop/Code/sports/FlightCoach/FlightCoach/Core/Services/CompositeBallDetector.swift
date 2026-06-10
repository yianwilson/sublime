import Foundation
import CoreGraphics

struct BallDetectorFusionConfig {
    let overlapThreshold: CGFloat
    let minimumConfidence: Float
    let maximumCandidates: Int

    static let production = BallDetectorFusionConfig(
        overlapThreshold: 0.28,
        minimumConfidence: 0.15,
        maximumCandidates: 16
    )
}

final class CompositeBallDetector: BallDetector {
    let kind: BallDetectorKind = .hybrid

    private let detectors: [BallDetector]
    private let config: BallDetectorFusionConfig

    init(detectors: [BallDetector], config: BallDetectorFusionConfig = .production) {
        self.detectors = detectors
        self.config = config
    }

    func detectCandidates(
        in frame: VideoFrame,
        region: BallDetectionRegion,
        context: BallDetectorContext
    ) async -> [BallDetectionCandidate] {
        guard !detectors.isEmpty else {
            return []
        }

        var rawCandidates: [BallDetectionCandidate] = []
        for detector in detectors {
            let candidates = await detector.detectCandidates(
                in: frame,
                region: region,
                context: context
            )
            rawCandidates.append(contentsOf: candidates)
        }

        return BallDetectorOutputFilter(
            minimumConfidence: config.minimumConfidence,
            maximumCandidates: config.maximumCandidates
        )
        .apply(to: fuse(rawCandidates))
    }

    private func fuse(_ candidates: [BallDetectionCandidate]) -> [BallDetectionCandidate] {
        var remaining = candidates.sorted { $0.confidence > $1.confidence }
        var fused: [BallDetectionCandidate] = []

        while let anchor = remaining.first {
            remaining.removeFirst()

            var cluster = [anchor]
            var leftovers: [BallDetectionCandidate] = []

            for candidate in remaining {
                if intersectionOverUnion(anchor.boundingBox, candidate.boundingBox) >= config.overlapThreshold {
                    cluster.append(candidate)
                } else {
                    leftovers.append(candidate)
                }
            }

            fused.append(fuseCluster(cluster))
            remaining = leftovers
        }

        return fused
    }

    private func fuseCluster(_ cluster: [BallDetectionCandidate]) -> BallDetectionCandidate {
        guard cluster.count > 1 else {
            return cluster[0]
        }

        let weightSum = CGFloat(cluster.reduce(Float(0)) { $0 + max(0.001, $1.confidence) })
        let weightedCenter = cluster.reduce(CGPoint.zero) { partial, candidate in
            let weight = CGFloat(max(0.001, candidate.confidence)) / weightSum
            return CGPoint(
                x: partial.x + candidate.center.x * weight,
                y: partial.y + candidate.center.y * weight
            )
        }

        let weightedBox = cluster.reduce(CGRect.zero) { partial, candidate in
            let weight = CGFloat(max(0.001, candidate.confidence)) / weightSum
            return CGRect(
                x: partial.origin.x + candidate.boundingBox.origin.x * weight,
                y: partial.origin.y + candidate.boundingBox.origin.y * weight,
                width: partial.width + candidate.boundingBox.width * weight,
                height: partial.height + candidate.boundingBox.height * weight
            )
        }

        let best = cluster.max { $0.confidence < $1.confidence } ?? cluster[0]
        let detectorKinds = Set(cluster.map(\.source.rawValue))
        let agreementBoost = min(0.12, Float(cluster.count - 1) * 0.04)
        let confidence = min(1, best.confidence + agreementBoost)

        return BallDetectionCandidate(
            frameIndex: best.frameIndex,
            timestamp: best.timestamp,
            center: weightedCenter,
            boundingBox: weightedBox,
            confidence: confidence,
            source: .hybrid,
            features: [
                "detector_count": Float(detectorKinds.count),
                "candidate_count": Float(cluster.count),
                "max_confidence": best.confidence,
                "agreement_boost": agreementBoost
            ]
        )
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea > 0 else {
            return 0
        }

        return intersectionArea / unionArea
    }
}
