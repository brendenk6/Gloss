import CoreGraphics
import Foundation

struct GlossHTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]

    static func json(_ value: some Encodable, status: Int = 200) -> GlossHTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return GlossHTTPResponse(
                status: status,
                contentType: "application/json; charset=utf-8",
                body: try encoder.encode(value)
            )
        } catch let serializationError {
            return Self.error(code: "serialization_failed", message: serializationError.localizedDescription, status: 500)
        }
    }

    static func png(_ data: Data, revision: Int, width: Int, height: Int) -> GlossHTTPResponse {
        GlossHTTPResponse(
            status: 200,
            contentType: "image/png",
            body: data,
            headers: [
                "X-Gloss-Revision": String(revision),
                "X-Gloss-Width": String(width),
                "X-Gloss-Height": String(height)
            ]
        )
    }

    static func error(code: String, message: String, status: Int) -> GlossHTTPResponse {
        json(ErrorEnvelope(error: APIError(code: code, message: message)), status: status)
    }
}

@MainActor
final class ServerIdempotencyCache {
    private var results: [String: CommandResult] = [:]
    private var layerCreates: [String: (result: CommandResult, layer: GlossLayer)] = [:]
    private var order: [String] = []
    private let cap = 256

    func result(for key: String) -> CommandResult? {
        results[key]
    }

    func layerCreate(for key: String) -> (result: CommandResult, layer: GlossLayer)? {
        layerCreates[key]
    }

    func record(_ result: CommandResult, for key: String?) {
        guard let key, !key.isEmpty else { return }
        if results[key] == nil {
            order.append(key)
        }
        results[key] = result
        while order.count > cap {
            let evicted = order.removeFirst()
            results.removeValue(forKey: evicted)
            layerCreates.removeValue(forKey: evicted)
        }
    }

    func recordLayerCreate(_ result: CommandResult, layer: GlossLayer, for key: String?) {
        record(result, for: key)
        guard let key, !key.isEmpty else { return }
        layerCreates[key] = (result, layer)
    }

    func clear() {
        results.removeAll()
        layerCreates.removeAll()
        order.removeAll()
    }
}

