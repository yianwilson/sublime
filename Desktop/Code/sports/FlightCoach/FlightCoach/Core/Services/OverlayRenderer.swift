import SwiftUI
import Vision

struct PoseOverlayView: View {
    let poseFrame: PoseFrame?
    let videoAspectRatio: CGFloat?

    private let connections: [(String, String)] = {
        func key(_ j: VNHumanBodyPoseObservation.JointName) -> String { j.rawValue.rawValue }
        return [
            (key(.leftShoulder),  key(.rightShoulder)),
            (key(.leftShoulder),  key(.leftElbow)),
            (key(.leftElbow),     key(.leftWrist)),
            (key(.rightShoulder), key(.rightElbow)),
            (key(.rightElbow),    key(.rightWrist)),
            (key(.leftShoulder),  key(.leftHip)),
            (key(.rightShoulder), key(.rightHip)),
            (key(.leftHip),       key(.rightHip)),
            (key(.leftHip),       key(.leftKnee)),
            (key(.leftKnee),      key(.leftAnkle)),
            (key(.rightHip),      key(.rightKnee)),
            (key(.rightKnee),     key(.rightAnkle)),
            (key(.neck),          key(.nose)),
            (key(.leftShoulder),  key(.neck)),
            (key(.rightShoulder), key(.neck)),
        ]
    }()

    var body: some View {
        GeometryReader { geo in
            if let frame = poseFrame {
                Canvas { context, size in
                    let videoRect = fittedVideoRect(in: CGRect(origin: .zero, size: size))
                    drawConnections(context: context, frame: frame, in: videoRect)
                    drawJoints(context: context, frame: frame, in: videoRect)
                }
            }
        }
    }

    private func drawConnections(context: GraphicsContext, frame: PoseFrame, in rect: CGRect) {
        for (joint1, joint2) in connections {
            guard let p1 = frame.landmark(named: joint1),
                  let p2 = frame.landmark(named: joint2),
                  p1.confidence > 0.3, p2.confidence > 0.3 else { continue }

            let from = visionToView(x: p1.x, y: p1.y, in: rect)
            let to   = visionToView(x: p2.x, y: p2.y, in: rect)

            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            context.stroke(path, with: .color(.green.opacity(0.75)), lineWidth: 2)
        }
    }

    private func drawJoints(context: GraphicsContext, frame: PoseFrame, in rect: CGRect) {
        for landmark in frame.landmarks where landmark.confidence > 0.3 {
            let center = visionToView(x: landmark.x, y: landmark.y, in: rect)
            let r: CGFloat = 4
            let dotRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: dotRect), with: .color(.yellow))
        }
    }

    private func visionToView(x: Float, y: Float, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + CGFloat(x) * rect.width,
            y: rect.minY + (1.0 - CGFloat(y)) * rect.height
        )
    }

    private func fittedVideoRect(in bounds: CGRect) -> CGRect {
        guard let ar = videoAspectRatio, ar > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let containerAspect = bounds.width / bounds.height
        if containerAspect > ar {
            let w = bounds.height * ar
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
        } else {
            let h = bounds.width / ar
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        }
    }
}

