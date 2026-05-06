import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Palette

enum GlossPalette {
    static let pearl     = Color(red: 0.96, green: 0.94, blue: 0.98)
    static let lavender  = Color(red: 0.78, green: 0.70, blue: 0.92)
    static let aqua      = Color(red: 0.62, green: 0.92, blue: 0.92)
    static let glow      = Color(red: 0.98, green: 0.78, blue: 0.92)
    static let ink       = Color(red: 0.10, green: 0.08, blue: 0.16)
    static let chrome    = Color(red: 0.08, green: 0.08, blue: 0.12)
}

struct ContentView: View {
    @Bindable var store: CanvasStore
    @State private var hoverPoint: CGPoint? = nil
    @State private var sampleColor: RGBA? = nil
    @State private var screenHover: CGPoint? = nil

    var body: some View {
        VStack(spacing: 0) {
            chromeHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(GlossPalette.chrome)
            Divider().background(Color.white.opacity(0.06))

            ZStack {
                LinearGradient(
                    colors: [GlossPalette.lavender.opacity(0.25),
                             GlossPalette.aqua.opacity(0.25),
                             GlossPalette.glow.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ZStack {
                    CanvasView(store: store)
                        .aspectRatio(CGFloat(store.width) / CGFloat(store.height), contentMode: .fit)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                        .padding(28)
                        .overlay(authorCursorLayer)
                        .overlay(brushPreviewLayer)
                        .background(
                            GeometryReader { geo in
                                Color.clear.onContinuousHover { phase in
                                    switch phase {
                                    case .active(let p):
                                        let canvasFrame = canvasFrameInside(geo.size)
                                        if canvasFrame.contains(p) {
                                            screenHover = p
                                            hoverPoint = canvasCoord(from: p, frame: canvasFrame)
                                            if let pt = hoverPoint {
                                                sampleColor = store.sample(at: pt)
                                            }
                                        } else {
                                            screenHover = nil
                                            hoverPoint = nil
                                            sampleColor = nil
                                        }
                                    case .ended:
                                        screenHover = nil
                                        hoverPoint = nil
                                        sampleColor = nil
                                    }
                                }
                            }
                        )
                }
            }
        }
        .background(GlossPalette.chrome)
        .background(keyboardShortcutLayer)
    }

    // MARK: - Chrome (Liquid Glass)

    private var chromeHeader: some View {
        HStack(spacing: 12) {
            Text("Gloss")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
            Text("\(store.width) × \(store.height)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))

            Spacer()

            // Tool buttons (Liquid Glass) — Save / Clear / Undo / Redo
            HStack(spacing: 8) {
                glassChromeButton(icon: "arrow.uturn.backward", tooltip: "Undo (\u{2318}Z)") {
                    runHistory(.undo)
                }
                glassChromeButton(icon: "arrow.uturn.forward", tooltip: "Redo (\u{21E7}\u{2318}Z)") {
                    runHistory(.redo)
                }
                glassChromeButton(icon: "trash", tooltip: "Clear canvas") {
                    runClear()
                }
                glassChromeButton(icon: "square.and.arrow.down", tooltip: "Save PNG (\u{2318}S)") {
                    saveAsPNG()
                }
            }

            // Last command + revision chips
            HStack(spacing: 10) {
                if let last = store.lastCommands.first {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(authorTint(last.author).opacity(0.95))
                            .frame(width: 8, height: 8)
                        Text("\(last.author ?? "anon") · \(last.kind)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular.tint(authorTint(last.author).opacity(0.18)), in: .capsule)
                }

                Text("rev \(store.revision)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)

                if let pt = hoverPoint {
                    Text(String(format: "(%.0f, %.0f)", pt.x, pt.y))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                }
                if let s = sampleColor {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: Double(s.r)/255, green: Double(s.g)/255, blue: Double(s.b)/255))
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
                        Text(String(format: "%02X%02X%02X", s.r, s.g, s.b))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                }
            }
        }
    }

    private func glassChromeButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(true), in: .circle)
        .help(tooltip)
    }

    // MARK: - Cursor / brush preview

    private var brushPreviewLayer: some View {
        Group {
            if let pt = screenHover {
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .frame(width: 14, height: 14)
                    .shadow(color: GlossPalette.aqua.opacity(0.4), radius: 4)
                    .position(pt)
                    .allowsHitTesting(false)
            }
        }
    }

    private var authorCursorLayer: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(Array(store.authorCursors.keys), id: \.self) { author in
                    if let pt = store.authorCursors[author] {
                        let frame = canvasFrameInside(geo.size)
                        let screen = CGPoint(
                            x: frame.minX + pt.x * frame.width / CGFloat(store.width),
                            y: frame.minY + pt.y * frame.height / CGFloat(store.height)
                        )
                        AuthorCursor(author: author, tint: authorTint(author))
                            .position(screen)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Keyboard shortcuts (hidden buttons that capture combos)

    private var keyboardShortcutLayer: some View {
        ZStack {
            Button("Save", action: saveAsPNG).keyboardShortcut("s", modifiers: .command).hidden()
            Button("Undo", action: { runHistory(.undo) }).keyboardShortcut("z", modifiers: .command).hidden()
            Button("Redo", action: { runHistory(.redo) }).keyboardShortcut("z", modifiers: [.command, .shift]).hidden()
            Button("Clear", action: runClear).keyboardShortcut("k", modifiers: [.command, .shift]).hidden()
        }
    }

    // MARK: - Actions

    private enum HistoryDirection { case undo, redo }

    private func runHistory(_ dir: HistoryDirection) {
        let cmd: DrawCommand = (dir == .undo)
            ? .undo(MetaPayload(author: "brenden"))
            : .redo(MetaPayload(author: "brenden"))
        try? store.apply(cmd)
    }

    private func runClear() {
        try? store.apply(.clear(ClearPayload(author: "brenden")))
    }

    private func saveAsPNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "gloss-rev\(store.revision).png"
        panel.canCreateDirectories = true
        panel.title = "Save Gloss canvas"
        if panel.runModal() == .OK, let url = panel.url {
            let img = store.snapshot(maxDim: nil)
            if let data = PNGExporter.data(from: img) {
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    NSLog("Gloss: failed to write PNG — %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Coordinate helpers

    private func canvasFrameInside(_ size: CGSize) -> CGRect {
        let pad: CGFloat = 28
        let inner = CGSize(width: size.width - pad * 2, height: size.height - pad * 2)
        guard inner.width > 0, inner.height > 0 else { return .zero }
        let aspect = CGFloat(store.width) / CGFloat(store.height)
        let innerAspect = inner.width / inner.height
        let rect: CGRect
        if innerAspect > aspect {
            let h = inner.height
            let w = h * aspect
            let x = pad + (inner.width - w) / 2
            rect = CGRect(x: x, y: pad, width: w, height: h)
        } else {
            let w = inner.width
            let h = w / aspect
            let y = pad + (inner.height - h) / 2
            rect = CGRect(x: pad, y: y, width: w, height: h)
        }
        return rect
    }

    private func canvasCoord(from screen: CGPoint, frame: CGRect) -> CGPoint {
        let nx = (screen.x - frame.minX) / frame.width
        let ny = (screen.y - frame.minY) / frame.height
        return CGPoint(x: nx * CGFloat(store.width), y: ny * CGFloat(store.height))
    }

    private func authorTint(_ author: String?) -> Color {
        switch (author ?? "").lowercased() {
        case "claude":  return GlossPalette.aqua
        case "codex":   return GlossPalette.glow
        case "brenden": return GlossPalette.lavender
        default:        return Color.gray
        }
    }
}

private struct AuthorCursor: View {
    let author: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                .shadow(color: tint.opacity(0.6), radius: 4)
            Text(author)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(tint.opacity(0.85))
                )
                .foregroundStyle(.black.opacity(0.75))
        }
        .offset(x: 6, y: -4)
    }
}
