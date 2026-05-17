import SwiftUI
import Vision

struct PoseOverlayView: View {
    let poseFrame: PoseFrame?
    let videoSize: CGSize

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
                    drawConnections(context: context, frame: frame, size: size)
                    drawJoints(context: context, frame: frame, size: size)
                }
            }
        }
    }

    private func drawConnections(context: GraphicsContext, frame: PoseFrame, size: CGSize) {
        for (joint1, joint2) in connections {
            guard let p1 = frame.landmark(named: joint1),
                  let p2 = frame.landmark(named: joint2),
                  p1.confidence > 0.3, p2.confidence > 0.3 else { continue }

            let from = visionToView(x: p1.x, y: p1.y, size: size)
            let to = visionToView(x: p2.x, y: p2.y, size: size)

            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            context.stroke(path, with: .color(.green.opacity(0.75)), lineWidth: 2)
        }
    }

    private func drawJoints(context: GraphicsContext, frame: PoseFrame, size: CGSize) {
        for landmark in frame.landmarks where landmark.confidence > 0.3 {
            let center = visionToView(x: landmark.x, y: landmark.y, size: size)
            let rect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: rect), with: .color(.yellow))
        }
    }

    private func visionToView(x: Float, y: Float, size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(x) * size.width, y: (1.0 - CGFloat(y)) * size.height)
    }
}

struct BallTrailOverlayView: View {
    let trackPoints: [BallTrackPoint]
    let highlightFrameIndex: Int?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard trackPoints.count > 1 else { return }

                var path = Path()
                let sorted = trackPoints.sorted { $0.frameIndex < $1.frameIndex }

                for (i, point) in sorted.enumerated() {
                    let pt = CGPoint(x: CGFloat(point.x) * size.width, y: (1.0 - CGFloat(point.y)) * size.height)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }

                context.stroke(path, with: .color(.orange.opacity(0.8)), lineWidth: 2)

                for point in sorted {
                    let pt = CGPoint(x: CGFloat(point.x) * size.width, y: (1.0 - CGFloat(point.y)) * size.height)
                    let isContact = point.frameIndex == highlightFrameIndex
                    let radius: CGFloat = isContact ? 8 : 4
                    let color: Color = isContact ? .red : .orange
                    let rect = CGRect(x: pt.x - radius / 2, y: pt.y - radius / 2, width: radius, height: radius)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
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
