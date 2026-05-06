import CoreGraphics
import Foundation

public struct GridSpec: Codable, Sendable, Equatable {
    public static let defaultCellSize = 16
    public static let minCellSize = 4

    public var cellW: Int
    public var cellH: Int
    public var originX: Int
    public var originY: Int
    public var visible: Bool
    public var opacity: Double
    public var snap: Bool

    public init(
        cellW: Int = GridSpec.defaultCellSize,
        cellH: Int = GridSpec.defaultCellSize,
        originX: Int = 0,
        originY: Int = 0,
        visible: Bool = false,
        opacity: Double = 0.35,
        snap: Bool = false
    ) {
        self.cellW = max(GridSpec.minCellSize, cellW)
        self.cellH = max(GridSpec.minCellSize, cellH)
        self.originX = max(0, originX)
        self.originY = max(0, originY)
        self.visible = visible
        self.opacity = max(0, min(1, opacity))
        self.snap = snap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GridCodingKey.self)
        self.init(
            cellW: try c.decodeInt(keys: "cell_w", "cellW") ?? GridSpec.defaultCellSize,
            cellH: try c.decodeInt(keys: "cell_h", "cellH") ?? GridSpec.defaultCellSize,
            originX: try c.decodeInt(keys: "origin_x", "originX") ?? 0,
            originY: try c.decodeInt(keys: "origin_y", "originY") ?? 0,
            visible: try c.decodeBool(keys: "visible") ?? false,
            opacity: try c.decodeDouble(keys: "opacity") ?? 0.35,
            snap: try c.decodeBool(keys: "snap", "snap_enabled", "snapEnabled") ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: GridCodingKey.self)
        try c.encode(cellW, forKey: GridCodingKey("cell_w"))
        try c.encode(cellH, forKey: GridCodingKey("cell_h"))
        try c.encode(originX, forKey: GridCodingKey("origin_x"))
        try c.encode(originY, forKey: GridCodingKey("origin_y"))
        try c.encode(visible, forKey: GridCodingKey("visible"))
        try c.encode(opacity, forKey: GridCodingKey("opacity"))
        try c.encode(snap, forKey: GridCodingKey("snap"))
    }

    public func normalized(canvasWidth: Int, canvasHeight: Int) -> GridSpec {
        GridSpec(
            cellW: cellW,
            cellH: cellH,
            originX: min(max(0, originX), max(0, canvasWidth - GridSpec.minCellSize)),
            originY: min(max(0, originY), max(0, canvasHeight - GridSpec.minCellSize)),
            visible: visible,
            opacity: opacity,
            snap: snap
        )
    }

    public func columns(canvasWidth: Int) -> Int {
        guard originX < canvasWidth else { return 0 }
        return max(0, (canvasWidth - originX) / cellW)
    }

    public func rows(canvasHeight: Int) -> Int {
        guard originY < canvasHeight else { return 0 }
        return max(0, (canvasHeight - originY) / cellH)
    }

    public func rect(for cell: GridCellIndex, canvasWidth: Int, canvasHeight: Int) -> CGRect? {
        let cols = columns(canvasWidth: canvasWidth)
        let rows = rows(canvasHeight: canvasHeight)
        guard cell.cx >= 0, cell.cy >= 0, cell.cx < cols, cell.cy < rows else {
            return nil
        }
        return CGRect(
            x: originX + cell.cx * cellW,
            y: originY + cell.cy * cellH,
            width: cellW,
            height: cellH
        )
    }

    public func cells(touching rect: CGRect, canvasWidth: Int, canvasHeight: Int) -> [GridCell] {
        let cols = columns(canvasWidth: canvasWidth)
        let rows = rows(canvasHeight: canvasHeight)
        guard cols > 0, rows > 0 else { return [] }

        let gridRect = CGRect(
            x: originX,
            y: originY,
            width: cols * cellW,
            height: rows * cellH
        )
        let bounded = rect.standardized.intersection(gridRect)
        guard !bounded.isNull, !bounded.isEmpty else { return [] }

        let epsilon = 0.000_001
        let minCol = max(0, Int(floor((bounded.minX - CGFloat(originX)) / CGFloat(cellW))))
        let maxCol = min(cols - 1, Int(floor((bounded.maxX - CGFloat(originX) - epsilon) / CGFloat(cellW))))
        let minRow = max(0, Int(floor((bounded.minY - CGFloat(originY)) / CGFloat(cellH))))
        let maxRow = min(rows - 1, Int(floor((bounded.maxY - CGFloat(originY) - epsilon) / CGFloat(cellH))))
        guard minCol <= maxCol, minRow <= maxRow else { return [] }

        var out: [GridCell] = []
        out.reserveCapacity((maxCol - minCol + 1) * (maxRow - minRow + 1))
        for cy in minRow...maxRow {
            for cx in minCol...maxCol {
                out.append(GridCell(
                    cx: cx,
                    cy: cy,
                    x: originX + cx * cellW,
                    y: originY + cy * cellH,
                    w: cellW,
                    h: cellH
                ))
            }
        }
        return out
    }

    public func snappedPoint(_ point: CGPoint, canvasWidth: Int, canvasHeight: Int) -> CGPoint {
        guard snap else { return point }
        let x = snappedCoordinate(point.x, origin: originX, cell: cellW, maxValue: canvasWidth - 1)
        let y = snappedCoordinate(point.y, origin: originY, cell: cellH, maxValue: canvasHeight - 1)
        return CGPoint(x: x, y: y)
    }

    private func snappedCoordinate(_ raw: CGFloat, origin: Int, cell: Int, maxValue: Int) -> CGFloat {
        let relative = (raw - CGFloat(origin)) / CGFloat(cell)
        let snapped = CGFloat(origin) + relative.rounded() * CGFloat(cell)
        return min(max(0, snapped), CGFloat(max(0, maxValue)))
    }
}

