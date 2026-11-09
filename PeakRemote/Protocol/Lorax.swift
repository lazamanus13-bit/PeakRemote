import Foundation
import CoreBluetooth
import CryptoKit

/// The Puffco "Lorax" BLE protocol, ported from the community projects
/// puffco-py (SoyMilkIsOk) and PuffcoBLE (Fr0st3h).
///
/// Every request is written to the Command characteristic as:
///   [seq lo][seq hi][opcode][body...]
/// and the device answers on the Reply characteristic with:
///   [seq lo][seq hi][status][payload...]
enum Lorax {
    // MARK: GATT

    static let serviceUUID = CBUUID(string: "E276967F-EA8A-478A-A92E-D78F5DD15DD5")
    static let commandUUID = CBUUID(string: "60133D5C-5727-4F2C-9697-D842C5292A3C")
    static let replyUUID   = CBUUID(string: "8DC5EC05-8F7D-45AD-99DB-3FBDE65DBD9C")
    static let eventUUID   = CBUUID(string: "43312CD1-7D34-46CE-A7D3-0A98FD9B4CB8")
    static let versionUUID = CBUUID(string: "05434BCA-CC7F-4EF6-BBB3-B1C520B9800C")

    /// Pre-Lorax firmware used a different flat GATT layout. Not supported here.
    static let legacyServiceUUID = CBUUID(string: "06CAF9C0-74D3-454F-9BE9-E30CD999C17A")

    static let deviceInfoServiceUUID = CBUUID(string: "180A")
    static let modelNumberUUID = CBUUID(string: "2A24")
    static let serialNumberUUID = CBUUID(string: "2A25")
    static let firmwareUUID = CBUUID(string: "2A26")

    // MARK: Opcodes

    enum Opcode: UInt8 {
        case getAccessSeed = 0x00
        case unlockAccess  = 0x01
        case getLimits     = 0x02
        /// Sent by the official app right after subscribing (seen in melt's traffic capture).
        case pruneFileHandles = 0x27
        case readShort     = 0x10
        case writeShort    = 0x11
    }

    // MARK: Authentication

    /// Lorax handshake key (base64 "ZMZFYlbyb1scoSc3pd1x+w==").
    static let handshakeKey: [UInt8] = [
        0x64, 0xC6, 0x45, 0x62, 0x56, 0xF2, 0x6F, 0x5B,
        0x1C, 0xA1, 0x27, 0x37, 0xA5, 0xDD, 0x71, 0xFB,
    ]

    /// token = SHA256(handshakeKey ++ seed[0..<16])[0..<16]
    static func authToken(seed: [UInt8], key: [UInt8] = handshakeKey) -> [UInt8]? {
        guard seed.count >= 16 else { return nil }
        let input = key + Array(seed.prefix(16))
        let digest = SHA256.hash(data: Data(input))
        return Array(Array(digest).prefix(16))
    }

    // MARK: Packets

    static func command(seq: UInt16, opcode: Opcode, body: [UInt8] = []) -> Data {
        Data([UInt8(seq & 0xFF), UInt8(seq >> 8), opcode.rawValue] + body)
    }

    /// READ_SHORT body: [offset u16][size u16][path utf8]
    static func readShortBody(path: String, offset: UInt16 = 0, size: UInt16) -> [UInt8] {
        Encode.uint16(offset) + Encode.uint16(size) + Array(path.utf8)
    }

    /// WRITE_SHORT body: [offset u16][flags u8][path utf8][0x00][value...]
    static func writeShortBody(path: String, value: [UInt8], offset: UInt16 = 0, flags: UInt8 = 0) -> [UInt8] {
        Encode.uint16(offset) + [flags] + Array(path.utf8) + [0x00] + value
    }

    struct Reply: Equatable {
        let seq: UInt16
        let status: UInt8
        let payload: [UInt8]
    }

    static func parseReply(_ data: Data) -> Reply? {
        let b = [UInt8](data)
        guard b.count >= 3 else { return nil }
        return Reply(
            seq: UInt16(b[0]) | (UInt16(b[1]) << 8),
            status: b[2],
            payload: Array(b[3...])
        )
    }
}

// MARK: - Virtual file system paths

enum LoraxPath {
    static let operatingState = "/p/app/stat/id"
    static let elapsed        = "/p/app/stat/elap"
    static let total          = "/p/app/stat/tott"
    static let modeCommand    = "/p/app/mc"

    static let heaterTemp     = "/p/app/htr/temp"
    static let heaterTarget   = "/p/app/htr/ttag"
    static let chamberType    = "/p/htr/chmt"

    // The two libraries disagree on these, so the app tries both.
    static let batteryCapacity = "/p/bat/cap"      // PuffcoBLE (float32 %)
    static let batterySoc      = "/p/bat/soc"      // puffco-py
    static let chargeState     = "/p/bat/chg/stat"
    static let totalDabs       = "/p/app/info/dtot" // PuffcoBLE (uint32)
    static let odometerDabs    = "/p/app/odom/0/nc" // puffco-py

