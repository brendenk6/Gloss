import Foundation
import CoreGraphics
import Observation

/// Snapshot of the entire layer stack at a single revision. Used by undo/redo
/// so reverting also restores layer order, visibility, opacity, blend, and the
/// active layer — not just the composite pixels.
///
/// We store raw bitmap bytes per layer rather than CGImages because CG's image
/// rendering pipeline applies a vertical flip relative to user space, and
/// round-tripping through ctx.draw silently lands pixels at the wrong memory
/// rows for our top-left coordinate convention. Direct byte copy is exact.
public struct LayerStackSnapshot: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let layers: [GlossLayer]
    public let activeID: String
    public let bitmaps: [String: Data]
    public let bytesPerRow: Int
}

/// Per-layer storage of CGContext bitmaps. Owned by CanvasStore, which routes
/// all draws through the layer resolved from the command's `layerID` (or the
/// active layer when none is given).
@MainActor
@Observable
public final class LayerStack {

    // MARK: - Configuration

    public static let defaultMaxLayers = 16
    public private(set) var width: Int
    public private(set) var height: Int

    /// Bottom → top draw order.
    public private(set) var layers: [GlossLayer] = []
    public private(set) var activeID: String

    /// Layer ID -> per-layer CGContext (sRGB premultiplied RGBA).
    /// Each layer paints into its own bitmap so the composite stays correct.
    private var contexts: [String: CGContext] = [:]

    private var compositeCache: CGImage?
    private var sampleCache: (image: CGImage, width: Int, height: Int)?

    public let maxLayers = LayerStack.defaultMaxLayers

    /// Known auto-create layer IDs. A draw command that names one of these and
    /// the layer doesn't exist yet → create it on the fly. Anything else rejects.
    public static let autoCreatablePatterns: Set<String> = [
        "claude-layer", "codex-layer", "brenden-layer"
    ]

    // MARK: - Init

    public init(width: Int, height: Int, background: GlossColor) {
        self.width = width
        self.height = height
        let baseID = "base"
        let baseLayer = GlossLayer(id: baseID, name: "Base", author: nil,
                                   visible: true, opacity: 1, blend: .normal,
                                   locked: false)
        self.activeID = baseID
        let ctx = LayerStack.makeContext(width: width, height: height)
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        self.contexts[baseID] = ctx
        self.layers.append(baseLayer)
    }

    // MARK: - Context factory

    fileprivate static func makeContext(width: Int, height: Int) -> CGContext {
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
            fatalError("Gloss: failed to create layer CGContext at \(width)x\(height)")
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        return ctx
    }

    // MARK: - Public layer queries

    public func layer(id: String) -> GlossLayer? {
        layers.first(where: { $0.id == id })
    }

    /// Layer indices map to draw order: 0 = bottom.
    public func index(of id: String) -> Int? {
        layers.firstIndex(where: { $0.id == id })
    }

    public var state: LayerStackState {
        LayerStackState(
            layers: layers,
            activeLayerID: activeID,
            memoryUsageBytes: memoryEstimateBytes,
            memoryCapBytes: maxLayers * width * height * 4,
            maxLayers: maxLayers
        )
    }

    public var memoryEstimateBytes: Int {
        layers.count * width * height * 4
    }

    /// Resolve a layer ID for a draw command. Missing = active layer. Explicit
    /// non-existent ID = auto-create if it matches the known author pattern,
    /// otherwise reject.
    @discardableResult
    public func resolveDrawTarget(layerID: String?, author: String?) throws -> String {
        guard let requested = layerID, !requested.isEmpty else {
            return activeID
        }
        if contexts[requested] != nil {
            return requested
        }
        if LayerStack.autoCreatablePatterns.contains(requested) {
            // Auto-create at top of stack with author-derived defaults.
            try insertLayer(GlossLayer(
                id: requested,
                name: requested,
                author: author,
                visible: true,
                opacity: 1,
                blend: .normal,
                locked: false
            ), afterID: nil)
            return requested
        }
        throw GlossError(
            code: "layer_not_found",
            message: "Layer '\(requested)' does not exist. Create it via /layer/create first."
        )
    }

    public func contextForDraw(layerID: String?, author: String?) throws -> (id: String, context: CGContext) {
        let id = try resolveDrawTarget(layerID: layerID, author: author)
        guard let ctx = contexts[id] else {
            throw GlossError.internalError("Resolved layer '\(id)' has no backing context.")
        }
        if layer(id: id)?.locked == true {
            throw GlossError(code: "layer_locked", message: "Layer '\(id)' is locked.")
        }
        return (id, ctx)
    }

    public func context(for id: String) -> CGContext? {
        contexts[id]
    }

    // MARK: - Mutation: layer-level