public struct GridConfigPayload: Codable, Sendable {
    public var author: String?
    public var idempotencyKey: String?
    public var cellW: Int?
    public var cellH: Int?
    public var originX: Int?
    public var originY: Int?
    public var visible: Bool?
    public var opacity: Double?
    public var snap: Bool?

    public init(
        author: String? = nil,
        idempotencyKey: String? = nil,
        cellW: Int? = nil,
        cellH: Int? = nil,
        originX: Int? = nil,
        originY: Int? = nil,
        visible: Bool? = nil,
        opacity: Double? = nil,
        snap: Bool? = nil
    ) {
        self.author = author
        self.idempotencyKey = idempotencyKey
        self.cellW = cellW
        self.cellH = cellH
        self.originX = originX
        self.originY = originY
        self.visible = visible
        self.opacity = opacity
        self.snap = snap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GridCodingKey.self)
        self.init(
            author: try c.decodeString(keys: "author"),
            idempotencyKey: try c.decodeString(keys: "idempotencyKey", "idempotency_key"),
            cellW: try c.decodeInt(keys: "cell_w", "cellW"),
            cellH: try c.decodeInt(keys: "cell_h", "cellH"),
            originX: try c.decodeInt(keys: "origin_x", "originX"),
            originY: try c.decodeInt(keys: "origin_y", "originY"),
            visible: try c.decodeBool(keys: "visible"),
            opacity: try c.decodeDouble(keys: "opacity"),
            snap: try c.decodeBool(keys: "snap", "snap_enabled", "snapEnabled")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: GridCodingKey.self)
        try c.encodeIfPresent(author, forKey: GridCodingKey("author"))
        try c.encodeIfPresent(idempotencyKey, forKey: GridCodingKey("idempotencyKey"))
        try c.encodeIfPresent(cellW, forKey: GridCodingKey("cell_w"))
        try c.encodeIfPresent(cellH, forKey: GridCodingKey("cell_h"))
        try c.encodeIfPresent(originX, forKey: GridCodingKey("origin_x"))
        try c.encodeIfPresent(originY, forKey: GridCodingKey("origin_y"))
        try c.encodeIfPresent(visible, forKey: GridCodingKey("visible"))
        try c.encodeIfPresent(opacity, forKey: GridCodingKey("opacity"))
        try c.encodeIfPresent(snap, forKey: GridCodingKey("snap"))
    }

    public func merged(with current: GridSpec, canvasWidth: Int, canvasHeight: Int) -> GridSpec {
        GridSpec(
            cellW: cellW ?? current.cellW,
            cellH: cellH ?? current.cellH,
            originX: originX ?? current.originX,
            originY: originY ?? current.originY,
            visible: visible ?? current.visible,
            opacity: opacity ?? current.opacity,
            snap: snap ?? current.snap
        ).normalized(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }
}

