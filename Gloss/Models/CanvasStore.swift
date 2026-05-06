import Foundation
import CoreGraphics
import AppKit
import Observation

private struct CanvasHistorySnapshot {
    var stack: LayerStackSnapshot
    var grid: GridSpec
    var gridCellsByLayer: [String: [GridCellIndex: GlossColor]]
}

/// The single source of truth for the Gloss canvas.
///
/// As of v1.2, CanvasStore owns a `LayerStack` (one CGContext per layer, all
/// sRGB premultiplied RGBA, top-left origin). `apply(_:)` resolves the target
/// layer from `layerID` (missing = active; explicit ID auto-creates only for
/// the known author patterns) and routes draws to that layer's context.
///
/// `currentImage`, `snapshot(...)`, and `sample(at:)` always read the
/// composited stack — never a single layer — so /sample, /canvas.png,
/// /canvas.ascii, and /region.png see what Brenden sees on screen.
///
/// Undo/redo snapshots the entire layer stack (per-layer pixels, ordering,
/// visibility, opacity, blend, lock state, active layer). Restoring only the
/// composite would silently break layers.
@MainActor
@Observable
public final class CanvasStore {

    // MARK: - Configuration

    public private(set) var stack: LayerStack
    public var width: Int { stack.width }
    public var height: Int { stack.height }
    public private(set) var grid: GridSpec
    private var gridCellsByLayer: [String: [GridCellIndex: GlossColor]] = [:]

    public private(set) var revision: Int = 0
    public private(set) var lastCommands: [LastCommandSummary] = []
    public private(set) var authorCursors: [String: GlossPoint] = [:]

    private var idempotencyCache: [String: Int] = [:]
    private var idempotencyKeyOrder: [String] = []
    private let idempotencyCacheCap = 256

    private var undoStack: [(snapshot: CanvasHistorySnapshot, summary: LastCommandSummary)] = []
    private var redoStack: [(snapshot: CanvasHistorySnapshot, summary: LastCommandSummary)] = []
    private let undoCap = 32

    /// Cached composite for SwiftUI binding. Refreshed on revision change.
    public var currentImage: CGImage { stack.compositeImage }

    // MARK: - Init

    public init(width: Int = 1024, height: Int = 1024,
                background: GlossColor = GlossColor(r: 1, g: 1, b: 1)) {
        self.stack = LayerStack(width: width, height: height, background: background)
        self.grid = GridSpec().normalized(canvasWidth: width, canvasHeight: height)
    }

    private static func validDirtyRect(_ rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        let standardized = rect.standardized
        guard !standardized.isNull, !standardized.isInfinite, !standardized.isEmpty else { return nil }
        guard standardized.origin.x.isFinite,
              standardized.origin.y.isFinite,
              standardized.size.width.isFinite,
              standardized.size.height.isFinite else { return nil }
        return standardized
    }

    // MARK: - Public command surface

