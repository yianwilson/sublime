import Foundation
import CoreML

enum BallDetectorFactory {
    static func productionDetector(
        bundledModelName: String = "GolfBallDetector",
        labels: Set<String> = ["ball", "golf_ball", "golf ball", "sports ball"]
    ) -> BallDetector {
        let heuristic = HeuristicBallDetector()

        guard let modelURL = Bundle.main.url(forResource: bundledModelName, withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: modelURL),
              let coreMLDetector = try? CoreMLBallDetector(model: model, labels: labels) else {
            return heuristic
        }

        return CompositeBallDetector(detectors: [coreMLDetector, heuristic])
    }
}
