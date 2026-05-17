import Foundation

final class ContactDetectionService {
    static let shared = ContactDetectionService()

    private init() {}

    // MARK: - Golf

    func detectGolfImpact(
        poseFrames: [PoseFrame],
        ballTrackPoints: [BallTrackPoint],
        totalFrames: Int
    ) -> (frameIndex: Int, confidence: Float) {
        if let ballBased = detectImpactFromBallAppearance(ballTrackPoints: ballTrackPoints) {
            return ballBased
        }
        if let poseBased = detectImpactFromWristAcceleration(poseFrames: poseFrames) {
            return poseBased
        }
        let estimated = estimateImpactFromSwingPhase(poseFrames: poseFrames, totalFrames: totalFrames)
        return estimated
    }

    private func detectImpactFromBallAppearance(ballTrackPoints: [BallTrackPoint]) -> (Int, Float)? {
        guard ballTrackPoints.count >= 2 else { return nil }

        for i in 1..<ballTrackPoints.count {
            let prev = ballTrackPoints[i - 1]
            let curr = ballTrackPoints[i]
            let dx = curr.x - prev.x
            let dy = curr.y - prev.y
            let velocity = sqrt(dx * dx + dy * dy)

            if velocity > 0.04 && curr.confidence > 0.5 {
                return (curr.frameIndex, min(0.8, curr.confidence * min(1.0, velocity * 10)))
            }
        }
        return nil
    }

    private func detectImpactFromWristAcceleration(poseFrames: [PoseFrame]) -> (Int, Float)? {
        guard poseFrames.count > 4 else { return nil }

        var maxAcceleration: Float = 0
        var candidateFrame = poseFrames[0]

        for i in 2..<poseFrames.count - 1 {
            let prev = poseFrames[i - 2]
            let curr = poseFrames[i]

            guard let pw = prev.rightWrist ?? prev.leftWrist,
                  let cw = curr.rightWrist ?? curr.leftWrist else { continue }

            let dx = cw.x - pw.x
            let dy = cw.y - pw.y
            let speed = sqrt(dx * dx + dy * dy)

            if speed > maxAcceleration && cw.confidence > 0.4 {
                maxAcceleration = speed
                candidateFrame = curr
            }
        }

        guard maxAcceleration > 0.02 else { return nil }

        let confidence = Float(min(0.65, Double(maxAcceleration) * 5.0))
        return (candidateFrame.frameIndex, confidence)
    }

    private func estimateImpactFromSwingPhase(poseFrames: [PoseFrame], totalFrames: Int) -> (Int, Float) {
        let estimatedFrame = Int(Double(totalFrames) * 0.6)
        return (estimatedFrame, 0.25)
    }

    // MARK: - Tennis

    func detectTennisContact(
        poseFrames: [PoseFrame],
        ballTrackPoints: [BallTrackPoint],
        totalFrames: Int
    ) -> (frameIndex: Int, confidence: Float) {
        if let ballDirectionChange = detectBallDirectionChange(ballTrackPoints: ballTrackPoints) {
            return ballDirectionChange
        }
        if let armExtension = detectArmExtensionPeak(poseFrames: poseFrames) {
            return armExtension
        }
        return (Int(Double(totalFrames) * 0.5), 0.2)
    }

    private func detectBallDirectionChange(ballTrackPoints: [BallTrackPoint]) -> (Int, Float)? {
        guard ballTrackPoints.count >= 3 else { return nil }

        for i in 1..<ballTrackPoints.count - 1 {
            let prev = ballTrackPoints[i - 1]
            let curr = ballTrackPoints[i]
            let next = ballTrackPoints[i + 1]

            let v1x = curr.x - prev.x
            let v1y = curr.y - prev.y
            let v2x = next.x - curr.x
            let v2y = next.y - curr.y

            let dot = v1x * v2x + v1y * v2y
            let mag1 = sqrt(v1x * v1x + v1y * v1y)
            let mag2 = sqrt(v2x * v2x + v2y * v2y)

            guard mag1 > 0 && mag2 > 0 else { continue }

            let cosAngle = dot / (mag1 * mag2)
            if cosAngle < -0.3 {
                let confidence = min(0.85, Float(-cosAngle) * curr.confidence)
                return (curr.frameIndex, confidence)
            }
        }
        return nil
    }

    private func detectArmExtensionPeak(poseFrames: [PoseFrame]) -> (Int, Float)? {
        guard poseFrames.count > 4 else { return nil }

        var maxExtension: Float = 0
        var candidate: PoseFrame? = nil

        for frame in poseFrames {
            guard let shoulder = frame.rightShoulder ?? frame.leftShoulder,
                  let wrist = frame.rightWrist ?? frame.leftWrist else { continue }

            let dx = wrist.x - shoulder.x
            let dy = wrist.y - shoulder.y
            let extension_ = sqrt(dx * dx + dy * dy)

            if extension_ > maxExtension && wrist.confidence > 0.4 {
                maxExtension = extension_
                candidate = frame
            }
        }

        guard let frame = candidate, maxExtension > 0.15 else { return nil }
        return (frame.frameIndex, 0.55)
    }
}
