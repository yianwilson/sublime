import Foundation
import SwiftData

@Model
final class PracticeSession {
    @Attribute(.unique) var id: UUID
    var sport: String
    var mode: String
    var cameraAngle: String
    var handedness: String = Handedness.rightHanded.rawValue
    var createdAt: Date
    var videoLocalPath: String?
    var processedVideoLocalPath: String?
    var thumbnailLocalPath: String?
    var durationSeconds: Double
    var analysisResultData: Data?
    var manualCorrectionData: Data?
    var notes: String

    init(
        sport: SportType,
        mode: String,
        cameraAngle: CameraAngle,
        handedness: Handedness = .rightHanded,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.sport = sport.rawValue
        self.mode = mode
        self.cameraAngle = cameraAngle.rawValue
        self.handedness = handedness.rawValue
        self.createdAt = createdAt
        self.durationSeconds = 0
        self.notes = ""
    }

    var sportType: SportType {
        SportType(rawValue: sport) ?? .golf
    }

    var cameraAngleEnum: CameraAngle {
        CameraAngle(rawValue: cameraAngle) ?? .unknown
    }

    var handednessEnum: Handedness {
        Handedness(rawValue: handedness) ?? .rightHanded
    }

    /// Handedness to use for analysis, honouring any manual correction.
    var effectiveHandedness: Handedness {
        manualCorrection?.correctedHandedness ?? handednessEnum
    }

    var analysisResult: AnalysisResult? {
        get {
            guard let data = analysisResultData else { return nil }
            return try? JSONDecoder().decode(AnalysisResult.self, from: data)
        }
        set {
            analysisResultData = try? JSONEncoder().encode(newValue)
        }
    }

    var manualCorrection: ManualCorrection? {
        get {
            guard let data = manualCorrectionData else { return nil }
            return try? JSONDecoder().decode(ManualCorrection.self, from: data)
        }
        set {
            manualCorrectionData = try? JSONEncoder().encode(newValue)
        }
    }

    var effectiveContactFrameIndex: Int? {
        manualCorrection?.correctedContactFrame ?? analysisResult?.contactFrameIndex
    }

    var displayTitle: String {
        let sport = sportType.displayName
        let modeDisplay = mode.capitalized
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(sport) · \(modeDisplay) · \(formatter.string(from: createdAt))"
    }
}
