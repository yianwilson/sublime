import Foundation

struct VisionBenchmarkPoint: Codable, Equatable {
    let frame: Int
    let x: Float
    let y: Float
    let confidence: Float?

    init(frame: Int, x: Float, y: Float, confidence: Float? = nil) {
        self.frame = frame
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.confidence = confidence.map { min(max($0, 0), 1) }
    }
}

struct VisionBenchmarkPredictions: Codable, Equatable {
    let addressBall: VisionBenchmarkPoint?
    let impactFrame: Int?
    let launchPoints: [VisionBenchmarkPoint]
    let failureReason: String?

    enum CodingKeys: String, CodingKey {
        case addressBall = "address_ball"
        case impactFrame = "impact_frame"
        case launchPoints = "launch_points"
        case failureReason = "failure_reason"
    }
}

struct VisionBenchmarkSampleResult: Codable, Equatable {
    let id: String
    let predictions: VisionBenchmarkPredictions
}

struct VisionBenchmarkRun: Codable, Equatable {
    let runId: String
    let samples: [VisionBenchmarkSampleResult]

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case samples
    }
}

extension VisionBenchmarkPredictions {
    init(
        ballTrackPoints: [BallTrackPoint],
        contactFrameIndex: Int?,
        failureReason: String? = nil
    ) {
        let sorted = ballTrackPoints.sorted { $0.timestamp < $1.timestamp }
        let address = sorted.first.map {
            VisionBenchmarkPoint(
                frame: $0.frameIndex,
                x: $0.x,
                y: $0.y,
                confidence: $0.confidence
            )
        }
        let launch = sorted.dropFirst().map {
            VisionBenchmarkPoint(
                frame: $0.frameIndex,
                x: $0.x,
                y: $0.y,
                confidence: $0.confidence
            )
        }

        self.init(
            addressBall: address,
            impactFrame: contactFrameIndex,
            launchPoints: Array(launch),
            failureReason: failureReason
        )
    }
}

