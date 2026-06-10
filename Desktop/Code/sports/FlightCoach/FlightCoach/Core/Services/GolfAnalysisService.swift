import Foundation

final class GolfAnalysisService {
    static let shared = GolfAnalysisService()

    private init() {}

    private struct BallTrackQuality {
        let usablePoints: [BallTrackPoint]
        let confidence: Float
        let reason: String
        let isUsableForShotShape: Bool
    }

    func analyse(
        poseFrames: [PoseFrame],
        ballTrackPoints: [BallTrackPoint],
        contactFrameIndex: Int,
        contactConfidence: Float,
        cameraAngle: CameraAngle,
        poseSummary: PoseSummary? = nil
    ) -> GolfAnalysisResult {
        let trackQuality = evaluateBallTrack(ballTrackPoints)
        let shotShape = estimateShotShape(ballTrackPoints: ballTrackPoints, cameraAngle: cameraAngle, trackQuality: trackQuality)
        let metrics = computeMetrics(
            poseFrames: poseFrames,
            contactFrameIndex: contactFrameIndex,
            ballTrackPoints: ballTrackPoints,
            trackQuality: trackQuality
        )
        let feedback = FeedbackEngine.shared.golfFeedback(
            metrics: metrics,
            shotShape: shotShape.shape,
            shotShapeConfidence: shotShape.confidence,
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
            poseFrames: poseFrames,
            poseSummary: poseSummary
        )
    }

    private func estimateShotShape(ballTrackPoints: [BallTrackPoint], cameraAngle: CameraAngle, trackQuality: BallTrackQuality) -> (shape: ShotShape, confidence: Float) {
        guard cameraAngle == .behindBallFlight, ballTrackPoints.count >= 4 else {
            return (.unknown, 0.15)
        }
        guard trackQuality.isUsableForShotShape else {
            return (.unknown, min(0.25, trackQuality.confidence))
        }

        let sorted = trackQuality.usablePoints
        guard let first = sorted.first, let last = sorted.last else {
            return (.unknown, 0.15)
        }

        let totalDX = last.x - first.x
        let mid = sorted[sorted.count / 2]
        let midDeviation = mid.x - (first.x + last.x) / 2.0
        let totalDY = last.y - first.y
        let pathLength = pathLength(sorted)
        let displacement = hypot(Double(totalDX), Double(totalDY))
        let curvatureRatio = displacement > 0 ? abs(Double(midDeviation)) / displacement : 0

        guard pathLength > 0.08, displacement > 0.06 else {
            return (.unknown, min(0.25, trackQuality.confidence))
        }

        let confidence = min(0.75, max(0.2, trackQuality.confidence * Float(min(1.0, curvatureRatio * 8.0))))

        if abs(midDeviation) < 0.025 || curvatureRatio < 0.08 {
            return (.straight, max(0.25, trackQuality.confidence * 0.55))
        } else if midDeviation > 0 {
            return totalDX > 0 ? (.fadeOrSlice, confidence) : (.drawOrHook, confidence)
        } else {
            return totalDX > 0 ? (.drawOrHook, confidence) : (.fadeOrSlice, confidence)
        }
    }

    private func computeMetrics(
        poseFrames: [PoseFrame],
        contactFrameIndex: Int,
        ballTrackPoints: [BallTrackPoint],
        trackQuality: BallTrackQuality
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

    private func evaluateBallTrack(_ points: [BallTrackPoint]) -> BallTrackQuality {
        let sorted = points
            .filter { $0.confidence >= 0.15 }
            .sorted { $0.frameIndex < $1.frameIndex }

        guard sorted.count >= 2 else {
            return BallTrackQuality(usablePoints: sorted, confidence: 0.15, reason: "too-few-points", isUsableForShotShape: false)
        }

        let totalPath = pathLength(sorted)
        guard let first = sorted.first, let last = sorted.last else {
            return BallTrackQuality(usablePoints: sorted, confidence: 0.15, reason: "empty-track", isUsableForShotShape: false)
        }

        let displacement = hypot(Double(last.x - first.x), Double(last.y - first.y))
        let avgConfidence = sorted.map(\.confidence).reduce(0, +) / Float(sorted.count)
        let jumpPenalty = largeJumpRatio(sorted)
        let straightness = displacement / max(totalPath, 0.0001)
        let pointScore = min(1.0, Float(sorted.count) / 8.0)
        let travelScore = min(1.0, Float(displacement / 0.18))
        let confidence = max(0.10, min(0.9, avgConfidence * 0.50 + pointScore * 0.22 + travelScore * 0.23 - Float(jumpPenalty) * 0.30))

        let usableForShape = sorted.count >= 6 && displacement > 0.08 && totalPath > 0.1 && jumpPenalty < 0.3 && straightness > 0.55

        return BallTrackQuality(
            usablePoints: sorted,
            confidence: confidence,
            reason: usableForShape ? "tracked" : "weak-track",
            isUsableForShotShape: usableForShape
        )
    }

    private func pathLength(_ points: [BallTrackPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0.0) { total, pair in
            total + hypot(Double(pair.1.x - pair.0.x), Double(pair.1.y - pair.0.y))
        }
    }

    private func largeJumpRatio(_ points: [BallTrackPoint]) -> Double {
        guard points.count > 1 else { return 1 }
        var jumps = 0
        var total = 0
        for pair in zip(points, points.dropFirst()) {
            let dt = max(1.0 / 240.0, pair.1.timestamp - pair.0.timestamp)
            let dist = hypot(Double(pair.1.x - pair.0.x), Double(pair.1.y - pair.0.y))
            let allowed = max(0.12, min(0.42, 18.0 * dt))
            if dist > allowed * 0.75 {
                jumps += 1
            }
            total += 1
        }
        return Double(jumps) / Double(max(1, total))
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
