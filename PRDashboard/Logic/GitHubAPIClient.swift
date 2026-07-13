import Foundation
import os

private let logger = Logger(subsystem: "com.prdashboard", category: "GitHubAPIClient")

struct RateLimitInfo: Equatable {
    let limit: Int
    let remaining: Int
    let resetDate: Date

    var isLow: Bool {
        remaining < 100
    }

    var hasHeadroomForMentions: Bool {
        remaining >= 500
    }

    var hasHeadroomForDetails: Bool {
        remaining >= 200
    }

    var hasHeadroomForHoverDetails: Bool {
        remaining >= 100
    }

    static var empty: RateLimitInfo {
        RateLimitInfo(limit: 5000, remaining: 5000, resetDate: Date())
    }
}

/// Lightweight snapshot produced by the index query. Holds only the scalars
/// we need to decide whether a cached detail can be reused.
struct IndexedPR {
    let databaseId: Int
    let graphqlNodeId: String?
    let number: Int
    let title: String
    let url: URL
    let state: PRState
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let mergedAt: Date?
    let author: String
    let authorAvatarURL: URL?
    let repositoryOwner: String
    let repositoryName: String
    let repositoryIsArchived: Bool?
    let baseRefName: String?
    let headRefName: String?
    let baseNeedsUpdate: Bool?
    let hasBaseConflicts: Bool?
    let category: PRCategory
    let isMerged: Bool
    let snapshot: IndexSnapshot

    var reference: PullRequestReference {
        PullRequestReference(owner: repositoryOwner, repo: repositoryName, number: number)
    }

    /// Produce a `PullRequest` suitable for optimistic UI rendering. Heavy fields
    /// (reviewThreads, CI contexts, comments) are taken from `existing` (cache)
    /// when available, falling back to `visible` (currently-displayed UI state)
    /// to avoid flicker when the cache is cold but the UI already has data.
    /// Header fields are patched from the fresh index scalars.
    func placeholderPullRequest(
        using existing: PullRequest? = nil,
        preserving visible: PullRequest? = nil
    ) -> PullRequest {
        let approvalAuthors = Self.retainedOptionalList(existing?.approvalAuthors, visible?.approvalAuthors)
        let changesRequestedAuthors = Self.retainedOptionalList(
            existing?.changesRequestedAuthors,
            visible?.changesRequestedAuthors
        )
        let approvalCount = max(existing?.approvalCount ?? 0, visible?.approvalCount ?? 0)
        let changesRequestedCount = Self.retainedOptionalCount(
            existing?.changesRequestedCount,
            visible?.changesRequestedCount
        )
        let checkSuccessCount = max(existing?.checkSuccessCount ?? 0, visible?.checkSuccessCount ?? 0)
        let checkFailureCount = max(existing?.checkFailureCount ?? 0, visible?.checkFailureCount ?? 0)
        let checkPendingCount = max(existing?.checkPendingCount ?? 0, visible?.checkPendingCount ?? 0)
        let ciStatus = Self.retainedCIStatus(
            existing?.ciStatus,
            visible?.ciStatus,
            failureCount: checkFailureCount,
            pendingCount: checkPendingCount,
            successCount: checkSuccessCount
        )

        return PullRequest(
            id: databaseId,
            graphqlNodeId: graphqlNodeId ?? existing?.graphqlNodeId ?? visible?.graphqlNodeId,
            number: number,
            title: title,
            author: author,
            authorAvatarURL: authorAvatarURL,
            repositoryOwner: repositoryOwner,
            repositoryName: repositoryName,
            repositoryIsArchived: repositoryIsArchived,
            url: url,
            state: state,
            isDraft: isDraft,
            createdAt: createdAt,
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            body: existing?.body ?? visible?.body,
            conversationComments: Self.retainedList(
                existing?.conversationComments,
                visible?.conversationComments
            ),
            lastCommitAt: existing?.lastCommitAt ?? visible?.lastCommitAt,
            headCommitOid: snapshot.headOid ?? existing?.headCommitOid ?? visible?.headCommitOid,
            baseRefName: baseRefName ?? existing?.baseRefName ?? visible?.baseRefName,
            headRefName: headRefName ?? existing?.headRefName ?? visible?.headRefName,
            baseNeedsUpdate: baseNeedsUpdate ?? existing?.baseNeedsUpdate ?? visible?.baseNeedsUpdate,
            approvalAuthors: approvalAuthors,
            changesRequestedAuthors: changesRequestedAuthors,
            reviewThreads: Self.retainedList(existing?.reviewThreads, visible?.reviewThreads),
            category: category,
            hasBaseConflicts: hasBaseConflicts ?? existing?.hasBaseConflicts ?? visible?.hasBaseConflicts ?? false,
            ciStatus: ciStatus,
            checkSuccessCount: checkSuccessCount,
            checkFailureCount: checkFailureCount,
            checkPendingCount: checkPendingCount,
            githubCIState: existing?.githubCIState ?? visible?.githubCIState,
            myLastReviewState: existing?.myLastReviewState ?? visible?.myLastReviewState,
            myLastReviewAt: existing?.myLastReviewAt ?? visible?.myLastReviewAt,
            reviewRequestedAt: existing?.reviewRequestedAt ?? visible?.reviewRequestedAt,
            myThreadsAllResolved: (existing?.myThreadsAllResolved ?? false) || (visible?.myThreadsAllResolved ?? false),
            approvalCount: approvalCount,
            changesRequestedCount: changesRequestedCount,
            ciExtendedInfo: existing?.ciExtendedInfo ?? visible?.ciExtendedInfo,
            jiraTicket: existing?.jiraTicket ?? visible?.jiraTicket,
            jiraTitle: existing?.jiraTitle ?? visible?.jiraTitle,
            jiraLabels: existing?.jiraLabels ?? visible?.jiraLabels,
            jiraStatusName: existing?.jiraStatusName ?? visible?.jiraStatusName,
            jiraStatusCategoryKey: existing?.jiraStatusCategoryKey ?? visible?.jiraStatusCategoryKey,
            jiraUpdatedAt: existing?.jiraUpdatedAt ?? visible?.jiraUpdatedAt,
            jiraMetadataFetchedAt: existing?.jiraMetadataFetchedAt ?? visible?.jiraMetadataFetchedAt,
            isOpenInCmux: visible?.isOpenInCmux ?? existing?.isOpenInCmux,
            mentionCount: visible?.mentionCount
        )
    }

    private static func retainedList<T>(_ existing: [T]?, _ visible: [T]?) -> [T] {
        if let existing, !existing.isEmpty {
            return existing
        }
        return visible ?? []
    }

    private static func retainedOptionalList<T>(_ existing: [T]?, _ visible: [T]?) -> [T]? {
        if let existing, !existing.isEmpty {
            return existing
        }
        if let visible, !visible.isEmpty {
            return visible
        }
        return nil
    }

    private static func retainedOptionalCount(_ existing: Int?, _ visible: Int?) -> Int? {
        guard existing != nil || visible != nil else { return nil }
        return max(existing ?? 0, visible ?? 0)
    }

    private static func retainedCIStatus(
        _ existing: CIStatus?,
        _ visible: CIStatus?,
        failureCount: Int,
        pendingCount: Int,
        successCount: Int
    ) -> CIStatus? {
        if failureCount > 0 {
            if existing == .success || visible == .success {
                return .success
            }
            return .failure
        }
        if pendingCount > 0 { return .pending }
        if successCount > 0 { return .success }
        return existing ?? visible
    }
}

enum APIError: LocalizedError {
    case unauthorized
    case rateLimited(resetDate: Date)
    case network(Error)
    case decoding(Error)
    case invalidResponse
    case http(statusCode: Int)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Invalid GitHub token. Please check your settings.")
        case .rateLimited(let resetDate):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return String(localized: "Rate limited. Try again after \(formatter.string(from: resetDate))")
        case .network(let error):
            return String(localized: "Network error: \(error.localizedDescription)")
        case .decoding(let error):
            return String(localized: "Failed to parse response: \(error.localizedDescription)")
        case .invalidResponse:
            return String(localized: "Invalid response from GitHub")
        case .http(let statusCode):
            switch statusCode {
            case 408:
                return String(localized: "GitHub API request timed out (HTTP 408)")
            case 429:
                return String(localized: "GitHub API temporarily rejected the request (HTTP 429)")
            case 500, 502, 503, 504:
                return String(localized: "GitHub API is temporarily unavailable (HTTP \(statusCode))")
            default:
                return String(localized: "GitHub API request failed (HTTP \(statusCode))")
            }
        case .unknown(let message):
            return message
        }
    }

    var isCancellation: Bool {
        switch self {
        case .network(let error):
            if error is CancellationError {
                return true
            }
            if let urlError = error as? URLError {
                return urlError.code == .cancelled
            }
            return false
        default:
            return false
        }
    }

    var isTransient: Bool {
        switch self {
        case .rateLimited:
            return true
        case .network(let error):
            return Self.isTransientNetworkError(error)
        case .http(let statusCode):
            return [408, 429, 500, 502, 503, 504].contains(statusCode)
        default:
            return false
        }
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .timedOut,
             .notConnectedToInternet,
             .networkConnectionLost,
             .dnsLookupFailed,
             .cannotFindHost,
             .cannotConnectToHost,
             .resourceUnavailable,
             .cannotLoadFromNetwork,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}

struct HTTPProxyConfig: Equatable {
    let host: String
    let port: Int
    let username: String
    let password: String
}

