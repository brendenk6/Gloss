import Foundation
import CoreGraphics
import AppKit
import Observation

/// The single source of truth for the Gloss canvas.
///
/// Owns a CGContext (sRGB premultiplied RGBA). All mutations route through
/// `apply(_:)` on @MainActor — CGContext is not thread-safe and we don't try
/// to make it so. Snapshots return a cached CGImage that's invalidated on
/// every mutation, so SwiftUI views can observe `revision` and refresh cheaply.
@MainActor
@Observable
public final class CanvasStore {

    // MARK: - Configuration

    public private(set) var width: Int
    public private(set) var height: Int

    /// Bumped on every mutation. SwiftUI views observe this and pull a fresh
    /// snapshot through `currentImage`.
    public private(set) var revision: Int = 0

    /// Recent commands for the chrome overlay. Capped at 32.
    public private(set) var lastCommands: [LastCommandSummary] = []

    /// Last cursor position per author, for the floating "X was here" tags.
    public private(set) var authorCursors: [String: GlossPoint] = [:]

    /// Idempotency cache. Maps key → revision at which it was applied. ~256 entries.
    private var idempotencyCache: [String: Int] = [:]
    private var idempotencyKeyOrder: [String] = []
    private let idempotencyCacheCap = 256

    /// Undo stack: list of CGImage snapshots taken before each mutation.
    /// Kept short to avoid memory blowup. ~32 entries.
    private var undoStack: [(image: CGImage, summary: LastCommandSummary)] = []
    private var redoStack: [(image: CGImage, summary: LastCommandSummary)] = []
    private let undoCap = 32

    // MARK: - Backing storage

    private var context: CGContext
    private var cachedImage: CGImage?

    /// Public read-only access to the current image. Cached; recomputed on revision change.
    public var currentImage: CGImage {
        if let cached = cachedImage { return cached }
        let img = context.makeImage()!
        cachedImage = img
        return img
    }

    // MARK: - Init

