import Foundation
import CoreGraphics

/// Produces per-frame ball CANDIDATES inside a pixel ROI (spec §10). It never selects the
/// ball — it only lists possibilities. All returned positions/boxes are FULL-FRAME,
/// orientation-corrected pixels (crop-local coords are converted via the ROI origin).
///
/// Detection sources: bright compact blob, frame-difference motion blob. Candidates are
/// scored (visual/motion/brightness/streak) but NOT thresholded into a single winner.
enum TracerCandidateDetector {

    /// Detect candidates in `frame` within `roiFullFrame` (full-frame pixels). `previous`
    /// is the prior frame for motion differencing (optional).
    static func detect(in frame: TracerFrameInfo,
                       previous: TracerFrameInfo?,
                       roiFullFrame: CGRect,
                       config: GolfTracerConfig) -> [TracerCandidate] {
        let roi = roiFullFrame.intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        guard roi.width >= 2, roi.height >= 2,
              let cur = Bitmap(cgImage: frame.image, crop: roi) else { return [] }

        var candidates: [TracerCandidate] = []
        candidates.append(contentsOf: contrastCandidates(cur, frame: frame, roi: roi))

        if let previous, let prev = Bitmap(cgImage: previous.image, crop: roi),
           prev.width == cur.width, prev.height == cur.height {
            candidates.append(contentsOf: motionCandidates(cur, prev, frame: frame, roi: roi))
        } else {
            // No motion reference (single-frame query, e.g. address inspection):
            // fall back to sharpness blobs so a stationary ball is still findable.
            candidates.append(contentsOf: staticBallCandidates(cur, frame: frame, roi: roi))
        }

        // The ball is the thing that MOVES. Motion blobs get priority slots — even a
        // faint mover (low diff after downscaling) outranks bright static texture,
        // which otherwise fills every slot and starves the launch selector.
        func rank(_ c: TracerCandidate) -> Double { c.motionScore + c.brightnessScore + 0.3 * c.visualScore }
        let movers = candidates
            .filter { $0.source == .frameDifference && $0.motionScore >= 0.04 }
            .sorted { rank($0) > rank($1) }
        let statics = candidates
            .filter { $0.source != .frameDifference && ($0.motionScore + $0.brightnessScore) >= 0.12 }
            .sorted { rank($0) > rank($1) }
        return Array((movers + statics).prefix(config.maxCandidatesPerFrame))
    }

