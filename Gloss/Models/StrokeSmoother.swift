import CoreGraphics
import Foundation

/// Catmull-Rom → cubic Bezier path conversion for agent strokes.
///
/// Agents send a list of points; we want a smooth, deterministic path with
/// rounded caps/joins. This produces a CGPath that flows through every input
/// point with controllable tension. Tension 0.5 is the canonical Catmull-Rom.
public enum StrokeSmoother {

    /// Build a smooth path through the given points.
    /// - Parameters:
    ///   - points: at least 1 point. 1 point → degenerate (single dot via stroke
    ///     with rounded cap). 2 points → straight line. 3+ → smoothed.
    ///   - tension: 0.5 = Catmull-Rom, 0 = sharper, 1 = looser. Clamped to [0, 1].
    ///   - simplify: optional resample distance. Points closer than this are dropped.
    public static func smoothPath(points: [CGPoint], tension: CGFloat = 0.5, simplify: CGFloat? = nil) -> CGPath {
        let pts = simplify.map { resample(points: points, minDistance: $0) } ?? points
        guard !pts.isEmpty else { return CGMutablePath() }
        let path = CGMutablePath()
        if pts.count == 1 {
            // Degenerate: a single-point dot is rendered via a 0-length subpath
            // with rounded line caps. Ensure stroke has lineCap = .round.
            path.move(to: pts[0])
            path.addLine(to: pts[0])
            return path
        }
        if pts.count == 2 {
            path.move(to: pts[0])
            path.addLine(to: pts[1])
            return path
        }
        let t = max(0, min(1, tension))
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]
            // Catmull-Rom → Bezier (Holten's formulation)
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * t / 6,
                y: p1.y + (p2.y - p0.y) * t / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * t / 6,
                y: p2.y - (p3.y - p1.y) * t / 6
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// Drop consecutive points within minDistance of each other. Keeps endpoints.
    public static func resample(points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard minDistance > 0, points.count > 2 else { return points }
        var out: [CGPoint] = [points[0]]
        for p in points.dropFirst() {
            if let last = out.last,
               hypot(p.x - last.x, p.y - last.y) >= minDistance {
                out.append(p)
            }
        }
        if let last = out.last, last != points.last, let final = points.last {
            out.append(final)
        }
        return out
    }
}
