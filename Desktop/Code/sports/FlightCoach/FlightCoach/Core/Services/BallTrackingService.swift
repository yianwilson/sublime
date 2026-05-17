import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Debug types (accessible to AnalysisResultScreen etc.)

struct BallCandidate {
    let centroid: CGPoint   // normalised [0,1]
    let size: Int           // pixel count at working resolution
    let brightness: Double  // 0–1, mean channel intensity
    let circularity: Double // 4πA/P², 1.0 = perfect circle
    let score: Double       // composite quality score
}

struct BallTrackDebugFrame {
    let frameIndex: Int
    let candidates: [BallCandidate]
    let selectedCentroid: CGPoint?
    let rejections: [(centroid: CGPoint, reason: String)]
    let confidence: Double
}

// MARK: -

final class BallTrackingService {
    static let shared = BallTrackingService()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Working resolution — 25 % of source; golf ball is still detectable at this scale
    private let workingScale: Float = 0.25

    // Limb exclusion capsule radius in normalised frame units
    private let limbRadius: Double = 0.055

    // Address ball protection zone — never mask this close to the known ball position
    private let addressProtectRadius: Double = 0.08

    private(set) var debugLog: [BallTrackDebugFrame] = []

    private init() {}

    // MARK: - Public API

    func trackBall(
        in frames: [VideoFrame],
        poseFrames: [PoseFrame],
        contactFrameHint: Int?,
        onProgress: ((Double) -> Void)? = nil
    ) async -> [BallTrackPoint] {
        debugLog.removeAll()
        guard frames.count > 3 else { return [] }

        let impactIdx = contactFrameHint ?? frames[frames.count / 2].index

        // Pre-impact frames: use a window ending just before impact
        let preFrames = frames.filter { $0.index < impactIdx }
        let setupFrames: [VideoFrame] = {
            let pool = preFrames.isEmpty ? Array(frames.prefix(frames.count / 3)) : preFrames
            return Array(pool.suffix(min(pool.count, max(6, frames.count / 5))))
        }()

        onProgress?(0.05)
        let staticBallPos = findStaticBall(in: setupFrames, poseFrames: poseFrames)

        onProgress?(0.2)
        var trackPoints: [BallTrackPoint] = []

        if let startPos = staticBallPos {
            // Anchor the last few pre-impact frames at the address position
            for f in setupFrames.suffix(3) {
                trackPoints.append(BallTrackPoint(
                    frameIndex: f.index,
                    timestamp: f.timestamp,
                    x: Float(startPos.x),
                    y: Float(startPos.y),
                    confidence: 0.7
                ))
            }

            let postFrames = frames.filter { $0.index >= impactIdx }
            let postTrack = await trackPostImpact(
                frames: postFrames,
                startNorm: startPos,
                poseFrames: poseFrames,
                addressBall: startPos,
                onProgress: { p in onProgress?(0.2 + p * 0.75) }
            )
            trackPoints.append(contentsOf: postTrack)
        } else {
            let fallback = await maskedFrameDifference(
                frames: frames,
                poseFrames: poseFrames,
                onProgress: { p in onProgress?(p) }
            )
            trackPoints = fallback
        }

        onProgress?(1.0)
        return filterPhysicallyPlausible(smooth(trackPoints))
    }

    // MARK: - Phase 1: Find stationary ball at address

    private func findStaticBall(in frames: [VideoFrame], poseFrames: [PoseFrame]) -> CGPoint? {
        var candidateSets: [[CGPoint]] = []

        for frame in frames {
            guard let scaled = scaleImage(frame.image),
                  let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { continue }

            let pose = closestPoseFrame(to: frame.index, in: poseFrames)
            let mask = buildLimbMask(nearestPose: pose, width: cg.width, height: cg.height, addressBall: nil)
            let candidates = findCandidates(in: cg, limbMask: mask, withinROI: nil)

            if !candidates.isEmpty {
                candidateSets.append(candidates.map(\.centroid))
            }
        }

        guard candidateSets.count >= 2 else { return nil }
        return mostConsistentPosition(candidateSets, maxSpread: 0.04)
    }

    // MARK: - Phase 2: ROI-based post-impact tracking

