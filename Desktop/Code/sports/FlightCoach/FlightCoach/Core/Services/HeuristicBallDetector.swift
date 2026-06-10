import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

final class HeuristicBallDetector: BallDetector {
    let kind: BallDetectorKind = .heuristic

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let workingScale: Float

    init(workingScale: Float = 0.35) {
        self.workingScale = workingScale
    }

    func detectCandidates(
        in frame: VideoFrame,
        region: BallDetectionRegion,
        context: BallDetectorContext = .empty
    ) async -> [BallDetectionCandidate] {
        guard let scaled = scaleImage(frame.image) else {
            return []
        }

        var candidates = findBrightCandidates(
            in: scaled,
            frame: frame,
            within: region.normalizedRect
        )

        if let previous = context.previousFrame,
           let previousScaled = scaleImage(previous.image) {
            candidates.append(contentsOf: findMotionCandidates(
                current: scaled,
                previous: previousScaled,
                frame: frame,
                within: region.normalizedRect
            ))
        }

        return BallDetectorOutputFilter.production.apply(to: candidates)
    }

    private struct PixelComponent {
        let pixels: [(Int, Int)]
        let score: Float
    }

    private func findBrightCandidates(
        in image: CIImage,
        frame: VideoFrame,
        within roi: CGRect
    ) -> [BallDetectionCandidate] {
        guard let cg = ciContext.createCGImage(image, from: image.extent),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return []
        }

        let width = cg.width
        let height = cg.height
        let bytesPerPixel = max(1, cg.bitsPerPixel / 8)
        let bytesPerRow = cg.bytesPerRow
        let dataLength = CFDataGetLength(data)

        var mask = [Bool](repeating: false, count: width * height)
        var scores = [Float](repeating: 0, count: width * height)

        for pixelY in 0..<height {
            for pixelX in 0..<width {
                let offset = pixelY * bytesPerRow + pixelX * bytesPerPixel
                guard offset + 2 < dataLength else { continue }

                let c0 = Double(ptr[offset])
                let c1 = Double(ptr[offset + 1])
                let c2 = Double(ptr[offset + 2])
                let brightness = (c0 + c1 + c2) / 765.0
                let channelSpread = abs(c0 - c1) + abs(c1 - c2) + abs(c0 - c2)
                let balance = 1.0 - min(1.0, channelSpread / 210.0)
                guard brightness > 0.68, balance > 0.45 else { continue }

                let normalized = normalizedPoint(pixelX: pixelX, pixelY: pixelY, width: width, height: height)
                guard roi.contains(normalized) else { continue }

                let index = pixelY * width + pixelX
                mask[index] = true
                scores[index] = Float(brightness * 0.7 + balance * 0.3)
            }
        }

