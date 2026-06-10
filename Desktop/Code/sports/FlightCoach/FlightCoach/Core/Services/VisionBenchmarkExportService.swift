import Foundation

final class VisionBenchmarkExportService {
    static let shared = VisionBenchmarkExportService()

    private let encoder: JSONEncoder

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func makeSampleResult(
        sampleId: String,
        ballTrackPoints: [BallTrackPoint],
        contactFrameIndex: Int?,
        failureReason: String? = nil
    ) -> VisionBenchmarkSampleResult {
        VisionBenchmarkSampleResult(
            id: sampleId,
            predictions: VisionBenchmarkPredictions(
                ballTrackPoints: ballTrackPoints,
                contactFrameIndex: contactFrameIndex,
                failureReason: failureReason
            )
        )
    }

    func encodeRun(runId: String, samples: [VisionBenchmarkSampleResult]) throws -> Data {
        try encoder.encode(VisionBenchmarkRun(runId: runId, samples: samples))
    }

    func writeRun(runId: String, samples: [VisionBenchmarkSampleResult], to url: URL) throws {
        let data = try encodeRun(runId: runId, samples: samples)
        try data.write(to: url, options: [.atomic])
    }
}

