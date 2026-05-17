import Foundation
import AVFoundation
import CoreImage

struct VideoFrame {
    let index: Int
    let timestamp: TimeInterval
    let image: CIImage
}

final class VideoFrameExtractor {
    let asset: AVURLAsset
    let frameRate: Double
    let totalFrames: Int
    let duration: TimeInterval

    private init(asset: AVURLAsset, frameRate: Double, totalFrames: Int, duration: TimeInterval) {
        self.asset = asset
        self.frameRate = frameRate
        self.totalFrames = totalFrames
        self.duration = duration
    }

    static func make(url: URL) async throws -> VideoFrameExtractor {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw FrameExtractorError.noVideoTrack
        }

        let frameRate = Double(try await track.load(.nominalFrameRate))
        let totalFrames = Int(duration * frameRate)

        return VideoFrameExtractor(
            asset: asset,
            frameRate: frameRate,
            totalFrames: max(1, totalFrames),
            duration: duration
        )
    }

    func extractFrames(
        stride: Int = 1,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [VideoFrame] {
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw FrameExtractorError.noVideoTrack
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw FrameExtractorError.readerFailed
        }

        var frames: [VideoFrame] = []
        var frameIndex = 0
        let ciContext = CIContext()

        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { frameIndex += 1 }
            guard frameIndex % stride == 0 else { continue }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestamp = pts.seconds

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let ciImage = CIImage(cvImageBuffer: imageBuffer)

            frames.append(VideoFrame(index: frameIndex, timestamp: timestamp, image: ciImage))

            let progress = Double(frameIndex) / Double(max(1, totalFrames))
            onProgress?(min(progress, 1.0))
        }

        return frames
    }

    func extractSingleFrame(at time: TimeInterval) async throws -> CIImage {
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        let cgImage = try await imageGenerator.image(at: cmTime).image
        return CIImage(cgImage: cgImage)
    }
}

enum FrameExtractorError: Error, LocalizedError {
    case noVideoTrack
    case readerFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track found in asset."
        case .readerFailed: return "Could not read video frames."
        }
    }
}
