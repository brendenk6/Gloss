import Foundation
import CoreGraphics

/// Stamp-based brush rasterizer for v1.2.
///
/// CanvasStore uses BrushEngine when:
///   - the command's `brush` is anything other than `.round`, OR
///   - the command provides per-point `pressures`, OR
///   - the command requests a `taper` other than `.none`.
///
/// `.round` strokes with uniform pressure still go through CGContext.strokePath()
/// for the smoothest, fastest result.
///
/// All stamp positions and per-pixel scatter are deterministic given the same
/// seed. Seed = djb2(idempotencyKey) when present, otherwise djb2(canonical
/// payload fields + author + layerID). Never wall clock, never revision.
@MainActor
public enum BrushEngine {

    public static let defaultStampedBrushes: Set<GlossBrushKind> = [
        .calligraphy, .marker, .pencil, .airbrush, .chalk,
        .ink, .ribbon, .glaze
    ]

    public struct StrokeRequest {
        public let points: [CGPoint]      // already smoothed/flattened, top-left origin
        public let baseWidth: Double
        public let color: GlossColor
        public let opacity: Double
        public let blend: GlossBlend
        public let brush: GlossBrushKind
        public let brushAngle: Double     // radians
        public let pressures: [Double]?   // 0..1, count == points.count or nil
        public let taper: GlossTaper
        public let seed: UInt64
        public let canvasWidth: Int
        public let canvasHeight: Int

        public init(points: [CGPoint], baseWidth: Double, color: GlossColor,
                    opacity: Double, blend: GlossBlend, brush: GlossBrushKind,
                    brushAngle: Double, pressures: [Double]?, taper: GlossTaper,
                    seed: UInt64, canvasWidth: Int, canvasHeight: Int) {
            self.points = points
            self.baseWidth = max(0.1, baseWidth)
            self.color = color
            self.opacity = max(0, min(1, opacity))
            self.blend = blend
            self.brush = brush
            self.brushAngle = brushAngle
            self.pressures = pressures
            self.taper = taper
            self.seed = seed
            self.canvasWidth = canvasWidth
            self.canvasHeight = canvasHeight
        }
    }

    public static func render(into ctx: CGContext, request r: StrokeRequest) -> CGRect {
        guard !r.points.isEmpty else { return .null }
        if r.points.count == 1 {
            var rng = LCG(seed: r.seed)
            return stampOnce(
                into: ctx,
                brush: r.brush,
                x: r.points[0].x, y: r.points[0].y,
                width: r.baseWidth,
                direction: 0,
                brushAngle: r.brushAngle,
                color: r.color,
                opacity: r.opacity,
                blend: r.blend,
                rng: &rng
            )
        }

        // Arclength table per anchor.
        var lengths = [Double](repeating: 0, count: r.points.count)
        for i in 1..<r.points.count {
            let dx = r.points[i].x - r.points[i-1].x
            let dy = r.points[i].y - r.points[i-1].y
            lengths[i] = lengths[i-1] + Double(hypot(dx, dy))
        }
        let totalLen = lengths.last ?? 0
        guard totalLen > 0 else {
            var rng = LCG(seed: r.seed)
            return stampOnce(
                into: ctx,
                brush: r.brush,
                x: r.points[0].x, y: r.points[0].y,
                width: r.baseWidth,
                direction: 0,
                brushAngle: r.brushAngle,
                color: r.color,
                opacity: r.opacity,
                blend: r.blend,
                rng: &rng
            )
        }

        let spacing = self.spacing(for: r.brush, baseWidth: r.baseWidth)
        let taperLen = min(totalLen * 0.5, max(r.baseWidth * 2, totalLen * 0.15))

        var rng = LCG(seed: r.seed)
        var bbox: CGRect = .null

        ctx.saveGState()
        ctx.setBlendMode(r.blend.cgBlend)
        defer { ctx.restoreGState() }

        var s = 0.0
        var segIdx = 0
        // Loop until we've covered totalLen, including a final stamp at the end.
        while s <= totalLen + 1e-6 {
            while segIdx < lengths.count - 2 && s > lengths[segIdx + 1] {
                segIdx += 1
            }
            let s0 = lengths[segIdx]
            let s1 = lengths[segIdx + 1]
            let t = (s1 > s0) ? (s - s0) / (s1 - s0) : 0
            let p0 = r.points[segIdx]
            let p1 = r.points[segIdx + 1]
            let sx = Double(p0.x) + (Double(p1.x) - Double(p0.x)) * t
            let sy = Double(p0.y) + (Double(p1.y) - Double(p0.y)) * t

            let pressure = interpolatePressure(
                pressures: r.pressures,
                lengths: lengths,
                arc: s,
                segIdx: segIdx,
                t: t
            )
            let taperFactor = taperFactor(
                s: s, totalLen: totalLen,
                taperLen: taperLen, taper: r.taper
            )
            let effective = r.baseWidth * pressure * taperFactor
            if effective >= 0.5 {
                let dx = p1.x - p0.x
                let dy = p1.y - p0.y
                let direction = atan2(Double(dy), Double(dx))
                let stamp = stampOnce(
                    into: ctx,
                    brush: r.brush,
                    x: sx, y: sy,
                    width: effective,
                    direction: direction,
                    brushAngle: r.brushAngle,
                    color: r.color,
                    opacity: r.opacity,
                    blend: r.blend,
                    rng: &rng
                )
                bbox = bbox.isNull ? stamp : bbox.union(stamp)
            }
            s += spacing
        }
        return bbox
    }

