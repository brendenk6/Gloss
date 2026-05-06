import Foundation
import CoreGraphics

// MARK: - Public types

public enum AsciiMode: String, Codable, Sendable {
    case color       // palette letter per cell + edge marks
    case braille     // 2x4 binary pixel pack via Unicode braille
    case brightness  // 5-level grayscale + edges
}

public struct GlossSize: Codable, Sendable, Equatable {
    public let w: Int
    public let h: Int
    public init(w: Int, h: Int) {
        self.w = max(1, w)
        self.h = max(1, h)
    }
}

public struct AsciiCellTag: Codable, Sendable {
    public let col: Int
    public let row: Int
    public let x: Int       // pixel x of cell center in source coords
    public let y: Int       // pixel y of cell center in source coords
    public let char: String
    public let color: String?  // hex, when mode emits color info
}

public struct AsciiCanvasResult: Codable, Sendable {
    public let mode: String
    public let grid: GlossSize          // cols x rows
    public let region: GlossRect        // source region in canvas coords
    public let cellSize: [Double]       // [cellW, cellH] in pixels
    public let legend: [String: String] // {"A":"aqua #7FFFD4", ...}
    public let rows: [String]           // one row per element
    public let cells: [AsciiCellTag]?   // populated when fullmap=true
    public let revision: Int
}

// MARK: - Encoder

@MainActor
public enum AsciiCanvasEncoder {

    /// Encode a region of the source image as a text grid at the requested mode.
    /// `region` defaults to the entire image. `grid` controls precision.
    public static func encode(
        image: CGImage,
        revision: Int,
        mode: AsciiMode,
        grid: GlossSize,
        region: CGRect? = nil,
        fullmap: Bool = false
    ) -> AsciiCanvasResult {
        let imageW = image.width
        let imageH = image.height
        let bounds = CGRect(x: 0, y: 0, width: imageW, height: imageH)
        let src = (region ?? bounds).intersection(bounds).integral
        let safeSrc = src.isEmpty ? bounds : src

        // Sample raw RGBA. We rasterize into a deterministic top-left RGBA buffer
        // sized to the requested cell grid (or 2× rows for braille — braille
        // packs 4 vertical pixels into one cell, so we want cellHeight*4 rows).
        let cols = grid.w
        let rows = mode == .braille ? grid.h : grid.h
        let sampleW = mode == .braille ? cols * 2 : cols
        let sampleH = mode == .braille ? rows * 4 : rows

        guard let pixels = renderToRGBABuffer(
            image: image,
            sourceRegion: safeSrc,
            outW: sampleW,
            outH: sampleH
        ) else {
            return AsciiCanvasResult(
                mode: mode.rawValue,
                grid: grid,
                region: GlossRect(safeSrc),
                cellSize: [safeSrc.width / Double(grid.w), safeSrc.height / Double(grid.h)],
                legend: [:],
                rows: [],
                cells: nil,
                revision: revision
            )
        }

        let cellW = safeSrc.width / Double(grid.w)
        let cellH = safeSrc.height / Double(grid.h)

        let rowsOut: [String]
        let legend: [String: String]
        let cellsOut: [AsciiCellTag]?

        switch mode {
        case .color:
            (rowsOut, legend, cellsOut) = encodeColor(
                pixels: pixels, sampleW: sampleW, sampleH: sampleH,
                cols: cols, rows: rows,
                regionOrigin: safeSrc.origin,
                cellW: cellW, cellH: cellH,
                fullmap: fullmap
            )
        case .braille:
            (rowsOut, legend, cellsOut) = encodeBraille(
                pixels: pixels, sampleW: sampleW, sampleH: sampleH,
                cols: cols, rows: rows,
                regionOrigin: safeSrc.origin,
                cellW: cellW, cellH: cellH,
                fullmap: fullmap
            )
        case .brightness:
            (rowsOut, legend, cellsOut) = encodeBrightness(
                pixels: pixels, sampleW: sampleW, sampleH: sampleH,
                cols: cols, rows: rows,
                regionOrigin: safeSrc.origin,
                cellW: cellW, cellH: cellH,
                fullmap: fullmap
            )
        }

        return AsciiCanvasResult(
            mode: mode.rawValue,
            grid: grid,
            region: GlossRect(safeSrc),
            cellSize: [cellW, cellH],
            legend: legend,
            rows: rowsOut,
            cells: fullmap ? cellsOut : nil,
            revision: revision
        )
    }

