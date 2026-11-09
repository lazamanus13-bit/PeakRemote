import SwiftUI
import UIKit

struct DeviceView: View {
    @EnvironmentObject private var c: PuffcoController
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("useCelsius") private var useCelsius = false
    @State private var editingProfile: HeatProfile?
    @State private var brightness: Double = 128
    @State private var lanternColor: Color = .orange
    @State private var lanternCommit: Task<Void, Never>?
    @State private var lanternEffect: LightEffect = .steady
    @State private var showLanternColors = false
    @AppStorage("studioUnlocked") private var studioUnlocked = false
    @State private var showJailbreak = false
    @AppStorage("dashboardLayout") private var tileLayoutRaw = TileLayout.default.raw
    @State private var editingLayout = false
    @State private var dropTarget: String?
    @Environment(\.openURL) private var openURL
    @State private var showFirmwareHelp = false
    @State private var showLog = false

    private var ready: Bool { c.phase == .ready }

    // The body is split into pieces so the Swift compiler can type-check each one quickly.
    var body: some View {
        syncState(presentations(chrome))
    }

    private var chrome: some View {
        scrollContent
            .navigationTitle(c.status.deviceName ?? c.connectedName ?? "Peak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
    }

    private var scrollContent: some View {
        ScrollView {
            Group {
                if sizeClass == .regular { wideLayout } else { narrowLayout }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    /// iPad: dial and heat controls on the left, everything else on the right.
    private var wideLayout: some View {
        VStack(spacing: 20) {
            if !ready { PhaseBanner(phase: c.phase) }
            if editingLayout { arrangeBanner }
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 20) {
                    TemperatureDial(status: c.status, celsius: useCelsius, size: 340)
                        .opacity(ready ? 1 : 0.4)
                    controls
                    tiles(layout.left, column: .left)
                }
                .frame(maxWidth: .infinity)
                tiles(layout.right, column: .right)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: 1100)
    }

    private var narrowLayout: some View {
        VStack(spacing: 20) {
            if !ready { PhaseBanner(phase: c.phase) }
            if editingLayout { arrangeBanner }
            TemperatureDial(status: c.status, celsius: useCelsius)
                .opacity(ready ? 1 : 0.4)
            controls
            tiles(layout.all, column: .right)
        }
        .frame(maxWidth: 600)
    }

    private var layout: TileLayout { TileLayout(raw: tileLayoutRaw) }

    /// A column of tiles in the user's chosen order. While arranging, tiles become draggable bars.
    @ViewBuilder
    private func tiles(_ list: [DashboardTile], column: TileColumn) -> some View {
        if editingLayout {
            VStack(spacing: 12) {
                ForEach(list.filter { $0 != .studio || studioUnlocked }) { tile in
                    arrangeable(tile)
                }
                columnDropZone(column)
            }
        } else {
            VStack(spacing: 20) {
                ForEach(list) { tile in
                    tileView(tile)
                }
            }
        }
    }

    private func arrangeable(_ tile: DashboardTile) -> some View {
        ArrangeableTile(tile: tile, isTargeted: dropTarget == tile.rawValue)
            .draggable(tile.rawValue) {
                ArrangeableTile(tile: tile, isTargeted: true).frame(width: 280)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let moved = items.first.flatMap(DashboardTile.init(rawValue:)) else { return false }
                saveLayout(layout.moving(moved, before: tile))
                return true
            } isTargeted: { over in
                dropTarget = over ? tile.rawValue : (dropTarget == tile.rawValue ? nil : dropTarget)
            }
    }

    private func columnDropZone(_ column: TileColumn) -> some View {
        let key = column == .left ? "|left" : "|right"
        return TileDropZone(isTargeted: dropTarget == key)
            .dropDestination(for: String.self) { items, _ in
                guard let moved = items.first.flatMap(DashboardTile.init(rawValue:)) else { return false }
                saveLayout(layout.moving(moved, toEndOf: column))
                return true
            } isTargeted: { over in
                dropTarget = over ? key : (dropTarget == key ? nil : dropTarget)
            }
    }

    private var arrangeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.draw")
            Text("Drag tiles to move them.")
                .font(.subheadline)
            Spacer()
            Button("Reset") { saveLayout(.default) }
                .buttonStyle(.bordered)
            Button("Done") { withAnimation { editingLayout = false } }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
        .padding()
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
    }

    private func saveLayout(_ next: TileLayout) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            tileLayoutRaw = next.raw
        }
        dropTarget = nil
    }

