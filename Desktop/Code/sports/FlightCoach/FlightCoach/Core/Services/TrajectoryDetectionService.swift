import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// Detects the launched ball's flight using Apple's built-in small-object
/// trajectory detector (`VNDetectTrajectoriesRequest`).
///
/// Clock discipline: VN observation times and the impact anchor MUST share a
/// timeline, but extractor PTS and VN times can disagree by over a second on
/// edit-listed iPhone MOVs. So the impact anchor (address-ball disappearance)
/// is measured inside the SAME buffer-read loop that feeds VN — one loop, one
/// clock, by construction.
///
/// Orientation: sample buffers are raw (un-rotated) while the address point is
/// display-space. Rather than trusting a rotation-mapping table, the four
/// rotation candidates of the address point are all probed; the ball is
/// wherever the white-pixel signal actually is.
final class TrajectoryDetectionService {
    static let shared = TrajectoryDetectionService()

    struct Trajectory {
        let uuid: UUID
        let start: TimeInterval
        let end: TimeInterval
        let confidence: Float
        /// Normalised, Vision space (origin bottom-left, y-up) with timestamps.
        let points: [(time: TimeInterval, point: CGPoint)]
    }

    struct DetectionResult {
        /// Trajectories in RAW buffer space (un-rotated).
        let trajectories: [Trajectory]
        /// Address-ball disappearance time in the SAME clock as trajectory
        /// times. nil when no clean ball signal exists at the address.
        let impactTime: TimeInterval?
        /// Which rotation candidate of the display-space address held the ball
        /// signal — defines the raw↔display mapping. nil when no signal.
        let orientationIndex: Int?
    }

    /// Single-seed convenience (tests, manual-seed path).
    func ballFlight(url: URL,
                    addressNormalized: CGPoint,
                    frameRate: Double,
                    impactTime: TimeInterval?) async -> [BallTrackPoint]? {
        let seed = DisappearanceSeed(address: addressNormalized,
                                     impactTime: impactTime ?? -1, runLength: 0, peak: 0)
        return await ballFlight(url: url, seeds: [seed], frameRate: frameRate)?.points
    }

