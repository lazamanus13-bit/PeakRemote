import Foundation
import CoreBluetooth

struct OperatingState: Equatable {
    var raw: UInt8

    static let unknown = OperatingState(raw: 0xFF)

    var isHeating: Bool { (7...9).contains(raw) }
    var isPreheating: Bool { raw == 7 }
    var isActive: Bool { raw == 8 }

    var label: String {
        switch raw {
        case 0, 1, 2: return "Starting up"
        case 3: return "Off"
        case 4: return "Sleeping"
        case 5: return "Ready"
        case 6: return "Selecting temp"
        case 7: return "Preheating"
        case 8: return "Ready to dab"
        case 9: return "Cooling down"
        case 10: return "Showing version"
        case 11: return "Showing battery"
        case 12: return "Factory test"
        case 13: return "Pairing"
        case 0xFF: return "—"
        default: return "State \(raw)"
        }
    }
}

enum ChamberLabel {
    static func name(_ raw: UInt8?) -> String {
        guard let raw else { return "—" }
        switch raw {
        case 0: return "None"
        case 1: return "Classic"
        case 2: return "XL"
        case 3: return "3D"
        default: return "Type \(raw)"
        }
    }
}

/// Values from the profile editor.
struct ProfileEdit {
    var tempC: Double
    var durationS: Double
    var boostTempDeltaC: Double?
    var boostTimeS: Double?
    var color: RGB?
    var intensity: Double?
}

/// Vapor levels and the values the official app writes to /u/app/hc/N/intn.
enum VaporLevel: Double, CaseIterable, Identifiable {
    case standard = 0
    case high = 0.5
    case max = 1
    case xl = 1.5

    var id: Double { rawValue }

    var name: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .max: return "Max"
        case .xl: return "XL"
        }
    }

    /// Closest level to a value read from the device.
    static func nearest(_ value: Double) -> VaporLevel {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .standard
    }
}

struct RGB: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

enum ChargeSourceLabel {
    static func name(_ raw: UInt8?) -> String? {
        switch raw {
        case 0?: return "USB-C"
        case 1?: return "Wireless (Qi)"
        case 2?: return "Power Dock"
        default: return nil
        }
    }
}

enum ChargeLabel {
    static func name(_ raw: UInt8?) -> String? {
        guard let raw else { return nil }
        switch raw {
        case 0, 1: return "Charging"
        case 2: return "Fully charged"
        case 3: return "Charging paused (temperature)"
        default: return nil
        }
    }

    static func isCharging(_ raw: UInt8?) -> Bool { raw == 0 || raw == 1 }
}

struct HeatProfile: Identifiable, Equatable {
    let slot: Int
    var name: String?
    var tempC: Double?
    var durationS: Double?
    /// Whether the device stored the duration as float32 (true) or uint32 (false).
    var durationIsFloat = true
    var boostTempDeltaC: Double?
    var boostTimeS: Double?
    var intensity: Double?
    var color: RGB?

    var id: Int { slot }
    var displayName: String { name ?? "Profile \(slot + 1)" }
}

struct DeviceStatus: Equatable {
    var deviceName: String?
    var model: String?
    var serial: String?
    var firmware: String?

    var state: OperatingState = .unknown
    var tempC: Double?
    var targetC: Double?
    var elapsedS: Double?
    var totalS: Double?

    var batteryPct: Int?
    var chargeRaw: UInt8?
    var chamberRaw: UInt8?
    var lifetimeDabs: Int?

    var activeProfile: Int?
    var profiles: [HeatProfile] = (0..<4).map { HeatProfile(slot: $0) }

    var stealth: Bool?
    var lantern = false
    var brightness: UInt8?
    var lanternColor: RGB?
    var lanternRemainingS: Double?

    /// nil = unknown, -1 = off, 0...3 = profile that starts when lifted off the Power Dock.
    var readyModeProfile: Int?

    var batteryVolts: Double?
    var batteryTempC: Double?
    var chargeSourceRaw: UInt8?
    var chargeTimeToFullS: Double?
    var maxBatteryPct: Double?
    var lowBatteryWarnPct: Double?

    var totalHeatTimeS: Double?
    var tripDabs: Int?
    var tripHeatTimeS: Double?
    var dabsPerDay: Double?
    var dabsRemaining: Double?

    var remainingS: Double? {
        guard let e = elapsedS, let t = totalS else { return nil }
        return max(0, t - e)
    }
}

struct DiscoveredDevice: Identifiable {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var isLikelyPuffco: Bool
    var lastSeen: Date

    var id: UUID { peripheral.identifier }
}

enum ConnectionPhase: Equatable {
    case disconnected
    case connecting
    case pairing
    case authenticating
    case ready
    case reconnecting
    case failed(String)

    var isInSession: Bool {
        switch self {
        case .connecting, .pairing, .authenticating, .ready, .reconnecting: return true
        case .disconnected, .failed: return false
        }
    }

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .pairing: return "Pairing… accept the iOS prompt if one appears"
        case .authenticating: return "Unlocking device…"
        case .ready: return "Connected"
        case .reconnecting: return "Connection lost. Reconnecting…"
        case .failed(let message): return message
        }
    }
}

enum PuffcoError: LocalizedError {
    case notConnected
    case timeout
    case authFailed
    case unsupportedFirmware

    var errorDescription: String? {
        switch self {
        case .notConnected: return "The device isn't connected."
        case .timeout: return "The device didn't answer in time."
        case .authFailed: return "Couldn't unlock the device. Make sure it's paired, then try again."
        case .unsupportedFirmware: return "This device doesn't expose the Lorax service. Older firmware isn't supported yet."
        }
    }
}

/// Temperature display helpers.
enum Temp {
    static func f(fromC c: Double) -> Double { c * 9 / 5 + 32 }
    static func c(fromF f: Double) -> Double { (f - 32) * 5 / 9 }

    static func format(_ c: Double?, celsius: Bool) -> String {
        guard let c else { return "—" }
        let v = celsius ? c : f(fromC: c)
        return "\(Int(v.rounded()))°"
    }
}
