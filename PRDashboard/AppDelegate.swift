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
    var jiraSetupWindow: NSWindow?
    var jiraSetupCoordinator: JiraSetupCoordinator?
    var presentationCoordinator: AppPresentationCoordinator?
    private var jiraClient: JiraAPIClient?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Create OAuth manager (loads saved auth automatically)
        oauthManager = GitHubOAuthManager()

        // 2. Create notification manager and request permission
        notificationManager = NotificationManager()
        let jiraClient = JiraAPIClient()
        self.jiraClient = jiraClient
        // 3. Create API client
        let apiClient = GitHubAPIClient(token: oauthManager?.authState.accessToken ?? "")

        // 4. Create PR manager
        prManager = PRManager(
            apiClient: apiClient,
            jiraClient: jiraClient,
            notificationManager: notificationManager!,
            oauthManager: oauthManager!,
            cmuxStatusProvider: CmuxBrowserRouter()
        )
        updateManager = UpdateManager(configuration: prManager!.configuration)
        updateManager?.onRequestPresentation = { [weak self] in
            self?.openUpdateWindow()
        }
        prLinkOpener = PRLinkOpener(configurationProvider: { [weak self] in
            self?.prManager?.configuration ?? .default
        })
        notificationManager?.openURL = { [weak self] url in
            Task { @MainActor in
                await self?.prLinkOpener?.open(url)
            }
        }

        // 4.1 Load cached PR data for immediate display
        // 5. Create view model
        let viewModel = PRListViewModel(
            prManager: prManager!,
            oauthManager: oauthManager!,
            linkOpener: prLinkOpener!
        )
        onboardingManager = OnboardingManager()

        presentationCoordinator = AppPresentationCoordinator { [weak self, weak viewModel] presentation in
            guard let self, let viewModel else { return }
            switch presentation {
            case .settings:
                self.openSettingsWindow(viewModel: viewModel)
            case .jiraSetup(let context):
                self.openJiraSetupWindow(context: context, viewModel: viewModel)
            }
        }

        viewModel.openSettings = { [weak self] in
            self?.presentationCoordinator?.present(.settings)
        }

        // 6. Create main view
        let mainView = MainView(
            viewModel: viewModel,
            onboardingManager: onboardingManager!,
            presentationCoordinator: presentationCoordinator
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

        // Observe PR list changes to update menu bar notification badge
        prManager?.$prList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prList in
                self?.statusBarController?.updateBadge(count: prList.menuNotificationCount)
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
    private func openJiraSetupWindow(context: JiraSetupContext, viewModel: PRListViewModel) {
        if let jiraSetupWindow {
            jiraSetupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let jiraClient else { return }
        let config = viewModel.configuration
        let initialServerURL = context.initialServerURL ?? config.jiraServerURL
        let coordinator = JiraSetupCoordinator(
            context: context,
            connectionState: viewModel.jiraConnectionState,
            savedServerURL: initialServerURL,
            savedEmail: config.jiraEmail,
            savedTokenAvailable: !Keychain.loadJiraAPIToken().isEmpty,
            testConnection: { serverURL, email, token in
                try await jiraClient.testConnection(serverURL: serverURL, email: email, apiToken: token)
            },
            commit: { [weak viewModel] serverURL, email, token in
                viewModel?.updateJiraCredentials(
                    serverURL: serverURL,
                    email: email,
                    apiToken: token,
                    refreshInterval: viewModel?.configuration.jiraRefreshInterval ?? 1800
                )
            },
            openExternalURL: { url in
                NSWorkspace.shared.open(url)
            },
            dismiss: { [weak self] in
                self?.jiraSetupWindow?.close()
                self?.jiraSetupWindow = nil
                self?.jiraSetupCoordinator = nil
            }
        )
        jiraSetupCoordinator = coordinator
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: JiraSetupView(coordinator: coordinator))
        )
        window.title = String(localized: "Connect Jira")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 360))
        window.center()
        window.isReleasedWhenClosed = false
        jiraSetupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettingsWindow(viewModel: PRListViewModel) {
        guard let onboardingManager, let updateManager else { return }

        if settingsWindow == nil {
            let settingsView = SettingsView(
                viewModel: viewModel,
                onboardingManager: onboardingManager,
                updateManager: updateManager,
                presentationCoordinator: presentationCoordinator
            )
            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Settings")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 450, height: 620))
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
                minimumApprovalsForReadyToMerge: prManager?.configuration.minimumApprovalsForReadyToMerge ??
                    Configuration.default.minimumApprovalsForReadyToMerge,
                refreshStatus: refreshStatus,
                refreshError: refreshError
            )
        )
    }

    private static func appInfoValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }
}
