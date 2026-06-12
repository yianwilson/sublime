import Foundation
import AVFoundation
import UIKit

final class VideoStorageService {
    static let shared = VideoStorageService()

    private let videosDirectory: URL
    private let processedVideosDirectory: URL
    private let thumbnailsDirectory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        videosDirectory = docs.appendingPathComponent("Videos", isDirectory: true)
        processedVideosDirectory = docs.appendingPathComponent("ProcessedVideos", isDirectory: true)
        thumbnailsDirectory = docs.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: processedVideosDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
    }

    func copyVideoToLocal(from sourceURL: URL, sessionId: UUID) async throws -> URL {
        let destinationURL = videosDirectory.appendingPathComponent("\(sessionId.uuidString).mov")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func processedVideoDestinationURL(for sessionId: UUID) -> URL {
        processedVideosDirectory.appendingPathComponent("\(sessionId.uuidString)-traced.mov")
    }

    /// SDR display composition for HDR (HLG/PQ) sources. Imports keep the
    /// original HDR bytes (analysis is ground-truth-validated against them);
    /// without tone mapping they render washed-out — on the simulator
    /// always, and in any non-EDR context. nil for SDR sources.
    static func sdrDisplayComposition(for asset: AVAsset) async -> AVVideoComposition? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions) else { return nil }
        let hdrTransfers = [
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        ]
        let isHDR = descriptions.contains { desc in
            guard let transfer = CMFormatDescriptionGetExtension(
                desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String else { return false }
            return hdrTransfers.contains(transfer)
        }
        guard isHDR,
              let composition = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset) else {
            return nil
        }
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }

    func generateThumbnail(from videoURL: URL, sessionId: UUID) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 300)
        generator.videoComposition = await Self.sdrDisplayComposition(for: asset)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let cgImage: CGImage
        if let composed = try? await generator.image(at: time).image {
            cgImage = composed
        } else {
            // Composition render can fail on the simulator (err -12306);
            // a washed-out HDR thumbnail beats none.
            generator.videoComposition = nil
            cgImage = try await generator.image(at: time).image
        }
        let uiImage = UIImage(cgImage: cgImage)

        guard let jpegData = uiImage.jpegData(compressionQuality: 0.7) else {
            throw VideoStorageError.thumbnailGenerationFailed
        }

        let thumbnailURL = thumbnailsDirectory.appendingPathComponent("\(sessionId.uuidString).jpg")
        try jpegData.write(to: thumbnailURL)
        return thumbnailURL
    }

    func videoURL(for session: PracticeSession) -> URL? {
        guard let path = session.videoLocalPath else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func processedVideoURL(for session: PracticeSession) -> URL? {
        guard let path = session.processedVideoLocalPath else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func deleteProcessedVideo(for session: PracticeSession) {
        if let path = session.processedVideoLocalPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        session.processedVideoLocalPath = nil
    }

    func thumbnailURL(for session: PracticeSession) -> URL? {
        guard let path = session.thumbnailLocalPath else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func deleteVideo(for session: PracticeSession) {
        if let path = session.videoLocalPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        if let path = session.processedVideoLocalPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        if let path = session.thumbnailLocalPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    func totalStorageUsed() -> Int64 {
        var total: Int64 = 0
        for dir in [videosDirectory, processedVideosDirectory, thumbnailsDirectory] {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
        }
        return total
    }
}

enum VideoStorageError: Error, LocalizedError {
    case thumbnailGenerationFailed
    case videoNotFound

    var errorDescription: String? {
        switch self {
        case .thumbnailGenerationFailed: return "Could not generate thumbnail from video."
        case .videoNotFound: return "Video file not found on device."
        }
    }
}