    static let deviceName      = "/u/sys/name"
    static let serial          = "/p/sys/hw/ser"
    static let firmwareRevision = "/p/sys/fw/ver"   // first byte = revision number
    static let modelCode        = "/p/sys/hw/mdcd"  // uint32 model code
    static let activeProfile   = "/p/app/hcs"
    static let stealth         = "/u/app/ui/stlm"
    static let lantern         = "/p/app/ltrn/cmd"
    static let ledBrightness   = "/u/app/ui/lbrt"

    // Settings and stats (names from the official app's register map)
    static let readyMode       = "/u/app/rdym/hc"   // float32 profile index, 4294967295 = off
    static let maxBatterySoc   = "/u/bat/msoc"      // float32 %, charge limit
    static let lowBatteryWarn  = "/u/app/lbws"      // float32 %
    static let batteryVolts    = "/p/bat/volt"      // float32 V
    static let batteryTemp     = "/p/bat/temp"      // float32 °C
    static let chargeSource    = "/p/bat/chg/src"   // uint8
    static let chargeTimeToFull = "/p/bat/chg/etf"  // float32 s
    static let totalHeatTime   = "/p/app/odom/0/tm" // total heat-cycle time
    static let tripDabs        = "/p/app/odom/1/nc"
    static let tripHeatTime    = "/p/app/odom/1/tm"
    static let dabsPerDay      = "/p/app/info/dpd"  // float32
    static let dabsRemaining   = "/p/app/info/drem" // float32, on current charge
    static let lanternColor    = "/p/app/ltrn/colr" // color file
    static let previewColor    = "/p/app/led/pclr"  // color shown live while editing
    static let sessionTemp     = "/p/app/thc/temp"  // running session's target (float32 °C)
    static let heaterCommand   = "/p/app/htr/tcmd"  // what the heater is actually aiming for (float32 °C)
    static let tempOverride    = "/p/app/tmpo"      // boost offset (float32 °C delta), firmware-capped
    static func userColorList(_ slot: UInt8) -> String { "/u/app/led/ca/\(slot)" }   // [R,G,B,0] entries
    static func userOffsetList(_ slot: UInt8) -> String { "/u/app/led/oa/\(slot)" }  // 20 x uint32
    static let lanternTime     = "/p/app/ltrn/time" // float32 s
    static let lanternRemaining = "/p/app/ltrn/remt" // float32 s

    static func profileName(_ slot: Int) -> String { "/u/app/hc/\(slot)/name" }
    static func profileBoostTemp(_ slot: Int) -> String { "/u/app/hc/\(slot)/btmp" } // float32 °C delta
    static func profileBoostTime(_ slot: Int) -> String { "/u/app/hc/\(slot)/btim" } // float32 s
    static func profileIntensity(_ slot: Int) -> String { "/u/app/hc/\(slot)/intn" } // float32
    static func profileColor(_ slot: Int) -> String { "/u/app/hc/\(slot)/colr" }     // CBOR color file
    static func profileTemp(_ slot: Int) -> String { "/u/app/hc/\(slot)/temp" }
    static func profileTime(_ slot: Int) -> String { "/u/app/hc/\(slot)/time" }
}

/// Values written to `/p/app/mc`.
enum ModeCommand: UInt8 {
    case sleep = 1
    case showBattery = 5
    case heatStart = 7
    case heatAbort = 8
    case heatBoost = 9
}

// MARK: - Encoding / decoding

enum Encode {
    static func uint16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    static func uint32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    static func float32(_ v: Float) -> [UInt8] { uint32(v.bitPattern) }
}

