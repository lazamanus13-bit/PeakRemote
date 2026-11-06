import SwiftUI

@main
struct PeakRemoteApp: App {
    @StateObject private var controller = PuffcoController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                .preferredColorScheme(.dark)
                .tint(.orange)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var controller: PuffcoController

    var body: some View {
        NavigationStack {
            if controller.phase.isInSession {
                DeviceView()
            } else {
                ScanView()
            }
        }
    }
}
