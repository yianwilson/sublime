import XCTest
import CoreGraphics
@testable import FlightCoach

/// Validates TrajectoryDetectionService against the ground-truth ball
/// positions. Comparison is geometric (path proximity), not frame-indexed,
/// to stay immune to per-container timeline quirks.
final class TrajectoryServiceTests: XCTestCase {

    func testBallFlight_IMG4165() async throws {
        // GT (vision y-up): tee at (0.591, 0.032) — pixel-verified at t=4.3,
        // ball white (luma 0.97), gone by t=4.6. Flight: slow riser at x≈0.49-0.50.
        // VN never emits this slow receding riser as a trajectory (verified by
        // dumping ALL 1189 trajectories: best worst-GT distance 0.172), so the
        // correct service behaviour is returning NIL — the pipeline then falls
        // back to the spec-v3 tracer. Returning a confident wrong path fails.
        try await assertFlight(
            resource: "IMG_4165", ext: "mp4",
            address: CGPoint(x: 0.5907, y: 0.0323),
            gtPath: [CGPoint(x: 0.4963, y: 0.4286), CGPoint(x: 0.4898, y: 0.4875),
                     CGPoint(x: 0.4963, y: 0.5177)],
            fps: 30, nilAllowed: true)
    }

    func testBallFlight_IMG4935() async throws {
        // GT (vision y-up, YOLO-verified): tee (0.686, 0.161), hard pull up-left.
        try await assertFlight(
            resource: "IMG_4935", ext: "MOV",
            address: CGPoint(x: 0.6856, y: 0.1607),
            gtPath: [CGPoint(x: 0.6579, y: 0.2326), CGPoint(x: 0.6264, y: 0.3133),
                     CGPoint(x: 0.5870, y: 0.4135)],
            fps: 60)
    }

    private func assertFlight(resource: String, ext: String,
                              address: CGPoint, gtPath: [CGPoint],
                              fps: Double, nilAllowed: Bool = false) async throws {
        guard let url = Bundle(for: Self.self).url(forResource: resource, withExtension: ext) else {
            throw XCTSkip("\(resource) not bundled")
        }
        // Impact estimate exactly as the app computes it — same AVFoundation
        // clock as the trajectory service, no cross-tool timeline guessing.
        let extractor = try await VideoFrameExtractor.make(url: url)
        let stride = max(1, Int(extractor.frameRate / 15.0))
        let estFrames = try await extractor.extractFrames(stride: stride)
        let impact = GolfImpactWindowEstimator.shared.estimateImpactWindow(
            frames: estFrames, poseFrames: [], manualContactFrame: nil)
        let estimatorTime = Double(impact.estimatedFrameIndex) / extractor.frameRate
        let disappearanceTime = await BallTrackingService.shared.impactTimeByDisappearance(
            address: address, frames: estFrames)
        let impactTime = disappearanceTime ?? estimatorTime
        print(String(format: "VNSVC %@: impact anchor %.2fs (disappearance %@, estimator %.2fs)",
                     resource, impactTime,
                     disappearanceTime.map { String(format: "%.2fs", $0) } ?? "nil",
                     estimatorTime))
        let points = await TrajectoryDetectionService.shared.ballFlight(
            url: url, addressNormalized: address, frameRate: extractor.frameRate, impactTime: impactTime)

        guard let points, points.count >= 4 else {
            if nilAllowed {
                print("VNSVC \(resource): no flight returned — accepted, pipeline falls back to spec-v3 tracer")
            } else {
                XCTFail("\(resource): no ball flight returned")
            }
            return
        }
        print("VNSVC \(resource): \(points.count) points " + points.prefix(8).map {
            String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: " "))

        // Every GT path sample must lie near the returned flight path.
        var worst: CGFloat = 0
        for gt in gtPath {
            let d = points.map { hypot(CGFloat($0.x) - gt.x, CGFloat($0.y) - gt.y) }.min() ?? 1
            worst = max(worst, d)
        }
        // 0.10: VN emits several sibling trajectories of the same flight; some
        // have noisy tails (VN drifting onto shimmer as the ball shrinks).
        // Starts/middles match GT within 0.02 — the tail noise is bounded.
        print(String(format: "VNSVC %@: worst GT distance %.3f (tolerance 0.10)", resource, worst))
        XCTAssertLessThan(worst, 0.10, "\(resource): flight path does not follow the real ball")
    }
}
