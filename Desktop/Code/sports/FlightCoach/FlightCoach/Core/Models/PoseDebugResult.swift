import Foundation
import Vision

// Runtime-only debug data produced during pose detection.
// Not persisted — use PoseSummary for stored stats.
struct PoseDebugResult {
    let frameIndex: Int
    let timestamp: TimeInterval
    let imageWidth: Int
    let imageHeight: Int
    let landmarkCount: Int
    let averageConfidence: Float
    let detectedJointNames: [String]
    let errorMessage: String?
    let didDetectPose: Bool

    static let keyJointNames: [String] = {
        func k(_ j: VNHumanBodyPoseObservation.JointName) -> String { j.rawValue.rawValue }
        return [
            k(.nose), k(.neck),
            k(.leftShoulder), k(.rightShoulder),
            k(.leftElbow),    k(.rightElbow),
            k(.leftWrist),    k(.rightWrist),
            k(.leftHip),      k(.rightHip),
            k(.leftKnee),     k(.rightKnee),
            k(.leftAnkle),    k(.rightAnkle),
        ]
    }()

    var missingKeyJoints: [String] {
        Self.keyJointNames.filter { !detectedJointNames.contains($0) }
    }

    var keyJointCoverage: Float {
        let detected = Self.keyJointNames.filter { detectedJointNames.contains($0) }.count
        return Float(detected) / Float(max(1, Self.keyJointNames.count))
    }

    var failureReason: String? {
        if let err = errorMessage { return "Vision error: \(err)" }
        if !didDetectPose { return "No person detected" }
        if landmarkCount < 4  { return "Too few landmarks (\(landmarkCount))" }
        if averageConfidence < 0.25 { return "Low confidence (\(Int(averageConfidence * 100))%)" }
        if keyJointCoverage < 0.40  { return "Body not fully visible (\(Int(keyJointCoverage * 100))% joints)" }
        return nil
    }
}