    @discardableResult
    public func createLayer(_ payload: LayerCreatePayload) throws -> GlossLayer {
        guard layers.count < maxLayers else {
            throw GlossError(
                code: "layer_cap",
                message: "Layer cap reached (\(maxLayers)). Delete a layer before adding another."
            )
        }
        let requestedID = payload.id.flatMap { $0.isEmpty ? nil : $0 }
        if let id = requestedID, contexts[id] != nil {
            throw GlossError.bad("Layer ID '\(id)' already exists.")
        }
        let id = requestedID ?? "layer-\(UUID().uuidString.prefix(8))"
        let name = payload.name?.isEmpty == false ? payload.name! : id
        let layer = GlossLayer(
            id: id,
            name: name,
            author: payload.author,
            visible: payload.visible ?? true,
            opacity: payload.opacity ?? 1,
            blend: payload.blend ?? .normal,
            locked: payload.locked ?? false
        )
        try insertLayer(layer, afterID: payload.afterID)
        if payload.setActive == true {
            activeID = id
        }
        return layer
    }

    public func deleteLayer(id: String) throws {
        guard let idx = index(of: id) else {
            throw GlossError.notFound("Layer '\(id)' not found.")
        }
        if layers.count <= 1 {
            throw GlossError.bad("Cannot delete the last remaining layer.")
        }
        layers.remove(at: idx)
        contexts.removeValue(forKey: id)
        if activeID == id {
            // Pick the topmost remaining layer that isn't locked, else just topmost.
            activeID = layers.last(where: { !$0.locked })?.id ?? layers.last!.id
        }
        invalidateComposite()
    }

    public func reorderLayer(id: String, to newIndex: Int) throws {
        guard let from = index(of: id) else {
            throw GlossError.notFound("Layer '\(id)' not found.")
        }
        let clamped = max(0, min(layers.count - 1, newIndex))
        guard clamped != from else { return }
        let layer = layers.remove(at: from)
        layers.insert(layer, at: clamped)
        invalidateComposite()
    }

    public func setVisibility(id: String, visible: Bool) throws {
        try mutate(id) { $0.visible = visible }
        invalidateComposite()
    }

    public func setOpacity(id: String, opacity: Double) throws {
        try mutate(id) { $0.opacity = max(0, min(1, opacity)) }
        invalidateComposite()
    }

    public func setBlend(id: String, blend: GlossBlend) throws {
        try mutate(id) { $0.blend = blend }
        invalidateComposite()
    }

    public func setLocked(id: String, locked: Bool) throws {
        try mutate(id) { $0.locked = locked }
        // Locked status doesn't affect composite, but UI cares.
    }

    public func setActive(id: String) throws {
        guard contexts[id] != nil else {
            throw GlossError.notFound("Layer '\(id)' not found.")
        }
        activeID = id
    }

    private func mutate(_ id: String, _ body: (inout GlossLayer) -> Void) throws {
        guard let idx = index(of: id) else {
            throw GlossError.notFound("Layer '\(id)' not found.")
        }
        var layer = layers[idx]
        body(&layer)
        layers[idx] = layer
    }

    private func insertLayer(_ layer: GlossLayer, afterID: String?) throws {
        let ctx = LayerStack.makeContext(width: width, height: height)
        contexts[layer.id] = ctx
        if let afterID, let idx = index(of: afterID) {
            layers.insert(layer, at: idx + 1)
        } else {
            layers.append(layer)
        }
        invalidateComposite()
    }

    // MARK: - Resize / reset

    public func resizeAll(width newW: Int, height newH: Int) {
        let sameSize = (newW == width && newH == height)
        width = newW
        height = newH
        var newContexts: [String: CGContext] = [:]
        for layer in layers {
            let ctx = LayerStack.makeContext(width: newW, height: newH)
            guard let oldCtx = contexts[layer.id] else {
                newContexts[layer.id] = ctx
                continue
            }
            if sameSize, let src = oldCtx.data, let dst = ctx.data {
                let count = oldCtx.bytesPerRow * oldCtx.height
                dst.copyMemory(from: src, byteCount: count)
            } else if let img = oldCtx.makeImage() {
                // Different dimensions: stretch via CG. The default-y-up draw
                // places image upright in memory because the source image was
                // captured from a top-left CTM ctx — both ends apply the same
                // canonical orientation, so memory layout matches.
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                if let temp = CGContext(data: nil, width: newW, height: newH,
                                        bitsPerComponent: 8, bytesPerRow: 0,
                                        space: cs, bitmapInfo: bitmapInfo) {
                    temp.interpolationQuality = .high
                    temp.draw(img, in: CGRect(x: 0, y: 0, width: newW, height: newH))
                    if let src = temp.data, let dst = ctx.data {
                        // Copy row-reversed so memory layout matches our
                        // top-left convention (CG draw produces y-up memory).
                        let bpr = temp.bytesPerRow
                        let h = newH
                        let srcPtr = src.assumingMemoryBound(to: UInt8.self)
                        let dstPtr = dst.assumingMemoryBound(to: UInt8.self)
                        for r in 0..<h {
                            let srcRow = srcPtr.advanced(by: (h - 1 - r) * bpr)
                            let dstRow = dstPtr.advanced(by: r * bpr)
                            dstRow.update(from: srcRow, count: bpr)
                        }
                    }
                }
            }
            newContexts[layer.id] = ctx
        }
        contexts = newContexts
        invalidateComposite()
    }

