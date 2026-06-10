import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

final class GolfImpactWindowEstimator {
    static let shared = GolfImpactWindowEstimator()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

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

        // Pose-independent fallback: the downswing/impact is the largest whole-frame
        // motion spike. Works even when body-pose detection is unavailable.
        if let motionPeak = estimateFromGlobalMotion(frames: sortedFrames, firstFrame: firstFrame, lastFrame: lastFrame, step: step) {
            return motionPeak
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

    /// Estimate impact from the peak of whole-frame motion energy. No pose required.
    private func estimateFromGlobalMotion(
        frames: [VideoFrame],
        firstFrame: Int,
        lastFrame: Int,
        step: Int
    ) -> ImpactWindow? {
        let sorted = frames.sorted { $0.index < $1.index }
        guard sorted.count > 5 else { return nil }

        var energies: [(index: Int, energy: Float)] = []
        var previous: [Float]?
        for frame in sorted {
            guard let small = downsampledLuma(frame.image, targetWidth: 48) else { continue }
            if let previous, previous.count == small.count {
                var sum: Float = 0
                for i in 0..<small.count { sum += abs(small[i] - previous[i]) }
                energies.append((frame.index, sum / Float(small.count)))
            }
            previous = small
        }
        guard energies.count > 3 else { return nil }

        // Search the plausible swing region, away from the very start/end.
        let lower = firstFrame + Int(Double(lastFrame - firstFrame) * 0.15)
        let upper = firstFrame + Int(Double(lastFrame - firstFrame) * 0.92)
        let trimmed = energies.filter { $0.index >= lower && $0.index <= upper }
        let pool = trimmed.isEmpty ? energies : trimmed

        guard let peak = pool.max(by: { $0.energy < $1.energy }) else { return nil }

        // The peak must stand out from the typical (median) motion to be a real swing.
        let sortedEnergies = pool.map(\.energy).sorted()
        let median = sortedEnergies[sortedEnergies.count / 2]
        guard peak.energy > max(0.0008, median * 1.6) else { return nil }

        let radius = max(step * 6, 12)
        return ImpactWindow(
            startFrameIndex: max(firstFrame, peak.index - radius),
            estimatedFrameIndex: peak.index,
            endFrameIndex: min(lastFrame, peak.index + radius),
            confidence: 0.45,
            reason: "global-motion-peak"
        )
    }

    /// Downsample to a small luma vector for cheap whole-frame motion comparison.
    private func downsampledLuma(_ image: CIImage, targetWidth: CGFloat) -> [Float]? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = targetWidth / extent.width
        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = image
        scaleFilter.scale = Float(scale)
        scaleFilter.aspectRatio = 1.0
        guard let scaled = scaleFilter.outputImage,
              let cg = ciContext.createCGImage(scaled, from: scaled.extent),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let w = cg.width
        let h = cg.height
        let bpp = max(1, cg.bitsPerPixel / 8)
        let bpr = cg.bytesPerRow
        let dataLen = CFDataGetLength(data)

        var out = [Float]()
        out.reserveCapacity(w * h)
        for py in 0..<h {
            for px in 0..<w {
                let offset = py * bpr + px * bpp
                guard offset + 2 < dataLen else { out.append(0); continue }
                let luma = (Float(ptr[offset]) + Float(ptr[offset + 1]) + Float(ptr[offset + 2])) / 3.0
                out.append(luma)
            }
        }
        return out
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
