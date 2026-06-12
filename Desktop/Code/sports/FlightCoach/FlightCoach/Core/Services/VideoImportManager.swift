import Foundation
import PhotosUI
import SwiftUI
import AVFoundation

@MainActor
final class VideoImportManager: ObservableObject {
    @Published var isImporting = false
    @Published var importError: String?

    // Imports keep the ORIGINAL Photos bytes (the picker requests .current):
    // 60fps is required by the flight detector, and the pipeline is
    // ground-truth-validated against HDR originals. HDR is tone-mapped at
    // DISPLAY time (player + thumbnails) — re-encoding to SDR here either
    // halves the frame rate (4K H.264 presets) or shrinks the ball below
    // what the detector needs (1080p).

    func importVideo(from item: PhotosPickerItem) async throws -> URL {
        isImporting = true
        defer { isImporting = false }

        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ImportError.loadFailed
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        try data.write(to: tempURL)
        return tempURL
    }

    func importVideo(from url: URL) async throws -> URL {
        isImporting = true
        defer { isImporting = false }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)

        try FileManager.default.copyItem(at: url, to: tempURL)
        return tempURL
    }

    func videoDuration(at url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return duration.seconds
        } catch {
            return 0
        }
    }
}

enum ImportError: Error, LocalizedError {
    case loadFailed
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "Could not load video from Photos."
        case .unsupportedFormat: return "Video format is not supported."
        }
    }
}