    // MARK: - Stamping per brush

    private static func stampOnce(into ctx: CGContext,
                                  brush: GlossBrushKind,
                                  x: Double, y: Double,
                                  width: Double,
                                  direction: Double,
                                  brushAngle: Double,
                                  color: GlossColor,
                                  opacity: Double,
                                  blend: GlossBlend,
                                  rng: inout LCG) -> CGRect {
        switch brush {
        case .round:
            return stampRound(ctx: ctx, x: x, y: y, width: width,
                              color: color, opacity: opacity)
        case .calligraphy:
            return stampCalligraphy(ctx: ctx, x: x, y: y, width: width,
                                    direction: direction, brushAngle: brushAngle,
                                    color: color, opacity: opacity)
        case .marker:
            return stampMarker(ctx: ctx, x: x, y: y, width: width,
                               color: color, opacity: opacity)
        case .pencil:
            return stampPencil(ctx: ctx, x: x, y: y, width: width,
                               color: color, opacity: opacity, rng: &rng)
        case .airbrush:
            return stampAirbrush(ctx: ctx, x: x, y: y, width: width,
                                 color: color, opacity: opacity, rng: &rng)
        case .chalk:
            return stampChalk(ctx: ctx, x: x, y: y, width: width,
                              color: color, opacity: opacity, rng: &rng)
        case .ink:
            return stampInk(ctx: ctx, x: x, y: y, width: width,
                            color: color, opacity: opacity, rng: &rng)
        case .ribbon:
            return stampRibbon(ctx: ctx, x: x, y: y, width: width,
                               direction: direction, brushAngle: brushAngle,
                               color: color, opacity: opacity, rng: &rng)
        case .glaze:
            return stampGlaze(ctx: ctx, x: x, y: y, width: width,
                              direction: direction, color: color,
                              opacity: opacity)
        }
    }