    // MARK: - Static ball detection (address, stalls)
    //
    // For stationary balls, a motion detector won't fire. Instead, look for compact,
    // round, high-local-contrast blobs using Laplacian-like sharpness. A golf ball
    // is a tight, sharp intensity peak (bright or dark) relative to its local region.
    private static func staticBallCandidates(_ bmp: Bitmap, frame: TracerFrameInfo, roi: CGRect) -> [TracerCandidate] {
        let w = bmp.width, h = bmp.height
        guard w > 8, h > 8 else { return [] }

        var bright = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = bmp.rgb(x, y)
                bright[y * w + x] = (Float(r) + Float(g) + Float(b)) / 765.0
            }
        }

        // Sharpness detection: compare each pixel to its neighborhood (Laplacian-like).
        // A sharp blob has high |pixel - neighborhood_mean|.
        var sharpness = [Float](repeating: 0, count: w * h)
        let radius = 4
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0, count = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        guard dx != 0 || dy != 0 else { continue }
                        let ny = y + dy, nx = x + dx
                        guard ny >= 0, ny < h, nx >= 0, nx < w else { continue }
                        sum += bright[ny * w + nx]
                        count += 1
                    }
                }
                let neighborMean = count > 0 ? sum / Float(count) : 0
                let center = bright[y * w + x]
                sharpness[y * w + x] = abs(center - neighborMean)
            }
        }

        // Find connected components of high-sharpness pixels (potential ball centers).
        var mask = [Bool](repeating: false, count: w * h)
        let sharpThreshold: Float = 0.08
        for i in 0..<(w * h) { mask[i] = sharpness[i] > sharpThreshold }

        return blobs(mask: mask, value: sharpness, bmp: bmp, frame: frame, roi: roi, motion: 0, source: .brightBlob)
    }

    // MARK: - Local-contrast blobs
    //
    // A golf ball is bright on grass but DARK against a bright sky — absolute brightness
    // can't find both. Instead, mark pixels that deviate from their LOCAL background
    // (coarse per-cell mean, which also absorbs the sky gradient). Uniform sky deviates
    // ~0 → no candidates; the ball (dark dot on sky / bright dot on grass) stands out.
    private static func contrastCandidates(_ bmp: Bitmap, frame: TracerFrameInfo, roi: CGRect) -> [TracerCandidate] {
        let w = bmp.width, h = bmp.height
        guard w > 4, h > 4 else { return [] }

        var bright = [Float](repeating: 0, count: w * h)
        var maxBright: Float = 0, minBright: Float = 1
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = bmp.rgb(x, y)
                let luminance = (Float(r) + Float(g) + Float(b)) / 765.0
                bright[y * w + x] = luminance
                maxBright = max(maxBright, luminance)
                minBright = min(minBright, luminance)
            }
        }

        // Coarse local-background mean per cell (absorbs gradients like sky).
        let cell = max(10, max(w, h) / 12)
        let gw = (w + cell - 1) / cell, gh = (h + cell - 1) / cell
        var cellSum = [Float](repeating: 0, count: gw * gh)
        var cellCnt = [Int](repeating: 0, count: gw * gh)
        for y in 0..<h {
            for x in 0..<w {
                let gi = (y / cell) * gw + (x / cell)
                cellSum[gi] += bright[y * w + x]; cellCnt[gi] += 1
            }
        }
        var cellMean = [Float](repeating: 0, count: gw * gh)
        for i in 0..<(gw * gh) where cellCnt[i] > 0 { cellMean[i] = cellSum[i] / Float(cellCnt[i]) }

        // Adaptive threshold: if scene is low-contrast (sky dominated), use a lower threshold.
        let range = maxBright - minBright
        let contrastThreshold: Float = range > 0.4 ? 0.12 : 0.08  // lower threshold in low-contrast scenes

        var mask = [Bool](repeating: false, count: w * h)
        var value = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dev = bright[y * w + x] - cellMean[(y / cell) * gw + (x / cell)]
                if abs(dev) > contrastThreshold {
                    mask[y * w + x] = true
                    value[y * w + x] = min(1, abs(dev) * 4)  // increase sensitivity
                }
            }
        }
        return blobs(mask: mask, value: value, bmp: bmp, frame: frame, roi: roi, motion: 0, source: .brightBlob)
    }

    // MARK: - Motion blobs

    private static func motionCandidates(_ cur: Bitmap, _ prev: Bitmap, frame: TracerFrameInfo, roi: CGRect) -> [TracerCandidate] {
        // Estimate per-pixel motion noise floor from the full frame difference distribution
        var diffs: [Int] = []
        diffs.reserveCapacity(cur.width * cur.height)
        for y in 0..<cur.height {
            for x in 0..<cur.width {
                let (r, g, b) = cur.rgb(x, y)
                let (pr, pg, pb) = prev.rgb(x, y)
                let diff = abs(Int(r) - Int(pr)) + abs(Int(g) - Int(pg)) + abs(Int(b) - Int(pb))
                diffs.append(diff)
            }
        }
        diffs.sort()
        let p75 = diffs[Int(Double(diffs.count) * 0.75)]
        // Floor of 18 (summed RGB): a small receding ball downscaled to ~1280px
        // long-edge produces frame diffs of only ~20-60; the old floor of 40
        // erased it entirely and the launch window saw pure static noise.
        let motionThreshold = max(18, min(80, p75 + 25))

        var mask = [Bool](repeating: false, count: cur.width * cur.height)
        var value = [Float](repeating: 0, count: cur.width * cur.height)
        for y in 0..<cur.height {
            for x in 0..<cur.width {
                let (r, g, b) = cur.rgb(x, y)
                let (pr, pg, pb) = prev.rgb(x, y)
                let diff = abs(Int(r) - Int(pr)) + abs(Int(g) - Int(pg)) + abs(Int(b) - Int(pb))
                if diff > motionThreshold {
                    let i = y * cur.width + x
                    mask[i] = true
                    value[i] = min(1, Float(diff) / 255.0)
                }
            }
        }
        return blobs(mask: mask, value: value, bmp: cur, frame: frame, roi: roi, motion: 1, source: .frameDifference)
    }

    // MARK: - Connected components → candidates

    private static func blobs(mask: [Bool], value: [Float], bmp: Bitmap,
                              frame: TracerFrameInfo, roi: CGRect,
                              motion: Float, source: TracerCandidateSource) -> [TracerCandidate] {
        let w = bmp.width, h = bmp.height
        var visited = [Bool](repeating: false, count: w * h)
        var out: [TracerCandidate] = []

        for sy in 0..<h {
            for sx in 0..<w {
                let s = sy * w + sx
                guard mask[s], !visited[s] else { continue }
                var queue = [(sx, sy)]; visited[s] = true
                var pixels: [(Int, Int)] = []; var sum: Float = 0; var cursor = 0
                while cursor < queue.count {
                    let (x, y) = queue[cursor]; cursor += 1
                    pixels.append((x, y)); sum += value[y * w + x]
                    for (nx, ny) in [(x-1, y), (x+1, y), (x, y-1), (x, y+1)] {
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let n = ny * w + nx
                        if mask[n], !visited[n] { visited[n] = true; queue.append((nx, ny)) }
                    }
                }
                guard pixels.count >= 2, pixels.count <= 2000 else { continue }

                let xs = pixels.map(\.0), ys = pixels.map(\.1)
                let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
                let cxLocal = Double(xs.reduce(0, +)) / Double(pixels.count)
                let cyLocal = Double(ys.reduce(0, +)) / Double(pixels.count)

                let bw = maxX - minX + 1, bh = maxY - minY + 1
                let minDim = min(bw, bh)

                // Filter obviously wrong sizes: too tiny (noise) or way too big (artifacts)
                guard minDim >= 2 else { continue }
                guard minDim <= 200 else { continue }

                let aspect = Float(min(bw, bh)) / Float(max(bw, bh))
                let fill = Float(pixels.count) / Float(bw * bh)
                let fillErr = min(1, abs(fill - 0.785) / 0.5)
                let roundness = max(0, min(1, aspect * 0.6 + (1 - fillErr) * 0.4))
                let streak = aspect < 0.45 ? Float(1 - aspect) : 0   // elongated → streak-like
                let avg = sum / Float(pixels.count)

                // crop-local → full-frame
                let full = TracerGeometry.cropLocalToFullFrame(CGPoint(x: cxLocal, y: cyLocal), roi: roi)
                let box = TracerGeometry.cropLocalRectToFullFrame(
                    CGRect(x: Double(minX), y: Double(minY), width: Double(bw), height: Double(bh)), roi: roi)

                out.append(TracerCandidate(
                    frameIndex: frame.index,
                    position: full,
                    radius: CGFloat(max(bw, bh)) / 2,
                    boundingBox: box,
                    visualScore: Double(roundness),
                    motionScore: Double(motion * avg),
                    brightnessScore: source == .brightBlob ? Double(avg) : 0,
                    streakScore: Double(streak),
                    source: source
                ))
            }
        }
        return out
    }
}

/// Minimal RGBA8 reader for a cropped region of a CGImage.
private struct Bitmap {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init?(cgImage: CGImage, crop: CGRect) {
        let x = max(0, Int(crop.origin.x)), y = max(0, Int(crop.origin.y))
        let w = min(Int(crop.width), cgImage.width - x)
        let h = min(Int(crop.height), cgImage.height - y)
        guard w > 0, h > 0, let cropped = cgImage.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return nil }

        let bytesPerRow = w * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.width = w; self.height = h; self.data = buffer
    }

    /// Pixel access with TOP-LEFT origin (CGContext draws bottom-up, so flip y).
    func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let flippedY = height - 1 - y
        let i = (flippedY * width + x) * 4
        return (data[i], data[i + 1], data[i + 2])
    }
}
