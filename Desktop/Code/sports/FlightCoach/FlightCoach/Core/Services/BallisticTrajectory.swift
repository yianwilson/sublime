import Foundation
import CoreGraphics

/// Fits a ballistic arc to the confidently-tracked launch points and extrapolates
/// the invisible remainder of the flight. A golf ball is a parabola: once the early
/// (visible) launch arc is measured, the rest is determined — so we track only what
/// is reliably visible and *predict* the apex/descent/landing.
///
/// Curves are parametric quadratics in time — x(t), y(t) — so the fit works for any
/// camera angle (a down-the-line shot that goes nearly straight up as well as a
/// face-on arc). Coordinates are normalised, origin bottom-left, y up.
enum BallisticTrajectory {

    /// Returns a dense arc (launch → extrapolated landing) with real timestamps, or
    /// nil when the input doesn't form a plausible ballistic launch.
    static func fit(points: [BallTrackPoint], frameInterval: TimeInterval) -> [BallTrackPoint]? {
        let cleaned = collapseStaticPrefix(points.sorted { $0.timestamp < $1.timestamp })
        guard cleaned.count >= 3 else { return nil }

        let t0 = cleaned.first!.timestamp
        let ts = cleaned.map { $0.timestamp - t0 }
        let xs = cleaned.map { Double($0.x) }
        let ys = cleaned.map { Double($0.y) }

        guard let fx = quadraticFit(t: ts, v: xs),
              let fy = quadraticFit(t: ts, v: ys) else { return nil }

        // The vertical must arc: rise then fall ⇒ concave (ay < 0) in y-up space.
        guard fy.a < -0.015 else { return nil }

        let launchY = ys.first!
        let lastT = ts.last!
        // Landing: the later time where y returns to launch height.
        let landingT = largerRoot(a: fy.a, b: fy.b, c: fy.c - launchY) ?? (lastT * 2)
        guard landingT > lastT else { return nil }      // fit must extend past data
        let endT = min(landingT, lastT + 5.0)           // safety cap on flight time

        let dt = max(frameInterval, 1.0 / 120.0)
        var arc: [BallTrackPoint] = []
        var frame = cleaned.first!.frameIndex
        var t = 0.0
        while t <= endT {
            let x = fx.a * t * t + fx.b * t + fx.c
            let y = fy.a * t * t + fy.b * t + fy.c
            arc.append(BallTrackPoint(
                frameIndex: frame,
                timestamp: t0 + t,
                x: Float(min(max(x, -0.05), 1.05)),
                y: Float(min(max(y, -0.05), 1.05)),
                confidence: t <= lastT ? 0.9 : 0.5      // measured vs predicted
            ))
            // Stop once it returns to/below the ground or clearly leaves the frame.
            if t > lastT, y <= launchY - 0.02 { break }
            if x < -0.04 || x > 1.04 || y > 1.04 { break }
            t += dt
            frame += 1
        }

        return arc.count >= 3 ? arc : nil
    }

    /// Extension for launches that exit the frame while still rising (the
    /// behind-ball camera): no apex is visible, so the parabola can't anchor
    /// — and a quadratic extrapolated from a ~0.15s window amplifies
    /// curvature noise (measured: it undershot the real flight by 0.14+).
    /// A straight continuation of the final velocity tracked the real ball
    /// to within ~0.06 on ground truth.
    static func extendLaunch(points: [BallTrackPoint], frameInterval: TimeInterval) -> [BallTrackPoint]? {
        let pts = points.sorted { $0.timestamp < $1.timestamp }
        guard pts.count >= 4, let last = pts.last else { return nil }
        let ref = pts[pts.count - min(4, pts.count)]
        let dt = last.timestamp - ref.timestamp
        guard dt > 0.01 else { return nil }
        let vx = Double(last.x - ref.x) / dt
        let vy = Double(last.y - ref.y) / dt
        guard vy > 0.05 else { return nil }            // must still be rising

        var arc = pts
        let step = max(frameInterval, 1.0 / 120.0)
        var t = last.timestamp
        var x = Double(last.x)
        var y = Double(last.y)
        var frame = last.frameIndex
        while t - last.timestamp < 1.2 {
            t += step
            frame += 1
            x += vx * step
            y += vy * step
            if x < -0.02 || x > 1.02 || y > 1.02 { break }
            arc.append(BallTrackPoint(frameIndex: frame, timestamp: t,
                                      x: Float(x), y: Float(y), confidence: 0.5))
        }
        return arc.count > pts.count ? arc : nil
    }

    // MARK: - Helpers

    /// Drop the static prefix (ball at rest at address) so the arc — and therefore
    /// the live reveal — begins at the first real ball motion (≈ impact), not while
    /// the ball is still sitting at address.
    private static func collapseStaticPrefix(_ points: [BallTrackPoint]) -> [BallTrackPoint] {
        guard let first = points.first else { return points }
        let origin = CGPoint(x: CGFloat(first.x), y: CGFloat(first.y))
        guard let firstMoving = points.firstIndex(where: {
            hypot(CGFloat($0.x) - origin.x, CGFloat($0.y) - origin.y) > 0.02
        }) else {
            return points
        }
        return Array(points[firstMoving...])
    }

    private struct Quadratic { let a, b, c: Double }

    /// Least-squares fit v ≈ a·t² + b·t + c.
    private static func quadraticFit(t: [Double], v: [Double]) -> Quadratic? {
        guard t.count >= 3 else { return nil }
        var s0 = Double(t.count), s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var r0 = 0.0, r1 = 0.0, r2 = 0.0
        for i in 0..<t.count {
            let ti = t[i], vi = v[i]
            let t2 = ti * ti
            s1 += ti; s2 += t2; s3 += t2 * ti; s4 += t2 * t2
            r0 += vi; r1 += vi * ti; r2 += vi * t2
        }
        let m = [[s4, s3, s2], [s3, s2, s1], [s2, s1, s0]]
        guard let sol = solve3x3(m, [r2, r1, r0]) else { return nil }
        return Quadratic(a: sol[0], b: sol[1], c: sol[2])
    }

    private static func solve3x3(_ m: [[Double]], _ r: [Double]) -> [Double]? {
        let det = determinant(m)
        guard abs(det) > 1e-12 else { return nil }
        var result = [Double](repeating: 0, count: 3)
        for col in 0..<3 {
            var mc = m
            for row in 0..<3 { mc[row][col] = r[row] }
            result[col] = determinant(mc) / det
        }
        return result
    }

    private static func determinant(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    private static func largerRoot(a: Double, b: Double, c: Double) -> Double? {
        guard abs(a) > 1e-12 else { return nil }
        let disc = b * b - 4 * a * c
        guard disc >= 0 else { return nil }
        let sq = disc.squareRoot()
        return max((-b + sq) / (2 * a), (-b - sq) / (2 * a))
    }
}
