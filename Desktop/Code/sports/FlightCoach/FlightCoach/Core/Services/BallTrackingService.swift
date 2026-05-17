import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

final class BallTrackingService {
    static let shared = BallTrackingService()

    // Cached context — creating one per frame is expensive
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Scale factor for diff image before pixel walking — keeps it fast on HD video
    private let diffScale: CGFloat = 0.25

    private init() {}

    func trackBall(
        in frames: [VideoFrame],
        contactFrameHint: Int? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async -> [BallTrackPoint] {
        guard frames.count > 1 else { return [] }

        var trackPoints: [BallTrackPoint] = []
        var previousImage: CIImage? = nil

        // Scan all frames but focus analysis around where the ball should move
        for (idx, frame) in frames.enumerated() {
            defer { previousImage = frame.image }

            guard let prev = previousImage else { continue }

            if let point = detectBallMovement(
                current: frame.image,
                previous: prev,
                frameIndex: frame.index,
                timestamp: frame.timestamp
            ) {
                trackPoints.append(point)
            }

            onProgress?(Double(idx + 1) / Double(frames.count))
            if idx % 10 == 0 { await Task.yield() }
        }

        return smooth(trackPoints: trackPoints)
    }

    private func detectBallMovement(
        current: CIImage,
        previous: CIImage,
        frameIndex: Int,
        timestamp: TimeInterval
    ) -> BallTrackPoint? {
        // Scale down both frames for speed
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = current
        scale.scale = Float(diffScale)
        scale.aspectRatio = 1.0
        guard let scaledCurrent = scale.outputImage else { return nil }

        scale.inputImage = previous
        guard let scaledPrevious = scale.outputImage else { return nil }

        // Absolute difference
        let diff = CIFilter.colorAbsoluteDifference()
        diff.inputImage = scaledCurrent
        diff.inputImage2 = scaledPrevious
        guard let diffImage = diff.outputImage else { return nil }

        // Threshold to isolate significant motion
        let thresh = CIFilter.colorThreshold()
        thresh.inputImage = diffImage
        thresh.threshold = 0.12
        guard let thresholded = thresh.outputImage else { return nil }

        let extent = thresholded.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }

        guard let cgImage = ciContext.createCGImage(thresholded, from: extent) else { return nil }

        let (centroid, pixelCount, confidence) = computeBrightCentroid(from: cgImage)

        // pixelCount window: too few = noise, too many = large motion (person, not ball)
        guard pixelCount > 8, pixelCount < 1500, confidence > 0.25 else { return nil }

        // Map centroid back to normalised [0,1] video coords
        let normX = Float(centroid.x / extent.width)
        let normY = Float(1.0 - centroid.y / extent.height)

        return BallTrackPoint(
            frameIndex: frameIndex,
            timestamp: timestamp,
            x: normX,
            y: normY,
            confidence: Float(confidence)
        )
    }

    private func computeBrightCentroid(from image: CGImage) -> (CGPoint, Int, Double) {
        let width = image.width
        let height = image.height

        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return (.zero, 0, 0)
        }

        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let bytesPerRow = image.bytesPerRow
        var sumX: Double = 0
        var sumY: Double = 0
        var count = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(data) else { continue }
                let r = Double(ptr[offset])
                let g = Double(ptr[offset + 1])
                let b = Double(ptr[offset + 2])
                let brightness = (r + g + b) / 765.0
                if brightness > 0.45 {
                    sumX += Double(x)
                    sumY += Double(y)
                    count += 1
                }
            }
        }

        guard count > 0 else { return (.zero, 0, 0) }

        let centroid = CGPoint(x: sumX / Double(count), y: sumY / Double(count))
        // Confidence scales with how compact the blob is (small tight clusters = ball-like)
        let confidence = min(1.0, Double(count) / 300.0)
        return (centroid, count, confidence)
    }

    private func smooth(trackPoints: [BallTrackPoint]) -> [BallTrackPoint] {
        guard trackPoints.count > 2 else { return trackPoints }

        return trackPoints.enumerated().map { i, curr in
            let prev = trackPoints[max(0, i - 1)]
            let next = trackPoints[min(trackPoints.count - 1, i + 1)]
            return BallTrackPoint(
                frameIndex: curr.frameIndex,
                timestamp: curr.timestamp,
                x: prev.x * 0.25 + curr.x * 0.5 + next.x * 0.25,
                y: prev.y * 0.25 + curr.y * 0.5 + next.y * 0.25,
                confidence: curr.confidence
            )
        }
    }
}