    public func reset(width newW: Int, height newH: Int, background: GlossColor) {
        width = newW
        height = newH
        contexts.removeAll()
        layers.removeAll()
        let baseID = "base"
        let baseLayer = GlossLayer(id: baseID, name: "Base", author: nil)
        let ctx = LayerStack.makeContext(width: newW, height: newH)
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        contexts[baseID] = ctx
        layers.append(baseLayer)
        activeID = baseID
        invalidateComposite()
    }

    // MARK: - Composite + sample

    public var compositeImage: CGImage {
        if let cached = compositeCache { return cached }
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
            return contexts[activeID]?.makeImage() ?? CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: cs, bitmapInfo: bitmapInfo
            )!.makeImage()!
        }
        // Default CGContext (y-up). CGContext.draw flips images vertically when
        // drawing them, which combined with how sampleComposite reads pixels
        // (also via a y-up 1×1 ctx with translation) produces the correct
        // result for /sample, /canvas.png, /canvas.ascii, /region.png.
        ctx.setBlendMode(.copy)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for layer in layers where layer.visible {
            guard let layerCtx = contexts[layer.id], let img = layerCtx.makeImage() else { continue }
            ctx.saveGState()
            ctx.setBlendMode(layer.blend.cgBlend)
            ctx.setAlpha(CGFloat(layer.opacity))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            ctx.restoreGState()
        }
        let img = ctx.makeImage()!
        compositeCache = img
        return img
    }

    /// Sample the composite at a top-left-origin pixel coordinate.
    public func sampleComposite(at point: CGPoint) -> RGBA? {
        let px = Int(point.x.rounded())
        let py = Int(point.y.rounded())
        guard px >= 0, px < width, py >= 0, py < height else { return nil }

        // Render the composite into a small persistent buffer for direct read.
        let img = compositeImage
        if sampleCache?.image !== img || sampleCache?.width != width || sampleCache?.height != height {
            sampleCache = (img, width, height)
        }

        // Render to a 1px context at the target pixel for an exact sample.
        // (CGImage doesn't expose pixel data directly without copying.)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var pixel: [UInt8] = [0, 0, 0, 0]
        let success: Bool = pixel.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: cs,
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            // Paint the requested source pixel into our 1×1 destination.
            // CGContext draws bottom-up, so flip and translate to make our
            // top-left source pixel the only visible pixel.
            ctx.translateBy(x: CGFloat(-px), y: CGFloat(py + 1 - height))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return nil }
        let r = pixel[0], g = pixel[1], b = pixel[2], a = pixel[3]
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

    public func invalidateComposite() {
        compositeCache = nil
        sampleCache = nil
    }

    // MARK: - Snapshot / restore (undo)

    public func snapshot() -> LayerStackSnapshot {
        var bitmaps: [String: Data] = [:]
        var bytesPerRow = width * 4
        for (id, ctx) in contexts {
            guard let raw = ctx.data else { continue }
            bytesPerRow = ctx.bytesPerRow
            let count = ctx.bytesPerRow * ctx.height
            bitmaps[id] = Data(bytes: raw, count: count)
        }
        return LayerStackSnapshot(
            width: width,
            height: height,
            layers: layers,
            activeID: activeID,
            bitmaps: bitmaps,
            bytesPerRow: bytesPerRow
        )
    }

    public func restore(_ snap: LayerStackSnapshot) {
        width = snap.width
        height = snap.height
        layers = snap.layers
        activeID = snap.activeID
        var newContexts: [String: CGContext] = [:]
        for layer in snap.layers {
            let ctx = LayerStack.makeContext(width: snap.width, height: snap.height)
            if let bytes = snap.bitmaps[layer.id], let dst = ctx.data {
                let dstStride = ctx.bytesPerRow
                let dstCount = dstStride * ctx.height
                if dstStride == snap.bytesPerRow && bytes.count == dstCount {
                    bytes.withUnsafeBytes { src in
                        if let base = src.baseAddress {
                            dst.copyMemory(from: base, byteCount: dstCount)
                        }
                    }
                } else {
                    // Strides differ (shouldn't happen at same dimensions, but
                    // be defensive). Copy row by row up to the common width.
                    let copyRowBytes = min(dstStride, snap.bytesPerRow)
                    let rows = min(ctx.height, snap.bitmaps[layer.id]!.count / max(1, snap.bytesPerRow))
                    bytes.withUnsafeBytes { src in
                        guard let srcBase = src.baseAddress else { return }
                        let dstPtr = dst.assumingMemoryBound(to: UInt8.self)
                        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
                        for r in 0..<rows {
                            let dstRow = dstPtr.advanced(by: r * dstStride)
                            let srcRow = srcPtr.advanced(by: r * snap.bytesPerRow)
                            dstRow.update(from: srcRow, count: copyRowBytes)
                        }
                    }
                }
            }
            newContexts[layer.id] = ctx
        }
        contexts = newContexts
        if !contexts.keys.contains(activeID), let firstID = layers.first?.id {
            activeID = firstID
        }
        invalidateComposite()
    }
}
