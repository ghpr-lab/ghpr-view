import Cocoa
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var oauthManager: GitHubOAuthManager?
    var prManager: PRManager?
    var notificationManager: NotificationManager?
    var prLinkOpener: PRLinkOpener?
    var onboardingManager: OnboardingManager?
    var updateManager: UpdateManager?
    var localSocketServer: LocalSocketServer?
    var settingsWindow: NSWindow?
    var updateWindow: NSWindow?

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
        prLinkOpener = PRLinkOpener(configurationProvider: { [weak self] in
            self?.prManager?.configuration ?? .default
        })
        notificationManager?.openURL = { [weak self] url in
            self?.prLinkOpener?.open(url)
        }

        // 4.1 Load cached PR data for immediate display
        prManager?.loadCachedData()

        // 5. Create view model
        let viewModel = PRListViewModel(
            prManager: prManager!,
            oauthManager: oauthManager!,
            linkOpener: prLinkOpener!
        )
        onboardingManager = OnboardingManager()

        // Wire up settings window callback
        viewModel.openSettings = { [weak self] in
            self?.openSettingsWindow(viewModel: viewModel)
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

        localSocketServer = LocalSocketServer { [weak self] in
            AppDelegate.makeLocalSnapshot(
                oauthManager: self?.oauthManager,
                prManager: self?.prManager
            )
        }
        localSocketServer?.start()

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

    func applicationWillTerminate(_ notification: Notification) {
        localSocketServer?.stop()
        localSocketServer = nil
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

    private func checkForUpdates(userInitiated: Bool) {
        if userInitiated {
            openUpdateWindow()
        }

        updateManager?.checkForUpdates(userInitiated: userInitiated)
    }

    private static func makeLocalSnapshot(
        oauthManager: GitHubOAuthManager?,
        prManager: PRManager?
    ) -> LocalSnapshot {
        let refreshStatus: String
        let refreshError: String?
        switch prManager?.refreshState ?? .idle {
        case .idle:
            refreshStatus = "idle"
            refreshError = prManager?.prList.error?.localizedDescription
        case .loading:
            refreshStatus = "loading"
            refreshError = nil
        case .error(let error):
            refreshStatus = "error"
            refreshError = error.localizedDescription
        }

        return LocalSnapshotFactory.makeSnapshot(
            input: LocalSnapshotInput(
                appVersion: appInfoValue("CFBundleShortVersionString"),
                buildVersion: appInfoValue("CFBundleVersion"),
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
                authState: oauthManager?.authState ?? .empty,
                prList: prManager?.prList ?? .empty,
                rateLimitInfo: prManager?.rateLimitInfo ?? .empty,
                pinnedPRIdentifiers: prManager?.pinnedPRIdentifiers ?? [],
                refreshStatus: refreshStatus,
                refreshError: refreshError
            )
        )
    }

    private static func appInfoValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }
}