        return connectedComponents(mask: mask, scores: scores, width: width, height: height)
            .compactMap { component in
                makeCandidate(
                    from: component,
                    width: width,
                    height: height,
                    frame: frame,
                    motionScore: 0,
                    detectorScore: component.score,
                    sourceLabel: "bright"
                )
            }
            .filter { candidate in
                let pixels = candidate.features["pixel_count"] ?? 0
                return pixels >= 2 && pixels <= 700
            }
            .sorted { $0.confidence > $1.confidence }
    }

    private func findMotionCandidates(
        current: CIImage,
        previous: CIImage,
        frame: VideoFrame,
        within roi: CGRect
    ) -> [BallDetectionCandidate] {
        let difference = CIFilter.colorAbsoluteDifference()
        difference.inputImage = current
        difference.inputImage2 = previous

        guard let diffImage = difference.outputImage,
              let cg = ciContext.createCGImage(diffImage, from: diffImage.extent),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return []
        }

        let width = cg.width
        let height = cg.height
        let bytesPerPixel = max(1, cg.bitsPerPixel / 8)
        let bytesPerRow = cg.bytesPerRow
        let dataLength = CFDataGetLength(data)

        var mask = [Bool](repeating: false, count: width * height)
        var scores = [Float](repeating: 0, count: width * height)

        for pixelY in 0..<height {
            for pixelX in 0..<width {
                let offset = pixelY * bytesPerRow + pixelX * bytesPerPixel
                guard offset + 2 < dataLength else { continue }

                let motion = Float(ptr[offset]) + Float(ptr[offset + 1]) + Float(ptr[offset + 2])
                guard motion > 45 else { continue }

                let normalized = normalizedPoint(pixelX: pixelX, pixelY: pixelY, width: width, height: height)
                guard roi.contains(normalized) else { continue }

                let index = pixelY * width + pixelX
                mask[index] = true
                scores[index] = min(1, motion / 255.0)
            }
        }

        return connectedComponents(mask: mask, scores: scores, width: width, height: height)
            .compactMap { component in
                makeCandidate(
                    from: component,
                    width: width,
                    height: height,
                    frame: frame,
                    motionScore: min(1, component.score),
                    detectorScore: component.score,
                    sourceLabel: "motion"
                )
            }
            .filter { candidate in
                let pixels = candidate.features["pixel_count"] ?? 0
                return pixels >= 2 && pixels <= 500
            }
            .sorted { $0.confidence > $1.confidence }
    }

    private func connectedComponents(mask: [Bool], scores: [Float], width: Int, height: Int) -> [PixelComponent] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [PixelComponent] = []

        for startY in 0..<height {
            for startX in 0..<width {
                let startIndex = startY * width + startX
                guard mask[startIndex], !visited[startIndex] else { continue }

                var queue = [(startX, startY)]
                var pixels: [(Int, Int)] = []
                var scoreSum: Float = 0
                visited[startIndex] = true

                var cursor = 0
                while cursor < queue.count {
                    let (x, y) = queue[cursor]
                    cursor += 1
                    pixels.append((x, y))
                    scoreSum += scores[y * width + x]

                    for neighbor in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                        let nx = neighbor.0
                        let ny = neighbor.1
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let index = ny * width + nx
                        guard mask[index], !visited[index] else { continue }
                        visited[index] = true
                        queue.append((nx, ny))
                    }
                }

                guard !pixels.isEmpty else { continue }
                components.append(PixelComponent(pixels: pixels, score: scoreSum / Float(pixels.count)))
            }
        }

        return components
    }

    private func makeCandidate(
        from component: PixelComponent,
        width: Int,
        height: Int,
        frame: VideoFrame,
        motionScore: Float,
        detectorScore: Float,
        sourceLabel: String
    ) -> BallDetectionCandidate? {
        let pixels = component.pixels
        guard pixels.count >= 2 else { return nil }

        let xs = pixels.map(\.0)
        let ys = pixels.map(\.1)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return nil
        }

        let sumX = pixels.reduce(0.0) { $0 + Double($1.0) }
        let sumY = pixels.reduce(0.0) { $0 + Double($1.1) }
        let center = CGPoint(
            x: sumX / Double(pixels.count) / Double(max(1, width - 1)),
            y: 1.0 - sumY / Double(pixels.count) / Double(max(1, height - 1))
        )

        let boxWidthPixels = max(1, maxX - minX + 1)
        let boxHeightPixels = max(1, maxY - minY + 1)
        let aspect = Float(min(boxWidthPixels, boxHeightPixels)) / Float(max(boxWidthPixels, boxHeightPixels))
        let fill = Float(pixels.count) / Float(boxWidthPixels * boxHeightPixels)
        let sizeScore = max(0, 1 - abs(Float(pixels.count) - 28) / 120)
        let shapeScore = max(0, min(1, aspect * 0.55 + fill * 0.25 + sizeScore * 0.20))
        let confidence = max(0, min(1, detectorScore * 0.45 + shapeScore * 0.35 + motionScore * 0.20))

        let boundingBox = CGRect(
            x: Double(minX) / Double(max(1, width - 1)),
            y: 1.0 - Double(maxY) / Double(max(1, height - 1)),
            width: Double(boxWidthPixels) / Double(max(1, width)),
            height: Double(boxHeightPixels) / Double(max(1, height))
        )

        return BallDetectionCandidate(
            frameIndex: frame.index,
            timestamp: frame.timestamp,
            center: center,
            boundingBox: boundingBox,
            confidence: confidence,
            source: kind,
            features: [
                "pixel_count": Float(pixels.count),
                "detector_score": detectorScore,
                "motion_score": motionScore,
                "shape_score": shapeScore,
                "source_\(sourceLabel)": 1
            ]
        )
    }

    private func normalizedPoint(pixelX: Int, pixelY: Int, width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: Double(pixelX) / Double(max(1, width - 1)),
            y: 1.0 - Double(pixelY) / Double(max(1, height - 1))
        )
    }

    private func scaleImage(_ image: CIImage) -> CIImage? {
        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = image
        scaleFilter.scale = workingScale
        scaleFilter.aspectRatio = 1.0
        return scaleFilter.outputImage
    }
}
