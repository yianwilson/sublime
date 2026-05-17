import Foundation
import Vision
import CoreImage

final class PoseDetectionService {
    static let shared = PoseDetectionService()

    private init() {}

    func detectPose(in image: CIImage, frameIndex: Int, timestamp: TimeInterval) throws -> PoseFrame? {
        let request = VNDetectHumanBodyPoseRequest()
        // VNImageRequestHandler is correct for per-frame detection.
        // VNSequenceRequestHandler is only for tracking requests across frames.
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            return nil
        }

        let recognizedPoints = try observation.recognizedPoints(.all)
        var landmarks: [PoseLandmark] = []

        for (key, point) in recognizedPoints {
            guard point.confidence > 0.2 else { continue }
            landmarks.append(PoseLandmark(
                jointName: key.rawValue.rawValue,
                x: Float(point.location.x),
                y: Float(point.location.y),
                confidence: point.confidence
            ))
        }

        guard !landmarks.isEmpty else { return nil }

        let overallConfidence = landmarks.map(\.confidence).reduce(0, +) / Float(landmarks.count)

        return PoseFrame(
            frameIndex: frameIndex,
            timestamp: timestamp,
            landmarks: landmarks,
            overallConfidence: overallConfidence
        )
    }

    func detectPoses(
        in frames: [VideoFrame],
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [PoseFrame] {
        var results: [PoseFrame] = []

        for (idx, frame) in frames.enumerated() {
            if let poseFrame = try? detectPose(in: frame.image, frameIndex: frame.index, timestamp: frame.timestamp) {
                results.append(poseFrame)
            }
            onProgress?(Double(idx + 1) / Double(frames.count))
            // Yield periodically so the main actor stays responsive
            if idx % 10 == 0 { await Task.yield() }
        }

        return results
    }
}

extension PoseFrame {
    var leftShoulder: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.leftShoulder.rawValue.rawValue) }
    var rightShoulder: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.rightShoulder.rawValue.rawValue) }
    var leftHip: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.leftHip.rawValue.rawValue) }
    var rightHip: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.rightHip.rawValue.rawValue) }
    var leftKnee: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.leftKnee.rawValue.rawValue) }
    var rightKnee: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.rightKnee.rawValue.rawValue) }
    var leftAnkle: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.leftAnkle.rawValue.rawValue) }
    var rightAnkle: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.rightAnkle.rawValue.rawValue) }
    var leftWrist: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.leftWrist.rawValue.rawValue) }
    var rightWrist: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.rightWrist.rawValue.rawValue) }
    var leftElbow: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.leftElbow.rawValue.rawValue) }
    var rightElbow: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.rightElbow.rawValue.rawValue) }
    var nose: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.nose.rawValue.rawValue) }
    var neck: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.neck.rawValue.rawValue) }
    var rootJoint: PoseLandmark? { landmark(named: VNHumanBodyPoseObservation.JointName.root.rawValue.rawValue) }
}
