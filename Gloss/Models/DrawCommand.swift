import Foundation
import CoreGraphics

// MARK: - Color (hex + alpha)

public struct GlossColor: Codable, Sendable, Equatable {
    public let r: Double  // 0…1
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = max(0, min(1, r))
        self.g = max(0, min(1, g))
        self.b = max(0, min(1, b))
        self.a = max(0, min(1, a))
    }

    /// Decode from hex strings: "#RRGGBB" or "#RRGGBBAA". Alpha override wins.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let hex = try? container.decode(String.self) {
            self = GlossColor.fromHex(hex) ?? GlossColor(r: 0, g: 0, b: 0, a: 1)
            return
        }
        if let dict = try? container.decode([String: Double].self) {
            self.init(
                r: dict["r"] ?? 0,
                g: dict["g"] ?? 0,
                b: dict["b"] ?? 0,
                a: dict["a"] ?? 1
            )
            return
        }
        throw DecodingError.typeMismatch(
            GlossColor.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected hex string or {r,g,b,a} dict")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(toHex())
    }

    public static func fromHex(_ raw: String) -> GlossColor? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let hasAlpha = (s.count == 8)
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1.0
        return GlossColor(r: r, g: g, b: b, a: a)
    }

    public func toHex() -> String {
        let R = Int(round(r * 255)), G = Int(round(g * 255)), B = Int(round(b * 255)), A = Int(round(a * 255))
        if A == 255 {
            return String(format: "#%02X%02X%02X", R, G, B)
        }
        return String(format: "#%02X%02X%02X%02X", R, G, B, A)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Point

public struct GlossPoint: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

// MARK: - Blend mode (subset of CGBlendMode)

public enum GlossBlend: String, Codable, Sendable {
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten
    case plusLighter
    case plusDarker
    case clear

    public var cgBlend: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .plusLighter: return .plusLighter
        case .plusDarker: return .plusDarker
        case .clear: return .clear
        }
    }
}

// MARK: - Shape kind

public enum GlossShapeKind: String, Codable, Sendable {
    case rect
    case ellipse
    case line
    case roundedRect
}

// MARK: - DrawCommand

/// All canvas mutations are expressed as a DrawCommand. The HTTP layer decodes
/// JSON straight into this enum and hands it to CanvasStore.apply.
public enum DrawCommand: Codable, Sendable {
    case stroke(StrokePayload)
    case shape(ShapePayload)
    case text(TextPayload)
    case image(ImagePayload)
    case clear(ClearPayload)
    case undo(MetaPayload)
    case redo(MetaPayload)
    case resize(ResizePayload)

    // MARK: Common metadata

    public var author: String? {
        switch self {
        case .stroke(let p): return p.author
        case .shape(let p): return p.author
        case .text(let p): return p.author
        case .image(let p): return p.author
        case .clear(let p): return p.author
        case .undo(let p): return p.author
        case .redo(let p): return p.author
        case .resize(let p): return p.author
        }
    }

    public var idempotencyKey: String? {
        switch self {
        case .stroke(let p): return p.idempotencyKey
        case .shape(let p): return p.idempotencyKey
        case .text(let p): return p.idempotencyKey
        case .image(let p): return p.idempotencyKey
        case .clear(let p): return p.idempotencyKey
        case .undo(let p): return p.idempotencyKey
        case .redo(let p): return p.idempotencyKey
        case .resize(let p): return p.idempotencyKey
        }
    }

    /// Short tag for chrome overlay / logs.
    public var displayKind: String {
        switch self {
        case .stroke: return "stroke"
        case .shape: return "shape"
        case .text: return "text"
        case .image: return "image"
        case .clear: return "clear"
        case .undo: return "undo"
        case .redo: return "redo"
        case .resize: return "resize"
        }
    }

