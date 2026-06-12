import XCTest
import CoreGraphics
@testable import FlightCoach

/// Mirrors AnalysisPipeline's golf path stage by stage to localise in-app
/// failures the service-level GT tests can't see (address seeding, impact
/// window, dense extraction, VN + fallback wiring).
final class PipelineSeedTests: XCTestCase {

    func testFullGolfPath_IMG4165() async throws {
        try await runGolfPath(resource: "IMG_4165", ext: "mp4",
                              gtAddress: CGPoint(x: 0.5907, y: 0.0323))
    }

    func testFullGolfPath_IMG4935() async throws {
        try await runGolfPath(resource: "IMG_4935", ext: "MOV",
                              gtAddress: CGPoint(x: 0.6856, y: 0.1607))
    }

    /// The EXACT bytes the app analyses: the Photos-import path re-encodes
    /// (4K60 → 4K30, darker video-range transfer). Validating only the
    /// original misses everything the transcode changes.
    func testFullGolfPath_IMG4935_imported() async throws {
        try await runGolfPath(resource: "IMG_4935_imported", ext: "mov",
                              gtAddress: CGPoint(x: 0.6856, y: 0.1607))
    }

    private func runGolfPath(resource: String, ext: String, gtAddress: CGPoint) async throws {
        guard let url = Bundle(for: Self.self).url(forResource: resource, withExtension: ext) else {
            throw XCTSkip("\(resource) not bundled")
        }
        let extractor = try await VideoFrameExtractor.make(url: url)
        let stride = max(1, Int(extractor.frameRate / 15.0))
        let frames = try await extractor.extractFrames(stride: stride)
        print("SEED \(resource): \(frames.count) frames @\(extractor.frameRate)fps")

        let poseStride = max(1, Int(extractor.frameRate / 30.0))
        let poseInputs = stride == poseStride ? frames : (try await extractor.extractFrames(stride: poseStride))
        let (poseFrames, _) = await PoseDetectionService.shared.detectPoses(in: poseInputs)
        print("SEED \(resource): pose \(poseFrames.count)/\(poseInputs.count) frames")

        let impactWindow = GolfImpactWindowEstimator.shared.estimateImpactWindow(
            frames: frames, poseFrames: poseFrames, manualContactFrame: nil)
        print("SEED \(resource): impact window est=\(impactWindow.estimatedFrameIndex) [\(impactWindow.startFrameIndex)-\(impactWindow.endFrameIndex)]")

        let seeds = await BallTrackingService.shared.disappearanceSeeds(frames: frames)
        let impactFrame = seeds.first.map { Int(($0.impactTime * extractor.frameRate).rounded()) }
            ?? impactWindow.estimatedFrameIndex
        let densePadding = max(12, Int(extractor.frameRate * 0.35))
        let maxDenseHalfSpan = max(densePadding, Int(extractor.frameRate * 0.6))
        let denseLower = max(0, impactFrame - maxDenseHalfSpan)
        let denseUpper = min(extractor.totalFrames - 1, impactFrame + maxDenseHalfSpan)
        let denseFrames = try await extractor.extractFrames(frameRange: denseLower...max(denseLower, denseUpper), stride: 1)
        var byIndex: [Int: VideoFrame] = [:]
        for f in frames { byIndex[f.index] = f }
        for f in denseFrames { byIndex[f.index] = f }
        let trackingFrames = byIndex.values.sorted { $0.index < $1.index }

        for (i, s) in seeds.enumerated() {
            let d = hypot(s.address.x - gtAddress.x, s.address.y - gtAddress.y)
            print(String(format: "SEED %@: candidate[%d] (%.3f,%.3f) impact %.2fs run %d — GT dist %.3f",
                         resource, i, s.address.x, s.address.y, s.impactTime, s.runLength, d))
        }
        XCTAssertFalse(seeds.isEmpty, "\(resource): no disappearance seeds at all")

        let flight = await TrajectoryDetectionService.shared.ballFlight(
            url: url, seeds: seeds, frameRate: extractor.frameRate)
        if let flight {
            let d = hypot(flight.seed.address.x - gtAddress.x, flight.seed.address.y - gtAddress.y)
            print(String(format: "SEED %@: VN flight %d points from seed (%.3f,%.3f) — GT dist %.3f",
                         resource, flight.points.count, flight.seed.address.x, flight.seed.address.y, d))
            XCTAssertLessThan(d, 0.06, "\(resource): VN validated a seed far from the real tee")
        } else {
            print("SEED \(resource): no VN flight from any seed — fallback tracer path")
        }

        if flight == nil || flight!.points.count < 4 {
            let addressNorm = seeds.first?.address ?? .zero
            let ctx = CIContext(options: [.useSoftwareRenderer: false])
            var tracerFrames: [TracerFrameInfo] = []
            for f in trackingFrames {
                let extent = f.image.extent
                guard extent.width > 0, extent.height > 0,
                      let cg = ctx.createCGImage(f.image, from: extent) else { continue }
                tracerFrames.append(TracerFrameInfo(index: f.index, timestamp: f.timestamp,
                                                    image: cg, width: cg.width, height: cg.height))
            }
            let w = CGFloat(tracerFrames.first!.width), h = CGFloat(tracerFrames.first!.height)
            let addressPx = CGPoint(x: addressNorm.x * w, y: (1 - addressNorm.y) * h)
            let result = GolfTracerPipeline.trace(
                frames: tracerFrames, addressBallFullFrame: addressPx,
                impactFrame: impactFrame,
                fps: extractor.frameRate, config: GolfTracerConfig())
            switch result {
            case .success(let track):
                print("SEED \(resource): fallback tracer SUCCESS, \(track.points.count) points")
                let norm = track.points.map {
                    CGPoint(x: $0.position.x / w, y: 1 - $0.position.y / h)
                }
                for (i, p) in norm.enumerated() where i < 12 {
                    print(String(format: "SEED %@: tracer[%d] f%d (%.3f,%.3f)",
                                 resource, i, track.points[i].frameIndex, p.x, p.y))
                }
                let gtPath = [CGPoint(x: 0.6579, y: 0.2326), CGPoint(x: 0.6264, y: 0.3133),
                              CGPoint(x: 0.5870, y: 0.4135)]
                var worst: CGFloat = 0
                for gt in gtPath {
                    let d = norm.map { hypot($0.x - gt.x, $0.y - gt.y) }.min() ?? 1
                    worst = max(worst, d)
                }
                print(String(format: "SEED %@: fallback worst GT distance %.3f", resource, worst))
            case .failure(let reason):
                print("SEED \(resource): fallback tracer NO TRACE — \(reason)")
            }
        }
    }
}
