import Foundation

final class GolfAnalysisService {
    static let shared = GolfAnalysisService()

    private init() {}

    func analyse(
        poseFrames: [PoseFrame],
        ballTrackPoints: [BallTrackPoint],
        contactFrameIndex: Int,
        contactConfidence: Float,
        cameraAngle: CameraAngle
    ) -> GolfAnalysisResult {
        let shotShape = estimateShotShape(ballTrackPoints: ballTrackPoints, cameraAngle: cameraAngle)
        let metrics = computeMetrics(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex, ballTrackPoints: ballTrackPoints)
        let feedback = FeedbackEngine.shared.golfFeedback(
            metrics: metrics,
            shotShape: shotShape.shape,
            cameraAngle: cameraAngle,
            contactConfidence: contactConfidence
        )

        return GolfAnalysisResult(
            contactFrameIndex: contactFrameIndex,
            contactConfidence: contactConfidence,
            shotShape: shotShape.shape,
            shotShapeConfidence: shotShape.confidence,
            ballTrackPoints: ballTrackPoints,
            metrics: metrics,
            feedback: feedback,
            poseFrames: poseFrames
        )
    }

    private func estimateShotShape(ballTrackPoints: [BallTrackPoint], cameraAngle: CameraAngle) -> (shape: ShotShape, confidence: Float) {
        guard cameraAngle == .behindBallFlight, ballTrackPoints.count >= 4 else {
            return (.unknown, 0.15)
        }

        let sorted = ballTrackPoints.sorted { $0.frameIndex < $1.frameIndex }
        let first = sorted[0]
        let last = sorted[sorted.count - 1]

        let totalDX = last.x - first.x
        let mid = sorted[sorted.count / 2]
        let midDeviation = mid.x - (first.x + last.x) / 2.0

        let confidence = Float(min(0.7, Double(ballTrackPoints.count) / 15.0))

        if abs(midDeviation) < 0.02 {
            return (.straight, confidence)
        } else if midDeviation > 0 {
            return totalDX > 0 ? (.fadeOrSlice, confidence) : (.drawOrHook, confidence)
        } else {
            return totalDX > 0 ? (.drawOrHook, confidence) : (.fadeOrSlice, confidence)
        }
    }

    private func computeMetrics(
        poseFrames: [PoseFrame],
        contactFrameIndex: Int,
        ballTrackPoints: [BallTrackPoint]
    ) -> [AnalysisMetric] {
        var metrics: [AnalysisMetric] = []

        if let tempo = computeTempoRatio(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex) {
            metrics.append(tempo)
        }
        if let headMovement = computeHeadMovement(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex) {
            metrics.append(headMovement)
        }
        if let spineAngle = computeSpineAngleChange(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex) {
            metrics.append(spineAngle)
        }
        if let hipSway = computeHipSway(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex) {
            metrics.append(hipSway)
        }
        if let balance = computeBalanceAtFinish(poseFrames: poseFrames) {
            metrics.append(balance)
        }

        return metrics
    }

    private func computeTempoRatio(poseFrames: [PoseFrame], contactFrameIndex: Int) -> AnalysisMetric? {
        guard poseFrames.count > 4 else { return nil }

        let framesBeforeContact = poseFrames.filter { $0.frameIndex < contactFrameIndex }
        let framesAfterContact = poseFrames.filter { $0.frameIndex > contactFrameIndex }

        guard !framesBeforeContact.isEmpty && !framesAfterContact.isEmpty else { return nil }

        let backswingFrames = Double(framesBeforeContact.count)
        let downswingFrames = Double(max(1, framesAfterContact.count / 2))
        let ratio = backswingFrames / downswingFrames

        let confidence: Float = poseFrames.count > 20 ? 0.6 : 0.4

        return AnalysisMetric(
            name: "Tempo Ratio",
            value: ratio,
            unit: ":1",
            confidence: confidence,
            displayValue: String(format: "%.1f:1", ratio)
        )
    }