@MainActor
enum GlossRoutes {
    static func handle(
        method: String,
        path: String,
        query: [String: String],
        body: Data,
        store: CanvasStore,
        idempotency: ServerIdempotencyCache
    ) -> GlossHTTPResponse {
        if method == "OPTIONS" {
            return GlossHTTPResponse(status: 204, contentType: "application/json; charset=utf-8", body: Data())
        }

        do {
            switch (method, path) {
            case ("GET", "/state"):
                return .json(StateEnvelope(state: store.state, layerState: store.layerState))

            case ("GET", "/layers"), ("GET", "/layer/list"):
                return .json(LayersEnvelope(layerState: store.layerState, revision: store.revision))

            case ("GET", "/canvas/presets"):
                return .json(CanvasPresetsEnvelope(presets: GlossCanvasPresets.all))

            case ("GET", "/grid/cells"):
                return gridCells(query: query, store: store)

            case ("GET", "/grid/state"):
                return gridState(query: query, store: store)

            case ("GET", "/grid/mask.png"), ("GET", "/grid/mask"):
                return gridMask(query: query, store: store)

            case ("GET", "/canvas.png"), ("GET", "/canvas"):
                let maxDim = intParam(query, "max_dim") ?? intParam(query, "maxDim")
                let image = store.snapshot(maxDim: maxDim)
                guard let data = PNGExporter.data(from: image) else {
                    return .error(code: "png_export_failed", message: "Could not encode canvas PNG.", status: 500)
                }
                return .png(data, revision: store.revision, width: image.width, height: image.height)

            case ("GET", "/export"):
                let format = query["format"]?.lowercased() ?? "png"
                guard format == "png" else {
                    return .error(code: "unsupported_format", message: "Only PNG export is supported.", status: 400)
                }
                let maxDim = intParam(query, "max_dim") ?? intParam(query, "maxDim")
                let image = store.snapshot(maxDim: maxDim)
                guard let data = PNGExporter.data(from: image) else {
                    return .error(code: "png_export_failed", message: "Could not encode canvas PNG.", status: 500)
                }
                var response = GlossHTTPResponse.png(data, revision: store.revision, width: image.width, height: image.height)
                response.headers["Content-Disposition"] = "attachment; filename=\"gloss-rev-\(store.revision).png\""
                return response

            case ("GET", "/region.png"), ("GET", "/canvas/region.png"), ("GET", "/region"):
                guard let rect = rectFromQuery(query) else {
                    return .error(code: "bad_request", message: "Region requires x, y, w, and h.", status: 400)
                }
                let scale = doubleParam(query, "scale").map { CGFloat($0) } ?? 1
                guard let image = store.snapshot(region: rect, scale: max(0.05, min(16, scale))),
                      let data = PNGExporter.data(from: image) else {
                    return .error(code: "region_unavailable", message: "Requested region is outside the canvas.", status: 404)
                }
                return .png(data, revision: store.revision, width: image.width, height: image.height)

            case ("GET", "/canvas.ascii"):
                return try asciiCanvas(query: query, store: store)

            case ("GET", "/sample"), ("GET", "/eyedropper"):
                guard let x = doubleParam(query, "x"), let y = doubleParam(query, "y") else {
                    return .error(code: "bad_request", message: "Sample requires x and y.", status: 400)
                }
                guard let rgba = store.sample(at: CGPoint(x: x, y: y)) else {
                    return .error(code: "out_of_bounds", message: "Sample point is outside the canvas.", status: 404)
                }
                return .json(SampleEnvelope(x: x, y: y, rgba: rgba, revision: store.revision))

            case ("GET", "/sample/grid"):
                return sampleGrid(query: query, store: store)

            case ("GET", "/sample/path"):
                return samplePath(query: query, store: store)

            case ("GET", "/diff"):
                guard intParam(query, "revision") != nil else {
                    return .error(code: "bad_request", message: "Diff requires revision=N.", status: 400)
                }
                return .error(
                    code: "not_implemented",
                    message: "/diff requires per-revision snapshots or dirty-cell history; Gloss v1.1 does not retain that yet.",
                    status: 501
                )

            case ("POST", "/stroke"):
                return try apply(body: body, inferredType: "stroke", store: store, idempotency: idempotency)
            case ("POST", "/shape"):
                return try apply(body: body, inferredType: "shape", store: store, idempotency: idempotency)
            case ("POST", "/text"):
                return try apply(body: body, inferredType: "text", store: store, idempotency: idempotency)
            case ("POST", "/image"), ("POST", "/image_paste"):
                return try apply(body: body, inferredType: "image", store: store, idempotency: idempotency)
            case ("POST", "/path"):
                return try apply(body: body, inferredType: "path", store: store, idempotency: idempotency)
            case ("POST", "/pixel"):
                return try apply(body: body, inferredType: "pixel", store: store, idempotency: idempotency)
            case ("POST", "/pixels"):
                return try apply(body: body, inferredType: "pixels", store: store, idempotency: idempotency)
            case ("POST", "/clear"):
                return try apply(body: body, inferredType: "clear", store: store, idempotency: idempotency)
            case ("POST", "/undo"):
                return try apply(body: body, inferredType: "undo", store: store, idempotency: idempotency)
            case ("POST", "/redo"):
                return try apply(body: body, inferredType: "redo", store: store, idempotency: idempotency)
            case ("POST", "/resize"):
                let response = try apply(body: body, inferredType: "resize", store: store, idempotency: idempotency)
                idempotency.clear()
                return response
            case ("POST", "/canvas/new"):
                let response = try applyCanvasNew(body: body, store: store, idempotency: idempotency)
                idempotency.clear()
                return response
            case ("POST", "/layer/create"):
                return try applyLayerCreate(body: body, store: store, idempotency: idempotency)
            case ("POST", "/layer/delete"):
                return try apply(body: body, inferredType: "layerDelete", store: store, idempotency: idempotency)
            case ("POST", "/layer/reorder"):
                return try apply(body: body, inferredType: "layerReorder", store: store, idempotency: idempotency)
            case ("POST", "/layer/visibility"), ("POST", "/layer/show"), ("POST", "/layer/hide"):
                return try applyLayerVisibility(body: body, path: path, store: store, idempotency: idempotency)
            case ("POST", "/layer/opacity"):
                return try apply(body: body, inferredType: "layerOpacity", store: store, idempotency: idempotency)
            case ("POST", "/layer/blend"):
                return try apply(body: body, inferredType: "layerBlend", store: store, idempotency: idempotency)
            case ("POST", "/layer/lock"):
                return try apply(body: body, inferredType: "layerLock", store: store, idempotency: idempotency)
            case ("POST", "/layer/activate"), ("POST", "/layer/active"):
                return try apply(body: body, inferredType: "layerActivate", store: store, idempotency: idempotency)
            case ("POST", "/grid/config"):
                return try apply(body: body, inferredType: "gridConfig", store: store, idempotency: idempotency)
            case ("POST", "/grid/fill"):
                return try apply(body: body, inferredType: "gridFill", store: store, idempotency: idempotency)

            default:
                return .error(code: "not_found", message: "Unknown route: \(method) \(path)", status: 404)
            }
        } catch let error as GlossError {
            return .error(code: error.code, message: error.message, status: status(for: error))
        } catch let error as DecodingError {
            return .error(code: "bad_json", message: decodingMessage(error), status: 400)
        } catch {
            return .error(code: "internal", message: error.localizedDescription, status: 500)
        }
    }

