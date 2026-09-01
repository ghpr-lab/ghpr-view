import SwiftUI

@main
struct PRDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-testing-browser-") }) {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
