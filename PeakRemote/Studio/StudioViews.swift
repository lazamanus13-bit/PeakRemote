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
    /// Shows a color on the Peak while picking one; nil ends the preview.
    var onPreview: (PreviewLook?) -> Void = { _ in }
    var showEffects = true

    @State private var custom: [HeatCurve] = CurveStore.load()
    @State private var presetEdits: [HeatCurve] = CurveStore.loadPresetEdits()
    @State private var editing: HeatCurve?

    var body: some View {
        Card("Studio · Heat curves") {
            if runner.isBusy || isFinished {
                runPanel
            }
            ForEach(CurveStore.presets(with: presetEdits) + custom) { curve in
                curveRow(curve)
            }
            Text("Long-press a curve to edit it.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            CurveEditorView(curve: curve, celsius: celsius, showEffects: showEffects, removeTitle: removeTitle(for: curve),
                            onSave: save, onDelete: delete, onPreview: onPreview)
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
                HStack(spacing: 6) {
                    if let multi = curve.multi {
                        Circle()
                            .fill(AngularGradient(colors: multi.colors.map(\.color) + [multi.colors[0].color], center: .center))
                            .frame(width: 10, height: 10)
                    } else if let color = curve.color {
                        Circle().fill(color.color).frame(width: 10, height: 10)
                    }
                    Text(curve.name).font(.subheadline.weight(.semibold))
                }
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
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                editing = curve
            } label: {
                Label("Edit curve", systemImage: "slider.horizontal.3")
            }
        }
    }

    /// Presets can be reset once edited; your own curves can be deleted.
    private func removeTitle(for curve: HeatCurve) -> String? {
        if curve.isPreset {
            return presetEdits.contains { $0.id == curve.id } ? "Reset to default" : nil
        }
        return custom.contains { $0.id == curve.id } ? "Delete curve" : nil
    }

    private func save(_ curve: HeatCurve) {
        if curve.isPreset {
            presetEdits.removeAll { $0.id == curve.id }
            presetEdits.append(curve)
            CurveStore.savePresetEdits(presetEdits)
            return
        }
        if let i = custom.firstIndex(where: { $0.id == curve.id }) {
            custom[i] = curve
        } else {
            custom.append(curve)
        }
        CurveStore.save(custom)
    }

    private func delete(_ curve: HeatCurve) {
        if curve.isPreset {
            presetEdits.removeAll { $0.id == curve.id }
            CurveStore.savePresetEdits(presetEdits)
        } else {
            custom.removeAll { $0.id == curve.id }
            CurveStore.save(custom)
        }
    }
}

/// A small line chart of a curve, with an optional "now" marker.
/// Swift Charts on iOS 16; a hand-drawn chart on iOS 15.
struct CurveChart: View {
    let curve: HeatCurve
    let elapsed: Double?
    let celsius: Bool

    var body: some View {
        if #available(iOS 16.0, *) {
            SwiftChartsCurve(curve: curve, elapsed: elapsed, celsius: celsius)
        } else {
            DrawnCurveChart(curve: curve, elapsed: elapsed)
        }
    }
}

/// iOS 15 version of the curve chart, drawn with paths on the same scales.
private struct DrawnCurveChart: View {
    let curve: HeatCurve
    let elapsed: Double?

    private var lineColor: Color { (curve.color ?? curve.multi?.colors.first)?.color ?? .orange }
    private var lowF: Double { HeatCurve.tempRangeF.lowerBound - 10 }
    private var highF: Double { HeatCurve.tempRangeF.upperBound + 10 }