    private static func apply(
        body: Data,
        inferredType: String,
        store: CanvasStore,
        idempotency: ServerIdempotencyCache
    ) throws -> GlossHTTPResponse {
        let command = try decodeCommand(body: body, inferredType: inferredType)

        if let key = command.idempotencyKey, let cached = idempotency.result(for: key) {
            return .json(CommandEnvelope(result: cached, dedupedByServer: true))
        }

        let result = try store.apply(command)
        idempotency.record(result, for: command.idempotencyKey)
        return .json(CommandEnvelope(result: result, dedupedByServer: false))
    }

    private static func applyLayerCreate(
        body: Data,
        store: CanvasStore,
        idempotency: ServerIdempotencyCache
    ) throws -> GlossHTTPResponse {
        let command = try decodeCommand(body: body, inferredType: "layerCreate")
        guard case .layerCreate = command else {
            throw GlossError.bad("Expected a layerCreate command.")
        }

        if let key = command.idempotencyKey, let cached = idempotency.layerCreate(for: key) {
            return .json(LayerCreateEnvelope(
                result: cached.result,
                layer: cached.layer,
                layerState: store.layerState,
                dedupedByServer: true
            ))
        }

        let existingIDs = Set(store.layerState.layers.map(\.id))
        let result = try store.apply(command)
        let createdLayer = store.layerState.layers.first { !existingIDs.contains($0.id) }
            ?? store.layerState.layers.first { $0.id == store.layerState.activeLayerID }
            ?? store.layerState.layers.last
        guard let layer = createdLayer else {
            throw GlossError.internalError("Layer create succeeded, but no layer is available in state.")
        }
        idempotency.recordLayerCreate(result, layer: layer, for: command.idempotencyKey)
        return .json(LayerCreateEnvelope(
            result: result,
            layer: layer,
            layerState: store.layerState,
            dedupedByServer: false
        ))
    }