    private func computeHeadMovement(poseFrames: [PoseFrame], contactFrameIndex: Int) -> AnalysisMetric? {
        guard let addressFrame = poseFrames.first,
              let contactFrame = poseFrames.first(where: { $0.frameIndex >= contactFrameIndex }) else { return nil }

        guard let addressNose = addressFrame.nose, let contactNose = contactFrame.nose else { return nil }
        guard addressNose.confidence > 0.4 && contactNose.confidence > 0.4 else { return nil }

        let dx = contactNose.x - addressNose.x
        let dy = contactNose.y - addressNose.y
        let movement = sqrt(dx * dx + dy * dy)
        let movementPercent = Double(movement) * 100.0

        let confidence = min(addressNose.confidence, contactNose.confidence)

        return AnalysisMetric(
            name: "Head Movement",
            value: Double(movement),
            unit: "% frame",
            confidence: confidence,
            displayValue: String(format: "%.1f%%", movementPercent)
        )
    }

    private func computeSpineAngleChange(poseFrames: [PoseFrame], contactFrameIndex: Int) -> AnalysisMetric? {
        guard let addressFrame = poseFrames.first,
              let contactFrame = poseFrames.first(where: { $0.frameIndex >= contactFrameIndex }) else { return nil }

        func spineAngle(_ frame: PoseFrame) -> Double? {
            guard let shoulder = frame.leftShoulder ?? frame.rightShoulder,
                  let hip = frame.leftHip ?? frame.rightHip,
                  shoulder.confidence > 0.4, hip.confidence > 0.4 else { return nil }
            let dx = Double(hip.x - shoulder.x)
            let dy = Double(hip.y - shoulder.y)
            return atan2(dy, dx) * 180.0 / .pi
        }

        guard let a1 = spineAngle(addressFrame), let a2 = spineAngle(contactFrame) else { return nil }

        let change = abs(a2 - a1)
        let confidence: Float = 0.55

        return AnalysisMetric(
            name: "Spine Angle Change",
            value: change,
            unit: "°",
            confidence: confidence,
            displayValue: String(format: "%.1f°", change)
        )
    }

    private func computeHipSway(poseFrames: [PoseFrame], contactFrameIndex: Int) -> AnalysisMetric? {
        guard let addressFrame = poseFrames.first,
              let contactFrame = poseFrames.first(where: { $0.frameIndex >= contactFrameIndex }) else { return nil }

        guard let ah = addressFrame.leftHip ?? addressFrame.rightHip,
              let ch = contactFrame.leftHip ?? contactFrame.rightHip,
              ah.confidence > 0.4, ch.confidence > 0.4 else { return nil }

        let sway = abs(ch.x - ah.x)
        let swayPercent = Double(sway) * 100.0

        return AnalysisMetric(
            name: "Hip Sway",
            value: Double(sway),
            unit: "% frame",
            confidence: min(ah.confidence, ch.confidence),
            displayValue: String(format: "%.1f%%", swayPercent)
        )
    }

    private func computeBalanceAtFinish(poseFrames: [PoseFrame]) -> AnalysisMetric? {
        guard let finishFrame = poseFrames.last else { return nil }

        guard let leftAnkle = finishFrame.leftAnkle, let rightAnkle = finishFrame.rightAnkle,
              let leftHip = finishFrame.leftHip, let rightHip = finishFrame.rightHip else { return nil }

        let ankleMidX = (leftAnkle.x + rightAnkle.x) / 2.0
        let hipMidX = (leftHip.x + rightHip.x) / 2.0
        let offset = abs(hipMidX - ankleMidX)
        let balance = max(0, 1.0 - Double(offset) * 5.0)

        let confidence = Float(min(leftAnkle.confidence, min(rightAnkle.confidence, min(leftHip.confidence, rightHip.confidence))))

        return AnalysisMetric(
            name: "Balance at Finish",
            value: balance * 100,
            unit: "%",
            confidence: confidence,
            displayValue: String(format: "%.0f%%", balance * 100)
        )
    }
}