private final class ProxyAuthDelegate: NSObject, URLSessionDelegate {
    var credential: URLCredential?

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let isProxyBasic = (space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
            || space.authenticationMethod == NSURLAuthenticationMethodDefault)
            && [NSURLProtectionSpaceHTTPProxy, NSURLProtectionSpaceHTTPSProxy].contains(space.proxyType ?? "")
        if isProxyBasic, let credential = credential {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class GitHubAPIClient: ObservableObject {
    private static let maxCIContextsToFetch = 512
    private static let maxGraphQLAttempts = 3
    /// Aliased-batch size used by detail and direct-mention row queries.
    private static let batchedPRQuerySize = 20
    static let backgroundMentionBatchSize = 10
    static let backgroundMentionBatchDelay: TimeInterval = 60
    static let recentMentionBatchDelay: TimeInterval = 3
    static var coldMentionScanIncompleteError: APIError {
        APIError.unknown(
            String(localized: "Cold mention scan did not finish; will retry on next refresh")
        )
    }
    private static let directMentionStateBatchSize = 5
    private static let directMentionRateFloor = 500
    private static let directMentionSearchPageSize = 100
    /// Maximum number of aliased-batch queries in flight at once. Applied to
    /// fetchIncremental so a cold start can't burst 10+ concurrent GraphQL requests.
    private static let batchedPRQueryConcurrency = 3
    static let defaultGraphQLURL = URL(string: "https://api.github.com/graphql")!
    private var graphQLURL: URL = GitHubAPIClient.defaultGraphQLURL
    private var token: String
    private var session: URLSession
    private let sessionDelegate = ProxyAuthDelegate()
    private var proxyConfig: HTTPProxyConfig?
    private var lastETag: String?

    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty

    private struct RetryDecision {
        let classification: String
        let delay: TimeInterval?
    }

    private struct CIExcludeMatcher {
        let pattern: String
        let regex: NSRegularExpression?

        init(pattern: String) {
            self.pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            self.regex = try? NSRegularExpression(pattern: self.pattern, options: [.caseInsensitive])
        }

        var isEmpty: Bool {
            pattern.isEmpty
        }

        func matches(_ value: String?) -> Bool {
            guard !pattern.isEmpty, let value, !value.isEmpty else {
                return false
            }
            if let regex {
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                return regex.firstMatch(in: value, range: range) != nil
            }
            return value.lowercased().contains(pattern.lowercased())
        }

        func matchesAny(_ values: [String?]) -> Bool {
            values.contains { matches($0) }
        }
    }

    struct WorkflowRunCompletionSummary: Equatable {
        let totalCount: Int
        let completedCount: Int
        let successCount: Int
        let skippedCount: Int
        let failureLikeCount: Int
        let blockingFailureLikeCount: Int
        let inFlightCount: Int

        var allCompleted: Bool {
            totalCount > 0 && inFlightCount == 0 && completedCount == totalCount
        }
    }

    struct WorkflowRunSnapshot: Equatable {
        let id: Int
        let name: String?
        let displayTitle: String?
        let path: String?
        let workflowId: Int?
        let runNumber: Int
        let runAttempt: Int
        let status: String?
        let conclusion: String?
        let createdAt: Date?
        let updatedAt: Date?

        var groupingKey: String {
            if let workflowId {
                return "workflow_id:\(workflowId)"
            }
            if let path, !path.isEmpty {
                return "path:\(path)"
            }
            if let name, !name.isEmpty {
                return "name:\(name)"
            }
            return "run:\(id)"
        }
    }

    init(token: String, graphQLEndpoint: String? = nil, session: URLSession? = nil) {
        self.token = token
        self.session = session ?? Self.makeSession(proxy: nil, delegate: sessionDelegate)
        self.graphQLURL = Self.resolveGraphQLURL(graphQLEndpoint)
    }

    func updateToken(_ newToken: String) {
        self.token = newToken
    }

    func updateGraphQLEndpoint(_ endpoint: String?) {
        let resolved = Self.resolveGraphQLURL(endpoint)
        graphQLURL = resolved
        if resolved == Self.defaultGraphQLURL {
            logger.info("GraphQL endpoint set to default (\(Self.defaultGraphQLURL.absoluteString, privacy: .public))")
        } else {
            logger.info("GraphQL endpoint overridden to \(resolved.absoluteString, privacy: .private)")
        }
    }

    func updateProxy(urlString: String, username: String, password: String) {
        let newConfig = Self.resolveProxyConfig(urlString: urlString, username: username, password: password)
        if newConfig == proxyConfig { return }

        proxyConfig = newConfig
        sessionDelegate.credential = newConfig.flatMap { cfg in
            cfg.username.isEmpty ? nil : URLCredential(user: cfg.username, password: cfg.password, persistence: .forSession)
        }
        session.invalidateAndCancel()
        session = Self.makeSession(proxy: newConfig, delegate: sessionDelegate)

        if let cfg = newConfig {
            logger.info("HTTP proxy set to \(cfg.host, privacy: .private):\(cfg.port, privacy: .public)")
        } else {
            logger.info("HTTP proxy disabled")
        }
    }

    private static func makeSession(proxy: HTTPProxyConfig?, delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        if let proxy {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as AnyHashable: 1,
                kCFNetworkProxiesHTTPProxy as AnyHashable: proxy.host,
                kCFNetworkProxiesHTTPPort as AnyHashable: proxy.port,
                "HTTPSEnable" as AnyHashable: 1,
                "HTTPSProxy" as AnyHashable: proxy.host,
                "HTTPSPort" as AnyHashable: proxy.port
            ]
        }
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private static func resolveProxyConfig(urlString: String, username: String, password: String) -> HTTPProxyConfig? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            logger.error("Invalid HTTP proxy URL '\(trimmed, privacy: .private)'; proxy disabled")
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return HTTPProxyConfig(
            host: host,
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    private static func resolveGraphQLURL(_ endpoint: String?) -> URL {
        guard let raw = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultGraphQLURL
        }
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            return url
        }
        logger.error("Invalid GraphQL endpoint override '\(raw, privacy: .private)'; falling back to default")
        return defaultGraphQLURL
    }

    func fetchPullRequests(username: String, searchQuery: String, category: PRCategory) async throws -> [PullRequest] {
        let query = buildGraphQLQuery(searchQuery: searchQuery)
        let responseData = try await executeGraphQL(query: query, operation: "fetchPullRequests")
        var prs = try parseSearchResponse(data: responseData, category: category)
        await applyWorkflowRunCompletionGuards(to: &prs)
        return prs
    }

    struct CombinedPRResult {
        let openPRs: [PullRequest]
        let mergedPRs: [PullRequest]
    }
    enum MentionRefreshMode {
        case cold
        case hot

        var authoredReferenceDaysBack: Int {
            switch self {
            case .cold: 365
            case .hot: 90
            }
        }

        var descriptionCandidateDaysBack: Int {
            switch self {
            case .cold: 30
            case .hot: 7
            }
        }
    }

    struct MentionRefreshOptions {
        let mode: MentionRefreshMode
        let authoredReferenceDaysBack: Int
        let descriptionCandidateDaysBack: Int
        let batchSize: Int
        let batchDelay: TimeInterval

        static func background(
            mode: MentionRefreshMode,
            authoredReferenceDaysBack: Int? = nil,
            descriptionCandidateDaysBack: Int? = nil
        ) -> MentionRefreshOptions {
            MentionRefreshOptions(
                mode: mode,
                authoredReferenceDaysBack: max(
                    mode.authoredReferenceDaysBack,
                    authoredReferenceDaysBack ?? mode.authoredReferenceDaysBack
                ),
                descriptionCandidateDaysBack: max(
                    mode.descriptionCandidateDaysBack,
                    descriptionCandidateDaysBack ?? mode.descriptionCandidateDaysBack
                ),
                batchSize: GitHubAPIClient.backgroundMentionBatchSize,
                batchDelay: GitHubAPIClient.backgroundMentionBatchDelay
            )
        }

        var boundedBatchSize: Int {
            max(1, min(100, batchSize))
        }

        func withBatchDelay(_ delay: TimeInterval) -> MentionRefreshOptions {
            MentionRefreshOptions(
                mode: mode,
                authoredReferenceDaysBack: authoredReferenceDaysBack,
                descriptionCandidateDaysBack: descriptionCandidateDaysBack,
                batchSize: batchSize,
                batchDelay: max(0, delay)
            )
        }

        var boundedSearchPageSize: Int {
            100
        }
    }
    /// Stage of an in-flight incremental refresh. PRManager uses this to decide
    /// whether to apply filters and publish, without running the final
    /// notification/Jira/change-detection pipeline on intermediate frames.
    enum IncrementalStage: String {
        case placeholders
        case detailProgress
    }

    /// Index-first, cache-aware refresh. Runs a cheap scalar-only "index" query
    /// then fetches detail only for PRs whose index snapshot changed or whose
    /// cached CI state is still in flight. Emits intermediate `onProgress`
    /// frames so the UI can paint as soon as index returns and re-paint after
    /// each detail batch.
    func fetchIncremental(
        username: String,
        existingPRs: [PullRequest] = [],
        onProgress: (@Sendable ([PullRequest], [PullRequest], IncrementalStage) async -> Void)? = nil
    ) async throws -> CombinedPRResult {
        let indexed = try await fetchIndex(username: username)
        logger.info("Index returned \(indexed.count, privacy: .public) PRs (authored+reviewed+merged)")

        let cache = PRDetailCache.shared.loadEntries()
        let visibleByID = Dictionary(existingPRs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        var snapshotByID: [Int: IndexSnapshot] = [:]
        var hits: [Int: PullRequest] = [:]
        var misses: [IndexedPR] = []

        for ip in indexed {
            snapshotByID[ip.databaseId] = ip.snapshot
            if let cached = cache[ip.databaseId],
               cached.isUsable(against: ip.snapshot, now: now, ttl: PRDetailCache.ttl) {
                hits[ip.databaseId] = ip.placeholderPullRequest(
                    using: cached.detail,
                    preserving: visibleByID[ip.databaseId]
                )
            } else {
                misses.append(ip)
            }
        }
        logger.info("Cache diff: \(hits.count, privacy: .public) hits, \(misses.count, privacy: .public) misses")

        // Build placeholders once; reused across the initial frame, rate-limit
        // fallback, mid-batch progress frames, and the final fill.
        var missPlaceholders: [Int: PullRequest] = [:]
        missPlaceholders.reserveCapacity(misses.count)
        for ip in misses {
            missPlaceholders[ip.databaseId] = ip.placeholderPullRequest(
                using: cache[ip.databaseId]?.detail,
                preserving: visibleByID[ip.databaseId]
            )
        }

        func splitOpenMerged(byID: [Int: PullRequest]) -> (open: [PullRequest], merged: [PullRequest]) {
            var open: [PullRequest] = []
            var merged: [PullRequest] = []
            var seenOpen = Set<Int>()
            var seenMerged = Set<Int>()
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            for ip in indexed {
                guard let pr = byID[ip.databaseId] else { continue }
                if ip.isMerged {
                    if let mergedAt = pr.mergedAt, mergedAt >= cutoff, seenMerged.insert(pr.id).inserted {
                        merged.append(pr)
                    }
                } else if seenOpen.insert(pr.id).inserted {
                    open.append(pr)
                }
            }
            open.sort { $0.updatedAt > $1.updatedAt }
            merged.sort { ($0.mergedAt ?? $0.updatedAt) > ($1.mergedAt ?? $1.updatedAt) }
            return (open, merged)
        }

        // Initial progress frame: hits + placeholders for pending misses so the UI
        // can paint titles/CI colors immediately on cold start.
        if let onProgress {
            var optimistic: [Int: PullRequest] = hits
            optimistic.merge(missPlaceholders) { _, new in new }
            let split = splitOpenMerged(byID: optimistic)
            await onProgress(split.open, split.merged, .placeholders)
        }

        // Rate-limit guard: if we don't have headroom, serve stale cached details
        // for misses rather than firing 50+ batch queries.
        let rateLimitSnapshot = await MainActor.run { self.rateLimitInfo }
        var fetched: [Int: PullRequest] = [:]
        if !misses.isEmpty && !rateLimitSnapshot.hasHeadroomForDetails {
            logger.warning(
                "Detail fetch skipped due to rate-limit floor: remaining=\(rateLimitSnapshot.remaining, privacy: .public)/\(rateLimitSnapshot.limit, privacy: .public)"
            )
            fetched.merge(missPlaceholders) { _, new in new }
        } else if !misses.isEmpty {
            // Run detail batches with a bounded concurrency cap. After each batch
            // completes we (a) merge its results into the running accumulator,
            // (b) emit a full-list snapshot for the UI, and (c) re-check rate
            // limit headroom — if we dropped below the floor mid-refresh, stop
            // dispatching new batches and serve placeholders for the rest.
            let categoryByID = Dictionary(uniqueKeysWithValues: misses.map { ($0.databaseId, $0.category) })

            // Ordering: authored PRs first (user's own work paints first on cold
            // start), then reviewRequest, then merged. Within each bucket sort
            // by owner/repo/number for batch stability.
            func orderKey(_ ip: IndexedPR) -> Int {
                if ip.category == .authored && !ip.isMerged { return 0 }
                if ip.category == .reviewRequest && !ip.isMerged { return 1 }
                return 2
            }
            let sorted = misses.sorted { a, b in
                let ka = orderKey(a), kb = orderKey(b)
                if ka != kb { return ka < kb }
                if a.repositoryOwner != b.repositoryOwner { return a.repositoryOwner < b.repositoryOwner }
                if a.repositoryName != b.repositoryName { return a.repositoryName < b.repositoryName }
                return a.number < b.number
            }
            let batches = sorted.chunked(into: Self.batchedPRQuerySize)
            let fieldSelection = buildPRFieldSelection(
                username: username,
                includeReviewMetadata: true,
                includeMentionBodies: true
            )
            let excludeFilter = Self.loadCIStatusExcludeFilter()

            // freshlyFetched holds only PRs that actually went over the wire this
            // refresh. Used for cache persistence. `fetched` will also pick up
            // placeholder fills for rate-limited-unfetched PRs so the UI sees a
            // complete list.
            var freshlyFetched: [Int: PullRequest] = [:]

            try await withThrowingTaskGroup(of: [Int: PullRequest].self) { group in
                var iter = batches.makeIterator()
                var inflight = 0
                var rateLimitExhausted = false

                while inflight < Self.batchedPRQueryConcurrency, let batch = iter.next() {
                    group.addTask { [fieldSelection] in
                        try await self.fetchDetailBatch(
                            batch,
                            categoryByID: categoryByID,
                            username: username,
                            fieldSelection: fieldSelection,
                            excludeFilter: excludeFilter
                        )
                    }
                    inflight += 1
                }
                while let partial = try await group.next() {
                    freshlyFetched.merge(partial) { _, new in new }
                    fetched.merge(partial) { _, new in new }
                    inflight -= 1

                    if let onProgress {
                        var byID: [Int: PullRequest] = hits
                        byID.merge(missPlaceholders) { _, new in new }
                        byID.merge(fetched) { _, new in new }
                        let split = splitOpenMerged(byID: byID)
                        await onProgress(split.open, split.merged, .detailProgress)
                    }

                    if !rateLimitExhausted {
                        let currentRateLimit = await MainActor.run { self.rateLimitInfo }
                        if !currentRateLimit.hasHeadroomForDetails {
                            rateLimitExhausted = true
                            logger.warning(
                                "Detail fetch stopping mid-flight: remaining=\(currentRateLimit.remaining, privacy: .public)/\(currentRateLimit.limit, privacy: .public) fell below headroom; remaining misses served as placeholders"
                            )
                        }
                    }

                    if !rateLimitExhausted, let next = iter.next() {
                        group.addTask { [fieldSelection] in
                            try await self.fetchDetailBatch(
                                next,
                                categoryByID: categoryByID,
                                username: username,
                                fieldSelection: fieldSelection,
                                excludeFilter: excludeFilter
                            )
                        }
                        inflight += 1
                    }
                }
            }

            // Fill in placeholders for any miss that wasn't fetched (either
            // rate-limited mid-flight or never dispatched at all).
            for (id, placeholder) in missPlaceholders where fetched[id] == nil {
                fetched[id] = placeholder
            }

            // Only persist entries we actually fetched fresh; placeholders would
            // pollute the cache with partial data and break the updatedAt diff.
            let cacheEntries: [CachedPRDetail] = freshlyFetched.compactMap { id, pr in
                guard let snapshot = snapshotByID[id] else { return nil }
                return CachedPRDetail(
                    prId: id,
                    indexSnapshot: snapshot,
                    detail: pr,
                    detailFetchedAt: now
                )
            }
            PRDetailCache.shared.upsert(cacheEntries)
        }

        var combinedByID: [Int: PullRequest] = hits
        combinedByID.merge(fetched) { _, new in new }
        await applyWorkflowRunCompletionGuards(to: &combinedByID)

        let split = splitOpenMerged(byID: combinedByID)
        let openPRs = split.open
        let mergedPRs = split.merged

        return CombinedPRResult(
            openPRs: openPRs,
            mergedPRs: mergedPRs
        )
    }
    func fetchMentionedPullRequests(
        username: String,
        openPRs: [PullRequest],
        mergedPRs: [PullRequest],
        options: MentionRefreshOptions,
        onProgress: (@Sendable ([PullRequest]) async -> Void)? = nil
    ) async throws -> [PullRequest] {
        try await enrichWithMentions(
            username: username,
            openPRs: openPRs,
            mergedPRs: mergedPRs,
            options: options,
            onProgress: onProgress
        )
    }

    static func normalizeMentionedResults(_ prs: [PullRequest]) -> [PullRequest] {
        var seen = Set<Int>()
        return prs
            .filter { $0.state == .open && seen.insert($0.id).inserted }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func enrichWithMentions(
        username: String,
        openPRs: [PullRequest],
        mergedPRs: [PullRequest],
        options: MentionRefreshOptions,
        onProgress: (@Sendable ([PullRequest]) async -> Void)? = nil
    ) async throws -> [PullRequest] {
        let seedPRs = openPRs + mergedPRs
        let existingReferences = Set(
            seedPRs.map {
                PullRequestReference(
                    owner: $0.repositoryOwner,
                    repo: $0.repositoryName,
                    number: $0.number
                )
            }
        )
        let fieldSelection = buildPRFieldSelection(
            includeReviewMetadata: false,
            includeMentionBodies: false
        )
        var fetchedByID: [Int: PullRequest] = [:]
        var fetchedReferences = existingReferences

        func ingest(_ references: Set<PullRequestReference>) async throws {
            let toFetch = references.subtracting(fetchedReferences)
                .sorted { PullRequestReference.ordered($0, $1, newestFirst: true) }
            guard !toFetch.isEmpty else { return }
            fetchedReferences.formUnion(toFetch)

            let batches = toFetch.chunked(into: options.boundedBatchSize)
            for (index, batch) in batches.enumerated() {
                let prs = try await fetchMentionedBatch(batch, fieldSelection: fieldSelection)
                for pr in prs {
                    fetchedByID[pr.id] = pr
                }
                if let onProgress, !fetchedByID.isEmpty {
                    await onProgress(Self.normalizeMentionedResults(Array(fetchedByID.values)))
                }
                if index < batches.count - 1 {
                    try await sleepBetweenMentionBatches(Self.recentMentionBatchDelay)
                }
            }
        }

        guard await hasMentionHeadroom() else {
            throw Self.coldMentionScanIncompleteError
        }

        let recentOptions = options.withBatchDelay(Self.recentMentionBatchDelay)
        let authoredReferences = try await fetchAuthoredPullRequestReferences(
            username: username,
            options: recentOptions
        )
        guard !authoredReferences.isEmpty else { return [] }

        fetchedReferences.formUnion(authoredReferences)
        let orderedAuthored = authoredReferences
            .sorted { PullRequestReference.ordered($0, $1, newestFirst: true) }
        let batches = orderedAuthored.chunked(into: options.boundedBatchSize)

        for (index, batch) in batches.enumerated() {
            guard await hasMentionHeadroom() else {
                throw Self.coldMentionScanIncompleteError
            }
            try await ingest(fetchInboundCrossReferenceBatch(batch))
            if index < batches.count - 1 {
                try await sleepBetweenMentionBatches(Self.recentMentionBatchDelay)
            }
        }

        return Self.normalizeMentionedResults(Array(fetchedByID.values))
    }

    private func fetchInboundCrossReferenceBatch(
        _ batch: [PullRequestReference]
    ) async throws -> Set<PullRequestReference> {
        guard !batch.isEmpty else { return [] }
        let queryParts = batch.enumerated().map { index, reference in
            """
            pr_\(index): repository(owner: \(Self.graphQLStringLiteral(reference.owner)), name: \(Self.graphQLStringLiteral(reference.repo))) {
                pullRequest(number: \(reference.number)) {
                    \(buildMentionSourceFieldSelection())
                }
            }
            """
        }
        let query = """
        query {
            \(queryParts.joined(separator: "\n"))
            rateLimit {
                cost
                remaining
                resetAt
            }
        }
        """
        let responseData = try await executeGraphQL(
            query: query,
            operation: "fetchInboundCrossReferences"
        )
        if let rateLimit = Self.graphQLRateLimit(in: responseData) {
            await recordGraphQLRateLimit(rateLimit)
        }

        let response: MentionSourceBatchResponse
        do {
            response = try JSONDecoder.githubDecoder.decode(
                MentionSourceBatchResponse.self,
                from: responseData
            )
        } catch {
            throw APIError.decoding(error)
        }

        var result = Set<PullRequestReference>()
        for node in response.data.nodes {
            let currentPR = PullRequestReference(
                owner: node.repository.owner.login,
                repo: node.repository.name,
                number: node.number
            )
            result.formUnion(Self.inboundMentionReferences(from: node, currentPR: currentPR))
        }
        return result
    }

    private func hasMentionHeadroom() async -> Bool {
        await MainActor.run { self.rateLimitInfo.hasHeadroomForMentions }
    }

    private func fetchAuthoredPullRequestReferences(
        username: String,
        options: MentionRefreshOptions
    ) async throws -> Set<PullRequestReference> {
        let searchQuery = Self.authoredMentionReferenceSearchQuery(
            username: username,
            daysBack: options.authoredReferenceDaysBack
        )
        let cachedReferences: Set<PullRequestReference> = options.mode == .cold
            ? []
            : AuthoredMentionReferenceCache.shared.entry(for: username)?.pullRequestReferences ?? []
        var references = Set<PullRequestReference>()
        var after: String?

        repeat {
            let page = try await fetchPullRequestReferencePage(
                searchQuery: searchQuery,
                first: options.boundedSearchPageSize,
                after: after
            )
            references.formUnion(page.references)
            after = page.pageInfo.endCursor
            if page.pageInfo.hasNextPage {
                try await sleepBetweenMentionBatches(options.batchDelay)
            } else {
                break
            }
        } while after != nil

        let mergedReferences = cachedReferences.union(references)
        AuthoredMentionReferenceCache.shared.saveEntry(
            username: username,
            references: mergedReferences,
            updatedAt: Date()
        )
        logger.info(
            "Fetched \(references.count, privacy: .public) authored PR references for mentioned-PR discovery; cachedTotal=\(mergedReferences.count, privacy: .public)"
        )
        return mergedReferences
    }

    private struct PullRequestReferencePage {
        let references: Set<PullRequestReference>
        let pageInfo: PRReferenceSearchResponse.PageInfo
    }

    private func fetchPullRequestReferencePage(
        searchQuery: String,
        first: Int,
        after: String?
    ) async throws -> PullRequestReferencePage {
        let query = buildReferenceSearchQuery(
            searchQuery: searchQuery,
            first: first,
            after: after
        )
        let responseData = try await executeGraphQL(
            query: query,
            operation: "fetchAuthoredPRReferences"
        )
        if let rateLimit = Self.graphQLRateLimit(in: responseData) {
            await recordGraphQLRateLimit(rateLimit)
        }
        do {
            let response = try JSONDecoder.githubDecoder.decode(
                PRReferenceSearchResponse.self,
                from: responseData
            )
            let references = Set(
                response.data.search.nodes.map {
                    PullRequestReference(
                        owner: $0.repository.owner.login,
                        repo: $0.repository.name,
                        number: $0.number
                    )
                }
            )
            return PullRequestReferencePage(
                references: references,
                pageInfo: response.data.search.pageInfo
            )
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func sleepBetweenMentionBatches(_ delay: TimeInterval) async throws {
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: delay.nanoseconds)
    }
    struct DirectMentionRefreshResult {
        var baseSources: [Int: DirectMentionSourceSnapshot]
        var refreshed: [Int: DirectMentionTrackingEntry]
        var closedIDs: Set<Int>
        var failedIDs: Set<Int>
    }

    struct DirectMentionDiscoveryResult {
        var seenIDs: Set<Int>
        var discovered: [Int: DirectMentionTrackingEntry]
        var isComplete: Bool
    }

    private static let explicitPRReferenceRegex = compileRegex(
        "([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)\\b"
    )
    private static let sameRepoPRReferenceRegex = compileRegex(
        "(?<![A-Za-z0-9_.\\-/])#([0-9]+)\\b"
    )
    private static let pullRequestURLRegex = compileRegex(
        "https?://github\\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)(?:\\b|/)"
    )

    static func extractMentionedPRReferences(
        from text: String,
        repositoryOwner: String,
        repositoryName: String,
        sourcePRNumber: Int
    ) -> Set<PullRequestReference> {
        guard text.contains("#") || text.contains("github.com/") else { return [] }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let ownerLower = repositoryOwner.lowercased()
        let repoLower = repositoryName.lowercased()
        var result = Set<PullRequestReference>()

        func insertIfSameRepository(owner: String, repo: String, number: Int) {
            guard number > 0, number != sourcePRNumber else { return }
            guard owner.lowercased() == ownerLower, repo.lowercased() == repoLower else { return }
            result.insert(
                PullRequestReference(owner: repositoryOwner, repo: repositoryName, number: number)
            )
        }

        for regex in [explicitPRReferenceRegex, pullRequestURLRegex] {
            for match in regex.matches(in: text, range: fullRange) {
                guard
                    let ownerRange = Range(match.range(at: 1), in: text),
                    let repoRange = Range(match.range(at: 2), in: text),
                    let numberRange = Range(match.range(at: 3), in: text),
                    let number = Int(text[numberRange])
                else { continue }
                insertIfSameRepository(
                    owner: String(text[ownerRange]),
                    repo: String(text[repoRange]),
                    number: number
                )
            }
        }

        for match in sameRepoPRReferenceRegex.matches(in: text, range: fullRange) {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let number = Int(text[numberRange]) else { continue }
            insertIfSameRepository(
                owner: repositoryOwner,
                repo: repositoryName,
                number: number
            )
        }

        return result
    }

    /// Count direct mentions of the exact login, excluding email addresses,
    /// longer logins, `@@login`, slash-qualified names, and hyphenated names.
    static func directUsernameMentionCount(username: String, in text: String) -> Int {
        guard !username.isEmpty, !text.isEmpty else { return 0 }
        let escaped = NSRegularExpression.escapedPattern(for: username)
        let pattern = "(?<![A-Za-z0-9_@-])@\(escaped)(?![A-Za-z0-9_/-])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    /// Evaluate the pending direct-mention state machine from immutable PR
    /// content and ordinary issue comments. Review submissions and inline review
    /// comments are intentionally not part of this input.
    static func pendingDirectMentionCount(
        username: String,
        pullRequestAuthor: String,
        title: String,
        body: String?,
        contentCreatedAt: Date,
        contentLastEditedAt: Date?,
        comments: [IssueCommentSummary]
    ) -> Int {
        let usernameLower = username.lowercased()
        let latestReplyAt = comments
            .filter { $0.author.lowercased() == usernameLower }
            .map(\.createdAt)
            .max()

        func isAfterReply(_ sourceAt: Date) -> Bool {
            guard let latestReplyAt else { return true }
            return sourceAt > latestReplyAt
        }

        var pending = 0
        if pullRequestAuthor.lowercased() != usernameLower {
            let sourceAt = contentLastEditedAt ?? contentCreatedAt
            if isAfterReply(sourceAt) {
                pending += directUsernameMentionCount(username: username, in: title)
                if let body {
                    pending += directUsernameMentionCount(username: username, in: body)
                }
            }
        }

        for comment in comments where comment.author.lowercased() != usernameLower {
            let sourceAt = comment.lastEditedAt ?? comment.createdAt
            guard isAfterReply(sourceAt) else { continue }
            pending += directUsernameMentionCount(username: username, in: comment.body)
        }
        return pending
    }



    /// Refresh tracked direct mentions using a cheap source snapshot first.
    /// Full ordinary-comment pagination is only performed when a source changed.
    func refreshTrackedMentions(
        username: String,
        entries: [Int: DirectMentionTrackingEntry]
    ) async -> DirectMentionRefreshResult {
        let orderedEntries = entries.values.sorted { $0.prID < $1.prID }
        guard !orderedEntries.isEmpty else {
            return DirectMentionRefreshResult(
                baseSources: [:],
                refreshed: [:],
                closedIDs: [],
                failedIDs: []
            )
        }

        var baseSources: [Int: DirectMentionSourceSnapshot] = [:]
        var refreshed: [Int: DirectMentionTrackingEntry] = [:]
        var closedIDs = Set<Int>()
        var failedIDs = Set<Int>()
        var changed: [(DirectMentionTrackingEntry, DirectMentionSourceSnapshot)] = []
        var remaining = await MainActor.run { self.rateLimitInfo.remaining }

        for batch in orderedEntries.chunked(into: Self.batchedPRQuerySize) {
            guard remaining >= Self.directMentionRateFloor else {
                failedIDs.formUnion(batch.map(\.prID))
                continue
            }

            let query = buildDirectMentionSourceQuery(entries: batch)
            let responseData: Data
            do {
                responseData = try await executeGraphQL(
                    query: query,
                    operation: "refreshDirectMentionSources"
                )
            } catch {
                logger.error("Direct mention source request failed for \(batch.count, privacy: .public) PRs: \(error.localizedDescription)")
                failedIDs.formUnion(batch.map(\.prID))
                continue
            }

            if let rateLimit = Self.graphQLRateLimit(in: responseData) {
                remaining = rateLimit.remaining
                await recordGraphQLRateLimit(rateLimit)
            }

            let response: DirectMentionSourceBatchResponse
            do {
                response = try JSONDecoder.githubDecoder.decode(
                    DirectMentionSourceBatchResponse.self,
                    from: responseData
                )
            } catch {
                logger.error("Direct mention source response decode failed for \(batch.count, privacy: .public) PRs: \(error.localizedDescription)")
                failedIDs.formUnion(batch.map(\.prID))
                continue
            }

            let erroredAliases = Self.graphQLErrorAliases(in: responseData)
            let globalGraphQLError = Self.hasGraphQLErrors(in: responseData) && erroredAliases.isEmpty
            for (index, entry) in batch.enumerated() {
                let alias = "pr_\(index)"
                guard !globalGraphQLError,
                      !erroredAliases.contains(alias),
                      let node = response.data.aliases[alias],
                      let source = Self.makeDirectMentionSourceSnapshot(from: node),
                      node.databaseId == entry.prID,
                      let state = node.state,
                      let isDraft = node.isDraft,
                      let repository = node.repository else {
                    failedIDs.insert(entry.prID)
                    continue
                }

                baseSources[entry.prID] = entry.source
                guard state.uppercased() == "OPEN" else {
                    closedIDs.insert(entry.prID)
                    continue
                }
                var updatedEntry = entry
                updatedEntry.pullRequest.isDraft = isDraft
                updatedEntry.pullRequest.repositoryIsArchived = repository.isArchived
                if source == entry.source {
                    refreshed[entry.prID] = updatedEntry
                } else {
                    changed.append((updatedEntry, source))
                }
            }
        }

        for batch in changed.chunked(into: Self.directMentionStateBatchSize) {
            let stateResult = await refreshDirectMentionState(
                username: username,
                entries: batch.map(\.0),
                sources: Dictionary(uniqueKeysWithValues: batch.map { ($0.0.prID, $0.1) })
            )
            refreshed.merge(stateResult.refreshed) { _, new in new }
            closedIDs.formUnion(stateResult.closedIDs)
            failedIDs.formUnion(stateResult.failedIDs)
        }

        return DirectMentionRefreshResult(
            baseSources: baseSources,
            refreshed: refreshed,
            closedIDs: closedIDs,
            failedIDs: failedIDs
        )
    }

    private struct DirectMentionStateRefreshResult {
        var refreshed: [Int: DirectMentionTrackingEntry]
        var closedIDs: Set<Int>
        var failedIDs: Set<Int>
    }

    private struct DirectMentionContent {
        let title: String
        let body: String?
        let author: String
        let createdAt: Date
        let updatedAt: Date
        let lastEditedAt: Date?
    }

    private func refreshDirectMentionState(
        username: String,
        entries: [DirectMentionTrackingEntry],
        sources: [Int: DirectMentionSourceSnapshot]
    ) async -> DirectMentionStateRefreshResult {
        guard !entries.isEmpty else {
            return DirectMentionStateRefreshResult(refreshed: [:], closedIDs: [], failedIDs: [])
        }

        var failedIDs = Set<Int>()
        var closedIDs = Set<Int>()
        var commentsByID: [Int: [String: IssueCommentSummary]] = [:]
        var pageSignaturesByID: [Int: Set<String>] = [:]
        var contentByID: [Int: DirectMentionContent] = [:]
        var cursors: [Int: String] = [:]
        var seenCursorsByID: [Int: Set<String>] = [:]
        var completeIDs = Set<Int>()
        var remaining = await MainActor.run { self.rateLimitInfo.remaining }

        for entry in entries {
            commentsByID[entry.prID] = [:]
            seenCursorsByID[entry.prID] = []
            pageSignaturesByID[entry.prID] = []
        }

        while completeIDs.count + failedIDs.count + closedIDs.count < entries.count {
            let active = entries.filter {
                !completeIDs.contains($0.prID) &&
                    !failedIDs.contains($0.prID) &&
                    !closedIDs.contains($0.prID)
            }
            guard !active.isEmpty else { break }
            guard remaining >= Self.directMentionRateFloor else {
                failedIDs.formUnion(active.map(\.prID))
                break
            }

            let query = buildDirectMentionStateQuery(entries: active, cursors: cursors)
            let responseData: Data
            do {
                responseData = try await executeGraphQL(
                    query: query,
                    operation: "refreshDirectMentionState"
                )
            } catch {
                logger.error("Direct mention state request failed for \(active.count, privacy: .public) PRs: \(error.localizedDescription)")
                failedIDs.formUnion(active.map(\.prID))
                break
            }

            if let rateLimit = Self.graphQLRateLimit(in: responseData) {
                remaining = rateLimit.remaining
                await recordGraphQLRateLimit(rateLimit)
            }

            let response: DirectMentionStateBatchResponse
            do {
                response = try JSONDecoder.githubDecoder.decode(
                    DirectMentionStateBatchResponse.self,
                    from: responseData
                )
            } catch {
                logger.error("Direct mention state response decode failed for \(active.count, privacy: .public) PRs: \(error.localizedDescription)")
                failedIDs.formUnion(active.map(\.prID))
                break
            }

            let erroredAliases = Self.graphQLErrorAliases(in: responseData)
            let globalGraphQLError = Self.hasGraphQLErrors(in: responseData) && erroredAliases.isEmpty
            var aliasesByID: [Int: String] = [:]
            var aliasEntries: [String: DirectMentionTrackingEntry] = [:]
            for (index, entry) in active.enumerated() {
                let alias = "pr_\(index)"
                aliasesByID[entry.prID] = alias
                aliasEntries[alias] = entry
            }

            for entry in active {
                guard let alias = aliasesByID[entry.prID],
                      !globalGraphQLError,
                      !erroredAliases.contains(alias),
                      let node = response.data.aliases[alias],
                      node.databaseId == entry.prID,
                      let comments = node.comments else {
                    failedIDs.insert(entry.prID)
                    continue
                }

                guard node.state?.uppercased() == "OPEN" else {
                    closedIDs.insert(entry.prID)
                    continue
                }
                guard !comments.hadDroppedNodes,
                      let pageInfo = comments.pageInfo else {
                    failedIDs.insert(entry.prID)
                    continue
                }
                guard let title = node.title,
                      let author = node.author?.login,
                      let createdAt = node.createdAt,
                      let updatedAt = node.updatedAt else {
                    failedIDs.insert(entry.prID)
                    continue
                }
                contentByID[entry.prID] = DirectMentionContent(
                    title: title,
                    body: node.body,
                    author: author,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    lastEditedAt: node.lastEditedAt
                )

                let pageIDs = comments.nodes.map(\.id)
                if !pageIDs.isEmpty {
                    let signature = pageIDs.sorted().joined(separator: "\u{1F}")
                    guard pageSignaturesByID[entry.prID, default: []].insert(signature).inserted else {
                        failedIDs.insert(entry.prID)
                        continue
                    }
                }
                var byID = commentsByID[entry.prID] ?? [:]
                for comment in comments.nodes {
                    byID[comment.id] = IssueCommentSummary(
                        id: comment.id,
                        author: comment.author?.login ?? "unknown",
                        body: comment.body ?? "",
                        createdAt: comment.createdAt,
                        lastEditedAt: comment.lastEditedAt
                    )
                }
                commentsByID[entry.prID] = byID

                if pageInfo.hasNextPage {
                    guard !pageIDs.isEmpty,
                          let next = pageInfo.endCursor,
                          !next.isEmpty,
                          next != cursors[entry.prID],
                          !seenCursorsByID[entry.prID, default: []].contains(next) else {
                        failedIDs.insert(entry.prID)
                        continue
                    }
                    seenCursorsByID[entry.prID, default: []].insert(next)
                    cursors[entry.prID] = next
                } else {
                    guard let expectedCount = sources[entry.prID]?.commentCount,
                          byID.count == expectedCount else {
                        failedIDs.insert(entry.prID)
                        continue
                    }
                    completeIDs.insert(entry.prID)
                }
            }

            if !erroredAliases.isEmpty {
                for alias in erroredAliases {
                    if let entry = aliasEntries[alias] {
                        failedIDs.insert(entry.prID)
                    }
                }
            }

            if remaining < Self.directMentionRateFloor {
                let stillActive = entries.filter {
                    !completeIDs.contains($0.prID) &&
                        !failedIDs.contains($0.prID) &&
                        !closedIDs.contains($0.prID)
                }
                failedIDs.formUnion(stillActive.map(\.prID))
                break
            }
        }

        var refreshed: [Int: DirectMentionTrackingEntry] = [:]

        for entry in entries where completeIDs.contains(entry.prID) {
            guard let source = sources[entry.prID],
                  let content = contentByID[entry.prID] else {
                failedIDs.insert(entry.prID)
                continue
            }
            let comments = (commentsByID[entry.prID] ?? [:]).values.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
            let count = Self.pendingDirectMentionCount(
                username: username,
                pullRequestAuthor: content.author,
                title: content.title,
                body: content.body,
                contentCreatedAt: content.createdAt,
                contentLastEditedAt: content.lastEditedAt ?? source.lastEditedAt,
                comments: comments
            )
            var updated = entry
            updated.pullRequest = Self.updatingPullRequest(
                entry.pullRequest,
                title: content.title,
                body: content.body,
                author: content.author,
                createdAt: content.createdAt,
                updatedAt: content.updatedAt
            )
            let latestComment = comments.last
            updated.source = DirectMentionSourceSnapshot(
                updatedAt: content.updatedAt,
                lastEditedAt: content.lastEditedAt ?? source.lastEditedAt,
                commentCount: comments.count,
                latestCommentID: latestComment?.id,
                latestCommentLastEditedAt: latestComment?.lastEditedAt
            )
            updated.state = DirectMentionState(pendingCount: count)
            updated.lastSeenAt = Date()
            refreshed[entry.prID] = updated
        }

        return DirectMentionStateRefreshResult(
            refreshed: refreshed,
            closedIDs: closedIDs,
            failedIDs: failedIDs
        )
    }
    /// Discover candidates with GitHub's mentions search. Search is deliberately
    /// hourly in PRManager; ordinary polling uses refreshTrackedMentions instead.
    func discoverDirectMentions(
        username: String,
        configuration: Configuration,
        existingEntries: [Int: DirectMentionTrackingEntry]
    ) async -> DirectMentionDiscoveryResult {
        var seenIDs = Set<Int>()
        var discovered: [Int: DirectMentionTrackingEntry] = [:]
        var isComplete = true
        let existingByID = existingEntries
        var changedExisting: [(DirectMentionTrackingEntry, DirectMentionSourceSnapshot)] = []
        var newCandidates: [(id: Int, reference: PullRequestReference, source: DirectMentionSourceSnapshot)] = []
        var decodedIDs = Set<Int>()
        var expectedIssueCount = 0
        var cursor: String?
        var seenCursors = Set<String>()
        var remaining = await MainActor.run { self.rateLimitInfo.remaining }

        while true {
            guard remaining >= Self.directMentionRateFloor else {
                isComplete = false
                break
            }

            let query = buildDirectMentionDiscoveryQuery(username: username, after: cursor)
            let responseData: Data
            do {
                responseData = try await executeGraphQL(
                    query: query,
                    operation: "discoverDirectMentions"
                )
            } catch {
                logger.error("Direct mention discovery request failed: \(error.localizedDescription)")
                isComplete = false
                break
            }

            if Self.hasGraphQLErrors(in: responseData) {
                isComplete = false
            }
            if let rateLimit = Self.graphQLRateLimit(in: responseData) {
                remaining = rateLimit.remaining
                await recordGraphQLRateLimit(rateLimit)
            }

            let response: DirectMentionDiscoveryResponse
            do {
                response = try JSONDecoder.githubDecoder.decode(
                    DirectMentionDiscoveryResponse.self,
                    from: responseData
                )
            } catch {
                logger.error("Direct mention discovery response decode failed: \(error.localizedDescription)")
                isComplete = false
                break
            }

            expectedIssueCount = max(expectedIssueCount, response.data.search.issueCount)
            if response.data.search.droppedNodeCount > 0 {
                isComplete = false
            }

            for node in response.data.search.nodes {
                guard let databaseId = node.databaseId,
                      let source = Self.makeDirectMentionSourceSnapshot(from: node) else {
                    isComplete = false
                    continue
                }
                guard decodedIDs.insert(databaseId).inserted else { continue }

                let repoFullName = "\(node.repository.owner.login)/\(node.repository.name)"
                guard PullRequestFilter.includes(
                    repoFullName: repoFullName,
                    isArchived: node.repository.isArchived,
                    isDraft: node.isDraft,
                    configuration: configuration
                ) else {
                    continue
                }

                let reference = PullRequestReference(
                    owner: node.repository.owner.login,
                    repo: node.repository.name,
                    number: node.number
                )
                seenIDs.insert(databaseId)
                if let existing = existingByID[databaseId] {
                    guard source != existing.source else { continue }
                    changedExisting.append((existing, source))
                } else {
                    newCandidates.append((databaseId, reference, source))
                }
            }

            let pageInfo = response.data.search.pageInfo
            guard pageInfo.hasNextPage else { break }
            guard let next = pageInfo.endCursor,
                  !next.isEmpty,
                  seenCursors.insert(next).inserted else {
                isComplete = false
                break
            }
            cursor = next
        }

        if expectedIssueCount > decodedIDs.count {
            isComplete = false
        }

        // Fetch the full row only after scope filtering. This preserves the
        // existing alias/detail/CI machinery without embedding all comments.
        var rowsByID: [Int: PullRequest] = [:]
        let rowFieldSelection = buildPRFieldSelection(
            includeReviewMetadata: false,
            includeMentionBodies: true
        )
        for batch in newCandidates.chunked(into: Self.batchedPRQuerySize) {
            guard remaining >= Self.directMentionRateFloor else {
                isComplete = false
                break
            }
            do {
                let rows = try await fetchMentionedBatch(
                    batch.map(\.reference),
                    fieldSelection: rowFieldSelection,
                    operation: "fetchDirectMentionRows"
                )
                for row in rows where row.state == .open {
                    rowsByID[row.id] = row
                }
                let currentRemaining = await MainActor.run { self.rateLimitInfo.remaining }
                if currentRemaining < Self.directMentionRateFloor {
                    remaining = currentRemaining
                }
            } catch {
                logger.error("Direct mention row fetch failed for \(batch.count, privacy: .public) PRs: \(error.localizedDescription)")
                isComplete = false
            }
        }

        var stateEntries: [DirectMentionTrackingEntry] = []
        for candidate in newCandidates {
            guard let row = rowsByID[candidate.id] else {
                isComplete = false
                continue
            }
            var entry = DirectMentionTrackingEntry(
                prID: candidate.id,
                reference: candidate.reference,
                pullRequest: row,
                source: candidate.source,
                state: DirectMentionState(pendingCount: 0),
                lastSeenAt: Date()
            )
            entry.pullRequest.mentionCount = nil
            stateEntries.append(entry)
        }

        for batch in (stateEntries + changedExisting.map(\.0)).chunked(into: Self.directMentionStateBatchSize) {
            var sources: [Int: DirectMentionSourceSnapshot] = [:]
            for entry in batch {
                if let source = newCandidates.first(where: { $0.id == entry.prID })?.source {
                    sources[entry.prID] = source
                } else if let source = changedExisting.first(where: { $0.0.prID == entry.prID })?.1 {
                    sources[entry.prID] = source
                }
            }
            let result = await refreshDirectMentionState(
                username: username,
                entries: batch,
                sources: sources
            )
            if !result.closedIDs.isEmpty || !result.failedIDs.isEmpty {
                isComplete = false
            }
            for (id, refreshed) in result.refreshed
            where !result.failedIDs.contains(id) && !result.closedIDs.contains(id) {
                discovered[id] = refreshed
            }
        }

        if !isComplete {
            logger.warning("Direct mention discovery incomplete: seen=\(seenIDs.count, privacy: .public) discovered=\(discovered.count, privacy: .public) decoded=\(decodedIDs.count, privacy: .public) expected=\(expectedIssueCount, privacy: .public)")
        }

        // A complete search can safely drive absence deletion in the manager;
        // partial pages, dropped nodes, cap truncation, and failed detail/state
        // requests deliberately leave isComplete false.
        return DirectMentionDiscoveryResult(
            seenIDs: seenIDs,
            discovered: discovered,
            isComplete: isComplete
        )
    }
    private func buildDirectMentionSourceQuery(
        entries: [DirectMentionTrackingEntry]
    ) -> String {
        let aliases = entries.enumerated().map { index, entry in
            """
            pr_\(index): repository(owner: \(Self.graphQLStringLiteral(entry.reference.owner)), name: \(Self.graphQLStringLiteral(entry.reference.repo))) {
                pullRequest(number: \(entry.reference.number)) {
                    databaseId
                    state
                    isDraft
                    repository {
                        isArchived
                    }
                    updatedAt
                    lastEditedAt
                    comments {
                        totalCount
                    }
                    latestComments: comments(last: 1) {
                        nodes {
                            id
                            lastEditedAt
                        }
                    }
                }
            }
            """
        }
        return """
        query {
            \(aliases.joined(separator: "\n"))
            rateLimit {
                cost
                remaining
                resetAt
            }
        }
        """
    }

    private func buildDirectMentionStateQuery(
        entries: [DirectMentionTrackingEntry],
        cursors: [Int: String]
    ) -> String {
        let aliases = entries.enumerated().map { index, entry in
            let after = cursors[entry.prID].map {
                ", after: \(Self.graphQLStringLiteral($0))"
            } ?? ""
            return """
            pr_\(index): repository(owner: \(Self.graphQLStringLiteral(entry.reference.owner)), name: \(Self.graphQLStringLiteral(entry.reference.repo))) {
                pullRequest(number: \(entry.reference.number)) {
                    databaseId
                    state
                    title
                    body
                    author {
                        login
                    }
                    createdAt
                    updatedAt
                    lastEditedAt
                    comments(first: 100\(after)) {
                        nodes {
                            id
                            author {
                                login
                            }
                            body
                            createdAt
                            lastEditedAt
                        }
                        pageInfo {
                            hasNextPage
                            endCursor
                        }
                    }
                }
            }
            """
        }
        return """
        query {
            \(aliases.joined(separator: "\n"))
            rateLimit {
                cost
                remaining
                resetAt
            }
        }
        """
    }

    private func buildDirectMentionDiscoveryQuery(
        username: String,
        after: String?
    ) -> String {
        let afterClause = after.map {
            ", after: \(Self.graphQLStringLiteral($0))"
        } ?? ""
        return """
        query {
            search(
                query: \(Self.graphQLStringLiteral("is:pr is:open mentions:\(username) sort:updated-desc")),
                type: ISSUE,
                first: \(Self.directMentionSearchPageSize)\(afterClause)
            ) {
                issueCount
                nodes {
                    ... on PullRequest {
                        databaseId
                        number
                        title
                        body
                        author {
                            login
                        }
                        createdAt
                        updatedAt
                        lastEditedAt
                        isDraft
                        repository {
                            owner {
                                login
                            }
                            name
                            isArchived
                        }
                        comments {
                            totalCount
                        }
                        latestComments: comments(last: 1) {
                            nodes {
                                id
                                lastEditedAt
                            }
                        }
                    }
                }
                pageInfo {
                    hasNextPage
                    endCursor
                }
            }
            rateLimit {
                cost
                remaining
                resetAt
            }
        }
        """
    }

    private static func makeDirectMentionSourceSnapshot(
        from node: DirectMentionSourceBatchResponse.SourceNode
    ) -> DirectMentionSourceSnapshot? {
        guard node.databaseId != nil,
              node.state != nil,
              let updatedAt = node.updatedAt,
              let comments = node.comments,
              let commentCount = comments.totalCount,
              let latestComments = node.latestComments else {
            return nil
        }
        let latest = latestComments.nodes.first
        guard commentCount == 0 || latest?.id != nil else { return nil }
        return DirectMentionSourceSnapshot(
            updatedAt: updatedAt,
            lastEditedAt: node.lastEditedAt,
            commentCount: commentCount,
            latestCommentID: latest?.id,
            latestCommentLastEditedAt: latest?.lastEditedAt
        )
    }

    private static func makeDirectMentionSourceSnapshot(
        from node: DirectMentionDiscoveryResponse.SearchNode
    ) -> DirectMentionSourceSnapshot? {
        guard node.databaseId != nil,
              let comments = node.comments,
              let commentCount = comments.totalCount,
              let latestComments = node.latestComments else {
            return nil
        }
        let latest = latestComments.nodes.first
        guard commentCount == 0 || latest?.id != nil else { return nil }
        return DirectMentionSourceSnapshot(
            updatedAt: node.updatedAt,
            lastEditedAt: node.lastEditedAt,
            commentCount: commentCount,
            latestCommentID: latest?.id,
            latestCommentLastEditedAt: latest?.lastEditedAt
        )
    }

    private func recordGraphQLRateLimit(_ rateLimit: DirectMentionRateLimit) async {
        let resetDate = rateLimit.resetAt.flatMap { Self.parseISO8601Date($0) } ?? Date()
        await MainActor.run {
            self.rateLimitInfo = RateLimitInfo(
                limit: self.rateLimitInfo.limit,
                remaining: rateLimit.remaining,
                resetDate: resetDate
            )
        }
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func graphQLRateLimit(in data: Data) -> DirectMentionRateLimit? {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                let rateLimit: DirectMentionRateLimit?
            }
            let data: Payload?
        }
        return try? JSONDecoder.githubDecoder.decode(Envelope.self, from: data).data?.rateLimit
    }

    private static func hasGraphQLErrors(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]] else {
            return false
        }
        return !errors.isEmpty
    }

    private static func graphQLErrorAliases(in data: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]] else {
            return []
        }
        var aliases = Set<String>()
        for error in errors {
            guard let path = error["path"] as? [Any],
                  let first = path.first as? String,
                  first.hasPrefix("pr_") else {
                continue
            }
            aliases.insert(first)
        }
        return aliases
    }

