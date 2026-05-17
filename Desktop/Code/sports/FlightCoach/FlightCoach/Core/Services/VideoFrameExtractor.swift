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
        frameRange: ClosedRange<Int>? = nil,
        stride: Int = 1,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [VideoFrame] {
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw FrameExtractorError.noVideoTrack
        }
        let preferredTransform = try await track.load(.preferredTransform)

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
        let lowerBound = frameRange?.lowerBound ?? 0
        let upperBound = frameRange?.upperBound ?? totalFrames
        let expectedFrames = max(1, upperBound - lowerBound + 1)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { frameIndex += 1 }
            if frameIndex < lowerBound { continue }
            if frameIndex > upperBound { break }
            guard frameIndex % stride == 0 else { continue }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestamp = pts.seconds

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let ciImage = displayOrientedImage(CIImage(cvImageBuffer: imageBuffer), preferredTransform: preferredTransform)

            frames.append(VideoFrame(index: frameIndex, timestamp: timestamp, image: ciImage))

            let progress = Double(frameIndex - lowerBound) / Double(expectedFrames)
            onProgress?(min(progress, 1.0))
        }

        return frames
    }

    func extractDenseFrames(
        around time: TimeInterval,
        windowSeconds: Double = 3.0,
        maxFPS: Double = 60,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [VideoFrame] {
        let startTime = max(0, time - windowSeconds / 2)
        let endTime   = min(duration, time + windowSeconds / 2)
        guard endTime > startTime else { return [] }

        let cmStart = CMTime(seconds: startTime, preferredTimescale: 600)
        let cmEnd   = CMTime(seconds: endTime,   preferredTimescale: 600)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: cmStart, end: cmEnd)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw FrameExtractorError.noVideoTrack }
        let preferredTransform = try await track.load(.preferredTransform)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw FrameExtractorError.readerFailed }

        let denseStride = max(1, Int((frameRate / maxFPS).rounded()))
        let windowFrameCount = max(1, Int((endTime - startTime) * frameRate))
        var frames: [VideoFrame] = []
        var localIndex = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { localIndex += 1 }
            guard localIndex % denseStride == 0 else { continue }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let globalIndex = Int((pts.seconds * frameRate).rounded())

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let ciImage = displayOrientedImage(CIImage(cvImageBuffer: imageBuffer), preferredTransform: preferredTransform)
            frames.append(VideoFrame(index: globalIndex, timestamp: pts.seconds, image: ciImage))

            onProgress?(Double(localIndex) / Double(windowFrameCount))
            if localIndex % 20 == 0 { await Task.yield() }
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

    private func displayOrientedImage(_ image: CIImage, preferredTransform: CGAffineTransform) -> CIImage {
        let transformed = image.transformed(by: preferredTransform)
        let extent = transformed.extent
        guard extent.origin != .zero else { return transformed }
        return transformed.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
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
