import Foundation
import Combine
import Network
import os

private let logger = Logger(subsystem: "com.prdashboard", category: "PRManager")

@MainActor
protocol PRManagerType: AnyObject {
    func enablePolling(_ enabled: Bool)
    func refresh()
}

@MainActor
final class PRManager: PRManagerType, ObservableObject {
    @Published private(set) var prList: PRList = .empty
    @Published private(set) var refreshState: RefreshState = .idle
    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty
    @Published var configuration: Configuration

    enum RefreshState {
        case idle
        case loading
        case error(Error)
    }

    private var apiClient: GitHubAPIClient
    private let notificationManager: NotificationManager
    private let oauthManager: GitHubOAuthManager

    private var timer: Timer?
    private var previousPRs: [Int: PullRequest] = [:]
    private var pendingAutoRetryPRIds: Set<Int> = []
    private var cancellables = Set<AnyCancellable>()
    private var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var isOnExpensiveNetwork: Bool = false
    private let networkMonitor = NWPathMonitor()

    init(
        apiClient: GitHubAPIClient,
        notificationManager: NotificationManager,
        oauthManager: GitHubOAuthManager
    ) {
        self.apiClient = apiClient
        self.notificationManager = notificationManager
        self.oauthManager = oauthManager
        self.configuration = Self.loadConfiguration()

        setupBindings()
    }

    private func setupBindings() {
        // Update API client when auth state changes
        oauthManager.$authState
            .dropFirst()  // Skip initial value
            .sink { [weak self] authState in
                guard let self else { return }
                self.handleAuthStateChange(authState)
            }
            .store(in: &cancellables)

        // Forward rate limit info from API client
        apiClient.$rateLimitInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.rateLimitInfo = info
            }
            .store(in: &cancellables)

