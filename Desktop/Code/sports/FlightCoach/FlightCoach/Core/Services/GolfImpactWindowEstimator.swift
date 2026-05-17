import Foundation
import CoreGraphics

final class GolfImpactWindowEstimator {
    static let shared = GolfImpactWindowEstimator()

    private init() {}

    func estimateImpactWindow(
        frames: [VideoFrame],
        poseFrames: [PoseFrame],
        manualContactFrame: Int?
    ) -> ImpactWindow {
        let sortedFrames = frames.sorted { $0.index < $1.index }
        let firstFrame = sortedFrames.first?.index ?? 0
        let lastFrame = sortedFrames.last?.index ?? max(firstFrame, 1)
        let step = typicalFrameStep(sortedFrames.map(\.index))

        if let manualContactFrame {
            let radius = max(step * 5, 10)
            return ImpactWindow(
                startFrameIndex: max(firstFrame, manualContactFrame - radius),
                estimatedFrameIndex: min(max(manualContactFrame, firstFrame), lastFrame),
                endFrameIndex: min(lastFrame, manualContactFrame + radius),
                confidence: 0.95,
                reason: "manual-contact"
            )
        }

        if let wristPeak = estimateFromWristSpeed(poseFrames: poseFrames, firstFrame: firstFrame, lastFrame: lastFrame, step: step) {
            return wristPeak
        }

        let start = firstFrame + Int(Double(lastFrame - firstFrame) * 0.35)
        let end = firstFrame + Int(Double(lastFrame - firstFrame) * 0.75)
        return ImpactWindow(
            startFrameIndex: min(start, end),
            estimatedFrameIndex: firstFrame + Int(Double(lastFrame - firstFrame) * 0.55),
            endFrameIndex: max(start, end),
            confidence: 0.2,
            reason: "broad-fallback"
        )
    }

    private func estimateFromWristSpeed(
        poseFrames: [PoseFrame],
        firstFrame: Int,
        lastFrame: Int,
        step: Int
    ) -> ImpactWindow? {
        let sorted = poseFrames.sorted { $0.frameIndex < $1.frameIndex }
        guard sorted.count > 4 else { return nil }

        var measurements: [(frameIndex: Int, speed: Float)] = []
        for i in 1..<sorted.count {
            guard let previous = bestWrist(in: sorted[i - 1]),
                  let current = bestWrist(in: sorted[i]) else { continue }

            let dt = max(1.0 / 240.0, sorted[i].timestamp - sorted[i - 1].timestamp)
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let speed = sqrt(dx * dx + dy * dy) / Float(dt)
            measurements.append((sorted[i].frameIndex, speed))
        }

        guard !measurements.isEmpty else { return nil }

        let lower = firstFrame + Int(Double(lastFrame - firstFrame) * 0.20)
        let upper = firstFrame + Int(Double(lastFrame - firstFrame) * 0.88)
        let trimmed = measurements.filter { $0.frameIndex >= lower && $0.frameIndex <= upper }
        let candidates = trimmed.isEmpty ? measurements : trimmed

        guard let peak = candidates.max(by: { $0.speed < $1.speed }), peak.speed > 0.35 else {
            return nil
        }

        let radius = max(step * 6, 12)
        let confidence = min(0.7, max(0.35, peak.speed / 3.5))
        return ImpactWindow(
            startFrameIndex: max(firstFrame, peak.frameIndex - radius),
            estimatedFrameIndex: peak.frameIndex,
            endFrameIndex: min(lastFrame, peak.frameIndex + radius),
            confidence: confidence,
            reason: "wrist-speed-peak"
        )
    }

    private func bestWrist(in frame: PoseFrame) -> PoseLandmark? {
        [frame.leftWrist, frame.rightWrist]
            .compactMap { $0 }
            .filter { $0.confidence > 0.35 }
            .max { $0.confidence < $1.confidence }
    }

    private func typicalFrameStep(_ indices: [Int]) -> Int {
        guard indices.count > 1 else { return 1 }
        let deltas = zip(indices.dropFirst(), indices).map { max(1, $0 - $1) }.sorted()
        return deltas[deltas.count / 2]
    }
}
