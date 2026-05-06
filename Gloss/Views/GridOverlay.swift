import SwiftUI

/// Draws the cell grid on top of the canvas. Visibility, opacity, cell size, and origin
/// are driven by the CanvasStore's GridSpec. The overlay sizes itself to match the rendered
/// canvas frame (apply via `.overlay(GridOverlay(store: store))` on the CanvasView).
///
/// Lines are drawn in screen space, scaled from canvas-pixel coordinates. We don't try to
/// be clever about visibility — a 100x72 grid at cell=16 is ~172 line draws per frame and
/// SwiftUI Canvas handles that without breaking a sweat. If somebody sets cell=4 they get
/// ~691 lines per frame, still cheap.
///
/// When `grid.snap` is enabled, the visual treatment shifts slightly so the user knows
/// strokes are being coerced to cell boundaries. We use a stronger line color rather than
/// a different color — keeps the chrome consistent.
struct GridOverlay: View {
    @Bindable var store: CanvasStore

    var body: some View {
        if store.grid.visible {
            Canvas { context, size in
                draw(spec: store.grid, into: context, size: size)
            }
            .allowsHitTesting(false)
        }
    }

    private func draw(spec: GridSpec, into context: GraphicsContext, size: CGSize) {
        let canvasW = CGFloat(store.width)
        let canvasH = CGFloat(store.height)
        guard canvasW > 0, canvasH > 0, size.width > 0, size.height > 0 else { return }

        let scaleX = size.width / canvasW
        let scaleY = size.height / canvasH

        // Snap mode strengthens the line so the user can tell coercion is on.
        let baseOpacity = max(0.05, min(1.0, spec.opacity))
        let opacity = spec.snap ? min(1.0, baseOpacity * 1.6) : baseOpacity
        let stroke = GraphicsContext.Shading.color(.white.opacity(opacity))
        let lineWidth: CGFloat = spec.snap ? 0.75 : 0.5

        // Vertical lines: from origin_x stepping by cellW.
        var path = Path()
        var x = CGFloat(spec.originX)
        while x <= canvasW {
            let sx = (x * scaleX).rounded() + 0.5  // half-pixel for crisp 1px line
            path.move(to: CGPoint(x: sx, y: 0))
            path.addLine(to: CGPoint(x: sx, y: size.height))
            x += CGFloat(spec.cellW)
        }
        // Horizontal lines: from origin_y stepping by cellH.
        var y = CGFloat(spec.originY)
        while y <= canvasH {
            let sy = (y * scaleY).rounded() + 0.5
            path.move(to: CGPoint(x: 0, y: sy))
            path.addLine(to: CGPoint(x: size.width, y: sy))
            y += CGFloat(spec.cellH)
        }
        context.stroke(path, with: stroke, lineWidth: lineWidth)
    }
}