struct PoseDebugOverlay: View {
    let debug: PoseDebugResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let d = debug {
                badge(d)
                    .padding(6)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func badge(_ d: PoseDebugResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(d.didDetectPose ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(d.didDetectPose ? "Pose detected" : "No pose")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("· f\(d.frameIndex)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }

            if d.didDetectPose {
                Text("\(d.landmarkCount) landmarks · \(Int(d.averageConfidence * 100))% avg conf")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                Text("Key joints: \(Int(d.keyJointCoverage * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
            }

            if let reason = d.failureReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if !d.missingKeyJoints.isEmpty && d.didDetectPose {
                Text("Missing: \(d.missingKeyJoints.prefix(4).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .lineLimit(2)
            }
        }
    }
}

struct BallTrailOverlayView: View {
    let trackPoints: [BallTrackPoint]
    let highlightFrameIndex: Int?
    let videoAspectRatio: CGFloat?
    /// When set, the tracer is revealed only up to this playback time, so the line
    /// "draws on" live as the video plays. Nil draws the whole arc.
    var currentTime: TimeInterval? = nil

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard trackPoints.count > 1 else { return }
                let videoRect = fittedVideoRect(in: CGRect(origin: .zero, size: size))
                let sorted = trackPoints.sorted { $0.timestamp < $1.timestamp }

                let revealed = revealedPoints(sorted)
                guard revealed.count > 1 else {
                    if let head = revealed.first {
                        drawBall(context, at: pointToView(head, in: videoRect))
                    }
                    return
                }

                let viewPoints = revealed.map { pointToView($0, in: videoRect) }

                // Draw trail with progressive thickness and distance-based opacity
                drawProgressiveTrail(context: context, points: viewPoints)

                // Ball at launch (hollow ring) and a live "head" dot at the leading edge.
                drawBall(context, at: viewPoints[0])
                if let head = viewPoints.last {
                    context.fill(
                        Path(ellipseIn: CGRect(x: head.x - 4, y: head.y - 4, width: 8, height: 8)),
                        with: .color(.orange)
                    )
                }
            }
        }
    }

    private func drawProgressiveTrail(context: GraphicsContext, points: [CGPoint]) {
        guard points.count > 1 else { return }

        // Draw trail segments with progressive thickness and opacity
        for i in 0..<(points.count - 1) {
            let start = points[i]
            let end = points[i + 1]

            // Progress along the trail: 0 = start (thin), 1 = end (thick)
            let progress = CGFloat(i) / CGFloat(max(1, points.count - 1))

            // Line width: thin (1.5) at start, thick (5.5) at end
            let lineWidth = 1.5 + progress * 4.0

            // Opacity: 0.5 at start (far), 0.95 at end (close/recent)
            let opacity = 0.5 + progress * 0.45

            var segmentPath = Path()
            segmentPath.move(to: start)
            segmentPath.addLine(to: end)

            context.stroke(
                segmentPath,
                with: .color(.orange.opacity(opacity)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawBall(_ context: GraphicsContext, at pt: CGPoint) {
        let outer = CGRect(x: pt.x - 9, y: pt.y - 9, width: 18, height: 18)
        context.stroke(Path(ellipseIn: outer), with: .color(.orange), lineWidth: 2.5)
    }

    /// Points up to `currentTime`, with an interpolated leading point exactly at the
    /// current time so the line grows smoothly between samples.
    private func revealedPoints(_ sorted: [BallTrackPoint]) -> [BallTrackPoint] {
        guard let now = currentTime else { return sorted }
        guard let first = sorted.first, now >= first.timestamp else { return [] }

        var result: [BallTrackPoint] = []
        for i in 0..<sorted.count {
            if sorted[i].timestamp <= now {
                result.append(sorted[i])
            } else {
                if i > 0 {
                    let a = sorted[i - 1], b = sorted[i]
                    let span = b.timestamp - a.timestamp
                    let f = span > 0 ? Float((now - a.timestamp) / span) : 0
                    result.append(BallTrackPoint(
                        frameIndex: b.frameIndex,
                        timestamp: now,
                        x: a.x + (b.x - a.x) * f,
                        y: a.y + (b.y - a.y) * f,
                        confidence: b.confidence
                    ))
                }
                break
            }
        }
        return result
    }

    private func fittedVideoRect(in bounds: CGRect) -> CGRect {
        guard let videoAspectRatio, videoAspectRatio > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let containerAspect = bounds.width / bounds.height
        if containerAspect > videoAspectRatio {
            let width = bounds.height * videoAspectRatio
            return CGRect(
                x: bounds.midX - width / 2,
                y: bounds.minY,
                width: width,
                height: bounds.height
            )
        } else {
            let height = bounds.width / videoAspectRatio
            return CGRect(
                x: bounds.minX,
                y: bounds.midY - height / 2,
                width: bounds.width,
                height: height
            )
        }
    }

    private func pointToView(_ point: BallTrackPoint, in rect: CGRect) -> CGPoint {
        let x = min(max(CGFloat(point.x), 0), 1)
        let y = min(max(CGFloat(point.y), 0), 1)
        return CGPoint(
            x: rect.minX + x * rect.width,
            y: rect.minY + (1.0 - y) * rect.height
        )
    }

    private func smoothedPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 2 else {
            if let last = points.last, last != first {
                path.addLine(to: last)
            }
            return path
        }

        for i in 1..<(points.count - 1) {
            let mid = CGPoint(
                x: (points[i].x + points[i + 1].x) / 2,
                y: (points[i].y + points[i + 1].y) / 2
            )
            path.addQuadCurve(to: mid, control: points[i])
        }

        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }
}

struct BallTracePointOverlayView: View {
    let point: BallTrackPoint
    let videoAspectRatio: CGFloat?
    var label: String = "Seed"

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let videoRect = fittedVideoRect(in: CGRect(origin: .zero, size: size))
                let pt = pointToView(point, in: videoRect)
                // Hollow ring so the ball stays visible through the marker.
                let outer = CGRect(x: pt.x - 10, y: pt.y - 10, width: 20, height: 20)
                context.stroke(Path(ellipseIn: outer), with: .color(.orange.opacity(0.9)), lineWidth: 2)
            }
            .overlay(alignment: .topLeading) {
                let videoRect = fittedVideoRect(in: CGRect(origin: .zero, size: geo.size))
                let pt = pointToView(point, in: videoRect)
                Text(label)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .position(x: min(max(pt.x + 24, 26), geo.size.width - 26), y: min(max(pt.y - 18, 12), geo.size.height - 12))
            }
        }
    }

    private func fittedVideoRect(in bounds: CGRect) -> CGRect {
        guard let videoAspectRatio, videoAspectRatio > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let containerAspect = bounds.width / bounds.height
        if containerAspect > videoAspectRatio {
            let width = bounds.height * videoAspectRatio
            return CGRect(
                x: bounds.midX - width / 2,
                y: bounds.minY,
                width: width,
                height: bounds.height
            )
        } else {
            let height = bounds.width / videoAspectRatio
            return CGRect(
                x: bounds.minX,
                y: bounds.midY - height / 2,
                width: bounds.width,
                height: height
            )
        }
    }

    private func pointToView(_ point: BallTrackPoint, in rect: CGRect) -> CGPoint {
        let x = min(max(CGFloat(point.x), 0), 1)
        let y = min(max(CGFloat(point.y), 0), 1)
        return CGPoint(
            x: rect.minX + x * rect.width,
            y: rect.minY + (1.0 - y) * rect.height
        )
    }
}

struct ContactFrameMarkerView: View {
    let isContact: Bool

    var body: some View {
        if isContact {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.red, lineWidth: 3)
                .padding(2)
        }
    }
}
