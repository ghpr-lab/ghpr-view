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

enum CIStatusNotificationPlanner {
    static func notificationStatus(previous: PullRequest?, current: PullRequest) -> CIStatus? {
        guard let previous else { return nil }
        return notificationStatus(previous: previous.ciStatus, current: current.ciStatus)
    }

    static func notificationStatus(previous: CIStatus?, current: CIStatus?) -> CIStatus? {
        guard previous != current,
              let current,
              current == .success || current == .failure else {
            return nil
        }
        return current
    }
}

enum CIWatchPlanner {
    static func watchCandidates(from prList: PRList) -> [PullRequest] {
        var seenIDs = Set<Int>()
        return prList.allPRs.filter { pr in
            pr.state == .open &&
                pr.ciIsInFlight &&
                seenIDs.insert(pr.id).inserted
        }
    }

    static func shouldRun(for prList: PRList) -> Bool {
        // Only existence matters here, so short-circuit on the first in-flight PR
        // instead of allocating the full (deduped) candidate list.
        prList.allPRs.contains { $0.state == .open && $0.ciIsInFlight }
    }
}

enum PullRequestFilter {
    static func includes(
        repoFullName: String,
        isArchived: Bool?,
        isDraft: Bool,
        configuration: Configuration
    ) -> Bool {
        let repositoryFilters = configuration.repositories.map { $0.lowercased() }
        let repo = repoFullName.lowercased()
        let matchesRepositoryFilter = repositoryFilters.contains { filter in
            filter.hasSuffix("/") ? repo.hasPrefix(filter) : repo == filter
        }
        let isExplicitlyIncluded = repositoryFilters.contains(repo)

        if !repositoryFilters.isEmpty && !matchesRepositoryFilter {
            return false
        }
        if isArchived == true && !isExplicitlyIncluded {
            return false
        }
        return configuration.showDrafts || !isDraft
    }

    static func apply(_ pullRequests: [PullRequest], configuration: Configuration) -> [PullRequest] {
        pullRequests.filter {
            includes(
                repoFullName: $0.repoFullName,
                isArchived: $0.repositoryIsArchived,
                isDraft: $0.isDraft,
                configuration: configuration
            )
        }
    }

    static func apply(to prList: inout PRList, configuration: Configuration) {
        prList.pullRequests = apply(prList.pullRequests, configuration: configuration)
        prList.mentionedPullRequests = apply(prList.mentionedPullRequests, configuration: configuration)
        prList.directMentionPullRequests = apply(
            prList.directMentionPullRequests,
            configuration: configuration
        )
        prList.mergedPullRequests = apply(prList.mergedPullRequests, configuration: configuration)
    }
}

struct DirectMentionProjection {
    var pullRequests: [PullRequest]
    var mentionedPullRequests: [PullRequest]
    var directMentionPullRequests: [PullRequest]
}

