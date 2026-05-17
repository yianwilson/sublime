import SwiftUI
import SwiftData

struct SettingsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sessions: [PracticeSession]
    @State private var showClearConfirm = false
    @State private var storageText = "Calculating…"

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Sessions", value: "\(sessions.count)")
                LabeledContent("Video storage", value: storageText)

                Button("Delete All Sessions", role: .destructive) {
                    showClearConfirm = true
                }
            }

            Section("Analysis") {
                LabeledContent("Processing", value: "On-device only")
                LabeledContent("Cloud upload", value: "Never")
                LabeledContent("Login required", value: "No")
            }

            Section("About") {
                LabeledContent("Version", value: "1.0")
                LabeledContent("Framework", value: "Apple Vision + Core ML")
                LabeledContent("Supported sports", value: "Golf · Tennis")

                Link("Privacy: No data leaves your device", destination: URL(string: "https://apple.com")!)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Limitations") {
                limitationRow("Ball speed not measured", "2D image-space tracking only")
                limitationRow("No carry distance", "GPS or launch monitor required")
                limitationRow("No spin rate", "Requires specialist hardware")
                limitationRow("Approximate metrics", "All values include confidence scores")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { updateStorageInfo() }
        .confirmationDialog("Delete all sessions?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { deleteAllSessions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All videos and analysis data will be permanently removed. This cannot be undone.")
        }
    }

    private func limitationRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: "xmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 26)
        }
    }

    private func updateStorageInfo() {
        let bytes = VideoStorageService.shared.totalStorageUsed()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        storageText = formatter.string(fromByteCount: bytes)
    }

    private func deleteAllSessions() {
        let repo = SessionRepository(modelContext: modelContext)
        for session in sessions {
            try? repo.delete(session)
        }
        updateStorageInfo()
    }
}
