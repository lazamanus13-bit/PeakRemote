import SwiftUI
import Charts

/// Explains Studio mode before unlocking it.
struct JailbreakSheet: View {
    let onUnlock: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Studio mode")
                        .font(.title.bold())
                    Text("Studio adds heat curves: instead of one fixed temperature, the app moves your Peak's target along a curve during the session, like starting hot and tapering off.")
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Curves run on profile 4, which is backed up and restored afterwards.", systemImage: "arrow.uturn.backward")
                        Label("Targets stay between 350°F and 590°F.", systemImage: "thermometer.medium")
                        Label("Heating stops right away if the chamber reaches 600°F.", systemImage: "exclamationmark.octagon")
                        Label("Keep the app open and nearby while a curve runs.", systemImage: "iphone.radiowaves.left.and.right")
                    }
                    .font(.subheadline)
                    Text("This isn't something Puffco makes or supports, and it's based on community reverse-engineering. Use it at your own risk and never leave your Peak heating unattended.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Built on puff-studio by SoyMilkIsOk (MIT).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        onUnlock()
                        dismiss()
                    } label: {
                        Text("Unlock Studio")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// The Studio card on the device screen: curve list plus the live run panel.
struct StudioCard: View {
    @ObservedObject var runner: CurveRunner
    let ready: Bool
    let liveTempC: Double?
    let celsius: Bool
    let onLock: () -> Void

    @State private var custom: [HeatCurve] = CurveStore.load()
    @State private var editing: HeatCurve?

    var body: some View {
        Card("Studio · Heat curves") {
            if runner.isBusy || isFinished {
                runPanel
            }
            ForEach(HeatCurve.presets + custom) { curve in
                curveRow(curve)
            }
            HStack {
                Button {
                    editing = HeatCurve(name: "My curve", points: [CurvePoint(time: 0, tempF: 500), CurvePoint(time: 45, tempF: 470)])
                } label: {
                    Label("New curve", systemImage: "plus")
                }
                Spacer()
                Button("Lock Studio", role: .destructive, action: onLock)
                    .font(.caption)
                    .disabled(runner.isBusy)
            }
        }
        .sheet(item: $editing) { curve in
            CurveEditorView(curve: curve, celsius: celsius, onSave: save, onDelete: delete)
        }
    }

    private var isFinished: Bool {
        if case .finished = runner.phase { return true }
        return false
    }

    private var phaseText: String {
        switch runner.phase {
        case .idle: return ""
        case .preparing: return "Getting ready…"
        case .preheating: return "Preheating"
        case .running: return "Running"
        case .finished(let message): return message
        }
    }

    @ViewBuilder
    private var runPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(runner.curve?.name ?? "Curve").font(.headline)
                Spacer()
                Text(phaseText).font(.subheadline).foregroundStyle(runner.isBusy ? .orange : .secondary)
            }
            if let curve = runner.curve {
                CurveChart(curve: curve, elapsed: runner.phase == .running ? runner.elapsed : nil, celsius: celsius)
                    .frame(height: 120)
                ProgressView(value: runner.elapsed, total: curve.duration)
            }
            HStack {
                InfoRow(label: "Target", value: runner.targetF.map { Temp.format(Temp.c(fromF: $0), celsius: celsius) } ?? "—")
                InfoRow(label: "Chamber", value: Temp.format(liveTempC, celsius: celsius))
            }
            if !runner.driveNote.isEmpty {
                Text(runner.driveNote).font(.caption).foregroundStyle(.secondary)
            }
            if runner.isBusy {
                BigButton(title: "Stop curve", icon: "stop.fill", tint: .red) { runner.stop() }
            } else {
                Button("Dismiss") { runner.reset() }.font(.caption)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private func curveRow(_ curve: HeatCurve) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(curve.name).font(.subheadline.weight(.semibold))
                Text("\(Int(curve.duration))s · starts \(Temp.format(Temp.c(fromF: curve.startTempF), celsius: celsius))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !curve.isPreset {
                Button { editing = curve } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
            }
            Button("Run") { runner.start(curve) }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!ready || runner.isBusy)
        }
    }

    private func save(_ curve: HeatCurve) {
        if let i = custom.firstIndex(where: { $0.id == curve.id }) {
            custom[i] = curve
        } else {
            custom.append(curve)
        }
        CurveStore.save(custom)
    }

    private func delete(_ curve: HeatCurve) {
        custom.removeAll { $0.id == curve.id }
        CurveStore.save(custom)
    }
}

/// A small line chart of a curve, with an optional "now" marker.
struct CurveChart: View {
    let curve: HeatCurve
    let elapsed: Double?
    let celsius: Bool

    private func display(_ f: Double) -> Double { celsius ? Temp.c(fromF: f) : f }

    var body: some View {
        Chart {
            ForEach(curve.points.sorted { $0.time < $1.time }) { p in
                LineMark(x: .value("Time", p.time), y: .value("Temp", display(p.tempF)))
                    .foregroundStyle(.orange)
                PointMark(x: .value("Time", p.time), y: .value("Temp", display(p.tempF)))
                    .foregroundStyle(.orange)
            }
            if let elapsed {
                RuleMark(x: .value("Now", elapsed))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .chartYScale(domain: display(HeatCurve.tempRangeF.lowerBound - 10)...display(HeatCurve.tempRangeF.upperBound + 10))
        .chartXScale(domain: 0...curve.duration)
    }
}

/// Edits a custom curve's name and points.
struct CurveEditorView: View {
    @State var curve: HeatCurve
    let celsius: Bool
    let onSave: (HeatCurve) -> Void
    let onDelete: (HeatCurve) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Name", text: $curve.name)
                    CurveChart(curve: curve.sanitized(), elapsed: nil, celsius: celsius)
                        .frame(height: 160)
                }
                Section {
                    ForEach($curve.points) { $point in
                        pointRow($point)
                    }
                    .onDelete { offsets in
                        if curve.points.count - offsets.count >= 2 { curve.points.remove(atOffsets: offsets) }
                    }
                    Button {
                        let last = curve.points.max { $0.time < $1.time }
                        let time = min((last?.time ?? 0) + 10, HeatCurve.timeRange.upperBound)
                        curve.points.append(CurvePoint(time: time, tempF: last?.tempF ?? 480))
                    } label: {
                        Label("Add point", systemImage: "plus")
                    }
                    .disabled((curve.points.map(\.time).max() ?? 0) >= HeatCurve.timeRange.upperBound)
                } header: {
                    Text("Points")
                } footer: {
                    Text("Temperatures 400–580°F, up to 120 seconds. Swipe a point to delete it.")
                }
                if CurveStore.load().contains(where: { $0.id == curve.id }) {
                    Section {
                        Button("Delete curve", role: .destructive) {
                            onDelete(curve)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(curve.name.isEmpty ? "Curve" : curve.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(curve.sanitized())
                        dismiss()
                    }
                    .disabled(curve.points.count < 2)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func pointRow(_ point: Binding<CurvePoint>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Stepper("At \(Int(point.wrappedValue.time))s", value: point.time, in: HeatCurve.timeRange, step: 1)
            Stepper(Temp.format(Temp.c(fromF: point.wrappedValue.tempF), celsius: celsius),
                    value: point.tempF, in: HeatCurve.tempRangeF, step: 5)
        }
    }
}
