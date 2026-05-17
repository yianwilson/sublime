import Foundation

final class FeedbackEngine {
    static let shared = FeedbackEngine()

    private init() {}

    // MARK: - Golf

    func golfFeedback(
        metrics: [AnalysisMetric],
        shotShape: ShotShape,
        shotShapeConfidence: Float,
        cameraAngle: CameraAngle,
        contactConfidence: Float
    ) -> [FeedbackItem] {
        var items: [FeedbackItem] = []

        if contactConfidence < 0.4 {
            items.append(FeedbackItem(
                title: "Low Detection Confidence",
                detail: "Impact frame was estimated, not detected directly. Results may be less accurate.",
                severity: .warning,
                confidence: contactConfidence
            ))
        }

        items += tempoFeedback(metrics: metrics)
        items += headMovementFeedback(metrics: metrics)
        items += spineAngleFeedback(metrics: metrics)
        items += hipSwayFeedback(metrics: metrics)
        items += balanceFeedback(metrics: metrics)
        items += ballSpeedFeedback(metrics: metrics)
        items += shotShapeFeedback(shape: shotShape, confidence: shotShapeConfidence, cameraAngle: cameraAngle)

        return items
    }

    private func tempoFeedback(metrics: [AnalysisMetric]) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Tempo Ratio" }) else { return [] }
        guard !metric.isLowConfidence else {
            return [FeedbackItem(title: "Tempo", detail: "Not enough data to measure tempo accurately.", severity: .info, confidence: metric.confidence)]
        }

