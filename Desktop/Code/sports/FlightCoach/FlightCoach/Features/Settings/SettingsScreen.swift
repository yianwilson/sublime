import SwiftUI
import SwiftData
import UIKit

struct SettingsScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sessions: [PracticeSession]
    @State private var showClearConfirm = false
    @State private var storageText = "Calculating…"
    @State private var trainingExampleCount = 0
    @State private var exportURL: URL?
    @State private var showExport = false
    @AppStorage("collectTrainingData") private var collectTrainingData = false

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Sessions", value: "\(sessions.count)")
                LabeledContent("Video storage", value: storageText)

                Button("Delete All Sessions", role: .destructive) {
                    showClearConfirm = true
                }
            }

            Section {
                Toggle("Collect training data", isOn: $collectTrainingData)
                LabeledContent("Labeled ball taps", value: "\(trainingExampleCount)")
                Button {
                    exportURL = TrainingDataService.shared.exportArchive()
                    showExport = exportURL != nil
                } label: {
                    Label("Export dataset (.zip)", systemImage: "square.and.arrow.up")
                }
                .disabled(trainingExampleCount == 0)
            } header: {
                Text("Training Data (Core ML)")
            } footer: {
                Text("Each ball tap is saved as a labeled example. Export and pull it to a Mac to train the detector. \u{26A0}\u{FE0F} This lives in app storage — export before deleting/reinstalling the app or it's lost.")
            }

            Section("Analysis") {
                LabeledContent("Processing", value: "On-device only")
                LabeledContent("Cloud upload", value: "Never")
                LabeledContent("Login required", value: "No")
            }

            Section("About") {
                LabeledContent("Version", value: "1.0")
                LabeledContent("Framework", value: "Apple Vision + Core ML")
                LabeledContent("Supported sport", value: "Golf beta")

                Link("Privacy: No data leaves your device", destination: URL(string: "https://example.com/flightcoach/privacy")!)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Limitations") {
                limitationRow("Ball speed unavailable", "Requires calibrated hardware or a launch monitor")
                limitationRow("No carry distance", "GPS or launch monitor required")
                limitationRow("No spin rate", "Requires specialist hardware")
                limitationRow("Approximate metrics", "All values include confidence scores")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            updateStorageInfo()
            trainingExampleCount = TrainingDataService.shared.exampleCount
        }
        .sheet(isPresented: $showExport) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
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

/// Wraps `UIActivityViewController` so the dataset zip can be AirDropped / saved to Files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