    @ViewBuilder
    private func tileView(_ tile: DashboardTile) -> some View {
        switch tile {
        case .studio: if studioUnlocked { studio }
        case .profiles: profiles
        case .readyMode: readyMode
        case .lights: lights
        case .stats: stats
        case .battery: battery
        case .device: info
        }
    }

    private var studio: some View {
        StudioCard(
            runner: c.curves,
            ready: ready && !c.status.state.isHeating,
            liveTempC: c.status.tempC,
            celsius: useCelsius,
            onLock: { studioUnlocked = false },
            onPreview: { look in c.preview(look) },
            showEffects: c.colorFormat != .api3
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Disconnect") { c.disconnect() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                BatteryBadge(percent: c.status.batteryPct, charging: ChargeLabel.isCharging(c.status.chargeRaw))
                Button {
                    withAnimation { editingLayout.toggle() }
                } label: {
                    Image(systemName: editingLayout ? "checkmark.circle.fill" : "rectangle.3.group")
                }
                .accessibilityLabel(editingLayout ? "Done arranging" : "Arrange tiles")
                Button { showLog = true } label: { Image(systemName: "ladybug") }
                    .accessibilityLabel("Debug log")
            }
        }
    }

    private func editor(for profile: HeatProfile) -> ProfileEditView {
        let controller = c
        return ProfileEditView(
            profile: profile,
            celsius: useCelsius,
            allowXL: controller.status.chamberRaw == 2,
            showEffects: controller.colorFormat != .api3,
            onSave: { edit in controller.saveProfile(slot: profile.slot, edit: edit) },
            onPreview: { look in controller.preview(look) }
        )
    }

    private func presentations<V: View>(_ content: V) -> some View {
        content
            .sheet(item: $editingProfile) { profile in editor(for: profile) }
            .sheet(isPresented: $showJailbreak) {
                JailbreakSheet { studioUnlocked = true }
            }
            .sheet(isPresented: $showLanternColors) {
                LanternColorsSheet(
                    look: .default,
                    onPreview: { look in c.preview(look) },
                    onSave: { look in c.setLanternMultiColor(look) }
                )
            }
            .sheet(isPresented: $showLog) {
                NavigationView { LogView() }
                    .navigationViewStyle(.stack)
                    .environmentObject(c)
            }
            .alert("Firmware updates", isPresented: $showFirmwareHelp) {
                Button("Disconnect so the computer can connect") { c.disconnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Firmware updates come from Puffco's web app. On a computer, open Google Chrome, go to puffco.app, connect your Peak, and check for updates there. Peak Remote has to disconnect first: the Peak only talks to one device at a time.")
            }
            .alert("Something went wrong", isPresented: errorBinding) {
                Button("OK") { c.lastError = nil }
            } message: {
                Text(c.lastError ?? "")
            }
    }

    /// Keeps local control state in step with values read from the Peak.
    private func syncState<V: View>(_ content: V) -> some View {
        content
            .onAppear {
                if let b = c.status.brightness { brightness = Double(b) }
            }
            .onChange(of: c.status.brightness) { value in
                if let value { brightness = Double(value) }
            }
            .onChange(of: c.status.lanternColor) { value in
                if let value { lanternColor = value.color }
            }
            .onChange(of: c.status.lanternEffect) { value in
                if let value { lanternEffect = value }
            }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { c.lastError != nil }, set: { if !$0 { c.lastError = nil } })
    }

    // MARK: Sections

    private var controls: some View {
        HStack(spacing: 12) {
            if c.status.state.isHeating {
                BigButton(title: "Boost", icon: "plus.circle.fill", tint: .orange) { c.boost() }
                BigButton(title: "Stop", icon: "stop.fill", tint: .red) { c.stopHeat() }
            } else {
                BigButton(title: "Start heat", icon: "flame.fill", tint: .orange) { c.startHeat() }
            }
        }
        .disabled(!ready)
    }

    private var profiles: some View {
        Card("Profiles") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(c.status.profiles) { profile in
                    ProfileTile(
                        profile: profile,
                        selected: c.status.activeProfile == profile.slot,
                        celsius: useCelsius
                    )
                    .onTapGesture {
                        guard ready, !c.status.state.isHeating else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        c.selectProfile(profile.slot)
                    }
                    .contextMenu {
                        Button {
                            editingProfile = profile
                        } label: {
                            Label("Edit profile", systemImage: "slider.horizontal.3")
                        }
                    }
                }
            }
            Text("Tap to select. Long-press to edit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!ready)
    }

    private var lanternColorBinding: Binding<Color> {
        Binding(get: { lanternColor }, set: { newColor in
            lanternColor = newColor
            previewAndCommitLantern()
        })
    }

    private var lanternEffectBinding: Binding<LightEffect> {
        Binding(get: { lanternEffect }, set: { newEffect in
            lanternEffect = newEffect
            previewAndCommitLantern()
        })
    }

    private var lanternControls: some View {
        Group {
            ColorPicker("Lantern color", selection: lanternColorBinding, supportsOpacity: false)
            if c.colorFormat != .api3 {
                Picker("Lantern effect", selection: lanternEffectBinding) {
                    ForEach(LightEffect.allCases) { e in
                        Text(e.name).tag(e)
                    }
                }
                .pickerStyle(.menu)
                Button {
                    showLanternColors = true
                } label: {
                    Label(c.status.lanternIsMultiColor ? "Multiple colors (on)" : "Use multiple colors…", systemImage: "paintpalette")
                }
            }
        }
    }

    private var lights: some View {
        Card("Lights") {
            Toggle("Stealth mode", isOn: Binding(
                get: { c.status.stealth ?? false },
                set: { c.setStealth($0) }
            ))
            Toggle("Lantern", isOn: Binding(
                get: { c.status.lantern },
                set: { c.setLantern($0) }
            ))
            lanternControls
            if c.status.lantern, let left = c.status.lanternRemainingS, left > 0 {
                InfoRow(label: "Lantern time left", value: Fmt.duration(left))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Brightness")
                HStack {
                    Image(systemName: "sun.min")
                    // The official app never goes below 38.25 / 255.
                    Slider(value: $brightness, in: 38...255, onEditingChanged: { editing in
                        if !editing { c.setBrightness(UInt8(brightness.rounded())) }
                    })
                    Image(systemName: "sun.max.fill")
                }
            }
        }
        .disabled(!ready)
    }

    private var readyMode: some View {
        Card("Ready Mode") {
            Picker("Start when lifted off the dock", selection: Binding(
                get: { c.status.readyModeProfile ?? -1 },
                set: { c.setReadyMode($0) }
            )) {
                Text("Off").tag(-1)
                ForEach(c.status.profiles) { p in
                    Text(p.displayName).tag(p.slot)
                }
            }
            .pickerStyle(.menu)
            Text("With a Power Dock, your Peak starts the chosen profile as soon as you lift it off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!ready)
    }

    private var stats: some View {
        Card("Stats") {
            InfoRow(label: "Lifetime dabs", value: c.status.lifetimeDabs.map { "\($0)" } ?? "—")
            InfoRow(label: "Total heating time", value: c.status.totalHeatTimeS.map(Fmt.duration) ?? "—")
            InfoRow(label: "Trip dabs", value: c.status.tripDabs.map { "\($0)" } ?? "—")
            InfoRow(label: "Dabs per day", value: c.status.dabsPerDay.map { String(format: "%.1f", $0) } ?? "—")
            InfoRow(label: "Dabs left on this charge", value: c.status.dabsRemaining.map { "~\(Int($0.rounded()))" } ?? "—")
        }
    }

    private var battery: some View {
        Card("Battery") {
            InfoRow(label: "Charge", value: batteryText)
            if let source = ChargeSourceLabel.name(c.status.chargeSourceRaw), ChargeLabel.isCharging(c.status.chargeRaw) {
                InfoRow(label: "Charging from", value: source)
            }
            if ChargeLabel.isCharging(c.status.chargeRaw), let etf = c.status.chargeTimeToFullS, etf > 0 {
                InfoRow(label: "Time to full", value: Fmt.duration(etf))
            }
            InfoRow(label: "Voltage", value: c.status.batteryVolts.map { String(format: "%.2f V", $0) } ?? "—")
            InfoRow(label: "Temperature", value: Temp.format(c.status.batteryTempC, celsius: useCelsius))
            InfoRow(label: "Charge limit", value: c.status.maxBatteryPct.map { "\(Int($0.rounded()))%" } ?? "—")
            InfoRow(label: "Low battery warning", value: c.status.lowBatteryWarnPct.map { "\(Int($0.rounded()))%" } ?? "—")
        }
    }

    private var info: some View {
        Card("Device") {
            InfoRow(label: "Chamber", value: ChamberLabel.name(c.status.chamberRaw))
            InfoRow(label: "Model", value: c.status.model ?? "—")
            InfoRow(label: "Firmware", value: c.status.firmware ?? "—")
            if studioUnlocked {
                Label("Studio unlocked", systemImage: "lock.open.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                Button {
                    showJailbreak = true
                } label: {
                    Label("Jailbreak", systemImage: "lock.open")
                }
            }
            Button {
                showFirmwareHelp = true
            } label: {
                Label("Check for firmware updates", systemImage: "arrow.down.circle")
            }
            InfoRow(label: "Serial", value: c.status.serial ?? "—")
            Picker("Units", selection: $useCelsius) {
                Text("°F").tag(false)
                Text("°C").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }

    /// Shows the lantern look on the Peak right away, then saves it once the user stops changing it.
    private func previewAndCommitLantern() {
        let rgb = RGB(lanternColor)
        let effect: LightEffect? = c.colorFormat != .api3 ? lanternEffect : nil
        c.preview(rgb, effect: effect)
        lanternCommit?.cancel()
        lanternCommit = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            c.setLanternColor(rgb, effect: effect)
            c.preview(nil)
        }
    }

    private var batteryText: String {
        guard let pct = c.status.batteryPct else { return "—" }
        if let charge = ChargeLabel.name(c.status.chargeRaw) { return "\(pct)% · \(charge)" }
        return "\(pct)%"
    }
}

// MARK: - Components

struct TemperatureDial: View {
    let status: DeviceStatus
    let celsius: Bool
    var size: CGFloat = 250

    private var scale: CGFloat { size / 250 }

    private var progress: Double {
        guard let t = status.tempC else { return 0 }
        let scale = status.state.isHeating ? (status.targetC ?? 330) : 330
        return min(1, max(0, t / scale))
    }

    private var stateColor: Color {
        if status.state.isActive { return .green }
        if status.state.isHeating { return .orange }
        return .secondary
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 18 * scale)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [.yellow, .orange, .red, .yellow], center: .center),
                    style: StrokeStyle(lineWidth: 18 * scale, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)

            VStack(spacing: 6) {
                Text(status.state.label.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(stateColor)
                Text(Temp.format(status.tempC, celsius: celsius))
                    .font(.system(size: 64 * scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: status.tempC)
                if let target = status.targetC {
                    Text("Target \(Temp.format(target, celsius: celsius))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if status.state.isHeating, let remaining = status.remainingS {
                    Label("\(Int(remaining.rounded()))s", systemImage: "timer")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(width: size, height: size)
        .padding(.vertical, 8)
    }
}

struct BigButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .buttonBorderShape(.roundedRectangle(radius: 16))
    }
}

struct ProfileTile: View {
    let profile: HeatProfile
    let selected: Bool
    let celsius: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if profile.isMultiColor {
                    MultiColorDot(colors: profile.multiColors)
                } else if let color = profile.color {
                    Circle().fill(color.color).frame(width: 10, height: 10)
                }
                Text(profile.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Text(Temp.format(profile.tempC, celsius: celsius))
                .font(.title2.weight(.bold).monospacedDigit())
            Text(profile.durationS.map { "\(Int($0.rounded()))s" } ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(selected ? Color.orange.opacity(0.18) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(selected ? Color.orange : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

struct BatteryBadge: View {
    let percent: Int?
    let charging: Bool

    private var icon: String {
        if charging { return "battery.100percent.bolt" }
        guard let p = percent else { return "battery.0percent" }
        switch p {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            if let percent { Text("\(percent)%").font(.caption.monospacedDigit()) }
        }
        .foregroundStyle((percent ?? 100) < 15 && !charging ? Color.red : Color.primary)
    }
}

struct PhaseBanner: View {
    let phase: ConnectionPhase

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(phase.label).font(.subheadline)
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Helpers

enum Fmt {
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        let h = s / 3600, m = (s % 3600) / 60
        return h >= 100 ? "\(h)h" : "\(h)h \(m)m"
    }
}

extension RGB {
    var color: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: byte(red), g: byte(green), b: byte(blue))
    }
}

/// A small color wheel for multi-color looks (a rainbow ring if the colors aren't known yet).
struct MultiColorDot: View {
    let colors: [RGB]
    var size: CGFloat = 10

    private var wheel: [Color] {
        let base = colors.count >= 2 ? colors.map(\.color) : [.red, .orange, .yellow, .green, .blue, .purple]
        return base + [base[0]]
    }

    var body: some View {
        Circle()
            .fill(AngularGradient(colors: wheel, center: .center))
            .frame(width: size, height: size)
            .accessibilityLabel("Multiple colors")
    }
}
