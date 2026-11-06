import SwiftUI
import UIKit

struct DeviceView: View {
    @EnvironmentObject private var c: PuffcoController
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("useCelsius") private var useCelsius = false
    @State private var editingProfile: HeatProfile?
    @State private var brightness: Double = 128
    @State private var showLog = false

    private var ready: Bool { c.phase == .ready }

    var body: some View {
        ScrollView {
            Group {
                if sizeClass == .regular {
                    // iPad: dial and heat controls on the left, everything else on the right.
                    VStack(spacing: 20) {
                        if !ready { PhaseBanner(phase: c.phase) }
                        HStack(alignment: .top, spacing: 24) {
                            VStack(spacing: 24) {
                                TemperatureDial(status: c.status, celsius: useCelsius, size: 340)
                                    .opacity(ready ? 1 : 0.4)
                                controls
                            }
                            .frame(maxWidth: .infinity)
                            VStack(spacing: 20) {
                                profiles
                                lights
                                info
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: 1100)
                } else {
                    VStack(spacing: 20) {
                        if !ready { PhaseBanner(phase: c.phase) }

                        TemperatureDial(status: c.status, celsius: useCelsius)
                            .opacity(ready ? 1 : 0.4)

                        controls
                        profiles
                        lights
                        info
                    }
                    .frame(maxWidth: 600)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(c.status.deviceName ?? c.connectedName ?? "Peak")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Disconnect") { c.disconnect() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    BatteryBadge(percent: c.status.batteryPct, charging: ChargeLabel.isCharging(c.status.chargeRaw))
                    Button { showLog = true } label: { Image(systemName: "ladybug") }
                        .accessibilityLabel("Debug log")
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditView(profile: profile, celsius: useCelsius) { tempC, seconds in
                c.saveProfile(slot: profile.slot, tempC: tempC, durationS: seconds)
            }
        }
        .sheet(isPresented: $showLog) {
            NavigationStack { LogView() }
                .environmentObject(c)
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { c.lastError = nil }
        } message: {
            Text(c.lastError ?? "")
        }
        .onAppear {
            if let b = c.status.brightness { brightness = Double(b) }
        }
        .onChange(of: c.status.brightness) { _, value in
            if let value { brightness = Double(value) }
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Brightness")
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: $brightness, in: 0...255, onEditingChanged: { editing in
                        if !editing { c.setBrightness(UInt8(brightness.rounded())) }
                    })
                    Image(systemName: "sun.max.fill")
                }
            }
        }
        .disabled(!ready)
    }

    private var info: some View {
        Card("Device") {
            InfoRow(label: "Battery", value: batteryText)
            InfoRow(label: "Chamber", value: ChamberLabel.name(c.status.chamberRaw))
            InfoRow(label: "Lifetime dabs", value: c.status.lifetimeDabs.map { "\($0)" } ?? "—")
            InfoRow(label: "Model", value: c.status.model ?? "—")
            InfoRow(label: "Firmware", value: c.status.firmware ?? "—")
            InfoRow(label: "Serial", value: c.status.serial ?? "—")
            Picker("Units", selection: $useCelsius) {
                Text("°F").tag(false)
                Text("°C").tag(true)
            }
            .pickerStyle(.segmented)
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
            Text(profile.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
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
