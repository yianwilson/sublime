import Foundation
import Vision
import CoreImage

final class PoseDetectionService {
    static let shared = PoseDetectionService()

    var minimumLandmarkConfidence: Float = 0.20

    private init() {}

    func detectPose(
        in image: CIImage,
        frameIndex: Int,
        timestamp: TimeInterval
    ) -> (frame: PoseFrame?, debug: PoseDebugResult) {
        let imageWidth  = Int(image.extent.width)
        let imageHeight = Int(image.extent.height)

        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            let debug = PoseDebugResult(
                frameIndex: frameIndex, timestamp: timestamp,
                imageWidth: imageWidth, imageHeight: imageHeight,
                landmarkCount: 0, averageConfidence: 0,
                detectedJointNames: [], errorMessage: error.localizedDescription,
                didDetectPose: false
            )
            return (nil, debug)
        }

        guard let observation = request.results?.first else {
            let debug = PoseDebugResult(
                frameIndex: frameIndex, timestamp: timestamp,
                imageWidth: imageWidth, imageHeight: imageHeight,
                landmarkCount: 0, averageConfidence: 0,
                detectedJointNames: [], errorMessage: nil,
                didDetectPose: false
            )
            return (nil, debug)
        }

        let recognizedPoints: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
        do {
            recognizedPoints = try observation.recognizedPoints(.all)
        } catch {
            let debug = PoseDebugResult(
                frameIndex: frameIndex, timestamp: timestamp,
                imageWidth: imageWidth, imageHeight: imageHeight,
                landmarkCount: 0, averageConfidence: 0,
                detectedJointNames: [], errorMessage: "recognizedPoints failed: \(error.localizedDescription)",
                didDetectPose: true
            )
            return (nil, debug)
        }

        var landmarks: [PoseLandmark] = []
        var detectedJointNames: [String] = []

        for (jointName, point) in recognizedPoints {
            let nameString = jointName.rawValue.rawValue
            detectedJointNames.append(nameString)
            guard point.confidence >= minimumLandmarkConfidence else { continue }
            landmarks.append(PoseLandmark(
                jointName: nameString,
                x: Float(point.location.x),
                y: Float(point.location.y),
                confidence: point.confidence
            ))
        }

        let avgConfidence = landmarks.isEmpty ? 0 : landmarks.map(\.confidence).reduce(0, +) / Float(landmarks.count)

        let debug = PoseDebugResult(
            frameIndex: frameIndex, timestamp: timestamp,
            imageWidth: imageWidth, imageHeight: imageHeight,
            landmarkCount: landmarks.count,
            averageConfidence: avgConfidence,
            detectedJointNames: detectedJointNames,
            errorMessage: nil,
            didDetectPose: true
        )

        guard !landmarks.isEmpty else {
            return (nil, debug)
        }

        let frame = PoseFrame(
            frameIndex: frameIndex,
            timestamp: timestamp,
            landmarks: landmarks,
            overallConfidence: avgConfidence
        )
        return (frame, debug)
    }

    func detectPoses(
        in frames: [VideoFrame],
        onProgress: ((Double) -> Void)? = nil
    ) async -> (poseFrames: [PoseFrame], debugResults: [PoseDebugResult]) {
        var poseFrames: [PoseFrame] = []
        var debugResults: [PoseDebugResult] = []

        for (idx, frame) in frames.enumerated() {
            let (poseFrame, debug) = detectPose(in: frame.image, frameIndex: frame.index, timestamp: frame.timestamp)
            if let poseFrame { poseFrames.append(poseFrame) }
            debugResults.append(debug)

#if DEBUG
            if debug.failureReason != nil {
                print("[Pose] frame \(frame.index): \(debug.failureReason!)")
            }
#endif

            onProgress?(Double(idx + 1) / Double(frames.count))
            if idx % 10 == 0 { await Task.yield() }
        }

#if DEBUG
        let detected = poseFrames.count
        let total    = frames.count
        let avgConf  = debugResults.filter { $0.didDetectPose }.map(\.averageConfidence).reduce(0, +) / Float(max(1, detected))
        print("[Pose] \(detected)/\(total) frames with pose — avg confidence \(String(format: "%.0f%%", avgConf * 100))")
#endif

        return (poseFrames, debugResults)
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