        // Observe Low Power Mode changes
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handlePowerStateChange()
                }
            }
            .store(in: &cancellables)

        // Monitor network status for expensive connections (cellular/hotspot)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkChange(path)
            }
        }
        networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func handleNetworkChange(_ path: NWPath) {
        let wasExpensive = isOnExpensiveNetwork
        isOnExpensiveNetwork = path.isExpensive

        guard configuration.pausePollingOnExpensiveNetwork else { return }

        if isOnExpensiveNetwork && !wasExpensive {
            timer?.invalidate()
            timer = nil
        } else if !isOnExpensiveNetwork && wasExpensive {
            if oauthManager.authState.isAuthenticated {
                enablePolling(true)
            }
        }
    }

    private func handlePowerStateChange() {
        let wasLowPowerMode = isLowPowerMode
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        guard configuration.pausePollingInLowPowerMode else { return }

        if isLowPowerMode && !wasLowPowerMode {
            timer?.invalidate()
            timer = nil
        } else if !isLowPowerMode && wasLowPowerMode {
            if oauthManager.authState.isAuthenticated {
                enablePolling(true)
            }
        }
    }

    private func handleAuthStateChange(_ authState: AuthState) {
        apiClient.updateToken(authState.accessToken ?? "")

        if authState.isAuthenticated {
            // Start background polling for notifications
            enablePolling(true)
        } else {
            enablePolling(false)
            prList = .empty
            previousPRs = [:]
            // Clear caches on sign-out
            PRCache.shared.clear()
            AvatarCache.shared.clear()
        }
    }

    /// Load cached PR data on startup for immediate display
    func loadCachedData() {
        if let cached = PRCache.shared.load() {
            self.prList = cached
            // Rebuild previousPRs for change detection
            for pr in cached.pullRequests {
                previousPRs[pr.id] = pr
            }
        }
    }

    func enablePolling(_ enabled: Bool) {
        if !enabled {
            timer?.invalidate()
            timer = nil
            return
        }

        guard oauthManager.authState.isAuthenticated else { return }

        // Check if we need to refresh on open
        let isFirstOpen = prList.pullRequests.isEmpty && prList.error == nil && !prList.isLoading
        let timeSinceLastUpdate = Date().timeIntervalSince(prList.lastUpdated)
        let isStale = timeSinceLastUpdate >= configuration.refreshInterval
        if isFirstOpen || configuration.refreshOnOpen || isStale {
            refresh()
        }

        // Only create timer if not already running
        if timer?.isValid == true {
            return
        }

        // Skip timer creation if in Low Power Mode and setting is enabled
        if isLowPowerMode && configuration.pausePollingInLowPowerMode {
            return
        }

        // Skip timer creation if on expensive network and setting is enabled
        if isOnExpensiveNetwork && configuration.pausePollingOnExpensiveNetwork {
            return
        }

        // Schedule periodic refresh using .common mode so timer fires during scrolling
        let interval = max(configuration.refreshInterval, 60)
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func refresh() {
        guard oauthManager.authState.isAuthenticated,
              let username = oauthManager.authState.username else {
            return
        }

        guard configuration.isValid else {
            prList = PRList(
                lastUpdated: Date(),
                pullRequests: [],
                isLoading: false,
                error: ConfigurationError.invalidRefreshInterval
            )
            return
        }

        refreshState = .loading
        prList = PRList(
            lastUpdated: prList.lastUpdated,
            pullRequests: prList.pullRequests,
            mergedPullRequests: prList.mergedPullRequests,
            isLoading: true,
            error: nil
        )

        Task { @MainActor in
            do {
                let result = try await apiClient.fetchAllPullRequests(username: username)
                var prs = result.openPRs
                var mergedPRs = result.mergedPRs

                logger.info("API returned: \(prs.count) open PRs, \(mergedPRs.count) merged PRs")

                // Filter by configured repositories if any (case-insensitive, supports "org/" prefix match)
                if !configuration.repositories.isEmpty {
                    let repoFilter: (PullRequest) -> Bool = { pr in
                        let repoName = pr.repoFullName.lowercased()
                        return self.configuration.repositories.contains { filter in
                            let filterLower = filter.lowercased()
                            if filterLower.hasSuffix("/") {
                                // Org/author prefix match (e.g., "xiaocang/" matches all repos under xiaocang)
                                return repoName.hasPrefix(filterLower)
                            } else {
                                // Full "owner/repo" match
                                return repoName == filterLower
                            }
                        }
                    }
                    prs = prs.filter(repoFilter)
                    mergedPRs = mergedPRs.filter(repoFilter)
                }

                // Filter drafts if disabled
                if !configuration.showDrafts {
                    prs = prs.filter { !$0.isDraft }
                    // Note: merged PRs are never drafts, but filter anyway for consistency
                    mergedPRs = mergedPRs.filter { !$0.isDraft }
                }

                logger.info("After filters: \(prs.count) open PRs, \(mergedPRs.count) merged PRs")

                // Check for changes and notify
                if configuration.notificationsEnabled {
                    checkForChangesAndNotify(newPRs: prs)
                }

                // Auto-retry failed CI when workflow completes
                checkAndAutoRetryCI(newPRs: prs)

                // Update previous state
                previousPRs = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })

                let newPRList = PRList(
                    lastUpdated: Date(),
                    pullRequests: prs,
                    mergedPullRequests: mergedPRs,
                    isLoading: false,
                    error: nil
                )
                prList = newPRList
                refreshState = .idle

                // Save to cache after successful refresh
                PRCache.shared.save(newPRList)

            } catch {
                // Try to fallback to stale cache on API error
                if prList.pullRequests.isEmpty,
                   let cached = PRCache.shared.load(ignoreExpiry: true) {
                    prList = PRList(
                        lastUpdated: cached.lastUpdated,
                        pullRequests: cached.pullRequests,
                        mergedPullRequests: cached.mergedPullRequests,
                        isLoading: false,
                        error: error  // Still show error to indicate stale data
                    )
                } else {
                    prList = PRList(
                        lastUpdated: prList.lastUpdated,
                        pullRequests: prList.pullRequests,
                        mergedPullRequests: prList.mergedPullRequests,
                        isLoading: false,
                        error: error
                    )
                }
                refreshState = .error(error)
            }
        }
    }

    func rerunFailedCI(for pr: PullRequest) async throws -> Int {
        guard let headSHA = pr.headCommitOid else {
            throw APIError.unknown("No head commit SHA available for PR #\(pr.number)")
        }
        let count = try await apiClient.rerunFailedWorkflows(
            owner: pr.repositoryOwner, repo: pr.repositoryName, headSHA: headSHA
        )
        if count > 0 {
            // Delay then refresh just this PR's CI status instead of all PRs
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refreshSinglePRCI(for: pr)
            }
        }
        return count
    }

    func refreshSinglePRCI(for pr: PullRequest) async {
        do {
            let result = try await apiClient.fetchSinglePRCIStatus(
                owner: pr.repositoryOwner, repo: pr.repositoryName, number: pr.number
            )
            if let index = prList.pullRequests.firstIndex(where: { $0.id == pr.id }) {
                var updated = prList.pullRequests
                updated[index].ciStatus = result.ciStatus
                updated[index].checkSuccessCount = result.checkSuccessCount
                updated[index].checkFailureCount = result.checkFailureCount
                updated[index].checkPendingCount = result.checkPendingCount
                updated[index].ciExtendedInfo = result.ciExtendedInfo
                prList = PRList(
                    lastUpdated: prList.lastUpdated,
                    pullRequests: updated,
                    mergedPullRequests: prList.mergedPullRequests,
                    isLoading: false,
                    error: nil
                )
                logger.info("Refreshed single PR CI status for #\(pr.number): \(result.ciStatus?.rawValue ?? "nil")")
            }
        } catch {
            logger.error("Failed to refresh single PR CI for #\(pr.number): \(error.localizedDescription)")
        }
    }

    func updateConfiguration(_ config: Configuration) {
        configuration = config
        Self.saveConfiguration(config)

        // Restart polling with new interval if currently polling
        if timer != nil {
            enablePolling(true)
        }
    }

    private func checkAndAutoRetryCI(newPRs: [PullRequest]) {
        let currentIds = Set(newPRs.map { $0.id })
        // Clean up tracking for PRs that have disappeared
        pendingAutoRetryPRIds = pendingAutoRetryPRIds.filter { currentIds.contains($0) }

        for pr in newPRs {
            guard pr.category == .authored else { continue }

            if pr.ciIsRunning && pr.checkFailureCount > 0 {
                // Mark for auto-retry when workflow completes
                pendingAutoRetryPRIds.insert(pr.id)
            } else if !pr.ciIsRunning && pr.ciStatus == .failure && pendingAutoRetryPRIds.contains(pr.id) {
                // Workflow just completed with failure — auto-retry
                pendingAutoRetryPRIds.remove(pr.id)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let count = try await self.rerunFailedCI(for: pr)
                        logger.info("Auto-retried \(count) failed workflow(s) for PR #\(pr.number)")
                    } catch {
                        logger.error("Auto-retry failed for PR #\(pr.number): \(error.localizedDescription)")
                    }
                }
            } else if !pr.ciIsRunning || pr.ciStatus == .success {
                // Clean up tracking
                pendingAutoRetryPRIds.remove(pr.id)
            }
        }
    }

    private func checkForChangesAndNotify(newPRs: [PullRequest]) {
        for pr in newPRs {
            guard let previousPR = previousPRs[pr.id] else {
                // This is a new PR we haven't seen before - skip notification
                continue
            }

            // Check for unresolved comment changes
            let previousUnresolved = previousPR.unresolvedCount
            let currentUnresolved = pr.unresolvedCount

            if currentUnresolved > previousUnresolved {
                let newCount = currentUnresolved - previousUnresolved
                notificationManager.notify(pr: pr, newUnresolvedCount: newCount)
            }

            // Check for CI status changes
            let previousCI = previousPR.ciStatus
            let currentCI = pr.ciStatus

            if previousCI != currentCI {
                if let newStatus = currentCI,
                   (newStatus == .success || newStatus == .failure) {
                    notificationManager.notifyCIStatusChange(pr: pr, newStatus: newStatus)
                }
            }
        }
    }

    // MARK: - Configuration Persistence

    private static let configurationKey = "PRDashboard.Configuration"

    private static func loadConfiguration() -> Configuration {
        guard let data = UserDefaults.standard.data(forKey: configurationKey),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            return .default
        }
        return config
    }

    private static func saveConfiguration(_ config: Configuration) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configurationKey)
        }
    }
}
