import SwiftUI

/// Edits a multi-color look: 2-6 colors, a pattern, and a speed. Calls `onChange` on every edit
/// so the Peak can preview it live.
struct MultiColorEditor: View {
    @Binding var look: MultiColorLook
    var onChange: (MultiColorLook) -> Void

    var body: some View {
        Group {
            presetRow
            ForEach(look.colors.indices, id: \.self) { index in
                colorRow(index)
            }
            if look.colors.count < MultiColorLook.maxColors {
                Button {
                    var next = look
                    next.colors.append(next.colors.last ?? RGB(r: 255, g: 255, b: 255))
                    update(next)
                } label: {
                    Label("Add color", systemImage: "plus.circle")
                }
            }
            Picker("Pattern", selection: patternBinding) {
                ForEach(LightPattern.allCases) { pattern in
                    Text(pattern.name).tag(pattern)
                }
            }
            .pickerStyle(.segmented)
            Text(look.pattern.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if look.pattern.moves {
                HStack {
                    Image(systemName: "tortoise")
                    Slider(value: speedBinding, in: 0.05...1, onEditingChanged: { editing in
                        if !editing { onChange(look) }
                    })
                    Image(systemName: "hare")
                }
            }
        }
    }

    /// Tap a swatch to load a ready-made look; it stays fully editable afterwards.
    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(MultiColorPreset.all) { preset in
                    Button {
                        update(preset.look)
                    } label: {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(AngularGradient(colors: preset.look.colors.map(\.color) + [preset.look.colors[0].color],
                                                      center: .center))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(look == preset.look ? Color.primary : Color.clear, lineWidth: 2))
                            Text(preset.name)
                                .font(.caption2)
                                .foregroundStyle(look == preset.look ? Color.primary : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.name) preset")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func colorRow(_ index: Int) -> some View {
        HStack {
            ColorPicker("Color \(index + 1)", selection: colorBinding(index), supportsOpacity: false)
            if look.colors.count > 2 {
                Button(role: .destructive) {
                    var next = look
                    next.colors.remove(at: index)
                    update(next)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove color \(index + 1)")
            }
        }
    }

    private func colorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { index < look.colors.count ? look.colors[index].color : .white },
            set: { newColor in
                guard index < look.colors.count else { return }
                var next = look
                next.colors[index] = RGB(newColor)
                update(next)
            }
        )
    }

    private var patternBinding: Binding<LightPattern> {
        Binding(get: { look.pattern }, set: { pattern in
            var next = look
            next.pattern = pattern
            update(next)
        })
    }

    /// Speed only previews when the slider is released, to avoid flooding the Peak.
    private var speedBinding: Binding<Double> {
        Binding(get: { look.speed }, set: { look.speed = $0 })
    }

    private func update(_ next: MultiColorLook) {
        look = next
        onChange(next)
    }
}

/// Sheet for picking the lantern's multiple colors.
struct LanternColorsSheet: View {
    @State var look: MultiColorLook
    let onPreview: (PreviewLook?) -> Void
    let onSave: (MultiColorLook) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    MultiColorEditor(look: $look) { onPreview(.multiColor($0)) }
                } footer: {
                    Text("Your Peak shows it live while you choose.")
                }
            }
            .navigationTitle("Lantern colors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(look)
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .halfSheet()
        .onAppear { onPreview(.multiColor(look)) }
        .onDisappear { onPreview(nil) }
    }
}