        let ratio = metric.value
        if ratio < 2.0 {
            return [FeedbackItem(title: "Tempo: Too Fast", detail: "Your backswing-to-downswing ratio of \(metric.displayValue) suggests a rushed transition. Aim for 3:1.", severity: .warning, confidence: metric.confidence, metricName: "Tempo Ratio")]
        } else if ratio > 4.5 {
            return [FeedbackItem(title: "Tempo: Very Slow Backswing", detail: "Ratio of \(metric.displayValue) is unusually slow. Check you maintained swing rhythm.", severity: .info, confidence: metric.confidence, metricName: "Tempo Ratio")]
        } else {
            return [FeedbackItem(title: "Tempo: Good Rhythm", detail: "Backswing-to-downswing ratio of \(metric.displayValue) is in a solid range.", severity: .positive, confidence: metric.confidence, metricName: "Tempo Ratio")]
        }
    }

    private func headMovementFeedback(metrics: [AnalysisMetric]) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Head Movement" }) else { return [] }
        guard !metric.isLowConfidence else { return [] }

        if metric.value > 0.05 {
            return [FeedbackItem(title: "Head Movement: Keep Still", detail: "Head moved \(metric.displayValue) from address to impact. Minimise lateral head drift for better contact.", severity: .warning, confidence: metric.confidence, metricName: "Head Movement")]
        } else {
            return [FeedbackItem(title: "Head Stable", detail: "Head stayed well-centred through the swing.", severity: .positive, confidence: metric.confidence, metricName: "Head Movement")]
        }
    }

    private func spineAngleFeedback(metrics: [AnalysisMetric]) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Spine Angle Change" }) else { return [] }
        guard !metric.isLowConfidence else { return [] }

        if metric.value > 15.0 {
            return [FeedbackItem(title: "Spine Angle: Early Extension", detail: "Spine angle changed by \(metric.displayValue). Try to maintain your original spine angle through impact.", severity: .warning, confidence: metric.confidence, metricName: "Spine Angle Change")]
        } else {
            return [FeedbackItem(title: "Spine Angle Maintained", detail: "Spine stayed consistent through the swing — solid fundamentals.", severity: .positive, confidence: metric.confidence, metricName: "Spine Angle Change")]
        }
    }

    private func hipSwayFeedback(metrics: [AnalysisMetric]) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Hip Sway" }) else { return [] }
        guard !metric.isLowConfidence else { return [] }

        if metric.value > 0.06 {
            return [FeedbackItem(title: "Hip Sway Detected", detail: "Hips moved \(metric.displayValue) laterally. Focus on hip rotation rather than sliding.", severity: .warning, confidence: metric.confidence, metricName: "Hip Sway")]
        } else {
            return [FeedbackItem(title: "Hip Control: Good", detail: "Minimal lateral hip movement detected.", severity: .positive, confidence: metric.confidence, metricName: "Hip Sway")]
        }
    }

    private func balanceFeedback(metrics: [AnalysisMetric]) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Balance at Finish" }) else { return [] }
        guard !metric.isLowConfidence else { return [] }

        if metric.value < 60 {
            return [FeedbackItem(title: "Finish Balance: Off", detail: "Balance score of \(metric.displayValue) at finish. Work on a full, controlled follow-through.", severity: .warning, confidence: metric.confidence, metricName: "Balance at Finish")]
        } else {
            return [FeedbackItem(title: "Strong Finish", detail: "Balance of \(metric.displayValue) at finish — well controlled.", severity: .positive, confidence: metric.confidence, metricName: "Balance at Finish")]
        }
    }

    private func ballSpeedFeedback(metrics: [AnalysisMetric]) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Ball Speed" }) else { return [] }
        guard metric.displayValue != "Unknown" else {
            return [FeedbackItem(title: "Ball Speed Unknown", detail: "Ball speed needs a stable launch track. The current trail is too weak or ambiguous to estimate speed.", severity: .info, confidence: metric.confidence, metricName: "Ball Speed")]
        }
        let qualifier = metric.isLowConfidence ? "rough estimate" : "estimate"
        return [FeedbackItem(title: "Ball Speed", detail: "\(metric.displayValue) \(qualifier) from image-space launch movement. Use a launch monitor for measured speed.", severity: .info, confidence: metric.confidence, metricName: "Ball Speed")]
    }

    private func shotShapeFeedback(shape: ShotShape, confidence: Float, cameraAngle: CameraAngle) -> [FeedbackItem] {
        if cameraAngle != .behindBallFlight {
            return [FeedbackItem(title: "Shot Shape", detail: "Set camera angle to 'Behind Ball Flight' for shot shape analysis.", severity: .info, confidence: 1.0)]
        }
        guard confidence >= 0.45 else {
            return [FeedbackItem(title: "Shot Shape: Unknown", detail: "Shot shape was not reliable enough to call from the ball trail. A diagonal or short trail is treated as weak evidence.", severity: .info, confidence: confidence)]
        }

        switch shape {
        case .straight:
            return [FeedbackItem(title: "Shot Shape: Straight", detail: "Ball tracked a straight flight line.", severity: .positive, confidence: confidence)]
        case .fadeOrSlice:
            return [FeedbackItem(title: "Shot Shape: Fade / Slice", detail: "Ball curved left-to-right (for right-handed player). Check club path and face angle at impact.", severity: .info, confidence: confidence)]
        case .drawOrHook:
            return [FeedbackItem(title: "Shot Shape: Draw / Hook", detail: "Ball curved right-to-left (for right-handed player). Club path may be too far inside-out.", severity: .info, confidence: confidence)]
        case .unknown:
            return [FeedbackItem(title: "Shot Shape: Unknown", detail: "Ball could not be tracked well enough to determine shot shape.", severity: .info, confidence: 0.2)]
        }
    }

    // MARK: - Tennis

    func tennisFeedback(
        metrics: [AnalysisMetric],
        mode: TennisMode,
        contactConfidence: Float
    ) -> [FeedbackItem] {
        var items: [FeedbackItem] = []

        if contactConfidence < 0.4 {
            items.append(FeedbackItem(
                title: "Low Detection Confidence",
                detail: "Contact frame was estimated. Metrics may be less accurate.",
                severity: .warning,
                confidence: contactConfidence
            ))
        }

        items += tennisContactPointFeedback(metrics: metrics, mode: mode)
        items += tennisBalanceFeedback(metrics: metrics)
        items += tennisFollowThroughFeedback(metrics: metrics, mode: mode)
        items += tennisRotationFeedback(metrics: metrics, mode: mode)

        return items
    }

    private func tennisContactPointFeedback(metrics: [AnalysisMetric], mode: TennisMode) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Contact Point" }) else { return [] }

        if metric.isLowConfidence {
            return [FeedbackItem(title: "Contact Point", detail: "Pose confidence too low to measure contact point accurately.", severity: .info, confidence: metric.confidence)]
        }

        let position = metric.displayValue
        if position.contains("behind") {
            return [FeedbackItem(title: "Late Contact", detail: "Contact point detected behind your body. Try to meet the ball earlier in front of your hip.", severity: .warning, confidence: metric.confidence, metricName: "Contact Point")]
        } else if position.contains("high") {
            return [FeedbackItem(title: "High Contact", detail: "Contact point appears elevated. For baseline strokes, aim for a waist-to-shoulder height sweet spot.", severity: .info, confidence: metric.confidence, metricName: "Contact Point")]
        } else {
            return [FeedbackItem(title: "Contact Point: Good", detail: "Contact point in a solid forward and optimal height position.", severity: .positive, confidence: metric.confidence, metricName: "Contact Point")]
        }
    }

    private func tennisBalanceFeedback(metrics: [AnalysisMetric]) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Balance at Contact" }) else { return [] }
        guard !metric.isLowConfidence else { return [] }

        if metric.value < 55 {
            return [FeedbackItem(title: "Balance: Unstable at Contact", detail: "Balance of \(metric.displayValue) at contact. Work on a stable base before striking.", severity: .warning, confidence: metric.confidence, metricName: "Balance at Contact")]
        } else {
            return [FeedbackItem(title: "Balanced Contact", detail: "Good base stability at contact (\(metric.displayValue)).", severity: .positive, confidence: metric.confidence, metricName: "Balance at Contact")]
        }
    }

    private func tennisFollowThroughFeedback(metrics: [AnalysisMetric], mode: TennisMode) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Follow-through" }) else { return [] }
        guard !metric.isLowConfidence else { return [] }

        let direction = metric.displayValue
        if mode == .serve && direction.contains("downward") {
            return [FeedbackItem(title: "Follow-through: Short", detail: "Serve follow-through appears to cut short. Let the arm swing across your body fully.", severity: .warning, confidence: metric.confidence, metricName: "Follow-through")]
        } else if direction.contains("upward") {
            return [FeedbackItem(title: "Follow-through: Upward", detail: "Good topspin follow-through direction.", severity: .positive, confidence: metric.confidence, metricName: "Follow-through")]
        } else {
            return [FeedbackItem(title: "Follow-through", detail: "Follow-through direction: \(direction).", severity: .info, confidence: metric.confidence, metricName: "Follow-through")]
        }
    }

    private func tennisRotationFeedback(metrics: [AnalysisMetric], mode: TennisMode) -> [FeedbackItem] {
        guard let metric = metrics.first(where: { $0.name == "Body Rotation" }) else { return [] }
        guard !metric.isLowConfidence else { return [] }

        if metric.value < 25 {
            return [FeedbackItem(title: "Limited Rotation", detail: "Body rotation of \(metric.displayValue) detected. More shoulder turn through the shot will generate more power.", severity: .warning, confidence: metric.confidence, metricName: "Body Rotation")]
        } else {
            return [FeedbackItem(title: "Good Body Rotation", detail: "\(metric.displayValue) of shoulder rotation — using the kinetic chain well.", severity: .positive, confidence: metric.confidence, metricName: "Body Rotation")]
        }
    }
}