    @discardableResult
    public func apply(_ command: DrawCommand) throws -> CommandResult {
        if let key = command.idempotencyKey, let priorRev = idempotencyCache[key] {
            return CommandResult(revision: priorRev, dirtyRect: nil, deduped: true)
        }

        let isHistoryOp: Bool = {
            if case .undo = command { return true }
            if case .redo = command { return true }
            return false
        }()
        let mutatesPixelsOrStack: Bool = {
            switch command {
            case .stroke, .shape, .text, .image, .path, .pixel, .pixels, .clear, .resize, .canvasNew,
                 .layerCreate, .layerDelete, .layerReorder, .layerVisibility, .layerOpacity, .layerBlend,
                 .gridConfig, .gridFill:
                return true
            case .layerLock, .layerActivate, .undo, .redo:
                return false
            }
        }()

        let snapshotForUndo: CanvasHistorySnapshot? = (mutatesPixelsOrStack && !isHistoryOp)
            ? historySnapshot()
            : nil

        let dirty: CGRect?
        switch command {
        case .stroke(let p):    dirty = try drawStroke(p)
        case .shape(let p):     dirty = try drawShape(p)
        case .text(let p):      dirty = try drawText(p)
        case .image(let p):     dirty = try drawImage(p)
        case .path(let p):      dirty = try drawPath(p)
        case .pixel(let p):     dirty = try drawPixel(p)
        case .pixels(let p):    dirty = try drawPixels(p)
        case .clear(let p):     dirty = try drawClear(p)
        case .undo:             dirty = performUndo()
        case .redo:             dirty = performRedo()
        case .resize(let p):    dirty = performResize(p)
        case .canvasNew(let p): dirty = performCanvasNew(p)
        case .layerCreate(let p):     dirty = try doLayerCreate(p)
        case .layerDelete(let p):     dirty = try doLayerDelete(p)
        case .layerReorder(let p):    dirty = try doLayerReorder(p)
        case .layerVisibility(let p): dirty = try doLayerVisibility(p)
        case .layerOpacity(let p):    dirty = try doLayerOpacity(p)
        case .layerBlend(let p):      dirty = try doLayerBlend(p)
        case .layerLock(let p):       dirty = try doLayerLock(p)
        case .layerActivate(let p):   dirty = try doLayerActivate(p)
        case .gridConfig(let p):      dirty = doGridConfig(p)
        case .gridFill(let p):        dirty = try drawGridFill(p)
        }

        revision += 1
        stack.invalidateComposite()

        let summary = LastCommandSummary(
            revision: revision,
            kind: command.displayKind,
            author: command.author,
            idempotencyKey: command.idempotencyKey
        )
        lastCommands.insert(summary, at: 0)
        if lastCommands.count > 32 { lastCommands.removeLast(lastCommands.count - 32) }

        if let author = command.author, let cursor = lastCursor(for: command) {
            authorCursors[author] = cursor
        }

        if let key = command.idempotencyKey {
            idempotencyCache[key] = revision
            idempotencyKeyOrder.append(key)
            if idempotencyKeyOrder.count > idempotencyCacheCap {
                let evict = idempotencyKeyOrder.removeFirst()
                idempotencyCache.removeValue(forKey: evict)
            }
        }

        if let snap = snapshotForUndo {
            undoStack.append((snap, summary))
            if undoStack.count > undoCap { undoStack.removeFirst() }
            redoStack.removeAll()
        }

        return CommandResult(
            revision: revision,
            dirtyRect: Self.validDirtyRect(dirty).map(GlossRect.init),
            deduped: false
        )
    }

