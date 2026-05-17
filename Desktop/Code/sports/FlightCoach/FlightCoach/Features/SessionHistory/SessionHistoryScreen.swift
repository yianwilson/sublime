import SwiftUI
import SwiftData
import UIKit

struct SessionHistoryScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeSession.createdAt, order: .reverse) private var sessions: [PracticeSession]
    @State private var filterSport: SportType? = nil
    @State private var sessionToDelete: PracticeSession?

    var filteredSessions: [PracticeSession] {
        guard let sport = filterSport else { return sessions }
        return sessions.filter { $0.sport == sport.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            sportFilter

            if filteredSessions.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filteredSessions) { session in
                        NavigationLink(destination: AnalysisResultScreen(session: session)) {
                            SessionListRow(session: session)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                sessionToDelete = session
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Session History")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("Delete session?", isPresented: .constant(sessionToDelete != nil), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = sessionToDelete { deleteSession(s) }
                sessionToDelete = nil
            }
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
        }
    }

    private var sportFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                FilterChip(title: "All", isSelected: filterSport == nil) { filterSport = nil }
                ForEach(SportType.allCases) { sport in
                    FilterChip(title: sport.displayName, isSelected: filterSport == sport) {
                        filterSport = sport
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.title3.weight(.semibold))
            Text("Record or import a video to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func deleteSession(_ session: PracticeSession) {
        let repo = SessionRepository(modelContext: modelContext)
        try? repo.delete(session)
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.green : Color(.secondarySystemGroupedBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SessionListRow: View {
    let session: PracticeSession

    var body: some View {
        HStack(spacing: 14) {
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
                Text(session.sportType.displayName + " · " + session.mode.capitalized)
                    .font(.subheadline.weight(.semibold))
                Text(session.cameraAngleEnum.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if session.analysisResult != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption2)
                    }
                }
            }
            Spacer()
            Text(formatDuration(session.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var thumbnailView: some View {
        Group {
            if let path = session.thumbnailLocalPath,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: session.sportType.iconName)
                    .font(.title2)
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 60, height: 44)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func formatDuration(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
