import SwiftUI
import AppKit

/// Layer-backed NSView that displays the current CanvasStore image. Cheap on
/// every refresh because we just swap `layer.contents`.
struct CanvasView: NSViewRepresentable {
    @Bindable var store: CanvasStore

    func makeNSView(context: Context) -> NSView {
        let v = LayerView()
        v.wantsLayer = true
        v.layer?.contentsGravity = .resize
        v.layer?.magnificationFilter = .linear
        v.layer?.minificationFilter = .linear
        v.layer?.backgroundColor = CGColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Touching `revision` here makes SwiftUI re-invoke updateNSView whenever
        // the store mutates; pulling `currentImage` recomputes on demand.
        _ = store.revision
        nsView.layer?.contents = store.currentImage
    }
}

private final class LayerView: NSView {
    override var isFlipped: Bool { true }
}