    public func snapshot(maxDim: Int? = nil) -> CGImage {
        let img = currentImage
        guard let maxDim, maxDim > 0, maxDim < max(width, height) else { return img }
        let scale = CGFloat(maxDim) / CGFloat(max(width, height))
        let outW = max(1, Int((CGFloat(width) * scale).rounded()))
        let outH = max(1, Int((CGFloat(height) * scale).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: bitmapInfo) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? img
    }

    public func snapshot(region: CGRect, scale: CGFloat = 1) -> CGImage? {
        let bounded = region.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !bounded.isEmpty else { return nil }
        let outW = max(1, Int((bounded.width * scale).rounded()))
        let outH = max(1, Int((bounded.height * scale).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        let drawRect = CGRect(
            x: -bounded.minX * scale,
            y: -(CGFloat(height) - bounded.maxY) * scale,
            width: CGFloat(width) * scale,
            height: CGFloat(height) * scale
        )
        ctx.draw(currentImage, in: drawRect)
        return ctx.makeImage()
    }

    public func sample(at point: CGPoint) -> RGBA? {
        stack.sampleComposite(at: point)
    }

    public var state: CanvasState {
        CanvasState(
            width: width,
            height: height,
            revision: revision,
            grid: grid,
            lastCommands: lastCommands,
            authorCursors: authorCursors
        )
    }

    public var layerState: LayerStackState { stack.state }

    public func gridCells(touching rect: CGRect) -> [GridCell] {
        grid.cells(touching: rect, canvasWidth: width, canvasHeight: height)
    }

    public func gridMaskImage(layerID: String) throws -> CGImage {
        guard stack.layer(id: layerID) != nil else {
            throw GlossError.notFound("Layer '\(layerID)' not found.")
        }
        let spec = grid.normalized(canvasWidth: width, canvasHeight: height)
        let cols = spec.columns(canvasWidth: width)
        let rows = spec.rows(canvasHeight: height)
        guard cols > 0, rows > 0 else {
            throw GlossError.bad("Grid has no cells at the current canvas size.")
        }
        var mask = [UInt8](repeating: 255, count: cols * rows * 4)
        if let layerCells = gridCellsByLayer[layerID] {
            for cell in layerCells.keys {
                guard cell.cx >= 0, cell.cy >= 0, cell.cx < cols, cell.cy < rows else { continue }
                let offset = (cell.cy * cols + cell.cx) * 4
                mask[offset + 0] = 0
                mask[offset + 1] = 0
                mask[offset + 2] = 0
                mask[offset + 3] = 255
            }
        }

        let data = NSData(bytes: mask, length: mask.count)
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: cols,
                height: rows,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: cols * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw GlossError.internalError("Could not encode grid mask image.")
        }
        return image
    }

    public func gridState(layerID: String) throws -> GridLayerState {
        guard stack.layer(id: layerID) != nil else {
            throw GlossError.notFound("Layer '\(layerID)' not found.")
        }
        let spec = grid.normalized(canvasWidth: width, canvasHeight: height)
        let cols = spec.columns(canvasWidth: width)
        let rows = spec.rows(canvasHeight: height)
        var entries: [GridFilledCell] = []
        if let cells = gridCellsByLayer[layerID] {
            entries.reserveCapacity(cells.count)
            for (cell, color) in cells {
                guard cell.cx >= 0, cell.cy >= 0, cell.cx < cols, cell.cy < rows else { continue }
                entries.append(GridFilledCell(cx: cell.cx, cy: cell.cy, color: color.toHex()))
            }
            entries.sort {
                $0.cy == $1.cy ? $0.cx < $1.cx : $0.cy < $1.cy
            }
        }
        return GridLayerState(
            layerID: layerID,
            grid: spec,
            cols: cols,
            rows: rows,
            filledCells: entries
        )
    }

    // MARK: - Layer command implementations

    private func doLayerCreate(_ p: LayerCreatePayload) throws -> CGRect {
        _ = try stack.createLayer(p)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func doLayerDelete(_ p: LayerDeletePayload) throws -> CGRect {
        try stack.deleteLayer(id: p.id)
        gridCellsByLayer.removeValue(forKey: p.id)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func doLayerReorder(_ p: LayerReorderPayload) throws -> CGRect {
        try stack.reorderLayer(id: p.id, to: p.toIndex)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func doLayerVisibility(_ p: LayerVisibilityPayload) throws -> CGRect {
        try stack.setVisibility(id: p.id, visible: p.visible)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func doLayerOpacity(_ p: LayerOpacityPayload) throws -> CGRect {
        try stack.setOpacity(id: p.id, opacity: p.opacity)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func doLayerBlend(_ p: LayerBlendPayload) throws -> CGRect {
        try stack.setBlend(id: p.id, blend: p.blend)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func doLayerLock(_ p: LayerLockPayload) throws -> CGRect {
        try stack.setLocked(id: p.id, locked: p.locked)
        return .null
    }

    private func doLayerActivate(_ p: LayerActivatePayload) throws -> CGRect {
        try stack.setActive(id: p.id)
        return .null
    }

    private func doGridConfig(_ p: GridConfigPayload) -> CGRect {
        let prior = grid
        grid = p.merged(with: grid, canvasWidth: width, canvasHeight: height)
        if prior.cellW != grid.cellW || prior.cellH != grid.cellH ||
            prior.originX != grid.originX || prior.originY != grid.originY {
            gridCellsByLayer.removeAll()
        } else {
            pruneGridCells()
        }
        return .null
    }

    // MARK: - Drawing implementations

    private func drawStroke(_ p: StrokePayload) throws -> CGRect {
        let target = try stack.contextForDraw(layerID: p.layerID, author: p.author)
        let ctx = target.context

        // Validate pressures length if provided.
        if let pressures = p.pressures, pressures.count != p.points.count {
            throw GlossError.bad("StrokePayload.pressures.count must equal points.count when provided.")
        }

        let brush = p.brush ?? .round
        let taper = p.taper ?? .none
        let usesEngine = brush != .round
            || (p.pressures != nil)
            || (taper != .none)

        if usesEngine {
            // Smooth/flatten first via StrokeSmoother for visual consistency.
            let cgPoints = snapped(points: p.points).map(\.cgPoint)
            let path = StrokeSmoother.smoothPath(
                points: cgPoints,
                tension: 0.5,
                simplify: p.simplify.map { CGFloat($0) }
            )
            let flattened = flattenCGPath(path)
            let request = BrushEngine.StrokeRequest(
                points: flattened,
                baseWidth: p.width,
                color: p.color,
                opacity: p.opacity,
                blend: p.blend,
                brush: brush,
                brushAngle: p.brushAngle ?? 0,
                pressures: p.pressures.flatMap { remap(pressures: $0, toCount: flattened.count) },
                taper: taper,
                seed: BrushEngine.seed(
                    idempotencyKey: p.idempotencyKey,
                    author: p.author,
                    layerID: target.id,
                    fields: ["stroke", brush.rawValue, p.color.toHex(),
                             String(format: "%.2f", p.width)]
                ),
                canvasWidth: width,
                canvasHeight: height
            )
            let bbox = BrushEngine.render(into: ctx, request: request)
            let pad = max(2, p.width * 1.2)
            return bbox.insetBy(dx: -pad, dy: -pad)
        } else {
            let cgPoints = snapped(points: p.points).map(\.cgPoint)
            let path = StrokeSmoother.smoothPath(
                points: cgPoints,
                tension: 0.5,
                simplify: p.simplify.map { CGFloat($0) }
            )
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.setBlendMode(p.blend.cgBlend)
            let baseAlpha = p.color.a * p.opacity
            let strokeColor = CGColor(srgbRed: p.color.r, green: p.color.g,
                                      blue: p.color.b, alpha: baseAlpha)
            ctx.setStrokeColor(strokeColor)
            ctx.setLineWidth(p.width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            return path.boundingBoxOfPath.insetBy(dx: -p.width, dy: -p.width)
        }
    }

    private func drawShape(_ p: ShapePayload) throws -> CGRect {
        let target = try stack.contextForDraw(layerID: p.layerID, author: p.author)
        let ctx = target.context
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setBlendMode(p.blend.cgBlend)
        ctx.setAlpha(p.opacity)

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
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        if let stroke = p.stroke {
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(p.strokeWidth ?? 2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
        }
        let pad = max(2, p.strokeWidth ?? 0)
        return bounds.insetBy(dx: -pad, dy: -pad)
    }

    private func drawText(_ p: TextPayload) throws -> CGRect {
        let target = try stack.contextForDraw(layerID: p.layerID, author: p.author)
        let ctx = target.context
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
        let size = attr.size()

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setBlendMode(p.blend.cgBlend)
        ctx.setAlpha(p.opacity)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attr.draw(at: CGPoint(x: p.x, y: p.y))
        return CGRect(x: p.x, y: p.y, width: size.width, height: size.height)
    }

    private func drawImage(_ p: ImagePayload) throws -> CGRect {
        let target = try stack.contextForDraw(layerID: p.layerID, author: p.author)
        let ctx = target.context
        guard let data = Data(base64Encoded: p.pngBase64),
              let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(pngDataProviderSource: provider, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent) else {
            return .null
        }
        let drawW = p.w ?? Double(img.width)
        let drawH = p.h ?? Double(img.height)
        let rect = CGRect(x: p.x, y: p.y, width: drawW, height: drawH)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setBlendMode(p.blend.cgBlend)
        ctx.setAlpha(p.opacity)
        ctx.draw(img, in: rect)
        return rect
    }

    private func drawPath(_ p: PathPayload) throws -> CGRect {
        let target = try stack.contextForDraw(layerID: p.layerID, author: p.author)
        let ctx = target.context

        if let pressures = p.pressures {
            // Pressures on path require a flattened geometry. We support stroke
            // pressures only; fill ignores them. Validate we have at least 2
            // ops and that pressures.count is sane.
            guard pressures.count >= 2 else {
                throw GlossError.bad("PathPayload.pressures must have at least 2 entries.")
            }
        }

        let path = CGMutablePath()
        for op in p.ops {
            switch op {
            case .move(let x, let y):
                path.move(to: CGPoint(x: x, y: y))
            case .line(let x, let y):
                path.addLine(to: CGPoint(x: x, y: y))
            case .quad(let cx, let cy, let x, let y):
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case .curve(let c1x, let c1y, let c2x, let c2y, let x, let y):
                path.addCurve(
                    to: CGPoint(x: x, y: y),
                    control1: CGPoint(x: c1x, y: c1y),
                    control2: CGPoint(x: c2x, y: c2y)
                )
            case .close:
                path.closeSubpath()
            }
        }
        if p.closed == true && !path.isEmpty {
            path.closeSubpath()
        }
        guard !path.isEmpty else { return .null }

        let strokeBrush = p.brush ?? .round
        let taper = p.taper ?? .none
        let useEngine = (p.color != nil) && (
            strokeBrush != .round
            || (p.pressures != nil)
            || (taper != .none)
        )

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setBlendMode(p.blend.cgBlend)
        ctx.setAlpha(p.opacity)

        if let fill = p.fill {
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }

        if useEngine, let strokeColor = p.color {
            // Flatten the path to evenly-sampled points and dispatch to the brush engine.
            let flattened = flattenCGPath(path)
            let request = BrushEngine.StrokeRequest(
                points: flattened,
                baseWidth: p.strokeWidth ?? 2,
                color: strokeColor,
                opacity: 1,                  // already applied via setAlpha above
                blend: p.blend,
                brush: strokeBrush,
                brushAngle: p.brushAngle ?? 0,
                pressures: p.pressures.flatMap { remap(pressures: $0, toCount: flattened.count) },
                taper: taper,
                seed: BrushEngine.seed(
                    idempotencyKey: p.idempotencyKey,
                    author: p.author,
                    layerID: target.id,
                    fields: ["path", strokeBrush.rawValue, strokeColor.toHex(),
                             String(format: "%.2f", p.strokeWidth ?? 2)]
                ),
                canvasWidth: width,
                canvasHeight: height
            )
            let bbox = BrushEngine.render(into: ctx, request: request)
            let pad = max(2, (p.strokeWidth ?? 2) * 1.2)
            return bbox.insetBy(dx: -pad, dy: -pad)
        } else if let strokeColor = p.color {
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(p.strokeWidth ?? 2)
            ctx.setLineCap(p.lineCap?.cgCap ?? .round)
            ctx.setLineJoin(p.lineJoin?.cgJoin ?? .round)
            if let miter = p.miterLimit { ctx.setMiterLimit(miter) }
            if let dash = p.dash, !dash.isEmpty {
                let lengths = dash.map { CGFloat($0) }
                ctx.setLineDash(phase: 0, lengths: lengths)
            }
            ctx.addPath(path)
            ctx.strokePath()
        }

        let pad = max(2, p.strokeWidth ?? 0)
        return path.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad)
    }

    private func drawPixel(_ p: PixelPayload) throws -> CGRect {
        let target = try stack.contextForDraw(layerID: p.layerID, author: p.author)
        let point = snappedPixel(x: p.x, y: p.y)
        guard point.x >= 0, point.x < width, point.y >= 0, point.y < height else { return .null }
        writePixel(into: target.context, x: point.x, y: point.y, color: p.color, blend: p.blend)
        return CGRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    private func drawPixels(_ p: PixelsPayload) throws -> CGRect {
        let target = try stack.contextForDraw(layerID: p.layerID, author: p.author)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        let fallback = p.defaultColor
        for px in p.pixels {
            let color = px.color ?? fallback ?? GlossColor(r: 0, g: 0, b: 0)
            let point = snappedPixel(x: px.x, y: px.y)
            guard point.x >= 0, point.x < width, point.y >= 0, point.y < height else { continue }
            writePixel(into: target.context, x: point.x, y: point.y, color: color, blend: p.blend)
            if point.x < minX { minX = point.x }
            if point.y < minY { minY = point.y }
            if point.x > maxX { maxX = point.x }
            if point.y > maxY { maxY = point.y }
        }
        if minX == Int.max { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func drawGridFill(_ p: GridFillPayload) throws -> CGRect {
        guard !p.cells.isEmpty else {
            throw GlossError.bad("Grid fill requires at least one cell.")
        }
        let target = try stack.contextForDraw(layerID: p.layerID, author: p.author)
        let uniqueCells = Array(Set(p.cells)).sorted {
            $0.cy == $1.cy ? $0.cx < $1.cx : $0.cy < $1.cy
        }
        var rects: [CGRect] = []
        rects.reserveCapacity(uniqueCells.count)
        for cell in uniqueCells {
            guard let rect = grid.rect(for: cell, canvasWidth: width, canvasHeight: height) else {
                throw GlossError.bad("Grid cell [\(cell.cx), \(cell.cy)] is outside the current grid.")
            }
            rects.append(rect)
        }

        let effectiveColor = GlossColor(
            r: p.color.r,
            g: p.color.g,
            b: p.color.b,
            a: p.color.a * p.opacity
        )
        let clearsCells = p.blend == .clear || effectiveColor.a <= 0
        var layerCells = gridCellsByLayer[target.id] ?? [:]
        for cell in uniqueCells {
            if clearsCells {
                layerCells.removeValue(forKey: cell)
            } else {
                layerCells[cell] = effectiveColor
            }
        }
        gridCellsByLayer[target.id] = layerCells.isEmpty ? nil : layerCells

        let ctx = target.context
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setBlendMode(p.blend.cgBlend)
        ctx.setAlpha(p.opacity)
        ctx.setFillColor(p.color.cgColor)
        var dirty = CGRect.null
        for rect in rects {
            ctx.fill(rect)
            dirty = dirty.isNull ? rect : dirty.union(rect)
        }
        return dirty
    }

    private func writePixel(into ctx: CGContext, x: Int, y: Int,
                            color: GlossColor, blend: GlossBlend) {
        guard let data = ctx.data else { return }
        let bytesPerRow = ctx.bytesPerRow
        let offset = y * bytesPerRow + x * 4
        let ptr = data.assumingMemoryBound(to: UInt8.self)

        let alpha = max(0, min(1, color.a))
        let dstR = ptr[offset + 0]
        let dstG = ptr[offset + 1]
        let dstB = ptr[offset + 2]
        let dstA = ptr[offset + 3]

        let srcR = UInt8(round(color.r * alpha * 255))
        let srcG = UInt8(round(color.g * alpha * 255))
        let srcB = UInt8(round(color.b * alpha * 255))
        let srcA = UInt8(round(alpha * 255))

        switch blend {
        case .normal, .clear:
            if blend == .clear {
                ptr[offset + 0] = 0
                ptr[offset + 1] = 0
                ptr[offset + 2] = 0
                ptr[offset + 3] = 0
                return
            }
            if alpha >= 1.0 {
                ptr[offset + 0] = srcR
                ptr[offset + 1] = srcG
                ptr[offset + 2] = srcB
                ptr[offset + 3] = 255
                return
            }
            let inv = 1.0 - alpha
            ptr[offset + 0] = UInt8(min(255, Int(round(Double(srcR) + Double(dstR) * inv))))
            ptr[offset + 1] = UInt8(min(255, Int(round(Double(srcG) + Double(dstG) * inv))))
            ptr[offset + 2] = UInt8(min(255, Int(round(Double(srcB) + Double(dstB) * inv))))
            ptr[offset + 3] = UInt8(min(255, Int(round(Double(srcA) + Double(dstA) * inv))))
        default:
            let inv = 1.0 - alpha
            ptr[offset + 0] = UInt8(min(255, Int(round(Double(srcR) + Double(dstR) * inv))))
            ptr[offset + 1] = UInt8(min(255, Int(round(Double(srcG) + Double(dstG) * inv))))
            ptr[offset + 2] = UInt8(min(255, Int(round(Double(srcB) + Double(dstB) * inv))))
            ptr[offset + 3] = UInt8(min(255, Int(round(Double(srcA) + Double(dstA) * inv))))
        }
    }

    private func drawClear(_ p: ClearPayload) throws -> CGRect {
        // A targeted clear with an explicit layerID clears just that layer; a
        // bare clear (no layerID) wipes the active layer.
        let target = try stack.contextForDraw(layerID: p.layerID, author: p.author)
        gridCellsByLayer.removeValue(forKey: target.id)
        let color = p.color ?? GlossColor(r: 1, g: 1, b: 1)
        let ctx = target.context
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setBlendMode(.copy)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func performUndo() -> CGRect {
        guard let entry = undoStack.popLast() else { return .null }
        let currentSnap = historySnapshot()
        redoStack.append((currentSnap, entry.summary))
        if redoStack.count > undoCap { redoStack.removeFirst() }
        restoreHistorySnapshot(entry.snapshot)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func performRedo() -> CGRect {
        guard let entry = redoStack.popLast() else { return .null }
        let currentSnap = historySnapshot()
        undoStack.append((currentSnap, entry.summary))
        if undoStack.count > undoCap { undoStack.removeFirst() }
        restoreHistorySnapshot(entry.snapshot)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private func performResize(_ p: ResizePayload) -> CGRect {
        if p.preserveContents {
            stack.resizeAll(width: p.width, height: p.height)
            grid = grid.normalized(canvasWidth: p.width, canvasHeight: p.height)
            pruneGridCells()
        } else {
            stack.reset(width: p.width, height: p.height,
                        background: GlossColor(r: 1, g: 1, b: 1))
            grid = grid.normalized(canvasWidth: p.width, canvasHeight: p.height)
            gridCellsByLayer.removeAll()
        }
        undoStack.removeAll()
        redoStack.removeAll()
        return CGRect(x: 0, y: 0, width: p.width, height: p.height)
    }

    private func performCanvasNew(_ p: CanvasNewPayload) -> CGRect {
        let bg = p.background ?? GlossColor(r: 1, g: 1, b: 1)
        if p.preserveLayers {
            stack.resizeAll(width: p.width, height: p.height)
        } else {
            stack.reset(width: p.width, height: p.height, background: bg)
            gridCellsByLayer.removeAll()
        }
        grid = (p.grid ?? GridSpec()).normalized(canvasWidth: p.width, canvasHeight: p.height)
        pruneGridCells()
        undoStack.removeAll()
        redoStack.removeAll()
        return CGRect(x: 0, y: 0, width: p.width, height: p.height)
    }

    private func lastCursor(for command: DrawCommand) -> GlossPoint? {
        switch command {
        case .stroke(let p): return p.points.last
        case .shape(let p): return GlossPoint(x: p.x, y: p.y)
        case .text(let p): return GlossPoint(x: p.x, y: p.y)
        case .image(let p): return GlossPoint(x: p.x, y: p.y)
        case .path(let p):
            for op in p.ops.reversed() {
                switch op {
                case .move(let x, let y): return GlossPoint(x: x, y: y)
                case .line(let x, let y): return GlossPoint(x: x, y: y)
                case .quad(_, _, let x, let y): return GlossPoint(x: x, y: y)
                case .curve(_, _, _, _, let x, let y): return GlossPoint(x: x, y: y)
                case .close: continue
                }
            }
            return nil
        case .pixel(let p): return GlossPoint(x: Double(p.x), y: Double(p.y))
        case .pixels(let p): return p.pixels.last.map { GlossPoint(x: Double($0.x), y: Double($0.y)) }
        case .gridFill(let p):
            guard let cell = p.cells.last,
                  let rect = grid.rect(for: cell, canvasWidth: width, canvasHeight: height) else {
                return nil
            }
            return GlossPoint(x: rect.minX, y: rect.minY)
        case .clear, .undo, .redo, .resize, .canvasNew,
             .layerCreate, .layerDelete, .layerReorder,
             .layerVisibility, .layerOpacity, .layerBlend,
             .layerLock, .layerActivate, .gridConfig:
            return nil
        }
    }

    private func snapped(points: [GlossPoint]) -> [GlossPoint] {
        guard grid.snap else { return points }
        return points.map { point in
            let snapped = grid.snappedPoint(point.cgPoint, canvasWidth: width, canvasHeight: height)
            return GlossPoint(x: Double(snapped.x), y: Double(snapped.y))
        }
    }

    private func snappedPixel(x: Int, y: Int) -> (x: Int, y: Int) {
        guard grid.snap else { return (x, y) }
        let snapped = grid.snappedPoint(CGPoint(x: x, y: y), canvasWidth: width, canvasHeight: height)
        return (Int(snapped.x.rounded()), Int(snapped.y.rounded()))
    }

    private func historySnapshot() -> CanvasHistorySnapshot {
        CanvasHistorySnapshot(
            stack: stack.snapshot(),
            grid: grid,
            gridCellsByLayer: gridCellsByLayer
        )
    }

    private func restoreHistorySnapshot(_ snapshot: CanvasHistorySnapshot) {
        stack.restore(snapshot.stack)
        grid = snapshot.grid
        gridCellsByLayer = snapshot.gridCellsByLayer
        pruneGridCells()
    }

    private func pruneGridCells() {
        let cols = grid.columns(canvasWidth: width)
        let rows = grid.rows(canvasHeight: height)
        let existingLayerIDs = Set(layerState.layers.map(\.id))
        let prunedByLayer = gridCellsByLayer.compactMapValues { cells in
            let pruned = cells.filter { key, _ in
                key.cx >= 0 && key.cy >= 0 && key.cx < cols && key.cy < rows
            }
            return pruned.isEmpty ? nil : pruned
        }
        gridCellsByLayer = prunedByLayer.filter { existingLayerIDs.contains($0.key) }
    }

    // MARK: - Path flattening helpers

    private func flattenCGPath(_ path: CGPath) -> [CGPoint] {
        var out: [CGPoint] = []
        let stepRoughly: CGFloat = 1.0
        // CoreGraphics doesn't expose path flattening directly; we sample by
        // iterating elements and chord-flattening each segment.
        let bezier = NSBezierPath(cgPath: path)
        let total = bezier.elementCount
        guard total > 0 else { return [] }

        var current = CGPoint.zero
        for i in 0..<total {
            var pts = [NSPoint](repeating: .zero, count: 3)
            let kind = bezier.element(at: i, associatedPoints: &pts)
            switch kind {
            case .moveTo:
                current = pts[0]
                out.append(current)
            case .lineTo:
                let target = pts[0]
                out.append(contentsOf: linearSamples(from: current, to: target, step: stepRoughly))
                current = target
            case .curveTo:
                let c1 = pts[0], c2 = pts[1], end = pts[2]
                out.append(contentsOf: cubicSamples(from: current, c1: c1, c2: c2, to: end, step: stepRoughly))
                current = end
            case .closePath:
                if let first = out.first {
                    out.append(contentsOf: linearSamples(from: current, to: first, step: stepRoughly))
                    current = first
                }
            case .quadraticCurveTo:
                let cp = pts[0], end = pts[1]
                out.append(contentsOf: quadSamples(from: current, c: cp, to: end, step: stepRoughly))
                current = end
            @unknown default:
                continue
            }
        }
        return out
    }

    private func linearSamples(from p0: CGPoint, to p1: CGPoint, step: CGFloat) -> [CGPoint] {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let dist = hypot(dx, dy)
        let n = max(1, Int(ceil(dist / max(0.5, step))))
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            pts.append(CGPoint(x: p0.x + dx * t, y: p0.y + dy * t))
        }
        return pts
    }

    private func quadSamples(from p0: CGPoint, c: CGPoint, to p1: CGPoint, step: CGFloat) -> [CGPoint] {
        let approxLen = hypot(c.x - p0.x, c.y - p0.y) + hypot(p1.x - c.x, p1.y - c.y)
        let n = max(2, Int(ceil(approxLen / max(0.5, step))))
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let oneT = 1 - t
            let x = oneT * oneT * p0.x + 2 * oneT * t * c.x + t * t * p1.x
            let y = oneT * oneT * p0.y + 2 * oneT * t * c.y + t * t * p1.y
            pts.append(CGPoint(x: x, y: y))
        }
        return pts
    }

    private func cubicSamples(from p0: CGPoint, c1: CGPoint, c2: CGPoint, to p1: CGPoint, step: CGFloat) -> [CGPoint] {
        let approxLen = hypot(c1.x - p0.x, c1.y - p0.y)
            + hypot(c2.x - c1.x, c2.y - c1.y)
            + hypot(p1.x - c2.x, p1.y - c2.y)
        let n = max(4, Int(ceil(approxLen / max(0.5, step))))
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let oneT = 1 - t
            let x = oneT*oneT*oneT * p0.x
                  + 3 * oneT*oneT * t * c1.x
                  + 3 * oneT * t*t * c2.x
                  + t*t*t * p1.x
            let y = oneT*oneT*oneT * p0.y
                  + 3 * oneT*oneT * t * c1.y
                  + 3 * oneT * t*t * c2.y
                  + t*t*t * p1.y
            pts.append(CGPoint(x: x, y: y))
        }
        return pts
    }

    private func remap(pressures: [Double], toCount n: Int) -> [Double]? {
        guard !pressures.isEmpty, n > 0 else { return nil }
        if pressures.count == n { return pressures }
        var out: [Double] = []
        out.reserveCapacity(n)
        let m = pressures.count
        for i in 0..<n {
            let f = Double(i) * Double(m - 1) / Double(max(1, n - 1))
            let lo = Int(floor(f))
            let hi = min(m - 1, lo + 1)
            let t = f - Double(lo)
            out.append(pressures[lo] * (1 - t) + pressures[hi] * t)
        }
        return out
    }
}
