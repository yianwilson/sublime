import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

final class BallTrackingService {
    static let shared = BallTrackingService()

    private init() {}

    func trackBall(
        in frames: [VideoFrame],
        contactFrameHint: Int? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async -> [BallTrackPoint] {
        guard frames.count > 1 else { return [] }

        var trackPoints: [BallTrackPoint] = []
        var previousImage: CIImage? = nil

        let startIndex = max(0, (contactFrameHint ?? 0) - 5)
        let analysisFrames = Array(frames[startIndex...])

        for (idx, frame) in analysisFrames.enumerated() {
            defer { previousImage = frame.image }

            guard let prev = previousImage else { continue }

            if let point = await detectBallMovement(current: frame.image, previous: prev, frameIndex: frame.index, timestamp: frame.timestamp) {
                trackPoints.append(point)
            }

            onProgress?(Double(idx + 1) / Double(analysisFrames.count))
        }

        return smooth(trackPoints: trackPoints)
    }

    private func detectBallMovement(
        current: CIImage,
        previous: CIImage,
        frameIndex: Int,
        timestamp: TimeInterval
    ) async -> BallTrackPoint? {
        let differenceFilter = CIFilter.colorAbsoluteDifference()
        differenceFilter.inputImage = current
        differenceFilter.inputImage2 = previous

        guard let diffImage = differenceFilter.outputImage else { return nil }

        let thresholdFilter = CIFilter.colorThreshold()
        thresholdFilter.inputImage = diffImage
        thresholdFilter.threshold = 0.15

        guard let thresholded = thresholdFilter.outputImage else { return nil }

        let extent = thresholded.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }

        let context = CIContext()
        guard let cgImage = context.createCGImage(thresholded, from: extent) else { return nil }

        let (centroid, pixelCount, confidence) = computeBrightCentroid(from: cgImage, imageSize: extent.size)

        guard pixelCount > 5 && pixelCount < 2000 && confidence > 0.3 else { return nil }

        return BallTrackPoint(
            frameIndex: frameIndex,
            timestamp: timestamp,
            x: Float(centroid.x / extent.width),
            y: Float(1.0 - centroid.y / extent.height),
            confidence: Float(confidence)
        )
    }

    private func computeBrightCentroid(from image: CGImage, imageSize: CGSize) -> (CGPoint, Int, Double) {
        let width = image.width
        let height = image.height
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return (.zero, 0, 0)
        }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        var sumX: Double = 0
        var sumY: Double = 0
        var count = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let b = Double(ptr[offset])
                let g = Double(ptr[offset + 1])
                let r = Double(ptr[offset + 2])
                let brightness = (r + g + b) / 765.0
                if brightness > 0.5 {
                    sumX += Double(x)
                    sumY += Double(y)
                    count += 1
                }
            }
        }

        guard count > 0 else { return (.zero, 0, 0) }

        let centroid = CGPoint(x: sumX / Double(count), y: sumY / Double(count))
        let confidence = min(1.0, Double(count) / 200.0)
        return (centroid, count, confidence)
    }

    private func smooth(trackPoints: [BallTrackPoint]) -> [BallTrackPoint] {
        guard trackPoints.count > 2 else { return trackPoints }

        var smoothed: [BallTrackPoint] = []
        for i in 0..<trackPoints.count {
            let prev = trackPoints[max(0, i - 1)]
            let curr = trackPoints[i]
            let next = trackPoints[min(trackPoints.count - 1, i + 1)]

            let smoothX = (prev.x * 0.25 + curr.x * 0.5 + next.x * 0.25)
            let smoothY = (prev.y * 0.25 + curr.y * 0.5 + next.y * 0.25)

            smoothed.append(BallTrackPoint(
                frameIndex: curr.frameIndex,
                timestamp: curr.timestamp,
                x: smoothX,
                y: smoothY,
                confidence: curr.confidence
            ))
        }
        return smoothed
    }
}
