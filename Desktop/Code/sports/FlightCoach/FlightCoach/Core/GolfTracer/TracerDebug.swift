import SwiftUI
import UIKit
import CoreGraphics

/// One detector candidate, in the app's normalised (y-up) overlay space, for the debug view.
struct TracerDebugDot: Identifiable {
    let id = UUID()
    let normalizedPosition: CGPoint   // y-up (0 = bottom), matches BallTrackPoint
    let normalizedBox: CGRect          // y-up normalised
    let source: TracerCandidateSource
}

/// Runs the spec-v3 candidate detector on a single displayed frame and returns its
/// candidates in overlay space, so the user can see whether the ball is even detected.
enum TracerDebugService {
    static func candidates(in image: UIImage) -> [TracerDebugDot] {
        guard let cg = image.cgImage else { return [] }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let frame = TracerFrameInfo(index: 0, timestamp: 0, image: cg, width: cg.width, height: cg.height)
        let cands = TracerCandidateDetector.detect(
            in: frame, previous: nil,
            roiFullFrame: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
            config: GolfTracerConfig())
        return cands.map { c in
            TracerDebugDot(
                normalizedPosition: CGPoint(x: c.position.x / w, y: 1 - c.position.y / h),
                normalizedBox: CGRect(x: c.boundingBox.minX / w,
                                      y: 1 - c.boundingBox.maxY / h,
                                      width: c.boundingBox.width / w,
                                      height: c.boundingBox.height / h),
                source: c.source)
        }
    }
}

/// Debug overlay: draws every detector candidate (boxes) on the current frame so coordinate
/// alignment and detection coverage are visible (spec §18.3).
struct TracerDebugOverlay: View {
    let dots: [TracerDebugDot]
    let videoAspectRatio: CGFloat?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let videoRect = fittedVideoRect(in: CGRect(origin: .zero, size: size))
                for dot in dots {
                    let r = rect(dot.normalizedBox, in: videoRect)
                    let inflated = r.insetBy(dx: -3, dy: -3)
                    context.stroke(Path(roundedRect: inflated, cornerRadius: 3),
                                   with: .color(.cyan.opacity(0.9)), lineWidth: 1.5)
                }
            }
        }
    }

    private func rect(_ box: CGRect, in videoRect: CGRect) -> CGRect {
        // box is y-up normalised; flip to top-left view space.
        CGRect(x: videoRect.minX + box.minX * videoRect.width,
               y: videoRect.minY + (1 - box.maxY) * videoRect.height,
               width: box.width * videoRect.width,
               height: box.height * videoRect.height)
    }

    private func fittedVideoRect(in bounds: CGRect) -> CGRect {
        guard let videoAspectRatio, videoAspectRatio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let containerAspect = bounds.width / bounds.height
        if containerAspect > videoAspectRatio {
            let width = bounds.height * videoAspectRatio
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        } else {
            let height = bounds.width / videoAspectRatio
            return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
    }
}