    private func trackPostImpact(
        frames: [VideoFrame],
        startNorm: CGPoint,
        poseFrames: [PoseFrame],
        addressBall: CGPoint,
        onProgress: ((Double) -> Void)?
    ) async -> [BallTrackPoint] {
        var results: [BallTrackPoint] = []
        var currentPos = startNorm
        var velocity = CGPoint(x: 0, y: -0.015)
        var lostCount = 0
        let maxLost = 5

        for (idx, frame) in frames.enumerated() {
            guard let scaled = scaleImage(frame.image),
                  let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { continue }

            // Search window grows as ball accelerates away from address
            let searchRadius = min(0.32, 0.06 + Double(idx) * 0.010)
            let predicted = CGPoint(x: currentPos.x + velocity.x, y: currentPos.y + velocity.y)
            let roi = CGRect(
                x: predicted.x - searchRadius,
                y: predicted.y - searchRadius,
                width: searchRadius * 2,
                height: searchRadius * 2
            )

            let pose = closestPoseFrame(to: frame.index, in: poseFrames)
            let limbMask = buildLimbMask(nearestPose: pose, width: cg.width, height: cg.height, addressBall: addressBall)
            let raw = findCandidates(in: cg, limbMask: limbMask, withinROI: roi)
            let scored = scoreCandidates(raw, predicted: predicted, searchRadius: searchRadius, lastVelocity: velocity, lastPos: currentPos)

            var rejections: [(CGPoint, String)] = []
            var selected: BallCandidate? = nil

            for c in scored {
                // Direction reversal check — ball shouldn't double-back
                if idx > 0 {
                    let velMag = hypot(velocity.x, velocity.y)
                    if velMag > 0.003 {
                        let dv = CGPoint(x: c.centroid.x - currentPos.x, y: c.centroid.y - currentPos.y)
                        let dot = velocity.x * dv.x + velocity.y * dv.y
                        if dot < -0.001 {
                            rejections.append((c.centroid, "velocity reversal"))
                            continue
                        }
                    }
                }
                selected = c
                break
            }

            // Log unselected candidates as rejected (outside ROI already filtered by findCandidates)
            let selectedCentroid = selected?.centroid
            for c in scored where c.centroid != selectedCentroid {
                if !rejections.contains(where: { $0.0 == c.centroid }) {
                    rejections.append((c.centroid, "lower score"))
                }
            }

            debugLog.append(BallTrackDebugFrame(
                frameIndex: frame.index,
                candidates: scored,
                selectedCentroid: selectedCentroid,
                rejections: rejections,
                confidence: selected.map { Double($0.score) } ?? 0
            ))

            if let best = selected {
                let newVel = CGPoint(x: best.centroid.x - currentPos.x, y: best.centroid.y - currentPos.y)
                velocity = CGPoint(
                    x: velocity.x * 0.35 + newVel.x * 0.65,
                    y: velocity.y * 0.35 + newVel.y * 0.65
                )
                currentPos = best.centroid
                lostCount = 0
                results.append(BallTrackPoint(
                    frameIndex: frame.index,
                    timestamp: frame.timestamp,
                    x: Float(best.centroid.x),
                    y: Float(best.centroid.y),
                    confidence: Float(min(0.92, best.score))
                ))
            } else {
                lostCount += 1
                currentPos = predicted
                if lostCount > maxLost { break }
            }

            if idx % 5 == 0 { await Task.yield() }
            onProgress?(Double(idx + 1) / Double(frames.count))
        }

        return results
    }

    // MARK: - Fallback: body-masked diff with direct connected-component tracking

    private func maskedFrameDifference(
        frames: [VideoFrame],
        poseFrames: [PoseFrame],
        onProgress: ((Double) -> Void)?
    ) async -> [BallTrackPoint] {
        var results: [BallTrackPoint] = []
        var prevScaled: CIImage? = nil

        for (idx, frame) in frames.enumerated() {
            guard let currentScaled = scaleImage(frame.image) else {
                prevScaled = nil
                continue
            }
            defer { prevScaled = currentScaled }
            guard let prev = prevScaled else { continue }

            let diff = CIFilter.colorAbsoluteDifference()
            diff.inputImage = currentScaled
            diff.inputImage2 = prev
            guard let diffImg = diff.outputImage else { continue }

            let thresh = CIFilter.colorThreshold()
            thresh.inputImage = diffImg
            thresh.threshold = 0.12
            guard let thresholded = thresh.outputImage else { continue }

            let extent = thresholded.extent
            guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { continue }
            guard let diffCG = ciContext.createCGImage(thresholded, from: extent) else { continue }

            let pose = closestPoseFrame(to: frame.index, in: poseFrames)
            let limbMask = buildLimbMask(nearestPose: pose, width: diffCG.width, height: diffCG.height, addressBall: nil)

            if let blob = largestComponentInDiff(cg: diffCG, limbMask: limbMask) {
                results.append(BallTrackPoint(
                    frameIndex: frame.index,
                    timestamp: frame.timestamp,
                    x: Float(blob.centroid.x),
                    y: Float(blob.centroid.y),
                    confidence: Float(min(0.45, blob.score))
                ))
                debugLog.append(BallTrackDebugFrame(
                    frameIndex: frame.index,
                    candidates: [blob],
                    selectedCentroid: blob.centroid,
                    rejections: [],
                    confidence: min(0.45, blob.score)
                ))
            }

            if idx % 8 == 0 { await Task.yield() }
            onProgress?(Double(idx + 1) / Double(frames.count))
        }

        return results
    }