    private static func updatingPullRequest(
        _ old: PullRequest,
        title: String?,
        body: String?,
        author: String?,
        createdAt: Date?,
        updatedAt: Date?
    ) -> PullRequest {
        var updated = PullRequest(
            id: old.id,
            graphqlNodeId: old.graphqlNodeId,
            number: old.number,
            title: title ?? old.title,
            author: author ?? old.author,
            authorAvatarURL: old.authorAvatarURL,
            repositoryOwner: old.repositoryOwner,
            repositoryName: old.repositoryName,
            repositoryIsArchived: old.repositoryIsArchived,
            url: old.url,
            state: old.state,
            isDraft: old.isDraft,
            createdAt: createdAt ?? old.createdAt,
            updatedAt: updatedAt ?? old.updatedAt,
            mergedAt: old.mergedAt,
            body: body,
            conversationComments: old.conversationComments,
            lastCommitAt: old.lastCommitAt,
            headCommitOid: old.headCommitOid,
            baseRefName: old.baseRefName,
            headRefName: old.headRefName,
            baseNeedsUpdate: old.baseNeedsUpdate,
            approvalAuthors: old.approvalAuthors,
            changesRequestedAuthors: old.changesRequestedAuthors,
            reviewThreads: old.reviewThreads,
            category: old.category,
            hasBaseConflicts: old.hasBaseConflicts,
            ciStatus: old.ciStatus,
            checkSuccessCount: old.checkSuccessCount,
            checkFailureCount: old.checkFailureCount,
            checkPendingCount: old.checkPendingCount,
            githubCIState: old.githubCIState,
            myLastReviewState: old.myLastReviewState,
            myLastReviewAt: old.myLastReviewAt,
            reviewRequestedAt: old.reviewRequestedAt,
            myThreadsAllResolved: old.myThreadsAllResolved,
            approvalCount: old.approvalCount,
            changesRequestedCount: old.changesRequestedCount,
            ciExtendedInfo: old.ciExtendedInfo,
            jiraTicket: old.jiraTicket,
            jiraTitle: old.jiraTitle,
            jiraLabels: old.jiraLabels,
            jiraStatusName: old.jiraStatusName,
            jiraStatusCategoryKey: old.jiraStatusCategoryKey,
            jiraUpdatedAt: old.jiraUpdatedAt,
            jiraMetadataFetchedAt: old.jiraMetadataFetchedAt,
            isOpenInCmux: old.isOpenInCmux
        )
        updated.mentionCount = old.mentionCount
        return updated
    }
    func validateToken() async throws -> Bool {
        let query = """
        query {
            viewer {
                login
            }
        }
        """

        do {
            _ = try await executeGraphQL(query: query, operation: "validateToken")
            return true
        } catch APIError.unauthorized {
            return false
        }
    }

    struct UpdatePullRequestBranchResult {
        let headCommitOid: String?
        let lastCommitAt: Date?
        let baseNeedsUpdate: Bool?
    }

    func updatePullRequestBranchWithRebase(
        pullRequestId: String,
        expectedHeadOid: String?
    ) async throws -> UpdatePullRequestBranchResult {
        let mutation = """
        mutation UpdatePullRequestBranchWithRebase(
            $pullRequestId: ID!,
            $expectedHeadOid: GitObjectID,
            $updateMethod: PullRequestBranchUpdateMethod!
        ) {
            updatePullRequestBranch(input: {
                pullRequestId: $pullRequestId,
                expectedHeadOid: $expectedHeadOid,
                updateMethod: $updateMethod
            }) {
                pullRequest {
                    mergeStateStatus
                    commits(last: 1) {
                        nodes {
                            commit {
                                oid
                                committedDate
                            }
                        }
                    }
                }
            }
        }
        """

        var variables: [String: Any] = [
            "pullRequestId": pullRequestId,
            "updateMethod": "REBASE"
        ]
        if let expectedHeadOid {
            variables["expectedHeadOid"] = expectedHeadOid
        }

        let responseData = try await executeGraphQL(
            query: mutation,
            operation: "updatePullRequestBranchWithRebase",
            variables: variables
        )
        return try parseUpdatePullRequestBranchResponse(data: responseData)
    }

    private func parseUpdatePullRequestBranchResponse(data: Data) throws -> UpdatePullRequestBranchResult {
        struct Response: Decodable {
            let data: DataContainer?

            struct DataContainer: Decodable {
                let updatePullRequestBranch: UpdatePullRequestBranchPayload?
            }

            struct UpdatePullRequestBranchPayload: Decodable {
                let pullRequest: PRNode?
            }

            struct PRNode: Decodable {
                let mergeStateStatus: String?
                let commits: CommitsContainer?
            }

            struct CommitsContainer: Decodable {
                let nodes: [CommitNode]
            }

            struct CommitNode: Decodable {
                let commit: CommitInfo
            }

            struct CommitInfo: Decodable {
                let oid: String?
                let committedDate: Date?
            }
        }

        let decoder = JSONDecoder.githubDecoder
        let response: Response
        do {
            response = try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }

        guard let pr = response.data?.updatePullRequestBranch?.pullRequest else {
            throw APIError.invalidResponse
        }
        let commit = pr.commits?.nodes.first?.commit
        return UpdatePullRequestBranchResult(
            headCommitOid: commit?.oid,
            lastCommitAt: commit?.committedDate,
            baseNeedsUpdate: Self.deriveBaseNeedsUpdate(mergeStateStatus: pr.mergeStateStatus)
        )
    }

    struct PRHoverMetadata {
        let databaseId: Int
        let graphqlNodeId: String?
        let baseRefName: String?
        let headRefName: String?
        let baseNeedsUpdate: Bool?
        let approvalAuthors: [String]
        let changesRequestedAuthors: [String]
        let approvalCount: Int
        let changesRequestedCount: Int
        let headCommitOid: String?
        let lastCommitAt: Date?
        let ciStatus: CIStatus?
        let githubCIState: String?
        let checkSuccessCount: Int?
        let checkFailureCount: Int?
        let checkPendingCount: Int?
        let ciExtendedInfo: CIExtendedInfo?
    }