    private func point(_ time: Double, _ tempF: Double, in size: CGSize) -> CGPoint {
        let duration = max(curve.duration, 1)
        let x = CGFloat(min(max(time / duration, 0), 1)) * size.width
        let y = (1 - CGFloat(min(max((tempF - lowF) / (highF - lowF), 0), 1))) * size.height
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { geo in
            let points = curve.points.sorted { $0.time < $1.time }.map { point($0.time, $0.tempF, in: geo.size) }
            ZStack {
                Path { path in
                    for i in 1...3 {
                        let y = geo.size.height * CGFloat(i) / 4
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(lineColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(points.indices, id: \.self) { i in
                    Circle().fill(lineColor).frame(width: 6, height: 6).position(points[i])
                }
                if let elapsed {
                    let x = point(elapsed, lowF, in: geo.size).x
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            }
        }
    }
}

@available(iOS 16.0, *)
private struct SwiftChartsCurve: View {
    let curve: HeatCurve
    let elapsed: Double?
    let celsius: Bool

    private func display(_ f: Double) -> Double { celsius ? Temp.c(fromF: f) : f }
    private var lineColor: Color { (curve.color ?? curve.multi?.colors.first)?.color ?? .orange }

    var body: some View {
        Chart {
            ForEach(curve.points.sorted { $0.time < $1.time }) { p in
                LineMark(x: .value("Time", p.time), y: .value("Temp", display(p.tempF)))
                    .foregroundStyle(lineColor)
                PointMark(x: .value("Time", p.time), y: .value("Temp", display(p.tempF)))
                    .foregroundStyle(lineColor)
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
    let showEffects: Bool
    /// "Delete curve", "Reset to default", or nil when there's nothing to remove.
    let removeTitle: String?
    let onSave: (HeatCurve) -> Void
    let onDelete: (HeatCurve) -> Void
    let onPreview: (PreviewLook?) -> Void
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
                lightsSection
                if let removeTitle {
                    Section {
                        Button(removeTitle, role: .destructive) {
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
        .onDisappear { onPreview(nil) }
    }

    @ViewBuilder
    private var lightsSection: some View {
        Section {
            Toggle("Light color", isOn: Binding(
                get: { curve.hasLights },
                set: { on in
                    if on {
                        curve.color = RGB(r: 255, g: 120, b: 0)
                    } else {
                        curve.color = nil
                        curve.multi = nil
                        curve.effect = nil
                    }
                    previewLights()
                }
            ))
            if curve.hasLights {
                if showEffects {
                    Picker("Style", selection: Binding(
                        get: { curve.multi != nil },
                        set: { isMulti in
                            if isMulti {
                                curve.multi = curve.multi ?? .default
                                curve.color = nil
                            } else {
                                curve.color = curve.multi?.colors.first ?? curve.color ?? RGB(r: 255, g: 120, b: 0)
                                curve.multi = nil
                            }
                            previewLights()
                        }
                    )) {
                        Text("Single color").tag(false)
                        Text("Multiple colors").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if curve.multi != nil {
                    MultiColorEditor(look: Binding(
                        get: { curve.multi ?? .default },
                        set: { curve.multi = $0 }
                    )) { look in
                        curve.multi = look
                        previewLights()
                    }
                } else {
                    singleColorControls
                }
            }
        } header: {
            Text("Lights")
        } footer: {
            Text(curve.hasLights
                 ? "Your Peak shows this while the curve runs, then profile 4's lights come back. It previews live while you choose."
                 : "Off: the Peak keeps profile 4's lights while the curve runs.")
        }
    }

    @ViewBuilder
    private var singleColorControls: some View {
        ColorPicker("Color", selection: Binding(
            get: { curve.color?.color ?? .orange },
            set: { curve.color = RGB($0); previewLights() }
        ), supportsOpacity: false)
        if showEffects {
            Picker("Effect", selection: Binding(
                get: { curve.effect ?? .steady },
                set: { curve.effect = $0; previewLights() }
            )) {
                ForEach(LightEffect.allCases) { e in
                    Text(e.name).tag(e)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func previewLights() {
        if let multi = curve.multi {
            onPreview(.multiColor(multi))
        } else if let color = curve.color {
            onPreview(.singleColor(color, showEffects ? (curve.effect ?? .steady) : nil))
        } else {
            onPreview(nil)
        }
    }

    private func pointRow(_ point: Binding<CurvePoint>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Stepper("At \(Int(point.wrappedValue.time))s", value: point.time, in: HeatCurve.timeRange, step: 1)
            Stepper(Temp.format(Temp.c(fromF: point.wrappedValue.tempF), celsius: celsius),
                    value: point.tempF, in: HeatCurve.tempRangeF, step: 5)
        }
    }
}
