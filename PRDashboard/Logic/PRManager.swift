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

struct CIRetryState {
    var workflowRetryCount: [String: Int] = [:]  // workflow name → retries used
    var pendingWorkflows: Set<String> = []         // workflows currently being retried
    static let maxRetries = 3

    var maxRetryRound: Int { workflowRetryCount.values.max() ?? 0 }
}

@MainActor
final class PRManager: PRManagerType, ObservableObject {
    @Published private(set) var prList: PRList = .empty
    @Published private(set) var refreshState: RefreshState = .idle
    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty
    @Published var configuration: Configuration
    @Published private(set) var pinnedPRIdentifiers: Set<String>
    @Published private(set) var ciRetryTracking: [String: CIRetryState] = [:]

    enum RefreshState {
        case idle
        case loading
        case error(Error)
    }

    private enum RefreshTrigger: String {
        case manual
        case timer
        case auth
        case recovery
        case queued
    }

    private struct RecoveryRetryPlan {
        let delay: TimeInterval
        let reason: String
    }

    private var apiClient: GitHubAPIClient
    private let notificationManager: NotificationManager
    private let oauthManager: GitHubOAuthManager

    private var timer: Timer?
    private var activeRefreshTask: Task<Void, Never>?
    private var recoveryRetryTask: Task<Void, Never>?
    private var queuedRefresh = false
    private var consecutiveTransientFailures = 0
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
        self.pinnedPRIdentifiers = Self.loadPinnedPRs()

