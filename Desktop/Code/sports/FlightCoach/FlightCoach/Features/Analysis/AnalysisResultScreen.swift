import SwiftUI
import SwiftData
import AVFoundation

struct AnalysisResultScreen: View {
    let session: PracticeSession

    @Environment(\.modelContext) private var modelContext
    @State private var navigateToAnalysis = false
    @State private var showManualCorrection = false
    @State private var showDeleteConfirm = false
    @State private var videoAspectRatio: CGFloat?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                videoSection
                    .frame(height: 280)

                actionBar

                if let result = session.analysisResult {
                    resultContent(result: result)
                } else {
                    pendingAnalysisPrompt
                }
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showManualCorrection = true } label: {
                        Label("Manual Corrections", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(isPresented: $navigateToAnalysis) {
            AnalysisProgressScreen(session: session)
        }
        .sheet(isPresented: $showManualCorrection) {
            ManualCorrectionSheet(session: session)
        }
        .task {
            videoAspectRatio = await loadVideoAspectRatio()
        }
        .confirmationDialog("Delete this session?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The video and all analysis data will be permanently removed.")
        }
    }

    private var videoSection: some View {
        ZStack {
            VideoPlayerView(session: session)

            if let result = session.analysisResult {
                GeometryReader { geo in
                    let contactIndex = session.effectiveContactFrameIndex
                    BallTrailOverlayView(
                        trackPoints: result.ballTrackPoints,
                        highlightFrameIndex: contactIndex,
                        videoAspectRatio: videoAspectRatio
                    )
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            sessionInfo

            Spacer()

            if session.analysisResult == nil {
                Button {
                    navigateToAnalysis = true
                } label: {
                    Label("Analyse", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            } else {
                Button {
                    navigateToAnalysis = true
                } label: {
                    Label("Re-analyse", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var sessionInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.sportType.displayName + " · " + session.mode.capitalized)
                .font(.subheadline.weight(.semibold))
            Text(session.cameraAngleEnum.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resultContent(result: AnalysisResult) -> some View {
        VStack(spacing: 0) {
            if let golf = golfResult(from: result) {
                GolfResultSection(result: golf, session: session)
            } else if let tennis = tennisResult(from: result) {
                TennisResultSection(result: tennis, session: session)
            }

            MetricsSection(metrics: result.metrics)
            FeedbackSection(feedbackItems: result.feedback)
        }
    }

    private var pendingAnalysisPrompt: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 40)
            Image(systemName: "wand.and.stars")
                .font(.system(size: 52))
                .foregroundStyle(.green.opacity(0.7))
            Text("Not yet analysed")
                .font(.title3.weight(.semibold))
            Text("Tap Analyse to run local pose detection, ball tracking, and feedback generation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                navigateToAnalysis = true
            } label: {
                Label("Analyse Now", systemImage: "wand.and.stars")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(.green)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 40)
        }
    }

    private func golfResult(from result: AnalysisResult) -> GolfAnalysisResult? {
        if case .golf(let r) = result { return r }
        return nil
    }

    private func tennisResult(from result: AnalysisResult) -> TennisAnalysisResult? {
        if case .tennis(let r) = result { return r }
        return nil
    }

    private func deleteSession() {
        let repo = SessionRepository(modelContext: modelContext)
        try? repo.delete(session)
        dismiss()
    }

    private func loadVideoAspectRatio() async -> CGFloat? {
        guard let url = VideoStorageService.shared.videoURL(for: session) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return nil
        }

        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        guard width > 0, height > 0 else { return nil }
        return width / height
    }
}

struct GolfResultSection: View {
    let result: GolfAnalysisResult
    let session: PracticeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Golf Analysis", icon: "figure.golf")

            HStack(spacing: 16) {
                ConfidenceBadge(label: "Impact", confidence: result.contactConfidence)
                ShotShapeBadge(shape: result.shotShape, confidence: result.shotShapeConfidence)
            }
            .padding(.horizontal, 20)

            if result.contactConfidence < 0.5 {
                LowConfidenceBanner(message: "Impact frame was estimated. Tap the video and use Manual Corrections to improve accuracy.")
                    .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 16)
    }
}

struct TennisResultSection: View {
    let result: TennisAnalysisResult
    let session: PracticeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Tennis Analysis", icon: "figure.tennis")

            ConfidenceBadge(label: "Contact", confidence: result.contactConfidence)
                .padding(.horizontal, 20)

            if result.contactConfidence < 0.5 {
                LowConfidenceBanner(message: "Contact frame was estimated. Use Manual Corrections to improve accuracy.")
                    .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 16)
    }
}

struct MetricsSection: View {
    let metrics: [AnalysisMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Metrics", icon: "chart.bar.fill")

            if metrics.isEmpty {
                Text("No metrics available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(metrics) { metric in
                        MetricCard(metric: metric)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 16)
    }
}

struct FeedbackSection: View {
    let feedbackItems: [FeedbackItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Feedback", icon: "text.bubble.fill")

            if feedbackItems.isEmpty {
                Text("No feedback available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(feedbackItems) { item in
                        FeedbackCard(item: item)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 16)
        .padding(.bottom, 40)
    }
}