    // MARK: - Buffer rendering

    /// Resample the image region into a top-left-origin RGBA buffer at outW×outH.
    private static func renderToRGBABuffer(
        image: CGImage,
        sourceRegion: CGRect,
        outW: Int,
        outH: Int
    ) -> [UInt8]? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard outW > 0, outH > 0 else { return nil }
        let bytesPerRow = outW * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * outH)
        let result: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: outW,
                height: outH,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: bitmapInfo
            ) else { return false }
            // Top-left origin to match our public convention.
            ctx.translateBy(x: 0, y: CGFloat(outH))
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none  // exact pixel sampling for ascii
            // Source rect in image coords (top-left origin in our public model).
            // CGContext.draw treats the destination rect in user-space (top-left
            // post-flip). We need to position the source image such that
            // sourceRegion maps to the full output rect.
            let scaleX = CGFloat(outW) / sourceRegion.width
            let scaleY = CGFloat(outH) / sourceRegion.height
            let drawW = CGFloat(image.width) * scaleX
            let drawH = CGFloat(image.height) * scaleY
            // The image's CGImage is bottom-up; CGContext.draw flips it as part
            // of its own contract. After our top-left CTM setup, drawing the
            // entire image at (-x*scale, -(imgH - y - h)*scale, drawW, drawH)
            // crops to the requested region.
            let drawRect = CGRect(
                x: -sourceRegion.minX * scaleX,
                y: -(CGFloat(image.height) - sourceRegion.maxY) * scaleY,
                width: drawW,
                height: drawH
            )
            ctx.draw(image, in: drawRect)
            return true
        }
        return result ? buffer : nil
    }

    // MARK: - Color mode

    /// Average each cell to RGB, then map to nearest palette letter.
    private static func encodeColor(
        pixels: [UInt8], sampleW: Int, sampleH: Int,
        cols: Int, rows: Int,
        regionOrigin: CGPoint,
        cellW: Double, cellH: Double,
        fullmap: Bool
    ) -> ([String], [String: String], [AsciiCellTag]?) {
        // Sample is exactly cols × rows for color mode (not 2x4 packed).
        var lines: [String] = []
        lines.reserveCapacity(rows)
        var cells: [AsciiCellTag] = fullmap ? [] : []

        for r in 0..<rows {
            var line = ""
            line.reserveCapacity(cols)
            for c in 0..<cols {
                let idx = (r * sampleW + c) * 4
                let red = pixels[idx + 0]
                let grn = pixels[idx + 1]
                let blu = pixels[idx + 2]
                let alp = pixels[idx + 3]
                let entry = nearestPaletteEntry(r: red, g: grn, b: blu, a: alp)
                line.append(entry.letter)
                if fullmap {
                    let cx = Int(regionOrigin.x + (Double(c) + 0.5) * cellW)
                    let cy = Int(regionOrigin.y + (Double(r) + 0.5) * cellH)
                    cells.append(AsciiCellTag(
                        col: c, row: r, x: cx, y: cy,
                        char: String(entry.letter),
                        color: String(format: "#%02X%02X%02X", red, grn, blu)
                    ))
                }
            }
            lines.append(line)
        }

        let legend: [String: String] = paletteLegend
        return (lines, legend, fullmap ? cells : nil)
    }

    // MARK: - Braille mode

    /// 2x4 pixel block per cell. Threshold ink density and pack into Unicode braille.
    /// Threshold uses luminance — anything darker than ~0.92 of pure white is "ink".
    private static func encodeBraille(
        pixels: [UInt8], sampleW: Int, sampleH: Int,
        cols: Int, rows: Int,
        regionOrigin: CGPoint,
        cellW: Double, cellH: Double,
        fullmap: Bool
    ) -> ([String], [String: String], [AsciiCellTag]?) {
        // Bit positions in the U+2800 base for each subpixel of the 2x4 block.
        // Layout (col, row inside block): bit value
        //  (0,0)=1   (1,0)=8
        //  (0,1)=2   (1,1)=16
        //  (0,2)=4   (1,2)=32
        //  (0,3)=64  (1,3)=128
        let bits: [(Int, Int, Int)] = [
            (0, 0, 0x01),
            (0, 1, 0x02),
            (0, 2, 0x04),
            (1, 0, 0x08),
            (1, 1, 0x10),
            (1, 2, 0x20),
            (0, 3, 0x40),
            (1, 3, 0x80)
        ]
        let braillBase: UInt32 = 0x2800

        var lines: [String] = []
        lines.reserveCapacity(rows)
        var cells: [AsciiCellTag] = []

        for r in 0..<rows {
            var line = ""
            line.reserveCapacity(cols)
            for c in 0..<cols {
                var pattern: UInt32 = 0
                let baseX = c * 2
                let baseY = r * 4
                for (dx, dy, bit) in bits {
                    let px = baseX + dx
                    let py = baseY + dy
                    if px < 0 || px >= sampleW || py < 0 || py >= sampleH { continue }
                    let idx = (py * sampleW + px) * 4
                    let lum = luminance(
                        r: pixels[idx + 0],
                        g: pixels[idx + 1],
                        b: pixels[idx + 2]
                    )
                    if lum < 0.92 { pattern |= UInt32(bit) }
                }
                let scalar = UnicodeScalar(braillBase + pattern)!
                line.append(Character(scalar))
                if fullmap {
                    let cx = Int(regionOrigin.x + (Double(c) + 0.5) * cellW)
                    let cy = Int(regionOrigin.y + (Double(r) + 0.5) * cellH)
                    cells.append(AsciiCellTag(
                        col: c, row: r, x: cx, y: cy,
                        char: String(Character(scalar)),
                        color: nil
                    ))
                }
            }
            lines.append(line)
        }

        let legend = ["⠀": "blank (8 pixels light)", "⣿": "all-ink (8 pixels dark)"]
        return (lines, legend, fullmap ? cells : nil)
    }

    // MARK: - Brightness mode

    /// 5-level luminance quantization. Levels: " .:-=+*#@" subset.
    private static func encodeBrightness(
        pixels: [UInt8], sampleW: Int, sampleH: Int,
        cols: Int, rows: Int,
        regionOrigin: CGPoint,
        cellW: Double, cellH: Double,
        fullmap: Bool
    ) -> ([String], [String: String], [AsciiCellTag]?) {
        // Light → dark
        let ramp: [Character] = [" ", ".", ":", "-", "=", "+", "*", "#", "@"]
        var lines: [String] = []
        lines.reserveCapacity(rows)
        var cells: [AsciiCellTag] = []

        for r in 0..<rows {
            var line = ""
            line.reserveCapacity(cols)
            for c in 0..<cols {
                let idx = (r * sampleW + c) * 4
                let lum = luminance(
                    r: pixels[idx + 0],
                    g: pixels[idx + 1],
                    b: pixels[idx + 2]
                )
                // Higher luminance = lighter character
                let level = max(0, min(ramp.count - 1, Int(round((1.0 - lum) * Double(ramp.count - 1)))))
                let ch = ramp[level]
                line.append(ch)
                if fullmap {
                    let cx = Int(regionOrigin.x + (Double(c) + 0.5) * cellW)
                    let cy = Int(regionOrigin.y + (Double(r) + 0.5) * cellH)
                    cells.append(AsciiCellTag(
                        col: c, row: r, x: cx, y: cy,
                        char: String(ch),
                        color: nil
                    ))
                }
            }
            lines.append(line)
        }

        let legend: [String: String] = [
            " ": "white",
            ".": "very light",
            ":": "light",
            "-": "light-mid",
            "=": "mid",
            "+": "mid-dark",
            "*": "dark",
            "#": "very dark",
            "@": "black"
        ]
        return (lines, legend, fullmap ? cells : nil)
    }

    // MARK: - Palette + helpers

    private struct PaletteEntry {
        let letter: Character
        let r: Double
        let g: Double
        let b: Double
        let name: String
        let hex: String
    }

    /// The Gloss palette plus generic colors for natural images.
    /// Letters are uppercase A-Z plus '.' for white and '#' for solid dark.
    private static let palette: [PaletteEntry] = [
        // Light / empty
        PaletteEntry(letter: ".", r: 1.00, g: 1.00, b: 1.00, name: "white", hex: "#FFFFFF"),
        PaletteEntry(letter: "*", r: 0.94, g: 0.92, b: 0.96, name: "pearl", hex: "#F0EBF5"),
        // Gloss palette
        PaletteEntry(letter: "A", r: 0.50, g: 1.00, b: 0.83, name: "aqua",      hex: "#7FFFD4"),
        PaletteEntry(letter: "G", r: 1.00, g: 0.62, b: 0.88, name: "glow",      hex: "#FF9EE0"),
        PaletteEntry(letter: "L", r: 0.78, g: 0.72, b: 0.94, name: "lavender",  hex: "#C8B8F0"),
        PaletteEntry(letter: "P", r: 1.00, g: 0.42, b: 0.62, name: "hotpink",   hex: "#FF6B9D"),
        PaletteEntry(letter: "C", r: 0.38, g: 0.85, b: 0.96, name: "cyan",      hex: "#62D8F5"),
        PaletteEntry(letter: "E", r: 0.50, g: 0.82, b: 0.94, name: "deepsky",   hex: "#80D2F0"),
        PaletteEntry(letter: "D", r: 0.69, g: 0.93, b: 0.93, name: "powder",    hex: "#B0EDED"),
        PaletteEntry(letter: "Q", r: 0.80, g: 0.93, b: 0.93, name: "turquoise", hex: "#CCEDED"),
        // Generic primaries
        PaletteEntry(letter: "R", r: 1.00, g: 0.20, b: 0.20, name: "red",     hex: "#FF3333"),
        PaletteEntry(letter: "O", r: 1.00, g: 0.55, b: 0.10, name: "orange",  hex: "#FF8C1A"),
        PaletteEntry(letter: "Y", r: 1.00, g: 0.95, b: 0.20, name: "yellow",  hex: "#FFF233"),
        PaletteEntry(letter: "M", r: 0.30, g: 0.85, b: 0.30, name: "green",   hex: "#4DD94D"),
        PaletteEntry(letter: "T", r: 0.10, g: 0.55, b: 0.30, name: "forest",  hex: "#1A8C4D"),
        PaletteEntry(letter: "B", r: 0.20, g: 0.40, b: 0.95, name: "blue",    hex: "#3366F2"),
        PaletteEntry(letter: "N", r: 0.10, g: 0.18, b: 0.45, name: "navy",    hex: "#1A2E73"),
        PaletteEntry(letter: "V", r: 0.55, g: 0.20, b: 0.85, name: "violet",  hex: "#8C33D9"),
        PaletteEntry(letter: "X", r: 0.45, g: 0.25, b: 0.10, name: "brown",   hex: "#73401A"),
        PaletteEntry(letter: "W", r: 0.85, g: 0.85, b: 0.85, name: "lightgray", hex: "#D9D9D9"),
        PaletteEntry(letter: "K", r: 0.50, g: 0.50, b: 0.50, name: "gray",      hex: "#808080"),
        PaletteEntry(letter: "Z", r: 0.20, g: 0.20, b: 0.20, name: "darkgray",  hex: "#333333"),
        PaletteEntry(letter: "#", r: 0.00, g: 0.00, b: 0.00, name: "black",     hex: "#000000")
    ]

    private static let paletteLegend: [String: String] = {
        var dict: [String: String] = [:]
        for p in palette {
            dict[String(p.letter)] = "\(p.name) \(p.hex)"
        }
        return dict
    }()

    private static func nearestPaletteEntry(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> (letter: Character, hex: String) {
        // Treat near-transparent as white
        if a < 32 { return (".", "#FFFFFF") }
        let nr = Double(r) / 255
        let ng = Double(g) / 255
        let nb = Double(b) / 255
        var best = palette[0]
        var bestDist = Double.greatestFiniteMagnitude
        for p in palette {
            let dr = nr - p.r
            let dg = ng - p.g
            let db = nb - p.b
            let d = dr*dr + dg*dg + db*db
            if d < bestDist {
                bestDist = d
                best = p
            }
        }
        return (best.letter, best.hex)
    }

    private static func luminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
        // sRGB Rec. 709 coefficients; rough since channels are gamma-encoded
        // but adequate for visual encoding.
        let nr = Double(r) / 255
        let ng = Double(g) / 255
        let nb = Double(b) / 255
        return 0.2126 * nr + 0.7152 * ng + 0.0722 * nb
    }
}