    func fetchHoverMetadata(for pr: PullRequest, includeCI: Bool) async throws -> PRHoverMetadata {
        let ciContextSection = includeCI ? """
                            contexts(first: 20) {
                                nodes {
                                    ... on CheckRun {
                                        name
                                        conclusion
                                        completedAt
                                        checkSuite {
                                            workflowRun {
                                                workflow {
                                                    name
                                                }
                                            }
                                        }
                                    }
                                    ... on StatusContext {
                                        context
                                        state
                                    }
                                }
                                pageInfo {
                                    hasNextPage
                                    endCursor
                                }
                            }
        """ : ""

        let query = """
        query {
            repository(owner: "\(pr.repositoryOwner)", name: "\(pr.repositoryName)") {
                pullRequest(number: \(pr.number)) {
                    id
                    databaseId
                    baseRefName
                    headRefName
                    mergeable
                    mergeStateStatus
                    latestReviews(first: 20) {
                        nodes {
                            state
                            author {
                                login
                            }
                        }
                    }
                    commits(last: 1) {
                        nodes {
                            commit {
                                oid
                                committedDate
                                statusCheckRollup {
                                    state
        \(ciContextSection)
                                }
                            }
                        }
                    }
                }
            }
            rateLimit {
                cost
                remaining
                resetAt
            }
        }
        """

        let responseData = try await executeGraphQL(query: query, operation: "fetchHoverMetadata")

        let decoder = JSONDecoder.githubDecoder
        let response: HoverMetadataResponse
        do {
            response = try decoder.decode(HoverMetadataResponse.self, from: responseData)
        } catch {
            throw APIError.decoding(error)
        }

        if let rl = response.data.rateLimit {
            logger.info("Hover metadata cost=\(rl.cost, privacy: .public) remaining=\(rl.remaining, privacy: .public) pr=\(pr.repoFullName)#\(pr.number, privacy: .public)")
        }

        guard let node = response.data.repository?.pullRequest,
              let databaseId = node.databaseId else {
            throw APIError.unknown(String(localized: "Failed to load PR hover details"))
        }

        let latestReviews = node.latestReviews?.nodes ?? []
        let reviewAgg = Self.aggregateReviews(latestReviews, state: { $0.state }, login: { $0.author?.login })
        let approvalAuthors = reviewAgg.approvalAuthors
        let changesRequestedAuthors = reviewAgg.changesRequestedAuthors
        let approvalCount = reviewAgg.approvalCount
        let changesRequestedCount = reviewAgg.changesRequestedCount

        let commit = node.commits?.nodes.first?.commit
        var ciStatus: CIStatus?
        var githubCIState: String?
        var checkSuccessCount: Int?
        var checkFailureCount: Int?
        var checkPendingCount: Int?
        var ciExtendedInfo: CIExtendedInfo?

        if includeCI, let statusCheckRollup = commit?.statusCheckRollup {
            let excludeFilter = Self.loadCIStatusExcludeFilter()
            var ciResult = Self.parseCIContexts(
                Self.contextNodes(from: statusCheckRollup.contexts?.nodes ?? []),
                excludeFilter: excludeFilter
            )
            let upperRollup = statusCheckRollup.state.uppercased()

            if let pageInfo = statusCheckRollup.contexts?.pageInfo,
               Self.shouldFetchRemainingCIContexts(rollupState: upperRollup, hasNextPage: pageInfo.hasNextPage),
               let endCursor = pageInfo.endCursor,
               let commitOid = commit?.oid {
                do {
                    let (combined, _) = try await fetchFullCIContexts(
                        owner: pr.repositoryOwner,
                        repo: pr.repositoryName,
                        commitOid: commitOid,
                        startCursor: endCursor,
                        initialCount: statusCheckRollup.contexts?.nodes.count ?? 0,
                        seed: ciResult
                    )
                    ciResult = combined
                } catch {
                    logger.warning("Failed to enrich hover CI metadata for \(pr.repoFullName)#\(pr.number, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            ciStatus = Self.deriveCIStatus(from: ciResult) ?? .expected

            var effectivePendingCount = ciResult.pendingCount
            var effectiveIsRunning = ciResult.isRunning
            if ciStatus == .success, upperRollup == "PENDING" {
                ciStatus = .pending
                effectivePendingCount = max(effectivePendingCount, 1)
                effectiveIsRunning = true
            }

            githubCIState = statusCheckRollup.state
            checkSuccessCount = ciResult.successCount
            checkFailureCount = ciResult.failureCount
            checkPendingCount = effectivePendingCount
            ciExtendedInfo = ciResult.workflows.isEmpty ? nil : CIExtendedInfo(
                isRunning: effectiveIsRunning,
                workflows: Array(ciResult.workflows.values)
            )

            let shouldFetchWorkflowRunGuard = ciStatus == .success || (
                ciStatus == .failure && !excludeFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            if shouldFetchWorkflowRunGuard, let headSHA = commit?.oid, !headSHA.isEmpty {
                do {
                    let summary = try await fetchWorkflowRunCompletionSummary(
                        owner: pr.repositoryOwner,
                        repo: pr.repositoryName,
                        headSHA: headSHA,
                        excludeFilter: excludeFilter
                    )
                    let snapshot = Self.CIStatusSnapshot(
                        status: ciStatus,
                        successCount: checkSuccessCount ?? 0,
                        failureCount: checkFailureCount ?? 0,
                        pendingCount: checkPendingCount ?? 0,
                        extendedInfo: ciExtendedInfo
                    )
                    let adjusted = Self.applyingWorkflowRunSummary(to: snapshot, summary: summary)
                    ciStatus = adjusted.status
                    checkSuccessCount = adjusted.successCount
                    checkFailureCount = adjusted.failureCount
                    checkPendingCount = adjusted.pendingCount
                    ciExtendedInfo = adjusted.extendedInfo
                } catch {
                    logger.warning("Failed to fetch hover workflow-run completion guard for \(pr.repoFullName)#\(pr.number, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let graphQLBaseNeedsUpdate = Self.deriveBaseNeedsUpdate(mergeStateStatus: node.mergeStateStatus)
        let baseNeedsUpdate = await resolveBaseNeedsUpdateForHover(
            owner: pr.repositoryOwner,
            repo: pr.repositoryName,
            base: node.baseRefName,
            head: node.headRefName,
            mergeable: node.mergeable,
            mergeStateStatus: node.mergeStateStatus,
            graphQLBaseNeedsUpdate: graphQLBaseNeedsUpdate
        )

        return PRHoverMetadata(
            databaseId: databaseId,
            graphqlNodeId: node.id,
            baseRefName: node.baseRefName,
            headRefName: node.headRefName,
            baseNeedsUpdate: baseNeedsUpdate,
            approvalAuthors: approvalAuthors,
            changesRequestedAuthors: changesRequestedAuthors,
            approvalCount: approvalCount,
            changesRequestedCount: changesRequestedCount,
            headCommitOid: commit?.oid,
            lastCommitAt: commit?.committedDate,
            ciStatus: ciStatus,
            githubCIState: githubCIState,
            checkSuccessCount: checkSuccessCount,
            checkFailureCount: checkFailureCount,
            checkPendingCount: checkPendingCount,
            ciExtendedInfo: ciExtendedInfo
        )
    }

    private func resolveBaseNeedsUpdateForHover(
        owner: String,
        repo: String,
        base: String?,
        head: String?,
        mergeable: String?,
        mergeStateStatus: String?,
        graphQLBaseNeedsUpdate: Bool?
    ) async -> Bool? {
        if graphQLBaseNeedsUpdate == true {
            return true
        }
        if Self.deriveBaseConflicts(mergeable: mergeable, mergeStateStatus: mergeStateStatus) {
            return graphQLBaseNeedsUpdate
        }
        guard Self.shouldCompareBaseUpdateStatus(mergeStateStatus: mergeStateStatus),
              let base,
              let head else {
            return graphQLBaseNeedsUpdate
        }

        do {
            return try await fetchBaseNeedsUpdateByCompare(
                owner: owner,
                repo: repo,
                base: base,
                head: head
            )
        } catch {
            logger.warning(
                "Failed to compare base/head for \(owner, privacy: .public)/\(repo, privacy: .public):\(base, privacy: .public)...\(head, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return graphQLBaseNeedsUpdate
        }
    }

    func fetchBaseNeedsUpdateByCompare(
        owner: String,
        repo: String,
        base: String,
        head: String
    ) async throws -> Bool? {
        guard let url = Self.compareURL(owner: owner, repo: repo, base: base, head: head) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        updateRateLimitInfo(from: httpResponse)

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.http(statusCode: httpResponse.statusCode)
        }

        struct CompareResponse: Decodable {
            let behindBy: Int

            enum CodingKeys: String, CodingKey {
                case behindBy = "behind_by"
            }
        }

        do {
            let decoded = try JSONDecoder.githubDecoder.decode(CompareResponse.self, from: data)
            return decoded.behindBy > 0
        } catch {
            throw APIError.decoding(error)
        }
    }

    static func compareURL(owner: String, repo: String, base: String, head: String) -> URL? {
        let comparePath = "\(base)...\(head)"
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "/")
        guard let encodedComparePath = comparePath.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            return nil
        }
        return URL(string: "https://api.github.com/repos/\(owner)/\(repo)/compare/\(encodedComparePath)")
    }

    /// Fetches additional CI contexts for a commit when pagination is needed
    func fetchAdditionalCIContexts(owner: String, repo: String, commitOid: String, after: String) async throws -> CIContextsResult {
        let query = """
        query {
            repository(owner: "\(owner)", name: "\(repo)") {
                object(oid: "\(commitOid)") {
                    ... on Commit {
                        statusCheckRollup {
                            contexts(first: 100, after: "\(after)") {
                                nodes {
                                    ... on CheckRun {
                                        name
                                        conclusion
                                        completedAt
                                        checkSuite {
                                            workflowRun {
                                                workflow {
                                                    name
                                                }
                                            }
                                        }
                                    }
                                    ... on StatusContext {
                                        context
                                        state
                                    }
                                }
                                pageInfo {
                                    hasNextPage
                                    endCursor
                                }
                            }
                        }
                    }
                }
            }
        }
        """

        let responseData = try await executeGraphQL(query: query, operation: "fetchAdditionalCIContexts")
        return try parseCIContextsResponse(data: responseData)
    }

    func fetchWorkflowRunCompletionSummary(
        owner: String,
        repo: String,
        headSHA: String,
        excludeFilter: String = ""
    ) async throws -> WorkflowRunCompletionSummary {
        var allRuns: [WorkflowRunSnapshot] = []
        let perPage = 100
        var page = 1
        var totalCount: Int?

        repeat {
            let response = try await fetchWorkflowRunsPage(
                owner: owner,
                repo: repo,
                headSHA: headSHA,
                perPage: perPage,
                page: page
            )
            totalCount = response.totalCount
            allRuns.append(contentsOf: response.workflowRuns)

            if response.workflowRuns.count < perPage {
                break
            }
            page += 1
        } while allRuns.count < (totalCount ?? allRuns.count)

        return Self.summarizeWorkflowRunCompletion(allRuns, excludeFilter: excludeFilter)
    }

    struct CIContextsResult {
        let contexts: [CIContextNode]
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct CIContextNode: CIContextLike {
        let name: String?
        let conclusion: String?
        let state: String?
        let context: String?
        let workflowName: String?
        let completedAt: Date?

        var ciName: String? { name }
        var ciConclusion: String? { conclusion }
        var ciState: String? { state }
        var ciContext: String? { context }
        var ciWorkflowName: String? { workflowName }
        var ciCompletedAt: Date? { completedAt }
    }

    private struct WorkflowRunsPage {
        let totalCount: Int
        let workflowRuns: [WorkflowRunSnapshot]
    }

    private func fetchWorkflowRunsPage(
        owner: String,
        repo: String,
        headSHA: String,
        perPage: Int,
        page: Int
    ) async throws -> WorkflowRunsPage {
        var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/runs")
        components?.queryItems = [
            URLQueryItem(name: "head_sha", value: headSHA),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard let url = components?.url else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        updateRateLimitInfo(from: httpResponse)
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.unknown(String(localized: "Failed to fetch workflow runs: HTTP \(httpResponse.statusCode)"))
        }

        struct Response: Decodable {
            let totalCount: Int
            let workflowRuns: [Run]

            enum CodingKeys: String, CodingKey {
                case totalCount = "total_count"
                case workflowRuns = "workflow_runs"
            }

            struct Run: Decodable {
                let id: Int
                let name: String?
                let displayTitle: String?
                let path: String?
                let workflowId: Int?
                let runNumber: Int?
                let runAttempt: Int?
                let status: String?
                let conclusion: String?
                let createdAt: Date?
                let updatedAt: Date?

                enum CodingKeys: String, CodingKey {
                    case id
                    case name
                    case displayTitle = "display_title"
                    case path
                    case workflowId = "workflow_id"
                    case runNumber = "run_number"
                    case runAttempt = "run_attempt"
                    case status
                    case conclusion
                    case createdAt = "created_at"
                    case updatedAt = "updated_at"
                }
            }
        }

        do {
            let decoded = try JSONDecoder.githubDecoder.decode(Response.self, from: data)
            return WorkflowRunsPage(
                totalCount: decoded.totalCount,
                workflowRuns: decoded.workflowRuns.map {
                    WorkflowRunSnapshot(
                        id: $0.id,
                        name: $0.name,
                        displayTitle: $0.displayTitle,
                        path: $0.path,
                        workflowId: $0.workflowId,
                        runNumber: $0.runNumber ?? 0,
                        runAttempt: $0.runAttempt ?? 0,
                        status: $0.status,
                        conclusion: $0.conclusion,
                        createdAt: $0.createdAt,
                        updatedAt: $0.updatedAt
                    )
                }
            )
        } catch {
            throw APIError.decoding(error)
        }
    }

    private static func compileRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            fatalError("Invalid regex \(pattern): \(error)")
        }
    }

    // GraphQL enum values for PR mergeable/mergeStateStatus indicating base-branch conflicts
    private static let mergeableConflicting = "CONFLICTING"
    private static let mergeStateDirty = "DIRTY"
    private static let mergeStateBehind = "BEHIND"
    private static let mergeStateClean = "CLEAN"
    private static let reviewStateApproved = "APPROVED"
    private static let reviewStateChangesRequested = "CHANGES_REQUESTED"

    struct ReviewAggregate {
        var approvalCount = 0
        var changesRequestedCount = 0
        var approvalAuthors: [String] = []
        var changesRequestedAuthors: [String] = []
    }

    private static func aggregateReviews<T>(
        _ reviews: [T],
        state: (T) -> String,
        login: (T) -> String?,
        collectAuthors: Bool = true
    ) -> ReviewAggregate {
        var agg = ReviewAggregate()
        var approvalSeen = Set<String>()
        var changesSeen = Set<String>()
        for review in reviews {
            switch state(review) {
            case reviewStateApproved:
                agg.approvalCount += 1
                if collectAuthors, let l = login(review), approvalSeen.insert(l.lowercased()).inserted {
                    agg.approvalAuthors.append(l)
                }
            case reviewStateChangesRequested:
                agg.changesRequestedCount += 1
                if collectAuthors, let l = login(review), changesSeen.insert(l.lowercased()).inserted {
                    agg.changesRequestedAuthors.append(l)
                }
            default:
                break
            }
        }
        return agg
    }

    private static func deriveBaseConflicts(mergeable: String?, mergeStateStatus: String?) -> Bool {
        mergeable == mergeableConflicting || mergeStateStatus == mergeStateDirty
    }

    private static func deriveBaseNeedsUpdate(mergeStateStatus: String?) -> Bool? {
        guard let mergeStateStatus else { return nil }
        switch mergeStateStatus {
        case mergeStateBehind:
            return true
        case mergeStateClean, mergeStateDirty:
            return false
        default:
            return nil
        }
    }

    private static func shouldCompareBaseUpdateStatus(mergeStateStatus: String?) -> Bool {
        guard let mergeStateStatus else { return true }
        switch mergeStateStatus {
        case mergeStateBehind, mergeStateClean, mergeStateDirty:
            return false
        default:
            return true
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    /// Decide whether to paginate past the first page of CI contexts.
    ///
    /// We paginate for FAILURE/PENDING (need the full picture to count failed/done
    /// tasks) and for SUCCESS so the workflow count reflects every workflow that
    /// ran, not just those whose checks landed on the first page. `hasNextPage`
    /// gates the cost: small-CI PRs (single page) never pay for an extra request;
    /// only large-CI PRs — exactly the ones whose first-page sample undercounts
    /// workflows — trigger pagination.
    static func shouldFetchRemainingCIContexts(rollupState: String, hasNextPage: Bool) -> Bool {
        guard hasNextPage else { return false }
        switch rollupState.uppercased() {
        case "FAILURE", "PENDING", "SUCCESS":
            return true
        default:
            return false
        }
    }


    private func buildPRFieldSelection(
        username: String? = nil,
        includeReviewMetadata: Bool,
        includeMentionBodies: Bool,
        includeReviewAuthors: Bool = false
    ) -> String {
        let reviewCommentBodyField = includeMentionBodies ? "\n                            body" : ""
        let reviewAuthorField = includeReviewAuthors ? """

                    author {
                        login
                    }
        """ : ""
        let bodySection = includeMentionBodies ? """
            body
            comments(last: 20) {
                nodes {
                    id
                    author {
                        login
                    }
                    body
                    createdAt
                    lastEditedAt
                }
            }
        """ : ""

        var sections: [String] = [
            """
            id
            databaseId
            number
            title
            url
            state
            isDraft
            baseRefName
            headRefName
            createdAt
            updatedAt
            mergedAt
            mergeable
            mergeStateStatus
            author {
                login
                avatarUrl
            }
            repository {
                owner {
                    login
                }
                name
                isArchived
            }
            \(bodySection)
            reviewThreads(last: 20) {
                nodes {
                    id
                    isResolved
                    isOutdated
                    path
                    line
                    comments(first: 5) {
                        nodes {
                            id
                            author {
                                login
                            }
                            createdAt\(reviewCommentBodyField)
                        }
                    }
                }
                pageInfo {
                    hasPreviousPage
                    startCursor
                }
            }
            commits(last: 1) {
                nodes {
                    commit {
                        oid
                        committedDate
                        statusCheckRollup {
                            state
                            contexts(first: 20) {
                                nodes {
                                    ... on CheckRun {
                                        name
                                        conclusion
                                        completedAt
                                        checkSuite {
                                            workflowRun {
                                                workflow {
                                                    name
                                                }
                                            }
                                        }
                                    }
                                    ... on StatusContext {
                                        context
                                        state
                                    }
                                }
                                pageInfo {
                                    hasNextPage
                                    endCursor
                                }
                            }
                        }
                    }
                }
            }
            latestReviews(first: 20) {
                nodes {
                    state\(reviewAuthorField)
                }
            }
            """
        ]

        if includeReviewMetadata, let username {
            sections.append(
                """
                reviews(author: "\(username)", last: 1) {
                    nodes {
                        state
                        submittedAt
                    }
                }
                reviewRequestEvents: timelineItems(last: 10, itemTypes: [REVIEW_REQUESTED_EVENT]) {
                    nodes {
                        ... on ReviewRequestedEvent {
                            createdAt
                            requestedReviewer {
                                ... on User {
                                    login
                                }
                            }
                        }
                    }
                }
                """
            )
        }


        return sections.joined(separator: "\n")
    }
    private func buildMentionSourceFieldSelection() -> String {
        """
        id
        databaseId
        number
        updatedAt
        repository {
            owner {
                login
            }
            name
        }
        crossReferences: timelineItems(last: 50, itemTypes: [CROSS_REFERENCED_EVENT]) {
            nodes {
                ... on CrossReferencedEvent {
                    source {
                        ... on PullRequest {
                            databaseId
                            number
                            state
                            repository {
                                owner {
                                    login
                                }
                                name
                            }
                        }
                    }
                    target {
                        ... on PullRequest {
                            databaseId
                            number
                            state
                            repository {
                                owner {
                                    login
                                }
                                name
                            }
                        }
                    }
                }
            }
        }
        """
    }

    private static func inboundMentionReferences(
        from node: MentionSourceBatchResponse.PRNode,
        currentPR: PullRequestReference
    ) -> Set<PullRequestReference> {
        let currentRepoLower = currentPR.repoFullName.lowercased()
        var result = Set<PullRequestReference>()

        func insert(_ related: MentionSourceBatchResponse.RelatedPR?) {
            guard let related,
                  related.state == "OPEN",
                  related.repoFullName.lowercased() == currentRepoLower,
                  related.number != currentPR.number else {
                return
            }
            result.insert(
                PullRequestReference(
                    owner: related.repository.owner.login,
                    repo: related.repository.name,
                    number: related.number
                )
            )
        }

        for event in node.crossReferences?.nodes ?? [] {
            insert(event.source)
            insert(event.target)
        }
        return result
    }


    private func parseCIContextsResponse(data: Data) throws -> CIContextsResult {
        struct Response: Decodable {
            let data: DataContainer
            struct DataContainer: Decodable {
                let repository: RepositoryContainer?
            }
            struct RepositoryContainer: Decodable {
                let object: ObjectContainer?
            }
            struct ObjectContainer: Decodable {
                let statusCheckRollup: StatusCheckRollup?
            }
            struct StatusCheckRollup: Decodable {
                let contexts: ContextsContainer?
            }
            struct ContextsContainer: Decodable {
                let nodes: [ContextNode]
                let pageInfo: PageInfo?
            }
            struct PageInfo: Decodable {
                let hasNextPage: Bool
                let endCursor: String?
            }
            struct ContextNode: Decodable {
                let name: String?
                let conclusion: String?
                let completedAt: Date?
                let state: String?
                let context: String?
                let checkSuite: CheckSuiteNode?
            }
            struct CheckSuiteNode: Decodable {
                let workflowRun: WorkflowRunNode?
            }
            struct WorkflowRunNode: Decodable {
                let workflow: WorkflowNode?
            }
            struct WorkflowNode: Decodable {
                let name: String?
            }
        }

        let decoder = JSONDecoder.githubDecoder
        let response = try decoder.decode(Response.self, from: data)

        guard let contexts = response.data.repository?.object?.statusCheckRollup?.contexts else {
            return CIContextsResult(contexts: [], hasNextPage: false, endCursor: nil)
        }

        let ciContexts = contexts.nodes.map { node in
            CIContextNode(
                name: node.name,
                conclusion: node.conclusion,
                state: node.state,
                context: node.context,
                workflowName: node.checkSuite?.workflowRun?.workflow?.name,
                completedAt: node.completedAt
            )
        }

        return CIContextsResult(
            contexts: ciContexts,
            hasNextPage: contexts.pageInfo?.hasNextPage ?? false,
            endCursor: contexts.pageInfo?.endCursor
        )
    }

    // MARK: - CI Parsing

    /// Protocol to unify different ContextNode types for shared CI parsing
    private protocol CIContextLike {
        var ciName: String? { get }
        var ciConclusion: String? { get }
        var ciState: String? { get }
        var ciContext: String? { get }
        var ciWorkflowName: String? { get }
        var ciCompletedAt: Date? { get }
    }

    /// Result of parsing CI contexts into workflow-grouped info
    private struct CIParseResult {
        var successCount: Int = 0
        var failureCount: Int = 0
        var blockingFailureCount: Int = 0
        var pendingCount: Int = 0
        var isRunning: Bool = false
        var workflows: [String: CIWorkflowInfo] = [:]
        var seenCheckNames: Set<String> = []
    }

    /// Core CI-status ladder shared by every GraphQL parse path. A blocking
    /// (non-excluded) failure wins, then any pending check, then any completed
    /// check — note success OR an excluded/non-blocking failure both render as
    /// `.success`. Returns nil when no check contributed, leaving each caller to
    /// supply its own fallback (`.expected`, a rollup-based value, or nil).
    private static func deriveCIStatus(from result: CIParseResult) -> CIStatus? {
        if result.blockingFailureCount > 0 { return .failure }
        if result.pendingCount > 0 { return .pending }
        if result.successCount > 0 || result.failureCount > 0 { return .success }
        return nil
    }

    /// CI fields a search-parsed PullRequest exposes, derived from a parsed
    /// `CIParseResult` plus GitHub's rollup state.
    private struct SearchCIDerivation {
        let status: CIStatus?
        let successCount: Int
        let failureCount: Int
        let pendingCount: Int
        let extendedInfo: CIExtendedInfo?
    }

    /// Derive the search-path CI fields from a `CIParseResult` and the rollup
    /// state. Shared by `makeSearchPullRequest` and the mentioned-path context
    /// pagination pass so both apply the identical trust-rollup-PENDING rule
    /// (GitHub reports PENDING for QUEUED checks not yet visible as contexts).
    private static func deriveSearchCI(
        from ciResult: CIParseResult,
        rollupState: String?,
        hasRollup: Bool
    ) -> SearchCIDerivation {
        var status: CIStatus? = deriveCIStatus(from: ciResult) ?? (hasRollup ? .expected : nil)
        var effectivePendingCount = ciResult.pendingCount
        var effectiveIsRunning = ciResult.isRunning
        if status == .success, rollupState?.uppercased() == "PENDING" {
            status = .pending
            effectivePendingCount = max(effectivePendingCount, 1)
            effectiveIsRunning = true
        }
        let extendedInfo: CIExtendedInfo? = ciResult.workflows.isEmpty ? nil : CIExtendedInfo(
            isRunning: effectiveIsRunning,
            workflows: Array(ciResult.workflows.values)
        )
        return SearchCIDerivation(
            status: status,
            successCount: ciResult.successCount,
            failureCount: ciResult.failureCount,
            pendingCount: effectivePendingCount,
            extendedInfo: extendedInfo
        )
    }

    private static func contextNodes(from nodes: [GraphQLResponse.ContextNode]) -> [CIContextNode] {
        nodes.map { ctx in
            CIContextNode(
                name: ctx.name,
                conclusion: ctx.conclusion,
                state: ctx.state,
                context: ctx.context,
                workflowName: ctx.checkSuite?.workflowRun?.workflow?.name,
                completedAt: ctx.completedAt
            )
        }
    }

    /// Shared CI context parsing logic used by parseSearchResponse, parseNodes, and fetchFullCIContexts
    private static func parseCIContexts<T: CIContextLike>(_ contexts: [T], excludeFilter: String, existing: CIParseResult = CIParseResult()) -> CIParseResult {
        var result = existing
        let excludeMatcher = CIExcludeMatcher(pattern: excludeFilter)

        // Sort newest-first by completedAt so dedup keeps the latest result per check name.
        // Entries without completedAt (in-progress checks, StatusContexts) sort to the end.
        let sorted = contexts.sorted {
            ($0.ciCompletedAt ?? .distantPast) > ($1.ciCompletedAt ?? .distantPast)
        }
        for context in sorted {
            let isExcluded = excludeMatcher.matchesAny([context.ciWorkflowName])

            if let conclusion = context.ciConclusion {
                // CheckRun with conclusion
                if let name = context.ciName {
                    if result.seenCheckNames.contains(name) { continue }
                    result.seenCheckNames.insert(name)
                }
                let workflowKey = context.ciWorkflowName ?? context.ciName ?? "unknown"
                let isWorkflow = context.ciWorkflowName != nil

                switch conclusion.uppercased() {
                case "SUCCESS":
                    result.successCount += 1
                    updateWorkflow(&result.workflows, key: workflowKey, isWorkflow: isWorkflow, success: 1)
                case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE":
                    result.failureCount += 1
                    if !isExcluded {
                        result.blockingFailureCount += 1
                    }
                    updateWorkflow(&result.workflows, key: workflowKey, isWorkflow: isWorkflow, failure: 1)
                case "CANCELLED", "SKIPPED", "NEUTRAL", "STALE":
                    break
                default:
                    result.pendingCount += 1
                    result.isRunning = true
                    updateWorkflow(&result.workflows, key: workflowKey, isWorkflow: isWorkflow, pending: 1)
                }
            } else if let state = context.ciState {
                // StatusContext
                let workflowKey = context.ciContext ?? "status"
                switch state.uppercased() {
                case "SUCCESS":
                    result.successCount += 1
                    updateWorkflow(&result.workflows, key: workflowKey, isWorkflow: false, success: 1)
                case "FAILURE", "ERROR":
                    result.failureCount += 1
                    if !isExcluded {
                        result.blockingFailureCount += 1
                    }
                    updateWorkflow(&result.workflows, key: workflowKey, isWorkflow: false, failure: 1)
                case "PENDING", "EXPECTED":
                    result.pendingCount += 1
                    if state.uppercased() == "PENDING" { result.isRunning = true }
                    updateWorkflow(&result.workflows, key: workflowKey, isWorkflow: false, pending: 1)
                default:
                    break
                }
            } else {
                // CheckRun with no conclusion = in progress
                if let name = context.ciName {
                    if result.seenCheckNames.contains(name) { continue }
                    result.seenCheckNames.insert(name)
                }
                let workflowKey = context.ciWorkflowName ?? context.ciName ?? "unknown"
                let isWorkflow = context.ciWorkflowName != nil
                result.pendingCount += 1
                result.isRunning = true
                updateWorkflow(&result.workflows, key: workflowKey, isWorkflow: isWorkflow, pending: 1)
            }
        }

        return result
    }

    private static func updateWorkflow(
        _ workflows: inout [String: CIWorkflowInfo],
        key: String,
        isWorkflow: Bool,
        success: Int = 0,
        failure: Int = 0,
        pending: Int = 0
    ) {
        if var wf = workflows[key] {
            wf.successCount += success
            wf.failureCount += failure
            wf.pendingCount += pending
            workflows[key] = wf
        } else {
            workflows[key] = CIWorkflowInfo(
                name: key,
                isWorkflow: isWorkflow,
                successCount: success,
                failureCount: failure,
                pendingCount: pending
            )
        }
    }

    static func latestWorkflowRunsByCurrentRound(_ runs: [WorkflowRunSnapshot]) -> [WorkflowRunSnapshot] {
        var latestByWorkflow: [String: WorkflowRunSnapshot] = [:]

        for run in runs {
            let key = run.groupingKey
            if let existing = latestByWorkflow[key],
               compareWorkflowRuns(run, existing) != .orderedDescending {
                continue
            }
            latestByWorkflow[key] = run
        }

        return Array(latestByWorkflow.values)
    }

    static func summarizeWorkflowRunCompletion(
        _ runs: [WorkflowRunSnapshot],
        excludeFilter: String = ""
    ) -> WorkflowRunCompletionSummary {
        let latestRuns = latestWorkflowRunsByCurrentRound(runs)
        let excludeMatcher = CIExcludeMatcher(pattern: excludeFilter)
        var completed = 0
        var success = 0
        var skipped = 0
        var failureLike = 0
        var blockingFailureLike = 0
        var inFlight = 0

        for run in latestRuns {
            let conclusion = run.conclusion?.lowercased()
            let isCompleted = run.status?.lowercased() == "completed" || isTerminalWorkflowRunConclusion(conclusion)

            if isCompleted {
                completed += 1
            } else {
                inFlight += 1
            }

            switch conclusion {
            case "success":
                success += 1
            case "skipped":
                skipped += 1
            case "failure", "cancelled", "timed_out", "action_required", "startup_failure":
                failureLike += 1
                if !excludeMatcher.matchesAny([run.displayTitle, run.name]) {
                    blockingFailureLike += 1
                }
            default:
                break
            }
        }

        return WorkflowRunCompletionSummary(
            totalCount: latestRuns.count,
            completedCount: completed,
            successCount: success,
            skippedCount: skipped,
            failureLikeCount: failureLike,
            blockingFailureLikeCount: blockingFailureLike,
            inFlightCount: inFlight
        )
    }

    private static func compareWorkflowRuns(_ lhs: WorkflowRunSnapshot, _ rhs: WorkflowRunSnapshot) -> ComparisonResult {
        if lhs.runNumber != rhs.runNumber {
            return lhs.runNumber > rhs.runNumber ? .orderedDescending : .orderedAscending
        }
        if lhs.runAttempt != rhs.runAttempt {
            return lhs.runAttempt > rhs.runAttempt ? .orderedDescending : .orderedAscending
        }

        let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
        let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate ? .orderedDescending : .orderedAscending
        }
        if lhs.id != rhs.id {
            return lhs.id > rhs.id ? .orderedDescending : .orderedAscending
        }
        return .orderedSame
    }

    private static func isTerminalWorkflowRunConclusion(_ conclusion: String?) -> Bool {
        guard let conclusion else { return false }
        return [
            "action_required",
            "cancelled",
            "failure",
            "neutral",
            "skipped",
            "stale",
            "success",
            "timed_out",
            "startup_failure"
        ].contains(conclusion)
    }

    private struct CIStatusSnapshot {
        var status: CIStatus?
        var successCount: Int
        var failureCount: Int
        var pendingCount: Int
        var extendedInfo: CIExtendedInfo?
    }

    private static func applyingWorkflowRunSummary(
        to snapshot: CIStatusSnapshot,
        summary: WorkflowRunCompletionSummary
    ) -> CIStatusSnapshot {
        guard summary.totalCount > 0 else {
            return snapshot
        }

        var adjusted = snapshot

        if summary.failureLikeCount > 0 {
            adjusted.failureCount = max(adjusted.failureCount, summary.failureLikeCount)
            addSyntheticWorkflowIfNeeded(
                to: &adjusted.extendedInfo,
                name: String(localized: "Failed workflow"),
                failureCount: summary.failureLikeCount,
                pendingCount: 0
            )
        }

        if summary.inFlightCount > 0 {
            adjusted.status = .pending
            adjusted.pendingCount = max(adjusted.pendingCount, summary.inFlightCount)
            setCIRunning(true, in: &adjusted.extendedInfo)
            addSyntheticWorkflowIfNeeded(
                to: &adjusted.extendedInfo,
                name: String(localized: "Queued workflow"),
                failureCount: 0,
                pendingCount: summary.inFlightCount
            )
        } else if summary.blockingFailureLikeCount > 0 {
            adjusted.status = .failure
            setCIRunning(false, in: &adjusted.extendedInfo)
        } else if summary.allCompleted, (adjusted.status == .success || summary.failureLikeCount > 0) {
            adjusted.status = .success
            adjusted.pendingCount = 0
            setCIRunning(false, in: &adjusted.extendedInfo)
        }

        return adjusted
    }

    private static func setCIRunning(_ isRunning: Bool, in extendedInfo: inout CIExtendedInfo?) {
        if extendedInfo == nil, isRunning {
            extendedInfo = CIExtendedInfo(isRunning: true, workflows: [])
            return
        }
        extendedInfo?.isRunning = isRunning
    }

    private static func addSyntheticWorkflowIfNeeded(
        to extendedInfo: inout CIExtendedInfo?,
        name: String,
        failureCount: Int,
        pendingCount: Int
    ) {
        guard failureCount > 0 || pendingCount > 0 else { return }

        var info = extendedInfo ?? CIExtendedInfo(isRunning: pendingCount > 0, workflows: [])
        let alreadyRepresented = info.workflows.contains { workflow in
            (failureCount > 0 && workflow.failureCount > 0) ||
            (pendingCount > 0 && workflow.pendingCount > 0)
        }
        if !alreadyRepresented {
            info.workflows.append(
                CIWorkflowInfo(
                    name: name,
                    isWorkflow: true,
                    successCount: 0,
                    failureCount: failureCount,
                    pendingCount: pendingCount
                )
            )
        }
        if pendingCount > 0 {
            info.isRunning = true
        }
        extendedInfo = info
    }

    // MARK: - Private

    private func buildPRIndexFieldSelection() -> String {
        """
        id
        databaseId
        number
        title
        url
        state
        isDraft
        baseRefName
        headRefName
        createdAt
        updatedAt
        mergedAt
        mergeable
        mergeStateStatus
        author {
            login
            avatarUrl
        }
        repository {
            owner {
                login
            }
            name
            isArchived
        }
        reviewThreads(last: 50) {
            totalCount
            nodes {
                id
                isResolved
                isOutdated
            }
        }
        oldestReviewThreads: reviewThreads(first: 50) {
            totalCount
            nodes {
                id
                isResolved
                isOutdated
            }
        }
        comments {
            totalCount
        }
        reviews {
            totalCount
        }
        commits(last: 1) {
            nodes {
                commit {
                    oid
                    committedDate
                    statusCheckRollup {
                        state
                    }
                }
            }
        }
        """
    }

    // One search per request. Combining all four index searches into a single
    // GraphQL document made GitHub evaluate up to 200 PR nodes (4 × first: 50)
    // with their nested repository/author/commits/reviewThreads selections in
    // one shot, which blows GitHub's per-query resource budget once the user has
    // ~50 authored PRs: the API returns HTTP 200 with `RESOURCE_LIMITS_EXCEEDED`
    // errors and null nodes, which the strict decoder then surfaced as a
    // confusing "Failed to parse response" error. A single search of 50 PRs with
    // full thread sampling resolves comfortably (cost ~2), so each search now
    // runs as its own request.
    private func buildIndexSearchQuery(searchQuery: String) -> String {
        let fragment = buildPRIndexFieldSelection()
        return """
        query {
            search(query: \(Self.graphQLStringLiteral(searchQuery)), type: ISSUE, first: 50) {
                nodes {
                    ... on PullRequest {
                        \(fragment)
                    }
                }
            }
            rateLimit {
                cost
                remaining
                resetAt
            }
        }
        """
    }

    func fetchIndex(username: String) async throws -> [IndexedPR] {
        let mergedSince = Self.dateStringForSearch(daysBack: 2)
        // Run the four searches concurrently to keep the index off the critical
        // path; each is independent and bounded to first: 50.
        async let authored = fetchIndexSearch(
            "is:pr is:open author:\(username)", operation: "fetchIndex.authored")
        async let reviewRequested = fetchIndexSearch(
            "is:pr is:open -author:\(username) review-requested:\(username)",
            operation: "fetchIndex.reviewRequested")
        async let reviewedBy = fetchIndexSearch(
            "is:pr is:open -author:\(username) reviewed-by:\(username)",
            operation: "fetchIndex.reviewedBy")
        async let mergedInvolved = fetchIndexSearch(
            "is:pr is:merged involves:\(username) merged:>=\(mergedSince)",
            operation: "fetchIndex.mergedInvolved")

        let groups = try await (authored, reviewRequested, reviewedBy, mergedInvolved)
        return buildIndexedPRs(
            authored: groups.0,
            reviewRequested: groups.1,
            reviewedBy: groups.2,
            mergedInvolved: groups.3,
            username: username
        )
    }

    private func fetchIndexSearch(
        _ searchQuery: String,
        operation: String
    ) async throws -> [IndexSearchResponse.PRNode] {
        let query = buildIndexSearchQuery(searchQuery: searchQuery)
        let data = try await executeGraphQL(query: query, operation: operation)
        let decoder = JSONDecoder.githubDecoder
        let response: IndexSearchResponse
        do {
            response = try decoder.decode(IndexSearchResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
        if let rl = response.data.rateLimit {
            logger.info("Index \(operation, privacy: .public) cost=\(rl.cost, privacy: .public) remaining=\(rl.remaining, privacy: .public) nodes=\(response.data.search.nodes.count, privacy: .public)")
        }
        return response.data.search.nodes
    }

    func buildIndexedPRs(
        authored: [IndexSearchResponse.PRNode],
        reviewRequested: [IndexSearchResponse.PRNode],
        reviewedBy: [IndexSearchResponse.PRNode],
        mergedInvolved: [IndexSearchResponse.PRNode],
        username: String
    ) -> [IndexedPR] {
        let usernameLower = username.lowercased()
        // Dedupe by databaseId: the 4 aliased searches overlap (e.g. a PR can be
        // both `review-requested:me` and `reviewed-by:me`). First write wins,
        // matching iteration order: authored → reviewRequested → reviewedBy → mergedInvolved.
        var result: [IndexedPR] = []
        var seen: Set<Int> = []

        func appendIfNew(_ ip: IndexedPR) {
            guard seen.insert(ip.databaseId).inserted else { return }
            result.append(ip)
        }

        func indexedFromNode(
            _ node: IndexSearchResponse.PRNode,
            category: PRCategory,
            isMerged: Bool
        ) -> IndexedPR? {
            guard let databaseId = node.databaseId else { return nil }
            let lastCommit = node.commits?.nodes.first?.commit
            // Sampled from the first 50 and last 50 threads; for PRs with
            // more, resolution changes on the middle slice rely on the TTL
            // to eventually refresh.
            let newestNodes = node.reviewThreads?.nodes ?? []
            let oldestNodes = node.oldestReviewThreads?.nodes ?? []
            var seenThreadIds = Set<String>()
            var sampledUnresolved = 0
            for threadNode in newestNodes where seenThreadIds.insert(threadNode.id).inserted {
                if !threadNode.isResolved && !threadNode.isOutdated {
                    sampledUnresolved += 1
                }
            }
            for threadNode in oldestNodes where seenThreadIds.insert(threadNode.id).inserted {
                if !threadNode.isResolved && !threadNode.isOutdated {
                    sampledUnresolved += 1
                }
            }
            // Base-branch conflicts surface when the base branch advances, which
            // bumps none of the other index scalars. Carry the derived flag both
            // as the IndexedPR value (so cache hits paint the badge immediately)
            // and inside the snapshot (so a conflict transition forces a detail
            // refetch instead of reusing stale detail for the full TTL).
            let hasBaseConflicts = Self.deriveBaseConflicts(
                mergeable: node.mergeable,
                mergeStateStatus: node.mergeStateStatus
            )
            let snapshot = IndexSnapshot(
                updatedAt: node.updatedAt,
                headOid: lastCommit?.oid,
                ciRollupState: lastCommit?.statusCheckRollup?.state.uppercased(),
                reviewThreadTotal: node.reviewThreads?.totalCount ?? 0,
                commentTotal: node.comments?.totalCount ?? 0,
                reviewTotal: node.reviews?.totalCount ?? 0,
                unresolvedReviewThreadCount: sampledUnresolved,
                hasBaseConflicts: hasBaseConflicts
            )
            return IndexedPR(
                databaseId: databaseId,
                graphqlNodeId: node.id,
                number: node.number,
                title: node.title,
                url: node.url,
                state: PRState(rawValue: node.state) ?? .open,
                isDraft: node.isDraft,
                createdAt: node.createdAt,
                updatedAt: node.updatedAt,
                mergedAt: node.mergedAt,
                author: node.author?.login ?? "unknown",
                authorAvatarURL: node.author?.avatarUrl,
                repositoryOwner: node.repository.owner.login,
                repositoryName: node.repository.name,
                repositoryIsArchived: node.repository.isArchived,
                baseRefName: node.baseRefName,
                headRefName: node.headRefName,
                baseNeedsUpdate: nil,
                hasBaseConflicts: hasBaseConflicts,
                category: category,
                isMerged: isMerged,
                snapshot: snapshot
            )
        }

        for node in authored {
            if let ip = indexedFromNode(node, category: .authored, isMerged: false) {
                appendIfNew(ip)
            }
        }
        for node in reviewRequested {
            if let ip = indexedFromNode(node, category: .reviewRequest, isMerged: false) {
                appendIfNew(ip)
            }
        }
        for node in reviewedBy {
            if let ip = indexedFromNode(node, category: .reviewRequest, isMerged: false) {
                appendIfNew(ip)
            }
        }
        for node in mergedInvolved {
            let resolved: PRCategory = (node.author?.login.lowercased() == usernameLower) ? .authored : .reviewRequest
            if let ip = indexedFromNode(node, category: resolved, isMerged: true) {
                appendIfNew(ip)
            }
        }
        return result
    }


    static func authoredMentionReferenceSearchQuery(
        username: String,
        daysBack: Int,
        now: Date = Date()
    ) -> String {
        "is:pr author:\(username) created:>=\(dateStringForSearch(daysBack: daysBack, now: now))"
    }

    private static func dateStringForSearch(daysBack: Int, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let sinceDate = calendar.date(byAdding: .day, value: -daysBack, to: now) ?? now

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: sinceDate)
    }

    private func buildGraphQLQuery(searchQuery: String) -> String {
        let fieldSelection = buildPRFieldSelection(
            includeReviewMetadata: false,
            includeMentionBodies: false
        )
        return buildSearchQuery(searchQuery: searchQuery, first: 50, after: nil, fieldSelection: fieldSelection)
    }

    private func buildSearchQuery(
        searchQuery: String,
        first: Int,
        after: String?,
        fieldSelection: String
    ) -> String {
        let afterClause = after.map { ", after: \(Self.graphQLStringLiteral($0))" } ?? ""
        return """
        query {
            search(query: \(Self.graphQLStringLiteral(searchQuery)), type: ISSUE, first: \(first)\(afterClause)) {
                nodes {
                    ... on PullRequest {
                        \(fieldSelection)
                    }
                }
                pageInfo {
                    hasNextPage
                    endCursor
                }
            }
        }
        """
    }
    private func buildReferenceSearchQuery(
        searchQuery: String,
        first: Int,
        after: String?
    ) -> String {
        let afterClause = after.map { ", after: \(Self.graphQLStringLiteral($0))" } ?? ""
        return """
        query {
            search(query: \(Self.graphQLStringLiteral(searchQuery)), type: ISSUE, first: \(first)\(afterClause)) {
                nodes {
                    ... on PullRequest {
                        number
                        repository {
                            owner {
                                login
                            }
                            name
                        }
                    }
                }
                pageInfo {
                    hasNextPage
                    endCursor
                }
            }
            rateLimit {
                cost
                remaining
                resetAt
            }
        }
        """
    }


    private static func graphQLStringLiteral(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }

    private func executeGraphQL(
        query: String,
        operation: String,
        variables: [String: Any]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: graphQLURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        var body: [String: Any] = ["query": query]
        if let variables, !variables.isEmpty {
            body["variables"] = variables
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        for attempt in 1...Self.maxGraphQLAttempts {
            let attemptStart = Date()
            do {
                let (data, response) = try await session.data(for: request)
                let elapsed = Date().timeIntervalSince(attemptStart)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }

                updateRateLimitInfo(from: httpResponse)

                switch httpResponse.statusCode {
                case 200:
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                        let messages = errors.compactMap { $0["message"] as? String }
                        if messages.contains(where: Self.isRateLimitMessage) {
                            let resetDate = rateLimitResetDate(from: httpResponse) ?? Date().addingTimeInterval(60)
                            throw APIError.rateLimited(resetDate: resetDate)
                        }
                        // GraphQL partial success: `data` and `errors` can coexist.
                        // One bad aliased sub-query (e.g. a mentioned `#NNN` that
                        // is really an Issue or a deleted PR) used to fail the
                        // whole batch; instead, warn and let the per-alias
                        // decoders skip nulls. Only hard-fail when data is empty.
                        let hasUsablePayload: Bool = {
                            guard let dict = json["data"] as? [String: Any] else { return false }
                            return dict.values.contains { !($0 is NSNull) }
                        }()
                        if hasUsablePayload {
                            logger.warning(
                                "GraphQL partial errors: operation=\(operation, privacy: .public) count=\(errors.count, privacy: .public) first=\(messages.first ?? "", privacy: .public)"
                            )
                        } else {
                            throw APIError.unknown(messages.first ?? String(localized: "GraphQL request failed"))
                        }
                    }

                    if attempt > 1 {
                        logger.info("GraphQL request recovered: operation=\(operation, privacy: .public) attempt=\(attempt)/\(Self.maxGraphQLAttempts) elapsed=\(elapsed.formattedSeconds, privacy: .public)s")
                    }
                    return data
                case 401:
                    throw APIError.unauthorized
                case 403:
                    if let rateLimitError = rateLimitError(from: httpResponse) {
                        throw rateLimitError
                    }
                    throw APIError.unauthorized
                case 429:
                    if let rateLimitError = rateLimitError(from: httpResponse) {
                        throw rateLimitError
                    }
                    throw APIError.http(statusCode: httpResponse.statusCode)
                default:
                    logger.warning(
                        "GraphQL upstream error: operation=\(operation, privacy: .public) attempt=\(attempt)/\(Self.maxGraphQLAttempts) status=\(httpResponse.statusCode, privacy: .public) elapsed=\(elapsed.formattedSeconds, privacy: .public)s bytes=\(data.count, privacy: .public)"
                    )
                    throw APIError.http(statusCode: httpResponse.statusCode)
                }
            } catch {
                let elapsed = Date().timeIntervalSince(attemptStart)
                let apiError = normalizeGraphQLError(error)
                let decision = retryDecision(for: apiError, attempt: attempt)

                if let delay = decision.delay, attempt < Self.maxGraphQLAttempts {
                    logger.warning(
                        "GraphQL request retry scheduled: operation=\(operation, privacy: .public) attempt=\(attempt)/\(Self.maxGraphQLAttempts) classification=\(decision.classification, privacy: .public) elapsed=\(elapsed.formattedSeconds, privacy: .public)s retryIn=\(delay.formattedSeconds, privacy: .public)s"
                    )
                    try await Task.sleep(nanoseconds: delay.nanoseconds)
                    continue
                }

                logger.error(
                    "GraphQL request failed: operation=\(operation, privacy: .public) attempt=\(attempt)/\(Self.maxGraphQLAttempts) classification=\(decision.classification, privacy: .public) elapsed=\(elapsed.formattedSeconds, privacy: .public)s error=\(apiError.localizedDescription, privacy: .public)"
                )
                throw apiError
            }
        }

        throw APIError.unknown(String(localized: "GraphQL request failed without a terminal error"))
    }

    private func updateRateLimitInfo(from response: HTTPURLResponse) {
        if let limitStr = response.value(forHTTPHeaderField: "X-RateLimit-Limit"),
           let remainingStr = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let resetStr = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let limit = Int(limitStr),
           let remaining = Int(remainingStr),
           let resetTimestamp = TimeInterval(resetStr) {
            Task { @MainActor in
                self.rateLimitInfo = RateLimitInfo(
                    limit: limit,
                    remaining: remaining,
                    resetDate: Date(timeIntervalSince1970: resetTimestamp)
                )
            }
        }
    }

    private func rateLimitResetDate(from response: HTTPURLResponse) -> Date? {
        guard let resetTime = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let timestamp = TimeInterval(resetTime) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func rateLimitError(from response: HTTPURLResponse) -> APIError? {
        rateLimitResetDate(from: response).map { APIError.rateLimited(resetDate: $0) }
    }

    static func isRateLimitMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("rate limit") ||
               lowered.contains("secondary rate") ||
               lowered.contains("abuse")
    }

    private func normalizeGraphQLError(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }
        return APIError.network(error)
    }

    private func retryDecision(for error: APIError, attempt: Int) -> RetryDecision {
        if error.isCancellation {
            return RetryDecision(classification: "cancellation", delay: nil)
        }

        switch error {
        case .rateLimited:
            return RetryDecision(classification: "rateLimited", delay: nil)
        case .network(_) where error.isTransient:
            return RetryDecision(classification: "transientNetwork", delay: graphQLRetryDelay(for: attempt))
        case .http(let statusCode) where [408, 429, 500, 502, 503, 504].contains(statusCode):
            return RetryDecision(classification: "transientHTTP", delay: graphQLRetryDelay(for: attempt))
        default:
            return RetryDecision(classification: "terminal", delay: nil)
        }
    }

    private func graphQLRetryDelay(for attempt: Int) -> TimeInterval {
        let cap: TimeInterval = attempt == 1 ? 2 : 4
        return Double.random(in: 0.5...cap)
    }

    private func parseSearchResponse(data: Data, category: PRCategory) throws -> [PullRequest] {
        let decoder = JSONDecoder.githubDecoder
        do {
            let response = try decoder.decode(GraphQLResponse.self, from: data)
            let excludeFilter = Self.loadCIStatusExcludeFilter()
            return response.data.search.nodes.compactMap {
                Self.makeSearchPullRequest(from: $0, category: category, excludeFilter: excludeFilter)
            }
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Build a PullRequest from a search-shaped node. Used by both search-list and mention-batch fetches.
    private static func makeSearchPullRequest(
        from node: GraphQLResponse.PRNode,
        category: PRCategory,
        excludeFilter: String,
        includeReviewAuthors: Bool = false
    ) -> PullRequest? {
        guard let databaseId = node.databaseId else { return nil }

        let conversationComments = node.comments?.nodes.map { comment in
            IssueCommentSummary(
                id: comment.id,
                author: comment.author?.login ?? "unknown",
                body: comment.body ?? "",
                createdAt: comment.createdAt,
                lastEditedAt: comment.lastEditedAt
            )
        } ?? []

        let reviewThreads = node.reviewThreads?.nodes.map { thread -> ReviewThread in
            let comments = thread.comments.nodes.map { comment -> ReviewComment in
                ReviewComment(
                    id: comment.id,
                    author: comment.author?.login ?? "unknown",
                    body: comment.body ?? "",
                    createdAt: comment.createdAt
                )
            }
            return ReviewThread(
                id: thread.id,
                isResolved: thread.isResolved,
                isOutdated: thread.isOutdated,
                path: thread.path,
                line: thread.line,
                comments: comments
            )
        } ?? []

        let lastCommit = node.commits?.nodes.first?.commit
        let statusCheckRollup = lastCommit?.statusCheckRollup
        let lastCommitAt = lastCommit?.committedDate

        let ciContexts = Self.contextNodes(from: statusCheckRollup?.contexts?.nodes ?? [])
        let ciResult = parseCIContexts(ciContexts, excludeFilter: excludeFilter)

        let rollupState = statusCheckRollup?.state
        // Note: this parses only the first page of contexts. Callers that keep the
        // search-parsed CI as final (mentioned PRs) must paginate via
        // enrichMentionedCIContexts; authored/review PRs are re-derived by the
        // detail batch instead.
        let derivedCI = Self.deriveSearchCI(
            from: ciResult,
            rollupState: rollupState,
            hasRollup: statusCheckRollup != nil
        )

        let reviewAgg = Self.aggregateReviews(
            node.latestReviews?.nodes ?? [],
            state: { $0.state },
            login: { $0.author?.login },
            collectAuthors: includeReviewAuthors
        )
        let approvalCount = reviewAgg.approvalCount
        let changesRequestedCount = reviewAgg.changesRequestedCount
        let approvalAuthors: [String]? = includeReviewAuthors ? reviewAgg.approvalAuthors : nil
        let changesRequestedAuthors: [String]? = includeReviewAuthors ? reviewAgg.changesRequestedAuthors : nil

        let hasBaseConflicts = deriveBaseConflicts(
            mergeable: node.mergeable,
            mergeStateStatus: node.mergeStateStatus
        )

        return PullRequest(
            id: databaseId,
            graphqlNodeId: node.id,
            number: node.number,
            title: node.title,
            author: node.author?.login ?? "unknown",
            authorAvatarURL: node.author?.avatarUrl,
            repositoryOwner: node.repository.owner.login,
            repositoryName: node.repository.name,
            repositoryIsArchived: node.repository.isArchived,
            url: node.url,
            state: PRState(rawValue: node.state) ?? .open,
            isDraft: node.isDraft,
            createdAt: node.createdAt,
            updatedAt: node.updatedAt,
            mergedAt: node.mergedAt,
            body: node.body,
            conversationComments: conversationComments,
            lastCommitAt: lastCommitAt,
            headCommitOid: lastCommit?.oid,
            baseRefName: node.baseRefName,
            headRefName: node.headRefName,
            baseNeedsUpdate: deriveBaseNeedsUpdate(mergeStateStatus: node.mergeStateStatus),
            approvalAuthors: approvalAuthors,
            changesRequestedAuthors: changesRequestedAuthors,
            reviewThreads: reviewThreads,
            category: category,
            hasBaseConflicts: hasBaseConflicts,
            ciStatus: derivedCI.status,
            checkSuccessCount: derivedCI.successCount,
            checkFailureCount: derivedCI.failureCount,
            checkPendingCount: derivedCI.pendingCount,
            githubCIState: rollupState,
            myLastReviewState: nil,
            myLastReviewAt: nil,
            reviewRequestedAt: nil,
            myThreadsAllResolved: false,
            approvalCount: approvalCount,
            changesRequestedCount: changesRequestedCount,
            ciExtendedInfo: derivedCI.extendedInfo
        )
    }

    /// Info needed to fetch additional review threads for a PR
    private struct ReviewThreadEnrichmentInfo {
        let prId: Int
        let owner: String
        let repo: String
        let number: Int
        let startCursor: String
    }

    /// Info needed to fetch additional CI contexts for a PR
    private struct CIEnrichmentInfo {
        let prId: Int
        let owner: String
        let repo: String
        let commitOid: String
        let endCursor: String
        let rollupState: String
        let initialContextCount: Int  // Number of contexts already fetched in first page
    }


    private func fetchDetailBatch(
        _ batch: [IndexedPR],
        categoryByID: [Int: PRCategory],
        username: String,
        fieldSelection: String,
        excludeFilter: String
    ) async throws -> [Int: PullRequest] {
        var queryParts: [String] = []
        for (index, ip) in batch.enumerated() {
            queryParts.append(
                """
                pr_\(index): repository(owner: "\(ip.repositoryOwner)", name: "\(ip.repositoryName)") {
                    pullRequest(number: \(ip.number)) {
                        \(fieldSelection)
                    }
                }
                """
            )
        }
        queryParts.append("rateLimit { cost remaining resetAt }")
        let query = "query {\n" + queryParts.joined(separator: "\n") + "\n}"
        let responseData = try await executeGraphQL(query: query, operation: "fetchPRDetailBatch")

        let decoder = JSONDecoder.githubDecoder
        let response: DetailBatchResponse
        do {
            response = try decoder.decode(DetailBatchResponse.self, from: responseData)
        } catch {
            throw APIError.decoding(error)
        }

        if let rl = response.data.rateLimit {
            logger.info("Detail batch cost=\(rl.cost, privacy: .public) remaining=\(rl.remaining, privacy: .public) size=\(batch.count, privacy: .public)")
        } else if let decodeError = response.data.rateLimitDecodeError {
            logger.warning("Detail batch rateLimit field failed to decode: \(decodeError, privacy: .public)")
        } else {
            logger.warning("Detail batch response missing rateLimit field (size=\(batch.count, privacy: .public))")
        }

        var ciEnrichment: [CIEnrichmentInfo] = []
        var reviewThreadEnrichment: [ReviewThreadEnrichmentInfo] = []
        var parsed: [Int: PullRequest] = [:]

        for node in response.data.nodes {
            guard let dbId = node.databaseId,
                  let resolvedCategory = categoryByID[dbId] else { continue }
            if let pr = makeFullPullRequest(
                from: node,
                category: resolvedCategory,
                username: username,
                excludeFilter: excludeFilter,
                enrichmentInfos: &ciEnrichment,
                reviewThreadEnrichmentInfos: &reviewThreadEnrichment
            ) {
                parsed[dbId] = pr
            }
        }

        if !ciEnrichment.isEmpty {
            let enriched = await fetchAllAdditionalCIContexts(enrichmentInfos: ciEnrichment)
            Self.applyCIEnrichments(to: &parsed, counts: enriched)
        }
        if !reviewThreadEnrichment.isEmpty {
            let additional = await fetchAllAdditionalReviewThreads(enrichmentInfos: reviewThreadEnrichment)
            for (id, threads) in additional {
                guard var pr = parsed[id] else { continue }
                let freshIds = Set(pr.reviewThreads.map { $0.id })
                var merged: [ReviewThread] = []
                merged.reserveCapacity(threads.count + pr.reviewThreads.count)
                for thread in threads where !freshIds.contains(thread.id) {
                    merged.append(thread)
                }
                merged.append(contentsOf: pr.reviewThreads)
                pr.reviewThreads = merged
                parsed[id] = pr
            }
        }

        await applyWorkflowRunCompletionGuards(to: &parsed)
        return parsed
    }

    /// Apply paginated CI-context counts back into the parsed PR map. Shared between
    /// combined-response enrichment (via a temporary dict) and detail-batch enrichment.
    private static func applyCIEnrichments(to prs: inout [Int: PullRequest], counts: [Int: CICounts]) {
        for (id, c) in counts {
            guard var pr = prs[id] else { continue }
            pr.checkSuccessCount += c.success
            pr.checkFailureCount += c.failure
            pr.checkPendingCount += c.pending
            let hasBlockingFailure = pr.ciStatus == .failure || c.blockingFailure > 0
            if hasBlockingFailure {
                pr.ciStatus = .failure
            } else if pr.checkPendingCount > 0 {
                pr.ciStatus = .pending
            } else if pr.checkSuccessCount > 0 || pr.checkFailureCount > 0 {
                pr.ciStatus = .success
            } else if c.limitReached && pr.githubCIState?.uppercased() == "FAILURE" {
                pr.ciStatus = .unknown
            }
            if !c.workflows.isEmpty {
                var merged = pr.ciExtendedInfo?.workflows.reduce(into: [String: CIWorkflowInfo]()) {
                    $0[$1.name] = $1
                } ?? [:]
                for (key, wf) in c.workflows {
                    if var existing = merged[key] {
                        existing.successCount += wf.successCount
                        existing.failureCount += wf.failureCount
                        existing.pendingCount += wf.pendingCount
                        merged[key] = existing
                    } else {
                        merged[key] = wf
                    }
                }
                let isRunning = (pr.ciExtendedInfo?.isRunning ?? false) || c.isRunning
                pr.ciExtendedInfo = CIExtendedInfo(isRunning: isRunning, workflows: Array(merged.values))
            }
            prs[id] = pr
        }
    }

    private func applyWorkflowRunCompletionGuards(to prs: inout [Int: PullRequest]) async {
        let excludeFilter = Self.loadCIStatusExcludeFilter()
        for id in prs.keys.sorted() {
            guard let pr = prs[id] else { continue }
            prs[id] = await applyWorkflowRunCompletionGuard(to: pr, excludeFilter: excludeFilter)
        }
    }

    private func applyWorkflowRunCompletionGuards(to prs: inout [PullRequest]) async {
        let excludeFilter = Self.loadCIStatusExcludeFilter()
        for index in prs.indices {
            prs[index] = await applyWorkflowRunCompletionGuard(to: prs[index], excludeFilter: excludeFilter)
        }
    }

    private func applyWorkflowRunCompletionGuard(to pr: PullRequest, excludeFilter: String) async -> PullRequest {
        let shouldCheckFailureForExclude = pr.ciStatus == .failure
            && !excludeFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard (pr.ciStatus == .success || shouldCheckFailureForExclude),
              let headSHA = pr.headCommitOid,
              !headSHA.isEmpty else {
            return pr
        }

        do {
            let summary = try await fetchWorkflowRunCompletionSummary(
                owner: pr.repositoryOwner,
                repo: pr.repositoryName,
                headSHA: headSHA,
                excludeFilter: excludeFilter
            )
            guard summary.totalCount > 0 else { return pr }

            var adjusted = pr
            let snapshot = Self.CIStatusSnapshot(
                status: adjusted.ciStatus,
                successCount: adjusted.checkSuccessCount,
                failureCount: adjusted.checkFailureCount,
                pendingCount: adjusted.checkPendingCount,
                extendedInfo: adjusted.ciExtendedInfo
            )
            let updated = Self.applyingWorkflowRunSummary(to: snapshot, summary: summary)
            adjusted.ciStatus = updated.status
            adjusted.checkSuccessCount = updated.successCount
            adjusted.checkFailureCount = updated.failureCount
            adjusted.checkPendingCount = updated.pendingCount
            adjusted.ciExtendedInfo = updated.extendedInfo

            if adjusted.ciStatus != pr.ciStatus || adjusted.ciIsRunning != pr.ciIsRunning {
                logger.info(
                    "Adjusted workflow-run CI state for \(pr.repoFullName)#\(pr.number, privacy: .public): total=\(summary.totalCount, privacy: .public) completed=\(summary.completedCount, privacy: .public) inFlight=\(summary.inFlightCount, privacy: .public) failureLike=\(summary.failureLikeCount, privacy: .public) blockingFailureLike=\(summary.blockingFailureLikeCount, privacy: .public)"
                )
            }
            return adjusted
        } catch {
            logger.warning(
                "Failed to fetch workflow-run completion guard for \(pr.repoFullName)#\(pr.number, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return pr
        }
    }

    /// Refresh CI for an already-discovered set of mentioned PRs without re-running
    /// the expensive cross-reference *discovery* (scanning which authored PRs are
    /// referenced) — that pass stays throttled (30 min in PRManager). A backport's
    /// CI changes far more often than the discovery cadence, so the regular poll
    /// calls this to keep mentioned-PR CI fresh instead of letting it freeze on a
    /// stale snapshot (e.g. stuck "running" after checks have finished). Only CI
    /// fields and the head-commit pointers are copied onto the existing objects, so
    /// Jira / cmux / review enrichment already on each PR is preserved; PRs that
    /// fail to refetch keep their previous CI rather than disappearing, and ones no
    /// longer open drop off.
    func refreshMentionedCIStatuses(_ existing: [PullRequest]) async -> [PullRequest] {
        guard !existing.isEmpty else { return existing }

        let references = existing.map {
            PullRequestReference(owner: $0.repositoryOwner, repo: $0.repositoryName, number: $0.number)
        }
        let fieldSelection = buildPRFieldSelection(
            includeReviewMetadata: false,
            includeMentionBodies: false
        )

        var refreshedByID: [Int: PullRequest] = [:]
        for batch in references.chunked(into: Self.batchedPRQuerySize) {
            do {
                for pr in try await fetchMentionedBatch(batch, fieldSelection: fieldSelection) {
                    refreshedByID[pr.id] = pr
                }
            } catch {
                logger.warning("Failed to refresh mentioned CI batch: \(error.localizedDescription, privacy: .public)")
            }
        }

        return Self.mergeMentionedRefreshResults(existing: existing, refreshedByID: refreshedByID)
    }

    static func mergeMentionedRefreshResults(
        existing: [PullRequest],
        refreshedByID: [Int: PullRequest]
    ) -> [PullRequest] {
        var result: [PullRequest] = []
        for old in existing {
            guard let fresh = refreshedByID[old.id] else {
                result.append(old)  // keep the prior (stale) snapshot on a refetch miss
                continue
            }
            guard fresh.state == .open else { continue }  // merged/closed backport drops off
            var updated = old
            updated.ciStatus = fresh.ciStatus
            updated.checkSuccessCount = fresh.checkSuccessCount
            updated.checkFailureCount = fresh.checkFailureCount
            updated.checkPendingCount = fresh.checkPendingCount
            updated.githubCIState = fresh.githubCIState
            updated.ciExtendedInfo = fresh.ciExtendedInfo
            updated.lastCommitAt = fresh.lastCommitAt
            updated.headCommitOid = fresh.headCommitOid
            updated.repositoryIsArchived = fresh.repositoryIsArchived
            result.append(updated)
        }
        var seen = Set<Int>()
        return result
            .filter { $0.state == .open && seen.insert($0.id).inserted }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func fetchMentionedBatch(
        _ batch: [PullRequestReference],
        fieldSelection: String,
        operation: String = "fetchMentionedPullRequests"
    ) async throws -> [PullRequest] {
        var queryParts: [String] = []
        for (index, reference) in batch.enumerated() {
            queryParts.append(
                """
                pr_\(index): repository(owner: \(Self.graphQLStringLiteral(reference.owner)), name: \(Self.graphQLStringLiteral(reference.repo))) {
                    pullRequest(number: \(reference.number)) {
                        \(fieldSelection)
                    }
                }
                """
            )
        }

        let query = """
        query {
            \(queryParts.joined(separator: "\n"))
            rateLimit {
                cost
                remaining
                resetAt
            }
        }
        """
        let responseData = try await executeGraphQL(query: query, operation: operation)
        if let rateLimit = Self.graphQLRateLimit(in: responseData) {
            await recordGraphQLRateLimit(rateLimit)
        }

        let decoder = JSONDecoder.githubDecoder
        let response: MentionedBatchResponse
        do {
            response = try decoder.decode(MentionedBatchResponse.self, from: responseData)
        } catch {
            throw APIError.decoding(error)
        }
        let erroredAliases = Self.graphQLErrorAliases(in: responseData)
        if Self.hasGraphQLErrors(in: responseData) && erroredAliases.isEmpty {
            throw APIError.unknown("GitHub returned partial errors for \(operation)")
        }
        let nodes = response.data.nodesByAlias.compactMap { alias, node in
            erroredAliases.contains(alias) ? nil : node
        }
        let excludeFilter = Self.loadCIStatusExcludeFilter()
        var prs = nodes.compactMap {
            Self.makeSearchPullRequest(from: $0, category: .mentioned, excludeFilter: excludeFilter)
        }
        await enrichMentionedCIContexts(&prs, from: nodes, excludeFilter: excludeFilter)
        await applyWorkflowRunCompletionGuards(to: &prs)
        return prs
    }

    /// Mentioned PRs are parsed from a single 20-context search page and — unlike
    /// the authored/review detail batch — never paginate, so a PR with many checks
    /// (e.g. a kong-ee backport with 90+ contexts) can miss failures that sit past
    /// the first page and get stuck showing success/pending. When the rollup reports
    /// more pages, fetch the remainder and re-derive CI from the full set, mirroring
    /// the detail/hover path. Pagination only fires for FAILURE/PENDING/SUCCESS
    /// rollups with a next page, so small-CI PRs pay nothing extra.
    private func enrichMentionedCIContexts(
        _ prs: inout [PullRequest],
        from nodes: [GraphQLResponse.PRNode],
        excludeFilter: String
    ) async {
        guard !prs.isEmpty else { return }

        var indexByID: [Int: Int] = [:]
        for (index, pr) in prs.enumerated() { indexByID[pr.id] = index }

        for node in nodes {
            guard let databaseId = node.databaseId, let prIndex = indexByID[databaseId] else { continue }
            let commit = node.commits?.nodes.first?.commit
            guard let statusCheckRollup = commit?.statusCheckRollup,
                  let pageInfo = statusCheckRollup.contexts?.pageInfo,
                  Self.shouldFetchRemainingCIContexts(
                      rollupState: statusCheckRollup.state.uppercased(),
                      hasNextPage: pageInfo.hasNextPage
                  ),
                  let endCursor = pageInfo.endCursor,
                  let commitOid = commit?.oid, !commitOid.isEmpty else { continue }

            // Snapshot identity into locals: os.Logger interpolation is an escaping
            // autoclosure and can't capture the `inout prs` parameter.
            var pr = prs[prIndex]
            let repoFullName = pr.repoFullName
            let prNumber = pr.number
            let firstPage = Self.contextNodes(from: statusCheckRollup.contexts?.nodes ?? [])
            let seed = Self.parseCIContexts(firstPage, excludeFilter: excludeFilter)
            do {
                let (full, _) = try await fetchFullCIContexts(
                    owner: pr.repositoryOwner,
                    repo: pr.repositoryName,
                    commitOid: commitOid,
                    startCursor: endCursor,
                    initialCount: firstPage.count,
                    seed: seed
                )
                let derived = Self.deriveSearchCI(
                    from: full,
                    rollupState: statusCheckRollup.state,
                    hasRollup: true
                )
                let before = pr.ciStatus
                pr.ciStatus = derived.status
                pr.checkSuccessCount = derived.successCount
                pr.checkFailureCount = derived.failureCount
                pr.checkPendingCount = derived.pendingCount
                pr.ciExtendedInfo = derived.extendedInfo
                prs[prIndex] = pr
                if before != derived.status {
                    logger.info(
                        "Paginated mentioned CI contexts for \(repoFullName)#\(prNumber, privacy: .public): \(String(describing: before), privacy: .public) -> \(String(describing: derived.status), privacy: .public) (success=\(derived.successCount, privacy: .public) failure=\(derived.failureCount, privacy: .public) pending=\(derived.pendingCount, privacy: .public))"
                    )
                }
            } catch {
                logger.warning(
                    "Failed to paginate mentioned CI contexts for \(repoFullName)#\(prNumber, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private struct CICounts {
        var success: Int
        var failure: Int
        var blockingFailure: Int
        var pending: Int
        var limitReached: Bool
        var isRunning: Bool
        var workflows: [String: CIWorkflowInfo]
    }

    // MARK: - Review Thread Enrichment

    struct ReviewThreadsResult {
        let threads: [ReviewThread]
        let hasPreviousPage: Bool
        let startCursor: String?
    }

    /// Fetches additional review threads for a PR when pagination is needed
    func fetchAdditionalReviewThreads(owner: String, repo: String, number: Int, before: String) async throws -> ReviewThreadsResult {
        let query = """
        query {
            repository(owner: "\(owner)", name: "\(repo)") {
                pullRequest(number: \(number)) {
                    reviewThreads(last: 20, before: "\(before)") {
                        nodes {
                            id
                            isResolved
                            isOutdated
                            path
                            line
                            comments(first: 5) {
                                nodes {
                                    id
                                    author {
                                        login
                                    }
                                    body
                                    createdAt
                                }
                            }
                        }
                        pageInfo {
                            hasPreviousPage
                            startCursor
                        }
                    }
                }
            }
        }
        """

        let responseData = try await executeGraphQL(query: query, operation: "fetchAdditionalReviewThreads")
        return try parseReviewThreadsResponse(data: responseData)
    }

    private func parseReviewThreadsResponse(data: Data) throws -> ReviewThreadsResult {
        struct Response: Decodable {
            let data: DataContainer
            struct DataContainer: Decodable {
                let repository: RepositoryContainer?
            }
            struct RepositoryContainer: Decodable {
                let pullRequest: PullRequestContainer?
            }
            struct PullRequestContainer: Decodable {
                let reviewThreads: ReviewThreadsContainer?
            }
            struct ReviewThreadsContainer: Decodable {
                let nodes: [ReviewThreadNode]
                let pageInfo: PageInfo?
            }
            struct PageInfo: Decodable {
                let hasPreviousPage: Bool
                let startCursor: String?
            }
            struct ReviewThreadNode: Decodable {
                let id: String
                let isResolved: Bool
                let isOutdated: Bool
                let path: String?
                let line: Int?
                let comments: CommentsContainer
            }
            struct CommentsContainer: Decodable {
                let nodes: [CommentNode]
            }
            struct CommentNode: Decodable {
                let id: String
                let author: Author?
                let body: String
                let createdAt: Date
            }
            struct Author: Decodable {
                let login: String
            }
        }

        let decoder = JSONDecoder.githubDecoder
        let response = try decoder.decode(Response.self, from: data)

        guard let reviewThreads = response.data.repository?.pullRequest?.reviewThreads else {
            return ReviewThreadsResult(threads: [], hasPreviousPage: false, startCursor: nil)
        }

        let threads = reviewThreads.nodes.map { node in
            let comments = node.comments.nodes.map { comment in
                ReviewComment(
                    id: comment.id,
                    author: comment.author?.login ?? "unknown",
                    body: comment.body,
                    createdAt: comment.createdAt
                )
            }
            return ReviewThread(
                id: node.id,
                isResolved: node.isResolved,
                isOutdated: node.isOutdated,
                path: node.path,
                line: node.line,
                comments: comments
            )
        }

        return ReviewThreadsResult(
            threads: threads,
            hasPreviousPage: reviewThreads.pageInfo?.hasPreviousPage ?? false,
            startCursor: reviewThreads.pageInfo?.startCursor
        )
    }

    /// Fetches all additional review threads for PRs that need enrichment
    private func fetchAllAdditionalReviewThreads(enrichmentInfos: [ReviewThreadEnrichmentInfo]) async -> [Int: [ReviewThread]] {
        var results: [Int: [ReviewThread]] = [:]

        for info in enrichmentInfos {
            do {
                var allThreads: [ReviewThread] = []
                var cursor: String? = info.startCursor

                while let currentCursor = cursor {
                    let result = try await fetchAdditionalReviewThreads(
                        owner: info.owner,
                        repo: info.repo,
                        number: info.number,
                        before: currentCursor
                    )
                    allThreads.append(contentsOf: result.threads)
                    cursor = result.hasPreviousPage ? result.startCursor : nil
                }

                if !allThreads.isEmpty {
                    results[info.prId] = allThreads
                    logger.info("Enriched review threads for PR \(info.prId) (#\(info.number)): fetched \(allThreads.count) additional threads")
                }
            } catch {
                logger.error("Failed to fetch additional review threads for PR \(info.prId) (#\(info.number)): \(error.localizedDescription)")
            }
        }

        return results
    }

    /// Fetches additional CI contexts for all PRs that need enrichment
    private func fetchAllAdditionalCIContexts(enrichmentInfos: [CIEnrichmentInfo]) async -> [Int: CICounts] {
        var results: [Int: CICounts] = [:]

        for info in enrichmentInfos {
            do {
                let (parseResult, limitReached) = try await fetchFullCIContexts(
                    owner: info.owner,
                    repo: info.repo,
                    commitOid: info.commitOid,
                    startCursor: info.endCursor,
                    initialCount: info.initialContextCount
                )
                let counts = CICounts(
                    success: parseResult.successCount,
                    failure: parseResult.failureCount,
                    blockingFailure: parseResult.blockingFailureCount,
                    pending: parseResult.pendingCount,
                    limitReached: limitReached,
                    isRunning: parseResult.isRunning,
                    workflows: parseResult.workflows
                )
                results[info.prId] = counts
                logger.info("Enriched CI for PR \(info.prId): \(counts.success) success, \(counts.failure) failure, \(counts.pending) pending, limitReached=\(counts.limitReached)")
            } catch {
                logger.error("Failed to fetch additional CI contexts for PR \(info.prId): \(error.localizedDescription)")
            }
        }

        return results
    }

    /// Fetches all remaining CI contexts for a commit, paginating as needed.
    /// The caller passes its first-page `CIParseResult` as `seed` so cross-page
    /// dedup (via `seenCheckNames`) is preserved. Returns the combined parse
    /// result plus whether the per-commit fetch limit was reached.
    private func fetchFullCIContexts(
        owner: String,
        repo: String,
        commitOid: String,
        startCursor: String,
        initialCount: Int,
        seed: CIParseResult = CIParseResult()
    ) async throws -> (parseResult: CIParseResult, limitReached: Bool) {
        var parseResult = seed
        var cursor: String? = startCursor
        let excludeFilter = Self.loadCIStatusExcludeFilter()
        var totalFetched = initialCount
        var limitReached = false

        while let currentCursor = cursor {
            let result = try await fetchAdditionalCIContexts(owner: owner, repo: repo, commitOid: commitOid, after: currentCursor)
            totalFetched += result.contexts.count

            parseResult = Self.parseCIContexts(result.contexts, excludeFilter: excludeFilter, existing: parseResult)

            if totalFetched >= Self.maxCIContextsToFetch {
                if result.hasNextPage {
                    logger.warning("Reached CI context limit (\(Self.maxCIContextsToFetch)) for \(owner)/\(repo)@\(commitOid), more pages available")
                    limitReached = true
                }
                break
            }

            cursor = result.hasNextPage ? result.endCursor : nil
        }

        return (parseResult, limitReached)
    }

    private func parseNodes(
        _ nodes: [CombinedGraphQLResponse.PRNode],
        category: PRCategory,
        usernameForAuthoredCheck: String? = nil,
        enrichmentInfos: inout [CIEnrichmentInfo],
        reviewThreadEnrichmentInfos: inout [ReviewThreadEnrichmentInfo]
    ) -> [PullRequest] {
        let excludeFilter = Self.loadCIStatusExcludeFilter()
        let usernameLower = usernameForAuthoredCheck?.lowercased()
        return nodes.compactMap { node in
            let resolved: PRCategory
            if let usernameLower, node.author?.login.lowercased() == usernameLower {
                resolved = .authored
            } else {
                resolved = category
            }
            return makeFullPullRequest(
                from: node,
                category: resolved,
                username: usernameForAuthoredCheck,
                excludeFilter: excludeFilter,
                enrichmentInfos: &enrichmentInfos,
                reviewThreadEnrichmentInfos: &reviewThreadEnrichmentInfos
            )
        }
    }

    /// Shared single-node parser for combined search results and detail-batch results.
    /// Callers supply the already-resolved `category`; username is used only for
    /// review-metadata and `myThreadsAllResolved` derivation.
    private func makeFullPullRequest(
        from node: CombinedGraphQLResponse.PRNode,
        category: PRCategory,
        username: String?,
        excludeFilter: String,
        enrichmentInfos: inout [CIEnrichmentInfo],
        reviewThreadEnrichmentInfos: inout [ReviewThreadEnrichmentInfo],
        includeReviewAuthors: Bool = false
    ) -> PullRequest? {
        guard let databaseId = node.databaseId else { return nil }
        let usernameLower = username?.lowercased()

        let conversationComments = node.comments?.nodes.map { comment in
            IssueCommentSummary(
                id: comment.id,
                author: comment.author?.login ?? "unknown",
                body: comment.body ?? "",
                createdAt: comment.createdAt,
                lastEditedAt: comment.lastEditedAt
            )
        } ?? []

        let reviewThreads = node.reviewThreads?.nodes.map { thread -> ReviewThread in
            let comments = thread.comments.nodes.map { comment -> ReviewComment in
                ReviewComment(
                    id: comment.id,
                    author: comment.author?.login ?? "unknown",
                    body: comment.body ?? "",
                    createdAt: comment.createdAt
                )
            }
            return ReviewThread(
                id: thread.id,
                isResolved: thread.isResolved,
                isOutdated: thread.isOutdated,
                path: thread.path,
                line: thread.line,
                comments: comments
            )
        } ?? []

        if let pageInfo = node.reviewThreads?.pageInfo,
           pageInfo.hasPreviousPage,
           let startCursor = pageInfo.startCursor {
            reviewThreadEnrichmentInfos.append(ReviewThreadEnrichmentInfo(
                prId: databaseId,
                owner: node.repository.owner.login,
                repo: node.repository.name,
                number: node.number,
                startCursor: startCursor
            ))
        }

        let lastCommit = node.commits?.nodes.first?.commit
        let statusCheckRollup = lastCommit?.statusCheckRollup
        let lastCommitAt = lastCommit?.committedDate

        let ciContexts = (statusCheckRollup?.contexts?.nodes ?? []).map { ctx in
            CIContextNode(
                name: ctx.name,
                conclusion: ctx.conclusion,
                state: ctx.state,
                context: ctx.context,
                workflowName: ctx.checkSuite?.workflowRun?.workflow?.name,
                completedAt: ctx.completedAt
            )
        }
        let ciResult = Self.parseCIContexts(ciContexts, excludeFilter: excludeFilter)

        let rollupState = statusCheckRollup?.state ?? ""
        let upperRollup = rollupState.uppercased()
        let initialContextCount = statusCheckRollup?.contexts?.nodes.count ?? 0
        if let pageInfo = statusCheckRollup?.contexts?.pageInfo,
           Self.shouldFetchRemainingCIContexts(rollupState: upperRollup, hasNextPage: pageInfo.hasNextPage),
           let endCursor = pageInfo.endCursor,
           let commitOid = lastCommit?.oid {
            enrichmentInfos.append(CIEnrichmentInfo(
                prId: databaseId,
                owner: node.repository.owner.login,
                repo: node.repository.name,
                commitOid: commitOid,
                endCursor: endCursor,
                rollupState: rollupState,
                initialContextCount: initialContextCount
            ))
        }

        var ciStatus: CIStatus? = Self.deriveCIStatus(from: ciResult)
            ?? (statusCheckRollup != nil ? .expected : nil)

        var effectivePendingCount = ciResult.pendingCount
        var effectiveIsRunning = ciResult.isRunning
        if ciStatus == .success, upperRollup == "PENDING" {
            ciStatus = .pending
            effectivePendingCount = max(effectivePendingCount, 1)
            effectiveIsRunning = true
        }

        let ciExtendedInfo: CIExtendedInfo? = ciResult.workflows.isEmpty ? nil : CIExtendedInfo(
            isRunning: effectiveIsRunning,
            workflows: Array(ciResult.workflows.values)
        )

        let hasBaseConflicts = Self.deriveBaseConflicts(
            mergeable: node.mergeable,
            mergeStateStatus: node.mergeStateStatus
        )

        let lastReview = node.reviews?.nodes.first
        let myLastReviewState: ReviewState? = lastReview.flatMap { ReviewState(rawValue: $0.state) }
        let myLastReviewAt: Date? = lastReview?.submittedAt

        let reviewRequestedAt: Date? = node.reviewRequestEvents?.nodes
            .filter { $0.requestedReviewer?.login?.lowercased() == usernameLower }
            .compactMap { $0.createdAt }
            .max()

        let reviewAgg = Self.aggregateReviews(
            node.latestReviews?.nodes ?? [],
            state: { $0.state },
            login: { $0.author?.login },
            collectAuthors: includeReviewAuthors
        )
        let approvalCount = reviewAgg.approvalCount
        let changesRequestedCount = reviewAgg.changesRequestedCount
        let approvalAuthors: [String]? = includeReviewAuthors ? reviewAgg.approvalAuthors : nil
        let changesRequestedAuthors: [String]? = includeReviewAuthors ? reviewAgg.changesRequestedAuthors : nil

        let myThreadsAllResolved: Bool = {
            guard let usernameLower else { return false }
            let myThreads = reviewThreads.filter { thread in
                thread.comments.first?.author.lowercased() == usernameLower
            }
            return !myThreads.isEmpty && myThreads.allSatisfy { $0.isResolved }
        }()

        return PullRequest(
            id: databaseId,
            graphqlNodeId: node.id,
            number: node.number,
            title: node.title,
            author: node.author?.login ?? "unknown",
            authorAvatarURL: node.author?.avatarUrl,
            repositoryOwner: node.repository.owner.login,
            repositoryName: node.repository.name,
            repositoryIsArchived: node.repository.isArchived,
            url: node.url,
            state: PRState(rawValue: node.state) ?? .open,
            isDraft: node.isDraft,
            createdAt: node.createdAt,
            updatedAt: node.updatedAt,
            mergedAt: node.mergedAt,
            body: node.body,
            conversationComments: conversationComments,
            lastCommitAt: lastCommitAt,
            headCommitOid: lastCommit?.oid,
            baseRefName: node.baseRefName,
            headRefName: node.headRefName,
            baseNeedsUpdate: Self.deriveBaseNeedsUpdate(mergeStateStatus: node.mergeStateStatus),
            approvalAuthors: approvalAuthors,
            changesRequestedAuthors: changesRequestedAuthors,
            reviewThreads: reviewThreads,
            category: category,
            hasBaseConflicts: hasBaseConflicts,
            ciStatus: ciStatus,
            checkSuccessCount: ciResult.successCount,
            checkFailureCount: ciResult.failureCount,
            checkPendingCount: effectivePendingCount,
            githubCIState: rollupState.isEmpty ? nil : rollupState,
            myLastReviewState: myLastReviewState,
            myLastReviewAt: myLastReviewAt,
            reviewRequestedAt: reviewRequestedAt,
            myThreadsAllResolved: myThreadsAllResolved,
            approvalCount: approvalCount,
            changesRequestedCount: changesRequestedCount,
            ciExtendedInfo: ciExtendedInfo
        )
    }

    // MARK: - Single PR CI Status

    struct SinglePRCIResult {
        let ciStatus: CIStatus?
        let checkSuccessCount: Int
        let checkFailureCount: Int
        let checkPendingCount: Int
        let ciExtendedInfo: CIExtendedInfo?
        let headSHA: String?
    }

    func fetchSinglePRCIStatus(owner: String, repo: String, number: Int) async throws -> SinglePRCIResult {
        let query = """
        query {
            repository(owner: "\(owner)", name: "\(repo)") {
                pullRequest(number: \(number)) {
                    commits(last: 1) {
                        nodes {
                            commit {
                                oid
                                statusCheckRollup {
                                    state
                                    contexts(first: 100) {
                                        nodes {
                                            ... on CheckRun {
                                                name
                                                conclusion
                                                completedAt
                                                checkSuite {
                                                    workflowRun {
                                                        workflow {
                                                            name
                                                        }
                                                    }
                                                }
                                            }
                                            ... on StatusContext {
                                                context
                                                state
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """

        let responseData = try await executeGraphQL(query: query, operation: "fetchSinglePRCIStatus")
        var result = try parseSinglePRCIResponse(data: responseData)
        let excludeFilter = Self.loadCIStatusExcludeFilter()
        let shouldFetchWorkflowRunGuard = result.ciStatus == .success || (
            result.ciStatus == .failure && !excludeFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        if shouldFetchWorkflowRunGuard, let headSHA = result.headSHA, !headSHA.isEmpty {
            do {
                let summary = try await fetchWorkflowRunCompletionSummary(
                    owner: owner,
                    repo: repo,
                    headSHA: headSHA,
                    excludeFilter: excludeFilter
                )
                result = Self.applyingWorkflowRunSummary(to: result, summary: summary)
            } catch {
                logger.warning("Failed to fetch single-PR workflow-run completion guard for \(owner)/\(repo)#\(number, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    private func parseSinglePRCIResponse(data: Data) throws -> SinglePRCIResult {
        struct Response: Decodable {
            let data: DataContainer
            struct DataContainer: Decodable {
                let repository: RepositoryContainer?
            }
            struct RepositoryContainer: Decodable {
                let pullRequest: PRContainer?
            }
            struct PRContainer: Decodable {
                let commits: CommitsContainer?
            }
            struct CommitsContainer: Decodable {
                let nodes: [CommitNode]
            }
            struct CommitNode: Decodable {
                let commit: CommitInfo
            }
            struct CommitInfo: Decodable {
                let oid: String?
                let statusCheckRollup: StatusCheckRollup?
            }
            struct StatusCheckRollup: Decodable {
                let state: String
                let contexts: ContextsContainer?
            }
            struct ContextsContainer: Decodable {
                let nodes: [ContextNode]
            }
            struct ContextNode: Decodable {
                let name: String?
                let conclusion: String?
                let completedAt: Date?
                let state: String?
                let context: String?
                let checkSuite: CheckSuiteNode?
            }
            struct CheckSuiteNode: Decodable {
                let workflowRun: WorkflowRunNode?
            }
            struct WorkflowRunNode: Decodable {
                let workflow: WorkflowNode?
            }
            struct WorkflowNode: Decodable {
                let name: String?
            }
        }

        let decoder = JSONDecoder.githubDecoder
        let response = try decoder.decode(Response.self, from: data)

        guard let rollup = response.data.repository?.pullRequest?.commits?.nodes.first?.commit.statusCheckRollup else {
            return SinglePRCIResult(ciStatus: nil, checkSuccessCount: 0, checkFailureCount: 0, checkPendingCount: 0, ciExtendedInfo: nil, headSHA: nil)
        }
        let headSHA = response.data.repository?.pullRequest?.commits?.nodes.first?.commit.oid

        let ciContexts = (rollup.contexts?.nodes ?? []).map { node in
            CIContextNode(
                name: node.name,
                conclusion: node.conclusion,
                state: node.state,
                context: node.context,
                workflowName: node.checkSuite?.workflowRun?.workflow?.name,
                completedAt: node.completedAt
            )
        }

        let excludeFilter = Self.loadCIStatusExcludeFilter()
        let ciResult = Self.parseCIContexts(ciContexts, excludeFilter: excludeFilter)

        var ciStatus: CIStatus? = Self.deriveCIStatus(from: ciResult) ?? .expected

        // Trust GitHub's rollup state when it says PENDING but we derived success.
        // This handles QUEUED checks not yet visible in individual contexts.
        var effectivePendingCount = ciResult.pendingCount
        var effectiveIsRunning = ciResult.isRunning
        if ciStatus == .success, rollup.state.uppercased() == "PENDING" {
            ciStatus = .pending
            effectivePendingCount = max(effectivePendingCount, 1)
            effectiveIsRunning = true
        }

        let ciExtendedInfo: CIExtendedInfo? = ciResult.workflows.isEmpty ? nil : CIExtendedInfo(
            isRunning: effectiveIsRunning,
            workflows: Array(ciResult.workflows.values)
        )

        return SinglePRCIResult(
            ciStatus: ciStatus,
            checkSuccessCount: ciResult.successCount,
            checkFailureCount: ciResult.failureCount,
            checkPendingCount: effectivePendingCount,
            ciExtendedInfo: ciExtendedInfo,
            headSHA: headSHA
        )
    }

    private static func applyingWorkflowRunSummary(
        to result: SinglePRCIResult,
        summary: WorkflowRunCompletionSummary
    ) -> SinglePRCIResult {
        let snapshot = CIStatusSnapshot(
            status: result.ciStatus,
            successCount: result.checkSuccessCount,
            failureCount: result.checkFailureCount,
            pendingCount: result.checkPendingCount,
            extendedInfo: result.ciExtendedInfo
        )
        let adjusted = applyingWorkflowRunSummary(to: snapshot, summary: summary)
        return SinglePRCIResult(
            ciStatus: adjusted.status,
            checkSuccessCount: adjusted.successCount,
            checkFailureCount: adjusted.failureCount,
            checkPendingCount: adjusted.pendingCount,
            ciExtendedInfo: adjusted.extendedInfo,
            headSHA: result.headSHA
        )
    }

    // MARK: - Rerun Failed CI

    /// Re-run all failed workflow runs for a PR's head commit.
    /// Returns the number of workflow runs that were re-triggered.
    func rerunFailedWorkflows(owner: String, repo: String, headSHA: String) async throws -> Int {
        // 1. Fetch workflow runs for this commit
        let runsURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/runs?head_sha=\(headSHA)")!
        var runsRequest = URLRequest(url: runsURL)
        runsRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        runsRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (runsData, runsResponse): (Data, URLResponse)
        do {
            (runsData, runsResponse) = try await session.data(for: runsRequest)
        } catch {
            throw APIError.network(error)
        }

        guard let httpResponse = runsResponse as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.unknown(String(localized: "Failed to fetch workflow runs: HTTP \(httpResponse.statusCode)"))
        }

        // 2. Parse and filter for failed runs
        guard let json = try? JSONSerialization.jsonObject(with: runsData) as? [String: Any],
              let workflowRuns = json["workflow_runs"] as? [[String: Any]] else {
            throw APIError.invalidResponse
        }

        let failedRuns = workflowRuns.filter { run in
            (run["conclusion"] as? String) == "failure"
        }

        if failedRuns.isEmpty {
            logger.info("No failed workflow runs found for SHA \(headSHA)")
            return 0
        }

        // 3. Rerun failed jobs for each failed workflow run
        var rerunCount = 0
        for run in failedRuns {
            guard let runId = run["id"] as? Int else { continue }

            let rerunURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/runs/\(runId)/rerun-failed-jobs")!
            var rerunRequest = URLRequest(url: rerunURL)
            rerunRequest.httpMethod = "POST"
            rerunRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            rerunRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            do {
                let (_, rerunResponse) = try await session.data(for: rerunRequest)
                if let rerunHttp = rerunResponse as? HTTPURLResponse, rerunHttp.statusCode == 201 {
                    rerunCount += 1
                    logger.info("Rerun triggered for workflow run \(runId)")
                } else if let rerunHttp = rerunResponse as? HTTPURLResponse {
                    logger.warning("Failed to rerun workflow run \(runId): HTTP \(rerunHttp.statusCode)")
                }
            } catch {
                logger.warning("Network error rerunning workflow run \(runId): \(error.localizedDescription)")
            }
        }

        return rerunCount
    }

    // MARK: - Jira Ticket Extraction

    private static let jiraCacheKey = "PRDashboard.JiraTicketCache"

    private static let jiraTicketRegex = compileRegex("[A-Z][A-Z0-9]+-\\d+")

    static func extractJiraTicket(from text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = jiraTicketRegex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }

    private static func loadJiraCache() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: jiraCacheKey) as? [String: String] ?? [:]
    }

    private static let maxJiraCacheSize = 500

    private static func saveJiraCache(_ cache: [String: String]) {
        var trimmed = cache
        if trimmed.count > maxJiraCacheSize {
            let excess = trimmed.count - maxJiraCacheSize
            trimmed = Dictionary(uniqueKeysWithValues: trimmed.dropFirst(excess).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(trimmed, forKey: jiraCacheKey)
    }

    static func jiraCacheKey(for pr: PullRequest) -> String {
        "\(pr.repositoryOwner)/\(pr.repositoryName)#\(pr.number)"
    }

    /// Fetches PR bodies for uncached PRs and extracts Jira tickets. Returns the full cache.
    func fetchJiraTickets(for prs: [PullRequest]) async throws -> [String: String] {
        var cache = Self.loadJiraCache()

        // Filter PRs not yet in cache
        let uncached = prs.filter { cache[Self.jiraCacheKey(for: $0)] == nil }
        if uncached.isEmpty {
            return cache
        }

        var bodyLookupPRs: [PullRequest] = []
        for pr in uncached {
            let key = Self.jiraCacheKey(for: pr)
            if let ticket = Self.extractJiraTicket(from: pr.title) {
                cache[key] = ticket
            } else {
                bodyLookupPRs.append(pr)
            }
        }

        if bodyLookupPRs.isEmpty {
            Self.saveJiraCache(cache)
            return cache
        }

        logger.info("Fetching Jira tickets for \(bodyLookupPRs.count) uncached PR bodies")

        // Batch into groups of 20 to avoid overly large queries
        let batchSize = 20
        for batch in stride(from: 0, to: bodyLookupPRs.count, by: batchSize) {
            let end = min(batch + batchSize, bodyLookupPRs.count)
            let slice = Array(bodyLookupPRs[batch..<end])

            // Build batched GraphQL query using aliases
            var queryParts: [String] = []
            for (index, pr) in slice.enumerated() {
                queryParts.append("""
                    pr_\(index): repository(owner: "\(pr.repositoryOwner)", name: "\(pr.repositoryName)") {
                        pullRequest(number: \(pr.number)) {
                            body
                        }
                    }
                """)
            }

            let query = "query {\n" + queryParts.joined(separator: "\n") + "\n}"

            do {
                let responseData = try await executeGraphQL(query: query, operation: "fetchJiraTicketsBatch")
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let data = json["data"] as? [String: Any] else {
                    logger.error("Unexpected Jira GraphQL response: missing or invalid 'data' field")
                    for pr in slice {
                        let key = Self.jiraCacheKey(for: pr)
                        if cache[key] == nil {
                            cache[key] = ""
                        }
                    }
                    continue
                }

                for (index, pr) in slice.enumerated() {
                    let key = Self.jiraCacheKey(for: pr)
                    if let repo = data["pr_\(index)"] as? [String: Any],
                       let prData = repo["pullRequest"] as? [String: Any],
                       let body = prData["body"] as? String {
                        let ticket = Self.extractJiraTicket(from: body) ?? ""
                        cache[key] = ticket
                    } else {
                        // Store empty to avoid re-fetching
                        cache[key] = ""
                    }
                }
            } catch {
                logger.error("Failed to fetch Jira tickets batch: \(error.localizedDescription)")
                throw error
            }
        }

        Self.saveJiraCache(cache)
        return cache
    }

    /// Apply cached Jira tickets to PRs
    static func applyJiraTickets(to prs: inout [PullRequest], cache: [String: String]) {
        for index in prs.indices {
            let key = jiraCacheKey(for: prs[index])
            if let ticket = cache[key], !ticket.isEmpty {
                prs[index].jiraTicket = ticket
            }
        }
    }

    // MARK: - Configuration

    private static let configurationKey = "PRDashboard.Configuration"

    private static func loadCIStatusExcludeFilter() -> String {
        guard let data = UserDefaults.standard.data(forKey: configurationKey),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            return Configuration.default.ciStatusExcludeFilter
        }
        return config.ciStatusExcludeFilter
    }
}

private struct DirectMentionRateLimit: Decodable {
    let cost: Int
    let remaining: Int
    let resetAt: String?
}

private struct DirectMentionDynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct DirectMentionSourceBatchResponse: Decodable {
    let data: BatchData

    struct BatchData: Decodable {
        let aliases: [String: SourceNode]
        let rateLimit: DirectMentionRateLimit?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DirectMentionDynamicKey.self)
            var aliases: [String: SourceNode] = [:]
            var rateLimit: DirectMentionRateLimit?
            for key in container.allKeys {
                if key.stringValue == "rateLimit" {
                    rateLimit = try? container.decode(DirectMentionRateLimit.self, forKey: key)
                } else if let wrapper = try? container.decode(RepositoryWrapper.self, forKey: key),
                          let pullRequest = wrapper.pullRequest {
                    aliases[key.stringValue] = pullRequest
                }
            }
            self.aliases = aliases
            self.rateLimit = rateLimit
        }
    }

    struct RepositoryWrapper: Decodable {
        let pullRequest: SourceNode?
    }

    struct SourceNode: Decodable {
        let databaseId: Int?
        let state: String?
        let isDraft: Bool?
        let repository: Repository?
        let updatedAt: Date?
        let lastEditedAt: Date?
        let comments: TotalCount?
        let latestComments: LatestComments?
    }

    struct Repository: Decodable {
        let isArchived: Bool?
    }

    struct TotalCount: Decodable {
        let totalCount: Int?
    }

    struct LatestComments: Decodable {
        let nodes: [LatestComment]
    }

    struct LatestComment: Decodable {
        let id: String?
        let lastEditedAt: Date?
    }
}

private struct DirectMentionStateBatchResponse: Decodable {
    let data: BatchData

    struct BatchData: Decodable {
        let aliases: [String: StateNode]
        let rateLimit: DirectMentionRateLimit?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DirectMentionDynamicKey.self)
            var aliases: [String: StateNode] = [:]
            var rateLimit: DirectMentionRateLimit?
            for key in container.allKeys {
                if key.stringValue == "rateLimit" {
                    rateLimit = try? container.decode(DirectMentionRateLimit.self, forKey: key)
                } else if let wrapper = try? container.decode(RepositoryWrapper.self, forKey: key),
                          let pullRequest = wrapper.pullRequest {
                    aliases[key.stringValue] = pullRequest
                }
            }
            self.aliases = aliases
            self.rateLimit = rateLimit
        }
    }

    struct RepositoryWrapper: Decodable {
        let pullRequest: StateNode?
    }

    struct StateNode: Decodable {
        let databaseId: Int?
        let state: String?
        let title: String?
        let body: String?
        let author: Author?
        let createdAt: Date?
        let updatedAt: Date?
        let lastEditedAt: Date?
        let comments: Comments?
    }

    struct Author: Decodable {
        let login: String?
    }

    struct Comments: Decodable {
        let nodes: [CommentNode]
        let pageInfo: PageInfo?
        let hadDroppedNodes: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decode([FailableComment].self, forKey: .nodes)
            nodes = raw.compactMap(\.value)
            hadDroppedNodes = raw.contains { $0.value == nil }
            pageInfo = try container.decodeIfPresent(PageInfo.self, forKey: .pageInfo)
        }

        private enum CodingKeys: String, CodingKey {
            case nodes
            case pageInfo
        }
    }

    struct FailableComment: Decodable {
        let value: CommentNode?

        init(from decoder: Decoder) throws {
            value = try? CommentNode(from: decoder)
        }
    }

    struct CommentNode: Decodable {
        let id: String
        let author: Author?
        let body: String?
        let createdAt: Date
        let lastEditedAt: Date?
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

private struct DirectMentionDiscoveryResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let search: SearchResult
        let rateLimit: DirectMentionRateLimit?
    }

    struct SearchResult: Decodable {
        let issueCount: Int
        let nodes: [SearchNode]
        let droppedNodeCount: Int
        let pageInfo: PageInfo

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            issueCount = try container.decode(Int.self, forKey: .issueCount)
            let raw = try container.decode([FailableNode].self, forKey: .nodes)
            nodes = raw.compactMap(\.value)
            droppedNodeCount = raw.reduce(into: 0) { count, node in
                if node.value == nil { count += 1 }
            }
            pageInfo = try container.decode(PageInfo.self, forKey: .pageInfo)
        }

        private enum CodingKeys: String, CodingKey {
            case issueCount
            case nodes
            case pageInfo
        }
    }

    struct FailableNode: Decodable {
        let value: SearchNode?

        init(from decoder: Decoder) throws {
            value = try? SearchNode(from: decoder)
        }
    }

    struct SearchNode: Decodable {
        let databaseId: Int?
        let number: Int
        let title: String
        let body: String?
        let author: Author?
        let createdAt: Date
        let updatedAt: Date
        let lastEditedAt: Date?
        let isDraft: Bool
        let repository: Repository
        let comments: TotalCount?
        let latestComments: LatestComments?
    }

    struct Author: Decodable {
        let login: String?
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
        let isArchived: Bool?
    }

    struct Owner: Decodable {
        let login: String
    }

    struct TotalCount: Decodable {
        let totalCount: Int?
    }

    struct LatestComments: Decodable {
        let nodes: [LatestComment]
    }

    struct LatestComment: Decodable {
        let id: String?
        let lastEditedAt: Date?
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

// MARK: - GraphQL Response Models
private struct MentionSourceBatchResponse: Decodable {
    let data: BatchData

    struct BatchData: Decodable {
        let nodes: [PRNode]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var collected: [PRNode] = []
            for key in container.allKeys {
                if try container.decodeNil(forKey: key) {
                    continue
                }
                if let wrapper = try? container.decode(RepositoryWrapper.self, forKey: key),
                   let pullRequest = wrapper.pullRequest {
                    collected.append(pullRequest)
                }
            }
            nodes = collected
        }
    }

    private struct RepositoryWrapper: Decodable {
        let pullRequest: PRNode?
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    struct PRNode: Decodable {
        let id: String?
        let databaseId: Int?
        let number: Int
        let updatedAt: Date
        let repository: Repository
        let crossReferences: CrossReferencesContainer?
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
    }

    struct Owner: Decodable {
        let login: String
    }

    struct CrossReferencesContainer: Decodable {
        let nodes: [CrossReferenceEventNode]
    }

    struct CrossReferenceEventNode: Decodable {
        let source: RelatedPR?
        let target: RelatedPR?
    }

    struct RelatedPR: Decodable {
        let databaseId: Int?
        let number: Int
        let state: String
        let repository: Repository

        var repoFullName: String {
            "\(repository.owner.login)/\(repository.name)"
        }
    }
}

private struct PRReferenceSearchResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let search: SearchResult
    }

    struct SearchResult: Decodable {
        let nodes: [PRNode]
        let pageInfo: PageInfo
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct PRNode: Decodable {
        let number: Int
        let repository: Repository
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
    }

    struct Owner: Decodable {
        let login: String
    }
}



/// Decodes aliased `pr_0`, `pr_1`, ... results from `fetchDetailBatch`. Unlike
/// `MentionedBatchResponse` (which uses the search-shaped `GraphQLResponse.PRNode`),
/// this wraps the richer `CombinedGraphQLResponse.PRNode` so we can reuse review
/// metadata and review-request timeline parsing.
private struct DetailBatchResponse: Decodable {
    let data: BatchData

    struct BatchData: Decodable {
        let nodes: [CombinedGraphQLResponse.PRNode]
        let rateLimit: RateLimit?
        let rateLimitDecodeError: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var collected: [CombinedGraphQLResponse.PRNode] = []
            var foundRateLimit: RateLimit?
            var foundDecodeError: String?
            for key in container.allKeys {
                if key.stringValue == "rateLimit" {
                    do {
                        foundRateLimit = try container.decode(RateLimit.self, forKey: key)
                    } catch {
                        foundDecodeError = error.localizedDescription
                    }
                    continue
                }
                if try container.decodeNil(forKey: key) { continue }
                if let wrapper = try? container.decode(RepositoryWrapper.self, forKey: key),
                   let pr = wrapper.pullRequest {
                    collected.append(pr)
                }
            }
            self.nodes = collected
            self.rateLimit = foundRateLimit
            self.rateLimitDecodeError = foundDecodeError
        }
    }

    struct RateLimit: Decodable {
        let cost: Int
        let remaining: Int
        let resetAt: String?
    }

    private struct RepositoryWrapper: Decodable {
        let pullRequest: CombinedGraphQLResponse.PRNode?
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Decodes the dynamic-aliased `pr_0`, `pr_1`, ... response from `fetchMentionedBatch`,
/// flattening successful repository.pullRequest results into a single node list.
private struct MentionedBatchResponse: Decodable {
    let data: BatchData

    struct BatchData: Decodable {
        let nodesByAlias: [String: GraphQLResponse.PRNode]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var collected: [String: GraphQLResponse.PRNode] = [:]
            for key in container.allKeys where key.stringValue != "rateLimit" {
                if try container.decodeNil(forKey: key) { continue }
                if let wrapper = try? container.decode(RepositoryWrapper.self, forKey: key),
                   let pr = wrapper.pullRequest {
                    collected[key.stringValue] = pr
                }
            }
            self.nodesByAlias = collected
        }
    }

    private struct RepositoryWrapper: Decodable {
        let pullRequest: GraphQLResponse.PRNode?
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

struct IndexSearchResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let search: SearchResult
        let rateLimit: RateLimit?
    }

    struct SearchResult: Decodable {
        let nodes: [PRNode]

        private enum CodingKeys: String, CodingKey {
            case nodes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Decode leniently: should a search ever hit GitHub's resource
            // budget, the over-limit nodes come back as null (the non-null
            // `id`/`owner` fields fail and the null propagates up the whole
            // node). Dropping those instead of failing the decode lets the PRs
            // that did resolve still surface, rather than failing the entire
            // refresh with a "Failed to parse response" error.
            let raw = try container.decode([FailableNode].self, forKey: .nodes)
            nodes = raw.compactMap(\.value)
        }
    }

    /// Wrapper that decodes a node to nil instead of throwing when the element
    /// is null or missing a required field (see `SearchResult`).
    struct FailableNode: Decodable {
        let value: PRNode?

        init(from decoder: Decoder) throws {
            value = try? PRNode(from: decoder)
        }
    }

    struct RateLimit: Decodable {
        let cost: Int
        let remaining: Int
        let resetAt: String?
    }

    struct PRNode: Decodable {
        let id: String?
        let databaseId: Int?
        let number: Int
        let title: String
        let url: URL
        let state: String
        let isDraft: Bool
        let baseRefName: String?
        let headRefName: String?
        let createdAt: Date
        let updatedAt: Date
        let mergedAt: Date?
        let mergeable: String?
        let mergeStateStatus: String?
        let author: Author?
        let repository: Repository
        let reviewThreads: ReviewThreadsSummary?
        let oldestReviewThreads: ReviewThreadsSummary?
        let comments: TotalCountContainer?
        let reviews: TotalCountContainer?
        let commits: CommitsContainer?
    }

    struct Author: Decodable {
        let login: String
        let avatarUrl: URL?
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
        let isArchived: Bool?
    }

    struct Owner: Decodable {
        let login: String
    }

    struct TotalCountContainer: Decodable {
        let totalCount: Int
    }

    struct ReviewThreadsSummary: Decodable {
        let totalCount: Int
        let nodes: [ReviewThreadStateNode]?
    }

    struct ReviewThreadStateNode: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
    }

    struct CommitsContainer: Decodable {
        let nodes: [CommitNode]
    }

    struct CommitNode: Decodable {
        let commit: CommitInfo
    }

    struct CommitInfo: Decodable {
        let oid: String?
        let committedDate: Date?
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable {
        let state: String
    }
}

private struct GraphQLResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let search: SearchResult
    }

    struct SearchResult: Decodable {
        let nodes: [PRNode]
        let pageInfo: PageInfo
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct PRNode: Decodable {
        let id: String?
        let databaseId: Int?
        let number: Int
        let title: String
        let body: String?
        let url: URL
        let state: String
        let isDraft: Bool
        let baseRefName: String?
        let headRefName: String?
        let createdAt: Date
        let updatedAt: Date
        let mergedAt: Date?
        let mergeable: String?
        let mergeStateStatus: String?
        let author: Author?
        let repository: Repository
        let comments: IssueCommentsContainer?
        let reviewThreads: ReviewThreadsContainer?
        let commits: CommitsContainer?
        let latestReviews: LatestReviewsContainer?
    }

    struct Author: Decodable {
        let login: String
        let avatarUrl: URL?
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
        let isArchived: Bool?
    }

    struct Owner: Decodable {
        let login: String
    }

    struct LatestReviewsContainer: Decodable {
        let nodes: [LatestReviewNode]
    }

    struct LatestReviewNode: Decodable {
        let state: String
        let author: Author?
    }

    struct IssueCommentsContainer: Decodable {
        let nodes: [CommentNode]
    }

    struct ReviewThreadsContainer: Decodable {
        let nodes: [ReviewThreadNode]
        let pageInfo: ReviewThreadPageInfo?
    }

    struct ReviewThreadPageInfo: Decodable {
        let hasPreviousPage: Bool
        let startCursor: String?
    }

    struct ReviewThreadNode: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let path: String?
        let line: Int?
        let comments: CommentsContainer
    }

    struct CommentsContainer: Decodable {
        let nodes: [CommentNode]
    }

    struct CommentNode: Decodable {
        let id: String
        let author: Author?
        let body: String?
        let createdAt: Date
        let lastEditedAt: Date?
    }

    struct CommitsContainer: Decodable {
        let nodes: [CommitNode]
    }

    struct CommitNode: Decodable {
        let commit: CommitInfo
    }

    struct CommitInfo: Decodable {
        let oid: String?
        let committedDate: Date?
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable {
        let state: String
        let contexts: ContextsContainer?
    }

    struct ContextsContainer: Decodable {
        let nodes: [ContextNode]
        let pageInfo: PageInfoContext?
    }

    struct PageInfoContext: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct ContextNode: Decodable {
        // CheckRun uses "name" and "conclusion", StatusContext uses "state" and "context"
        let name: String?        // CheckRun name (e.g., "build", "test")
        let conclusion: String?  // SUCCESS, FAILURE, NEUTRAL, CANCELLED, SKIPPED, TIMED_OUT, ACTION_REQUIRED, null (in progress)
        let completedAt: Date?   // CheckRun completion timestamp (used for dedup ordering)
        let state: String?       // PENDING, SUCCESS, FAILURE, ERROR, EXPECTED
        let context: String?     // StatusContext name (e.g., "ci/build", "code-review/reviewable")
        let checkSuite: CheckSuiteNode?
    }

    struct CheckSuiteNode: Decodable {
        let workflowRun: WorkflowRunNode?
    }
    struct WorkflowRunNode: Decodable {
        let workflow: WorkflowNode?
    }
    struct WorkflowNode: Decodable {
        let name: String?
    }
}


private struct HoverMetadataResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let repository: RepositoryContainer?
        let rateLimit: RateLimit?
    }

    struct RepositoryContainer: Decodable {
        let pullRequest: PullRequestNode?
    }

    struct PullRequestNode: Decodable {
        let id: String?
        let databaseId: Int?
        let baseRefName: String?
        let headRefName: String?
        let mergeable: String?
        let mergeStateStatus: String?
        let latestReviews: GraphQLResponse.LatestReviewsContainer?
        let commits: GraphQLResponse.CommitsContainer?
    }

    struct RateLimit: Decodable {
        let cost: Int
        let remaining: Int
        let resetAt: String?
    }
}

// MARK: - Combined GraphQL Response Models (for single-query fetch)

private struct CombinedGraphQLResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let authored: SearchResult
        let reviewRequested: SearchResult
        let reviewedBy: SearchResult
        let mergedInvolved: SearchResult
    }

    struct SearchResult: Decodable {
        let nodes: [PRNode]
    }

    struct PRNode: Decodable {
        let id: String?
        let databaseId: Int?
        let number: Int
        let title: String
        let body: String?
        let url: URL
        let state: String
        let isDraft: Bool
        let baseRefName: String?
        let headRefName: String?
        let createdAt: Date
        let updatedAt: Date
        let mergedAt: Date?
        let mergeable: String?
        let mergeStateStatus: String?
        let author: Author?
        let repository: Repository
        let comments: IssueCommentsContainer?
        let reviewThreads: ReviewThreadsContainer?
        let commits: CommitsContainer?
        let reviews: ReviewsContainer?
        let latestReviews: LatestReviewsContainer?
        let reviewRequestEvents: ReviewRequestEventsContainer?
    }

    struct Author: Decodable {
        let login: String
        let avatarUrl: URL?
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
        let isArchived: Bool?
    }

    struct Owner: Decodable {
        let login: String
    }

    struct LatestReviewsContainer: Decodable {
        let nodes: [LatestReviewNode]
    }

    struct LatestReviewNode: Decodable {
        let state: String
        let author: Author?
    }

    struct IssueCommentsContainer: Decodable {
        let nodes: [CommentNode]
    }

    struct ReviewThreadsContainer: Decodable {
        let nodes: [ReviewThreadNode]
        let pageInfo: ReviewThreadPageInfo?
    }

    struct ReviewThreadPageInfo: Decodable {
        let hasPreviousPage: Bool
        let startCursor: String?
    }

    struct ReviewThreadNode: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let path: String?
        let line: Int?
        let comments: CommentsContainer
    }

    struct CommentsContainer: Decodable {
        let nodes: [CommentNode]
    }

    struct CommentNode: Decodable {
        let id: String
        let author: Author?
        let body: String?
        let createdAt: Date
        let lastEditedAt: Date?
    }

    struct CommitsContainer: Decodable {
        let nodes: [CommitNode]
    }

    struct CommitNode: Decodable {
        let commit: CommitInfo
    }

    struct CommitInfo: Decodable {
        let oid: String?
        let committedDate: Date?
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable {
        let state: String
        let contexts: ContextsContainer?
    }

    struct ContextsContainer: Decodable {
        let nodes: [ContextNode]
        let pageInfo: PageInfoContext?
    }

    struct PageInfoContext: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct ContextNode: Decodable {
        let name: String?
        let conclusion: String?
        let completedAt: Date?
        let state: String?
        let context: String?
        let checkSuite: CheckSuiteNode?
    }

    struct CheckSuiteNode: Decodable {
        let workflowRun: WorkflowRunNode?
    }
    struct WorkflowRunNode: Decodable {
        let workflow: WorkflowNode?
    }
    struct WorkflowNode: Decodable {
        let name: String?
    }

    struct ReviewsContainer: Decodable {
        let nodes: [ReviewNode]
    }

    struct ReviewNode: Decodable {
        let state: String
        let submittedAt: Date?
    }

    struct ReviewRequestEventsContainer: Decodable {
        let nodes: [ReviewRequestEventNode]
    }

    struct ReviewRequestEventNode: Decodable {
        let createdAt: Date?
        let requestedReviewer: RequestedReviewer?
    }

    struct RequestedReviewer: Decodable {
        let login: String?
    }

}

private extension Array {
    /// Split into consecutive sub-arrays of at most `size` elements. A non-positive
    /// `size` yields a single chunk so callers can't trip `stride(by: 0)`.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
