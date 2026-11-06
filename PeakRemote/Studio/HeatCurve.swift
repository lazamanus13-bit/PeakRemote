import Foundation

/// A heat curve: target temperature over time during one session.
/// Studio mode is based on puff-studio by SoyMilkIsOk (MIT): https://github.com/SoyMilkIsOk/puff-studio
struct HeatCurve: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var detail: String = ""
    var points: [CurvePoint]
    var isPreset = false

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
    private static func preset(_ name: String, _ detail: String, _ pts: [(Double, Double)]) -> HeatCurve {
        HeatCurve(name: name, detail: detail, points: pts.map { CurvePoint(time: $0.0, tempF: $0.1) }, isPreset: true)
    }

    /// Preset curves from puff-studio's curves.json (MIT).
    static let presets: [HeatCurve] = [
        preset("Step Down", "Three steps from hot to mellow.",
               [(0, 535), (15, 535), (18, 485), (35, 485), (45, 430), (60, 430)]),
        preset("Decay", "Hot start for thick vapor, cooling as the dab thins out.",
               [(0, 535), (12, 525), (30, 475), (55, 436)]),
        preset("Linear", "A smooth, steady ramp down.",
               [(0, 535), (60, 420)]),
        preset("Dwell", "A long low plateau for delicate concentrates.",
               [(0, 490), (20, 490), (25, 460), (60, 460)]),
        preset("Temp Burst", "Steady 480°F with a hot finish.",
               [(0, 480), (38, 480), (42, 535), (55, 535)]),
    ]
}

/// Saved custom curves (stored on this device only).
enum CurveStore {
    private static let key = "studioCustomCurves"

    static func load() -> [HeatCurve] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let curves = try? JSONDecoder().decode([HeatCurve].self, from: data) else { return [] }
        return curves
    }

    static func save(_ curves: [HeatCurve]) {
        if let data = try? JSONEncoder().encode(curves) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
