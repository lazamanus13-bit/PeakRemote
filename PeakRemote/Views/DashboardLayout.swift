import SwiftUI

/// The movable tiles on the device screen.
enum DashboardTile: String, CaseIterable, Identifiable {
    case studio
    case profiles
    case readyMode
    case lights
    case stats
    case battery
    case device

    var id: String { rawValue }

    var name: String {
        switch self {
        case .studio: return "Studio"
        case .profiles: return "Profiles"
        case .readyMode: return "Ready Mode"
        case .lights: return "Lights"
        case .stats: return "Stats"
        case .battery: return "Battery"
        case .device: return "Device"
        }
    }

    var icon: String {
        switch self {
        case .studio: return "waveform.path.ecg"
        case .profiles: return "square.grid.2x2"
        case .readyMode: return "bolt.circle"
        case .lights: return "lightbulb"
        case .stats: return "chart.bar"
        case .battery: return "battery.75percent"
        case .device: return "info.circle"
        }
    }
}

/// Which tiles go in which column, in order. Saved as text like "lights,stats|profiles,battery".
struct TileLayout: Equatable {
    /// Under the temperature dial (iPad) / first on iPhone.
    var left: [DashboardTile]
    /// The second column (iPad) / after the left tiles on iPhone.
    var right: [DashboardTile]

    static let `default` = TileLayout(left: [], right: [.studio, .profiles, .readyMode, .lights, .stats, .battery, .device])

    /// Parses saved text; unknown names are dropped and any missing tiles are added to the right column.
    init(raw: String) {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            self.init(left: TileLayout.default.left, right: TileLayout.default.right)
            return
        }
        func tiles(_ s: String) -> [DashboardTile] {
            s.split(separator: ",").compactMap { DashboardTile(rawValue: String($0)) }
        }
        var seen = Set<DashboardTile>()
        let l = tiles(parts[0]).filter { seen.insert($0).inserted }
        let r = tiles(parts[1]).filter { seen.insert($0).inserted }
        let missing = DashboardTile.allCases.filter { !seen.contains($0) }
        self.init(left: l, right: r + missing)
    }

    init(left: [DashboardTile], right: [DashboardTile]) {
        self.left = left
        self.right = right
    }

    var raw: String {
        left.map(\.rawValue).joined(separator: ",") + "|" + right.map(\.rawValue).joined(separator: ",")
    }

    var all: [DashboardTile] { left + right }
}

enum TileColumn {
    case left
    case right
}

extension TileLayout {
    /// Moves `tile` so it sits just before `target`, in whichever column `target` is in.
    func moving(_ tile: DashboardTile, before target: DashboardTile) -> TileLayout {
        guard tile != target else { return self }
        var next = removing(tile)
        if let i = next.left.firstIndex(of: target) {
            next.left.insert(tile, at: i)
        } else if let i = next.right.firstIndex(of: target) {
            next.right.insert(tile, at: i)
        } else {
            next.right.append(tile)
        }
        return next
    }

    /// Moves `tile` to the end of `column`.
    func moving(_ tile: DashboardTile, toEndOf column: TileColumn) -> TileLayout {
        var next = removing(tile)
        switch column {
        case .left: next.left.append(tile)
        case .right: next.right.append(tile)
        }
        return next
    }

    private func removing(_ tile: DashboardTile) -> TileLayout {
        TileLayout(left: left.filter { $0 != tile }, right: right.filter { $0 != tile })
    }
}

/// A tile while the layout is being edited: a compact bar you can drag onto another tile or a drop zone.
struct ArrangeableTile: View {
    let tile: DashboardTile
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tile.icon)
                .frame(width: 24)
                .foregroundStyle(.orange)
            Text(tile.name)
                .font(.headline)
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isTargeted ? Color.orange : Color.white.opacity(0.15),
                        style: StrokeStyle(lineWidth: isTargeted ? 3 : 1, dash: isTargeted ? [] : [6, 4]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// The empty slot at the bottom of a column while editing.
struct TileDropZone: View {
    let isTargeted: Bool

    var body: some View {
        Text("Drop here")
            .font(.subheadline)
            .foregroundStyle(isTargeted ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isTargeted ? Color.orange : Color.secondary.opacity(0.5),
                            style: StrokeStyle(lineWidth: isTargeted ? 3 : 1, dash: [6, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
