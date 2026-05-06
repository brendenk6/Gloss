import SwiftUI
import AppKit

struct LayerPanel: View {
    @Bindable var store: CanvasStore
    @State private var hoveredID: String? = nil
    @State private var renamingID: String? = nil
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider().background(.white.opacity(0.06))
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(orderedLayers, id: \.id) { layer in
                        layerRow(layer)
                            .onHover { hovering in
                                hoveredID = hovering ? layer.id : nil
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            Divider().background(.white.opacity(0.06))
            memoryFooter
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(
            ZStack {
                Color.black.opacity(0.45)
                LinearGradient(
                    colors: [GlossPalette.lavender.opacity(0.10),
                             GlossPalette.aqua.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .overlay(
            Rectangle().frame(width: 1).foregroundStyle(.white.opacity(0.06)),
            alignment: .leading
        )
    }

    // MARK: - Layout

    private var orderedLayers: [GlossLayer] {
        // Display top → bottom (top of stack first), which matches user mental model.
        Array(store.layerState.layers.reversed())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Layers")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
            Spacer()
            Button(action: addLayer) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(true), in: .circle)
            .help("New layer")
        }
    }

    private var memoryFooter: some View {
        let s = store.layerState
        let used = Double(s.memoryUsageBytes) / 1_048_576
        let cap = Double(s.memoryCapBytes) / 1_048_576
        return HStack(spacing: 6) {
            Image(systemName: "memorychip")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
            Text(String(format: "%.0f / %.0f MB", used, cap))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text("\(s.layers.count)/\(s.maxLayers) layers")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func layerRow(_ layer: GlossLayer) -> some View {
        let isActive = (layer.id == store.layerState.activeLayerID)
        let tint = authorTint(layer.author)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    setVisible(layer, !layer.visible)
                } label: {
                    Image(systemName: layer.visible ? "eye" : "eye.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(layer.visible ? Color.white : Color.white.opacity(0.35))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layer.visible ? "Hide" : "Show")

                Group {
                    if renamingID == layer.id {
                        TextField("name", text: $renameDraft, onCommit: {
                            commitRename(layer)
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .onSubmit { commitRename(layer) }
                    } else {
                        Text(layer.name)
                            .font(.system(size: 11, weight: isActive ? .semibold : .regular,
                                          design: .rounded))
                            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.78))
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                renamingID = layer.id
                                renameDraft = layer.name
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    setLocked(layer, !layer.locked)
                } label: {
                    Image(systemName: layer.locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(layer.locked ? Color.white.opacity(0.92) : Color.white.opacity(0.35))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layer.locked ? "Unlock" : "Lock")

                Button {
                    setActive(layer)
                } label: {
                    Circle()
                        .fill(isActive ? tint : Color.white.opacity(0.10))
                        .overlay(Circle().strokeBorder(.white.opacity(isActive ? 0.6 : 0.18), lineWidth: 1))
                        .frame(width: 12, height: 12)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isActive ? "Active layer" : "Activate this layer")
            }

            HStack(spacing: 8) {
                Slider(value: opacityBinding(for: layer), in: 0...1)
                    .controlSize(.mini)
                    .tint(tint)
                Text(String(format: "%.0f%%", layer.opacity * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 32, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Picker("", selection: blendBinding(for: layer)) {
                    ForEach(blendOptions, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.mini)
                .labelsHidden()

                Spacer()

                if hoveredID == layer.id, store.layerState.layers.count > 1, layer.id != "base" {
                    Button {
                        deleteLayer(layer)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete layer")
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive
                      ? tint.opacity(0.12)
                      : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? tint.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .contextMenu {
            Button("Move up") {
                if let idx = store.layerState.layers.firstIndex(where: { $0.id == layer.id }) {
                    moveLayer(layer, to: min(store.layerState.layers.count - 1, idx + 1))
                }
            }
            Button("Move down") {
                if let idx = store.layerState.layers.firstIndex(where: { $0.id == layer.id }) {
                    moveLayer(layer, to: max(0, idx - 1))
                }
            }
            Divider()
            Button("Activate") { setActive(layer) }
            Button(layer.visible ? "Hide" : "Show") { setVisible(layer, !layer.visible) }
            Button(layer.locked ? "Unlock" : "Lock") { setLocked(layer, !layer.locked) }
            if store.layerState.layers.count > 1, layer.id != "base" {
                Divider()
                Button("Delete", role: .destructive) { deleteLayer(layer) }
            }
        }
    }

    private var blendOptions: [GlossBlend] {
        [.normal, .multiply, .screen, .overlay, .darken, .lighten]
    }

    // MARK: - Bindings & helpers

    private func opacityBinding(for layer: GlossLayer) -> Binding<Double> {
        Binding(
            get: { layer.opacity },
            set: { newValue in
                try? store.apply(.layerOpacity(LayerOpacityPayload(
                    author: "brenden", id: layer.id, opacity: newValue
                )))
            }
        )
    }

    private func blendBinding(for layer: GlossLayer) -> Binding<GlossBlend> {
        Binding(
            get: { layer.blend },
            set: { newValue in
                try? store.apply(.layerBlend(LayerBlendPayload(
                    author: "brenden", id: layer.id, blend: newValue
                )))
            }
        )
    }

    private func setVisible(_ layer: GlossLayer, _ visible: Bool) {
        try? store.apply(.layerVisibility(LayerVisibilityPayload(
            author: "brenden", id: layer.id, visible: visible
        )))
    }

    private func setLocked(_ layer: GlossLayer, _ locked: Bool) {
        try? store.apply(.layerLock(LayerLockPayload(
            author: "brenden", id: layer.id, locked: locked
        )))
    }

    private func setActive(_ layer: GlossLayer) {
        try? store.apply(.layerActivate(LayerActivatePayload(
            author: "brenden", id: layer.id
        )))
    }

    private func moveLayer(_ layer: GlossLayer, to index: Int) {
        try? store.apply(.layerReorder(LayerReorderPayload(
            author: "brenden", id: layer.id, toIndex: index
        )))
    }

    private func deleteLayer(_ layer: GlossLayer) {
        try? store.apply(.layerDelete(LayerDeletePayload(
            author: "brenden", id: layer.id
        )))
    }

    private func addLayer() {
        let count = store.layerState.layers.count
        let payload = LayerCreatePayload(
            author: "brenden",
            name: "Layer \(count)",
            setActive: true
        )
        try? store.apply(.layerCreate(payload))
    }

    private func commitRename(_ layer: GlossLayer) {
        // No dedicated rename command yet; rely on a layerActivate to refresh
        // and just show the field exit. (v1.3 can add /layer/rename.)
        renamingID = nil
        renameDraft = ""
    }

    private func authorTint(_ author: String?) -> Color {
        switch (author ?? "").lowercased() {
        case "claude":  return GlossPalette.aqua
        case "codex":   return GlossPalette.glow
        case "brenden": return GlossPalette.lavender
        default:        return GlossPalette.pearl
        }
    }
}
