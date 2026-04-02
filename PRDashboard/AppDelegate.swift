import Cocoa
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var oauthManager: GitHubOAuthManager?
    var prManager: PRManager?
    var notificationManager: NotificationManager?
    var settingsWindow: NSWindow?

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Create OAuth manager (loads saved auth automatically)
        oauthManager = GitHubOAuthManager()

        // 2. Create notification manager and request permission
        notificationManager = NotificationManager()

        // 3. Create API client
        let apiClient = GitHubAPIClient(token: oauthManager?.authState.accessToken ?? "")

        // 4. Create PR manager
        prManager = PRManager(
            apiClient: apiClient,
            notificationManager: notificationManager!,
            oauthManager: oauthManager!
        )

        // 4.1 Load cached PR data for immediate display
        prManager?.loadCachedData()

        // 5. Create view model
        let viewModel = PRListViewModel(prManager: prManager!, oauthManager: oauthManager!)

        // Wire up settings window callback
        viewModel.openSettings = { [weak self] in
            self?.openSettingsWindow(viewModel: viewModel)
        }

        // 6. Create main view
        let mainView = MainView(viewModel: viewModel)

        // 7. Create popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: mainView)

        // 8. Create status bar controller
        statusBarController = StatusBarController(popover: popover, prManager: prManager!)

        // 9. Observe PR list changes to update badge (authored PRs only)
        prManager?.$prList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prList in
                self?.statusBarController?.updateBadge(count: prList.authoredUnresolvedCount)
            }
            .store(in: &cancellables)

        // 10. Request notification permission if authenticated
        if oauthManager?.authState.isAuthenticated == true {
            notificationManager?.requestPermission()
        }

        // 11. Request notification permission after sign-in
        oauthManager?.$authState
            .dropFirst()  // Skip initial value
            .filter { $0.isAuthenticated }
            .sink { [weak self] _ in
                self?.notificationManager?.requestPermission()
            }
            .store(in: &cancellables)
    }

    private func openSettingsWindow(viewModel: PRListViewModel) {
        if settingsWindow == nil {
            let settingsView = SettingsView(viewModel: viewModel)
            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 450, height: 450))
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
