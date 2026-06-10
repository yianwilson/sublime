import Foundation

@MainActor
final class ManualCorrectionService: ObservableObject {
    private let repository: SessionRepository

    init(repository: SessionRepository) {
        self.repository = repository
    }

    func applyContactFrameCorrection(to session: PracticeSession, frameIndex: Int) throws {
        var correction = session.manualCorrection ?? ManualCorrection()
        correction.correctedContactFrame = frameIndex
        session.manualCorrection = correction
        try repository.update()
    }

    func applyShotTypeCorrection(to session: PracticeSession, shotType: String) throws {
        var correction = session.manualCorrection ?? ManualCorrection()
        correction.correctedShotType = shotType
        session.manualCorrection = correction
        try repository.update()
    }

    func applyCameraAngleCorrection(to session: PracticeSession, angle: CameraAngle) throws {
        var correction = session.manualCorrection ?? ManualCorrection()
        correction.correctedCameraAngle = angle
        session.manualCorrection = correction
        try repository.update()
    }

    func applyManualBallTrace(to session: PracticeSession, points: [BallTrackPoint]) throws {
        var correction = session.manualCorrection ?? ManualCorrection()
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        correction.manualBallTrackPoints = sorted
        correction.manualTraceSeedFrame = sorted.first?.frameIndex
        session.manualCorrection = correction
        VideoStorageService.shared.deleteProcessedVideo(for: session)
        try repository.update()
    }

    func clearManualBallTrace(for session: PracticeSession) throws {
        var correction = session.manualCorrection ?? ManualCorrection()
        correction.manualBallTrackPoints = []
        correction.manualTraceSeedFrame = nil
        session.manualCorrection = correction
        VideoStorageService.shared.deleteProcessedVideo(for: session)
        try repository.update()
    }

    func resetCorrections(for session: PracticeSession) throws {
        session.manualCorrectionData = nil
        try repository.update()
    }
}