    // MARK: Codable (tagged union — top-level "type" key)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()
        switch type {
        case "stroke": self = .stroke(try single.decode(StrokePayload.self))
        case "shape":  self = .shape(try single.decode(ShapePayload.self))
        case "text":   self = .text(try single.decode(TextPayload.self))
        case "image":  self = .image(try single.decode(ImagePayload.self))
        case "clear":  self = .clear(try single.decode(ClearPayload.self))
        case "undo":   self = .undo(try single.decode(MetaPayload.self))
        case "redo":   self = .redo(try single.decode(MetaPayload.self))
        case "resize": self = .resize(try single.decode(ResizePayload.self))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown command type \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .stroke(let p): try single.encode(_TaggedEncode(type: "stroke", payload: p))
        case .shape(let p):  try single.encode(_TaggedEncode(type: "shape",  payload: p))
        case .text(let p):   try single.encode(_TaggedEncode(type: "text",   payload: p))
        case .image(let p):  try single.encode(_TaggedEncode(type: "image",  payload: p))
        case .clear(let p):  try single.encode(_TaggedEncode(type: "clear",  payload: p))
        case .undo(let p):   try single.encode(_TaggedEncode(type: "undo",   payload: p))
        case .redo(let p):   try single.encode(_TaggedEncode(type: "redo",   payload: p))
        case .resize(let p): try single.encode(_TaggedEncode(type: "resize", payload: p))
        }
    }
}

// MARK: - Payload structs

public struct StrokePayload: Codable, Sendable {
    public var author: String?
    public var idempotencyKey: String?
    public var layerID: String?
    public var points: [GlossPoint]
    public var width: Double          // px
    public var color: GlossColor
    public var opacity: Double        // 0…1, multiplies color.a
    public var blend: GlossBlend
    public var simplify: Double?      // optional resample tolerance

    public init(author: String? = nil, idempotencyKey: String? = nil, layerID: String? = nil,
                points: [GlossPoint], width: Double, color: GlossColor,
                opacity: Double = 1, blend: GlossBlend = .normal, simplify: Double? = nil) {
        self.author = author
        self.idempotencyKey = idempotencyKey
        self.layerID = layerID
        self.points = points
        self.width = max(0.1, width)
        self.color = color
        self.opacity = max(0, min(1, opacity))
        self.blend = blend
        self.simplify = simplify
    }
}

public struct ShapePayload: Codable, Sendable {
    public var author: String?
    public var idempotencyKey: String?
    public var layerID: String?
    public var kind: GlossShapeKind
    /// For rect/ellipse/roundedRect: rect fields.
    public var x: Double
    public var y: Double
    public var w: Double?
    public var h: Double?
    /// For line: x2,y2.
    public var x2: Double?
    public var y2: Double?
    public var radius: Double?        // roundedRect corner
    public var stroke: GlossColor?
    public var strokeWidth: Double?
    public var fill: GlossColor?
    public var opacity: Double
    public var blend: GlossBlend

    public init(author: String? = nil, idempotencyKey: String? = nil, layerID: String? = nil,
                kind: GlossShapeKind,
                x: Double, y: Double, w: Double? = nil, h: Double? = nil,
                x2: Double? = nil, y2: Double? = nil, radius: Double? = nil,
                stroke: GlossColor? = nil, strokeWidth: Double? = nil,
                fill: GlossColor? = nil, opacity: Double = 1, blend: GlossBlend = .normal) {
        self.author = author
        self.idempotencyKey = idempotencyKey
        self.layerID = layerID
        self.kind = kind
        self.x = x; self.y = y
        self.w = w; self.h = h
        self.x2 = x2; self.y2 = y2
        self.radius = radius
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.fill = fill
        self.opacity = max(0, min(1, opacity))
        self.blend = blend
    }
}

public struct TextPayload: Codable, Sendable {
    public var author: String?
    public var idempotencyKey: String?
    public var layerID: String?
    public var string: String
    public var x: Double
    public var y: Double
    public var fontSize: Double
    public var fontName: String?      // e.g. "Helvetica", "SF Pro Rounded"
    public var weight: String?        // "regular", "medium", "bold", "heavy"
    public var color: GlossColor
    public var opacity: Double
    public var blend: GlossBlend

    public init(author: String? = nil, idempotencyKey: String? = nil, layerID: String? = nil,
                string: String, x: Double, y: Double,
                fontSize: Double = 24, fontName: String? = nil, weight: String? = nil,
                color: GlossColor = GlossColor(r: 0, g: 0, b: 0),
                opacity: Double = 1, blend: GlossBlend = .normal) {
        self.author = author
        self.idempotencyKey = idempotencyKey
        self.layerID = layerID
        self.string = string
        self.x = x; self.y = y
        self.fontSize = max(1, fontSize)
        self.fontName = fontName
        self.weight = weight
        self.color = color
        self.opacity = max(0, min(1, opacity))
        self.blend = blend
    }
}

