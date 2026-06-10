import SwiftUI
import SwiftData
import AVFoundation
import UIKit

struct AnalysisResultScreen: View {
    let session: PracticeSession

    @Environment(\.modelContext) private var modelContext
    @State private var navigateToAnalysis = false
    @State private var showManualCorrection = false
    @State private var showDeleteConfirm = false
    @State private var videoAspectRatio: CGFloat?
    @State private var videoFrameRate: Double = 60
    @State private var showPoseDebug = false
    @State private var isEditingTrace = false
    @State private var isRetracing = false
    @State private var retraceMessage: String?
    @State private var currentPlayTime: TimeInterval = 0
    @State private var traceEditTime: TimeInterval = 0
    @State private var tracePreviewImage: UIImage?
    @State private var tracePreviewTask: Task<Void, Never>?
    @State private var showBallCandidates = false
    @State private var candidateDebugReport: BallCandidateDebugReport?
    @State private var isExportingTrace = false
    @State private var exportMessage: String?
    @State private var showFullScreen = false
    @State private var showTracerDebug = false
    @State private var tracerDebugDots: [TracerDebugDot] = []
    @State private var lastDebugFrame = -1
    @State private var tracerDebugTask: Task<Void, Never>?
    @AppStorage("collectTrainingData") private var collectTrainingData = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                videoSection
                    .frame(height: 280)

                if isEditingTrace {
                    traceEditorBar
                }

