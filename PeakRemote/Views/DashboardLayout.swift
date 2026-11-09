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

/// Drag tiles to reorder them; tiles above the "Right column" divider go in the left column.
struct ArrangeTilesSheet: View {
    @Binding var raw: String
    let twoColumns: Bool
    @Environment(\.dismiss) private var dismiss

    private enum Row: Hashable, Identifiable {
        case tile(DashboardTile)
        case divider
        var id: String {
            switch self {
            case .tile(let t): return t.rawValue
            case .divider: return "|divider"
            }
        }
    }

    @State private var rows: [Row] = []

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                    .onMove { from, to in
                        rows.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                } header: {
                    Text(twoColumns ? "Left column (under the dial)" : "Order")
                } footer: {
                    Text(twoColumns
                         ? "Drag tiles by their handles. Tiles above the divider go in the left column, tiles below it in the right column."
                         : "Drag tiles by their handles to change their order. On iPad, tiles above the divider go in the left column, under the temperature dial.")
                }
                Section {
                    Button("Reset to default") {
                        load(TileLayout.default)
                        save()
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Arrange tiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { load(TileLayout(raw: raw)) }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .tile(let tile):
            Label(tile.name, systemImage: tile.icon)
        case .divider:
            HStack {
                Image(systemName: "rectangle.split.2x1")
                Text("Right column")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.orange)
        }
    }

    private func load(_ layout: TileLayout) {
        rows = layout.left.map(Row.tile) + [.divider] + layout.right.map(Row.tile)
    }

    private func save() {
        guard let split = rows.firstIndex(of: .divider) else { return }
        func tiles(_ slice: ArraySlice<Row>) -> [DashboardTile] {
            slice.compactMap { if case .tile(let t) = $0 { return t } else { return nil } }
        }
        raw = TileLayout(left: tiles(rows[..<split]), right: tiles(rows[(split + 1)...])).raw
    }
}
