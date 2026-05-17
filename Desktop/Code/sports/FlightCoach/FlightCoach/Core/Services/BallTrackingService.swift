import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

final class BallTrackingService {
    static let shared = BallTrackingService()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Working resolution — 25% of source keeps it fast while a golf ball is still detectable
    private let workingScale: Float = 0.25

    private init() {}

    // MARK: - Public API

    func trackBall(
        in frames: [VideoFrame],
        poseFrames: [PoseFrame],
        contactFrameHint: Int?,
        onProgress: ((Double) -> Void)? = nil
    ) async -> [BallTrackPoint] {
        guard frames.count > 3 else { return [] }

        let totalFrames = frames.count

        // Phase 1 — Find the stationary ball at address.
        // The ball is still during setup; look for a consistent small white blob
        // in the first third of frames.
        onProgress?(0.05)
        let setupEnd = max(2, totalFrames / 3)
        let setupFrames = Array(frames.prefix(setupEnd))
        let bodyMask = buildBodyMask(from: poseFrames.prefix(setupEnd).map { $0 })
        let staticBallPos = findStaticBall(in: setupFrames, bodyMask: bodyMask)

        // Phase 2 — Track the ball post-impact.
        // Start from the known address position and look for it moving away.
        let contactIdx = contactFrameHint ?? (totalFrames / 2)
        onProgress?(0.2)

        var trackPoints: [BallTrackPoint] = []

        if let startPos = staticBallPos {
            // Record the ball sitting still just before impact
            let preContactFrames = frames.filter { $0.index < contactIdx }.suffix(3)
            for f in preContactFrames {
                trackPoints.append(BallTrackPoint(
                    frameIndex: f.index,
                    timestamp: f.timestamp,
                    x: Float(startPos.x),
                    y: Float(startPos.y),
                    confidence: 0.8
                ))
            }

            // Post-impact: follow the white ball as it moves away
            let postFrames = frames.filter { $0.index >= contactIdx }
            let postTrack = await trackPostImpact(
                frames: postFrames,
                startNorm: startPos,
                bodyMask: bodyMask,
                onProgress: { p in onProgress?(0.2 + p * 0.75) }
            )
            trackPoints.append(contentsOf: postTrack)
        } else {
            // Fallback — body-masked frame differencing across all frames
            let fallback = await maskedFrameDifference(
                frames: frames,
                bodyMask: bodyMask,
                onProgress: { p in onProgress?(p) }
            )
            trackPoints = fallback
        }

        onProgress?(1.0)
        return filterPhysicallyPlausible(smooth(trackPoints))
    }

    // MARK: - Phase 1: Find stationary ball at address

    private func findStaticBall(in frames: [VideoFrame], bodyMask: CGRect?) -> CGPoint? {
        var candidateSets: [[CGPoint]] = []

        for frame in frames {
            guard let scaled = scaleImage(frame.image) else { continue }
            let blobs = findWhiteBlobs(in: scaled, excludingMask: bodyMask)
            if !blobs.isEmpty {
                candidateSets.append(blobs.map(\.centroid))
            }
        }

        guard candidateSets.count >= 2 else { return nil }

        // Find a position consistent across multiple frames — that's the stationary ball
        return mostConsistentPosition(candidateSets, maxSpread: 0.04)
    }

    // MARK: - Phase 2: Track post-impact

    private func trackPostImpact(
        frames: [VideoFrame],
        startNorm: CGPoint,
        bodyMask: CGRect?,
        onProgress: ((Double) -> Void)?
    ) async -> [BallTrackPoint] {
        var results: [BallTrackPoint] = []
        var currentPos = startNorm
        var velocity = CGPoint(x: 0, y: -0.015) // golf ball typically rises initially
        var lostCount = 0
        let maxLost = 4

        for (idx, frame) in frames.enumerated() {
            guard let scaled = scaleImage(frame.image) else { continue }

            // Search radius grows as the ball accelerates away
            let searchRadius = min(0.25, 0.05 + Double(idx) * 0.012)
            let searchRect = CGRect(
                x: currentPos.x - searchRadius,
                y: currentPos.y - searchRadius,
                width: searchRadius * 2,
                height: searchRadius * 2
            )

            let blobs = findWhiteBlobs(in: scaled, excludingMask: bodyMask, withinROI: searchRect)

            if let best = blobs.first {
                let newPos = best.centroid
                let newVelocity = CGPoint(x: newPos.x - currentPos.x, y: newPos.y - currentPos.y)

                // Sanity check: velocity should be consistent direction (ball doesn't reverse)
                if idx > 0 {
                    let dotProduct = velocity.x * newVelocity.x + velocity.y * newVelocity.y
                    if dotProduct < -0.001 { // reversed direction — likely a false positive
                        lostCount += 1
                        currentPos = CGPoint(x: currentPos.x + velocity.x, y: currentPos.y + velocity.y)
                        if lostCount > maxLost { break }
                        continue
                    }
                }

                velocity = CGPoint(
                    x: velocity.x * 0.4 + newVelocity.x * 0.6,
                    y: velocity.y * 0.4 + newVelocity.y * 0.6
                )
                currentPos = newPos
                lostCount = 0

                results.append(BallTrackPoint(
                    frameIndex: frame.index,
                    timestamp: frame.timestamp,
                    x: Float(newPos.x),
                    y: Float(newPos.y),
                    confidence: Float(min(0.9, best.confidence))
                ))
            } else {
                lostCount += 1
                // Extrapolate position using last known velocity
                currentPos = CGPoint(x: currentPos.x + velocity.x, y: currentPos.y + velocity.y)
                if lostCount > maxLost { break }
            }

            if idx % 5 == 0 { await Task.yield() }
            onProgress?(Double(idx + 1) / Double(frames.count))
        }

        return results
    }