    private static func applyCanvasNew(
        body: Data,
        store: CanvasStore,
        idempotency: ServerIdempotencyCache
    ) throws -> GlossHTTPResponse {
        let source = body.isEmpty ? Data("{}".utf8) : body
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: source)
        } catch {
            throw GlossError(code: "bad_json", message: "Invalid JSON body: \(error.localizedDescription)")
        }
        guard var object = jsonObject as? [String: Any] else {
            throw GlossError(code: "bad_json", message: "Expected a JSON object body.")
        }
        object["type"] = object["type"] ?? "canvasNew"

        if let presetName = object["preset"] as? String {
            guard let preset = GlossCanvasPresets.resolve(presetName) else {
                throw GlossError.bad("Unknown canvas preset '\(presetName)'. Call /canvas/presets for valid names.")
            }
            object["width"] = object["width"] ?? preset.width
            object["height"] = object["height"] ?? preset.height
            object["grid"] = object["grid"] ?? [
                "cell_w": preset.grid.cellW,
                "cell_h": preset.grid.cellH,
                "origin_x": preset.grid.originX,
                "origin_y": preset.grid.originY,
                "visible": preset.grid.visible,
                "opacity": preset.grid.opacity,
                "snap": preset.grid.snap
            ]
        }

        guard object["width"] != nil, object["height"] != nil else {
            throw GlossError.bad("Canvas new requires width and height, or a valid preset.")
        }

        let normalized = try JSONSerialization.data(withJSONObject: object)
        let command = try JSONDecoder().decode(DrawCommand.self, from: normalized)

        if let key = command.idempotencyKey, let cached = idempotency.result(for: key) {
            return .json(CommandEnvelope(result: cached, dedupedByServer: true))
        }
        let result = try store.apply(command)
        idempotency.record(result, for: command.idempotencyKey)
        return .json(CommandEnvelope(result: result, dedupedByServer: false))
    }

    private static func applyLayerVisibility(
        body: Data,
        path: String,
        store: CanvasStore,
        idempotency: ServerIdempotencyCache
    ) throws -> GlossHTTPResponse {
        let inferredType = "layerVisibility"
        let source = body.isEmpty ? Data("{}".utf8) : body
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: source)
        } catch {
            throw GlossError(code: "bad_json", message: "Invalid JSON body: \(error.localizedDescription)")
        }
        guard var object = jsonObject as? [String: Any] else {
            throw GlossError(code: "bad_json", message: "Expected a JSON object body.")
        }
        object["type"] = object["type"] ?? inferredType
        if path == "/layer/show" {
            object["visible"] = true
        } else if path == "/layer/hide" {
            object["visible"] = false
        }
        let normalized = try JSONSerialization.data(withJSONObject: object)
        let command = try JSONDecoder().decode(DrawCommand.self, from: normalized)

        if let key = command.idempotencyKey, let cached = idempotency.result(for: key) {
            return .json(CommandEnvelope(result: cached, dedupedByServer: true))
        }
        let result = try store.apply(command)
        idempotency.record(result, for: command.idempotencyKey)
        return .json(CommandEnvelope(result: result, dedupedByServer: false))
    }

    private static func asciiCanvas(query: [String: String], store: CanvasStore) throws -> GlossHTTPResponse {
        let modeRaw = (query["mode"] ?? "color").lowercased()
        guard let mode = AsciiMode(rawValue: modeRaw) else {
            return .error(code: "bad_request", message: "mode must be color, braille, or brightness.", status: 400)
        }
        let requestedGrid = gridFromQuery(query, defaultCols: 64, defaultRows: 48)
        let grid = cappedGrid(cols: requestedGrid.w, rows: requestedGrid.h, maxCells: 8_192)
        let region = try optionalRectFromQuery(query)
        let result = AsciiCanvasEncoder.encode(
            image: store.currentImage,
            revision: store.revision,
            mode: mode,
            grid: grid,
            region: region,
            fullmap: boolParam(query, "fullmap")
        )
        return .json(result)
    }

    private static func sampleGrid(query: [String: String], store: CanvasStore) -> GlossHTTPResponse {
        guard let rect = rectFromQuery(query) else {
            return .error(code: "bad_request", message: "Sample grid requires x, y, w, and h.", status: 400)
        }
        guard rect.width > 0, rect.height > 0 else {
            return .error(code: "bad_request", message: "Sample grid width and height must be positive.", status: 400)
        }
        let requestedStep = max(1, intParam(query, "step") ?? 8)
        let capStep = max(
            requestedStep,
            Int(ceil(rect.width / 64.0)),
            Int(ceil(rect.height / 64.0))
        )
        let xs = sampleAxis(start: rect.minX, length: rect.width, step: capStep)
        let ys = sampleAxis(start: rect.minY, length: rect.height, step: capStep)
        let samples = ys.map { y in
            xs.map { x in
                store.sample(at: CGPoint(x: x, y: y))
            }
        }
        return .json(SampleGridEnvelope(
            revision: store.revision,
            region: GlossRect(rect),
            requestedStep: requestedStep,
            step: capStep,
            cols: xs.count,
            rows: ys.count,
            x: xs,
            y: ys,
            samples: samples
        ))
    }

    private static func samplePath(query: [String: String], store: CanvasStore) -> GlossHTTPResponse {
        guard let raw = query["points"], !raw.isEmpty else {
            return .error(code: "bad_request", message: "Sample path requires points=x,y;x,y;...", status: 400)
        }
        do {
            let points = try parsePointList(raw)
            guard points.count <= 4_096 else {
                return .error(code: "bad_request", message: "Sample path is capped at 4096 points.", status: 400)
            }
            let samples = points.enumerated().map { index, point in
                PathSample(index: index, x: point.x, y: point.y, rgba: store.sample(at: point))
            }
            return .json(SamplePathEnvelope(revision: store.revision, samples: samples))
        } catch let error as GlossError {
            return .error(code: error.code, message: error.message, status: status(for: error))
        } catch {
            return .error(code: "bad_request", message: "Could not parse points.", status: 400)
        }
    }

    private static func gridCells(query: [String: String], store: CanvasStore) -> GlossHTTPResponse {
        guard let rect = rectFromQuery(query) else {
            return .error(code: "bad_request", message: "Grid cells requires x, y, w, and h.", status: 400)
        }
        let cells = store.gridCells(touching: rect)
        guard cells.count <= 100_000 else {
            return .error(
                code: "grid_query_too_large",
                message: "Grid cell query matched \(cells.count) cells; narrow the region.",
                status: 400
            )
        }
        return .json(GridCellsEnvelope(
            revision: store.revision,
            grid: store.grid,
            region: GlossRect(rect),
            cols: store.grid.columns(canvasWidth: store.width),
            rows: store.grid.rows(canvasHeight: store.height),
            cells: cells
        ))
    }

    private static func gridState(query: [String: String], store: CanvasStore) -> GlossHTTPResponse {
        guard let layerID = query["layerID"] ?? query["layer_id"], !layerID.isEmpty else {
            return .error(code: "bad_request", message: "Grid state requires layerID.", status: 400)
        }
        do {
            let state = try store.gridState(layerID: layerID)
            return .json(GridStateEnvelope(revision: store.revision, state: state))
        } catch let error as GlossError {
            return .error(code: error.code, message: error.message, status: status(for: error))
        } catch {
            return .error(code: "internal", message: error.localizedDescription, status: 500)
        }
    }

    private static func gridMask(query: [String: String], store: CanvasStore) -> GlossHTTPResponse {
        guard let layerID = query["layerID"] ?? query["layer_id"], !layerID.isEmpty else {
            return .error(code: "bad_request", message: "Grid mask requires layerID.", status: 400)
        }
        do {
            let image = try store.gridMaskImage(layerID: layerID)
            guard let data = PNGExporter.data(from: image) else {
                return .error(code: "png_export_failed", message: "Could not encode grid mask PNG.", status: 500)
            }
            return .png(data, revision: store.revision, width: image.width, height: image.height)
        } catch let error as GlossError {
            return .error(code: error.code, message: error.message, status: status(for: error))
        } catch {
            return .error(code: "internal", message: error.localizedDescription, status: 500)
        }
    }

    private static func decodeCommand(body: Data, inferredType: String) throws -> DrawCommand {
        let source = body.isEmpty ? Data("{}".utf8) : body
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: source)
        } catch {
            throw GlossError(code: "bad_json", message: "Invalid JSON body: \(error.localizedDescription)")
        }

        guard var object = jsonObject as? [String: Any] else {
            throw GlossError(code: "bad_json", message: "Expected a JSON object body.")
        }
        object["type"] = object["type"] ?? inferredType
        let normalized = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DrawCommand.self, from: normalized)
    }

    private static func rectFromQuery(_ query: [String: String]) -> CGRect? {
        guard let x = doubleParam(query, "x"),
              let y = doubleParam(query, "y"),
              let w = doubleParam(query, "w") ?? doubleParam(query, "width"),
              let h = doubleParam(query, "h") ?? doubleParam(query, "height") else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func optionalRectFromQuery(_ query: [String: String]) throws -> CGRect? {
        let hasAnyRegionKey = ["x", "y", "w", "h", "width", "height"].contains { query[$0] != nil }
        if !hasAnyRegionKey { return nil }
        guard let rect = rectFromQuery(query) else {
            throw GlossError.bad("ASCII region requires either no region, or x, y, w, and h.")
        }
        return rect
    }

    private static func gridFromQuery(_ query: [String: String], defaultCols: Int, defaultRows: Int) -> GlossSize {
        if let grid = query["grid"] {
            let parts = grid.lowercased().split(separator: "x", maxSplits: 1).compactMap { Int($0) }
            if parts.count == 2 {
                return GlossSize(w: parts[0], h: parts[1])
            }
        }
        let cols = intParam(query, "cols") ?? intParam(query, "columns") ?? defaultCols
        let rows = intParam(query, "rows") ?? defaultRows
        return GlossSize(w: cols, h: rows)
    }

    private static func cappedGrid(cols: Int, rows: Int, maxCells: Int) -> GlossSize {
        let safeCols = max(1, cols)
        let safeRows = max(1, rows)
        guard safeCols * safeRows > maxCells else {
            return GlossSize(w: safeCols, h: safeRows)
        }
        let ratio = Double(safeCols) / Double(safeRows)
        let cappedRows = max(1, Int(floor(sqrt(Double(maxCells) / ratio))))
        let cappedCols = max(1, min(maxCells, Int(floor(Double(cappedRows) * ratio))))
        return GlossSize(w: cappedCols, h: max(1, min(cappedRows, maxCells / max(1, cappedCols))))
    }

    private static func sampleAxis(start: Double, length: Double, step: Int) -> [Double] {
        let count = max(1, min(64, Int(ceil(length / Double(step)))))
        return (0..<count).map { start + Double($0 * step) }
    }

    private static func parsePointList(_ raw: String) throws -> [CGPoint] {
        let pairs = raw.split(separator: ";", omittingEmptySubsequences: true)
        guard !pairs.isEmpty else {
            throw GlossError.bad("Sample path requires at least one point.")
        }
        return try pairs.map { pair in
            let parts = pair.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
                throw GlossError.bad("Invalid point '\(pair)'; expected x,y.")
            }
            return CGPoint(x: x, y: y)
        }
    }

    private static func intParam(_ query: [String: String], _ key: String) -> Int? {
        query[key].flatMap(Int.init)
    }

    private static func doubleParam(_ query: [String: String], _ key: String) -> Double? {
        query[key].flatMap(Double.init)
    }

    private static func boolParam(_ query: [String: String], _ key: String) -> Bool {
        switch query[key]?.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    private static func status(for error: GlossError) -> Int {
        switch error.code {
        case "bad_request", "bad_json", "layer_locked", "layer_cap": return 400
        case "not_found", "layer_not_found": return 404
        case "not_implemented": return 501
        default: return 500
        }
    }

    private static func decodingMessage(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            return context.debugDescription
        case .keyNotFound(let key, let context):
            return "Missing key '\(key.stringValue)': \(context.debugDescription)"
        case .typeMismatch(let type, let context):
            return "Expected \(type): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "Missing value for \(type): \(context.debugDescription)"
        @unknown default:
            return "Invalid JSON body."
        }
    }
}

