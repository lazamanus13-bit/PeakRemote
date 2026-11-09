import Foundation

/// Multi-color lighting.
///
/// The Peak's 8-byte color can point at a color list instead of holding one color:
///   [brightness, speed, lumaAnim, 1, pllNum, pllDenom, (offsetIndex << 4) | colorIndex, colorCount]
///   where index 0-7 are the firmware's own lists and 8-15 are user lists 0-7 (index = 8 + slot).
/// - Color lists live in /u/app/led/ca/0...7 as [R, G, B, 0] per entry (up to 32 entries).
/// - Offset lists live in /u/app/led/oa/0...7 as 20 little-endian uint32 values, one per LED:
///   where in the color loop that LED starts, in 1/4096ths of a list entry.
/// - Speed is cycles per minute / 3; 0 holds the colors still.
/// Layout learned from the official app's codecs; the patterns and blending below are our own.

enum LightPattern: String, CaseIterable, Identifiable, Codable {
    case fade
    case wave
    case gradient

    var id: String { rawValue }

    var name: String {
        switch self {
        case .fade: return "Fade"
        case .wave: return "Wave"
        case .gradient: return "Gradient"
        }
    }

    var detail: String {
        switch self {
        case .fade: return "All lights move through your colors together."
        case .wave: return "Your colors flow across the lights."
        case .gradient: return "Your colors spread across the Peak and hold still."
        }
    }

    var moves: Bool { self != .gradient }
}

struct MultiColorLook: Equatable, Codable {
    static let maxColors = 6           // 6 colors x 5 blend steps = 30 entries (limit 32)
    static let stepsPerColor = 5
    static let ledCount = 20
    static let usedLeds = 16           // the last 4 offset entries are unused on Peak Pro

    var colors: [RGB]
    var pattern: LightPattern = .fade
    /// 0...1; mapped to cycles per minute on a curve so slow speeds are easy to pick.
    var speed: Double = 0.4

    static let `default` = MultiColorLook(
        colors: [RGB(r: 255, g: 60, b: 0), RGB(r: 255, g: 0, b: 140), RGB(r: 80, g: 0, b: 255)]
    )

    var entryCount: Int { colors.count * Self.stepsPerColor }

    /// Speed byte for the device (cycles per minute / 3).
    var speedByte: UInt8 {
        guard pattern.moves else { return 0 }
        let cyclesPerMinute = pow(max(0.05, min(1, speed)), 2) * 240
        return UInt8(max(1, min(255, (cyclesPerMinute / 3).rounded())))
    }

    /// The blended color loop: `stepsPerColor` entries per color, wrapping smoothly back to the first.
    func blendedColors() -> [RGB] {
        let n = colors.count
        guard n > 1 else { return Array(repeating: colors.first ?? RGB(r: 255, g: 255, b: 255), count: Self.stepsPerColor) }
        return (0..<entryCount).map { i in
            let position = Double(i) / Double(Self.stepsPerColor)
            let index = Int(position)
            let t = position - Double(index)
            let eased = t * t * (3 - 2 * t)
            return Self.mix(colors[index % n], colors[(index + 1) % n], eased)
        }
    }

    /// Color list file: [R, G, B, 0] per entry.
    func colorListBytes() -> [UInt8] {
        blendedColors().flatMap { [$0.r, $0.g, $0.b, 0] }
    }

    /// Offset list file: 20 little-endian uint32 values.
    func offsetListBytes() -> [UInt8] {
        let loop = Double(entryCount) * 4096 // one full trip around the color loop
        let values: [UInt32] = (0..<Self.ledCount).map { led in
            guard pattern != .fade, led < Self.usedLeds else { return 0 }
            let fraction = Double(led) / Double(Self.usedLeds)
            return UInt32((fraction * loop).rounded())
        }
        return values.flatMap { Encode.uint32($0) }
    }

    /// The 8-byte color that points the Peak at the user color and offset lists in `slot` (0-7).
    func pointerBytes(slot: UInt8, brightness: UInt8 = 255) -> [UInt8] {
        let count = UInt8(entryCount)
        let phaseLockDenominator: UInt8 = speedByte > 0 ? 0 : 1
        let index = MultiColorSlot.userListOffset + (slot & 0x07)
        return [brightness, speedByte, 0, 1, 0, phaseLockDenominator, (index << 4) | index, count < 32 ? count : 0]
    }

    /// Blends in linear light so mixes stay bright instead of turning muddy.
    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        func toLinear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func toByte(_ l: Double) -> UInt8 {
            let c = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
            return UInt8(max(0, min(255, (c * 255).rounded())))
        }
        func channel(_ x: UInt8, _ y: UInt8) -> UInt8 {
            toByte(toLinear(x) * (1 - t) + toLinear(y) * t)
        }
        return RGB(r: channel(a.r, b.r), g: channel(a.g, b.g), b: channel(a.b, b.b))
    }
}

enum MultiColorSlot {
    /// Pointer indices 8-15 address user lists 0-7 (the official app's NVM user-array offset).
    static let userListOffset: UInt8 = 8
    /// Same slots the official app uses: profiles 1-4, lantern 5 (0 and 6 are its temporary/alternate slots).
    static func profile(_ index: Int) -> UInt8 { UInt8(index + 1) }
    static let lantern: UInt8 = 5
    /// Unused by the official app, so previews never overwrite a saved look.
    static let preview: UInt8 = 7
    /// Studio curve runs use slot 0, the official app's temporary slot, so saved looks stay untouched.
    static let curve: UInt8 = 0
}

extension PeakColor {
    /// True when an 8-byte color file points at a color list instead of holding one color.
    static func isMultiColor(_ bytes: [UInt8]) -> Bool {
        PeakColorFormat.detect(bytes) == .api2 && bytes[3] == 1
    }
}
