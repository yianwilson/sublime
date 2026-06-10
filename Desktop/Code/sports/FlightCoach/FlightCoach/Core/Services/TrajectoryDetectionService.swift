import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// Detects the launched ball's flight using Apple's built-in small-object
/// trajectory detector (`VNDetectTrajectoriesRequest`).
///
/// Sample buffers are read straight from the asset and fed to the request, so
/// trajectory timestamps share the SAME AVFoundation timeline as
/// `VideoFrameExtractor` frames — immune to the iPhone-MOV edit-list offsets
/// that make ffmpeg/player/media clocks disagree.
///
/// The detector fires on every shimmering leaf, so candidates are filtered by
/// physics: must start near the address ball, must rise, and (when known)
/// must begin inside the impact window.
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

    /// Runs the trajectory detector over the whole clip. Heavy (full decode);
    /// call once per analysis.
    func detectTrajectories(url: URL) async -> [Trajectory] {
        await Task.detached(priority: .userInitiated) {
            Self.runDetection(url: url)
        }.value
    }

    /// The ball flight as normalised track points, or nil if no plausible
    /// trajectory survives the physics filters.
    func ballFlight(url: URL,
                    addressNormalized: CGPoint,
                    frameRate: Double,
                    impactTime: TimeInterval?) async -> [BallTrackPoint]? {
        let all = await detectTrajectories(url: url)
        guard !all.isEmpty else { return nil }

        // Vision space is y-up; addressNormalized is already in that space.
        let candidates = all.filter { t in
            guard let first = t.points.first, let last = t.points.last else { return false }
            let nearAddress = hypot(first.point.x - addressNormalized.x,
                                    first.point.y - addressNormalized.y) < 0.12
            let rises = last.point.y - first.point.y > 0.03
            let inWindow = impactTime.map { abs(t.start - $0) < 1.5 } ?? true
            return nearAddress && rises && inWindow
        }
        guard let best = candidates.max(by: {
            score($0, impactTime: impactTime) < score($1, impactTime: impactTime)
        }) else { return nil }

        #if DEBUG
        let f = best.points.first!.point, l = best.points.last!.point
        print(String(format: "TrajectoryDetection: ball flight t=%.2f–%.2fs conf=%.2f (%.3f,%.3f)→(%.3f,%.3f) of %d trajectories",
                     best.start, best.end, best.confidence, f.x, f.y, l.x, l.y, all.count))
        #endif

        return best.points.map { tp in
            BallTrackPoint(frameIndex: Int((tp.time * frameRate).rounded()),
                           timestamp: tp.time,
                           x: Float(tp.point.x), y: Float(tp.point.y),
                           confidence: best.confidence)
        }
    }

    private func score(_ t: Trajectory, impactTime: TimeInterval?) -> Double {
        // Rise is capped: a receding ball rises modestly while birds/shimmer
        // can rise across half the frame — magnitude of rise is not evidence.
        let rise = min(Double((t.points.last?.point.y ?? 0) - (t.points.first?.point.y ?? 0)), 0.15)
        let proximity = impactTime.map { 2.0 / (1.0 + abs(t.start - $0)) } ?? 0.5
        return Double(t.points.count) * 0.2 + Double(t.confidence) + rise * 2 + proximity
    }

    private static func runDetection(url: URL) -> [Trajectory] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return [] }

        var observed: [UUID: Trajectory] = [:]
        let request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                                  trajectoryLength: 6) { req, _ in
            for obs in (req.results as? [VNTrajectoryObservation]) ?? [] {
                let pts = obs.detectedPoints.map {
                    (time: obs.timeRange.start.seconds, point: CGPoint(x: $0.x, y: $0.y))
                }
                // Re-time points evenly across the observation's range; per-point
                // times aren't exposed, and this is accurate enough for frame mapping.
                var timed: [(TimeInterval, CGPoint)] = []
                let span = obs.timeRange.duration.seconds
                for (i, p) in pts.enumerated() {
                    let f = pts.count > 1 ? Double(i) / Double(pts.count - 1) : 0
                    timed.append((obs.timeRange.start.seconds + f * span, p.point))
                }
                observed[obs.uuid] = Trajectory(
                    uuid: obs.uuid,
                    start: obs.timeRange.start.seconds,
                    end: obs.timeRange.end.seconds,
                    confidence: obs.confidence,
                    points: timed.map { (time: $0.0, point: $0.1) })
            }
        }
        request.objectMinimumNormalizedRadius = 0.001
        request.objectMaximumNormalizedRadius = 0.05

        let handler = VNSequenceRequestHandler()
        while let sample = output.copyNextSampleBuffer() {
            try? handler.perform([request], on: sample)
        }
        return Array(observed.values)
    }
}