public struct ImagePayload: Codable, Sendable {
    public var author: String?
    public var idempotencyKey: String?
    public var layerID: String?
    public var pngBase64: String
    public var x: Double
    public var y: Double
    public var w: Double?             // optional resize on stamp
    public var h: Double?
    public var opacity: Double
    public var blend: GlossBlend

    public init(author: String? = nil, idempotencyKey: String? = nil, layerID: String? = nil,
                pngBase64: String, x: Double, y: Double, w: Double? = nil, h: Double? = nil,
                opacity: Double = 1, blend: GlossBlend = .normal) {
        self.author = author
        self.idempotencyKey = idempotencyKey
        self.layerID = layerID
        self.pngBase64 = pngBase64
        self.x = x; self.y = y; self.w = w; self.h = h
        self.opacity = max(0, min(1, opacity))
        self.blend = blend
    }
}

public struct ClearPayload: Codable, Sendable {
    public var author: String?
    public var idempotencyKey: String?
    public var layerID: String?
    public var color: GlossColor?     // optional fill color, default white
    public init(author: String? = nil, idempotencyKey: String? = nil, layerID: String? = nil,
                color: GlossColor? = nil) {
        self.author = author
        self.idempotencyKey = idempotencyKey
        self.layerID = layerID
        self.color = color
    }
}

public struct MetaPayload: Codable, Sendable {
    public var author: String?
    public var idempotencyKey: String?
    public init(author: String? = nil, idempotencyKey: String? = nil) {
        self.author = author
        self.idempotencyKey = idempotencyKey
    }
}

public struct ResizePayload: Codable, Sendable {
    public var author: String?
    public var idempotencyKey: String?
    public var width: Int
    public var height: Int
    public var preserveContents: Bool   // true → stretch; false → clear to white
    public init(author: String? = nil, idempotencyKey: String? = nil,
                width: Int, height: Int, preserveContents: Bool = true) {
        self.author = author
        self.idempotencyKey = idempotencyKey
        self.width = max(16, min(8192, width))
        self.height = max(16, min(8192, height))
        self.preserveContents = preserveContents
    }
}

// MARK: - Result / state envelopes

public struct CommandResult: Codable, Sendable {
    public var revision: Int
    public var dirtyRect: GlossRect?
    public var deduped: Bool   // true when an idempotency-key match no-op'd
    public init(revision: Int, dirtyRect: GlossRect? = nil, deduped: Bool = false) {
        self.revision = revision
        self.dirtyRect = dirtyRect
        self.deduped = deduped
    }
}

public struct GlossRect: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    public init(_ cg: CGRect) {
        self.x = cg.origin.x; self.y = cg.origin.y
        self.w = cg.size.width; self.h = cg.size.height
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public struct RGBA: Codable, Sendable, Equatable {
    public let r: Int  // 0…255
    public let g: Int
    public let b: Int
    public let a: Int
    public init(r: Int, g: Int, b: Int, a: Int) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public struct CanvasState: Codable, Sendable {
    public var width: Int
    public var height: Int
    public var revision: Int
    public var lastCommands: [LastCommandSummary]
    public var authorCursors: [String: GlossPoint]   // author → last-known cursor
    public init(width: Int, height: Int, revision: Int,
                lastCommands: [LastCommandSummary], authorCursors: [String: GlossPoint]) {
        self.width = width; self.height = height; self.revision = revision
        self.lastCommands = lastCommands; self.authorCursors = authorCursors
    }
}

public struct LastCommandSummary: Codable, Sendable {
    public var revision: Int
    public var kind: String
    public var author: String?
    public var idempotencyKey: String?
    public init(revision: Int, kind: String, author: String? = nil, idempotencyKey: String? = nil) {
        self.revision = revision
        self.kind = kind
        self.author = author
        self.idempotencyKey = idempotencyKey
    }
}

// MARK: - Error envelope

public struct GlossError: Codable, Sendable, Error {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
    public static func bad(_ msg: String) -> GlossError { .init(code: "bad_request", message: msg) }
    public static func internalError(_ msg: String) -> GlossError { .init(code: "internal", message: msg) }
    public static func notFound(_ msg: String) -> GlossError { .init(code: "not_found", message: msg) }
}

// MARK: - Internal tagged-encode helper

private struct _TaggedEncode<T: Encodable>: Encodable {
    let type: String
    let payload: T
    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(type, forKey: .type)
    }
    private enum TypeKey: String, CodingKey { case type }
}