enum DirectMentionProjector {
    static func project(
        entries: [Int: DirectMentionTrackingEntry],
        onto pullRequests: [PullRequest],
        mentionedPullRequests: [PullRequest],
        mergedIDs: Set<Int>
    ) -> DirectMentionProjection {
        var visibleIDs = Set<Int>()

        func projectKnown(
            _ pullRequests: [PullRequest],
            excludingActiveDirectMentions: Bool = false
        ) -> [PullRequest] {
            var projected: [PullRequest] = []
            projected.reserveCapacity(pullRequests.count)

            for var pullRequest in pullRequests {
                if excludingActiveDirectMentions,
                   let entry = entries[pullRequest.id],
                   entry.state.pendingCount > 0,
                   entry.pullRequest.state == .open {
                    continue
                }
                guard pullRequest.state == .open,
                      !mergedIDs.contains(pullRequest.id),
                      visibleIDs.insert(pullRequest.id).inserted else {
                    continue
                }
                let entryIsOpen = entries[pullRequest.id].map {
                    $0.pullRequest.state == .open
                } ?? true
                let pendingCount = entryIsOpen
                    ? (entries[pullRequest.id]?.state.pendingCount ?? 0)
                    : 0
                pullRequest.mentionCount = pendingCount > 0 ? pendingCount : nil
                projected.append(pullRequest)
            }
            return projected
        }

        let projectedPullRequests = projectKnown(pullRequests)
        let projectedMentionedPullRequests = projectKnown(
            mentionedPullRequests,
            excludingActiveDirectMentions: true
        )

        var directMentionPullRequests: [PullRequest] = []
        for (id, entry) in entries {
            guard entry.state.pendingCount > 0,
                  !visibleIDs.contains(id),
                  !mergedIDs.contains(id),
                  entry.pullRequest.state == .open else {
                continue
            }

            var pullRequest = entry.pullRequest
            pullRequest.category = .directMention
            pullRequest.mentionCount = entry.state.pendingCount
            directMentionPullRequests.append(pullRequest)
        }
        directMentionPullRequests.sort {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id < $1.id
        }

        return DirectMentionProjection(
            pullRequests: projectedPullRequests,
            mentionedPullRequests: projectedMentionedPullRequests,
            directMentionPullRequests: directMentionPullRequests
        )
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

@MainActor
final class PRManager: PRManagerType, ObservableObject {
    @Published private(set) var prList: PRList = .empty
    @Published private(set) var refreshState: RefreshState = .idle
    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty
    @Published var configuration: Configuration
    @Published private(set) var pinnedPRIdentifiers: Set<String>
    @Published private(set) var readReviewThreadIDs: Set<String>
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
    private var ciWatchTimer: Timer?
    private var activeRefreshTask: Task<Void, Never>?
    private var ciWatchTask: Task<Void, Never>?
    private var mentionedRefreshTask: Task<Void, Never>?
    private var directMentionTask: Task<Void, Never>?
    private var mentionedRefreshPublishVersion: UInt64 = 0
    private var directMentionTracking: [Int: DirectMentionTrackingEntry] = [:]
    private var recoveryRetryTask: Task<Void, Never>?
    private var queuedRefresh = false
    private var consecutiveTransientFailures = 0
    private var backgroundRefreshGeneration = 0
    private var lastDirectMentionDiscoveryAt: Date?
    private var lastMentionedRefreshStartedAt: Date?
    private var lastMentionedRefreshSucceededAt: Date?
    private var lastAuthoredMentionReferenceCoverageAt: Date?
    private var lastAuthoredMentionReferenceCoverageUsername: String?
    private var previousPRs: [Int: PullRequest] = [:]
    private var previousPinnedMajorEvents: [Int: Set<PinnedMajorPREvent>] = [:]
    private var hoverDetailTasks: [Int: Task<Void, Never>] = [:]
    private var hoverDetailCache: [Int: HoverDetailCacheEntry] = [:]
    private let cmuxStatusProvider: CmuxPRStatusProviding?
    private static let maxBaseUpdateStatusRefreshes = 20
    private var cancellables = Set<AnyCancellable>()
    private var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var isOnExpensiveNetwork: Bool = false
    private let networkMonitor = NWPathMonitor()
    private static let directMentionDiscoveryInterval: TimeInterval = 60 * 60
    private static let mentionedRefreshThrottle: TimeInterval = 30 * 60
    private static let ciWatchInterval: TimeInterval = 30
    private static let lastDirectMentionDiscoveryAtKey = "PRDashboard.LastDirectMentionDiscoveryAt"
    private static let lastMentionedRefreshSucceededAtKey = "PRDashboard.LastMentionedRefreshSucceededAt"
    private static let lastAuthoredMentionReferenceCoverageAtKey = "PRDashboard.LastAuthoredMentionReferenceCoverageAt"
    private static let lastAuthoredMentionReferenceCoverageUsernameKey = "PRDashboard.LastAuthoredMentionReferenceCoverageUsername"

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
        self.lastDirectMentionDiscoveryAt = Self.loadDate(
            forKey: Self.lastDirectMentionDiscoveryAtKey
        )
        self.lastMentionedRefreshSucceededAt = Self.loadDate(
            forKey: Self.lastMentionedRefreshSucceededAtKey
        )
        self.lastAuthoredMentionReferenceCoverageAt = Self.loadDate(
            forKey: Self.lastAuthoredMentionReferenceCoverageAtKey
        )
        self.lastAuthoredMentionReferenceCoverageUsername = UserDefaults.standard.string(
            forKey: Self.lastAuthoredMentionReferenceCoverageUsernameKey
        )

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
        ciWatchTask?.cancel()
        ciWatchTimer?.invalidate()
        directMentionTask?.cancel()
        mentionedRefreshTask?.cancel()
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
                Task { @MainActor [weak self] in
                    self?.rateLimitInfo = info
                    self?.updateCIWatchTimer()
                }
            }
            .store(in: &cancellables)

        // Re-evaluate the fast CI watch whenever the snapshot changes. Deriving it from
        // the single source of truth means any path that surfaces in-flight CI (main poll,
        // manual refresh, direct-mention maintenance, cache load, single-PR refresh) arms the
        // watch — no manual call site can be forgotten. Debounced so a burst of per-field
        // mutations during a refresh collapses into one evaluation, and so the closure reads
        // the committed `prList` rather than the pre-update value @Published delivers.
        $prList
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateCIWatchTimer()
                }
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
            stopCIWatchTimer(reason: "expensive_network")
            invalidateBackgroundRefreshWork(reason: "expensive_network")
            cancelRecoveryRetry()
        } else if !isOnExpensiveNetwork && wasExpensive {
            if oauthManager.authState.isAuthenticated {
                enablePolling(true)
            }
            updateCIWatchTimer()
        }
    }

    private func handlePowerStateChange() {
        let wasLowPowerMode = isLowPowerMode
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        guard configuration.pausePollingInLowPowerMode else { return }

        if isLowPowerMode && !wasLowPowerMode {
            timer?.invalidate()
            timer = nil
            stopCIWatchTimer(reason: "low_power_mode")
            invalidateBackgroundRefreshWork(reason: "low_power_mode")
            cancelRecoveryRetry()
        } else if !isLowPowerMode && wasLowPowerMode {
            if oauthManager.authState.isAuthenticated {
                enablePolling(true)
            }
            updateCIWatchTimer()
        }
    }

    private func handleAuthStateChange(_ authState: AuthState) {
        invalidateBackgroundRefreshWork(reason: "auth_state_change")
        apiClient.updateToken(authState.accessToken ?? "")

        if authState.isAuthenticated {
            cancelRecoveryRetry(resetFailureCount: true)
            enablePolling(true, refreshTrigger: .auth, refreshIfNeeded: false)
            requestRefresh(trigger: .auth)
        } else {
            enablePolling(false)
            stopCIWatchTimer(reason: "sign_out")
            cancelRefreshWork(reason: "sign_out")
            prList = .empty
            directMentionTracking = [:]
            previousPRs = [:]
            previousPinnedMajorEvents = [:]
            hoverDetailTasks.values.forEach { $0.cancel() }
            hoverDetailTasks = [:]
            hoverDetailCache = [:]
            loadingHoverDetailPRIDs = []
            // Clear caches on sign-out
            PRCache.shared.clear()
            PRDetailCache.shared.clear()
            DirectMentionTrackingCache.shared.clear()
            AuthoredMentionReferenceCache.shared.clear()
            AvatarCache.shared.clear()
            lastDirectMentionDiscoveryAt = nil
            Self.saveDate(nil, forKey: Self.lastDirectMentionDiscoveryAtKey)
            lastMentionedRefreshStartedAt = nil
            lastMentionedRefreshSucceededAt = nil
            lastAuthoredMentionReferenceCoverageAt = nil
            lastAuthoredMentionReferenceCoverageUsername = nil
            Self.saveDate(nil, forKey: Self.lastMentionedRefreshSucceededAtKey)
            Self.saveDate(nil, forKey: Self.lastAuthoredMentionReferenceCoverageAtKey)
            UserDefaults.standard.removeObject(
                forKey: Self.lastAuthoredMentionReferenceCoverageUsernameKey
            )
        }
    }

    /// Load cached PR data on startup for immediate display. Legacy mentioned PRs
    /// stay in their own list; direct mention tracking is projected independently.
    func loadCachedData() {
        directMentionTracking = DirectMentionTrackingCache.shared.load()
        if var cached = PRCache.shared.load() {
            prepareCachedPRList(&cached)
            self.prList = cached
            previousPRs = Self.previousPRState(from: cached.allPRs)
            updateCIWatchTimer()
            persistProjectedCaches()
        }
    }

    private func prepareCachedPRList(_ cached: inout PRList) {
        clearCmuxOpenStatus(in: &cached)

        let openPRs = filterByConfiguration(
            cached.pullRequests.filter {
                $0.category == .authored || $0.category == .reviewRequest
            }
        )
        let legacyMentionedPRs = filterByConfiguration(
            cached.mentionedPullRequests.filter {
                !(($0.mentionCount ?? 0) > 0 && directMentionTracking[$0.id] != nil)
            }
        )
        let mergedPRs = filterByConfiguration(cached.mergedPullRequests)
        let projection = projectDirectMentions(
            onto: openPRs,
            mentionedPullRequests: legacyMentionedPRs,
            mergedPRs: mergedPRs
        )

        cached.pullRequests = projection.pullRequests
        cached.mentionedPullRequests = projection.mentionedPullRequests
        cached.directMentionPullRequests = projection.directMentionPullRequests
        cached.mergedPullRequests = mergedPRs.map { pr in
            var copy = pr
            copy.mentionCount = nil
            return copy
        }
        applyReadState(to: &cached)
    }

    func enablePolling(_ enabled: Bool) {
        enablePolling(enabled, refreshTrigger: .timer, refreshIfNeeded: true)
    }

    private func enablePolling(_ enabled: Bool, refreshTrigger: RefreshTrigger, refreshIfNeeded: Bool) {
        if !enabled {
            timer?.invalidate()
            timer = nil
            stopCIWatchTimer(reason: "polling_disabled")
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

    func clearDirectMentionTracking() {
        invalidateBackgroundRefreshWork(reason: "cache_cleared")
        directMentionTracking = [:]
        DirectMentionTrackingCache.shared.clear()
        let projection = DirectMentionProjector.project(
            entries: [:],
            onto: prList.pullRequests,
            mentionedPullRequests: prList.mentionedPullRequests,
            mergedIDs: Set(prList.mergedPullRequests.map(\.id))
        )
        prList.pullRequests = projection.pullRequests
        prList.mentionedPullRequests = projection.mentionedPullRequests
        prList.directMentionPullRequests = []
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
                let mentionedRefreshPublishVersion = self.mentionedRefreshPublishVersion
                let unfilteredOpenPRs = result.openPRs
                let unfilteredMergedPRs = result.mergedPRs
                var prs = self.filterByConfiguration(result.openPRs)
                var mergedPRs = self.filterByConfiguration(result.mergedPRs)
                var mentionedPRs = self.filterByConfiguration(
                    self.prList.mentionedPullRequests
                )
                var directMentionPRs = self.filterByConfiguration(
                    self.prList.directMentionPullRequests
                )
                mentionedPRs = await self.apiClient.refreshMentionedCIStatuses(mentionedPRs)
                directMentionPRs = await self.apiClient.refreshMentionedCIStatuses(
                    directMentionPRs
                )
                mentionedPRs = self.filterByConfiguration(mentionedPRs)
                directMentionPRs = self.filterByConfiguration(directMentionPRs)

                self.applyReadState(to: &prs)
                self.applyReadState(to: &mentionedPRs)
                self.applyReadState(to: &directMentionPRs)
                self.applyReadState(to: &mergedPRs)

                logger.info(
                    "After filters: \(prs.count) open PRs, \(mentionedPRs.count) mentioned PRs, \(directMentionPRs.count) direct mention PRs, \(mergedPRs.count) merged PRs"
                )

                if configuration.notificationsEnabled {
                    checkForChangesAndNotify(newPRs: prs)
                    notifyPinnedMajorEvents(newPRs: prs)
                }

                // Enrich PRs with Jira tickets from body (fetches only for uncached PRs)
                do {
                    let jiraCache = try await apiClient.fetchJiraTickets(
                        for: prs + directMentionPRs + mergedPRs
                    )
                    GitHubAPIClient.applyJiraTickets(to: &prs, cache: jiraCache)
                    GitHubAPIClient.applyJiraTickets(to: &directMentionPRs, cache: jiraCache)
                    GitHubAPIClient.applyJiraTickets(to: &mergedPRs, cache: jiraCache)
                } catch {
                    logger.error("Failed to enrich Jira tickets: \(error.localizedDescription)")
                }

                await enrichJiraMetadata(
                    openPRs: &prs,
                    mentionedPRs: &mentionedPRs,
                    directMentionPRs: &directMentionPRs,
                    mergedPRs: &mergedPRs
                )

                await refreshBaseUpdateStatuses(prs: &prs)
                await refreshCmuxOpenStatuses(
                    openPRs: &prs,
                    mentionedPRs: &mentionedPRs,
                    directMentionPRs: &directMentionPRs,
                    mergedPRs: &mergedPRs
                )
                if self.mentionedRefreshPublishVersion != mentionedRefreshPublishVersion {
                    mentionedPRs = self.filterByConfiguration(
                        self.prList.mentionedPullRequests
                    )
                    self.applyReadState(to: &mentionedPRs)
                }
                self.updateDirectMentionTrackingRows(from: directMentionPRs)

                let projection = projectDirectMentions(
                    onto: prs,
                    mentionedPullRequests: mentionedPRs,
                    mergedPRs: mergedPRs
                )
                let newPRList = PRList(
                    lastUpdated: Date(),
                    pullRequests: projection.pullRequests,
                    mentionedPullRequests: projection.mentionedPullRequests,
                    directMentionPullRequests: projection.directMentionPullRequests,
                    mergedPullRequests: mergedPRs.map { pr in
                        var copy = pr
                        copy.mentionCount = nil
                        return copy
                    },
                    isLoading: false,
                    error: nil
                )
                self.prList = newPRList
                self.applyReadState(to: &self.prList)
                self.previousPRs = Self.previousPRState(from: self.prList.allPRs)
                self.refreshState = .idle
                self.consecutiveTransientFailures = 0
                self.cancelRecoveryRetry(resetFailureCount: true)

                self.persistProjectedCaches()
                self.updateCIWatchTimer()
                self.scheduleMentionedRefreshIfNeeded(
                    username: username,
                    openPRs: unfilteredOpenPRs,
                    mergedPRs: unfilteredMergedPRs,
                    mode: hadUsableData ? .hot : .cold
                )
                self.scheduleDirectMentionMaintenanceIfNeeded(username: username)
                logger.info(
                    "Refresh succeeded: trigger=\(trigger.rawValue, privacy: .public) openPRs=\(self.prList.pullRequests.count, privacy: .public) mentionedPRs=\(self.prList.mentionedPullRequests.count, privacy: .public) directMentionPRs=\(self.prList.directMentionPullRequests.count, privacy: .public) mergedPRs=\(self.prList.mergedPullRequests.count, privacy: .public)"
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
                    self.prepareCachedPRList(&cached)
                    self.prList = cached
                    self.prList.error = error
                    self.previousPRs = Self.previousPRState(from: cached.allPRs)
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
                self.scheduleDirectMentionMaintenanceIfNeeded(
                    username: username,
                    allowDiscovery: false
                )
                self.updateCIWatchTimer()
            }
        }
    }

    /// Apply `fetchIncremental` progress frame to the published `prList`. Runs on
    /// MainActor. Filters (repositories, drafts) are applied here so the partial
    /// view is consistent with user settings; mention state is projected from the
    /// current tracking store without changing the row's category or placement.
    private func applyIncrementalProgress(
        openPRs: [PullRequest],
        mergedPRs: [PullRequest],
        stage: GitHubAPIClient.IncrementalStage
    ) {
        let filteredOpen = filterByConfiguration(openPRs)
        let filteredMerged = filterByConfiguration(mergedPRs)
        let projection = projectDirectMentions(
            onto: filteredOpen,
            mentionedPullRequests: prList.mentionedPullRequests,
            mergedPRs: filteredMerged
        )

        var updated = prList
        updated.pullRequests = projection.pullRequests
        updated.mentionedPullRequests = projection.mentionedPullRequests
        updated.directMentionPullRequests = projection.directMentionPullRequests
        updated.mergedPullRequests = filteredMerged.map { pr in
            var copy = pr
            copy.mentionCount = nil
            return copy
        }
        updated.isLoading = true
        updated.error = nil
        applyReadState(to: &updated)
        prList = updated
        logger.debug(
            "Incremental progress: stage=\(stage.rawValue, privacy: .public) open=\(projection.pullRequests.count, privacy: .public) mentioned=\(projection.mentionedPullRequests.count, privacy: .public) directMentions=\(projection.directMentionPullRequests.count, privacy: .public) merged=\(filteredMerged.count, privacy: .public)"
        )
    }

    private func scheduleMentionedRefreshIfNeeded(
        username: String,
        openPRs: [PullRequest],
        mergedPRs: [PullRequest],
        mode: GitHubAPIClient.MentionRefreshMode
    ) {
        guard oauthManager.authState.isAuthenticated,
              oauthManager.authState.username == username,
              configuration.isValid else {
            return
        }
        guard mentionedRefreshTask == nil else {
            logger.info("Skipping mentioned refresh because a previous run is still active")
            return
        }
        guard !isRateLimitCritical,
              rateLimitInfo.hasHeadroomForMentions else {
            logger.info("Skipping mentioned refresh because rate limit floor is active")
            return
        }
        guard !isAutomaticRecoveryPaused else {
            logger.info("Skipping mentioned refresh because background polling is paused")
            return
        }

        let now = Date()
        if let lastMentionedRefreshStartedAt,
           now.timeIntervalSince(lastMentionedRefreshStartedAt) < Self.mentionedRefreshThrottle {
            logger.debug("Skipping mentioned refresh due to 30-minute throttle")
            return
        }

        let effectiveMode = effectiveMentionRefreshMode(
            requestedMode: mode,
            username: username
        )
        let options = mentionRefreshOptions(
            mode: effectiveMode,
            username: username,
            now: now
        )
        lastMentionedRefreshStartedAt = now
        let generation = backgroundRefreshGeneration
        logger.info(
            "Starting background mentioned refresh: mode=\(String(describing: effectiveMode), privacy: .public) authoredWindowDays=\(options.authoredReferenceDaysBack, privacy: .public)"
        )

        mentionedRefreshTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            let activityToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Background mentioned PR refresh"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activityToken)
                if self.backgroundRefreshGeneration == generation {
                    self.mentionedRefreshTask = nil
                }
            }

            let onProgress: @Sendable ([PullRequest]) async -> Void = { [weak self] partial in
                guard let self else { return }
                await self.applyMentionedProgress(
                    partial,
                    generation: generation,
                    username: username
                )
            }

            do {
                var mentionedPRs = try await self.apiClient.fetchMentionedPullRequests(
                    username: username,
                    openPRs: openPRs,
                    mergedPRs: mergedPRs,
                    options: options,
                    onProgress: onProgress
                )
                guard self.canApplyMentionedRefresh(
                    generation: generation,
                    username: username
                ) else {
                    return
                }

                mentionedPRs = self.filterByConfiguration(mentionedPRs)
                self.applyReadState(to: &mentionedPRs)

                do {
                    let jiraCache = try await self.apiClient.fetchJiraTickets(for: mentionedPRs)
                    GitHubAPIClient.applyJiraTickets(to: &mentionedPRs, cache: jiraCache)
                } catch {
                    logger.error(
                        "Failed to enrich mentioned Jira tickets: \(error.localizedDescription)"
                    )
                }

                guard self.canApplyMentionedRefresh(
                    generation: generation,
                    username: username
                ) else {
                    return
                }

                var emptyOpenPRs: [PullRequest] = []
                var emptyMergedPRs: [PullRequest] = []
                var emptyDirectMentionPRs: [PullRequest] = []
                await self.enrichJiraMetadata(
                    openPRs: &emptyOpenPRs,
                    mentionedPRs: &mentionedPRs,
                    directMentionPRs: &emptyDirectMentionPRs,
                    mergedPRs: &emptyMergedPRs
                )
                await self.refreshCmuxOpenStatuses(
                    openPRs: &emptyOpenPRs,
                    mentionedPRs: &mentionedPRs,
                    directMentionPRs: &emptyDirectMentionPRs,
                    mergedPRs: &emptyMergedPRs
                )

                guard self.canApplyMentionedRefresh(
                    generation: generation,
                    username: username
                ) else {
                    return
                }

                self.prList.mentionedPullRequests = mentionedPRs
                self.mentionedRefreshPublishVersion &+= 1
                self.prList.error = nil
                self.recordMentionedRefreshSucceeded(
                    mode: effectiveMode,
                    username: username,
                    at: Date()
                )
                self.applyDirectMentionProjectionAndPersist()
                logger.info(
                    "Background mentioned refresh succeeded: mentionedPRs=\(mentionedPRs.count, privacy: .public)"
                )
            } catch {
                if error is CancellationError || ((error as? APIError)?.isCancellation == true) {
                    logger.debug("Background mentioned refresh cancelled")
                    return
                }
                logger.error(
                    "Background mentioned refresh failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func effectiveMentionRefreshMode(
        requestedMode: GitHubAPIClient.MentionRefreshMode,
        username: String
    ) -> GitHubAPIClient.MentionRefreshMode {
        if requestedMode == .hot, !hasAuthoredMentionReferenceCoverage(for: username) {
            return .cold
        }
        return requestedMode
    }

    private func mentionRefreshOptions(
        mode: GitHubAPIClient.MentionRefreshMode,
        username: String,
        now: Date
    ) -> GitHubAPIClient.MentionRefreshOptions {
        let authoredCoverageAt = hasAuthoredMentionReferenceCoverage(for: username)
            ? lastAuthoredMentionReferenceCoverageAt
            : nil
        let authoredGapDays = gapDaysBack(since: authoredCoverageAt, now: now)
        let candidateGapDays = gapDaysBack(since: lastMentionedRefreshSucceededAt, now: now)
        return GitHubAPIClient.MentionRefreshOptions.background(
            mode: mode,
            authoredReferenceDaysBack: mode == .hot ? authoredGapDays : nil,
            descriptionCandidateDaysBack: mode == .hot ? candidateGapDays : nil
        )
    }

    private func gapDaysBack(since date: Date?, now: Date) -> Int? {
        guard let date else { return nil }
        let elapsed = max(0, now.timeIntervalSince(date))
        return max(1, Int(ceil(elapsed / 86_400))) + 1
    }

    private func recordMentionedRefreshSucceeded(
        mode: GitHubAPIClient.MentionRefreshMode,
        username: String,
        at date: Date
    ) {
        lastMentionedRefreshSucceededAt = date
        lastAuthoredMentionReferenceCoverageAt = date
        lastAuthoredMentionReferenceCoverageUsername = username
        Self.saveDate(date, forKey: Self.lastMentionedRefreshSucceededAtKey)
        Self.saveDate(date, forKey: Self.lastAuthoredMentionReferenceCoverageAtKey)
        UserDefaults.standard.set(
            username,
            forKey: Self.lastAuthoredMentionReferenceCoverageUsernameKey
        )

        if mode == .cold {
            logger.debug("Recorded cold mentioned refresh coverage timestamp")
        }
    }

    private func hasAuthoredMentionReferenceCoverage(for username: String) -> Bool {
        lastAuthoredMentionReferenceCoverageAt != nil &&
            lastAuthoredMentionReferenceCoverageUsername?
                .caseInsensitiveCompare(username) == .orderedSame
    }

    private func canApplyMentionedRefresh(generation: Int, username: String) -> Bool {
        backgroundRefreshGeneration == generation &&
            oauthManager.authState.isAuthenticated &&
            oauthManager.authState.username == username &&
            !isAutomaticRecoveryPaused &&
            configuration.isValid
    }

    private func applyMentionedProgress(
        _ partial: [PullRequest],
        generation: Int,
        username: String
    ) {
        guard canApplyMentionedRefresh(generation: generation, username: username) else {
            return
        }
        prList.mentionedPullRequests = filterByConfiguration(partial)
        mentionedRefreshPublishVersion &+= 1
        applyReadState(to: &prList.mentionedPullRequests)
        applyDirectMentionProjection()
        logger.debug(
            "Mentioned refresh progress: published \(self.prList.mentionedPullRequests.count, privacy: .public) partial mentioned PRs"
        )
    }

    private func scheduleDirectMentionMaintenanceIfNeeded(
        username: String,
        allowDiscovery: Bool = true
    ) {
        guard oauthManager.authState.isAuthenticated,
              oauthManager.authState.username == username,
              configuration.isValid else { return }
        guard directMentionTask == nil else {
            logger.info("Skipping direct mention maintenance because a previous run is still active")
            return
        }
        guard !isRateLimitCritical,
              rateLimitInfo.hasHeadroomForMentions else {
            logger.info("Skipping direct mention maintenance because rate limit floor is active")
            return
        }
        guard !isAutomaticRecoveryPaused else {
            logger.info("Skipping direct mention maintenance because background polling is paused")
            return
        }

        let now = Date()
        let shouldDiscover = allowDiscovery && (lastDirectMentionDiscoveryAt.map {
            now.timeIntervalSince($0) >= Self.directMentionDiscoveryInterval
        } ?? true)
        let discoveryStartedAt = shouldDiscover ? now : nil

        let generation = backgroundRefreshGeneration
        let entries = scopedDirectMentionTracking()
        let scopedIDs = Set(directMentionTracking.keys)
        directMentionTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            let activityToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Background direct mention maintenance"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activityToken)
                if self.backgroundRefreshGeneration == generation {
                    self.directMentionTask = nil
                }
            }

            guard !Task.isCancelled else { return }
            let refreshResult = await self.apiClient.refreshTrackedMentions(
                username: username,
                entries: entries
            )
            guard self.canApplyDirectMentionWork(generation: generation, username: username) else { return }
            self.applyDirectMentionRefresh(refreshResult, generation: generation, username: username)

            guard self.rateLimitInfo.hasHeadroomForMentions,
                  !self.isRateLimitCritical else {
                return
            }
            guard shouldDiscover,
                  !Task.isCancelled,
                  self.canApplyDirectMentionWork(generation: generation, username: username) else {
                return
            }
            let startedAt = discoveryStartedAt ?? now
            self.lastDirectMentionDiscoveryAt = startedAt
            Self.saveDate(startedAt, forKey: Self.lastDirectMentionDiscoveryAtKey)
            let discoveryResult = await self.apiClient.discoverDirectMentions(
                username: username,
                configuration: self.configuration,
                existingEntries: self.scopedDirectMentionTracking()
            )
            guard self.canApplyDirectMentionWork(generation: generation, username: username) else { return }
            self.applyDirectMentionDiscovery(
                discoveryResult,
                generation: generation,
                username: username,
                startedAt: startedAt,
                scopedIDs: scopedIDs
            )
        }
    }

    private func canApplyDirectMentionWork(generation: Int, username: String) -> Bool {
        backgroundRefreshGeneration == generation &&
            oauthManager.authState.isAuthenticated &&
            oauthManager.authState.username == username &&
            !isAutomaticRecoveryPaused &&
            configuration.isValid
    }

    private func applyDirectMentionRefresh(
        _ result: GitHubAPIClient.DirectMentionRefreshResult,
        generation: Int,
        username: String
    ) {
        guard canApplyDirectMentionWork(generation: generation, username: username) else { return }

        var changed = false
        for (id, baseSource) in result.baseSources {
            guard let current = directMentionTracking[id],
                  current.source == baseSource,
                  !result.failedIDs.contains(id) else {
                continue
            }

            if result.closedIDs.contains(id) {
                directMentionTracking.removeValue(forKey: id)
                prList.directMentionPullRequests.removeAll { $0.id == id }
                changed = true
                continue
            }
            if let refreshed = result.refreshed[id] {
                let rebased = rebaseDirectMentionEntry(refreshed, preserving: current)
                if current != rebased
                    || current.pullRequest.isDraft != rebased.pullRequest.isDraft
                    || current.pullRequest.repositoryIsArchived != rebased.pullRequest.repositoryIsArchived {
                    directMentionTracking[id] = rebased
                    changed = true
                }
            }
        }

        guard changed else { return }
        applyDirectMentionProjectionAndPersist()
    }
    private func rebaseDirectMentionEntry(
        _ refreshed: DirectMentionTrackingEntry,
        preserving current: DirectMentionTrackingEntry
    ) -> DirectMentionTrackingEntry {
        var rebased = refreshed
        rebased.pullRequest.graphqlNodeId = current.pullRequest.graphqlNodeId
        rebased.pullRequest.lastCommitAt = current.pullRequest.lastCommitAt
        rebased.pullRequest.headCommitOid = current.pullRequest.headCommitOid
        rebased.pullRequest.baseRefName = current.pullRequest.baseRefName
        rebased.pullRequest.headRefName = current.pullRequest.headRefName
        rebased.pullRequest.baseNeedsUpdate = current.pullRequest.baseNeedsUpdate
        rebased.pullRequest.approvalAuthors = current.pullRequest.approvalAuthors
        rebased.pullRequest.changesRequestedAuthors = current.pullRequest.changesRequestedAuthors
        rebased.pullRequest.reviewThreads = current.pullRequest.reviewThreads
        rebased.pullRequest.category = current.pullRequest.category
        rebased.pullRequest.ciStatus = current.pullRequest.ciStatus
        rebased.pullRequest.checkSuccessCount = current.pullRequest.checkSuccessCount
        rebased.pullRequest.checkFailureCount = current.pullRequest.checkFailureCount
        rebased.pullRequest.checkPendingCount = current.pullRequest.checkPendingCount
        rebased.pullRequest.githubCIState = current.pullRequest.githubCIState
        rebased.pullRequest.myLastReviewState = current.pullRequest.myLastReviewState
        rebased.pullRequest.myLastReviewAt = current.pullRequest.myLastReviewAt
        rebased.pullRequest.reviewRequestedAt = current.pullRequest.reviewRequestedAt
        rebased.pullRequest.myThreadsAllResolved = current.pullRequest.myThreadsAllResolved
        rebased.pullRequest.approvalCount = current.pullRequest.approvalCount
        rebased.pullRequest.changesRequestedCount = current.pullRequest.changesRequestedCount
        rebased.pullRequest.ciExtendedInfo = current.pullRequest.ciExtendedInfo
        rebased.pullRequest.jiraTicket = current.pullRequest.jiraTicket
        rebased.pullRequest.jiraTitle = current.pullRequest.jiraTitle
        rebased.pullRequest.jiraLabels = current.pullRequest.jiraLabels
        rebased.pullRequest.jiraStatusName = current.pullRequest.jiraStatusName
        rebased.pullRequest.jiraStatusCategoryKey = current.pullRequest.jiraStatusCategoryKey
        rebased.pullRequest.jiraUpdatedAt = current.pullRequest.jiraUpdatedAt
        rebased.pullRequest.jiraMetadataFetchedAt = current.pullRequest.jiraMetadataFetchedAt
        rebased.pullRequest.isOpenInCmux = current.pullRequest.isOpenInCmux
        rebased.pullRequest.mentionCount = nil
        return rebased
    }


    private func applyDirectMentionDiscovery(
        _ result: GitHubAPIClient.DirectMentionDiscoveryResult,
        generation: Int,
        username: String,
        startedAt: Date,
        scopedIDs: Set<Int>
    ) {
        guard canApplyDirectMentionWork(generation: generation, username: username) else { return }

        let now = Date()
        var changed = false
        for (id, discovered) in result.discovered {
            guard PullRequestFilter.includes(
                repoFullName: discovered.pullRequest.repoFullName,
                isArchived: discovered.pullRequest.repositoryIsArchived,
                isDraft: discovered.pullRequest.isDraft,
                configuration: configuration
            ) else {
                continue
            }
            let candidate = directMentionTracking[id].map {
                rebaseDirectMentionEntry(discovered, preserving: $0)
            } ?? discovered
            if directMentionTracking[id] != candidate {
                directMentionTracking[id] = candidate
                changed = true
            }
        }

        for id in result.seenIDs {
            guard var entry = directMentionTracking[id] else { continue }
            let seenAt = max(entry.lastSeenAt, now)
            if entry.lastSeenAt != seenAt {
                entry.lastSeenAt = seenAt
                directMentionTracking[id] = entry
                changed = true
            }
        }

        if result.isComplete {
            for (id, entry) in directMentionTracking
            where scopedIDs.contains(id) &&
                !result.seenIDs.contains(id) &&
                entry.lastSeenAt <= startedAt {
                directMentionTracking.removeValue(forKey: id)
                changed = true
            }
        }

        guard changed else { return }
        applyDirectMentionProjectionAndPersist()
    }

    private func scopedDirectMentionTracking() -> [Int: DirectMentionTrackingEntry] {
        directMentionTracking.filter { _, entry in
            PullRequestFilter.includes(
                repoFullName: entry.pullRequest.repoFullName,
                isArchived: entry.pullRequest.repositoryIsArchived,
                isDraft: entry.pullRequest.isDraft,
                configuration: configuration
            )
        }
    }

    private func projectDirectMentions(
        onto openPRs: [PullRequest],
        mentionedPullRequests: [PullRequest],
        mergedPRs: [PullRequest]
    ) -> DirectMentionProjection {
        DirectMentionProjector.project(
            entries: scopedDirectMentionTracking(),
            onto: openPRs,
            mentionedPullRequests: mentionedPullRequests,
            mergedIDs: Set(mergedPRs.map(\.id))
        )
    }

    private func applyDirectMentionProjectionAndPersist() {
        applyDirectMentionProjection()
        persistProjectedCaches(forceTrackingWrite: true)
        updateCIWatchTimer()
    }
    
    private func updateDirectMentionTrackingRows(from pullRequests: [PullRequest]) {
        for pullRequest in pullRequests {
            guard var entry = directMentionTracking[pullRequest.id] else { continue }
            entry.pullRequest = pullRequest
            entry.pullRequest.mentionCount = nil
            directMentionTracking[pullRequest.id] = entry
        }
    }

    private func applyDirectMentionProjection() {
        let projection = projectDirectMentions(
            onto: prList.pullRequests,
            mentionedPullRequests: prList.mentionedPullRequests,
            mergedPRs: prList.mergedPullRequests
        )
        prList.pullRequests = projection.pullRequests
        prList.mentionedPullRequests = projection.mentionedPullRequests
        prList.directMentionPullRequests = projection.directMentionPullRequests
        prList.mergedPullRequests = prList.mergedPullRequests.map { pr in
            var copy = pr
            copy.mentionCount = nil
            return copy
        }
        applyReadState(to: &prList)
    }

    private func persistProjectedCaches(forceTrackingWrite: Bool = false) {
        DirectMentionTrackingCache.shared.save(
            directMentionTracking,
            force: forceTrackingWrite
        )
        PRCache.shared.save(prList)
    }

    private func filterByConfiguration(_ prs: [PullRequest]) -> [PullRequest] {
        PullRequestFilter.apply(prs, configuration: configuration)
    }

    private func enrichJiraMetadata(
        openPRs: inout [PullRequest],
        mentionedPRs: inout [PullRequest],
        directMentionPRs: inout [PullRequest],
        mergedPRs: inout [PullRequest]
    ) async {
        var issueKeys: Set<String> = []
        for list in [openPRs, mentionedPRs, directMentionPRs, mergedPRs] {
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
        applyJiraMetadata(metadata, in: &directMentionPRs)
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
        directMentionTask?.cancel()
        directMentionTask = nil
        mentionedRefreshTask?.cancel()
        mentionedRefreshTask = nil
        cancelRecoveryRetry(resetFailureCount: true)
        refreshState = .idle
        logger.info("Cancelled refresh work: reason=\(reason, privacy: .public)")
    }

    private func invalidateBackgroundRefreshWork(reason: String) {
        backgroundRefreshGeneration += 1
        lastDirectMentionDiscoveryAt = nil
        Self.saveDate(nil, forKey: Self.lastDirectMentionDiscoveryAtKey)
        lastMentionedRefreshStartedAt = nil
        directMentionTask?.cancel()
        directMentionTask = nil
        mentionedRefreshTask?.cancel()
        mentionedRefreshTask = nil
        logger.debug("Invalidated background refresh work: reason=\(reason, privacy: .public)")
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
        await refreshSinglePRCI(for: pr, notifyOnTerminalChange: false)
    }

    private func refreshSinglePRCI(for pr: PullRequest, notifyOnTerminalChange: Bool) async {
        do {
            let result = try await apiClient.fetchSinglePRCIStatus(
                owner: pr.repositoryOwner, repo: pr.repositoryName, number: pr.number
            )
            applyCIRefreshResult(result, for: pr, notifyOnTerminalChange: notifyOnTerminalChange)
            updateCIWatchTimer()
            logger.info("Refreshed single PR CI status for #\(pr.number): \(result.ciStatus?.rawValue ?? "nil")")
        } catch {
            if error is CancellationError || ((error as? APIError)?.isCancellation == true) {
                return
            }
            logger.error("Failed to refresh single PR CI for #\(pr.number): \(error.localizedDescription)")
        }
    }

    private func applyCIRefreshResult(
        _ result: GitHubAPIClient.SinglePRCIResult,
        for pr: PullRequest,
        notifyOnTerminalChange: Bool
    ) {
        let previousPR = previousPRs[pr.id]
        var updatedPR: PullRequest?

        func apply(to prs: inout [PullRequest]) {
            guard let index = prs.firstIndex(where: { $0.id == pr.id }) else { return }
            prs[index].ciStatus = result.ciStatus
            prs[index].checkSuccessCount = result.checkSuccessCount
            prs[index].checkFailureCount = result.checkFailureCount
            prs[index].checkPendingCount = result.checkPendingCount
            prs[index].githubCIState = result.ciStatus?.rawValue
            prs[index].ciExtendedInfo = result.ciExtendedInfo
            if let headSHA = result.headSHA, !headSHA.isEmpty {
                prs[index].headCommitOid = headSHA
            }
            updatedPR = prs[index]
        }

        apply(to: &prList.pullRequests)
        apply(to: &prList.mentionedPullRequests)
        apply(to: &prList.directMentionPullRequests)
        apply(to: &prList.mergedPullRequests)
        var trackingChanged = false
        if var trackingEntry = directMentionTracking[pr.id] {
            trackingEntry.pullRequest.ciStatus = result.ciStatus
            trackingEntry.pullRequest.checkSuccessCount = result.checkSuccessCount
            trackingEntry.pullRequest.checkFailureCount = result.checkFailureCount
            trackingEntry.pullRequest.checkPendingCount = result.checkPendingCount
            trackingEntry.pullRequest.githubCIState = result.ciStatus?.rawValue
            trackingEntry.pullRequest.ciExtendedInfo = result.ciExtendedInfo
            if let headSHA = result.headSHA, !headSHA.isEmpty {
                trackingEntry.pullRequest.headCommitOid = headSHA
            }
            directMentionTracking[pr.id] = trackingEntry
            trackingChanged = true
        }


        guard let updatedPR else { return }
        previousPRs[updatedPR.id] = updatedPR
        persistProjectedCaches(forceTrackingWrite: trackingChanged)

        guard notifyOnTerminalChange,
              configuration.notificationsEnabled,
              let newStatus = CIStatusNotificationPlanner.notificationStatus(
                previous: previousPR,
                current: updatedPR
              ) else {
            return
        }

        if newStatus == .failure && pinnedPRIdentifiers.contains(updatedPR.pinIdentifier) {
            notifyPinnedMajorEventsIfNeeded(for: updatedPR)
        } else {
            notificationManager.notifyCIStatusChange(pr: updatedPR, newStatus: newStatus)
        }
    }

    private func updateCIWatchTimer() {
        guard oauthManager.authState.isAuthenticated,
              configuration.isValid,
              !isAutomaticRecoveryPaused,
              !isRateLimitCritical else {
            stopCIWatchTimer(reason: "ci_watch_paused")
            return
        }

        guard CIWatchPlanner.shouldRun(for: prList) else {
            stopCIWatchTimer(reason: "no_in_flight_ci", cancelInFlight: false)
            return
        }

        guard ciWatchTimer?.isValid != true else { return }

        let newTimer = Timer(timeInterval: Self.ciWatchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.startCIWatchRefresh()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        ciWatchTimer = newTimer
        logger.info("Started fast CI watch timer")
    }

    private func stopCIWatchTimer(reason: String, cancelInFlight: Bool = true) {
        if ciWatchTimer != nil {
            logger.info("Stopped fast CI watch timer: reason=\(reason, privacy: .public)")
        }
        ciWatchTimer?.invalidate()
        ciWatchTimer = nil

        if cancelInFlight {
            ciWatchTask?.cancel()
            ciWatchTask = nil
        }
    }

    private func startCIWatchRefresh() {
        guard ciWatchTask == nil else { return }
        // Intentionally NOT gated on activeRefreshTask. A full refresh runs for tens of
        // seconds (incremental fetch + background direct-mention maintenance); on a
        // >=60s poll interval
        // watch — nearly every tick landed inside a refresh and was dropped. The watch only
        // fetches in-flight PRs and self-pauses under rate-limit pressure, so running it
        // alongside a full refresh is acceptable: snapshot writes are MainActor-serialized
        // and the last writer wins, self-healing on the next tick.

        let candidates = CIWatchPlanner.watchCandidates(from: prList)
        guard !candidates.isEmpty else {
            updateCIWatchTimer()
            return
        }

        ciWatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.ciWatchTask = nil
                logger.debug("CI watch sweep complete")
                self.updateCIWatchTimer()
            }

            for pr in candidates {
                guard !Task.isCancelled else { return }
                await self.refreshSinglePRCI(for: pr, notifyOnTerminalChange: true)
            }
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
        directMentionPRs: inout [PullRequest],
        mergedPRs: inout [PullRequest]
    ) async {
        guard configuration.openAtCmuxFirst, let cmuxStatusProvider else {
            clearCmuxOpenStatus(
                openPRs: &openPRs,
                mentionedPRs: &mentionedPRs,
                directMentionPRs: &directMentionPRs,
                mergedPRs: &mergedPRs
            )
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
        apply(to: &directMentionPRs)
        apply(to: &mergedPRs)
        logger.info("Refreshed cmux open status: openPRIdentities=\(openIdentities.count, privacy: .public)")
    }

    private func clearCmuxOpenStatus(
        openPRs: inout [PullRequest],
        mentionedPRs: inout [PullRequest],
        directMentionPRs: inout [PullRequest],
        mergedPRs: inout [PullRequest]
    ) {
        func clear(_ prs: inout [PullRequest]) {
            for index in prs.indices {
                prs[index].isOpenInCmux = nil
            }
        }
        clear(&openPRs)
        clear(&mentionedPRs)
        clear(&directMentionPRs)
        clear(&mergedPRs)
    }

    private func clearCmuxOpenStatus(in prList: inout PRList) {
        clearCmuxOpenStatus(
            openPRs: &prList.pullRequests,
            mentionedPRs: &prList.mentionedPullRequests,
            directMentionPRs: &prList.directMentionPullRequests,
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
        apply(to: &prList.directMentionPullRequests)
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
        apply(to: &prList.directMentionPullRequests)
        apply(to: &prList.mergedPullRequests)
        var trackingChanged = false
        if var trackingEntry = directMentionTracking[metadata.databaseId],
           var visible = prList.pullRequests.first(where: { $0.id == metadata.databaseId })
            ?? prList.mentionedPullRequests.first(where: { $0.id == metadata.databaseId })
            ?? prList.directMentionPullRequests.first(where: { $0.id == metadata.databaseId })
            ?? prList.mergedPullRequests.first(where: { $0.id == metadata.databaseId }) {
            visible.mentionCount = nil
            trackingEntry.pullRequest = visible
            directMentionTracking[metadata.databaseId] = trackingEntry
            trackingChanged = true
        }
        persistProjectedCaches(forceTrackingWrite: trackingChanged)
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
        if config != configuration || jiraTokenChanged {
            invalidateBackgroundRefreshWork(reason: "configuration_change")
        }
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
        updateCIWatchTimer()
    }

    private func clearJiraMetadata(in prList: inout PRList) {
        clearJiraMetadata(in: &prList.pullRequests)
        clearJiraMetadata(in: &prList.mentionedPullRequests)
        clearJiraMetadata(in: &prList.directMentionPullRequests)
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
        applyReadState(to: &prList.directMentionPullRequests)
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
            if let newStatus = CIStatusNotificationPlanner.notificationStatus(
                previous: previousPR,
                current: pr
            ) {
                if newStatus == .failure && pinnedPRIdentifiers.contains(pr.pinIdentifier) {
                    continue
                }
                notificationManager.notifyCIStatusChange(pr: pr, newStatus: newStatus)
            }
        }
    }

    private func notifyPinnedMajorEventsIfNeeded(for pr: PullRequest) {
        guard pinnedPRIdentifiers.contains(pr.pinIdentifier) else { return }
        guard pr.category == .authored || pr.category == .reviewRequest else { return }

        previousPinnedMajorEvents[pr.id] = notifyPinnedMajorEventsDelta(for: pr)
    }

    /// Notifies for pinned major events newly observed since the last recorded state and
    /// returns the current event set for the caller to persist. Suppresses notifications on
    /// first sighting (cold start, newly pinned) — the caller records state and waits for the
    /// next delta.
    private func notifyPinnedMajorEventsDelta(for pr: PullRequest) -> Set<PinnedMajorPREvent> {
        let events = PinnedMajorPRNotificationPlanner.events(for: pr)
        if let previousSet = previousPinnedMajorEvents[pr.id] {
            let newEvents = events.filter { !previousSet.contains($0) }
            if !newEvents.isEmpty {
                notificationManager.notifyPinnedMajorEvents(pr: pr, events: newEvents)
            }
        }
        return Set(events)
    }

    private func notifyPinnedMajorEvents(newPRs: [PullRequest]) {
        guard !pinnedPRIdentifiers.isEmpty else {
            previousPinnedMajorEvents.removeAll(keepingCapacity: true)
            return
        }

        var nextState: [Int: Set<PinnedMajorPREvent>] = [:]

        for pr in newPRs where pinnedPRIdentifiers.contains(pr.pinIdentifier) {
            guard pr.category == .authored || pr.category == .reviewRequest else { continue }
            nextState[pr.id] = notifyPinnedMajorEventsDelta(for: pr)
        }

        previousPinnedMajorEvents = nextState
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

    private static func previousPRState(from prs: [PullRequest]) -> [Int: PullRequest] {
        Dictionary(prs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func loadDate(forKey key: String) -> Date? {
        UserDefaults.standard.object(forKey: key) as? Date
    }

    private static func saveDate(_ date: Date?, forKey key: String) {
        if let date {
            UserDefaults.standard.set(date, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
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
