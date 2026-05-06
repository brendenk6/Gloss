import SwiftUI
import Foundation

/// Popover content for adjusting grid visibility, snap mode, opacity, and cell size.
/// Every control change dispatches a `.gridConfig` command through the CanvasStore so
/// the change goes through the same idempotent command pipeline as everything else —
/// undo/redo and HTTP API stay consistent.
struct GridControls: View {
    @Bindable var store: CanvasStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Grid")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            Toggle(isOn: Binding(
                get: { store.grid.visible },
                set: { dispatch(visible: $0) }
            )) {
                Text("Show grid")
                    .font(.system(size: 12))
            }

            Toggle(isOn: Binding(
                get: { store.grid.snap },
                set: { dispatch(snap: $0) }
            )) {
                Text("Snap strokes to cells")
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Opacity")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(store.grid.opacity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { store.grid.opacity },
                    set: { dispatch(opacity: $0) }
                ), in: 0.05...1.0)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Cell size")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(store.grid.cellW) px")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach([4, 8, 16, 24, 32, 48], id: \.self) { size in
                        Button {
                            dispatch(cellSize: size)
                        } label: {
                            Text("\(size)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .frame(minWidth: 24)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(store.grid.cellW == size
                                              ? Color.accentColor.opacity(0.4)
                                              : Color.gray.opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                let cols = store.grid.columns(canvasWidth: store.width)
                let rows = store.grid.rows(canvasHeight: store.height)
                Text("\(cols) × \(rows) cells")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func dispatch(visible: Bool? = nil,
                         snap: Bool? = nil,
                         opacity: Double? = nil,
                         cellSize: Int? = nil) {
        let payload = GridConfigPayload(
            author: "brenden",
            idempotencyKey: "grid-control-\(UUID().uuidString)",
            cellW: cellSize,
            cellH: cellSize,
            originX: nil,
            originY: nil,
            visible: visible,
            opacity: opacity,
            snap: snap
        )
        try? store.apply(.gridConfig(payload))
    }
}
