import XCTest
import CoreGraphics
@testable import FlightCoach

/// Focused probe diagnostics on the Photos-import transcode.
final class ImportedProbeTests: XCTestCase {

    func testProbeAtGTAddress() async throws {
        guard let url = Bundle(for: Self.self).url(forResource: "IMG_4935_imported", withExtension: "mov") else {
            throw XCTSkip("imported fixture not bundled")
        }
        let extractor = try await VideoFrameExtractor.make(url: url)
        let stride = max(1, Int(extractor.frameRate / 15.0))
        let frames = try await extractor.extractFrames(stride: stride)
        print("PROBE imported: \(frames.count) frames @\(extractor.frameRate)")
        let impact = await BallTrackingService.shared.impactTimeByDisappearance(
            address: CGPoint(x: 0.6856, y: 0.1607), frames: frames)
        print("PROBE imported: GT-address impact = \(impact.map { String(format: "%.2f", $0) } ?? "nil") (cv2 says 5.50–5.83)")
    }
}