enum Decode {
    static func uint32(_ b: [UInt8]) -> UInt32? {
        guard b.count >= 4 else { return nil }
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    static func int32(_ b: [UInt8]) -> Int32? {
        uint32(b).map { Int32(bitPattern: $0) }
    }

    static func float32(_ b: [UInt8]) -> Float? {
        uint32(b).map { Float(bitPattern: $0) }
    }

    /// A float32 that is a real number (not NaN or infinity).
    static func finiteFloat(_ b: [UInt8]) -> Double? {
        guard let f = float32(b), f.isFinite else { return nil }
        return Double(f)
    }

    /// NUL-terminated / padded UTF-8 string.
    static func string(_ b: [UInt8]) -> String? {
        let bytes = b.prefix { $0 != 0 }
        let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Temperature in °C. Peak Pro sends float32 °C; Proxy may send int32 tenths of °C.
    static func temperatureC(_ b: [UInt8]) -> Double? {
        if let f = float32(b), f.isFinite, f >= 5, f <= 500 { return Double(f) }
        if let i = int32(b), (50...5000).contains(i) { return Double(i) / 10 }
        return nil
    }

    /// Seconds, sent as either float32 or uint32 depending on firmware.
    /// `isFloat` records which encoding was seen so writes can match it.
    static func seconds(_ b: [UInt8]) -> (value: Double, isFloat: Bool)? {
        if let f = float32(b), f.isFinite, f >= 0.5, f <= 1_000_000 { return (Double(f), true) }
        if let u = uint32(b), u <= 1_000_000 { return (Double(u), false) }
        return nil
    }

    /// Battery percent from a single byte, float32 or uint32.
    static func battery(_ b: [UInt8]) -> Int? {
        if b.count == 1 { return min(100, Int(b[0])) }
        if let f = float32(b), f.isFinite, f >= 1, f <= 100 { return Int(f.rounded()) }
        if let u = uint32(b) {
            if u <= 100 { return Int(u) }
            if u <= 10_000 { return min(100, Int((Double(u) / 100).rounded())) }
        }
        return nil
    }

    /// Counters (dabs) sent as uint32, float32, uint16 or uint8.
    static func count(_ b: [UInt8]) -> Int? {
        if b.count >= 4 {
            if let f = float32(b), f.isFinite, f >= 1, f < 10_000_000, f == f.rounded() { return Int(f) }
            return uint32(b).map { Int($0) }
        }
        if b.count == 2 { return Int(UInt16(b[0]) | (UInt16(b[1]) << 8)) }
        if b.count == 1 { return Int(b[0]) }
        return nil
    }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Firmware / model decoding (from PuffcoBLE's utils and product table)

enum PuffcoInfo {
    /// 1 → "A", 2 → "B", … skipping I, L, O, Q, S; 0 → "X*".
    static func revisionString(_ value: Int) -> String {
        let letters = Array("ABCDEFGHJKMNPRTUVWXYZ")
        if value < 0 { return String(value) }
        if value == 0 { return "X*" }
        var shift = value - 1
        var out = ""
        while shift >= 0 {
            out = String(letters[shift % letters.count]) + out
            shift = shift / letters.count - 1
        }
        return out
    }

    /// Product codes (the first three digits of the model number printed on the device, e.g. 071794 → 71),
    /// from the official app's product table.
    static func productName(code: Int) -> String? {
        switch code {
        case 71, 79: return "Peak Pro Onyx"
        case 72, 80: return "Peak Pro Pearl"
        case 74: return "Peak Pro Desert"
        case 75: return "Peak Pro Flourish"
        case 78: return "Peak Pro Storm"
        case 81: return "Peak Pro Daybreak"
        case 83: return "Peak Pro Plasma"
        case 84: return "Peak Pro Glacier"
        case 21: return "Peak Pro (OG)"
        case 22: return "Peak Pro Opal"
        case 25: return "Peak Pro Indiglow"
        case 26: return "Peak Pro Guardian"
        case 51: return "Peak (OG)"
        case 10: return "Proxy Onyx"
        case 11: return "Proxy Haze"
        case 12: return "Proxy Onyx Core"
        case 13: return "Proxy Pine Core"
        case 14: return "Proxy Pine"
        default: return nil
        }
    }

    /// The device's name from its model number (e.g. "071794" → "Peak Pro Onyx").
    static func productName(modelNumber: String) -> String? {
        let digits = modelNumber.filter(\.isNumber)
        guard digits.count >= 3, let code = Int(digits.prefix(3)) else { return nil }
        return productName(code: code)
    }

    /// Best name for the device: from the advertised product code, then the printed model number,
    /// then the internal model code.
    static func displayName(productCode: Int? = nil, modelNumber: String?, modelCode: UInt32?) -> String? {
        if let code = productCode, let name = productName(code: code) { return name }
        if let number = modelNumber, let name = productName(modelNumber: number) { return name }
        if let code = modelCode { return model(code: code) }
        return nil
    }

    /// The product code a Puffco puts in its Bluetooth advertisement (the first digits printed on the
    /// bottom, e.g. 71 for "071794"). `manufacturerData` is iOS's raw value: a 2-byte company ID, then
    /// [version, connectability, productCode, battery…]. Version 0 broadcasts (6 bytes) carry no code.
    /// Layout from the official app's parseBroadcastedData / parseProductCode.
    static func productCode(fromManufacturerData data: [UInt8]) -> Int? {
        guard data.count > 2 else { return nil }
        let payload = Array(data.dropFirst(2))
        if payload.count == 6 && payload[0] >> 4 == 0 { return nil }
        guard payload.count >= 3, payload[0] == 1 || payload[0] == 2 else { return nil }
        return Int(payload[2])
    }

    /// Product code as printed on the device: three digits, e.g. "071".
    static func productCodeText(_ code: Int) -> String {
        String(format: "%03d", code)
    }

    /// Internal model code (/p/sys/hw/mdcd) → name, from PuffcoBLE's table. Fallback only.
    static func model(code: UInt32) -> String? {
        switch code {
        case 0, 21: return "Peak Pro (OG)"
        case 1, 22: return "Peak Pro Opal"
        case 2, 25: return "Peak Pro Indiglow"
        case 4, 26: return "Peak Pro Guardian"
        case 12: return "Peak Pro Pearl"
        case 13: return "Peak Pro Onyx"
        case 15: return "Peak Pro Desert"
        case 17: return "Peak Pro Flourish"
        case 19: return "Peak Pro Storm"
        case 23: return "Peak Pro Daybreak"
        default: return nil
        }
    }
}