    /// Cross-validates candidate seeds against detected launches: a real
    /// address ball's disappearance coincides with a trajectory rising from
    /// it. Detection runs ONCE; seeds are tried in the caller's ranking
    /// order, and the first with a plausible flight wins. Seed impact times
    /// are extractor-clock PTS — the same clock the trajectories are
    /// re-stamped into.
    func ballFlight(url: URL,
                    seeds: [DisappearanceSeed],
                    frameRate: Double) async -> (points: [BallTrackPoint], seed: DisappearanceSeed)? {
        guard let probeAddress = seeds.first?.address else { return nil }
        let result = await Task.detached(priority: .userInitiated) {
            Self.runDetection(url: url, address: probeAddress)
        }.value
        guard !result.trajectories.isEmpty else { return nil }

        // VN reports trajectories in raw buffer space; the winning probe index
        // is direct evidence of how display space maps onto the buffer.
        // (Verified on IMG_4935: rotation −90 MOV, ball found at index 3.)
        let toDisplay: (CGPoint) -> CGPoint
        switch result.orientationIndex {
        case 1: toDisplay = { CGPoint(x: 1 - $0.x, y: 1 - $0.y) }
        case 2: toDisplay = { CGPoint(x: 1 - $0.y, y: $0.x) }
        case 3: toDisplay = { CGPoint(x: $0.y, y: 1 - $0.x) }
        default: toDisplay = { $0 }
        }
        let all = result.trajectories.map { t in
            Trajectory(uuid: t.uuid, start: t.start, end: t.end, confidence: t.confidence,
                       points: t.points.map { (time: $0.time, point: toDisplay($0.point)) })
        }

        // Evaluate EVERY seed; among those with a plausible flight, the ball
        // is the one departing LATEST — practice swings and club glints fake
        // earlier "impacts", and post-shot artefacts (tee retrieval) can't
        // validate because their window falls past the end of the clip.
        var validated: [(seed: DisappearanceSeed, flight: Trajectory)] = []
        for seed in seeds {
            if let best = select(from: all, seed: seed, frameRate: frameRate) {
                validated.append((seed, best))
            }
        }
        guard let pick = validated.max(by: { $0.seed.impactTime < $1.seed.impactTime }) else {
            #if DEBUG
            print("TrajectoryDetection: no flight for any of \(seeds.count) seeds (\(all.count) trajectories)")
            #endif
            return nil
        }
        let best = pick.flight
        #if DEBUG
        let f = best.points.first!.point, l = best.points.last!.point
        print(String(format: "TrajectoryDetection: ball flight t=%.2f–%.2fs conf=%.2f (%.3f,%.3f)→(%.3f,%.3f) seed (%.3f,%.3f)@%.2fs [%d validated of %d seeds, %d trajectories]",
                     best.start, best.end, best.confidence, f.x, f.y, l.x, l.y,
                     pick.seed.address.x, pick.seed.address.y, pick.seed.impactTime,
                     validated.count, seeds.count, all.count))
        #endif
        // Trajectory times are when VN REPORTED each point — ~1.4s after the
        // producing frame. Drawn as-is, the trail renders during the
        // follow-through and reads as tracking the club/hands. The ball
        // physically leaves at the seed's impact (+ the few frames VN needs
        // to lock on), so shift the whole flight back to that moment.
        let lockOn = 6.0 / frameRate
        let offset = pick.seed.impactTime >= 0
            ? best.points.first!.time - (pick.seed.impactTime + lockOn)
            : 0
        let points = best.points.map { tp in
            BallTrackPoint(frameIndex: Int(((tp.time - offset) * frameRate).rounded()),
                           timestamp: tp.time - offset,
                           x: Float(tp.point.x), y: Float(tp.point.y),
                           confidence: best.confidence)
        }
        return (points, pick.seed)
    }

