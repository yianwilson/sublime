import SwiftUI
import PhotosUI
import SwiftData

struct SessionSetupScreen: View {
    let sport: SportType

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMode: String = ""
    @State private var selectedAngle: CameraAngle = .faceOn
    @State private var selectedHandedness: Handedness = .rightHanded
    @State private var showingVideoPicker = false
    @State private var showingCamera = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var navigateToSession: PracticeSession?

    private var availableModes: [String] {
        switch sport {
        case .golf: return GolfMode.allCases.map(\.rawValue)
        case .tennis: return TennisMode.allCases.map(\.rawValue)
        }
    }

    private var availableAngles: [CameraAngle] {
        switch sport {
        case .golf: return CameraAngle.golfAngles
        case .tennis: return CameraAngle.tennisAngles
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                sportHeader
                modeSection
                angleSection
                if sport == .golf {
                    handednessSection
                }
                Divider().padding(.horizontal)
                videoSourceSection
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Session Setup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selectedMode = availableModes.first ?? "" }
        .photosPicker(isPresented: $showingVideoPicker, selection: $selectedPhotoItem, matching: .videos)
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await importVideo(from: item) }
        }
        .navigationDestination(item: $navigateToSession) { session in
            AnalysisResultScreen(session: session)
        }
        .overlay {
            if isImporting {
                ProgressView("Importing video…")
                    .padding(24)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Import Error", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            if let e = importError { Text(e) }
        }
    }

    private var sportHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: sport.iconName)
                .font(.title)
                .foregroundStyle(.green)
            Text(sport.displayName)
                .font(.title2.weight(.semibold))
        }
        .padding(.horizontal, 24)
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Mode", systemImage: "figure.mixed.cardio")
                .font(.headline)
                .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(availableModes, id: \.self) { mode in
                        ModeChip(title: mode.capitalized, isSelected: selectedMode == mode)
                            .onTapGesture { selectedMode = mode }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var angleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Camera Angle", systemImage: "camera.viewfinder")
                .font(.headline)
                .padding(.horizontal, 24)

            VStack(spacing: 10) {
                ForEach(availableAngles) { angle in
                    AngleRow(angle: angle, isSelected: selectedAngle == angle)
                        .onTapGesture { selectedAngle = angle }
                        .padding(.horizontal, 24)
                }
            }
        }
    }

    private var handednessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Handedness", systemImage: "hand.raised")
                .font(.headline)
                .padding(.horizontal, 24)

            Picker("Handedness", selection: $selectedHandedness) {
                ForEach(Handedness.allCases) { hand in
                    Text(hand.displayName).tag(hand)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            Text("Used to anchor where the ball sits at address for more reliable detection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
    }

    private var videoSourceSection: some View {
        VStack(spacing: 12) {
            Text("Add Video")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

            VideoSourceButton(
                title: "Import from Photos",
                subtitle: "Choose an existing video",
                icon: "photo.on.rectangle.angled",
                color: .blue
            ) {
                showingVideoPicker = true
            }
            .padding(.horizontal, 24)

            VideoSourceButton(
                title: "Record with Camera",
                subtitle: "Record a new practice session",
                icon: "video.fill",
                color: .red
            ) {
                showingCamera = true
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $showingCamera) {
            CameraRecordingScreen(sport: sport, mode: selectedMode, angle: selectedAngle, handedness: selectedHandedness) { session in
                navigateToSession = session
            }
        }
    }

    private func importVideo(from item: PhotosPickerItem) async {
        isImporting = true
        defer { isImporting = false }

        do {
            let importManager = VideoImportManager()
            let tempURL = try await importManager.importVideo(from: item)
            let duration = await importManager.videoDuration(at: tempURL)

            let session = PracticeSession(sport: sport, mode: selectedMode, cameraAngle: selectedAngle, handedness: selectedHandedness)
            session.durationSeconds = duration

            let savedURL = try await VideoStorageService.shared.copyVideoToLocal(from: tempURL, sessionId: session.id)
            session.videoLocalPath = savedURL.path

            if let thumbURL = try? await VideoStorageService.shared.generateThumbnail(from: savedURL, sessionId: session.id) {
                session.thumbnailLocalPath = thumbURL.path
            }

            try? FileManager.default.removeItem(at: tempURL)

            let repo = SessionRepository(modelContext: modelContext)
            try repo.save(session)

            navigateToSession = session

        } catch {
            importError = error.localizedDescription
        }
    }
}

struct ModeChip: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.green : Color(.secondarySystemGroupedBackground))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
    }
}

struct AngleRow: View {
    let angle: CameraAngle
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "camera.fill" : "camera")
                .foregroundStyle(isSelected ? .green : .secondary)
            Text(angle.displayName)
                .font(.subheadline)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .fontWeight(.semibold)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.green : .clear, lineWidth: 1.5))
    }
}

struct VideoSourceButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(color.opacity(0.12))
                    .foregroundStyle(color)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
