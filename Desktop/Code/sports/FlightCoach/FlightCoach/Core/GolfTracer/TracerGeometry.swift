import Foundation
import CoreGraphics

/// Pure geometry, physics gates, resolution/FPS scaling, and coordinate conversions.
/// All functions are deterministic and unit-tested (spec §19). No detection or rendering.
enum TracerGeometry {

    // MARK: - Vector helpers (§12.1)

    static func dot(_ a: CGVector, _ b: CGVector) -> CGFloat { a.dx * b.dx + a.dy * b.dy }

    static func norm(_ v: CGVector) -> CGFloat { hypot(v.dx, v.dy) }

    static func normalized(_ v: CGVector) -> CGVector {
        let n = norm(v)
        guard n > 0.0001 else { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: v.dx / n, dy: v.dy / n)
    }

    static func vector(from a: CGPoint, to b: CGPoint) -> CGVector {
        CGVector(dx: b.x - a.x, dy: b.y - a.y)
    }

    // MARK: - Distance helpers (§12.2)

    static func totalDistance(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        return total
    }

    static func netDisplacement(_ points: [CGPoint]) -> CGFloat {
        guard let first = points.first, let last = points.last else { return 0 }
        return hypot(last.x - first.x, last.y - first.y)
    }

    static func pathEfficiencyRatio(_ points: [CGPoint]) -> CGFloat {
        let net = netDisplacement(points)
        guard net > 1 else { return .infinity }
        return totalDistance(points) / net
    }

    // MARK: - Angle helper (§12.3)

    static func angleDegreesBetween(_ a: CGVector, _ b: CGVector) -> CGFloat {
        let na = norm(a), nb = norm(b)
        guard na > 0.0001, nb > 0.0001 else { return 0 }
        let cosTheta = max(-1, min(1, dot(a, b) / (na * nb)))
        return acos(cosTheta) * 180 / .pi
    }

    // MARK: - Resolution / FPS scaling (§6)

    static func resolutionScale(width: Int, height: Int) -> CGFloat {
        let referenceDiagonal = hypot(CGFloat(3840), CGFloat(2160))
        let actualDiagonal = hypot(CGFloat(width), CGFloat(height))
        guard referenceDiagonal > 0 else { return 1 }
        return actualDiagonal / referenceDiagonal
    }

    static func fpsDisplacementScale(fps: Double) -> CGFloat {
        guard fps > 0 else { return 1 }
        return CGFloat(120.0 / fps)
    }

    static func effectiveRadius(basePx4K120: CGFloat, width: Int, height: Int, fps: Double) -> CGFloat {
        basePx4K120 * resolutionScale(width: width, height: height) * fpsDisplacementScale(fps: fps)
    }

    // MARK: - Hard physical gates (§13)

    static func passesPredictionGate(candidate: CGPoint, predicted: CGPoint, radius: CGFloat) -> Bool {
        hypot(candidate.x - predicted.x, candidate.y - predicted.y) <= radius
    }

    static func isMovingForward(previous: CGPoint, candidate: CGPoint,
                                launchDirection: CGVector, minForwardDot: CGFloat) -> Bool {
        let movement = vector(from: previous, to: candidate)
        return dot(normalized(movement), normalized(launchDirection)) >= minForwardDot
    }

    static func passesAngleGate(p0: CGPoint, p1: CGPoint, p2: CGPoint, maxAngleDegrees: CGFloat) -> Bool {
        let v1 = vector(from: p0, to: p1)
        let v2 = vector(from: p1, to: p2)
        return angleDegreesBetween(v1, v2) <= maxAngleDegrees
    }

    static func passesSpeedGate(p0: CGPoint, p1: CGPoint, p2: CGPoint,
                                minRatio: CGFloat, maxRatio: CGFloat) -> Bool {
        let s1 = hypot(p1.x - p0.x, p1.y - p0.y)
        let s2 = hypot(p2.x - p1.x, p2.y - p1.y)
        guard s1 > 1, s2 > 1 else { return true }
        let ratio = s2 / s1
        return ratio >= minRatio && ratio <= maxRatio
    }

    static func recentPathIsEfficient(_ points: [CGPoint], maxRatio: CGFloat) -> Bool {
        let recent = Array(points.suffix(8))
        guard recent.count >= 4 else { return true }
        return pathEfficiencyRatio(recent) <= maxRatio
    }

    static func isCompactLoopLike(_ points: [CGPoint],
                                  totalDistanceThreshold: CGFloat,
                                  netDistanceThreshold: CGFloat) -> Bool {
        let recent = Array(points.suffix(10))
        guard recent.count >= 6 else { return false }
        let total = totalDistance(recent)
        let net = netDisplacement(recent)
        if total > totalDistanceThreshold && net < netDistanceThreshold { return true }
        if net > 0 && total / net > 2.0 { return true }
        return false
    }

    /// Average direction consistency of a path relative to its overall net direction (§11.5).
    static func averageDirectionConsistency(_ points: [CGPoint]) -> Double {
        guard points.count >= 3, let first = points.first, let last = points.last else { return 1 }
        let overall = normalized(vector(from: first, to: last))
        guard norm(overall) > 0 else { return 0 }
        var sum = 0.0
        var n = 0
        for i in 1..<points.count {
            let step = normalized(vector(from: points[i - 1], to: points[i]))
            if norm(step) > 0 {
                sum += Double(dot(step, overall))   // -1…1
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        return max(0, (sum / Double(n) + 1) / 2)    // 0…1
    }

    /// True if any interior reversal exists (a step pointing opposite to overall direction).
    static func hasImmediateReversal(_ points: [CGPoint]) -> Bool {
        guard points.count >= 3, let first = points.first, let last = points.last else { return false }
        let overall = normalized(vector(from: first, to: last))
        for i in 1..<points.count {
            let step = normalized(vector(from: points[i - 1], to: points[i]))
            if norm(step) > 0 && dot(step, overall) < -0.2 { return true }
        }
        return false
    }

    // MARK: - Coordinate conversions (coordinate-safety section)

    static func cropLocalToFullFrame(_ point: CGPoint, roi: CGRect) -> CGPoint {
        CGPoint(x: roi.origin.x + point.x, y: roi.origin.y + point.y)
    }

    static func cropLocalRectToFullFrame(_ rect: CGRect, roi: CGRect) -> CGRect {
        CGRect(x: roi.origin.x + rect.origin.x, y: roi.origin.y + rect.origin.y,
               width: rect.width, height: rect.height)
    }

    /// Convert a view/preview tap to canonical full-frame pixels (aspect-fit). For
    /// aspect-fill, pass the already-fitted `videoDisplayRect` (the visible video rect).
    static func viewPointToFullFramePoint(_ viewPoint: CGPoint,
                                          videoDisplayRect: CGRect,
                                          frameSize: CGSize) -> CGPoint {
        let xInVideo = viewPoint.x - videoDisplayRect.origin.x
        let yInVideo = viewPoint.y - videoDisplayRect.origin.y
        let scaleX = videoDisplayRect.width > 0 ? frameSize.width / videoDisplayRect.width : 1
        let scaleY = videoDisplayRect.height > 0 ? frameSize.height / videoDisplayRect.height : 1
        return CGPoint(x: xInVideo * scaleX, y: yInVideo * scaleY)
    }
}