    private func select(from all: [Trajectory], seed: DisappearanceSeed, frameRate: Double) -> Trajectory? {
        let address = seed.address
        let candidates = all.filter { t in
            guard let first = t.points.first, let last = t.points.last else { return false }
            let nearAddress = hypot(first.point.x - address.x,
                                    first.point.y - address.y) < 0.10
            // By the time VN locks on (+0.7s after impact minimum), the ball
            // has visibly risen — a flight starting at or below the tee is a
            // ground-level glint or edge artifact.
            let aboveTee = first.point.y > address.y + 0.03
            // A ball receding from a behind-ball camera rises substantially —
            // also relative to its horizontal drift (GT flights: ≥0.65× the
            // drift). Near-horizontal movers are club glints and birds.
            let rise = Double(last.point.y - first.point.y)
            let drift = abs(Double(last.point.x - first.point.x))
            let rises = rise > 0.03 && rise >= 0.55 * drift
            // A receding ball flies straight; reversals mean VN bridged the
            // club arc or shimmer into one trajectory.
            var pathLength: CGFloat = 0
            for (a, b) in zip(t.points, t.points.dropFirst()) {
                pathLength += hypot(b.point.x - a.point.x, b.point.y - a.point.y)
            }
            let net = hypot(last.point.x - first.point.x, last.point.y - first.point.y)
            let straight = pathLength < 0.001 || net / pathLength > 0.7
            // A real flight is detected on (nearly) consecutive frames; sparse
            // re-detections seconds apart are shimmer stitched together.
            let dts = zip(t.points, t.points.dropFirst()).map { $1.time - $0.time }
            let denseCount = dts.filter { $0 <= 3.5 / frameRate }.count
            let dense = !dts.isEmpty && Double(denseCount) / Double(dts.count) >= 0.6
            // A receding launched ball decelerates in image space immediately
            // (perspective + gravity); a walking golfer's cap/shoe and drifting
            // shimmer rise steadily. Compare early vs late rise RATE.
            let third = max(2, t.points.count / 3)
            let earlyRise = Double(t.points[third - 1].point.y - first.point.y)
            let lateRise = Double(last.point.y - t.points[t.points.count - third].point.y)
            let earlyDt = max(0.01, t.points[third - 1].time - first.time)
            let lateDt = max(0.01, last.time - t.points[t.points.count - third].time)
            let decelerates = earlyRise / earlyDt > 1.5 * max(0.0, lateRise / lateDt)
            // A receding ball's image-space rise rate is bounded (it moves
            // away); a walking golfer is CLOSE to the camera and sweeps the
            // frame much faster. Fastest GT flight: 0.35/s.
            let riseRate = Double(last.point.y - first.point.y) / max(0.05, last.time - first.time)
            let plausibleRate = riseRate <= 0.42
            // Trajectory times are buffer PTS (re-stamped), the same clock as
            // the seed's impact. VN reports a NEWLY appearing object (the
            // launched ball) ~1.4s after its first frame — consistently
            // +1.35…+1.6s on both GT fixtures. Trajectories starting AT the
            // seed's impact are the same motion event that caused the
            // occlusion (club glints, practice swings), not a launch.
            let inWindow = seed.impactTime < 0
                || (t.start > seed.impactTime + 1.1 && t.start < seed.impactTime + 1.8)
            return nearAddress && aboveTee && rises && straight && dense
                && decelerates && plausibleRate && inWindow
        }
        // The club crosses the address region BEFORE impact; the ball is the
        // LAST riser to depart it. Among near-simultaneous candidates (VN
        // duplicates of the same flight) the score decides.
        return candidates.sorted(by: { a, b in
            if abs(a.start - b.start) > 0.3 { return a.start < b.start }
            return score(a, impactTime: seed.impactTime >= 0 ? seed.impactTime : nil, address: address)
                < score(b, impactTime: seed.impactTime >= 0 ? seed.impactTime : nil, address: address)
        }).last
    }

    private func score(_ t: Trajectory, impactTime: TimeInterval?, address: CGPoint) -> Double {
        // Rise is capped: a receding ball rises modestly while birds/shimmer
        // can rise across half the frame — magnitude of rise is not evidence.
        let rise = min(Double((t.points.last?.point.y ?? 0) - (t.points.first?.point.y ?? 0)), 0.15)
        let proximity = impactTime.map { 2.0 / (1.0 + abs(t.start - $0)) } ?? 0.5
        // The real flight STARTS at the tee; VN's duplicate fragments of the
        // same flight start progressively further along it.
        let addressDistance = t.points.first.map {
            Double(hypot($0.point.x - address.x, $0.point.y - address.y))
        } ?? 1
        let addressCloseness = max(0, 0.10 - addressDistance) * 10
        return Double(t.points.count) * 0.2 + Double(t.confidence) + rise * 2 + proximity + addressCloseness
    }

    private static func runDetection(url: URL, address: CGPoint?) -> DetectionResult {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return DetectionResult(trajectories: [], impactTime: nil, orientationIndex: nil)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            return DetectionResult(trajectories: [], impactTime: nil, orientationIndex: nil)
        }