    // MARK: - Candidate detection with circularity scoring

    private func findCandidates(
        in cg: CGImage,
        limbMask: [Bool],
        withinROI: CGRect?
    ) -> [BallCandidate] {
        let w = cg.width, h = cg.height
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return [] }
        let bpp = max(1, cg.bitsPerPixel / 8)
        let bpr = cg.bytesPerRow
        let dataLen = CFDataGetLength(data)

        // Build bright-pixel map: high luminance, colour-balanced (white)
        var bright = [Bool](repeating: false, count: w * h)

        for py in 0..<h {
            for px in 0..<w {
                guard !limbMask[py * w + px] else { continue }
                let offset = py * bpr + px * bpp
                guard offset + 2 < dataLen else { continue }

                let r = Double(ptr[offset])
                let g = Double(ptr[offset + 1])
                let b = Double(ptr[offset + 2])
                let lum = (r + g + b) / 765.0
                let balanced = abs(r - g) < 40 && abs(g - b) < 40 && abs(r - b) < 40

                if lum > 0.78 && balanced {
                    let nx = Double(px) / Double(w)
                    let ny = 1.0 - Double(py) / Double(h)
                    if let roi = withinROI, !roi.contains(CGPoint(x: nx, y: ny)) { continue }
                    bright[py * w + px] = true
                }
            }
        }

        // Flood-fill BFS to find connected components
        var visited = [Bool](repeating: false, count: w * h)
        var candidates: [BallCandidate] = []

