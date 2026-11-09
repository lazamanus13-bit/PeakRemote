import SwiftUI
import UIKit

struct ProfileEditView: View {
    let profile: HeatProfile
    let celsius: Bool
    /// XL vapor is only offered with an XL chamber (the official app restricts it too).
    let allowXL: Bool
    /// Firmware light effects only work with the 8-byte color format.
    let showEffects: Bool
    let onSave: (ProfileEdit) -> Void
    /// Shows the look on the Peak while choosing; nil ends the preview.
    let onPreview: (PreviewLook?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tempF: Double
    @State private var seconds: Double
    @State private var boostF: Double
    @State private var boostSeconds: Double
    @State private var color: Color
    @State private var colorChanged = false
    @State private var effect: LightEffect
    @State private var effectChanged = false
    @State private var vapor: VaporLevel?
    @State private var multiColor: Bool
    @State private var multi = MultiColorLook.default
    @State private var multiChanged = false

    // Limits from the official app.
    static let tempRangeF: ClosedRange<Double> = 400...644
    static let durationRange: ClosedRange<Double> = 15...120
    static let boostRangeF: ClosedRange<Double> = 1...36
    static let boostTimeRange: ClosedRange<Double> = 1...60

    init(profile: HeatProfile, celsius: Bool, allowXL: Bool,
         showEffects: Bool,
         onSave: @escaping (ProfileEdit) -> Void,
         onPreview: @escaping (PreviewLook?) -> Void) {
        self.showEffects = showEffects
        _multiColor = State(initialValue: showEffects && profile.isMultiColor)
        if profile.multiColors.count >= 2 {
            // Start from the colors already on the Peak.
            _multi = State(initialValue: MultiColorLook(colors: profile.multiColors))
        }
        _effect = State(initialValue: profile.lightEffect ?? .steady)
        self.profile = profile
        self.celsius = celsius
        self.allowXL = allowXL || profile.intensity.map { VaporLevel.nearest($0) == .xl } == true
        _vapor = State(initialValue: profile.intensity.map(VaporLevel.nearest))
        self.onSave = onSave
        self.onPreview = onPreview
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        let f = profile.tempC.map { Temp.f(fromC: $0) } ?? 500
        _tempF = State(initialValue: clamp(f.rounded(), Self.tempRangeF))
        _seconds = State(initialValue: clamp((profile.durationS ?? 45).rounded(), Self.durationRange))
        let boostF = (profile.boostTempDeltaC ?? Temp.c(fromF: 42) - Temp.c(fromF: 32)) * 9 / 5
        _boostF = State(initialValue: clamp(boostF.rounded(), Self.boostRangeF))
        _boostSeconds = State(initialValue: clamp((profile.boostTimeS ?? 15).rounded(), Self.boostTimeRange))
        _color = State(initialValue: profile.color?.color ?? .orange)
    }

    private var singlePreview: PreviewLook {
        .singleColor(RGB(color), showEffects ? effect : nil)
    }

    @ViewBuilder
    private var colorSection: some View {
        Section {
            if showEffects {
                Picker("Style", selection: Binding(
                    get: { multiColor },
                    set: { isMulti in
                        multiColor = isMulti
                        onPreview(isMulti ? .multiColor(multi) : singlePreview)
                    }
                )) {
                    Text("Single color").tag(false)
                    Text("Multiple colors").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if multiColor {
                MultiColorEditor(look: $multi) { look in
                    multiChanged = true
                    onPreview(.multiColor(look))
                }
            } else {
                singleColorControls
            }
        } header: {
            Text("Lights")
        } footer: {
            Text(profile.isMultiColor && !multiChanged && multiColor
                 ? "This profile already uses multiple colors. Edit them here to replace them. Your Peak shows it live while you choose."
                 : "Your Peak shows it live while you choose.")
        }
    }

    @ViewBuilder
    private var singleColorControls: some View {
        ColorPicker("Profile color", selection: Binding(
            get: { color },
            set: {
                color = $0
                colorChanged = true
                onPreview(singlePreview)
            }
        ), supportsOpacity: false)
        if showEffects {
            Picker("Effect", selection: Binding(
                get: { effect },
                set: {
                    effect = $0
                    effectChanged = true
                    onPreview(singlePreview)
                }
            )) {
                ForEach(LightEffect.allCases) { e in
                    Text(e.name).tag(e)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var boostLabel: String {
        celsius ? "+\(Int((boostF * 5 / 9).rounded()))°C" : "+\(Int(boostF))°F"
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Temperature") {
                    Text(Temp.format(Temp.c(fromF: tempF), celsius: celsius))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                    Slider(value: $tempF, in: Self.tempRangeF, step: 1)
                    Stepper("Fine-tune", value: $tempF, in: Self.tempRangeF, step: 1)
                }
                Section("Duration") {
                    Stepper("\(Int(seconds)) seconds", value: $seconds, in: Self.durationRange, step: 5)
                }
                Section {
                    Stepper("Temperature \(boostLabel)", value: $boostF, in: Self.boostRangeF, step: 1)
                    Stepper("Time +\(Int(boostSeconds))s", value: $boostSeconds, in: Self.boostTimeRange, step: 1)
                } header: {
                    Text("Boost")
                } footer: {
                    Text("What one press of Boost adds during this profile's session.")
                }
                colorSection
                if vapor != nil {
                    Section {
                        Picker("Vapor", selection: Binding(
                            get: { vapor ?? .standard },
                            set: { vapor = $0 }
                        )) {
                            ForEach(VaporLevel.allCases.filter { $0 != .xl || allowXL }) { level in
                                Text(level.name).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Vapor")
                    } footer: {
                        Text(allowXL ? "Higher levels make denser vapor." : "Higher levels make denser vapor. XL needs a 3DXL chamber.")
                    }
                }
                Section {
                    Text("Saving writes these settings to your Peak.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(profile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(ProfileEdit(
                            tempC: Temp.c(fromF: tempF),
                            durationS: seconds,
                            boostTempDeltaC: boostF * 5 / 9,
                            boostTimeS: boostSeconds,
                            color: !multiColor && (colorChanged || effectChanged || profile.isMultiColor) ? RGB(color) : nil,
                            effect: showEffects && !multiColor && (colorChanged || effectChanged) ? effect : nil,
                            multi: multiColor && (multiChanged || !profile.isMultiColor) ? multi : nil,
                            intensity: vapor?.rawValue
                        ))
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .presentationDetents([.medium, .large])
        .onDisappear { onPreview(nil) }
    }
}

struct LogView: View {
    @EnvironmentObject private var c: PuffcoController
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        List {
            if c.log.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(c.log.enumerated().reversed()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Debug log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = c.log.joined(separator: "\n")
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: c.log.joined(separator: "\n")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button("Clear") { c.clearLog() }
            }
        }
    }
}
