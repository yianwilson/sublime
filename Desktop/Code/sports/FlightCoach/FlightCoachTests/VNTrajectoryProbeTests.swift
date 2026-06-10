import XCTest
import Vision
import AVFoundation
@testable import FlightCoach

/// Probes Apple's built-in small-object trajectory detector against the bundled
/// fixtures. If this finds the ball flight, it replaces the custom launch
/// detection entirely — zero models, zero licensing, Apple-maintained.
final class VNTrajectoryProbeTests: XCTestCase {

    func testTrajectories_IMG4935() throws {
        try probe("IMG_4935", "MOV")
    }

    func testTrajectories_IMG4165() throws {
        try probe("IMG_4165", "mp4")
    }

    private func probe(_ res: String, _ ext: String) throws {
        guard let url = Bundle(for: Self.self).url(forResource: res, withExtension: ext) else {
            throw XCTSkip("\(res).\(ext) not bundled")
        }

        var seen: [String: (start: Double, end: Double, first: CGPoint, last: CGPoint, conf: Float, count: Int)] = [:]

        let request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 6) { req, _ in
            for obs in (req.results as? [VNTrajectoryObservation]) ?? [] {
                guard let f = obs.detectedPoints.first, let l = obs.detectedPoints.last else { continue }
                seen[obs.uuid.uuidString] = (
                    start: obs.timeRange.start.seconds,
                    end: obs.timeRange.end.seconds,
                    first: CGPoint(x: f.x, y: f.y),
                    last: CGPoint(x: l.x, y: l.y),
                    conf: obs.confidence,
                    count: obs.detectedPoints.count)
            }
        }
        request.objectMinimumNormalizedRadius = 0.001
        request.objectMaximumNormalizedRadius = 0.05

        let processor = VNVideoProcessor(url: url)
        try processor.addRequest(request, processingOptions: VNVideoProcessor.RequestProcessingOptions())
        try processor.analyze(CMTimeRange(start: .zero, duration: CMTime(seconds: 600, preferredTimescale: 600)))

        print("TRAJ \(res): \(seen.count) trajectories")
        for (_, t) in seen.sorted(by: { $0.value.start < $1.value.start }) {
            print(String(format: "TRAJ %@ t=%.2f–%.2fs pts=%d conf=%.2f (%.3f,%.3f)->(%.3f,%.3f) [vision y-up]",
                         res, t.start, t.end, t.count, t.conf,
                         t.first.x, t.first.y, t.last.x, t.last.y))
        }
    }
}