        setupBindings()
    }

    deinit {
        activeRefreshTask?.cancel()
        recoveryRetryTask?.cancel()
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
            cancelRecoveryRetry()
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
            cancelRecoveryRetry()
        } else if !isLowPowerMode && wasLowPowerMode {
            if oauthManager.authState.isAuthenticated {
                enablePolling(true)
            }
        }
    }

    private func handleAuthStateChange(_ authState: AuthState) {
        apiClient.updateToken(authState.accessToken ?? "")

        if authState.isAuthenticated {
            cancelRecoveryRetry(resetFailureCount: true)
            enablePolling(true, refreshTrigger: .auth, refreshIfNeeded: false)
            requestRefresh(trigger: .auth)
        } else {
            enablePolling(false)
            cancelRefreshWork(reason: "sign_out")
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
        enablePolling(enabled, refreshTrigger: .timer, refreshIfNeeded: true)
    }

    private func enablePolling(_ enabled: Bool, refreshTrigger: RefreshTrigger, refreshIfNeeded: Bool) {
        if !enabled {
            timer?.invalidate()
            timer = nil
            cancelRecoveryRetry()
            return
        }

        guard oauthManager.authState.isAuthenticated else { return }

        if refreshIfNeeded {
            // Check if we need to refresh on open
            let isFirstOpen = !prList.hasUsableData && prList.error == nil && !prList.isLoading
            let timeSinceLastUpdate = Date().timeIntervalSince(prList.lastUpdated)
            let isStale = timeSinceLastUpdate >= configuration.refreshInterval
            if isFirstOpen || configuration.refreshOnOpen || isStale {
                requestRefresh(trigger: refreshTrigger)
            }
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
                self?.requestRefresh(trigger: .timer)
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func refresh() {
        requestRefresh(trigger: .manual)
    }

    private func requestRefresh(trigger: RefreshTrigger) {
        if trigger != .recovery {
            cancelRecoveryRetry()
        }

        guard oauthManager.authState.isAuthenticated,
              let username = oauthManager.authState.username else {
            return
        }

        guard configuration.isValid else {
            let error = ConfigurationError.invalidRefreshInterval
            prList = PRList(
                lastUpdated: prList.lastUpdated,
                pullRequests: prList.pullRequests,
                mergedPullRequests: prList.mergedPullRequests,
                isLoading: false,
                error: error
            )
            refreshState = .error(error)
            consecutiveTransientFailures = 0
            return
        }

        guard activeRefreshTask == nil else {
            if !queuedRefresh {
                logger.info("Coalescing refresh request: trigger=\(trigger.rawValue, privacy: .public)")
            }
            queuedRefresh = true
            return
        }

        startRefresh(username: username, trigger: trigger)
    }

    private func startRefresh(username: String, trigger: RefreshTrigger) {
        let hadUsableData = prList.hasUsableData
        refreshState = .loading
        prList = PRList(
            lastUpdated: prList.lastUpdated,
            pullRequests: prList.pullRequests,
            mergedPullRequests: prList.mergedPullRequests,
            isLoading: true,
            error: nil
        )

        logger.info(
            "Starting refresh: trigger=\(trigger.rawValue, privacy: .public) staleData=\((hadUsableData ? "true" : "false"), privacy: .public)"
        )

        activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeRefreshTask = nil
                if self.queuedRefresh {
                    self.queuedRefresh = false
                    self.requestRefresh(trigger: .queued)
                }
            }

            do {
                let result = try await self.apiClient.fetchAllPullRequests(username: username)
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

                // Enrich PRs with Jira tickets from body (fetches only for uncached PRs)
                do {
                    let jiraCache = try await apiClient.fetchJiraTickets(for: prs + mergedPRs)
                    GitHubAPIClient.applyJiraTickets(to: &prs, cache: jiraCache)
                    GitHubAPIClient.applyJiraTickets(to: &mergedPRs, cache: jiraCache)
                } catch {
                    logger.error("Failed to enrich Jira tickets: \(error.localizedDescription)")
                }

                // Auto-retry CI for pinned PRs with retry tracking
                checkCIAutoRetries(newPRs: prs)

                // Update previous state
                previousPRs = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })

                let newPRList = PRList(
                    lastUpdated: Date(),
                    pullRequests: prs,
                    mergedPullRequests: mergedPRs,
                    isLoading: false,
                    error: nil
                )
                self.prList = newPRList
                self.refreshState = .idle
                self.consecutiveTransientFailures = 0
                self.cancelRecoveryRetry(resetFailureCount: true)

                // Save to cache after successful refresh
                PRCache.shared.save(newPRList)
                logger.info(
                    "Refresh succeeded: trigger=\(trigger.rawValue, privacy: .public) openPRs=\(prs.count) mergedPRs=\(mergedPRs.count)"
                )

            } catch {
                if error is CancellationError || ((error as? APIError)?.isCancellation == true) {
                    if self.oauthManager.authState.isAuthenticated {
                        self.prList = PRList(
                            lastUpdated: self.prList.lastUpdated,
                            pullRequests: self.prList.pullRequests,
                            mergedPullRequests: self.prList.mergedPullRequests,
                            isLoading: false,
                            error: nil
                        )
                        self.refreshState = .idle
                    }
                    logger.debug("Refresh cancelled: trigger=\(trigger.rawValue, privacy: .public)")
                    return
                }

                // Try to fallback to stale cache on API error
                if !self.prList.hasUsableData,
                   let cached = PRCache.shared.load(ignoreExpiry: true) {
                    self.prList = PRList(
                        lastUpdated: cached.lastUpdated,
                        pullRequests: cached.pullRequests,
                        mergedPullRequests: cached.mergedPullRequests,
                        isLoading: false,
                        error: error  // Still show error to indicate stale data
                    )
                    self.previousPRs = Dictionary(uniqueKeysWithValues: cached.pullRequests.map { ($0.id, $0) })
                } else {
                    self.prList = PRList(
                        lastUpdated: self.prList.lastUpdated,
                        pullRequests: self.prList.pullRequests,
                        mergedPullRequests: self.prList.mergedPullRequests,
                        isLoading: false,
                        error: error
                    )
                }
                self.refreshState = .error(error)

                let showingStaleData = self.prList.hasUsableData
                logger.error(
                    "Refresh failed: trigger=\(trigger.rawValue, privacy: .public) staleData=\((showingStaleData ? "true" : "false"), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )

                if !self.queuedRefresh {
                    self.scheduleRecoveryRetry(after: error, trigger: trigger, showingStaleData: showingStaleData)
                }
            }
        }
    }

    private func cancelRefreshWork(reason: String) {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        queuedRefresh = false
        cancelRecoveryRetry(resetFailureCount: true)
        refreshState = .idle
        logger.info("Cancelled refresh work: reason=\(reason, privacy: .public)")
    }

    private func cancelRecoveryRetry(resetFailureCount: Bool = false) {
        recoveryRetryTask?.cancel()
        recoveryRetryTask = nil
        if resetFailureCount {
            consecutiveTransientFailures = 0
        }
    }

    private func scheduleRecoveryRetry(after error: Error, trigger: RefreshTrigger, showingStaleData: Bool) {
        guard oauthManager.authState.isAuthenticated else { return }

        guard !isAutomaticRecoveryPaused else {
            logger.info(
                "Skipping recovery retry because polling is paused: trigger=\(trigger.rawValue, privacy: .public)"
            )
            return
        }

        guard let plan = recoveryRetryPlan(for: error) else { return }

        cancelRecoveryRetry()
        let retryAt = Date().addingTimeInterval(plan.delay)
        logger.warning(
            "Scheduling recovery retry: trigger=\(trigger.rawValue, privacy: .public) reason=\(plan.reason, privacy: .public) retryIn=\(plan.delay.formattedSeconds, privacy: .public)s retryAt=\(retryAt.ISO8601Format(), privacy: .public) staleData=\((showingStaleData ? "true" : "false"), privacy: .public)"
        )

        recoveryRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: plan.delay.nanoseconds)
            } catch {
                return
            }

            guard let self else { return }
            self.recoveryRetryTask = nil
            self.requestRefresh(trigger: .recovery)
        }
    }

    private func recoveryRetryPlan(for error: Error) -> RecoveryRetryPlan? {
        guard let apiError = error as? APIError else {
            consecutiveTransientFailures = 0
            return nil
        }

        if apiError.isCancellation {
            return nil
        }

        switch apiError {
        case .rateLimited(let resetDate):
            consecutiveTransientFailures = 0
            let delay = max(0, resetDate.timeIntervalSinceNow) + Double.random(in: 1...3)
            return RecoveryRetryPlan(delay: delay, reason: "rate_limited")
        case .network(_), .http(_) where apiError.isTransient:
            consecutiveTransientFailures += 1
            let baseDelay: TimeInterval
            switch min(consecutiveTransientFailures, 3) {
            case 1:
                baseDelay = 15
            case 2:
                baseDelay = 30
            default:
                baseDelay = 60
            }
            return RecoveryRetryPlan(
                delay: baseDelay + Double.random(in: 0...3),
                reason: "transient_failure"
            )
        default:
            consecutiveTransientFailures = 0
            return nil
        }
    }

    private var isAutomaticRecoveryPaused: Bool {
        (isLowPowerMode && configuration.pausePollingInLowPowerMode) ||
        (isOnExpensiveNetwork && configuration.pausePollingOnExpensiveNetwork)
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

    // MARK: - CI Auto-retry (3x per workflow)

    func enableCIAutoRetry(for pr: PullRequest) {
        let pinId = pr.pinIdentifier
        guard ciRetryTracking[pinId] == nil else { return }  // already active

        ciRetryTracking[pinId] = CIRetryState()

        // Immediately trigger first retry if there are failures
        if pr.checkFailureCount > 0, let headSHA = pr.headCommitOid {
            triggerSelectiveRetry(for: pr, pinId: pinId, headSHA: headSHA)
        }
    }

    func cancelCIAutoRetry(for pr: PullRequest) {
        ciRetryTracking.removeValue(forKey: pr.pinIdentifier)
    }

    private func checkCIAutoRetries(newPRs: [PullRequest]) {
        let currentPinIds = Set(newPRs.map { $0.pinIdentifier })
        // Clean up tracking for PRs that disappeared
        for pinId in Array(ciRetryTracking.keys) where !currentPinIds.contains(pinId) {
            ciRetryTracking.removeValue(forKey: pinId)
        }

        for (pinId, var state) in Array(ciRetryTracking) {
            guard let pr = newPRs.first(where: { $0.pinIdentifier == pinId }) else { continue }

            // 1. Update pendingWorkflows based on current workflow statuses
            let currentWorkflows = pr.ciWorkflows
            let currentNames = Set(currentWorkflows.map { $0.name })
            // Remove pending workflows that no longer exist or have completed
            state.pendingWorkflows = Set(state.pendingWorkflows.filter { name in
                guard currentNames.contains(name) else { return false }
                guard let workflow = currentWorkflows.first(where: { $0.name == name }) else { return false }
                return workflow.pendingCount > 0  // only keep if still has pending jobs
            })

            // 2. Find eligible workflows for retry
            let eligible = currentWorkflows.filter { workflow in
                workflow.isWorkflow &&
                workflow.status == .failure &&
                workflow.pendingCount == 0 &&
                !state.pendingWorkflows.contains(workflow.name) &&
                (state.workflowRetryCount[workflow.name] ?? 0) < CIRetryState.maxRetries
            }

            if !eligible.isEmpty, let headSHA = pr.headCommitOid {
                // Optimistically mark as pending to prevent duplicate retries
                for workflow in eligible {
                    state.pendingWorkflows.insert(workflow.name)
                }
                ciRetryTracking[pinId] = state
                triggerSelectiveRetry(for: pr, pinId: pinId, headSHA: headSHA)
            } else {
                // 3. Check if tracking should be removed
                let hasFailures = currentWorkflows.contains { $0.status == .failure }
                let allExhausted = currentWorkflows
                    .filter { $0.status == .failure }
                    .allSatisfy { (state.workflowRetryCount[$0.name] ?? 0) >= CIRetryState.maxRetries }

                if (!hasFailures && state.pendingWorkflows.isEmpty) ||
                   (allExhausted && state.pendingWorkflows.isEmpty) {
                    ciRetryTracking.removeValue(forKey: pinId)
                } else {
                    ciRetryTracking[pinId] = state
                }
            }
        }
    }

    private func triggerSelectiveRetry(for pr: PullRequest, pinId: String, headSHA: String) {
        // Build exclude set: exhausted workflows (retries >= 3)
        let state = ciRetryTracking[pinId] ?? CIRetryState()
        let exhausted = Set(state.workflowRetryCount.filter { $0.value >= CIRetryState.maxRetries }.map { $0.key })
        let excludeSet = exhausted

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let retriedNames = try await self.apiClient.rerunSelectiveFailedWorkflows(
                    owner: pr.repositoryOwner, repo: pr.repositoryName,
                    headSHA: headSHA, excludeWorkflows: excludeSet
                )
                // Update retry counts
                for name in retriedNames {
                    self.ciRetryTracking[pinId]?.workflowRetryCount[name, default: 0] += 1
                    self.ciRetryTracking[pinId]?.pendingWorkflows.insert(name)
                }
                if !retriedNames.isEmpty {
                    logger.info("Auto-retry triggered \(retriedNames.count) workflow(s) for \(pinId): \(retriedNames.joined(separator: ", "))")
                    // Refresh CI status after delay
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await self.refreshSinglePRCI(for: pr)
                }
            } catch {
                logger.error("Auto-retry failed for \(pinId): \(error.localizedDescription)")
                // Remove optimistic pending on failure
                if var s = self.ciRetryTracking[pinId] {
                    let failedWorkflows = pr.ciWorkflows.filter { $0.status == .failure }.map { $0.name }
                    for name in failedWorkflows {
                        s.pendingWorkflows.remove(name)
                    }
                    self.ciRetryTracking[pinId] = s
                }
            }
        }
    }

    // MARK: - Pin PR

    func pinPR(_ identifier: String) {
        // NOTE: Avoid in-place mutation on @Published collections; ensure a new value is assigned
        // so Combine publishes changes and SwiftUI updates immediately.
        var updated = pinnedPRIdentifiers
        updated.insert(identifier)
        pinnedPRIdentifiers = updated
        Self.savePinnedPRs(updated)
    }

    func unpinPR(_ identifier: String) {
        // Same rationale as pinPR(_:): assign a new Set to trigger @Published emission.
        var updated = pinnedPRIdentifiers
        updated.remove(identifier)
        pinnedPRIdentifiers = updated

        // Keep CI auto-retry tracking consistent for this PR.
        var updatedTracking = ciRetryTracking
        updatedTracking.removeValue(forKey: identifier)
        ciRetryTracking = updatedTracking

        Self.savePinnedPRs(updated)
    }

    func togglePinPR(_ identifier: String) {
        if pinnedPRIdentifiers.contains(identifier) {
            unpinPR(identifier)
        } else {
            pinPR(identifier)
        }
    }

    // MARK: - Configuration Persistence

    private static let configurationKey = "PRDashboard.Configuration"
    private static let pinnedPRsKey = "PRDashboard.PinnedPRs"

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

    private static func loadPinnedPRs() -> Set<String> {
        guard let array = UserDefaults.standard.stringArray(forKey: pinnedPRsKey) else {
            return []
        }
        return Set(array)
    }

    private static func savePinnedPRs(_ identifiers: Set<String>) {
        UserDefaults.standard.set(Array(identifiers), forKey: pinnedPRsKey)
    }
}
