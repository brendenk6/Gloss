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
    private var order: [String] = []
    private let cap = 256

    func result(for key: String) -> CommandResult? {
        results[key]
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
        }
    }

    func clear() {
        results.removeAll()
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
                return .json(StateEnvelope(state: store.state))

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

            case ("GET", "/sample"), ("GET", "/eyedropper"):
                guard let x = doubleParam(query, "x"), let y = doubleParam(query, "y") else {
                    return .error(code: "bad_request", message: "Sample requires x and y.", status: 400)
                }
                guard let rgba = store.sample(at: CGPoint(x: x, y: y)) else {
                    return .error(code: "out_of_bounds", message: "Sample point is outside the canvas.", status: 404)
                }
                return .json(SampleEnvelope(x: x, y: y, rgba: rgba, revision: store.revision))

            case ("POST", "/stroke"):
                return try apply(body: body, inferredType: "stroke", store: store, idempotency: idempotency)
            case ("POST", "/shape"):
                return try apply(body: body, inferredType: "shape", store: store, idempotency: idempotency)
            case ("POST", "/text"):
                return try apply(body: body, inferredType: "text", store: store, idempotency: idempotency)
            case ("POST", "/image"), ("POST", "/image_paste"):
                return try apply(body: body, inferredType: "image", store: store, idempotency: idempotency)
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

    private static func intParam(_ query: [String: String], _ key: String) -> Int? {
        query[key].flatMap(Int.init)
    }

    private static func doubleParam(_ query: [String: String], _ key: String) -> Double? {
        query[key].flatMap(Double.init)
    }

    private static func status(for error: GlossError) -> Int {
        switch error.code {
        case "bad_request", "bad_json": return 400
        case "not_found": return 404
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
    let lastCommands: [LastCommandSummary]
    let authorCursors: [String: GlossPoint]

    init(state: CanvasState) {
        self.width = state.width
        self.height = state.height
        self.revision = state.revision
        self.lastCommands = state.lastCommands
        self.authorCursors = state.authorCursors
    }
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

private struct SampleEnvelope: Encodable {
    let ok = true
    let x: Double
    let y: Double
    let rgba: RGBA
    let revision: Int
}

private struct ErrorEnvelope: Encodable {
    let ok = false
    let error: APIError
}

private struct APIError: Encodable {
    let code: String
    let message: String
}
