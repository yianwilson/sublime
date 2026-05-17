import Foundation

final class TennisAnalysisService {
    static let shared = TennisAnalysisService()

    private init() {}

    func analyse(
        poseFrames: [PoseFrame],
        ballTrackPoints: [BallTrackPoint],
        contactFrameIndex: Int,
        contactConfidence: Float,
        mode: TennisMode
    ) -> TennisAnalysisResult {
        let metrics = computeMetrics(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex, ballTrackPoints: ballTrackPoints)
        let feedback = FeedbackEngine.shared.tennisFeedback(
            metrics: metrics,
            mode: mode,
            contactConfidence: contactConfidence
        )

        return TennisAnalysisResult(
            contactFrameIndex: contactFrameIndex,
            contactConfidence: contactConfidence,
            ballTrackPoints: ballTrackPoints,
            metrics: metrics,
            feedback: feedback,
            poseFrames: poseFrames
        )
    }

    private func computeMetrics(
        poseFrames: [PoseFrame],
        contactFrameIndex: Int,
        ballTrackPoints: [BallTrackPoint]
    ) -> [AnalysisMetric] {
        var metrics: [AnalysisMetric] = []

        if let contactPoint = computeContactPoint(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex) {
            metrics.append(contactPoint)
        }
        if let balance = computeBalanceAtContact(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex) {
            metrics.append(balance)
        }
        if let followThrough = computeFollowThroughDirection(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex) {
            metrics.append(followThrough)
        }
        if let rotation = computeBodyRotation(poseFrames: poseFrames, contactFrameIndex: contactFrameIndex) {
            metrics.append(rotation)
        }

        return metrics
    }

    private func computeContactPoint(poseFrames: [PoseFrame], contactFrameIndex: Int) -> AnalysisMetric? {
        guard let contactFrame = poseFrames.first(where: { $0.frameIndex >= contactFrameIndex }) else { return nil }

        guard let wrist = contactFrame.rightWrist ?? contactFrame.leftWrist,
              let hip = contactFrame.rightHip ?? contactFrame.leftHip,
              wrist.confidence > 0.4, hip.confidence > 0.4 else { return nil }

        let relativeX = wrist.x - hip.x
        let relativeY = wrist.y - hip.y
        let position = relativeX > 0.05 ? "in front" : relativeX < -0.05 ? "behind" : "even"
        let height = relativeY > 0.15 ? "high" : relativeY < -0.05 ? "low" : "optimal"

        return AnalysisMetric(
            name: "Contact Point",
            value: Double(relativeX),
            unit: "",
            confidence: min(wrist.confidence, hip.confidence),
            displayValue: "\(height), \(position)"
        )
    }

    private func computeBalanceAtContact(poseFrames: [PoseFrame], contactFrameIndex: Int) -> AnalysisMetric? {
        guard let contactFrame = poseFrames.first(where: { $0.frameIndex >= contactFrameIndex }) else { return nil }

        guard let leftAnkle = contactFrame.leftAnkle, let rightAnkle = contactFrame.rightAnkle,
              let leftHip = contactFrame.leftHip, let rightHip = contactFrame.rightHip else { return nil }

        let ankleMidX = (leftAnkle.x + rightAnkle.x) / 2.0
        let hipMidX = (leftHip.x + rightHip.x) / 2.0
        let offset = abs(hipMidX - ankleMidX)
        let balance = max(0.0, 1.0 - Double(offset) * 5.0) * 100.0

        let confidence = Float(min(leftAnkle.confidence, min(rightAnkle.confidence, min(leftHip.confidence, rightHip.confidence))))

        return AnalysisMetric(
            name: "Balance at Contact",
            value: balance,
            unit: "%",
            confidence: confidence,
            displayValue: String(format: "%.0f%%", balance)
        )
    }

    private func computeFollowThroughDirection(poseFrames: [PoseFrame], contactFrameIndex: Int) -> AnalysisMetric? {
        let postContactFrames = poseFrames.filter { $0.frameIndex > contactFrameIndex }
        guard postContactFrames.count >= 3 else { return nil }

        let first = postContactFrames[0]
        let last = postContactFrames[min(postContactFrames.count - 1, 5)]

        guard let fw = first.rightWrist ?? first.leftWrist,
              let lw = last.rightWrist ?? last.leftWrist,
              fw.confidence > 0.3, lw.confidence > 0.3 else { return nil }

        let dx = lw.x - fw.x
        let dy = lw.y - fw.y
        let angleDeg = atan2(Double(dy), Double(dx)) * 180.0 / .pi

        let direction: String
        switch angleDeg {
        case -45..<45: direction = "across body"
        case 45..<135: direction = "upward"
        case -135..<(-45): direction = "downward"
        default: direction = "across body"
        }

        return AnalysisMetric(
            name: "Follow-through",
            value: angleDeg,
            unit: "°",
            confidence: min(fw.confidence, lw.confidence),
            displayValue: direction
        )
    }

    private func computeBodyRotation(poseFrames: [PoseFrame], contactFrameIndex: Int) -> AnalysisMetric? {
        guard let addressFrame = poseFrames.first,
              let contactFrame = poseFrames.first(where: { $0.frameIndex >= contactFrameIndex }) else { return nil }

        func shoulderAngle(_ frame: PoseFrame) -> Double? {
            guard let ls = frame.leftShoulder, let rs = frame.rightShoulder,
                  ls.confidence > 0.4, rs.confidence > 0.4 else { return nil }
            return atan2(Double(rs.y - ls.y), Double(rs.x - ls.x)) * 180.0 / .pi
        }

        guard let a1 = shoulderAngle(addressFrame), let a2 = shoulderAngle(contactFrame) else { return nil }

        var rotation = abs(a2 - a1)
        if rotation > 180 { rotation = 360 - rotation }

        return AnalysisMetric(
            name: "Body Rotation",
            value: rotation,
            unit: "°",
            confidence: 0.55,
            displayValue: String(format: "%.0f°", rotation)
        )
    }
}
