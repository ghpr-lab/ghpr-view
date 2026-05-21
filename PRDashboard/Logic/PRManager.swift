import Foundation
import Combine
import Network
import os

private let logger = Logger(subsystem: "com.prdashboard", category: "PRManager")

enum PinnedMajorPREvent: Hashable {
    case ciFailure
    case changeRequests(Int)
    case approvals(Int)

    var notificationText: String {
        switch self {
        case .ciFailure:
            return String(localized: "CI failing")
        case .changeRequests(let count):
            if count == 1 {
                return String(localized: "1 change request")
            }
            return String(localized: "\(count) change requests")
        case .approvals(let count):
            if count == 1 {
                return String(localized: "1 approval")
            }
            return String(localized: "\(count) approvals")
        }
    }
}

struct PinnedMajorPRNotificationPlan: Equatable {
    let prID: Int
    let events: [PinnedMajorPREvent]
}

enum PinnedMajorPRNotificationPlanner {
    static func events(for pr: PullRequest) -> [PinnedMajorPREvent] {
        var events: [PinnedMajorPREvent] = []

        if pr.ciStatus == .failure || pr.ciStatus == .unknown || pr.checkFailureCount > 0 {
            events.append(.ciFailure)
        }

        if let changesRequestedCount = pr.changesRequestedCount, changesRequestedCount > 0 {
            events.append(.changeRequests(changesRequestedCount))
        }

        if pr.approvalCount > 0 {
            events.append(.approvals(pr.approvalCount))
        }

        return events
    }

