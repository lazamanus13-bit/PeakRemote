import Foundation

/// A heat curve: target temperature over time during one session.
/// Studio mode is based on puff-studio by SoyMilkIsOk (MIT): https://github.com/SoyMilkIsOk/puff-studio
struct HeatCurve: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var detail: String = ""
    var points: [CurvePoint]
    var isPreset = false
    /// Light color shown on the Peak while this curve runs (nil = leave the lights alone).
    var color: RGB?
    var effect: LightEffect?
    /// Multiple colors shown while this curve runs (takes the place of `color`).
    var multi: MultiColorLook?

    var hasLights: Bool { color != nil || multi != nil }

    /// Limits for curve points (°F); the runner clamps targets again before sending them.
    static let tempRangeF: ClosedRange<Double> = 400...580
    static let timeRange: ClosedRange<Double> = 0...120
    static let minDuration: Double = 15

    var duration: Double {
        max(Self.minDuration, min(Self.timeRange.upperBound, points.map(\.time).max() ?? Self.minDuration))
    }

    var startTempF: Double { temp(at: 0) }

    /// Straight-line interpolation between points, held flat before the first and after the last.
    func temp(at time: Double) -> Double {
        let sorted = points.sorted { $0.time < $1.time }
        guard let first = sorted.first, let last = sorted.last else { return 480 }
        if time <= first.time { return first.tempF }
        if time >= last.time { return last.tempF }
        for (a, b) in zip(sorted, sorted.dropFirst()) where time >= a.time && time <= b.time {
            let span = b.time - a.time
            guard span > 0 else { return b.tempF }
            return a.tempF + (b.tempF - a.tempF) * (time - a.time) / span
        }
        return last.tempF
    }

    /// Clamps every point into the allowed ranges and keeps them in time order.
    func sanitized() -> HeatCurve {
        var copy = self
        copy.points = points
            .map { CurvePoint(time: min(max($0.time, Self.timeRange.lowerBound), Self.timeRange.upperBound),
                              tempF: min(max($0.tempF, Self.tempRangeF.lowerBound), Self.tempRangeF.upperBound)) }
            .sorted { $0.time < $1.time }
        return copy
    }
}

struct CurvePoint: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var tempF: Double

    init(time: Double, tempF: Double) {
        self.time = time
        self.tempF = tempF
    }
}

extension HeatCurve {
    /// Presets get fixed IDs so edits to them can be saved and matched up again.
    private static func preset(_ id: String, _ name: String, _ detail: String, _ pts: [(Double, Double)]) -> HeatCurve {
        HeatCurve(id: UUID(uuidString: id) ?? UUID(), name: name, detail: detail,
                  points: pts.map { CurvePoint(time: $0.0, tempF: $0.1) }, isPreset: true)
    }

    /// Preset curves from puff-studio's curves.json (MIT).
    static let presets: [HeatCurve] = [
        preset("00000000-0000-0000-0000-00000000C001", "Step Down", "Three steps from hot to mellow.",
               [(0, 535), (15, 535), (18, 485), (35, 485), (45, 430), (60, 430)]),
        preset("00000000-0000-0000-0000-00000000C002", "Decay", "Hot start for thick vapor, cooling as the dab thins out.",
               [(0, 535), (12, 525), (30, 475), (55, 436)]),
        preset("00000000-0000-0000-0000-00000000C003", "Linear", "A smooth, steady ramp down.",
               [(0, 535), (60, 420)]),
        preset("00000000-0000-0000-0000-00000000C004", "Dwell", "A long low plateau for delicate concentrates.",
               [(0, 490), (20, 490), (25, 460), (60, 460)]),
        preset("00000000-0000-0000-0000-00000000C005", "Temp Burst", "Steady 480°F with a hot finish.",
               [(0, 480), (38, 480), (42, 535), (55, 535)]),
    ]
}

/// Saved curves (stored on this device only): your own curves, plus your edits to the presets.
enum CurveStore {
    private static let customKey = "studioCustomCurves"
    private static let presetEditsKey = "studioPresetEdits"

    static func load() -> [HeatCurve] { read(customKey) }
    static func save(_ curves: [HeatCurve]) { write(curves, customKey) }

    static func loadPresetEdits() -> [HeatCurve] { read(presetEditsKey) }
    static func savePresetEdits(_ curves: [HeatCurve]) { write(curves, presetEditsKey) }

    /// The presets, with any of your edits swapped in.
    static func presets(with edits: [HeatCurve]) -> [HeatCurve] {
        HeatCurve.presets.map { preset in edits.first { $0.id == preset.id } ?? preset }
    }

    private static func read(_ key: String) -> [HeatCurve] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let curves = try? JSONDecoder().decode([HeatCurve].self, from: data) else { return [] }
        return curves
    }

    private static func write(_ curves: [HeatCurve], _ key: String) {
        if let data = try? JSONEncoder().encode(curves) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