    public init(width: Int = 1024, height: Int = 1024, background: GlossColor = GlossColor(r: 1, g: 1, b: 1)) {
        self.width = width
        self.height = height
        self.context = Self.makeContext(width: width, height: height)
        self.fillBackground(background)
        self.cachedImage = self.context.makeImage()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            fatalError("Gloss: failed to create CGContext at \(width)x\(height)")
        }
        // Top-left origin to match Apple imaging convention used in the API spec.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        return ctx
    }

    private static func validDirtyRect(_ rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        let standardized = rect.standardized
        guard !standardized.isNull, !standardized.isInfinite, !standardized.isEmpty else {
            return nil
        }
        guard standardized.origin.x.isFinite,
              standardized.origin.y.isFinite,
              standardized.size.width.isFinite,
              standardized.size.height.isFinite else {
            return nil
        }
        return standardized
    }

    private func fillBackground(_ color: GlossColor) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    // MARK: - Public command surface

    /// Apply a command. Mutations bump revision and invalidate snapshots.
    /// Returns CommandResult including dirtyRect (best-effort).
    @discardableResult
    public func apply(_ command: DrawCommand) throws -> CommandResult {
        // Idempotency
        if let key = command.idempotencyKey, let priorRev = idempotencyCache[key] {
            return CommandResult(revision: priorRev, dirtyRect: nil, deduped: true)
        }

        // Snapshot for undo BEFORE mutating (skip on undo/redo themselves).
        let isHistoryOp: Bool = {
            if case .undo = command { return true }
            if case .redo = command { return true }
            return false
        }()

        var snapshotForUndo: CGImage? = nil
        if !isHistoryOp {
            snapshotForUndo = context.makeImage()
        }

        let dirty: CGRect?
        switch command {
        case .stroke(let p):    dirty = drawStroke(p)
        case .shape(let p):     dirty = drawShape(p)
        case .text(let p):      dirty = drawText(p)
        case .image(let p):     dirty = drawImage(p)
        case .clear(let p):     dirty = drawClear(p)
        case .undo:             dirty = performUndo()
        case .redo:             dirty = performRedo()
        case .resize(let p):    dirty = performResize(p)
        }

        revision += 1
        cachedImage = nil

        // Update lastCommands log (cap 32, newest first)
        let summary = LastCommandSummary(
            revision: revision,
            kind: command.displayKind,
            author: command.author,
            idempotencyKey: command.idempotencyKey
        )
        lastCommands.insert(summary, at: 0)
        if lastCommands.count > 32 { lastCommands.removeLast(lastCommands.count - 32) }

        // Update author cursor based on last-touch point
        if let author = command.author, let cursor = lastCursor(for: command) {
            authorCursors[author] = cursor
        }

        // Idempotency record
        if let key = command.idempotencyKey {
            idempotencyCache[key] = revision
            idempotencyKeyOrder.append(key)
            if idempotencyKeyOrder.count > idempotencyCacheCap {
                let evict = idempotencyKeyOrder.removeFirst()
                idempotencyCache.removeValue(forKey: evict)
            }
        }

        // Undo stack push (after we know mutation succeeded)
        if let snap = snapshotForUndo {
            undoStack.append((snap, summary))
            if undoStack.count > undoCap { undoStack.removeFirst() }
            // Any new mutation invalidates redo
            redoStack.removeAll()
        }

        return CommandResult(revision: revision, dirtyRect: Self.validDirtyRect(dirty).map(GlossRect.init), deduped: false)
    }

    /// Snapshot the whole canvas, optionally downscaled to fit within maxDim
    /// on the longest side. Returns a CGImage in sRGB.
    public func snapshot(maxDim: Int? = nil) -> CGImage {
        let img = currentImage
        guard let maxDim, maxDim > 0, maxDim < max(width, height) else { return img }
        let scale = CGFloat(maxDim) / CGFloat(max(width, height))
        let outW = max(1, Int((CGFloat(width) * scale).rounded()))
        let outH = max(1, Int((CGFloat(height) * scale).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? img
    }

    /// Snapshot a specific region at native or scaled resolution.
    public func snapshot(region: CGRect, scale: CGFloat = 1) -> CGImage? {
        let bounded = region.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !bounded.isEmpty else { return nil }
        let outW = max(1, Int((bounded.width * scale).rounded()))
        let outH = max(1, Int((bounded.height * scale).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        // Translate so we render the requested region into the output image.
        let drawRect = CGRect(
            x: -bounded.minX * scale,
            y: -(CGFloat(height) - bounded.maxY) * scale,
            width: CGFloat(width) * scale,
            height: CGFloat(height) * scale
        )
        ctx.draw(currentImage, in: drawRect)
        return ctx.makeImage()
    }

    /// Sample the pixel at the given coordinate. Top-left origin, y down.
    public func sample(at point: CGPoint) -> RGBA? {
        let px = Int(point.x.rounded())
        let py = Int(point.y.rounded())
        guard px >= 0, px < width, py >= 0, py < height else { return nil }
        guard let data = context.data else { return nil }
        let bytesPerRow = context.bytesPerRow
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let offset = py * bytesPerRow + px * 4
        let r = ptr[offset + 0]
        let g = ptr[offset + 1]
        let b = ptr[offset + 2]
        let a = ptr[offset + 3]
        // Premultiplied → straight (display-correct)
        if a == 0 {
            return RGBA(r: 0, g: 0, b: 0, a: 0)
        }
        let af = Double(a) / 255
        return RGBA(
            r: Int(round(min(255, Double(r) / af))),
            g: Int(round(min(255, Double(g) / af))),
            b: Int(round(min(255, Double(b) / af))),
            a: Int(a)
        )
    }

    /// Public state envelope for /state.
    public var state: CanvasState {
        CanvasState(
            width: width,
            height: height,
            revision: revision,
            lastCommands: lastCommands,
            authorCursors: authorCursors
        )
    }

    // MARK: - Drawing implementations

    private func drawStroke(_ p: StrokePayload) -> CGRect {
        let cgPoints = p.points.map(\.cgPoint)
        let path = StrokeSmoother.smoothPath(
            points: cgPoints,
            tension: 0.5,
            simplify: p.simplify.map { CGFloat($0) }
        )
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(p.blend.cgBlend)
        let baseAlpha = p.color.a * p.opacity
        let strokeColor = CGColor(srgbRed: p.color.r, green: p.color.g, blue: p.color.b, alpha: baseAlpha)
        context.setStrokeColor(strokeColor)
        context.setLineWidth(p.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        return path.boundingBoxOfPath.insetBy(dx: -p.width, dy: -p.width)
    }

    private func drawShape(_ p: ShapePayload) -> CGRect {
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(p.blend.cgBlend)
        context.setAlpha(p.opacity)

        let path = CGMutablePath()
        var bounds: CGRect = .null
        switch p.kind {
        case .rect:
            let r = CGRect(x: p.x, y: p.y, width: p.w ?? 0, height: p.h ?? 0)
            path.addRect(r); bounds = r
        case .ellipse:
            let r = CGRect(x: p.x, y: p.y, width: p.w ?? 0, height: p.h ?? 0)
            path.addEllipse(in: r); bounds = r
        case .roundedRect:
            let r = CGRect(x: p.x, y: p.y, width: p.w ?? 0, height: p.h ?? 0)
            let rad = p.radius ?? min(r.width, r.height) * 0.2
            path.addRoundedRect(in: r, cornerWidth: rad, cornerHeight: rad)
            bounds = r
        case .line:
            path.move(to: CGPoint(x: p.x, y: p.y))
            path.addLine(to: CGPoint(x: p.x2 ?? p.x, y: p.y2 ?? p.y))
            bounds = path.boundingBoxOfPath
        }

        if let fill = p.fill {
            context.setFillColor(fill.cgColor)
            context.addPath(path)
            context.fillPath()
        }
        if let stroke = p.stroke {
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(p.strokeWidth ?? 2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
        }
        let pad = max(2, p.strokeWidth ?? 0)
        return bounds.insetBy(dx: -pad, dy: -pad)
    }

    private func drawText(_ p: TextPayload) -> CGRect {
        let weight: NSFont.Weight = {
            switch (p.weight ?? "regular").lowercased() {
            case "thin": return .thin
            case "ultralight": return .ultraLight
            case "light": return .light
            case "medium": return .medium
            case "semibold": return .semibold
            case "bold": return .bold
            case "heavy": return .heavy
            case "black": return .black
            default: return .regular
            }
        }()
        let font: NSFont
        if let name = p.fontName, let f = NSFont(name: name, size: p.fontSize) {
            font = f
        } else {
            font = NSFont.systemFont(ofSize: p.fontSize, weight: weight)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: p.color.cgColor) ?? .black
        ]
        let attr = NSAttributedString(string: p.string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        let bbox = CTLineGetImageBounds(line, context)

        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(p.blend.cgBlend)
        context.setAlpha(p.opacity)
        // Our CTM is y-flipped; flip back so the glyphs render upright.
        context.textMatrix = .identity
        context.translateBy(x: p.x, y: p.y + p.fontSize)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        return CGRect(x: p.x + bbox.minX, y: p.y, width: bbox.width, height: p.fontSize * 1.4)
    }

    private func drawImage(_ p: ImagePayload) -> CGRect {
        guard let data = Data(base64Encoded: p.pngBase64),
              let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return .null
        }
        let drawW = p.w ?? Double(img.width)
        let drawH = p.h ?? Double(img.height)
        let rect = CGRect(x: p.x, y: p.y, width: drawW, height: drawH)
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(p.blend.cgBlend)
        context.setAlpha(p.opacity)
        context.draw(img, in: rect)
        return rect
    }

    private func drawClear(_ p: ClearPayload) -> CGRect {
        let color = p.color ?? GlossColor(r: 1, g: 1, b: 1)
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.copy)
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func performUndo() -> CGRect {
        guard let entry = undoStack.popLast() else { return .null }
        // Push current state to redo before reverting.
        if let curr = context.makeImage() {
            redoStack.append((curr, entry.summary))
            if redoStack.count > undoCap { redoStack.removeFirst() }
        }
        // Restore the snapshot.
        replaceContents(with: entry.image)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func performRedo() -> CGRect {
        guard let entry = redoStack.popLast() else { return .null }
        if let curr = context.makeImage() {
            undoStack.append((curr, entry.summary))
            if undoStack.count > undoCap { undoStack.removeFirst() }
        }
        replaceContents(with: entry.image)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func performResize(_ p: ResizePayload) -> CGRect {
        let newCtx = Self.makeContext(width: p.width, height: p.height)
        if p.preserveContents, let img = context.makeImage() {
            // Stretch existing contents into the new canvas.
            newCtx.draw(img, in: CGRect(x: 0, y: 0, width: p.width, height: p.height))
        } else {
            newCtx.setFillColor(GlossColor(r: 1, g: 1, b: 1).cgColor)
            newCtx.fill(CGRect(x: 0, y: 0, width: p.width, height: p.height))
        }
        self.context = newCtx
        self.width = p.width
        self.height = p.height
        // Resize invalidates undo/redo because dimensions changed.
        undoStack.removeAll()
        redoStack.removeAll()
        return CGRect(x: 0, y: 0, width: p.width, height: p.height)
    }

    private func replaceContents(with image: CGImage) {
        // Wipe + redraw the snapshot.
        context.saveGState()
        context.setBlendMode(.copy)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    private func lastCursor(for command: DrawCommand) -> GlossPoint? {
        switch command {
        case .stroke(let p): return p.points.last
        case .shape(let p): return GlossPoint(x: p.x, y: p.y)
        case .text(let p): return GlossPoint(x: p.x, y: p.y)
        case .image(let p): return GlossPoint(x: p.x, y: p.y)
        case .clear, .undo, .redo, .resize: return nil
        }
    }
}
