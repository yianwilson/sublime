import Foundation
@preconcurrency import AVFoundation
import UIKit
import QuartzCore

enum TracerExportError: Error, LocalizedError {
    case missingVideo
    case missingVideoTrack
    case missingTrace
    case cannotCreateCompositionTrack
    case cannotCreateExporter
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVideo: return "Original video was not found."
        case .missingVideoTrack: return "Video track was not found."
        case .missingTrace: return "No trace points are available to export."
        case .cannotCreateCompositionTrack: return "Could not prepare the video for export."
        case .cannotCreateExporter: return "Could not create the video exporter."
        case .exportFailed(let message): return "Export failed: \(message)"
        }
    }
}

final class TracerExportService {
    static let shared = TracerExportService()

    private init() {}

    func export(session: PracticeSession, trackPoints: [BallTrackPoint]) async throws -> URL {
        guard let sourceURL = VideoStorageService.shared.videoURL(for: session) else {
            throw TracerExportError.missingVideo
        }
        let sortedPoints = trackPoints.sorted { $0.timestamp < $1.timestamp }
        guard sortedPoints.count >= 2 else {
            throw TracerExportError.missingTrace
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TracerExportError.missingVideoTrack
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TracerExportError.cannotCreateCompositionTrack
        }

        let duration = try await asset.load(.duration)
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideoTrack, at: .zero)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for sourceAudioTrack in audioTracks {
            guard let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try? audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudioTrack, at: .zero)
        }

        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        let transformedSize = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized.size
        let renderSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.animationTool = makeAnimationTool(trackPoints: sortedPoints, renderSize: renderSize)

        let destinationURL = VideoStorageService.shared.processedVideoDestinationURL(for: session.id)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw TracerExportError.cannotCreateExporter
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .mov
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true

        let exportBox = ExportSessionBox(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportBox.exporter.exportAsynchronously {
                switch exportBox.exporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: TracerExportError.exportFailed(exportBox.exporter.error?.localizedDescription ?? exportBox.exporter.status.description))
                default:
                    continuation.resume(throwing: TracerExportError.exportFailed("Unexpected exporter status \(exportBox.exporter.status.rawValue)"))
                }
            }
        }

        return destinationURL
    }

    private func makeAnimationTool(trackPoints: [BallTrackPoint], renderSize: CGSize) -> AVVideoCompositionCoreAnimationTool {
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)

        let overlayLayer = CALayer()
        overlayLayer.frame = CGRect(origin: .zero, size: renderSize)
        overlayLayer.masksToBounds = true

        let path = smoothedPath(for: trackPoints, renderSize: renderSize)
        let averageConfidence = trackPoints.map(\.confidence).reduce(0, +) / Float(max(1, trackPoints.count))

        let glowLayer = CAShapeLayer()
        glowLayer.path = path.cgPath
        glowLayer.fillColor = UIColor.clear.cgColor
        glowLayer.strokeColor = UIColor.orange.withAlphaComponent(0.35).cgColor
        glowLayer.lineWidth = averageConfidence < 0.45 ? 10 : 8
        glowLayer.lineCap = .round
        glowLayer.lineJoin = .round
        glowLayer.shadowColor = UIColor.orange.cgColor
        glowLayer.shadowRadius = 8
        glowLayer.shadowOpacity = 0.75
        glowLayer.shadowOffset = .zero
        overlayLayer.addSublayer(glowLayer)

        let lineLayer = CAShapeLayer()
        lineLayer.path = path.cgPath
        lineLayer.fillColor = UIColor.clear.cgColor
        lineLayer.strokeColor = UIColor.orange.cgColor
        lineLayer.lineWidth = averageConfidence < 0.45 ? 4 : 3
        lineLayer.lineCap = .round
        lineLayer.lineJoin = .round
        if averageConfidence < 0.45 {
            lineLayer.lineDashPattern = [12, 8]
        }
        overlayLayer.addSublayer(lineLayer)

        if let first = trackPoints.sorted(by: { $0.timestamp < $1.timestamp }).first {
            let seedPoint = CGPoint(
                x: CGFloat(first.x) * renderSize.width,
                y: (1 - CGFloat(first.y)) * renderSize.height
            )
            let seedRing = CAShapeLayer()
            seedRing.path = UIBezierPath(ovalIn: CGRect(x: seedPoint.x - 11, y: seedPoint.y - 11, width: 22, height: 22)).cgPath
            seedRing.fillColor = UIColor.clear.cgColor
            seedRing.strokeColor = UIColor.orange.cgColor
            seedRing.lineWidth = 4
            overlayLayer.addSublayer(seedRing)

            let seedDot = CAShapeLayer()
            seedDot.path = UIBezierPath(ovalIn: CGRect(x: seedPoint.x - 4, y: seedPoint.y - 4, width: 8, height: 8)).cgPath
            seedDot.fillColor = UIColor.orange.cgColor
            overlayLayer.addSublayer(seedDot)
        }

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
    }

    private func smoothedPath(for points: [BallTrackPoint], renderSize: CGSize) -> UIBezierPath {
        let converted = points.map { point in
            CGPoint(
                x: CGFloat(point.x) * renderSize.width,
                y: (1 - CGFloat(point.y)) * renderSize.height
            )
        }
        let path = UIBezierPath()
        guard let first = converted.first else { return path }
        path.move(to: first)

        guard converted.count > 2 else {
            if let last = converted.last, last != first {
                path.addLine(to: last)
            }
            return path
        }

        for i in 1..<(converted.count - 1) {
            let mid = CGPoint(
                x: (converted[i].x + converted[i + 1].x) / 2,
                y: (converted[i].y + converted[i + 1].y) / 2
            )
            path.addQuadCurve(to: mid, controlPoint: converted[i])
        }

        if let last = converted.last {
            path.addLine(to: last)
        }
        return path
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let exporter: AVAssetExportSession

    init(_ exporter: AVAssetExportSession) {
        self.exporter = exporter
    }
}

private extension AVAssetExportSession.Status {
    var description: String {
        switch self {
        case .unknown: return "unknown"
        case .waiting: return "waiting"
        case .exporting: return "exporting"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }
}
