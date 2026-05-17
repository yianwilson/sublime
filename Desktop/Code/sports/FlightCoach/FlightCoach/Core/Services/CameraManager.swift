import Foundation
import AVFoundation
import SwiftUI

enum CameraManagerError: Error, LocalizedError {
    case deviceNotAvailable
    case setupFailed(String)
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotAvailable: return "Camera device not available."
        case .setupFailed(let msg): return "Camera setup failed: \(msg)"
        case .recordingFailed(let msg): return "Recording failed: \(msg)"
        }
    }
}

enum RecordingState {
    case idle
    case preparing
    case recording
    case stopping
}

@MainActor
final class CameraManager: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var recordedVideoURL: URL?
    @Published var error: String?
    @Published var previewLayer: AVCaptureVideoPreviewLayer?

    private let session = AVCaptureSession()
    private var movieOutput = AVCaptureMovieFileOutput()
    private var outputURL: URL?
    private var completionHandler: ((Result<URL, Error>) -> Void)?

    override init() {
        super.init()
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func setupSession() async throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraManagerError.deviceNotAvailable
        }

        session.beginConfiguration()
        session.sessionPreset = .high

        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else {
            throw CameraManagerError.setupFailed("Cannot add video input")
        }
        session.addInput(videoInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }
        }

        guard session.canAddOutput(movieOutput) else {
            throw CameraManagerError.setupFailed("Cannot add movie output")
        }
        session.addOutput(movieOutput)
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
    }

    func startSession() {
        guard !session.isRunning else { return }
        Task.detached { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopSession() {
        guard session.isRunning else { return }
        Task.detached { [weak self] in
            self?.session.stopRunning()
        }
    }

    func startRecording() async throws {
        guard recordingState == .idle else { return }
        recordingState = .preparing

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        outputURL = url
        recordingState = .recording
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() async throws -> URL {
        guard recordingState == .recording else {
            throw CameraManagerError.recordingFailed("Not currently recording")
        }
        recordingState = .stopping
        return try await withCheckedThrowingContinuation { continuation in
            completionHandler = { result in
                continuation.resume(with: result)
            }
            self.movieOutput.stopRecording()
        }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.recordingState = .idle
            if let error {
                self.completionHandler?(.failure(CameraManagerError.recordingFailed(error.localizedDescription)))
            } else {
                self.recordedVideoURL = outputFileURL
                self.completionHandler?(.success(outputFileURL))
            }
            self.completionHandler = nil
        }
    }
}
