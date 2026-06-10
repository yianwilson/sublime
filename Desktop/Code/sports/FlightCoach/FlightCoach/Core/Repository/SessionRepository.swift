import Foundation
import SwiftData

@MainActor
final class SessionRepository: ObservableObject {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func save(_ session: PracticeSession) throws {
        modelContext.insert(session)
        try modelContext.save()
    }

    func update() throws {
        try modelContext.save()
    }

    func delete(_ session: PracticeSession) throws {
        if let videoPath = session.videoLocalPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: videoPath))
        }
        if let processedPath = session.processedVideoLocalPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: processedPath))
        }
        if let thumbPath = session.thumbnailLocalPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: thumbPath))
        }
        modelContext.delete(session)
        try modelContext.save()
    }

    func fetchAll(sport: SportType? = nil) throws -> [PracticeSession] {
        var descriptor = FetchDescriptor<PracticeSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let sport {
            descriptor.predicate = #Predicate { $0.sport == sport.rawValue }
        }
        return try modelContext.fetch(descriptor)
    }

    func fetch(id: UUID) throws -> PracticeSession? {
        let descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }
}