                if let retraceMessage {
                    Text(retraceMessage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.08))
                }

                actionBar

                if session.sportType == .golf {
                    traceStatusBanner
                }

                if showTracerDebug {
                    tracerDebugBanner
                }

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
                Button {
                    showFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Full screen video")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if session.sportType == .golf {
                        Button {
                            toggleTraceEditing()
                        } label: {
                            Label(isEditingTrace ? "Done Editing Ball Trace" : "Edit Ball Trace", systemImage: "scope")
                        }
                    }
                    Button { showManualCorrection = true } label: {
                        Label("Manual Corrections", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        showTracerDebug.toggle()
                        if showTracerDebug { lastDebugFrame = -1; recomputeTracerDebug(at: currentPlayTime) }
                        else { tracerDebugDots = [] }
                    } label: {
                        Label(showTracerDebug ? "Hide Detector Debug" : "Detector Debug", systemImage: "viewfinder")
                    }
                    Divider()
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
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenVideoView(
                session: session,
                trackPoints: displayedBallTrackPoints,
                contactFrameIndex: session.effectiveContactFrameIndex,
                videoAspectRatio: videoAspectRatio
            )
        }
        .task {
            let metadata = await loadVideoMetadata()
            videoAspectRatio = metadata.aspectRatio
            videoFrameRate = metadata.frameRate
        }
        .confirmationDialog("Delete this session?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The video and all analysis data will be permanently removed.")
        }
        .alert("Tracer Export", isPresented: .constant(exportMessage != nil)) {
            Button("OK") { exportMessage = nil }
        } message: {
            if let exportMessage { Text(exportMessage) }
        }
    }

    private var videoSection: some View {
        ZStack {
            VideoPlayerView(session: session, onTimeChange: { t in currentPlayTime = t })
                // While placing the ball, the AVKit player must not swallow taps —
                // let them reach the trace-tap layer on top.
                .allowsHitTesting(!isEditingTrace)

            if isEditingTrace, let tracePreviewImage {
                TraceFramePreview(image: tracePreviewImage, videoAspectRatio: videoAspectRatio)
                    .allowsHitTesting(false)
            }

            if isEditingTrace, showBallCandidates, let candidateDebugReport {
                BallCandidateDebugOverlay(report: candidateDebugReport, videoAspectRatio: videoAspectRatio)
                    .allowsHitTesting(false)
            }

            let tracePoints = displayedBallTrackPoints
            if !tracePoints.isEmpty {
                if tracePoints.count == 1, let point = tracePoints.first {
                    BallTracePointOverlayView(point: point, videoAspectRatio: videoAspectRatio)
                        .allowsHitTesting(false)
                } else {
                    BallTrailOverlayView(
                        trackPoints: tracePoints,
                        highlightFrameIndex: session.effectiveContactFrameIndex,
                        videoAspectRatio: videoAspectRatio,
                        currentTime: isEditingTrace ? nil : currentPlayTime
                    )
                    .allowsHitTesting(false)
                }
            }

            if let result = session.analysisResult {
                if showPoseDebug {
                    let nearestPose = nearestPoseFrame(in: result.poseFrames, at: currentPlayTime)
                    PoseOverlayView(poseFrame: nearestPose, videoAspectRatio: videoAspectRatio)
                        .allowsHitTesting(false)
                    PoseDebugOverlay(debug: nearestDebugResult(in: result.poseFrames, at: currentPlayTime))
                        .allowsHitTesting(false)
                }
            }

            if showTracerDebug, !tracerDebugDots.isEmpty {
                TracerDebugOverlay(dots: tracerDebugDots, videoAspectRatio: videoAspectRatio)
                    .allowsHitTesting(false)
            }

            if isEditingTrace {
                traceTapLayer
            }
        }
        .onChange(of: currentPlayTime) { _, t in
            guard showTracerDebug, !isEditingTrace else { return }
            let frame = Int((t * videoFrameRate).rounded())
            if frame != lastDebugFrame { lastDebugFrame = frame; recomputeTracerDebug(at: t) }
        }
    }

    private var tracerDebugBanner: some View {
        let count = autoBallTrackPoints.count
        let outcome = count >= 4 ? "Tracer: \(count) validated points"
                                 : "Tracer: no valid trace — ball only (spec rejects nonsense)"
        return HStack(spacing: 10) {
            Image(systemName: "viewfinder").foregroundStyle(.cyan).font(.subheadline)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome).font(.caption.weight(.semibold))
                Text("\(tracerDebugDots.count) detector candidates on this frame · cyan boxes = candidates")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 8).background(Color.cyan.opacity(0.08))
    }

    private func recomputeTracerDebug(at time: TimeInterval) {
        tracerDebugTask?.cancel()
        tracerDebugTask = Task {
            guard let image = await loadPreviewImage(at: time), !Task.isCancelled else { return }
            let dots = TracerDebugService.candidates(in: image)
            await MainActor.run { tracerDebugDots = dots }
        }
    }

    private var traceTapLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            addManualTracePoint(at: value.location, in: CGRect(origin: .zero, size: geo.size))
                        }
                )
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(traceInstructionTitle)
                            .font(.caption.weight(.semibold))
                        Text(traceInstructionDetail)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.68))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                }
        }
    }

    private func nearestPoseFrame(in frames: [PoseFrame], at time: TimeInterval) -> PoseFrame? {
        guard !frames.isEmpty else { return nil }
        return frames.min(by: { abs($0.timestamp - time) < abs($1.timestamp - time) })
    }

    private func nearestDebugResult(in frames: [PoseFrame], at time: TimeInterval) -> PoseDebugResult? {
        guard let nearest = nearestPoseFrame(in: frames, at: time) else { return nil }
        return PoseDebugResult(
            frameIndex: nearest.frameIndex,
            timestamp: nearest.timestamp,
            imageWidth: 0, imageHeight: 0,
            landmarkCount: nearest.landmarks.count,
            averageConfidence: nearest.overallConfidence,
            detectedJointNames: nearest.landmarks.map(\.jointName),
            errorMessage: nil,
            didDetectPose: true
        )
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            sessionInfo

            Spacer()

            if session.sportType == .golf, displayedBallTrackPoints.count >= 2 {
                Button {
                    Task { await exportTracerVideo() }
                } label: {
                    Label(isExportingTrace ? "Exporting" : "Export", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.semibold))
                }
                .disabled(isExportingTrace)
            }

            if session.sportType == .golf, let processedURL = VideoStorageService.shared.processedVideoURL(for: session) {
                ShareLink(item: processedURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
            }

            if session.sportType == .golf, initialBallPoint == nil {
                Button {
                    beginTraceEditing()
                } label: {
                    Label("Set Ball", systemImage: "scope")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }

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

    private var traceEditorBar: some View {
        HStack(spacing: 12) {
            let count = session.manualCorrection?.manualBallTrackPoints.count ?? 0

            Label(traceEditorCountLabel(count), systemImage: count <= 1 ? "scope" : "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            Spacer()

            Button {
                stepTraceFrame(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Text("f\(traceEditFrameIndex)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 52)

            Button {
                stepTraceFrame(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button {
                undoManualTracePoint()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.caption.weight(.semibold))
            }
            .disabled(count == 0)

            Button {
                showBallCandidates.toggle()
                if showBallCandidates, let tracePreviewImage {
                    candidateDebugReport = BallCandidateDebugService.shared.analyze(image: tracePreviewImage)
                } else {
                    candidateDebugReport = nil
                }
            } label: {
                Image(systemName: showBallCandidates ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button {
                autoTraceFromSeed()
            } label: {
                if isRetracing {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("Auto-trace", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .disabled(count < 1 || isRetracing)

            Button(role: .destructive) {
                clearManualTrace()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.caption.weight(.semibold))
            }
            .disabled(count == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    /// One-tap "trace from this ball": take the first tapped point as the address seed and
    /// re-run the validated tracer from it (no pose needed → works on the simulator).
    private func autoTraceFromSeed() {
        guard let seed = session.manualCorrection?.manualBallTrackPoints.first,
              let videoPath = session.videoLocalPath else { return }
        isRetracing = true
        retraceMessage = nil
        let contact = session.manualCorrection?.correctedContactFrame
        Task {
            let pipeline = AnalysisPipeline()
            let points = await pipeline.retraceFromSeed(
                videoPath: videoPath,
                seedNormalized: CGPoint(x: CGFloat(seed.x), y: CGFloat(seed.y)),
                manualContactFrame: contact)
            await MainActor.run {
                isRetracing = false
                if points.count >= 2 {
                    saveManualTrace(points)
                    isEditingTrace = false
                    retraceMessage = "Traced \(points.count) points from the ball."
                } else {
                    retraceMessage = "No valid flight found from that ball — try a clearer launch or tap the exact ball."
                }
            }
        }
    }

    private var traceStatusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: traceStatusIcon)
                .foregroundStyle(traceStatusColor)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text(traceStatusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(traceStatusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if traceStatusNeedsAction {
                Button {
                    performTraceStatusAction()
                } label: {
                    Text(traceStatusActionTitle)
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(traceStatusColor.opacity(0.08))
    }

    private var ballPositionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: initialBallPoint == nil ? "scope" : "scope")
                .foregroundStyle(initialBallPoint == nil ? .red : initialBallSourceColor)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text(initialBallTitle)
                    .font(.caption.weight(.semibold))
                Text(initialBallDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                beginTraceEditing()
            } label: {
                Text(initialBallPoint == nil ? "Set Ball" : "Adjust")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(initialBallSourceColor.opacity(0.08))
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

    private var poseSummaryBanner: some View {
        Group {
            if let result = session.analysisResult {
                let summary: PoseSummary? = {
                    if case .golf(let r) = result { return r.poseSummary }
                    if case .tennis(let r) = result { return r.poseSummary }
                    return nil
                }()
                if let s = summary {
                    HStack(spacing: 8) {
                        Image(systemName: s.detectionRate > 0.6 ? "figure.walk" : "exclamationmark.triangle.fill")
                            .foregroundStyle(s.detectionRate > 0.6 ? .green : .orange)
                            .font(.caption)
                        Text("Pose: \(s.displaySummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if showPoseDebug {
                            Text("Overlay ON")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                }
            }
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

    private var displayedBallTrackPoints: [BallTrackPoint] {
        if manualTracePoints.count >= 2 {
            return manualTracePoints
        }
        if let seedAssistedTracePoints {
            return seedAssistedTracePoints
        }
        if manualTracePoints.count == 1 {
            return manualTracePoints
        }
        // Show the automatically tracked flight trail when it exists.
        if autoBallTrackPoints.count >= 2 {
            return autoBallTrackPoints
        }
        if let firstAuto = autoBallTrackPoints.first {
            return [firstAuto]
        }
        return []
    }

    private var manualTracePoints: [BallTrackPoint] {
        session.manualCorrection?.manualBallTrackPoints.sorted { $0.timestamp < $1.timestamp } ?? []
    }

    private var autoBallTrackPoints: [BallTrackPoint] {
        session.analysisResult?.ballTrackPoints.sorted { $0.timestamp < $1.timestamp } ?? []
    }

    private var seedAssistedTracePoints: [BallTrackPoint]? {
        guard manualTracePoints.count == 1,
              let seed = manualTracePoints.first,
              autoBallTrackPoints.count >= 2,
              let firstAuto = autoBallTrackPoints.first,
              abs(seed.timestamp - firstAuto.timestamp) <= 0.05,
              abs(seed.frameIndex - firstAuto.frameIndex) <= 2,
              tracePointDistance(seed, firstAuto) <= 0.035 else {
            return nil
        }

        return autoBallTrackPoints
    }

    private var initialBallPoint: BallTrackPoint? {
        manualTracePoints.first ?? autoBallTrackPoints.first
    }

    private var initialBallTitle: String {
        if !manualTracePoints.isEmpty { return "Ball position set by user" }
        if initialBallPoint != nil { return "Auto ball candidate" }
        return "Ball position not detected"
    }

    private var initialBallDetail: String {
        if let manual = manualTracePoints.first {
            return "Frame \(manual.frameIndex), confidence 95%. Confirm this circle is on the ball before tracing flight."
        }
        if let auto = initialBallPoint {
            return "Frame \(auto.frameIndex), confidence \(Int(auto.confidence * 100))%. If the circle is wrong, tap Adjust."
        }
        return "Set the ball first. Flight tracing stays disabled until the starting ball is known."
    }

    private var initialBallSourceColor: Color {
        if !manualTracePoints.isEmpty { return .green }
        if initialBallPoint != nil { return .orange }
        return .red
    }

    private var traceStatusTitle: String {
        let manualCount = manualTracePoints.count
        if manualCount >= 2 { return "Manual flight trace active" }
        if seedAssistedTracePoints != nil { return "Seed-assisted flight trace" }
        if manualCount == 1 { return "Ready to re-analyse" }
        if let result = session.analysisResult {
            let autoCount = result.ballTrackPoints.count
            if autoCount >= 2 {
                return "Auto flight trace"
            }
            return "No reliable flight trace"
        }
        return "No flight trace yet"
    }

    private var traceStatusDetail: String {
        let manualCount = manualTracePoints.count
        if manualCount >= 2 {
            return "\(manualCount) user points are driving the tracer."
        }
        if let seedAssistedTracePoints {
            return "\(seedAssistedTracePoints.count) points generated from your ball seed, avg confidence \(Int(autoTraceAverageConfidence * 100))%."
        }
        if let seed = manualTracePoints.first {
            return "Seed at frame \(seed.frameIndex). Re-analyse to generate a flight trace, or add flight points manually."
        }
        if let result = session.analysisResult {
            let autoCount = result.ballTrackPoints.count
            if autoCount >= 2 {
                return "\(autoCount) auto-tracked flight points. Tap Edit Ball Trace to refine if needed."
            }
            return "Initial ball must be correct before flight tracing."
        }
        return "Run analysis, or set the ball manually first."
    }

    private var traceStatusIcon: String {
        let manualCount = manualTracePoints.count
        if manualCount >= 2 { return "checkmark.circle.fill" }
        if seedAssistedTracePoints != nil { return "scope" }
        if manualCount == 1 { return "point.3.connected.trianglepath.dotted" }
        if let result = session.analysisResult, result.ballTrackPoints.count >= 2 {
            return "scope"
        }
        return "exclamationmark.triangle.fill"
    }

    private var traceStatusColor: Color {
        let manualCount = manualTracePoints.count
        if manualCount >= 2 { return .green }
        if seedAssistedTracePoints != nil { return .green }
        if manualCount == 1 { return .orange }
        if let result = session.analysisResult, result.ballTrackPoints.count >= 2 {
            return .green
        }
        return .red
    }

    private var traceStatusNeedsAction: Bool {
        if seedAssistedTracePoints != nil { return false }
        if manualTracePoints.count == 1 { return true }
        guard manualTracePoints.isEmpty else { return false }
        let autoCount = session.analysisResult?.ballTrackPoints.count ?? 0
        return autoCount < 2
    }

    private var traceStatusActionTitle: String {
        manualTracePoints.count == 1 ? "Re-analyse" : "Fix"
    }

    private var autoTraceAverageConfidence: Float {
        guard let points = session.analysisResult?.ballTrackPoints, !points.isEmpty else { return 0 }
        return points.map(\.confidence).reduce(0, +) / Float(points.count)
    }

    private var traceInstructionTitle: String {
        manualTracePoints.isEmpty ? "Tap the ball" : "Add flight point"
    }

    private var traceInstructionDetail: String {
        manualTracePoints.isEmpty
            ? "Place the first point directly on the ball."
            : "Only add flight points after the ball circle is correct."
    }

    private func traceEditorCountLabel(_ count: Int) -> String {
        switch count {
        case 0: return "No ball seed"
        case 1: return "1 ball seed"
        default: return "\(count) trace points"
        }
    }

    private func tracePointDistance(_ lhs: BallTrackPoint, _ rhs: BallTrackPoint) -> CGFloat {
        let dx = CGFloat(lhs.x - rhs.x)
        let dy = CGFloat(lhs.y - rhs.y)
        return sqrt(dx * dx + dy * dy)
    }

    private var traceEditFrameIndex: Int {
        max(0, Int((traceEditTime * videoFrameRate).rounded()))
    }

    private func toggleTraceEditing() {
        if isEditingTrace {
            isEditingTrace = false
            tracePreviewTask?.cancel()
            tracePreviewTask = nil
            tracePreviewImage = nil
            candidateDebugReport = nil
        } else {
            beginTraceEditing()
        }
    }

    private func beginTraceEditing() {
        isEditingTrace = true
        traceEditTime = currentPlayTime
        loadTracePreview(at: traceEditTime)
    }

    private func performTraceStatusAction() {
        if manualTracePoints.count == 1 {
            navigateToAnalysis = true
        } else {
            beginTraceEditing()
        }
    }

    private func stepTraceFrame(by frameDelta: Int) {
        let frameDuration = 1.0 / max(1, videoFrameRate)
        traceEditTime = max(0, traceEditTime + Double(frameDelta) * frameDuration)
        loadTracePreview(at: traceEditTime)
    }

    private func loadTracePreview(at time: TimeInterval) {
        tracePreviewTask?.cancel()
        tracePreviewTask = Task {
            guard let image = await loadPreviewImage(at: time), !Task.isCancelled else { return }
            let report = showBallCandidates ? BallCandidateDebugService.shared.analyze(image: image) : nil
            await MainActor.run {
                tracePreviewImage = image
                candidateDebugReport = report
            }
        }
    }

    private func addManualTracePoint(at location: CGPoint, in bounds: CGRect) {
        let rect = fittedVideoRect(in: bounds)
        guard rect.contains(location), rect.width > 0, rect.height > 0 else { return }

        let x = Float((location.x - rect.minX) / rect.width)
        let y = Float(1.0 - ((location.y - rect.minY) / rect.height))
        let timestamp = max(0, isEditingTrace ? traceEditTime : currentPlayTime)
        let point = BallTrackPoint(
            frameIndex: Int((timestamp * videoFrameRate).rounded()),
            timestamp: timestamp,
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1),
            confidence: 0.95
        )

        var points = session.manualCorrection?.manualBallTrackPoints ?? []
        points.removeAll { abs($0.timestamp - timestamp) < 0.035 }
        points.append(point)
        saveManualTrace(points)

        // Capture this tap as a labeled training example — only when the user has
        // opted in (Settings), so accidental taps don't pollute the dataset.
        if collectTrainingData, let frame = tracePreviewImage {
            TrainingDataService.shared.record(
                image: frame,
                normalizedCenter: CGPoint(x: CGFloat(point.x), y: CGFloat(1 - point.y))
            )
        }
    }

    private func undoManualTracePoint() {
        var points = session.manualCorrection?.manualBallTrackPoints ?? []
        guard !points.isEmpty else { return }
        points.sort { $0.timestamp < $1.timestamp }
        points.removeLast()
        saveManualTrace(points)
    }

    private func clearManualTrace() {
        saveManualTrace([])
    }

    private func saveManualTrace(_ points: [BallTrackPoint]) {
        let service = ManualCorrectionService(repository: SessionRepository(modelContext: modelContext))
        try? service.applyManualBallTrace(to: session, points: points)
    }

    private func exportTracerVideo() async {
        guard displayedBallTrackPoints.count >= 2 else {
            exportMessage = "Add or generate a trace before exporting."
            return
        }

        isExportingTrace = true
        defer { isExportingTrace = false }

        do {
            let url = try await TracerExportService.shared.export(session: session, trackPoints: displayedBallTrackPoints)
            session.processedVideoLocalPath = url.path
            try SessionRepository(modelContext: modelContext).update()
            exportMessage = "Tracer video saved to this session."
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    private func fittedVideoRect(in bounds: CGRect) -> CGRect {
        guard let videoAspectRatio, videoAspectRatio > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let containerAspect = bounds.width / bounds.height
        if containerAspect > videoAspectRatio {
            let width = bounds.height * videoAspectRatio
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        } else {
            let height = bounds.width / videoAspectRatio
            return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
    }

    private func loadVideoMetadata() async -> (aspectRatio: CGFloat?, frameRate: Double) {
        guard let url = VideoStorageService.shared.videoURL(for: session) else { return (nil, 60) }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let nominalFrameRate = try? await track.load(.nominalFrameRate) else {
            return (nil, 60)
        }

        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        guard width > 0, height > 0 else { return (nil, max(1, Double(nominalFrameRate))) }
        return (width / height, max(1, Double(nominalFrameRate)))
    }

    private func loadPreviewImage(at time: TimeInterval) async -> UIImage? {
        guard let url = VideoStorageService.shared.videoURL(for: session) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(videoFrameRate))))
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(videoFrameRate))))

        do {
            let cgImage = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }
}

struct TraceFramePreview: View {
    let image: UIImage
    let videoAspectRatio: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let rect = fittedVideoRect(in: bounds)
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .background(Color.black.opacity(0.22))
        }
    }

    private func fittedVideoRect(in bounds: CGRect) -> CGRect {
        guard let videoAspectRatio, videoAspectRatio > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let containerAspect = bounds.width / bounds.height
        if containerAspect > videoAspectRatio {
            let width = bounds.height * videoAspectRatio
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        } else {
            let height = bounds.width / videoAspectRatio
            return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
    }
}

struct BallCandidateDebugOverlay: View {
    let report: BallCandidateDebugReport
    let videoAspectRatio: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let videoRect = fittedVideoRect(in: bounds)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .path(in: rect(report.searchRegion, in: videoRect))
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))

                ForEach(Array(report.candidates.enumerated()), id: \.element.id) { index, candidate in
                    let candidateRect = rect(candidate.boundingBox, in: videoRect)
                    let color = color(for: candidate.status)
                    Rectangle()
                        .path(in: candidateRect)
                        .stroke(color, lineWidth: candidate.status == .selected ? 3 : 1.5)

                    Text(label(for: candidate, index: index))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.82))
                        .foregroundStyle(.white)
                        .position(
                            x: min(max(candidateRect.midX, 24), geo.size.width - 24),
                            y: min(max(candidateRect.minY - 8, 9), geo.size.height - 9)
                        )
                }
            }
        }
    }

    private func label(for candidate: BallCandidateDebugResult, index: Int) -> String {
        if let reason = candidate.rejectionReason {
            return "\(index + 1) \(reason)"
        }
        return "\(index + 1) \(Int(candidate.score * 100)) a\(candidate.area)"
    }

    private func color(for status: BallCandidateDebugResult.Status) -> Color {
        switch status {
        case .candidate: return .green
        case .rejected: return .red
        case .selected: return .blue
        }
    }

    private func rect(_ normalized: CGRect, in videoRect: CGRect) -> CGRect {
        CGRect(
            x: videoRect.minX + normalized.minX * videoRect.width,
            y: videoRect.minY + normalized.minY * videoRect.height,
            width: normalized.width * videoRect.width,
            height: normalized.height * videoRect.height
        )
    }

    private func fittedVideoRect(in bounds: CGRect) -> CGRect {
        guard let videoAspectRatio, videoAspectRatio > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let containerAspect = bounds.width / bounds.height
        if containerAspect > videoAspectRatio {
            let width = bounds.height * videoAspectRatio
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        } else {
            let height = bounds.width / videoAspectRatio
            return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
    }
}

struct AnalysisSummarySection: View {
    let result: AnalysisResult
    let manualTracePointCount: Int
    let onSetBall: () -> Void
    let onReanalyse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Analysis Summary", icon: "checklist.checked")

            VStack(alignment: .leading, spacing: 10) {
                SummaryRow(
                    icon: "figure.walk",
                    title: "Pose detection",
                    detail: poseDetail,
                    color: poseColor
                )
                SummaryRow(
                    icon: "scope",
                    title: "Ball tracking",
                    detail: ballDetail,
                    color: ballColor
                )
                SummaryRow(
                    icon: "camera.metering.center.weighted",
                    title: "Impact frame",
                    detail: impactDetail,
                    color: contactColor
                )

                if needsBallAction {
                    HStack(spacing: 10) {
                        Button {
                            onSetBall()
                        } label: {
                            Label("Set Ball", systemImage: "scope")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)

                        if manualTracePointCount == 1 {
                            Button {
                                onReanalyse()
                            } label: {
                                Label("Re-analyse", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 16)
        .background(Color(.systemGray6).opacity(0.65))
    }

    private var poseSummary: PoseSummary? {
        switch result {
        case .golf(let golf): return golf.poseSummary
        case .tennis(let tennis): return tennis.poseSummary
        default: return nil
        }
    }

    private var poseDetail: String {
        guard let poseSummary else {
            return "Pose summary unavailable."
        }
        return "\(poseSummary.displaySummary) detected. Metrics require clear full-body landmarks."
    }

    private var poseColor: Color {
        guard let poseSummary else { return .orange }
        return poseSummary.detectionRate >= 0.6 ? .green : .orange
    }

    private var ballDetail: String {
        let count = result.ballTrackPoints.count
        if manualTracePointCount >= 2 {
            return "\(manualTracePointCount) manual trace points are being used."
        }
        if manualTracePointCount == 1 {
            return "Ball seed set. Re-analyse to generate a seed-assisted flight trace."
        }
        if count >= 2 {
            return "\(count) automatic ball points found. Verify the initial ball before exporting a tracer."
        }
        if count == 1 {
            return "Address ball candidate found, but launch flight was not reliable enough to render."
        }
        return "No reliable ball candidate found. Set the ball manually to continue."
    }

    private var ballColor: Color {
        if manualTracePointCount >= 2 { return .green }
        if manualTracePointCount == 1 { return .orange }
        let count = result.ballTrackPoints.count
        return count >= 2 ? .orange : .red
    }

    private var impactDetail: String {
        guard let frame = result.contactFrameIndex else {
            return "Impact/contact frame unavailable."
        }
        let confidence = contactConfidence
        return "Frame \(frame), confidence \(Int(confidence * 100))%."
    }

    private var contactConfidence: Float {
        switch result {
        case .golf(let golf): return golf.contactConfidence
        case .tennis(let tennis): return tennis.contactConfidence
        default: return 0
        }
    }

    private var contactColor: Color {
        contactConfidence >= 0.5 ? .green : .orange
    }

    private var needsBallAction: Bool {
        result.ballTrackPoints.count < 2 || manualTracePointCount == 1
    }
}

struct SummaryRow: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
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
                LowConfidenceBanner(message: "No swing metrics were produced from this video. Usually this means pose detection did not see enough confident body landmarks at address, impact, and finish.")
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
                LowConfidenceBanner(message: "No coaching feedback was generated because there were no reliable metrics to explain. Try a brighter side-on clip with the full body visible, or set the ball manually and re-analyse.")
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

/// Full-screen video with the live tracer overlay, so the user can assess the shot.
struct FullScreenVideoView: View {
    let session: PracticeSession
    let trackPoints: [BallTrackPoint]
    let contactFrameIndex: Int?
    let videoAspectRatio: CGFloat?

    @Environment(\.dismiss) private var dismiss
    @State private var currentPlayTime: TimeInterval = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayerView(session: session, onTimeChange: { currentPlayTime = $0 })
                .ignoresSafeArea()

            if trackPoints.count > 1 {
                BallTrailOverlayView(
                    trackPoints: trackPoints,
                    highlightFrameIndex: contactFrameIndex,
                    videoAspectRatio: videoAspectRatio,
                    currentTime: currentPlayTime
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(12)
                    }
                }
                Spacer()
            }
        }
        .statusBarHidden()
    }
}
