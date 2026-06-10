import XCTest
import CoreGraphics
@testable import FlightCoach

/// Validates TrajectoryDetectionService against the ground-truth ball
/// positions. Comparison is geometric (path proximity), not frame-indexed,
/// to stay immune to per-container timeline quirks.
final class TrajectoryServiceTests: XCTestCase {

    func testBallFlight_IMG4165() async throws {
        // GT (vision y-up): slow riser at x≈0.49-0.50 from the tee at (0.50, 0.10).
        try await assertFlight(
            resource: "IMG_4165", ext: "mp4",
            address: CGPoint(x: 0.50, y: 0.10),
            gtPath: [CGPoint(x: 0.4963, y: 0.4286), CGPoint(x: 0.4898, y: 0.4875),
                     CGPoint(x: 0.4963, y: 0.5177)],
            fps: 30)
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
                              fps: Double) async throws {
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
        let impactTime = Double(impact.estimatedFrameIndex) / extractor.frameRate
        print("VNSVC \(resource): app impact estimate \(impact.estimatedFrameIndex) (t=\(String(format: "%.2f", impactTime))s)")
        let points = await TrajectoryDetectionService.shared.ballFlight(
            url: url, addressNormalized: address, frameRate: extractor.frameRate, impactTime: impactTime)

        guard let points, points.count >= 4 else {
            XCTFail("\(resource): no ball flight returned")
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
        print(String(format: "VNSVC %@: worst GT distance %.3f (tolerance 0.08)", resource, worst))
        XCTAssertLessThan(worst, 0.08, "\(resource): flight path does not follow the real ball")
    }
}