        var observed: [UUID: Trajectory] = [:]
        // VN's observation timeRange is NOT reliably the buffer PTS (off by
        // over a second on 60fps MOVs), so every update is re-stamped with the
        // PTS of the buffer that produced it. Callbacks run synchronously
        // inside perform(), so the box always holds the producing buffer's PTS.
        final class Clock { var pts: TimeInterval = 0 }
        let clock = Clock()
        let request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                                  trajectoryLength: 6) { req, _ in
            for obs in (req.results as? [VNTrajectoryObservation]) ?? [] {
                let pts = obs.detectedPoints.map { CGPoint(x: $0.x, y: $0.y) }
                guard let newest = pts.last else { continue }
                let now = clock.pts
                if let existing = observed[obs.uuid] {
                    // detectedPoints is a sliding tail; each update contributes
                    // one new point at the current buffer's time —
                    // accumulating them preserves the FULL flight path.
                    var points = existing.points
                    if points.last?.point != newest {
                        points.append((time: now, point: newest))
                    }
                    observed[obs.uuid] = Trajectory(
                        uuid: obs.uuid, start: existing.start, end: now,
                        confidence: max(existing.confidence, obs.confidence),
                        points: points)
                } else {
                    // First sighting: the tail spans the trajectory's lifetime
                    // so far; spread it back from the current buffer's time.
                    let span = max(0, obs.timeRange.duration.seconds)
                    let timed = pts.enumerated().map { i, p in
                        (time: now - span + (pts.count > 1 ? Double(i) / Double(pts.count - 1) : 1) * span,
                         point: p)
                    }
                    observed[obs.uuid] = Trajectory(
                        uuid: obs.uuid, start: now - span, end: now,
                        confidence: obs.confidence, points: timed)
                }
            }
        }
        request.objectMinimumNormalizedRadius = 0.001
        request.objectMaximumNormalizedRadius = 0.05

        // Address-ball presence probes: the display-space address under each
        // possible buffer rotation. The real one shows the ball's white-pixel
        // step signal; the others show turf.
        let probePoints: [CGPoint] = address.map { a in
            [CGPoint(x: a.x, y: a.y),
             CGPoint(x: 1 - a.x, y: 1 - a.y),
             CGPoint(x: a.y, y: 1 - a.x),
             CGPoint(x: 1 - a.y, y: a.x)]
        } ?? []
        var probeSeries = [[(time: TimeInterval, count: Int)]](repeating: [], count: probePoints.count)

        let handler = VNSequenceRequestHandler()
        var frameCounter = 0
        var probeWindowArea = 0
        let probeStride = max(1, Int((Double(track.nominalFrameRate) / 15.0).rounded()))
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            clock.pts = pts
            if !probePoints.isEmpty, frameCounter % probeStride == 0,
               let buffer = CMSampleBufferGetImageBuffer(sample) {
                if probeWindowArea == 0 {
                    let edge = max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
                    let r = max(8, Int(0.011 * Double(edge)))
                    probeWindowArea = 4 * r * r
                }
                for (i, p) in probePoints.enumerated() {
                    if let count = lumaWhiteOutlierCount(buffer: buffer, at: p) {
                        probeSeries[i].append((pts, count))
                    }
                }
            }
            frameCounter += 1
            try? handler.perform([request], on: sample)
        }

        let anchor = disappearanceTime(from: probeSeries, windowArea: probeWindowArea)
        // Probe found no ball signal → fall back to the track's rotation tag.
        // (270° ↔ index 3 verified on IMG_4935; 90° ↔ 2 by symmetry.)
        let transform = track.preferredTransform
        let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        let transformIndex: Int
        switch ((degrees % 360) + 360) % 360 {
        case 180: transformIndex = 1
        case 90: transformIndex = 2
        case 270: transformIndex = 3
        default: transformIndex = 0
        }
        #if DEBUG
        if let dumpDir = ProcessInfo.processInfo.environment["VN_DUMP_DIR"] {
            let rows = observed.values.map { t in
                ["start": t.start, "end": t.end, "conf": Double(t.confidence),
                 "points": t.points.map { [$0.time, $0.point.x, $0.point.y] }] as [String: Any]
            }
            let payload: [String: Any] = ["impact": anchor?.impact ?? -1,
                                          "orientation": anchor?.index ?? -1,
                                          "trajectories": rows]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                let name = url.deletingPathExtension().lastPathComponent
                try? data.write(to: URL(fileURLWithPath: "\(dumpDir)/vn_\(name).json"))
            }
        }
        #endif
        #if DEBUG
        print(String(format: "TrajectoryDetection: %d trajectories, in-loop impact %@ orientation %@ (probe peaks %@)",
                     observed.count,
                     anchor.map { String(format: "%.2fs", $0.impact) } ?? "nil",
                     anchor.map { "\($0.index)" } ?? "nil",
                     probeSeries.map { "\($0.map(\.count).max() ?? 0)" }.joined(separator: "/")))
        #endif
        return DetectionResult(trajectories: Array(observed.values),
                               impactTime: anchor?.impact,
                               orientationIndex: anchor?.index ?? transformIndex)
    }

    /// White-outlier pixel count (luma > window median + 0.2) in a tight window
    /// around a normalised y-up point, read from the buffer's luma plane.
    private static func lumaWhiteOutlierCount(buffer: CVPixelBuffer, at point: CGPoint) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let planar = CVPixelBufferIsPlanar(buffer)
        let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let bpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let r = max(8, Int(0.011 * Double(max(w, h))))
        let ro = r * 4
        let cx = Int(point.x * CGFloat(w - 1))
        let cy = Int((1 - point.y) * CGFloat(h - 1))
        let x0 = max(0, cx - ro), x1 = min(w, cx + ro)
        let y0 = max(0, cy - ro), y1 = min(h, cy + ro)
        guard x1 - x0 >= r, y1 - y0 >= r else { return nil }

        var histogram = [Int](repeating: 0, count: 256)
        for row in y0..<y1 {
            for col in x0..<x1 {
                histogram[Int(ptr[row * bpr + col])] += 1
            }
        }
        var cumulative = 0
        var median = 0
        let half = (x1 - x0) * (y1 - y0) / 2
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= half { median = value; break }
        }

        let cutoff = UInt8(min(255, median + 51))
        var count = 0
        for row in max(0, cy - r)..<min(h, cy + r) {
            for col in max(0, cx - r)..<min(w, cx + r) where ptr[row * bpr + col] > cutoff {
                count += 1
            }
        }
        return count
    }

    /// Impact = end of the LAST sustained presence run, taken from the
    /// strongest probe series that shows a real disappearance step. A series
    /// that stays bright forever (sky under a wrong rotation) has no step, and
    /// one where most of the window is "outlier" isn't a compact blob — both
    /// are skipped regardless of brightness.
    private static func disappearanceTime(
        from series: [[(time: TimeInterval, count: Int)]],
        windowArea: Int
    ) -> (impact: TimeInterval, index: Int)? {
        var best: (peak: Int, impact: TimeInterval, index: Int)?
        for (index, samples) in series.enumerated() {
            guard samples.count >= 8, let peak = samples.map(\.count).max(),
                  peak >= 8, windowArea > 0, peak <= windowArea / 2 else { continue }
            guard let impact = stepTime(samples: samples, peak: peak) else { continue }
            if best == nil || peak > best!.peak {
                best = (peak, impact, index)
            }
        }
        return best.map { ($0.impact, $0.index) }
    }

    /// The ball sits at address for seconds — the LONGEST presence run — then
    /// vanishes for good. "Last run" is wrong: the golfer retrieving the tee
    /// re-brightens the window near the end of the clip.
    private static func stepTime(samples: [(time: TimeInterval, count: Int)], peak: Int) -> TimeInterval? {
        let threshold = max(4, Int(Double(peak) * 0.35))
        let present = samples.map { $0.count >= threshold }
        var bestRun: (start: Int, end: Int)?
        var i = 0
        while i < present.count {
            if present[i] {
                var j = i
                while j + 1 < present.count && present[j + 1] { j += 1 }
                if j > i, j - i >= (bestRun.map { $0.end - $0.start } ?? -1) {
                    bestRun = (i, j)
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        guard let run = bestRun, run.end + 3 < samples.count,
              !present[run.end + 1], !present[run.end + 2], !present[run.end + 3] else { return nil }
        return (samples[run.end].time + samples[run.end + 1].time) / 2
    }
}
