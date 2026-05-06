import SwiftUI
import Foundation

/// Popover content for selecting a canvas preset (TV, iPhone, iPad, Studio).
/// Picking a preset dispatches a `.canvasNew` command — same path as the HTTP
/// /canvas/new route — so the canvas resizes and the layer stack resets to a
/// fresh background. Existing artwork is lost; the user is expected to save first.
///
/// Presets are grouped semantically so the picker doesn't read as one giant list.
/// Each group is a section of buttons. The currently-active preset (if the canvas
/// dims match exactly) is highlighted.
struct PresetPicker: View {
    @Bindable var store: CanvasStore
    var onPick: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("New canvas")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                section(title: "Animation broadcast", presets: animation)
                section(title: "iPhone (landscape)", presets: iphone)
                section(title: "iPad (landscape)", presets: ipad)
                section(title: "Studio", presets: studio)

                Divider()
                Text("Picking a preset starts a fresh canvas. Save first if you want to keep the current artwork.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .frame(width: 320, height: 460)
    }

    @ViewBuilder
    private func section(title: String, presets: [CanvasPreset]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(presets, id: \.name) { preset in
                    presetRow(preset)
                }
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: CanvasPreset) -> some View {
        Button {
            apply(preset)
            onPick()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(preset.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(preset.width)×\(preset.height)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent(preset)
                          ? Color.accentColor.opacity(0.25)
                          : Color.gray.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preset groups

    private var animation: [CanvasPreset] {
        ["tv_hd", "tv_fhd", "tv_uhd", "tv_dci", "tv_ntsc"]
            .compactMap { GlossCanvasPresets.resolve($0) }
    }

    private var iphone: [CanvasPreset] {
        ["iphone_se", "iphone_16", "iphone_16_plus", "iphone_16_pro", "iphone_16_pro_max"]
            .compactMap { GlossCanvasPresets.resolve($0) }
    }

    private var ipad: [CanvasPreset] {
        ["ipad_mini", "ipad_pro_11", "ipad_air_13", "ipad_pro_13"]
            .compactMap { GlossCanvasPresets.resolve($0) }
    }

    private var studio: [CanvasPreset] {
        ["square_1k", "square_2k", "study_default"]
            .compactMap { GlossCanvasPresets.resolve($0) }
    }

    private func isCurrent(_ preset: CanvasPreset) -> Bool {
        store.width == preset.width && store.height == preset.height
    }

    private func apply(_ preset: CanvasPreset) {
        let payload = CanvasNewPayload(
            author: "brenden",
            idempotencyKey: "preset-\(preset.name)-\(UUID().uuidString)",
            preset: preset.name,
            width: preset.width,
            height: preset.height,
            background: nil,
            grid: preset.grid,
            preserveLayers: false
        )
        try? store.apply(.canvasNew(payload))
    }
}
