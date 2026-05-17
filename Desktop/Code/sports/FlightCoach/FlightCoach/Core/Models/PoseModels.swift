import Foundation
import Vision

struct PoseLandmark: Codable, Identifiable, Equatable {
    let id: UUID
    let jointName: String
    let x: Float
    let y: Float
    let confidence: Float

    init(jointName: String, x: Float, y: Float, confidence: Float) {
        self.id = UUID()
        self.jointName = jointName
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

struct PoseFrame: Codable, Identifiable, Equatable {
    let id: UUID
    let frameIndex: Int
    let timestamp: TimeInterval
    let landmarks: [PoseLandmark]
    let overallConfidence: Float

    init(frameIndex: Int, timestamp: TimeInterval, landmarks: [PoseLandmark], overallConfidence: Float) {
        self.id = UUID()
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.landmarks = landmarks
        self.overallConfidence = overallConfidence
    }

    func landmark(named name: String) -> PoseLandmark? {
        landmarks.first { $0.jointName == name }
    }
}

struct BallTrackPoint: Codable, Identifiable, Equatable {
    let id: UUID
    let frameIndex: Int
    let timestamp: TimeInterval
    let x: Float
    let y: Float
    let confidence: Float

    init(frameIndex: Int, timestamp: TimeInterval, x: Float, y: Float, confidence: Float) {
        self.id = UUID()
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}
