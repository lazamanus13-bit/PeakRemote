import SwiftUI
import CoreBluetooth

struct ScanView: View {
    @EnvironmentObject private var c: PuffcoController
    @State private var showLog = false

    var body: some View {
        List {
            if let message = bluetoothMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if case .failed(let message) = c.phase {
                Section {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }

            if let last = c.lastDevice, c.bluetoothState == .poweredOn {
                Section("Last device") {
                    Button {
                        c.connectLastDevice()
                    } label: {
                        DeviceRow(name: last.name ?? "Puffco", detail: "Tap to reconnect", rssi: nil)
                    }
                }
            }

            Section {
                if c.visibleDevices.isEmpty {
                    HStack(spacing: 12) {
                        if c.isScanning { ProgressView() }
                        Text(c.isScanning ? "Looking for your Peak… make sure it's awake." : "No devices found.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(c.visibleDevices) { device in
                    Button {
                        c.connect(device)
                    } label: {
                        DeviceRow(
                            name: device.name,
                            detail: device.isLikelyPuffco ? "Puffco" : String(device.id.uuidString.prefix(8)),
                            rssi: device.rssi
                        )
                    }
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("Your Peak shows up under the name you gave it. Close the official Puffco app first: the device only talks to one phone app at a time. If yours doesn't appear, turn on Show all devices.")
            }

            Section {
                Toggle("Show all devices", isOn: $c.showAllDevices)
            }
        }
        .navigationTitle("Peak Remote")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showLog = true } label: { Image(systemName: "ladybug") }
                    .accessibilityLabel("Debug log")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(c.isScanning ? "Stop" : "Scan") {
                    if c.isScanning { c.stopScan() } else { c.startScan() }
                }
                .disabled(c.bluetoothState != .poweredOn)
            }
        }
        .refreshable {
            c.stopScan()
            c.startScan()
        }
        .onAppear { c.startScan() }
        .sheet(isPresented: $showLog) {
            NavigationView { LogView() }
                .navigationViewStyle(.stack)
                .environmentObject(c)
        }
    }

    private var bluetoothMessage: String? {
        switch c.bluetoothState {
        case .poweredOn, .unknown, .resetting: return nil
        case .poweredOff: return "Bluetooth is off. Turn it on in Control Center."
        case .unauthorized: return "Bluetooth permission is off. Enable it in Settings → Peak Remote."
        case .unsupported: return "This device doesn't support Bluetooth LE."
        @unknown default: return nil
        }
    }
}

struct DeviceRow: View {
    let name: String
    let detail: String
    let rssi: Int?

    var body: some View {
        HStack {
            Image(systemName: "flame.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let rssi { SignalBars(rssi: rssi) }
        }
        .contentShape(Rectangle())
    }
}

struct SignalBars: View {
    let rssi: Int

    private var level: Int {
        if rssi >= -60 { return 4 }
        if rssi >= -70 { return 3 }
        if rssi >= -80 { return 2 }
        return 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
        .accessibilityLabel("Signal \(level) of 4")
    }
}
