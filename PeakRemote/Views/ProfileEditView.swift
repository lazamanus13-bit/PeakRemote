import SwiftUI
import UIKit

struct ProfileEditView: View {
    let profile: HeatProfile
    let celsius: Bool
    let onSave: (_ tempC: Double, _ seconds: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tempF: Double
    @State private var seconds: Double

    static let tempRangeF: ClosedRange<Double> = 400...620
    static let durationRange: ClosedRange<Double> = 15...120

    init(profile: HeatProfile, celsius: Bool, onSave: @escaping (_ tempC: Double, _ seconds: Double) -> Void) {
        self.profile = profile
        self.celsius = celsius
        self.onSave = onSave
        let f = profile.tempC.map { Temp.f(fromC: $0) } ?? 500
        _tempF = State(initialValue: min(max(f.rounded(), Self.tempRangeF.lowerBound), Self.tempRangeF.upperBound))
        let s = profile.durationS ?? 45
        _seconds = State(initialValue: min(max(s.rounded(), Self.durationRange.lowerBound), Self.durationRange.upperBound))
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Temperature") {
                    Text(Temp.format(Temp.c(fromF: tempF), celsius: celsius))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                    Slider(value: $tempF, in: Self.tempRangeF, step: 5)
                }
                Section("Duration") {
                    Stepper("\(Int(seconds)) seconds", value: $seconds, in: Self.durationRange, step: 5)
                }
                Section {
                    Text("This writes to your Peak. Profile editing is the least-tested part of the app, so check the new values on the device after saving.")
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
                        onSave(Temp.c(fromF: tempF), seconds)
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
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
                Button("Clear") { c.clearLog() }
            }
        }
    }
}
