import Cocoa
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var oauthManager: GitHubOAuthManager?
    var prManager: PRManager?
    var notificationManager: NotificationManager?
    var onboardingManager: OnboardingManager?
    var updateManager: UpdateManager?
    var settingsWindow: NSWindow?
    var updateWindow: NSWindow?
    var flakyCIBotReportWindow: NSWindow?
    var flakyCIBotReportViewModel: FlakyCIBotReportViewModel?

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
        updateManager = UpdateManager(configuration: prManager!.configuration)
        updateManager?.onRequestPresentation = { [weak self] in
            self?.openUpdateWindow()
        }

        // 4.1 Load cached PR data for immediate display
        prManager?.loadCachedData()

        // 5. Create view model
        let viewModel = PRListViewModel(prManager: prManager!, oauthManager: oauthManager!)
        onboardingManager = OnboardingManager()

        // Wire up settings window callback
        viewModel.openSettings = { [weak self] in
            self?.openSettingsWindow(viewModel: viewModel)
        }
        viewModel.openFlakyCIBotReport = { [weak self] context, launchMode in
            self?.openFlakyCIBotReport(context: context, launchMode: launchMode)
        }

        // 6. Create main view
        let mainView = MainView(
            viewModel: viewModel,
            onboardingManager: onboardingManager!
        )

        // 7. Create popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: mainView)

        // 8. Create status bar controller
        statusBarController = StatusBarController(
            popover: popover,
            prManager: prManager!,
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates(userInitiated: true)
            }
        )

        // 9. Observe PR list changes to update badge (authored PRs only)
        prManager?.$prList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prList in
                self?.statusBarController?.updateBadge(count: prList.authoredUnresolvedCount)
            }
            .store(in: &cancellables)

        prManager?.$configuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configuration in
                self?.updateManager?.updateConfiguration(configuration)
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

        updateManager?.start()
    }

    private func openSettingsWindow(viewModel: PRListViewModel) {
        guard let onboardingManager else { return }

        if settingsWindow == nil {
            let settingsView = SettingsView(
                viewModel: viewModel,
                onboardingManager: onboardingManager
            )
            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Settings")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 450, height: 520))
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openUpdateWindow() {
        guard let updateManager else { return }

        if updateWindow == nil {
            let updateView = UpdateView(updateManager: updateManager)
            let hostingController = NSHostingController(rootView: updateView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Software Update")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 560, height: 520))
            window.center()
            updateWindow = window
        }

        updateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openFlakyCIBotReport(context: FlakyCIBotContext, launchMode: FlakyCIBotLaunchMode) {
        if let flakyCIBotReportViewModel {
            flakyCIBotReportViewModel.update(context: context, launchMode: launchMode)
        } else {
            let viewModel = FlakyCIBotReportViewModel(context: context, launchMode: launchMode)
            let reportView = FlakyCIBotReportView(
                viewModel: viewModel,
                onClose: { [weak self] in
                    self?.flakyCIBotReportWindow?.close()
                }
            )
            let hostingController = NSHostingController(rootView: reportView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Flaky CI Bot")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 340, height: 280))
            window.center()
            window.isReleasedWhenClosed = false

            flakyCIBotReportWindow = window
            flakyCIBotReportViewModel = viewModel
        }

        flakyCIBotReportWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func checkForUpdates(userInitiated: Bool) {
        if userInitiated {
            openUpdateWindow()
        }

        updateManager?.checkForUpdates(userInitiated: userInitiated)
    }
}