    private static func stampRound(ctx: CGContext, x: Double, y: Double,
                                   width: Double, color: GlossColor,
                                   opacity: Double) -> CGRect {
        let alpha = max(0, min(1, color.a * opacity))
        let r = width / 2
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(alpha)))
        let rect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
        ctx.fillEllipse(in: rect)
        return rect
    }

    private static func stampCalligraphy(ctx: CGContext, x: Double, y: Double,
                                         width: Double, direction: Double,
                                         brushAngle: Double,
                                         color: GlossColor, opacity: Double) -> CGRect {
        // Width along stroke direction tapers per Codex's formula:
        //   w = base * (1 - |cos(strokeDir - nibAngle)| * 0.7)
        // The stamp is an ellipse rotated by the nib angle. Its long axis is the
        // resolved width; its short axis is the nib thickness (~22% of long).
        let cosTerm = abs(cos(direction - brushAngle))
        let resolvedWidth = max(0.4, width * (1 - cosTerm * 0.7))
        let major = resolvedWidth
        let minor = max(0.4, resolvedWidth * 0.22)
        let alpha = max(0, min(1, color.a * opacity))
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
        ctx.rotate(by: CGFloat(brushAngle))
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(alpha)))
        ctx.fillEllipse(in: CGRect(x: -major / 2, y: -minor / 2,
                                   width: major, height: minor))
        let radius = max(major, minor) / 2
        return CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
    }

    private static func stampMarker(ctx: CGContext, x: Double, y: Double,
                                    width: Double, color: GlossColor,
                                    opacity: Double) -> CGRect {
        // A solid core with a soft outer ring (lower alpha) — simulates a
        // felt-tip marker's edge bloom.
        let alphaCore = max(0, min(1, color.a * opacity))
        let alphaRing = max(0, min(1, alphaCore * 0.35))
        let core = width / 2
        let ring = width * 0.65
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(alphaRing)))
        ctx.fillEllipse(in: CGRect(x: x - ring, y: y - ring, width: 2 * ring, height: 2 * ring))
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(alphaCore)))
        ctx.fillEllipse(in: CGRect(x: x - core, y: y - core, width: 2 * core, height: 2 * core))
        return CGRect(x: x - ring, y: y - ring, width: 2 * ring, height: 2 * ring)
    }

    private static func stampPencil(ctx: CGContext, x: Double, y: Double,
                                    width: Double, color: GlossColor,
                                    opacity: Double, rng: inout LCG) -> CGRect {
        // Many tiny low-alpha dots with slight position jitter — graphite feel.
        let alpha = max(0, min(1, color.a * opacity * 0.32))
        let dots = max(3, Int(round(width * 1.2)))
        let radius = max(0.4, width * 0.18)
        let pad = radius
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(alpha)))
        for _ in 0..<dots {
            let theta = rng.nextDouble() * 2 * .pi
            let rho  = rng.nextDouble() * (width / 2)
            let dx = cos(theta) * rho
            let dy = sin(theta) * rho
            let px = x + dx
            let py = y + dy
            ctx.fillEllipse(in: CGRect(x: px - radius, y: py - radius,
                                       width: 2 * radius, height: 2 * radius))
        }
        let r = (width / 2) + pad
        return CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
    }

    private static func stampAirbrush(ctx: CGContext, x: Double, y: Double,
                                      width: Double, color: GlossColor,
                                      opacity: Double, rng: inout LCG) -> CGRect {
        // Gaussian-distributed pixel scatter. Each pixel is one square; density
        // scales with width. Per-pixel alpha is small so density builds up
        // naturally as strokes overlap.
        let baseAlpha = max(0, min(1, color.a * opacity * 0.18))
        let sigma = width * 0.42
        let count = max(8, Int(round(width * 4)))
        let pad: Double = sigma * 2.4
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(baseAlpha)))
        for _ in 0..<count {
            let nx = rng.nextNormal()
            let ny = rng.nextNormal()
            let px = x + nx * sigma
            let py = y + ny * sigma
            ctx.fill(CGRect(x: px, y: py, width: 1, height: 1))
        }
        return CGRect(x: x - pad, y: y - pad, width: 2 * pad, height: 2 * pad)
    }

    private static func stampChalk(ctx: CGContext, x: Double, y: Double,
                                   width: Double, color: GlossColor,
                                   opacity: Double, rng: inout LCG) -> CGRect {
        // Grainy texture: many small rects across a circular footprint, half
        // randomly skipped to leave gaps. Alpha is medium so chalk strokes look
        // dusty without disappearing.
        let alpha = max(0, min(1, color.a * opacity * 0.65))
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(alpha)))
        let radius = width / 2
        let grainCount = max(8, Int(round(width * 5)))
        for _ in 0..<grainCount {
            // Skip ~45% to expose grain.
            if rng.nextDouble() < 0.45 { continue }
            let theta = rng.nextDouble() * 2 * .pi
            let rho  = sqrt(rng.nextDouble()) * radius
            let dx = cos(theta) * rho
            let dy = sin(theta) * rho
            let grainW = max(0.6, rng.nextDouble(in: 0.6..<1.6))
            ctx.fill(CGRect(x: x + dx, y: y + dy, width: grainW, height: grainW))
        }
        return CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
    }

    private static func stampInk(ctx: CGContext, x: Double, y: Double,
                                 width: Double, color: GlossColor,
                                 opacity: Double, rng: inout LCG) -> CGRect {
        // Wet pressure ink: dense core, tiny soft shoulder, and sub-pixel
        // wobble so pressure-tapered curves do not look mechanically perfect.
        let r = width / 2
        let wobble = min(0.65, width * 0.025)
        let px = x + rng.nextDouble(in: -wobble..<wobble)
        let py = y + rng.nextDouble(in: -wobble..<wobble)
        let alpha = max(0, min(1, color.a * opacity))
        let shoulderAlpha = max(0, min(1, alpha * 0.18))

        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(shoulderAlpha)))
        let shoulder = r * 1.16
        ctx.fillEllipse(in: CGRect(x: px - shoulder, y: py - shoulder,
                                   width: shoulder * 2, height: shoulder * 2))

        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(alpha)))
        ctx.fillEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))

        return CGRect(x: px - shoulder, y: py - shoulder,
                      width: shoulder * 2, height: shoulder * 2)
    }

    private static func stampRibbon(ctx: CGContext, x: Double, y: Double,
                                    width: Double, direction: Double,
                                    brushAngle: Double,
                                    color: GlossColor,
                                    opacity: Double,
                                    rng: inout LCG) -> CGRect {
        // A pressure ribbon like a flat flexible nib. With brushAngle at zero,
        // the nib follows the curve normal; non-zero brushAngle locks the nib
        // to a caller-chosen angle for more traditional calligraphy.
        let followAngle = abs(brushAngle) < 1e-9 ? direction + (.pi / 2) : brushAngle
        let major = max(0.5, width)
        let minor = max(0.45, width * 0.34)
        let alpha = max(0, min(1, color.a * opacity))
        let jitter = min(0.4, width * 0.01)
        let px = x + rng.nextDouble(in: -jitter..<jitter)
        let py = y + rng.nextDouble(in: -jitter..<jitter)

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: CGFloat(px), y: CGFloat(py))
        ctx.rotate(by: CGFloat(followAngle))

        let outerAlpha = max(0, min(1, alpha * 0.16))
        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(outerAlpha)))
        ctx.fillEllipse(in: CGRect(x: -major * 0.55, y: -minor * 0.85,
                                   width: major * 1.1, height: minor * 1.7))

        ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                 alpha: CGFloat(alpha)))
        ctx.fillEllipse(in: CGRect(x: -major / 2, y: -minor / 2,
                                   width: major, height: minor))

        let radius = max(major * 0.55, minor)
        return CGRect(x: px - radius, y: py - radius,
                      width: radius * 2, height: radius * 2)
    }

    private static func stampGlaze(ctx: CGContext, x: Double, y: Double,
                                   width: Double, direction: Double,
                                   color: GlossColor,
                                   opacity: Double) -> CGRect {
        // Transparent marker / glaze. Repeated passes build a saturated center
        // while the edges stay feathered, matching broad soft strokes.
        let alpha = max(0, min(1, color.a * opacity))
        let angle = direction
        let major = max(1.0, width * 0.74)
        let minor = max(1.0, width * 0.50)

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
        ctx.rotate(by: CGFloat(angle))

        let rings: [(scale: Double, alpha: Double)] = [
            (1.35, 0.014),
            (1.02, 0.024),
            (0.72, 0.038),
            (0.46, 0.052)
        ]
        for ring in rings {
            ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b,
                                     alpha: CGFloat(max(0, min(1, alpha * ring.alpha)))))
            ctx.fillEllipse(in: CGRect(
                x: -major * ring.scale,
                y: -minor * ring.scale,
                width: major * ring.scale * 2,
                height: minor * ring.scale * 2
            ))
        }

        let radius = max(major, minor) * 1.25
        return CGRect(x: x - radius, y: y - radius,
                      width: radius * 2, height: radius * 2)
    }

    // MARK: - Spacing / pressure / taper

    private static func spacing(for brush: GlossBrushKind, baseWidth: Double) -> Double {
        switch brush {
        case .round:        return max(1.0, baseWidth * 0.25)
        case .calligraphy:  return max(0.5, baseWidth * 0.16)
        case .marker:       return max(1.0, baseWidth * 0.30)
        case .pencil:       return max(1.0, baseWidth * 0.40)
        case .airbrush:     return max(2.0, baseWidth * 0.50)
        case .chalk:        return max(1.0, baseWidth * 0.32)
        case .ink:          return max(0.5, baseWidth * 0.12)
        case .ribbon:       return max(0.35, baseWidth * 0.012)
        case .glaze:        return max(0.75, baseWidth * 0.060)
        }
    }

    private static func interpolatePressure(pressures: [Double]?,
                                            lengths: [Double],
                                            arc: Double,
                                            segIdx: Int,
                                            t: Double) -> Double {
        guard let pressures, pressures.count == lengths.count else { return 1 }
        let p0 = pressures[segIdx]
        let p1 = pressures[min(segIdx + 1, pressures.count - 1)]
        let result = p0 + (p1 - p0) * t
        return max(0, min(1, result))
    }

    private static func taperFactor(s: Double, totalLen: Double,
                                    taperLen: Double, taper: GlossTaper) -> Double {
        guard totalLen > 0, taperLen > 0 else { return 1 }
        switch taper {
        case .none:
            return 1
        case .in:
            return min(1, s / taperLen)
        case .out:
            return min(1, (totalLen - s) / taperLen)
        case .both:
            return min(1, s / taperLen) * min(1, (totalLen - s) / taperLen)
        }
    }

    // MARK: - Seed helper

    public static func seed(idempotencyKey: String?, author: String?,
                            layerID: String?, fields: [String]) -> UInt64 {
        if let key = idempotencyKey, !key.isEmpty {
            return djb2Hash64(key)
        }
        var combined = ""
        if let author { combined += "@\(author)" }
        if let layerID { combined += "#\(layerID)" }
        if !fields.isEmpty {
            combined += "|" + fields.joined(separator: "|")
        }
        return djb2Hash64(combined)
    }

    private static func djb2Hash64(_ s: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in s.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        return hash
    }
}

// MARK: - LCG (deterministic stream)

/// Minimal seeded PRNG. Same seed → same stream; never references wall clock.
public struct LCG {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed != 0 ? seed : 0xDEAD_BEEF_CAFE_BABE
    }

    public mutating func nextU64() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    public mutating func nextDouble() -> Double {
        let v = nextU64() >> 11
        return Double(v) / Double(UInt64(1) << 53)
    }

    public mutating func nextDouble(in range: Range<Double>) -> Double {
        let r = nextDouble()
        return range.lowerBound + r * (range.upperBound - range.lowerBound)
    }

    /// Box-Muller standard normal.
    public mutating func nextNormal() -> Double {
        let u1 = max(1e-9, nextDouble())
        let u2 = nextDouble()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
