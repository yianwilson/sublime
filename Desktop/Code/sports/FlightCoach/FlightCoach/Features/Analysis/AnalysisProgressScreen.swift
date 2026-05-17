import SwiftUI
import SwiftData

struct AnalysisProgressScreen: View {
    let session: PracticeSession

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pipeline = AnalysisPipeline()
    @State private var didStart = false
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: session.sportType == .golf ? "figure.golf" : "figure.tennis")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Analysing Video")
                .font(.title2.bold())

            progressContent

            Spacer()

            Text("This happens entirely on your device.\nNo data leaves your iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
        }
        .navigationTitle("Processing")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .task {
            guard !didStart else { return }
            didStart = true
            await pipeline.run(session: session)
        }
        .onChange(of: pipeline.progress) { _, newProgress in
            switch newProgress {
            case .done(let result):
                session.analysisResult = result
                try? modelContext.save()
                // Dismiss back to AnalysisResultScreen — it holds the same session
                // reference and will reflect the updated analysisResult immediately.
                dismiss()
            case .failed(let msg):
                failureMessage = msg
            default:
                break
            }
        }
    }

    private var progressContent: some View {
        VStack(spacing: 16) {
            switch pipeline.progress {
            case .extractingFrames(let p):
                ProgressRow(label: "Extracting frames", progress: p, isActive: true)
                ProgressRow(label: "Detecting pose", progress: 0, isActive: false)
                ProgressRow(label: "Tracking ball", progress: 0, isActive: false)
                ProgressRow(label: "Computing metrics", progress: 0, isActive: false)

            case .detectingPose(let p):
                ProgressRow(label: "Extracting frames", progress: 1, isActive: false)
                ProgressRow(label: "Detecting pose", progress: p, isActive: true)
                ProgressRow(label: "Tracking ball", progress: 0, isActive: false)
                ProgressRow(label: "Computing metrics", progress: 0, isActive: false)

            case .trackingBall(let p):
                ProgressRow(label: "Extracting frames", progress: 1, isActive: false)
                ProgressRow(label: "Detecting pose", progress: 1, isActive: false)
                ProgressRow(label: "Tracking ball", progress: p, isActive: true)
                ProgressRow(label: "Computing metrics", progress: 0, isActive: false)

            case .detectingContact, .computing:
                ProgressRow(label: "Extracting frames", progress: 1, isActive: false)
                ProgressRow(label: "Detecting pose", progress: 1, isActive: false)
                ProgressRow(label: "Tracking ball", progress: 1, isActive: false)
                ProgressRow(label: "Computing metrics", progress: 0, isActive: true)

            case .done:
                ProgressRow(label: "Extracting frames", progress: 1, isActive: false)
                ProgressRow(label: "Detecting pose", progress: 1, isActive: false)
                ProgressRow(label: "Tracking ball", progress: 1, isActive: false)
                ProgressRow(label: "Computing metrics", progress: 1, isActive: false)

            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Analysis failed")
                        .font(.headline)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.horizontal, 32)
    }
}

struct ProgressRow: View {
    let label: String
    let progress: Double
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(isActive ? .primary : .secondary)
                Spacer()
                if progress >= 1 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isActive {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            if isActive {
                ProgressView(value: progress)
                    .tint(.green)
            } else if progress >= 1 {
                ProgressView(value: 1.0)
                    .tint(.green)
                    .opacity(0.4)
            }
        }
    }
}