public struct GridFillPayload: Codable, Sendable {
    public var author: String?
    public var idempotencyKey: String?
    public var layerID: String?
    public var cells: [GridCellIndex]
    public var color: GlossColor
    public var opacity: Double
    public var blend: GlossBlend

    public init(
        author: String? = nil,
        idempotencyKey: String? = nil,
        layerID: String? = nil,
        cells: [GridCellIndex],
        color: GlossColor,
        opacity: Double = 1,
        blend: GlossBlend = .normal
    ) {
        self.author = author
        self.idempotencyKey = idempotencyKey
        self.layerID = layerID
        self.cells = cells
        self.color = color
        self.opacity = max(0, min(1, opacity))
        self.blend = blend
    }

    private enum CodingKeys: String, CodingKey {
        case author, idempotencyKey, layerID, cells, color, opacity, blend
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.author = try c.decodeIfPresent(String.self, forKey: .author)
        self.idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
        self.layerID = try c.decodeIfPresent(String.self, forKey: .layerID)
        self.cells = try c.decode([GridCellIndex].self, forKey: .cells)
        self.color = try c.decode(GlossColor.self, forKey: .color)
        self.opacity = max(0, min(1, try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1))
        self.blend = try c.decodeIfPresent(GlossBlend.self, forKey: .blend) ?? .normal
    }
}

public struct GridCellIndex: Codable, Sendable, Hashable {
    public var cx: Int
    public var cy: Int

    public init(cx: Int, cy: Int) {
        self.cx = cx
        self.cy = cy
    }

    public init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            let cx = try array.decode(Int.self)
            let cy = try array.decode(Int.self)
            self.init(cx: cx, cy: cy)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(cx: try c.decode(Int.self, forKey: .cx),
                  cy: try c.decode(Int.self, forKey: .cy))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cx, forKey: .cx)
        try c.encode(cy, forKey: .cy)
    }

    private enum CodingKeys: String, CodingKey { case cx, cy }
}

public struct GridCell: Codable, Sendable, Equatable {
    public var cx: Int
    public var cy: Int
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(cx: Int, cy: Int, x: Int, y: Int, w: Int, h: Int) {
        self.cx = cx
        self.cy = cy
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct GridFilledCell: Codable, Sendable, Equatable {
    public var cx: Int
    public var cy: Int
    public var color: String

    public init(cx: Int, cy: Int, color: String) {
        self.cx = cx
        self.cy = cy
        self.color = color
    }

    public init(from decoder: Decoder) throws {
        var array = try decoder.unkeyedContainer()
        self.cx = try array.decode(Int.self)
        self.cy = try array.decode(Int.self)
        self.color = try array.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var array = encoder.unkeyedContainer()
        try array.encode(cx)
        try array.encode(cy)
        try array.encode(color)
    }
}

public struct GridLayerState: Codable, Sendable, Equatable {
    public var layerID: String
    public var grid: GridSpec
    public var cols: Int
    public var rows: Int
    public var filledCells: [GridFilledCell]

    public init(layerID: String, grid: GridSpec, cols: Int, rows: Int, filledCells: [GridFilledCell]) {
        self.layerID = layerID
        self.grid = grid
        self.cols = cols
        self.rows = rows
        self.filledCells = filledCells
    }

    private enum CodingKeys: String, CodingKey {
        case layerID
        case grid
        case cols
        case rows
        case filledCells = "filled_cells"
    }
}

private struct GridCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == GridCodingKey {
    func decodeInt(keys: String...) throws -> Int? {
        for key in keys {
            if let value = try decodeIfPresent(Int.self, forKey: GridCodingKey(key)) {
                return value
            }
        }
        return nil
    }

    func decodeDouble(keys: String...) throws -> Double? {
        for key in keys {
            if let value = try decodeIfPresent(Double.self, forKey: GridCodingKey(key)) {
                return value
            }
        }
        return nil
    }

    func decodeBool(keys: String...) throws -> Bool? {
        for key in keys {
            if let value = try decodeIfPresent(Bool.self, forKey: GridCodingKey(key)) {
                return value
            }
        }
        return nil
    }

    func decodeString(keys: String...) throws -> String? {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: GridCodingKey(key)) {
                return value
            }
        }
        return nil
    }
}
