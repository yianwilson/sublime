import SwiftUI
import SwiftData

struct ManualCorrectionSheet: View {
    let session: PracticeSession

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var contactFrameText: String = ""
    @State private var selectedAngle: CameraAngle
    @State private var saveError: String?

    init(session: PracticeSession) {
        self.session = session
        let existing = session.manualCorrection?.correctedCameraAngle ?? session.cameraAngleEnum
        _selectedAngle = State(initialValue: existing)
        let frame = session.manualCorrection?.correctedContactFrame ?? session.analysisResult?.contactFrameIndex
        _contactFrameText = State(initialValue: frame.map { "\($0)" } ?? "")
    }

    private var availableAngles: [CameraAngle] {
        session.sportType == .golf ? CameraAngle.golfAngles : CameraAngle.tennisAngles
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Session")
                        Spacer()
                        Text(session.displayTitle)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Section(
                    header: Text("Impact / Contact Frame"),
                    footer: Text("Override the auto-detected impact frame if it appears wrong.")
                ) {
                    HStack {
                        Text("Frame Index")
                        Spacer()
                        TextField("e.g. 42", text: $contactFrameText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    if let result = session.analysisResult, let detected = result.contactFrameIndex {
                        Text("Auto-detected: frame \(detected)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Camera Angle") {
                    ForEach(availableAngles) { angle in
                        HStack {
                            Text(angle.displayName)
                            Spacer()
                            if selectedAngle == angle {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedAngle = angle }
                    }
                }

                if session.manualCorrection != nil {
                    Section {
                        Button("Reset All Corrections", role: .destructive) {
                            resetCorrections()
                        }
                    }
                }
            }
            .navigationTitle("Manual Corrections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveCorrections() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Error", isPresented: .constant(saveError != nil)) {
                Button("OK") { saveError = nil }
            } message: {
                if let e = saveError { Text(e) }
            }
        }
    }

    private func saveCorrections() {
        let correctionService = ManualCorrectionService(repository: SessionRepository(modelContext: modelContext))
        do {
            if let frameIdx = Int(contactFrameText) {
                try correctionService.applyContactFrameCorrection(to: session, frameIndex: frameIdx)
            }
            try correctionService.applyCameraAngleCorrection(to: session, angle: selectedAngle)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func resetCorrections() {
        let correctionService = ManualCorrectionService(repository: SessionRepository(modelContext: modelContext))
        try? correctionService.resetCorrections(for: session)
        dismiss()
    }
}
