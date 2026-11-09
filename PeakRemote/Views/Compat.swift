import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iOS 15 fallbacks for the few iOS 16 features the app uses.
extension View {
    /// Half-height sheet that can be pulled up to full height (iOS 16); a normal sheet on iOS 15.
    @ViewBuilder
    func halfSheet() -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.medium, .large])
        } else {
            self
        }
    }

    /// Digits that roll as the number changes (iOS 16); a plain change on iOS 15.
    @ViewBuilder
    func rollingDigits() -> some View {
        if #available(iOS 16.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }

    /// Lets a dashboard tile be picked up and dragged while arranging.
    @ViewBuilder
    func tileDrag(_ tile: DashboardTile) -> some View {
        if #available(iOS 16.0, *) {
            draggable(tile.rawValue) {
                ArrangeableTile(tile: tile, isTargeted: true).frame(width: 280)
            }
        } else {
            onDrag { NSItemProvider(object: tile.rawValue as NSString) }
        }
    }

    /// Accepts a dragged dashboard tile.
    @ViewBuilder
    func tileDrop(perform: @escaping (DashboardTile) -> Bool, isTargeted: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 16.0, *) {
            dropDestination(for: String.self) { items, _ in
                guard let tile = items.first.flatMap(DashboardTile.init(rawValue:)) else { return false }
                return perform(tile)
            } isTargeted: { over in
                isTargeted(over)
            }
        } else {
            onDrop(of: [UTType.plainText, UTType.utf8PlainText],
                   delegate: TileDropDelegate(perform: perform, isTargeted: isTargeted))
        }
    }
}

/// iOS 15 drop handling for dashboard tiles.
private struct TileDropDelegate: DropDelegate {
    let perform: (DashboardTile) -> Bool
    let isTargeted: (Bool) -> Void

    func dropEntered(info: DropInfo) { isTargeted(true) }
    func dropExited(info: DropInfo) { isTargeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted(false)
        guard let provider = info.itemProviders(for: [UTType.plainText, UTType.utf8PlainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, let tile = DashboardTile(rawValue: text as String) else { return }
            DispatchQueue.main.async { _ = perform(tile) }
        }
        return true
    }
}

/// "Share" button for text: ShareLink on iOS 16, the system share sheet on iOS 15.
struct ShareTextButton: View {
    let text: () -> String
    @State private var sharing: String?

    var body: some View {
        if #available(iOS 16.0, *) {
            ShareLink(item: text()) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } else {
            Button {
                sharing = text()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
                ActivityView(items: [sharing ?? ""])
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
