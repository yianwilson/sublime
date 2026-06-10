import Foundation
import UIKit
import CoreGraphics

struct BallCandidateDebugResult: Identifiable, Equatable {
    enum Status: String, Equatable {
        case candidate
        case rejected
        case selected
    }

    let id = UUID()
    let boundingBox: CGRect
    let center: CGPoint
    let score: Float
    let area: Int
    let brightness: Float
    let circularity: Float
    let groundScore: Float
    let status: Status
    let rejectionReason: String?
}

struct BallCandidateDebugReport: Equatable {
    let candidates: [BallCandidateDebugResult]
    let searchRegion: CGRect
    let selected: BallCandidateDebugResult?
}

final class BallCandidateDebugService {
    static let shared = BallCandidateDebugService()

    private init() {}

    func analyze(image: UIImage, maxCandidates: Int = 20) -> BallCandidateDebugReport {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return BallCandidateDebugReport(candidates: [], searchRegion: defaultSearchRegion, selected: nil)
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = max(1, cgImage.bitsPerPixel / 8)
        let bytesPerRow = cgImage.bytesPerRow
        let dataLength = CFDataGetLength(data)
        let searchRegion = defaultSearchRegion

        var mask = [Bool](repeating: false, count: width * height)
        var values = [Float](repeating: 0, count: width * height)

        let minX = max(0, Int(searchRegion.minX * CGFloat(width)))
        let maxX = min(width - 1, Int(searchRegion.maxX * CGFloat(width)))
        let minY = max(0, Int(searchRegion.minY * CGFloat(height)))
        let maxY = min(height - 1, Int(searchRegion.maxY * CGFloat(height)))

        for y in minY...maxY {
            for x in minX...maxX {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < dataLength else { continue }

                let c0 = Double(ptr[offset])
                let c1 = Double(ptr[offset + 1])
                let c2 = Double(ptr[offset + 2])
                let brightness = (c0 + c1 + c2) / 765.0
                let balance = 1.0 - min(1.0, (abs(c0 - c1) + abs(c1 - c2) + abs(c0 - c2)) / 255.0)

                guard brightness > 0.56, balance > 0.34 else { continue }

                let index = y * width + x
                mask[index] = true
                values[index] = Float(brightness * 0.55 + balance * 0.45)
            }
        }

        let all = connectedComponents(mask: mask, values: values, width: width, height: height)
        let ranked = all
            .map { componentResult($0, width: width, height: height) }
            .sorted { $0.score > $1.score }

        let selected = ranked.first { $0.status == .candidate && $0.score >= 0.52 }
        let displayed = ranked.prefix(maxCandidates).map { result -> BallCandidateDebugResult in
            guard let selected, result.id == selected.id else { return result }
            return BallCandidateDebugResult(
                boundingBox: result.boundingBox,
                center: result.center,
                score: result.score,
                area: result.area,
                brightness: result.brightness,
                circularity: result.circularity,
                groundScore: result.groundScore,
                status: .selected,
                rejectionReason: nil
            )
        }

        return BallCandidateDebugReport(candidates: Array(displayed), searchRegion: searchRegion, selected: selected)
    }

    private var defaultSearchRegion: CGRect {
        CGRect(x: 0.05, y: 0.55, width: 0.90, height: 0.38)
    }

    private struct PixelComponent {
        let pixels: [(x: Int, y: Int)]
        let averageValue: Float
    }

    private func connectedComponents(mask: [Bool], values: [Float], width: Int, height: Int) -> [PixelComponent] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [PixelComponent] = []

        for y in 0..<height {
            for x in 0..<width {
                let start = y * width + x
                guard mask[start], !visited[start] else { continue }

                var queue = [(x, y)]
                var pixels: [(x: Int, y: Int)] = []
                var valueSum: Float = 0
                visited[start] = true

                var idx = 0
                while idx < queue.count {
                    let (cx, cy) = queue[idx]
                    idx += 1
                    pixels.append((cx, cy))
                    valueSum += values[cy * width + cx]

                    for neighbor in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                        let nx = neighbor.0
                        let ny = neighbor.1
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let nIndex = ny * width + nx
                        guard mask[nIndex], !visited[nIndex] else { continue }
                        visited[nIndex] = true
                        queue.append((nx, ny))
                    }
                }

                guard !pixels.isEmpty else { continue }
                components.append(PixelComponent(pixels: pixels, averageValue: valueSum / Float(pixels.count)))
            }
        }

        return components
    }

    private func componentResult(_ component: PixelComponent, width: Int, height: Int) -> BallCandidateDebugResult {
        let pixels = component.pixels
        let minX = pixels.map(\.x).min() ?? 0
        let maxX = pixels.map(\.x).max() ?? minX
        let minY = pixels.map(\.y).min() ?? 0
        let maxY = pixels.map(\.y).max() ?? minY
        let boxWidth = max(1, maxX - minX + 1)
        let boxHeight = max(1, maxY - minY + 1)
        let area = pixels.count
        let centerX = pixels.map(\.x).reduce(0, +) / max(1, area)
        let centerY = pixels.map(\.y).reduce(0, +) / max(1, area)

        let aspect = Float(min(boxWidth, boxHeight)) / Float(max(boxWidth, boxHeight))
        let fill = Float(area) / Float(boxWidth * boxHeight)
        let circularity = min(1, aspect * 0.65 + fill * 0.35)
        let normalizedYFromBottom = 1 - Float(centerY) / Float(max(1, height - 1))
        let groundScore = max(0, 1 - abs(normalizedYFromBottom - 0.16) / 0.20)
        let sizeScore = max(0, 1 - abs(Float(area) - 18) / 70)
        let edgePenalty: Float = centerX < Int(Double(width) * 0.08) || centerX > Int(Double(width) * 0.92) ? 0.22 : 0
        let tooHighPenalty: Float = normalizedYFromBottom > 0.42 ? 0.45 : 0
        let tooLargePenalty: Float = area > 180 ? 0.40 : 0

        let score = max(
            0,
            component.averageValue * 0.18
            + circularity * 0.22
            + groundScore * 0.34
            + sizeScore * 0.18
            - edgePenalty
            - tooHighPenalty
            - tooLargePenalty
        )

        let reason: String?
        if area > 180 {
            reason = "large"
        } else if normalizedYFromBottom > 0.42 {
            reason = "high"
        } else if edgePenalty > 0 {
            reason = "edge"
        } else if score < 0.38 {
            reason = "low"
        } else {
            reason = nil
        }

        return BallCandidateDebugResult(
            boundingBox: CGRect(
                x: CGFloat(minX) / CGFloat(width),
                y: CGFloat(minY) / CGFloat(height),
                width: CGFloat(boxWidth) / CGFloat(width),
                height: CGFloat(boxHeight) / CGFloat(height)
            ),
            center: CGPoint(x: CGFloat(centerX) / CGFloat(width), y: CGFloat(centerY) / CGFloat(height)),
            score: score,
            area: area,
            brightness: component.averageValue,
            circularity: circularity,
            groundScore: groundScore,
            status: reason == nil ? .candidate : .rejected,
            rejectionReason: reason
        )
    }
}