    // MARK: - Fallback: body-masked frame differencing

    private func maskedFrameDifference(
        frames: [VideoFrame],
        bodyMask: CGRect?,
        onProgress: ((Double) -> Void)?
    ) async -> [BallTrackPoint] {
        var results: [BallTrackPoint] = []
        var prev: CIImage? = nil

        for (idx, frame) in frames.enumerated() {
            defer { prev = frame.image }
            guard let previous = prev else { continue }

            guard let scaledCurrent = scaleImage(frame.image),
                  let scaledPrev = scaleImage(previous) else { continue }

            let diff = CIFilter.colorAbsoluteDifference()
            diff.inputImage = scaledCurrent
            diff.inputImage2 = scaledPrev
            guard let diffImg = diff.outputImage else { continue }

            let thresh = CIFilter.colorThreshold()
            thresh.inputImage = diffImg
            thresh.threshold = 0.10
            guard let thresholded = thresh.outputImage else { continue }

            let extent = thresholded.extent
            guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { continue }
            guard let cg = ciContext.createCGImage(thresholded, from: extent) else { continue }

            let blobs = findWhiteBlobs(in: cg, in: extent, excludingMask: bodyMask, withinROI: nil)
            if let b = blobs.first, b.size > 4, b.size < 800 {
                results.append(BallTrackPoint(
                    frameIndex: frame.index,
                    timestamp: frame.timestamp,
                    x: Float(b.centroid.x),
                    y: Float(b.centroid.y),
                    confidence: Float(min(0.5, b.confidence))
                ))
            }

            if idx % 8 == 0 { await Task.yield() }
            onProgress?(Double(idx + 1) / Double(frames.count))
        }

        return results
    }

    // MARK: - White blob detection

    private struct BlobResult {
        let centroid: CGPoint   // normalised [0,1]
        let size: Int           // pixel count
        let confidence: Double
    }