private struct StateEnvelope: Encodable {
    let ok = true
    let width: Int
    let height: Int
    let revision: Int
    let grid: GridSpec
    let lastCommands: [LastCommandSummary]
    let authorCursors: [String: GlossPoint]
    let layerState: LayerStackState

    init(state: CanvasState, layerState: LayerStackState) {
        self.width = state.width
        self.height = state.height
        self.revision = state.revision
        self.grid = state.grid
        self.lastCommands = state.lastCommands
        self.authorCursors = state.authorCursors
        self.layerState = layerState
    }
}

private struct LayersEnvelope: Encodable {
    let ok = true
    let layerState: LayerStackState
    let revision: Int
}

private struct CanvasPresetsEnvelope: Encodable {
    let ok = true
    let presets: [CanvasPreset]
}

private struct CommandEnvelope: Encodable {
    let ok = true
    let revision: Int
    let dirtyRect: GlossRect?
    let deduped: Bool
    let dedupedByServer: Bool

    init(result: CommandResult, dedupedByServer: Bool) {
        self.revision = result.revision
        self.dirtyRect = result.dirtyRect
        self.deduped = result.deduped || dedupedByServer
        self.dedupedByServer = dedupedByServer
    }
}

private struct LayerCreateEnvelope: Encodable {
    let ok = true
    let revision: Int
    let dirtyRect: GlossRect?
    let deduped: Bool
    let dedupedByServer: Bool
    let layer: GlossLayer
    let layerState: LayerStackState

