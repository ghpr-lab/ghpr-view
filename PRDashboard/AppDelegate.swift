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
    var extensionPlatformController: ExtensionPlatformController?
    var browserPairingWindow: NSWindow?
    var extensionPlatformUITestWindow: NSWindow?
    private var jiraClient: JiraAPIClient?
    private var cancellables = Set<AnyCancellable>()



    func applicationDidFinishLaunching(_ notification: Notification) {
        let isExtensionPlatformUITest = CommandLine.arguments.contains {
            $0.hasPrefix("--ui-testing-browser-")
        }

        // 1. Create OAuth manager (loads saved auth automatically outside deterministic UI tests)
        oauthManager = GitHubOAuthManager(loadSavedAuth: !isExtensionPlatformUITest)

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
            cmuxStatusProvider: CmuxBrowserRouter(),
            loadKeychainSecrets: !isExtensionPlatformUITest
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

        let isPRActionsUITest = CommandLine.arguments.contains("--ui-testing-browser-pr-actions")
        let extensionPlatformController = ExtensionPlatformController(
            snapshotProvider: { [weak self] in
#if DEBUG
                if isPRActionsUITest {
                    return ExtensionPlatformUITestFixture.snapshot
                }
#endif
                return AppDelegate.makeLocalSnapshot(
                    oauthManager: self?.oauthManager,
                    prManager: self?.prManager
                )
            },
            rerunFailedJobs: { [weak self] snapshot in
                guard let self,
                      let pr = self.prManager?.prList.allPRs.first(where: {
                          $0.repoFullName.caseInsensitiveCompare(snapshot.repository) == .orderedSame &&
                              $0.number == snapshot.number
                      }),
                      let prManager = self.prManager else {
                    throw BrowserBridgeActionError.pullRequestUnavailable
                }
                return try await prManager.rerunFailedCI(for: pr)
            },
            storageURL: isExtensionPlatformUITest ? nil : defaultExtensionPlatformStorageURL(),
            appVersion: Self.appInfoValue("CFBundleShortVersionString"),
            ports: isExtensionPlatformUITest ? [0] : Array(48120...48129)
        )
        self.extensionPlatformController = extensionPlatformController

        // 6. Create main view
        let mainView = MainView(
            viewModel: viewModel,
            onboardingManager: onboardingManager!,
            presentationCoordinator: presentationCoordinator,
            extensionPlatformController: extensionPlatformController
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
        extensionPlatformController.onPendingPairing = { [weak self] approval in
            self?.openBrowserPairingWindow(approval: approval)
        }
        extensionPlatformController.start()

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

        configureExtensionPlatformUITestIfRequested(viewModel: viewModel)
    }

    func applicationWillTerminate(_ notification: Notification) {
        localSocketServer?.stop()
        localSocketServer = nil
        extensionPlatformController?.stop()
        extensionPlatformController = nil
    }
    private func configureExtensionPlatformUITestIfRequested(viewModel: PRListViewModel) {
        guard let extensionPlatformController else { return }
        if CommandLine.arguments.contains("--ui-testing-browser-settings") {
            let descriptor = BrowserClientDescriptor(
                id: "dev.ghpr.ui-test-client",
                name: "UI Test Client",
                version: "1.0.0",
                requestedScopes: [.prRead, .analysisRead]
            )
            if let pairing = try? extensionPlatformController.store.startPairing(
                descriptor: descriptor,
                bridgeBaseURL: URL(string: "http://127.0.0.1:48120")!
            ) {
                _ = try? extensionPlatformController.store.approvePairingFromNative(
                    id: pairing.requestID,
                    approvedScopes: descriptor.requestedScopes
                )
            }
            presentationCoordinator?.present(.settings)
        } else if CommandLine.arguments.contains("--ui-testing-browser-pairing") ||
            CommandLine.arguments.contains("--ui-testing-browser-permission-upgrade") {
            let isUpgrade = CommandLine.arguments.contains("--ui-testing-browser-permission-upgrade")
            let descriptor = BrowserClientDescriptor(
                id: "com.example.team-ci-helper",
                name: "Team CI Helper",
                version: "1.2.0",
                requestedScopes: [
                    .prRead,
                    .analysisRead,
                    .uiContribute,
                    .skillRun
                ],
                requiredScopes: isUpgrade ? [.skillRun] : []
            )
            _ = try? extensionPlatformController.store.startPairing(
                descriptor: descriptor,
                bridgeBaseURL: URL(string: "http://127.0.0.1:48120")!
            )
        }
#if DEBUG
        let hasFailedCI = CommandLine.arguments.contains("--ui-testing-browser-pr-actions")
        let hasPassingCI = CommandLine.arguments.contains("--ui-testing-browser-pr-actions-passing")
        if hasFailedCI || hasPassingCI {
            openExtensionPlatformUITestWindow(
                controller: extensionPlatformController,
                hasFailedCI: hasFailedCI
            )
        }
#endif
    }

#if DEBUG
    private func openExtensionPlatformUITestWindow(
        controller: ExtensionPlatformController,
        hasFailedCI: Bool
    ) {
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: ExtensionPlatformPRActionsUITestView(
                    controller: controller,
                    hasFailedCI: hasFailedCI
                )
            )
        )
        window.title = "PR Actions"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 190))
        window.center()
        extensionPlatformUITestWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
