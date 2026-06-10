import Foundation
import CoreGraphics
import CoreImage
import CoreML
import Vision

final class CoreMLBallDetector: BallDetector {
    let kind: BallDetectorKind = .coreML

    private let visionModel: VNCoreMLModel
    private let labels: Set<String>
    private let filter: BallDetectorOutputFilter

    init(
        model: MLModel,
        labels: Set<String> = ["ball", "golf_ball", "golf ball"],
        filter: BallDetectorOutputFilter = .production
    ) throws {
        self.visionModel = try VNCoreMLModel(for: model)
        self.labels = Set(labels.map { $0.lowercased() })
        self.filter = filter
    }

    func detectCandidates(
        in frame: VideoFrame,
        region: BallDetectionRegion,
        context: BallDetectorContext
    ) async -> [BallDetectionCandidate] {
        await withCheckedContinuation { continuation in
            let request = VNCoreMLRequest(model: visionModel) { [labels, filter] request, _ in
                let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []
                let candidates = observations.compactMap { observation -> BallDetectionCandidate? in
                    guard let bestLabel = observation.labels.first else {
                        return nil
                    }

                    let normalizedLabel = bestLabel.identifier.lowercased()
                    guard labels.isEmpty || labels.contains(normalizedLabel) else {
                        return nil
                    }

                    let box = observation.boundingBox
                    guard region.normalizedRect.intersects(box) else {
                        return nil
                    }

                    let center = CGPoint(x: box.midX, y: box.midY)
                    let area = Float(max(0, box.width * box.height))
                    return BallDetectionCandidate(
                        frameIndex: frame.index,
                        timestamp: frame.timestamp,
                        center: center,
                        boundingBox: box,
                        confidence: bestLabel.confidence,
                        source: .coreML,
                        features: [
                            "class_confidence": bestLabel.confidence,
                            "box_area": area,
                            "label_ball": normalizedLabel == "ball" ? 1 : 0,
                            "label_golf_ball": normalizedLabel == "golf_ball" || normalizedLabel == "golf ball" ? 1 : 0
                        ]
                    )
                }

                continuation.resume(returning: filter.apply(to: candidates))
            }

            request.imageCropAndScaleOption = .scaleFit
            let handler = VNImageRequestHandler(ciImage: frame.image, orientation: .up)

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}
