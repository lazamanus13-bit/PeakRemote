import Foundation

/// Minimal CBOR (RFC 8949) support: enough for the Peak's color files,
/// e.g. {"lamp": {"name": "solid", "param": {"color": h'ff0000'}}}.
indirect enum CBOR: Equatable {
    case uint(UInt64)
    case negative(Int64)
    case bytes([UInt8])
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case bool(Bool)
    case null
    case double(Double)

    static func == (lhs: CBOR, rhs: CBOR) -> Bool {
        lhs.encoded() == rhs.encoded()
    }

    // MARK: Encoding (canonical: map keys sorted by encoded length, then bytes)

    func encoded() -> [UInt8] {
        switch self {
        case .uint(let v): return Self.head(0, v)
        case .negative(let v): return Self.head(1, UInt64(-1 - v))
        case .bytes(let b): return Self.head(2, UInt64(b.count)) + b
        case .text(let s):
            let u = Array(s.utf8)
            return Self.head(3, UInt64(u.count)) + u
        case .array(let items):
            return Self.head(4, UInt64(items.count)) + items.flatMap { $0.encoded() }
        case .map(let pairs):
            let encodedPairs = pairs.map { ($0.0.encoded(), $0.1.encoded()) }
                .sorted { a, b in
                    a.0.count != b.0.count ? a.0.count < b.0.count : a.0.lexicographicallyPrecedes(b.0)
                }
            return Self.head(5, UInt64(pairs.count)) + encodedPairs.flatMap { $0.0 + $0.1 }
        case .bool(let b): return [b ? 0xF5 : 0xF4]
        case .null: return [0xF6]
        case .double(let d):
            return [0xFB] + withUnsafeBytes(of: d.bitPattern.bigEndian) { Array($0) }
        }
    }

    private static func head(_ major: UInt8, _ value: UInt64) -> [UInt8] {
        let m = major << 5
        switch value {
        case 0..<24: return [m | UInt8(value)]
        case 24..<0x100: return [m | 24, UInt8(value)]
        case 0x100..<0x10000: return [m | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
        case 0x10000..<0x1_0000_0000:
            return [m | 26] + (0..<4).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
        default:
            return [m | 27] + (0..<8).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
        }
    }

    // MARK: Decoding

    static func decode(_ bytes: [UInt8]) -> CBOR? {
        var i = 0
        return decodeItem(bytes, &i)
    }

    private static func readUInt(_ b: [UInt8], _ i: inout Int, _ info: UInt8) -> UInt64? {
        switch info {
        case 0..<24: return UInt64(info)
        case 24, 25, 26, 27:
            let n = 1 << Int(info - 24)
            guard i + n <= b.count else { return nil }
            var v: UInt64 = 0
            for k in 0..<n { v = (v << 8) | UInt64(b[i + k]) }
            i += n
            return v
        default: return nil
        }
    }

    private static func decodeItem(_ b: [UInt8], _ i: inout Int) -> CBOR? {
        guard i < b.count else { return nil }
        let first = b[i]; i += 1
        let major = first >> 5, info = first & 0x1F
        switch major {
        case 0: return readUInt(b, &i, info).map { .uint($0) }
        case 1: return readUInt(b, &i, info).map { .negative(-1 - Int64($0)) }
        case 2, 3:
            guard let n = readUInt(b, &i, info), i + Int(n) <= b.count else { return nil }
            let slice = Array(b[i..<(i + Int(n))]); i += Int(n)
            return major == 2 ? .bytes(slice) : .text(String(decoding: slice, as: UTF8.self))
        case 4:
            guard let n = readUInt(b, &i, info) else { return nil }
            var items: [CBOR] = []
            for _ in 0..<n { guard let item = decodeItem(b, &i) else { return nil }; items.append(item) }
            return .array(items)
        case 5:
            guard let n = readUInt(b, &i, info) else { return nil }
            var pairs: [(CBOR, CBOR)] = []
            for _ in 0..<n {
                guard let k = decodeItem(b, &i), let v = decodeItem(b, &i) else { return nil }
                pairs.append((k, v))
            }
            return .map(pairs)
        case 6: return decodeItem(b, &i) // ignore tags
        case 7:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22, 23: return .null
            case 25:
                guard i + 2 <= b.count else { return nil }
                let h = UInt16(b[i]) << 8 | UInt16(b[i + 1]); i += 2
                return .double(Double(Float16Bits.toFloat(h)))
            case 26:
                guard i + 4 <= b.count else { return nil }
                let bits = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(b[i + $1]) }; i += 4
                return .double(Double(Float(bitPattern: bits)))
            case 27:
                guard i + 8 <= b.count else { return nil }
                let bits = (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[i + $1]) }; i += 8
                return .double(Double(bitPattern: bits))
            default: return .null
            }
        default: return nil
        }
    }

    /// Finds the first value stored under `key` anywhere in the tree.
    func find(_ key: String) -> CBOR? {
        switch self {
        case .map(let pairs):
            for (k, v) in pairs {
                if case .text(let s) = k, s == key { return v }
            }
            for (_, v) in pairs { if let hit = v.find(key) { return hit } }
            return nil
        case .array(let items):
            for item in items { if let hit = item.find(key) { return hit } }
            return nil
        default:
            return nil
        }
    }
}

/// Half-precision float decoding without relying on Float16 (unavailable on some targets).
enum Float16Bits {
    static func toFloat(_ h: UInt16) -> Float {
        let sign: Float = (h & 0x8000) != 0 ? -1 : 1
        let exp = Int((h >> 10) & 0x1F)
        let frac = Float(h & 0x3FF)
        if exp == 0 { return sign * frac * pow(2, -24) }
        if exp == 31 { return frac == 0 ? sign * .infinity : .nan }
        return sign * (1 + frac / 1024) * pow(2, Float(exp - 15))
    }
}

/// Peak LED color files.
enum PeakColor {
    /// The payload the official app and PuffcoBLE use for a single solid color.
    static func solidPayload(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        CBOR.map([
            (.text("lamp"), .map([
                (.text("name"), .text("solid")),
                (.text("param"), .map([(.text("color"), .bytes([r, g, b]))])),
            ])),
        ]).encoded()
    }

    /// First RGB color found in a color file, if any.
    static func firstColor(in bytes: [UInt8]) -> (UInt8, UInt8, UInt8)? {
        guard let root = CBOR.decode(bytes) else { return nil }
        if case .bytes(let c)? = root.find("color"), c.count >= 3 { return (c[0], c[1], c[2]) }
        if case .array(let arr)? = root.find("color"), case .bytes(let c)? = arr.first, c.count >= 3 {
            return (c[0], c[1], c[2])
        }
        return nil
    }
}