#endif

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
        guard let onboardingManager,
              let updateManager,
              let extensionPlatformController else {
            return
        }

        if settingsWindow == nil {
            let settingsView = SettingsView(
                viewModel: viewModel,
                onboardingManager: onboardingManager,
                updateManager: updateManager,
                extensionPlatformController: extensionPlatformController,
                presentationCoordinator: presentationCoordinator
            )
            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Settings")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 520, height: 720))
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openBrowserPairingWindow(approval: PendingPairingApproval) {
        browserPairingWindow?.close()

        let pairingView = BrowserPairingApprovalView(
            controller: extensionPlatformController!,
            approval: approval
        ) { [weak self] in
            self?.browserPairingWindow?.close()
            self?.browserPairingWindow = nil
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Browser Client Permission")
        window.contentViewController = NSHostingController(rootView: pairingView)
        window.center()
        window.isReleasedWhenClosed = false
        browserPairingWindow = window
        window.makeKeyAndOrderFront(nil)
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

#if DEBUG
private enum ExtensionPlatformUITestFixture {
    static let pullRequest = makePullRequest(hasFailedCI: true)
    static let passingPullRequest = makePullRequest(hasFailedCI: false)

    private static func makePullRequest(hasFailedCI: Bool) -> PullRequest {
        PullRequest(
            id: 1238,
            number: 1238,
            title: hasFailedCI ? "UI fixture failed check" : "UI fixture passing checks",
            author: "octocat",
            authorAvatarURL: nil,
            repositoryOwner: "example-org",
            repositoryName: "example-repo",
            url: URL(string: "https://github.com/example-org/example-repo/pull/1238")!,
            state: .open,
            isDraft: false,
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_775_000_100),
            mergedAt: nil,
            body: nil,
            conversationComments: [],
            lastCommitAt: Date(timeIntervalSince1970: 1_775_000_100),
            headCommitOid: "0123456789abcdef",
            reviewThreads: [],
            category: .authored,
            hasBaseConflicts: false,
            ciStatus: hasFailedCI ? .failure : .success,
            checkSuccessCount: hasFailedCI ? 3 : 4,
            checkFailureCount: hasFailedCI ? 1 : 0,
            checkPendingCount: 0,
            myLastReviewState: nil,
            myLastReviewAt: nil,
            reviewRequestedAt: nil,
            myThreadsAllResolved: true,
            approvalCount: 2,
            changesRequestedCount: 0,
            ciExtendedInfo: CIExtendedInfo(
                isRunning: false,
                workflows: [
                    CIWorkflowInfo(
                        name: "unit-test",
                        isWorkflow: true,
                        successCount: hasFailedCI ? 3 : 4,
                        failureCount: hasFailedCI ? 1 : 0,
                        pendingCount: 0
                    )
                ]
            )
        )
    }

    static let snapshot = LocalSnapshotFactory.makeSnapshot(
        input: LocalSnapshotInput(
            appVersion: "1.0.0",
            buildVersion: "1",
            bundleIdentifier: "com.example.ghpr-ui-test",
            authState: AuthState(accessToken: nil, username: "octocat", authMethod: nil),
            prList: PRList(
                lastUpdated: Date(timeIntervalSince1970: 1_775_000_100),
                pullRequests: [pullRequest],
                isLoading: false,
                error: nil
            ),
            rateLimitInfo: RateLimitInfo(
                limit: 5_000,
                remaining: 4_999,
                resetDate: Date(timeIntervalSince1970: 1_775_003_600)
            ),
            pinnedPRIdentifiers: [],
            minimumApprovalsForReadyToMerge: 2,
            refreshStatus: "idle",
            refreshError: nil
        ),
        now: Date(timeIntervalSince1970: 1_775_000_100)
    )
}

@MainActor
private struct ExtensionPlatformPRActionsUITestView: View {
    @ObservedObject var controller: ExtensionPlatformController
    let hasFailedCI: Bool

    private var pullRequest: PullRequest {
        hasFailedCI
            ? ExtensionPlatformUITestFixture.pullRequest
            : ExtensionPlatformUITestFixture.passingPullRequest
    }

    private var latestRun: SkillRun? {
        controller.store.runs(
            pageKey: GitHubPageContext.pullRequest(
                repository: pullRequest.repoFullName,
                number: pullRequest.number
            ).key
        ).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PR Actions")
                .font(.headline)
            PRRowView(
                pr: pullRequest,
                onOpen: {},
                onOpenJira: { _ in },
                onCopyURL: {},
                onRerunFailedCI: {},
                onAnalyzeCIFailure: {
                    _ = try? controller.runSkill(
                        id: "ci.failure.classify_flaky",
                        repository: pullRequest.repoFullName,
                        number: pullRequest.number
                    )
                },
                onViewCIAnalysis: {},
                onRunSkill: {
                    _ = try? controller.runSkill(
                        id: $0,
                        repository: pullRequest.repoFullName,
                        number: pullRequest.number
                    )
                },
                onInstallBrowserUserscript: {},
                runnableSkills: controller.runnableSkills(forFailedCI: hasFailedCI),
                extensionRun: controller.activeRun(
                    repository: pullRequest.repoFullName,
                    number: pullRequest.number
                ),
                extensionAnalysis: controller.latestAnalysis(
                    repository: pullRequest.repoFullName,
                    number: pullRequest.number
                ),
                extensionTags: controller.tags(
                    repository: pullRequest.repoFullName,
                    number: pullRequest.number
                )
            )
            Text("Tags: \(controller.tags(repository: pullRequest.repoFullName, number: pullRequest.number).map(\.displayName).sorted().joined(separator: ", "))")
                .accessibilityIdentifier("pr-action-tags")
            Text(
                "Analysis: \(controller.latestAnalysis(repository: pullRequest.repoFullName, number: pullRequest.number)?.verdict.displayName ?? "None")"
            )
            .accessibilityIdentifier("pr-action-analysis")
            Text("Last run: \(latestRun?.status.displayName ?? "None")")
                .accessibilityIdentifier("pr-action-last-run")
        }
        .padding()
        .frame(width: 420, height: 190)
    }
}
#endif