    static func plans(
        for prs: [PullRequest],
        pinnedPRIdentifiers: Set<String>
    ) -> [PinnedMajorPRNotificationPlan] {
        prs.compactMap { pr in
            guard pr.category == .authored || pr.category == .reviewRequest else { return nil }
            guard pinnedPRIdentifiers.contains(pr.pinIdentifier) else { return nil }

            let events = events(for: pr)
            guard !events.isEmpty else { return nil }

            return PinnedMajorPRNotificationPlan(
                prID: pr.id,
                events: events
            )
        }
    }
}

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
    @Published private(set) var readReviewThreadIDs: Set<String>
    @Published private(set) var ciRetryTracking: [String: CIRetryState] = [:]
    @Published private(set) var updatingBranchPRIDs: Set<Int> = []
    @Published private(set) var loadingHoverDetailPRIDs: Set<Int> = []
    @Published private(set) var isJiraConfigured: Bool = false

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
    private let jiraClient: JiraAPIClient
    private let notificationManager: NotificationManager
    private let oauthManager: GitHubOAuthManager

    private var timer: Timer?
    private var activeRefreshTask: Task<Void, Never>?
    private var recoveryRetryTask: Task<Void, Never>?
    private var queuedRefresh = false
    private var consecutiveTransientFailures = 0
    private var previousPRs: [Int: PullRequest] = [:]
    private var previousPinnedMajorEvents: [Int: Set<PinnedMajorPREvent>] = [:]
    private var pendingAutoRetryPRIds: Set<Int> = []
    private var hoverDetailTasks: [Int: Task<Void, Never>] = [:]
    private var hoverDetailCache: [Int: HoverDetailCacheEntry] = [:]
    private let cmuxStatusProvider: CmuxPRStatusProviding?
    private static let maxBaseUpdateStatusRefreshes = 20
    private var cancellables = Set<AnyCancellable>()
    private var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var isOnExpensiveNetwork: Bool = false
    private let networkMonitor = NWPathMonitor()

    private struct HoverDetailCacheEntry {
        let metadata: GitHubAPIClient.PRHoverMetadata
        let prUpdatedAt: Date
        let headCommitOid: String?
        let fetchedAt: Date

        func isUsable(for pr: PullRequest) -> Bool {
            prUpdatedAt == pr.updatedAt &&
                headCommitOid == pr.headCommitOid &&
                Date().timeIntervalSince(fetchedAt) < 10 * 60 &&
                (pr.baseNeedsUpdate != nil || metadata.baseNeedsUpdate != nil)
        }
    }

    init(
        apiClient: GitHubAPIClient,
        jiraClient: JiraAPIClient = JiraAPIClient(),
        notificationManager: NotificationManager,
        oauthManager: GitHubOAuthManager,
        cmuxStatusProvider: CmuxPRStatusProviding? = nil
    ) {
        self.apiClient = apiClient
        self.jiraClient = jiraClient
        self.notificationManager = notificationManager
        self.oauthManager = oauthManager
        self.cmuxStatusProvider = cmuxStatusProvider
        self.configuration = Self.loadConfiguration()
        self.pinnedPRIdentifiers = Self.loadPinnedPRs()
        self.readReviewThreadIDs = Self.loadReadReviewThreadIDs()

        apiClient.updateGraphQLEndpoint(self.configuration.graphQLEndpoint)
        apiClient.updateProxy(
            urlString: self.configuration.httpProxyURL,
            username: self.configuration.httpProxyUsername,
            password: Keychain.loadProxyPassword()
        )

        self.isJiraConfigured = Self.computeJiraConfigured(
            config: self.configuration,
            tokenPresent: !Keychain.loadJiraAPIToken().isEmpty
        )

        setupBindings()
    }

    private static func computeJiraConfigured(config: Configuration, tokenPresent: Bool) -> Bool {
        !config.jiraServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !config.jiraEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            tokenPresent
    }

    deinit {
        activeRefreshTask?.cancel()
        recoveryRetryTask?.cancel()
        hoverDetailTasks.values.forEach { $0.cancel() }
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
            previousPinnedMajorEvents = [:]
            hoverDetailTasks.values.forEach { $0.cancel() }
            hoverDetailTasks = [:]
            hoverDetailCache = [:]
            loadingHoverDetailPRIDs = []
            // Clear caches on sign-out
            PRCache.shared.clear()
            PRDetailCache.shared.clear()
            MentionCache.shared.clear()
            AvatarCache.shared.clear()
        }
    }

    /// Load cached PR data on startup for immediate display
    func loadCachedData() {
        if var cached = PRCache.shared.load() {
            clearCmuxOpenStatus(in: &cached)
            applyReadState(to: &cached)
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
            prList.isLoading = false
            prList.error = error
            refreshState = .error(error)
            consecutiveTransientFailures = 0
            return
        }

        if trigger != .manual, isRateLimitCritical {
            let resetDate = rateLimitInfo.resetDate
            logger.warning(
                "Skipping refresh due to low rate limit: trigger=\(trigger.rawValue, privacy: .public) remaining=\(self.rateLimitInfo.remaining, privacy: .public)/\(self.rateLimitInfo.limit, privacy: .public) threshold=\(Self.criticalRateLimitThresholdPercent, privacy: .public)% resumeAt=\(resetDate.ISO8601Format(), privacy: .public)"
            )
            scheduleRateLimitResume(at: resetDate)
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
        let visiblePRs = prList.allPRs
        refreshState = .loading
        prList.isLoading = true
        prList.error = nil

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
                let onProgress: @Sendable ([PullRequest], [PullRequest], GitHubAPIClient.IncrementalStage) async -> Void = { [weak self] openPRs, mergedPRs, stage in
                    guard let self else { return }
                    await self.applyIncrementalProgress(openPRs: openPRs, mergedPRs: mergedPRs, stage: stage)
                }

                let result = try await self.apiClient.fetchIncremental(
                    username: username,
                    existingPRs: visiblePRs,
                    onProgress: onProgress
                )
                var prs = self.filterByConfiguration(result.openPRs)
                var mentionedPRs = self.filterByConfiguration(result.mentionedPRs)
                var mergedPRs = self.filterByConfiguration(result.mergedPRs)
                self.applyReadState(to: &prs)
                self.applyReadState(to: &mentionedPRs)
                self.applyReadState(to: &mergedPRs)

                logger.info("After filters: \(prs.count) open PRs, \(mentionedPRs.count) mentioned PRs, \(mergedPRs.count) merged PRs")

                // Check for changes and notify
                if configuration.notificationsEnabled {
                    checkForChangesAndNotify(newPRs: prs)
                    notifyPinnedMajorEvents(newPRs: prs)
                }

                // Auto-retry failed CI when workflow completes
                checkAndAutoRetryCI(newPRs: prs)

                // Enrich PRs with Jira tickets from body (fetches only for uncached PRs)
                do {
                    let jiraCache = try await apiClient.fetchJiraTickets(for: prs + mentionedPRs + mergedPRs)
                    GitHubAPIClient.applyJiraTickets(to: &prs, cache: jiraCache)
                    GitHubAPIClient.applyJiraTickets(to: &mentionedPRs, cache: jiraCache)
                    GitHubAPIClient.applyJiraTickets(to: &mergedPRs, cache: jiraCache)
                } catch {
                    logger.error("Failed to enrich Jira tickets: \(error.localizedDescription)")
                }

                await enrichJiraMetadata(
                    openPRs: &prs,
                    mentionedPRs: &mentionedPRs,
                    mergedPRs: &mergedPRs
                )

                await refreshBaseUpdateStatuses(prs: &prs)
                await refreshCmuxOpenStatuses(
                    openPRs: &prs,
                    mentionedPRs: &mentionedPRs,
                    mergedPRs: &mergedPRs
                )

                // Auto-retry CI for pinned PRs with retry tracking
                checkCIAutoRetries(newPRs: prs)

                // Update previous state
                previousPRs = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })

                let newPRList = PRList(
                    lastUpdated: Date(),
                    pullRequests: prs,
                    mentionedPullRequests: mentionedPRs,
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
                    "Refresh succeeded: trigger=\(trigger.rawValue, privacy: .public) openPRs=\(prs.count) mentionedPRs=\(mentionedPRs.count) mergedPRs=\(mergedPRs.count)"
                )

            } catch {
                if error is CancellationError || ((error as? APIError)?.isCancellation == true) {
                    if self.oauthManager.authState.isAuthenticated {
                        self.prList.isLoading = false
                        self.prList.error = nil
                        self.refreshState = .idle
                    }
                    logger.debug("Refresh cancelled: trigger=\(trigger.rawValue, privacy: .public)")
                    return
                }

                // Try to fallback to stale cache on API error
                if !self.prList.hasUsableData,
                   var cached = PRCache.shared.load() {
                    self.clearCmuxOpenStatus(in: &cached)
                    self.prList = cached
                    self.prList.error = error  // Still show error to indicate stale data
                    self.previousPRs = Dictionary(uniqueKeysWithValues: cached.pullRequests.map { ($0.id, $0) })
                } else {
                    self.prList.isLoading = false
                    self.prList.error = error
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

    /// Apply `fetchIncremental` progress frame to the published `prList`. Runs on
    /// MainActor. Filters (repositories, drafts) are applied here so the partial
    /// view is consistent with user settings. The full notification / Jira / CI
    /// auto-retry pipeline only runs on the final (returned) result; intermediate
    /// frames only refresh the UI.
    private func applyIncrementalProgress(
        openPRs: [PullRequest],
        mergedPRs: [PullRequest],
        stage: GitHubAPIClient.IncrementalStage
    ) {
        var filteredOpen = filterByConfiguration(openPRs)
        var filteredMerged = filterByConfiguration(mergedPRs)
        applyReadState(to: &filteredOpen)
        applyReadState(to: &filteredMerged)

        var updated = prList
        updated.pullRequests = filteredOpen
        updated.mergedPullRequests = filteredMerged
        updated.isLoading = true
        updated.error = nil
        prList = updated
        logger.debug(
            "Incremental progress: stage=\(stage.rawValue, privacy: .public) open=\(filteredOpen.count, privacy: .public) merged=\(filteredMerged.count, privacy: .public)"
        )
    }

    private func filterByConfiguration(_ prs: [PullRequest]) -> [PullRequest] {
        var result = prs
        if !configuration.repositories.isEmpty {
            result = result.filter { pr in
                let repoName = pr.repoFullName.lowercased()
                return configuration.repositories.contains { filter in
                    let filterLower = filter.lowercased()
                    if filterLower.hasSuffix("/") {
                        return repoName.hasPrefix(filterLower)
                    } else {
                        return repoName == filterLower
                    }
                }
            }
        }
        if !configuration.showDrafts {
            result = result.filter { !$0.isDraft }
        }
        return result
    }

    private func enrichJiraMetadata(
        openPRs: inout [PullRequest],
        mentionedPRs: inout [PullRequest],
        mergedPRs: inout [PullRequest]
    ) async {
        var issueKeys: Set<String> = []
        for list in [openPRs, mentionedPRs, mergedPRs] {
            for pr in list {
                if let ticket = pr.jiraTicket {
                    issueKeys.insert(JiraMetadataCache.normalizeIssueKey(ticket))
                }
            }
        }
        guard !issueKeys.isEmpty else { return }

        let serverURL = configuration.jiraServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = configuration.jiraEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = Keychain.loadJiraAPIToken()
        guard !serverURL.isEmpty, !email.isEmpty, !token.isEmpty else { return }

        var metadata: [String: JiraIssueMetadata] = [:]
        do {
            metadata = try await jiraClient.fetchMetadata(
                for: issueKeys,
                serverURL: serverURL,
                email: email,
                apiToken: token,
                refreshInterval: configuration.jiraRefreshInterval
            )
        } catch {
            logger.error("Failed to enrich Jira metadata: \(error.localizedDescription, privacy: .public)")
        }

        // Apply whatever metadata we got (may be empty on hard failure, partial on
        // partial failure) and then mark every PR with a ticket as attempted, so the
        // UI stops showing the "Loading" placeholder even when Jira is unreachable.
        applyJiraMetadata(metadata, in: &openPRs)
        applyJiraMetadata(metadata, in: &mentionedPRs)
        applyJiraMetadata(metadata, in: &mergedPRs)
    }

    private func applyJiraMetadata(_ metadata: [String: JiraIssueMetadata], in prs: inout [PullRequest]) {
        let now = Date()
        for index in prs.indices {
            guard let ticket = prs[index].jiraTicket.map(JiraMetadataCache.normalizeIssueKey) else {
                continue
            }
            if let issue = metadata[ticket] {
                prs[index].jiraLabels = issue.labels
                prs[index].jiraTitle = issue.title
                prs[index].jiraStatusName = issue.statusName
                prs[index].jiraStatusCategoryKey = issue.statusCategoryKey
                prs[index].jiraUpdatedAt = issue.updatedAt
                prs[index].jiraMetadataFetchedAt = issue.fetchedAt
            } else {
                prs[index].jiraLabels = prs[index].jiraLabels ?? []
                prs[index].jiraMetadataFetchedAt = prs[index].jiraMetadataFetchedAt ?? now
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

        // When rate limit is critical, wait for reset regardless of the transient error kind.
        // Otherwise a 502-storm keeps burning remaining quota.
        if isRateLimitCritical {
            consecutiveTransientFailures = 0
            let delay = max(0, rateLimitInfo.resetDate.timeIntervalSinceNow) + Double.random(in: 1...3)
            return RecoveryRetryPlan(delay: delay, reason: "rate_limit_critical")
        }

        switch apiError {
        case .rateLimited(let resetDate):
            consecutiveTransientFailures = 0
            let delay = max(0, resetDate.timeIntervalSinceNow) + Double.random(in: 1...3)
            return RecoveryRetryPlan(delay: delay, reason: "rate_limited")
        case .network(_) where apiError.isTransient,
             .http(_) where apiError.isTransient:
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

    private static let criticalRateLimitThresholdPercent: Int = 15

    private var isRateLimitCritical: Bool {
        guard rateLimitInfo.limit > 0 else { return false }
        let threshold = max(1, rateLimitInfo.limit * Self.criticalRateLimitThresholdPercent / 100)
        return rateLimitInfo.remaining < threshold && rateLimitInfo.resetDate > Date()
    }

    private func scheduleRateLimitResume(at resetDate: Date) {
        cancelRecoveryRetry()
        consecutiveTransientFailures = 0
        let delay = max(0, resetDate.timeIntervalSinceNow) + Double.random(in: 1...3)
        recoveryRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay.nanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            self.recoveryRetryTask = nil
            self.requestRefresh(trigger: .recovery)
        }
    }

    private var isAutomaticRecoveryPaused: Bool {
        (isLowPowerMode && configuration.pausePollingInLowPowerMode) ||
        (isOnExpensiveNetwork && configuration.pausePollingOnExpensiveNetwork)
    }

    func rerunFailedCI(for pr: PullRequest) async throws -> Int {
        guard let headSHA = pr.headCommitOid else {
            throw APIError.unknown(String(localized: "No head commit SHA available for PR #\(pr.number)"))
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

    func updateBranchWithRebase(for pr: PullRequest) async throws {
        guard !updatingBranchPRIDs.contains(pr.id) else { return }
        guard pr.baseNeedsUpdate == true else { return }
        guard let pullRequestId = pr.graphqlNodeId else {
            throw APIError.unknown(String(localized: "No GitHub node ID available for PR #\(pr.number)"))
        }

        setBranchUpdating(true, for: pr.id)
        defer {
            setBranchUpdating(false, for: pr.id)
        }

        let result = try await apiClient.updatePullRequestBranchWithRebase(
            pullRequestId: pullRequestId,
            expectedHeadOid: pr.headCommitOid
        )
        updateBranchMetadata(for: pr.id, result: result)
        logger.info("Requested rebase branch update for PR #\(pr.number)")

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.requestRefresh(trigger: .manual)
        }
    }

    func loadHoverDetailIfNeeded(for pr: PullRequest) {
        guard needsHoverDetailFetch(pr) else { return }
        let includeCI = needsHoverCIFetch(pr)

        if let cached = hoverDetailCache[pr.id], cached.isUsable(for: pr) {
            applyHoverMetadata(cached.metadata)
            return
        }

        guard hoverDetailTasks[pr.id] == nil else { return }
        guard rateLimitInfo.hasHeadroomForHoverDetails else {
            logger.warning(
                "Skipping hover detail fetch due to rate-limit floor: remaining=\(self.rateLimitInfo.remaining, privacy: .public)/\(self.rateLimitInfo.limit, privacy: .public)"
            )
            return
        }

        setHoverDetailLoading(true, for: pr.id)
        hoverDetailTasks[pr.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.hoverDetailTasks[pr.id] = nil
                self.setHoverDetailLoading(false, for: pr.id)
            }

            do {
                let metadata = try await self.apiClient.fetchHoverMetadata(for: pr, includeCI: includeCI)
                self.hoverDetailCache[pr.id] = HoverDetailCacheEntry(
                    metadata: metadata,
                    prUpdatedAt: pr.updatedAt,
                    headCommitOid: pr.headCommitOid,
                    fetchedAt: Date()
                )
                self.applyHoverMetadata(metadata)
                logger.info("Loaded hover detail metadata for \(pr.repoFullName)#\(pr.number, privacy: .public)")
            } catch {
                if error is CancellationError || ((error as? APIError)?.isCancellation == true) {
                    return
                }
                logger.error("Failed to load hover detail metadata for \(pr.repoFullName)#\(pr.number, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func refreshSinglePRCI(for pr: PullRequest) async {
        do {
            let result = try await apiClient.fetchSinglePRCIStatus(
                owner: pr.repositoryOwner, repo: pr.repositoryName, number: pr.number
            )
            if let index = prList.pullRequests.firstIndex(where: { $0.id == pr.id }) {
                prList.pullRequests[index].ciStatus = result.ciStatus
                prList.pullRequests[index].checkSuccessCount = result.checkSuccessCount
                prList.pullRequests[index].checkFailureCount = result.checkFailureCount
                prList.pullRequests[index].checkPendingCount = result.checkPendingCount
                prList.pullRequests[index].ciExtendedInfo = result.ciExtendedInfo
                logger.info("Refreshed single PR CI status for #\(pr.number): \(result.ciStatus?.rawValue ?? "nil")")
            }
        } catch {
            logger.error("Failed to refresh single PR CI for #\(pr.number): \(error.localizedDescription)")
        }
    }

    private func refreshBaseUpdateStatuses(prs: inout [PullRequest]) async {
        guard rateLimitInfo.hasHeadroomForHoverDetails else {
            logger.warning(
                "Skipping base update status refresh due to rate-limit floor: remaining=\(self.rateLimitInfo.remaining, privacy: .public)/\(self.rateLimitInfo.limit, privacy: .public)"
            )
            return
        }

        let candidateIndices = prs.indices.filter { index in
            let pr = prs[index]
            return pr.category == .authored &&
                pr.state == .open &&
                !pr.hasBaseConflicts &&
                pr.baseRefName?.isEmpty == false &&
                pr.headRefName?.isEmpty == false
        }.prefix(Self.maxBaseUpdateStatusRefreshes)

        guard !candidateIndices.isEmpty else { return }

        var refreshed = 0
        for index in candidateIndices {
            let pr = prs[index]
            guard let base = pr.baseRefName,
                  let head = pr.headRefName else {
                continue
            }

            do {
                prs[index].baseNeedsUpdate = try await apiClient.fetchBaseNeedsUpdateByCompare(
                    owner: pr.repositoryOwner,
                    repo: pr.repositoryName,
                    base: base,
                    head: head
                )
                refreshed += 1
            } catch {
                logger.warning(
                    "Failed to refresh base update status for \(pr.repoFullName)#\(pr.number, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if refreshed > 0 {
            logger.info("Refreshed base update status for \(refreshed, privacy: .public) authored PRs")
        }
    }

    private func refreshCmuxOpenStatuses(
        openPRs: inout [PullRequest],
        mentionedPRs: inout [PullRequest],
        mergedPRs: inout [PullRequest]
    ) async {
        guard configuration.openAtCmuxFirst, let cmuxStatusProvider else {
            clearCmuxOpenStatus(openPRs: &openPRs, mentionedPRs: &mentionedPRs, mergedPRs: &mergedPRs)
            return
        }

        let openIdentities = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: cmuxStatusProvider.openPRIdentities())
            }
        }

        func apply(to prs: inout [PullRequest]) {
            for index in prs.indices {
                guard let identity = GitHubPRIdentity(url: prs[index].url) else {
                    prs[index].isOpenInCmux = false
                    continue
                }
                prs[index].isOpenInCmux = openIdentities.contains(identity)
            }
        }

        apply(to: &openPRs)
        apply(to: &mentionedPRs)
        apply(to: &mergedPRs)
        logger.info("Refreshed cmux open status: openPRIdentities=\(openIdentities.count, privacy: .public)")
    }

    private func clearCmuxOpenStatus(
        openPRs: inout [PullRequest],
        mentionedPRs: inout [PullRequest],
        mergedPRs: inout [PullRequest]
    ) {
        func clear(_ prs: inout [PullRequest]) {
            for index in prs.indices {
                prs[index].isOpenInCmux = nil
            }
        }
        clear(&openPRs)
        clear(&mentionedPRs)
        clear(&mergedPRs)
    }

    private func clearCmuxOpenStatus(in prList: inout PRList) {
        clearCmuxOpenStatus(
            openPRs: &prList.pullRequests,
            mentionedPRs: &prList.mentionedPullRequests,
            mergedPRs: &prList.mergedPullRequests
        )
    }

    private func updateBranchMetadata(
        for prID: Int,
        result: GitHubAPIClient.UpdatePullRequestBranchResult
    ) {
        func apply(to prs: inout [PullRequest]) {
            guard let index = prs.firstIndex(where: { $0.id == prID }) else { return }
            if let headCommitOid = result.headCommitOid {
                prs[index].headCommitOid = headCommitOid
            }
            if let lastCommitAt = result.lastCommitAt {
                prs[index].lastCommitAt = lastCommitAt
            }
            prs[index].baseNeedsUpdate = result.baseNeedsUpdate
        }

        apply(to: &prList.pullRequests)
        apply(to: &prList.mentionedPullRequests)
        apply(to: &prList.mergedPullRequests)
    }

    private func needsHoverDetailFetch(_ pr: PullRequest) -> Bool {
        if pr.approvalAuthors == nil || pr.changesRequestedAuthors == nil {
            return true
        }
        if pr.baseNeedsUpdate == nil || pr.baseRefName == nil || pr.headRefName == nil {
            return true
        }
        if needsHoverCIFetch(pr) {
            return true
        }
        return false
    }

    private func needsHoverCIFetch(_ pr: PullRequest) -> Bool {
        (pr.ciStatus == .failure || pr.ciStatus == .unknown || pr.checkFailureCount > 0) &&
            pr.failedWorkflowNames.isEmpty
    }

    private func applyHoverMetadata(_ metadata: GitHubAPIClient.PRHoverMetadata) {
        func apply(to prs: inout [PullRequest]) {
            guard let index = prs.firstIndex(where: { $0.id == metadata.databaseId }) else { return }
            prs[index].graphqlNodeId = metadata.graphqlNodeId ?? prs[index].graphqlNodeId
            prs[index].baseRefName = metadata.baseRefName ?? prs[index].baseRefName
            prs[index].headRefName = metadata.headRefName ?? prs[index].headRefName
            prs[index].baseNeedsUpdate = metadata.baseNeedsUpdate ?? prs[index].baseNeedsUpdate
            prs[index].approvalAuthors = metadata.approvalAuthors
            prs[index].changesRequestedAuthors = metadata.changesRequestedAuthors
            prs[index].approvalCount = metadata.approvalCount
            prs[index].changesRequestedCount = metadata.changesRequestedCount
            if let headCommitOid = metadata.headCommitOid {
                prs[index].headCommitOid = headCommitOid
            }
            if let lastCommitAt = metadata.lastCommitAt {
                prs[index].lastCommitAt = lastCommitAt
            }
            if let ciStatus = metadata.ciStatus {
                prs[index].ciStatus = ciStatus
            }
            if let checkSuccessCount = metadata.checkSuccessCount {
                prs[index].checkSuccessCount = checkSuccessCount
            }
            if let checkFailureCount = metadata.checkFailureCount {
                prs[index].checkFailureCount = checkFailureCount
            }
            if let checkPendingCount = metadata.checkPendingCount {
                prs[index].checkPendingCount = checkPendingCount
            }
            if let githubCIState = metadata.githubCIState {
                prs[index].githubCIState = githubCIState
            }
            if let ciExtendedInfo = metadata.ciExtendedInfo {
                prs[index].ciExtendedInfo = ciExtendedInfo
            }
        }

        apply(to: &prList.pullRequests)
        apply(to: &prList.mentionedPullRequests)
        apply(to: &prList.mergedPullRequests)
        PRCache.shared.save(prList)
    }

    private func setBranchUpdating(_ isUpdating: Bool, for prID: Int) {
        guard isUpdating != updatingBranchPRIDs.contains(prID) else { return }
        if isUpdating {
            updatingBranchPRIDs.insert(prID)
        } else {
            updatingBranchPRIDs.remove(prID)
        }
    }

    private func setHoverDetailLoading(_ isLoading: Bool, for prID: Int) {
        guard isLoading != loadingHoverDetailPRIDs.contains(prID) else { return }
        if isLoading {
            loadingHoverDetailPRIDs.insert(prID)
        } else {
            loadingHoverDetailPRIDs.remove(prID)
        }
    }

    func updateConfiguration(_ config: Configuration) {
        updateConfiguration(config, jiraTokenChanged: false)
    }

    /// Atomically update the four Jira credential fields. Saves the token to the Keychain,
    /// invalidates the Jira metadata cache if anything material changed, and triggers a single
    /// refresh — coalescing what would otherwise be split between SettingsView and PRManager.
    func updateJiraCredentials(
        serverURL: String,
        email: String,
        apiToken: String,
        refreshInterval: TimeInterval
    ) {
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenChanged = Keychain.loadJiraAPIToken() != trimmedToken
        Keychain.saveJiraAPIToken(apiToken)

        var newConfig = configuration
        newConfig.jiraServerURL = serverURL
        newConfig.jiraEmail = email
        newConfig.jiraRefreshInterval = refreshInterval
        updateConfiguration(newConfig, jiraTokenChanged: tokenChanged)
    }

    private func updateConfiguration(_ config: Configuration, jiraTokenChanged: Bool) {
        let previousOpenAtCmuxFirst = configuration.openAtCmuxFirst
        let previousJiraServerURL = configuration.jiraServerURL
        let previousJiraEmail = configuration.jiraEmail
        configuration = config
        Self.saveConfiguration(config)

        apiClient.updateGraphQLEndpoint(config.graphQLEndpoint)
        apiClient.updateProxy(
            urlString: config.httpProxyURL,
            username: config.httpProxyUsername,
            password: Keychain.loadProxyPassword()
        )

        // Restart polling with new interval if currently polling
        if timer != nil {
            enablePolling(true)
        }

        if previousOpenAtCmuxFirst != config.openAtCmuxFirst {
            var updated = prList
            clearCmuxOpenStatus(in: &updated)
            prList = updated
            if config.openAtCmuxFirst {
                requestRefresh(trigger: .manual)
            }
        }

        let jiraServerOrEmailChanged = previousJiraServerURL != config.jiraServerURL
            || previousJiraEmail != config.jiraEmail
        if jiraServerOrEmailChanged || jiraTokenChanged {
            JiraMetadataCache.shared.clear()
            var updated = prList
            clearJiraMetadata(in: &updated)
            prList = updated
            requestRefresh(trigger: .manual)
        }

        isJiraConfigured = Self.computeJiraConfigured(
            config: config,
            tokenPresent: !Keychain.loadJiraAPIToken().isEmpty
        )
    }

    private func clearJiraMetadata(in prList: inout PRList) {
        clearJiraMetadata(in: &prList.pullRequests)
        clearJiraMetadata(in: &prList.mentionedPullRequests)
        clearJiraMetadata(in: &prList.mergedPullRequests)
    }

    private func clearJiraMetadata(in prs: inout [PullRequest]) {
        for index in prs.indices {
            prs[index].jiraLabels = nil
            prs[index].jiraTitle = nil
            prs[index].jiraStatusName = nil
            prs[index].jiraStatusCategoryKey = nil
            prs[index].jiraUpdatedAt = nil
            prs[index].jiraMetadataFetchedAt = nil
        }
    }

    // MARK: - Review Comment Read State

    func markReviewCommentsRead(for pr: PullRequest) {
        updateReviewCommentReadState(for: pr, isRead: true)
    }

    func markReviewCommentsUnread(for pr: PullRequest) {
        updateReviewCommentReadState(for: pr, isRead: false)
    }

    private func updateReviewCommentReadState(for pr: PullRequest, isRead: Bool) {
        let threadIDs = unresolvedReviewThreadIDs(for: pr)
        guard !threadIDs.isEmpty else { return }

        var updated = readReviewThreadIDs
        if isRead {
            updated.formUnion(threadIDs)
        } else {
            updated.subtract(threadIDs)
        }

        guard updated != readReviewThreadIDs else { return }

        readReviewThreadIDs = updated
        Self.saveReadReviewThreadIDs(updated)
        refreshReadStateOverlay()

        let action = isRead ? "read" : "unread"
        logger.info(
            "Marked review comments \(action, privacy: .public): \(pr.pinIdentifier, privacy: .public) threads=\(threadIDs.count, privacy: .public)"
        )
    }

    private func unresolvedReviewThreadIDs(for pr: PullRequest) -> Set<String> {
        Set(pr.reviewThreads.lazy.filter(\.isUnresolved).map(\.id))
    }

    private func refreshReadStateOverlay() {
        var updated = prList
        applyReadState(to: &updated)
        prList = updated
    }

    private func applyReadState(to prList: inout PRList) {
        applyReadState(to: &prList.pullRequests)
        applyReadState(to: &prList.mentionedPullRequests)
        applyReadState(to: &prList.mergedPullRequests)
    }

    private func applyReadState(to prs: inout [PullRequest]) {
        for prIndex in prs.indices {
            for threadIndex in prs[prIndex].reviewThreads.indices {
                let threadID = prs[prIndex].reviewThreads[threadIndex].id
                prs[prIndex].reviewThreads[threadIndex].isRead = readReviewThreadIDs.contains(threadID)
            }
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
                    if newStatus == .failure && pinnedPRIdentifiers.contains(pr.pinIdentifier) {
                        continue
                    }
                    notificationManager.notifyCIStatusChange(pr: pr, newStatus: newStatus)
                }
            }
        }
    }

    private func notifyPinnedMajorEvents(newPRs: [PullRequest]) {
        guard !pinnedPRIdentifiers.isEmpty else {
            previousPinnedMajorEvents.removeAll(keepingCapacity: true)
            return
        }

        var nextState: [Int: Set<PinnedMajorPREvent>] = [:]

        for pr in newPRs where pinnedPRIdentifiers.contains(pr.pinIdentifier) {
            guard pr.category == .authored || pr.category == .reviewRequest else { continue }

            let events = PinnedMajorPRNotificationPlanner.events(for: pr)
            let currentSet = Set(events)

            // Suppress on first sighting (cold start, newly pinned) — record state and wait for next delta.
            if let previousSet = previousPinnedMajorEvents[pr.id] {
                let newEvents = events.filter { !previousSet.contains($0) }
                if !newEvents.isEmpty {
                    notificationManager.notifyPinnedMajorEvents(pr: pr, events: newEvents)
                }
            }

            nextState[pr.id] = currentSet
        }

        previousPinnedMajorEvents = nextState
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
    private static let readReviewThreadIDsKey = "PRDashboard.ReadReviewThreadIDs"

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

    private static func loadStringSet(forKey key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func saveStringSet(_ values: Set<String>, forKey key: String) {
        UserDefaults.standard.set(Array(values), forKey: key)
    }

    private static func loadPinnedPRs() -> Set<String> {
        loadStringSet(forKey: pinnedPRsKey)
    }

    private static func savePinnedPRs(_ identifiers: Set<String>) {
        saveStringSet(identifiers, forKey: pinnedPRsKey)
    }

    private static func loadReadReviewThreadIDs() -> Set<String> {
        loadStringSet(forKey: readReviewThreadIDsKey)
    }

    private static func saveReadReviewThreadIDs(_ identifiers: Set<String>) {
        saveStringSet(identifiers, forKey: readReviewThreadIDsKey)
    }
}
