import Foundation

struct AnalysisMetric: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let value: Double
    let unit: String
    let confidence: Float
    let displayValue: String

    init(name: String, value: Double, unit: String, confidence: Float, displayValue: String) {
        self.id = UUID()
        self.name = name
        self.value = value
        self.unit = unit
        self.confidence = confidence
        self.displayValue = displayValue
    }

    var isLowConfidence: Bool { confidence < 0.5 }
}

enum FeedbackSeverity: String, Codable, Equatable {
    case info
    case warning
    case positive
}

struct FeedbackItem: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let detail: String
    let severity: FeedbackSeverity
    let confidence: Float
    let metricName: String?

    init(title: String, detail: String, severity: FeedbackSeverity, confidence: Float, metricName: String? = nil) {
        self.id = UUID()
        self.title = title
        self.detail = detail
        self.severity = severity
        self.confidence = confidence
        self.metricName = metricName
    }

    var isLowConfidence: Bool { confidence < 0.5 }
}

struct GolfAnalysisResult: Codable, Equatable {
    let contactFrameIndex: Int
    let contactConfidence: Float
    let shotShape: ShotShape
    let shotShapeConfidence: Float
    let ballTrackPoints: [BallTrackPoint]
    let metrics: [AnalysisMetric]
    let feedback: [FeedbackItem]
    let poseFrames: [PoseFrame]
}

struct TennisAnalysisResult: Codable, Equatable {
    let contactFrameIndex: Int
    let contactConfidence: Float
    let ballTrackPoints: [BallTrackPoint]
    let metrics: [AnalysisMetric]
    let feedback: [FeedbackItem]
    let poseFrames: [PoseFrame]
}

enum AnalysisResult: Codable, Equatable {
    case golf(GolfAnalysisResult)
    case tennis(TennisAnalysisResult)
    case pending
    case failed(String)

    var metrics: [AnalysisMetric] {
        switch self {
        case .golf(let r): return r.metrics
        case .tennis(let r): return r.metrics
        default: return []
        }
    }

    var feedback: [FeedbackItem] {
        switch self {
        case .golf(let r): return r.feedback
        case .tennis(let r): return r.feedback
        default: return []
        }
    }

    var contactFrameIndex: Int? {
        switch self {
        case .golf(let r): return r.contactFrameIndex
        case .tennis(let r): return r.contactFrameIndex
        default: return nil
        }
    }

    var ballTrackPoints: [BallTrackPoint] {
        switch self {
        case .golf(let r): return r.ballTrackPoints
        case .tennis(let r): return r.ballTrackPoints
        default: return []
        }
    }

    var poseFrames: [PoseFrame] {
        switch self {
        case .golf(let r): return r.poseFrames
        case .tennis(let r): return r.poseFrames
        default: return []
        }
    }
}

struct ManualCorrection: Codable, Identifiable, Equatable {
    let id: UUID
    var correctedContactFrame: Int?
    var correctedShotType: String?
    var correctedCameraAngle: CameraAngle?
    let correctedAt: Date

    init(correctedContactFrame: Int? = nil, correctedShotType: String? = nil, correctedCameraAngle: CameraAngle? = nil) {
        self.id = UUID()
        self.correctedContactFrame = correctedContactFrame
        self.correctedShotType = correctedShotType
        self.correctedCameraAngle = correctedCameraAngle
        self.correctedAt = Date()
    }
}