    private func findWhiteBlobs(
        in ciImage: CIImage,
        excludingMask: CGRect?,
        withinROI: CGRect? = nil
    ) -> [BlobResult] {
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return [] }
        return findWhiteBlobs(in: cg, in: ciImage.extent, excludingMask: excludingMask, withinROI: withinROI)
    }

    private func findWhiteBlobs(
        in cg: CGImage,
        in extent: CGRect,
        excludingMask: CGRect?,
        withinROI: CGRect?
    ) -> [BlobResult] {
        let w = cg.width
        let h = cg.height
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return [] }

        let bpp = max(1, cg.bitsPerPixel / 8)
        let bpr = cg.bytesPerRow
        let dataLen = CFDataGetLength(data)

        // Build a boolean map of "bright white" pixels
        var bright = [Bool](repeating: false, count: w * h)

        for py in 0..<h {
            for px in 0..<w {
                let offset = py * bpr + px * bpp
                guard offset + 2 < dataLen else { continue }

                let r = Double(ptr[offset])
                let g = Double(ptr[offset + 1])
                let b = Double(ptr[offset + 2])

                // A golf ball is white: all channels high, relatively balanced
                let brightness = (r + g + b) / 765.0
                let balanced = abs(r - g) < 40 && abs(g - b) < 40 && abs(r - b) < 40
                if brightness > 0.80 && balanced {
                    // Normalised coords for mask checks
                    let nx = Double(px) / Double(w)
                    let ny = 1.0 - Double(py) / Double(h)

                    if let mask = excludingMask, mask.contains(CGPoint(x: nx, y: ny)) { continue }
                    if let roi = withinROI, !roi.contains(CGPoint(x: nx, y: ny)) { continue }

                    bright[py * w + px] = true
                }
            }
        }

        // Simple flood-fill to find connected components
        var visited = [Bool](repeating: false, count: w * h)
        var blobs: [BlobResult] = []

        for startY in 0..<h {
            for startX in 0..<w {
                let idx = startY * w + startX
                guard bright[idx], !visited[idx] else { continue }

                // BFS
                var queue = [(startX, startY)]
                var pixels: [(Int, Int)] = []
                visited[idx] = true

                var qi = 0
                while qi < queue.count {
                    let (cx, cy) = queue[qi]; qi += 1
                    pixels.append((cx, cy))

                    for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let nx2 = cx + dx, ny2 = cy + dy
                        guard nx2 >= 0, nx2 < w, ny2 >= 0, ny2 < h else { continue }
                        let ni = ny2 * w + nx2
                        guard bright[ni], !visited[ni] else { continue }
                        visited[ni] = true
                        queue.append((nx2, ny2))
                    }
                }

                // Filter: golf ball should be small but not a single pixel
                guard pixels.count >= 3, pixels.count <= 2000 else { continue }

                let sumX = pixels.reduce(0.0) { $0 + Double($1.0) }
                let sumY = pixels.reduce(0.0) { $0 + Double($1.1) }
                let cx = sumX / Double(pixels.count)
                let cy = sumY / Double(pixels.count)

                let normX = cx / Double(w)
                let normY = 1.0 - cy / Double(h)
                let confidence = min(1.0, Double(pixels.count) / 80.0)

                blobs.append(BlobResult(
                    centroid: CGPoint(x: normX, y: normY),
                    size: pixels.count,
                    confidence: confidence
                ))
            }
        }

        // Sort: prefer compact mid-size blobs (most ball-like)
        return blobs.sorted { abs($0.size - 40) < abs($1.size - 40) }
    }

    // MARK: - Body mask

    private func buildBodyMask(from poseFrames: [PoseFrame]) -> CGRect? {
        var allX: [Float] = []
        var allY: [Float] = []

        for frame in poseFrames {
            for lm in frame.landmarks where lm.confidence > 0.3 {
                allX.append(lm.x)
                allY.append(lm.y)
            }
        }

        guard !allX.isEmpty else { return nil }

        let pad: Float = 0.08
        let minX = max(0, (allX.min() ?? 0) - pad)
        let maxX = min(1, (allX.max() ?? 1) + pad)
        let minY = max(0, (allY.min() ?? 0) - pad)
        let maxY = min(1, (allY.max() ?? 1) + pad)

        return CGRect(x: Double(minX), y: Double(minY),
                      width: Double(maxX - minX), height: Double(maxY - minY))
    }

    // MARK: - Helpers

    private func scaleImage(_ image: CIImage) -> CIImage? {
        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = image
        scaleFilter.scale = workingScale
        scaleFilter.aspectRatio = 1.0
        return scaleFilter.outputImage
    }

    private func mostConsistentPosition(_ sets: [[CGPoint]], maxSpread: Double) -> CGPoint? {
        guard !sets.isEmpty else { return nil }
        // For each candidate in the first set, check how many other sets have a point nearby
        guard let first = sets.first else { return nil }

        var bestScore = 0
        var bestPos = CGPoint.zero

        for candidate in first {
            var score = 0
            var sumX = candidate.x
            var sumY = candidate.y

            for otherSet in sets.dropFirst() {
                if let nearby = otherSet.first(where: {
                    hypot($0.x - candidate.x, $0.y - candidate.y) < maxSpread
                }) {
                    score += 1
                    sumX += nearby.x
                    sumY += nearby.y
                }
            }

            if score > bestScore {
                bestScore = score
                bestPos = CGPoint(x: sumX / Double(score + 1), y: sumY / Double(score + 1))
            }
        }

        return bestScore >= 1 ? bestPos : nil
    }

    private func smooth(_ points: [BallTrackPoint]) -> [BallTrackPoint] {
        guard points.count > 2 else { return points }
        return points.enumerated().map { i, curr in
            let prev = points[max(0, i - 1)]
            let next = points[min(points.count - 1, i + 1)]
            return BallTrackPoint(
                frameIndex: curr.frameIndex,
                timestamp: curr.timestamp,
                x: prev.x * 0.2 + curr.x * 0.6 + next.x * 0.2,
                y: prev.y * 0.2 + curr.y * 0.6 + next.y * 0.2,
                confidence: curr.confidence
            )
        }
    }

    private func filterPhysicallyPlausible(_ points: [BallTrackPoint]) -> [BallTrackPoint] {
        guard points.count > 1 else { return points }
        var filtered: [BallTrackPoint] = [points[0]]
        for i in 1..<points.count {
            let prev = filtered.last!
            let curr = points[i]
            let dist = hypot(Double(curr.x - prev.x), Double(curr.y - prev.y))
            // Reject if ball teleports more than 30% of frame width between samples
            if dist < 0.30 {
                filtered.append(curr)
            }
        }
        return filtered
    }
}