        for startY in 0..<h {
            for startX in 0..<w {
                let startIdx = startY * w + startX
                guard bright[startIdx], !visited[startIdx] else { continue }

                var queue = [(startX, startY)]
                var pixels: [(Int, Int)] = []
                var brightSum = 0.0
                visited[startIdx] = true
                var qi = 0

                while qi < queue.count {
                    let (cx, cy) = queue[qi]; qi += 1
                    pixels.append((cx, cy))

                    let off = cy * bpr + cx * bpp
                    if off + 2 < dataLen {
                        let r = Double(ptr[off])
                        let g = Double(ptr[off + 1])
                        let b = Double(ptr[off + 2])
                        brightSum += (r + g + b) / 765.0
                    }

                    for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let nx2 = cx + dx, ny2 = cy + dy
                        guard nx2 >= 0, nx2 < w, ny2 >= 0, ny2 < h else { continue }
                        let ni = ny2 * w + nx2
                        guard bright[ni], !visited[ni] else { continue }
                        visited[ni] = true
                        queue.append((nx2, ny2))
                    }
                }

                guard pixels.count >= 3, pixels.count <= 2000 else { continue }

                // Centroid
                let sumX = pixels.reduce(0.0) { $0 + Double($1.0) }
                let sumY = pixels.reduce(0.0) { $0 + Double($1.1) }
                let cxF = sumX / Double(pixels.count)
                let cyF = sumY / Double(pixels.count)

                // Circularity: count boundary edges (pixels adjacent to non-blob or image border)
                var perimeter = 0
                for (px2, py2) in pixels {
                    for (ddx, ddy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let nx2 = px2 + ddx, ny2 = py2 + ddy
                        if nx2 < 0 || nx2 >= w || ny2 < 0 || ny2 >= h || !bright[ny2 * w + nx2] {
                            perimeter += 1
                        }
                    }
                }
                let area = Double(pixels.count)
                let circularity = perimeter > 0
                    ? min(1.0, (4 * Double.pi * area) / Double(perimeter * perimeter))
                    : 0

                let avgBrightness = brightSum / area
                let normX = cxF / Double(w)
                let normY = 1.0 - cyF / Double(h)

                // Base score: prefer ~40-pixel blobs, round, bright
                let sizeScore  = exp(-abs(area - 40) / 35)
                let baseScore  = sizeScore * (0.40 + 0.40 * circularity + 0.20 * avgBrightness)

                candidates.append(BallCandidate(
                    centroid: CGPoint(x: normX, y: normY),
                    size: pixels.count,
                    brightness: avgBrightness,
                    circularity: circularity,
                    score: baseScore
                ))
            }
        }

        return candidates.sorted { $0.score > $1.score }
    }

    // MARK: - Candidate scoring (adds distance-from-prediction + temporal continuity)

    private func scoreCandidates(
        _ candidates: [BallCandidate],
        predicted: CGPoint,
        searchRadius: Double,
        lastVelocity: CGPoint,
        lastPos: CGPoint
    ) -> [BallCandidate] {
        return candidates.map { c in
            let dist = hypot(c.centroid.x - predicted.x, c.centroid.y - predicted.y)
            let distScore = exp(-dist / max(0.01, searchRadius * 0.5))

            let velMag = hypot(lastVelocity.x, lastVelocity.y)
            var continuityScore = 1.0
            if velMag > 0.002 {
                let dx = c.centroid.x - lastPos.x
                let dy = c.centroid.y - lastPos.y
                let moveMag = hypot(dx, dy)
                if moveMag > 0.001 {
                    let cosAngle = (dx * lastVelocity.x + dy * lastVelocity.y) / (moveMag * velMag)
                    continuityScore = max(0, cosAngle * 0.5 + 0.5)
                }
            }

            let combined = c.score * 0.45 + distScore * 0.35 + continuityScore * 0.20
            return BallCandidate(
                centroid: c.centroid,
                size: c.size,
                brightness: c.brightness,
                circularity: c.circularity,
                score: combined
            )
        }.sorted { $0.score > $1.score }
    }

    // MARK: - Fallback: pick best connected component from diff directly

    private func largestComponentInDiff(cg: CGImage, limbMask: [Bool]) -> BallCandidate? {
        let w = cg.width, h = cg.height
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpp = max(1, cg.bitsPerPixel / 8)
        let bpr = cg.bytesPerRow
        let dataLen = CFDataGetLength(data)

        // Any pixel bright after threshold = motion pixel
        var active = [Bool](repeating: false, count: w * h)
        for py in 0..<h {
            for px in 0..<w {
                guard !limbMask[py * w + px] else { continue }
                let offset = py * bpr + px * bpp
                guard offset < dataLen else { continue }
                if ptr[offset] > 180 { active[py * w + px] = true }
            }
        }

        var visited = [Bool](repeating: false, count: w * h)
        var best: BallCandidate? = nil
        var bestScore = 0.0

        for startY in 0..<h {
            for startX in 0..<w {
                let startIdx = startY * w + startX
                guard active[startIdx], !visited[startIdx] else { continue }

                var queue = [(startX, startY)]
                var pixels: [(Int, Int)] = []
                visited[startIdx] = true
                var qi = 0

                while qi < queue.count {
                    let (cx, cy) = queue[qi]; qi += 1
                    pixels.append((cx, cy))
                    for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let nx2 = cx + dx, ny2 = cy + dy
                        guard nx2 >= 0, nx2 < w, ny2 >= 0, ny2 < h else { continue }
                        let ni = ny2 * w + nx2
                        guard active[ni], !visited[ni] else { continue }
                        visited[ni] = true
                        queue.append((nx2, ny2))
                    }
                }

                guard pixels.count >= 3, pixels.count <= 1500 else { continue }

                let sumX = pixels.reduce(0.0) { $0 + Double($1.0) }
                let sumY = pixels.reduce(0.0) { $0 + Double($1.1) }
                let cxF = sumX / Double(pixels.count)
                let cyF = sumY / Double(pixels.count)

                var perimeter = 0
                for (px2, py2) in pixels {
                    for (ddx, ddy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let nx2 = px2 + ddx, ny2 = py2 + ddy
                        if nx2 < 0 || nx2 >= w || ny2 < 0 || ny2 >= h || !active[ny2 * w + nx2] {
                            perimeter += 1
                        }
                    }
                }
                let area = Double(pixels.count)
                let circularity = perimeter > 0
                    ? min(1.0, (4 * Double.pi * area) / Double(perimeter * perimeter))
                    : 0
                let sizeScore = exp(-abs(area - 40) / 30)
                let score = sizeScore * (0.5 + 0.5 * circularity)

                if score > bestScore {
                    bestScore = score
                    best = BallCandidate(
                        centroid: CGPoint(x: cxF / Double(w), y: 1.0 - cyF / Double(h)),
                        size: pixels.count,
                        brightness: 0.8,
                        circularity: circularity,
                        score: score
                    )
                }
            }
        }

        return best
    }

    // MARK: - Limb-segment mask (avoids one big bounding box)

    private struct Segment {
        let p1: CGPoint
        let p2: CGPoint
    }

    private func buildLimbMask(
        nearestPose: PoseFrame?,
        width: Int,
        height: Int,
        addressBall: CGPoint?
    ) -> [Bool] {
        var mask = [Bool](repeating: false, count: width * height)
        guard let pose = nearestPose else { return mask }

        func lm(_ j: VNHumanBodyPoseObservation.JointName) -> PoseLandmark? {
            pose.landmark(named: j.rawValue.rawValue)
        }

        let jointPairs: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
            (.neck, .leftShoulder),   (.neck, .rightShoulder),
            (.leftShoulder, .leftElbow),  (.leftElbow, .leftWrist),
            (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
            (.leftShoulder, .leftHip),    (.rightShoulder, .rightHip),
            (.leftHip, .leftKnee),        (.leftKnee, .leftAnkle),
            (.rightHip, .rightKnee),      (.rightKnee, .rightAnkle),
            (.leftHip, .rightHip)
        ]

        var segments: [Segment] = []
        for (j1, j2) in jointPairs {
            guard let a = lm(j1), let b = lm(j2),
                  a.confidence > 0.3, b.confidence > 0.3 else { continue }
            segments.append(Segment(
                p1: CGPoint(x: Double(a.x), y: Double(a.y)),
                p2: CGPoint(x: Double(b.x), y: Double(b.y))
            ))
        }

        for seg in segments {
            // Bounding box for this limb segment with padding
            let pad = limbRadius * 1.5
            let minNX = min(seg.p1.x, seg.p2.x) - pad
            let maxNX = max(seg.p1.x, seg.p2.x) + pad
            let minNY = min(seg.p1.y, seg.p2.y) - pad
            let maxNY = max(seg.p1.y, seg.p2.y) + pad

            // Image pixel coords: y is flipped (ny=0 is bottom, py=0 is top)
            let minPX = max(0, Int(minNX * Double(width)))
            let maxPX = min(width - 1, Int(maxNX * Double(width)))
            let minPY = max(0, Int((1.0 - maxNY) * Double(height)))
            let maxPY = min(height - 1, Int((1.0 - minNY) * Double(height)))
            guard minPX <= maxPX, minPY <= maxPY else { continue }

            for py in minPY...maxPY {
                for px in minPX...maxPX {
                    let nx = Double(px) / Double(width)
                    let ny = 1.0 - Double(py) / Double(height)

                    // Never mask the address ball area
                    if let ab = addressBall,
                       hypot(nx - ab.x, ny - ab.y) < addressProtectRadius { continue }

                    if distToSegment(CGPoint(x: nx, y: ny), seg: seg) < limbRadius {
                        mask[py * width + px] = true
                    }
                }
            }
        }

        return mask
    }

    private func distToSegment(_ point: CGPoint, seg: Segment) -> Double {
        let dx = seg.p2.x - seg.p1.x
        let dy = seg.p2.y - seg.p1.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-12 else {
            return hypot(point.x - seg.p1.x, point.y - seg.p1.y)
        }
        let t = max(0, min(1, ((point.x - seg.p1.x) * dx + (point.y - seg.p1.y) * dy) / lenSq))
        return hypot(point.x - (seg.p1.x + t * dx), point.y - (seg.p1.y + t * dy))
    }

    // MARK: - Helpers

    private func closestPoseFrame(to frameIndex: Int, in poseFrames: [PoseFrame]) -> PoseFrame? {
        poseFrames.min(by: { abs($0.frameIndex - frameIndex) < abs($1.frameIndex - frameIndex) })
    }

    private func scaleImage(_ image: CIImage) -> CIImage? {
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image
        f.scale = workingScale
        f.aspectRatio = 1.0
        return f.outputImage
    }

    private func mostConsistentPosition(_ sets: [[CGPoint]], maxSpread: Double) -> CGPoint? {
        guard let first = sets.first else { return nil }
        var bestScore = 0
        var bestPos = CGPoint.zero

        for candidate in first {
            var score = 0
            var sumX = candidate.x
            var sumY = candidate.y

            for other in sets.dropFirst() {
                if let nearby = other.first(where: {
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
            if dist < 0.30 { filtered.append(curr) }
        }
        return filtered
    }
}
