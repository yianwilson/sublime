import Foundation

final class ContactDetectionService {
    static let shared = ContactDetectionService()

    private init() {}

    // MARK: - Pre-tracking pose-only estimate (call before ball tracking)

    func estimateImpactFromPoseOnly(poseFrames: [PoseFrame]) -> (frameIndex: Int, confidence: Float) {
        if let r = detectImpactFromWristAcceleration(poseFrames: poseFrames) { return r }
        return estimateImpactFromSwingPhase(
            poseFrames: poseFrames,
            totalFrames: poseFrames.last?.frameIndex ?? 100
        )
    }

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
        guard ballTrackPoints.count >= 4 else { return nil }
        let sorted = ballTrackPoints.sorted { $0.frameIndex < $1.frameIndex }

        func vel(_ a: BallTrackPoint, _ b: BallTrackPoint) -> Float {
            let dx = b.x - a.x, dy = b.y - a.y
            return sqrt(dx * dx + dy * dy)
        }

        // Require: ball was stationary (low velocity) for the frame just before,
        // then has a sustained velocity increase for at least two consecutive frames.
        for i in 2..<sorted.count - 1 {
            let vBefore  = vel(sorted[i - 2], sorted[i - 1])   // pre-impact
            let vAt      = vel(sorted[i - 1], sorted[i])        // at impact
            let vAfter   = vel(sorted[i],     sorted[i + 1])    // post-impact

            let wasSteady  = vBefore < 0.018
            let nowMoving  = vAt > 0.040 && sorted[i].confidence > 0.45
            let sustained  = vAfter > 0.020

            if wasSteady && nowMoving && sustained {
                let conf = min(0.85, sorted[i].confidence * min(1.0, vAt * 8))
                return (sorted[i].frameIndex, conf)
            }
        }
        return nil
    }

    private func detectImpactFromWristAcceleration(poseFrames: [PoseFrame]) -> (Int, Float)? {
        guard poseFrames.count > 5 else { return nil }

        // Build wrist speed profile
        var speeds: [(frameIndex: Int, speed: Float, frame: PoseFrame)] = []
        for i in 1..<poseFrames.count {
            let prev = poseFrames[i - 1]
            let curr = poseFrames[i]
            guard let pw = prev.rightWrist ?? prev.leftWrist,
                  let cw = curr.rightWrist ?? curr.leftWrist,
                  cw.confidence > 0.35 else { continue }
            let speed = sqrt(pow(cw.x - pw.x, 2) + pow(cw.y - pw.y, 2))
            speeds.append((curr.frameIndex, speed, curr))
        }
        guard speeds.count > 3 else { return nil }

        // Find the speed peak, then walk forward to the first deceleration — that's impact
        let peakIdx = speeds.indices.max(by: { speeds[$0].speed < speeds[$1].speed }) ?? 0
        guard speeds[peakIdx].speed > 0.020 else { return nil }

        // Impact is at or just after the speed peak (deceleration onset)
        let impactIdx = min(peakIdx + 1, speeds.count - 1)
        let confidence = Float(min(0.65, Double(speeds[peakIdx].speed) * 4.5))
        return (speeds[impactIdx].frameIndex, confidence)
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