    init(result: CommandResult, layer: GlossLayer, layerState: LayerStackState, dedupedByServer: Bool) {
        self.revision = result.revision
        self.dirtyRect = result.dirtyRect
        self.deduped = result.deduped || dedupedByServer
        self.dedupedByServer = dedupedByServer
        self.layer = layer
        self.layerState = layerState
    }
}

private struct SampleEnvelope: Encodable {
    let ok = true
    let x: Double
    let y: Double
    let rgba: RGBA
    let revision: Int
}

private struct SampleGridEnvelope: Encodable {
    let ok = true
    let revision: Int
    let region: GlossRect
    let requestedStep: Int
    let step: Int
    let cols: Int
    let rows: Int
    let x: [Double]
    let y: [Double]
    let samples: [[RGBA?]]
}

private struct SamplePathEnvelope: Encodable {
    let ok = true
    let revision: Int
    let samples: [PathSample]
}

private struct GridCellsEnvelope: Encodable {
    let ok = true
    let revision: Int
    let grid: GridSpec
    let region: GlossRect
    let cols: Int
    let rows: Int
    let cells: [GridCell]
}

private struct GridStateEnvelope: Encodable {
    let ok = true
    let revision: Int
    let layerID: String
    let grid: GridSpec
    let cols: Int
    let rows: Int
    let filledCells: [GridFilledCell]

    init(revision: Int, state: GridLayerState) {
        self.revision = revision
        self.layerID = state.layerID
        self.grid = state.grid
        self.cols = state.cols
        self.rows = state.rows
        self.filledCells = state.filledCells
    }

    enum CodingKeys: String, CodingKey {
        case ok, revision, layerID, grid, cols, rows
        case filledCells = "filled_cells"
    }
}

private struct PathSample: Encodable {
    let index: Int
    let x: Double
    let y: Double
    let rgba: RGBA?
}

private struct ErrorEnvelope: Encodable {
    let ok = false
    let error: APIError
}

private struct APIError: Encodable {
    let code: String
    let message: String
}
