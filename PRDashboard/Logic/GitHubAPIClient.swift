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

    static var empty: RateLimitInfo {
        RateLimitInfo(limit: 5000, remaining: 5000, resetDate: Date())
    }
}

/// Lightweight snapshot produced by the index query. Holds only the scalars
/// we need to decide whether a cached detail can be reused.
struct IndexedPR {
    let databaseId: Int
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
    let hasBaseConflicts: Bool
    let category: PRCategory
    let isMerged: Bool
    let snapshot: IndexSnapshot

    var reference: PullRequestReference {
        PullRequestReference(owner: repositoryOwner, repo: repositoryName, number: number)
    }

    /// Produce a `PullRequest` suitable for optimistic UI rendering. When a cached
    /// detail is supplied we keep its heavy fields (reviewThreads, CI contexts,
    /// comments) and patch only the header fields from the fresh index scalars.
    func placeholderPullRequest(using existing: PullRequest? = nil) -> PullRequest {
        return PullRequest(
            id: databaseId,
            number: number,
            title: title,
            author: author,
            authorAvatarURL: authorAvatarURL,
            repositoryOwner: repositoryOwner,
            repositoryName: repositoryName,
            url: url,
            state: state,
            isDraft: isDraft,
            createdAt: createdAt,
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            body: existing?.body,
            conversationComments: existing?.conversationComments ?? [],
            lastCommitAt: existing?.lastCommitAt,
            headCommitOid: snapshot.headOid ?? existing?.headCommitOid,
            reviewThreads: existing?.reviewThreads ?? [],
            category: category,
            hasBaseConflicts: hasBaseConflicts,
            ciStatus: existing?.ciStatus,
            checkSuccessCount: existing?.checkSuccessCount ?? 0,
            checkFailureCount: existing?.checkFailureCount ?? 0,
            checkPendingCount: existing?.checkPendingCount ?? 0,
            githubCIState: existing?.githubCIState,
            myLastReviewState: existing?.myLastReviewState,
            myLastReviewAt: existing?.myLastReviewAt,
            reviewRequestedAt: existing?.reviewRequestedAt,
            myThreadsAllResolved: existing?.myThreadsAllResolved ?? false,
            approvalCount: existing?.approvalCount ?? 0,
            changesRequestedCount: existing?.changesRequestedCount,
            ciExtendedInfo: existing?.ciExtendedInfo,
            jiraTicket: existing?.jiraTicket
        )
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
    private static let maxCIContextsToFetch = 200
    private static let maxGraphQLAttempts = 3
    /// Aliased-batch size used by detail / mention-source / mentioned-PR batches.
    private static let batchedPRQuerySize = 20
    /// Maximum number of aliased-batch queries in flight at once. Applied to
    /// fetchIncremental, fetchMentionSourceReferences, and fetchMentionedPullRequests
    /// so a cold start can't burst 10+ concurrent GraphQL requests.
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

    init(token: String, graphQLEndpoint: String? = nil) {
        self.token = token
        self.session = Self.makeSession(proxy: nil, delegate: sessionDelegate)
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
        return try parseSearchResponse(data: responseData, category: category)
    }

    struct CombinedPRResult {
        let openPRs: [PullRequest]
        let mentionedPRs: [PullRequest]
        let mergedPRs: [PullRequest]
    }

    /// Stage of an in-flight incremental refresh. PRManager uses this to decide
    /// whether to apply filters and publish, without running the final
    /// notification/Jira/change-detection pipeline on intermediate frames.
    enum IncrementalStage: String {
        case placeholders
        case detailProgress
    }

    /// Index-first, cache-aware refresh. Runs a cheap scalar-only "index" query
    /// then fetches detail only for PRs whose index snapshot changed. Emits
    /// intermediate `onProgress` frames so the UI can paint as soon as index
    /// returns and re-paint after each detail batch.
    func fetchIncremental(
        username: String,
        onProgress: (@Sendable ([PullRequest], [PullRequest], IncrementalStage) async -> Void)? = nil
    ) async throws -> CombinedPRResult {
        let indexed = try await fetchIndex(username: username)
        logger.info("Index returned \(indexed.count, privacy: .public) PRs (authored+reviewed+merged)")

        let cache = PRDetailCache.shared.loadEntries()
        let now = Date()
        var snapshotByID: [Int: IndexSnapshot] = [:]
        var hits: [Int: PullRequest] = [:]
        var misses: [IndexedPR] = []

        for ip in indexed {
            snapshotByID[ip.databaseId] = ip.snapshot
            if let cached = cache[ip.databaseId],
               cached.isUsable(against: ip.snapshot, now: now, ttl: PRDetailCache.ttl) {
                hits[ip.databaseId] = ip.placeholderPullRequest(using: cached.detail)
            } else {
                misses.append(ip)
            }
        }
        logger.info("Cache diff: \(hits.count, privacy: .public) hits, \(misses.count, privacy: .public) misses")

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
            for ip in misses {
                optimistic[ip.databaseId] = ip.placeholderPullRequest(using: cache[ip.databaseId]?.detail)
            }
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
            for ip in misses {
                if let cached = cache[ip.databaseId] {
                    fetched[ip.databaseId] = ip.placeholderPullRequest(using: cached.detail)
                } else {
                    fetched[ip.databaseId] = ip.placeholderPullRequest()
                }
            }
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
            let batches: [[IndexedPR]] = stride(from: 0, to: sorted.count, by: Self.batchedPRQuerySize).map {
                Array(sorted[$0..<min($0 + Self.batchedPRQuerySize, sorted.count)])
            }
            let fieldSelection = buildPRFieldSelection(
                username: username,
                includeReviewMetadata: true,
                includeCrossReferences: false,
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
                        byID.merge(fetched) { _, new in new }
                        for ip in misses where byID[ip.databaseId] == nil {
                            byID[ip.databaseId] = ip.placeholderPullRequest(using: cache[ip.databaseId]?.detail)
                        }
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
            for ip in misses where fetched[ip.databaseId] == nil {
                fetched[ip.databaseId] = ip.placeholderPullRequest(using: cache[ip.databaseId]?.detail)
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

        let split = splitOpenMerged(byID: combinedByID)
        let openPRs = split.open
        let mergedPRs = split.merged

        let mentionedPRs = try await enrichWithMentions(openPRs: openPRs, mergedPRs: mergedPRs)

        return CombinedPRResult(
            openPRs: openPRs,
            mentionedPRs: mentionedPRs,
            mergedPRs: mergedPRs
        )
    }

    /// Run the mention-discovery pipeline for the given seed PRs. Uses MentionCache
    /// (TTL+cooldown) to avoid re-scanning unchanged source PRs.
    private func enrichWithMentions(
        openPRs: [PullRequest],
        mergedPRs: [PullRequest]
    ) async throws -> [PullRequest] {
        let seedPRs = openPRs + mergedPRs
        guard !seedPRs.isEmpty else { return [] }

        let existingReferences = Set(
            seedPRs.map {
                PullRequestReference(
                    owner: $0.repositoryOwner,
                    repo: $0.repositoryName,
                    number: $0.number
                )
            }
        )

        var mentionCandidates = Set<PullRequestReference>()
        var mentionCacheEntries = MentionCache.shared.loadEntries()
        var mentionSourcesToRefresh: [PullRequest] = []
        let refreshTimestamp = Date()

        for pr in seedPRs {
            if let cacheEntry = mentionCacheEntries[pr.id],
               cacheEntry.isUsable(
                   currentUpdatedAt: pr.updatedAt,
                   now: refreshTimestamp,
                   ttl: MentionCache.ttl,
                   cooldown: MentionCache.cooldown
               ) {
                mentionCandidates.formUnion(cacheEntry.pullRequestReferences)
            } else {
                mentionSourcesToRefresh.append(pr)
            }
        }

        let rateLimitSnapshot = await MainActor.run { self.rateLimitInfo }
        if !mentionSourcesToRefresh.isEmpty, !rateLimitSnapshot.hasHeadroomForMentions {
            logger.info(
                "Skipping mention refresh: rate limit remaining \(rateLimitSnapshot.remaining) below headroom threshold"
            )
            for pr in mentionSourcesToRefresh {
                if let stale = mentionCacheEntries[pr.id] {
                    mentionCandidates.formUnion(stale.pullRequestReferences)
                }
            }
            mentionSourcesToRefresh.removeAll()
        }

        if !mentionSourcesToRefresh.isEmpty {
            logger.info("Refreshing mention sources for \(mentionSourcesToRefresh.count) PRs")
            let refreshedReferences = try await fetchMentionSourceReferences(for: mentionSourcesToRefresh)

            for pr in mentionSourcesToRefresh {
                let references = refreshedReferences[pr.id] ?? []
                mentionCandidates.formUnion(references)
                let sortedReferences = references.sorted {
                    if $0.owner != $1.owner { return $0.owner < $1.owner }
                    if $0.repo != $1.repo { return $0.repo < $1.repo }
                    return $0.number < $1.number
                }
                mentionCacheEntries[pr.id] = MentionCacheEntry(
                    sourcePRID: pr.id,
                    sourceUpdatedAt: pr.updatedAt,
                    references: sortedReferences,
                    cachedAt: refreshTimestamp
                )
            }

            MentionCache.shared.saveEntries(mentionCacheEntries)
        }

        mentionCandidates.subtract(existingReferences)
        guard !mentionCandidates.isEmpty else { return [] }

        var mentionedPRs = try await fetchMentionedPullRequests(references: Array(mentionCandidates))
        var seenMentionedIDs = Set<Int>()
        mentionedPRs = mentionedPRs
            .filter { $0.state == .open && seenMentionedIDs.insert($0.id).inserted }
            .sorted { $0.updatedAt > $1.updatedAt }
        return mentionedPRs
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

    private static func deriveBaseConflicts(mergeable: String?, mergeStateStatus: String?) -> Bool {
        mergeable == mergeableConflicting || mergeStateStatus == mergeStateDirty
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
            insertIfSameRepository(owner: repositoryOwner, repo: repositoryName, number: number)
        }

        return result
    }

    private func buildPRFieldSelection(
        username: String? = nil,
        includeReviewMetadata: Bool,
        includeCrossReferences: Bool,
        includeMentionBodies: Bool
    ) -> String {
        let reviewCommentBodyField = includeMentionBodies ? "\n                            body" : ""
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
                }
            }
        """ : ""

        var sections: [String] = [
            """
            databaseId
            number
            title
            url
            state
            isDraft
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
                    state
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

        if includeCrossReferences {
            sections.append(
                """
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
            )
        }

        return sections.joined(separator: "\n")
    }

    private func buildMentionSourceFieldSelection() -> String {
        """
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
        var pendingCount: Int = 0
        var isRunning: Bool = false
        var workflows: [String: CIWorkflowInfo] = [:]
        var seenCheckNames: Set<String> = []
    }

    /// Shared CI context parsing logic used by parseSearchResponse, parseNodes, and fetchFullCIContexts
    private static func parseCIContexts<T: CIContextLike>(_ contexts: [T], excludeFilter: String, existing: CIParseResult = CIParseResult()) -> CIParseResult {
        var result = existing

        // Sort newest-first by completedAt so dedup keeps the latest result per check name.
        // Entries without completedAt (in-progress checks, StatusContexts) sort to the end.
        let sorted = contexts.sorted {
            ($0.ciCompletedAt ?? .distantPast) > ($1.ciCompletedAt ?? .distantPast)
        }
        for context in sorted {
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
                if !excludeFilter.isEmpty,
                   let contextName = context.ciContext,
                   contextName.lowercased().contains(excludeFilter.lowercased()) {
                    continue
                }
                let workflowKey = context.ciContext ?? "status"
                switch state.uppercased() {
                case "SUCCESS":
                    result.successCount += 1
                    updateWorkflow(&result.workflows, key: workflowKey, isWorkflow: false, success: 1)
                case "FAILURE", "ERROR":
                    result.failureCount += 1
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

    // MARK: - Private

    private func buildPRIndexFieldSelection() -> String {
        """
        databaseId
        number
        title
        url
        state
        isDraft
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
                }
            }
        }
        """
    }

    private func buildIndexQuery(username: String) -> String {
        let fragment = buildPRIndexFieldSelection()
        let mergedSince = Self.dateStringForSearch(daysBack: 2)
        let prFragment = """
                nodes {
                    ... on PullRequest {
                        \(fragment)
                    }
                }
        """

        return """
        query {
            authored: search(query: "is:pr is:open author:\(username)", type: ISSUE, first: 50) {
                \(prFragment)
            }
            reviewRequested: search(query: "is:pr is:open -author:\(username) review-requested:\(username)", type: ISSUE, first: 50) {
                \(prFragment)
            }
            reviewedBy: search(query: "is:pr is:open -author:\(username) reviewed-by:\(username)", type: ISSUE, first: 50) {
                \(prFragment)
            }
            mergedInvolved: search(query: "is:pr is:merged involves:\(username) merged:>=\(mergedSince)", type: ISSUE, first: 50) {
                \(prFragment)
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
        let query = buildIndexQuery(username: username)
        let data = try await executeGraphQL(query: query, operation: "fetchIndex")
        return try parseIndexResponse(data: data, username: username)
    }

    private func parseIndexResponse(data: Data, username: String) throws -> [IndexedPR] {
        let decoder = JSONDecoder.githubDecoder
        let response: IndexGraphQLResponse
        do {
            response = try decoder.decode(IndexGraphQLResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }

        if let rl = response.data.rateLimit {
            logger.info("Index query cost=\(rl.cost, privacy: .public) remaining=\(rl.remaining, privacy: .public)")
        }

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
            _ node: IndexGraphQLResponse.PRNode,
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
            let snapshot = IndexSnapshot(
                updatedAt: node.updatedAt,
                headOid: lastCommit?.oid,
                reviewThreadTotal: node.reviewThreads?.totalCount ?? 0,
                commentTotal: node.comments?.totalCount ?? 0,
                reviewTotal: node.reviews?.totalCount ?? 0,
                unresolvedReviewThreadCount: sampledUnresolved
            )
            return IndexedPR(
                databaseId: databaseId,
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
                hasBaseConflicts: Self.deriveBaseConflicts(
                    mergeable: node.mergeable,
                    mergeStateStatus: node.mergeStateStatus
                ),
                category: category,
                isMerged: isMerged,
                snapshot: snapshot
            )
        }

        for node in response.data.authored.nodes {
            if let ip = indexedFromNode(node, category: .authored, isMerged: false) {
                appendIfNew(ip)
            }
        }
        for node in response.data.reviewRequested.nodes {
            if let ip = indexedFromNode(node, category: .reviewRequest, isMerged: false) {
                appendIfNew(ip)
            }
        }
        for node in response.data.reviewedBy.nodes {
            if let ip = indexedFromNode(node, category: .reviewRequest, isMerged: false) {
                appendIfNew(ip)
            }
        }
        for node in response.data.mergedInvolved.nodes {
            let resolved: PRCategory = (node.author?.login.lowercased() == usernameLower) ? .authored : .reviewRequest
            if let ip = indexedFromNode(node, category: resolved, isMerged: true) {
                appendIfNew(ip)
            }
        }
        return result
    }

    private static func dateStringForSearch(daysBack: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let sinceDate = calendar.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: sinceDate)
    }

    private func buildGraphQLQuery(searchQuery: String) -> String {
        """
        query {
            search(query: "\(searchQuery)", type: ISSUE, first: 50) {
                nodes {
                    ... on PullRequest {
                        \(buildPRFieldSelection(
                            includeReviewMetadata: false,
                            includeCrossReferences: false,
                            includeMentionBodies: false
                        ))
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

    private func executeGraphQL(query: String, operation: String) async throws -> Data {
        var request = URLRequest(url: graphQLURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let body = ["query": query]
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
        excludeFilter: String
    ) -> PullRequest? {
        guard let databaseId = node.databaseId else { return nil }

        let conversationComments = node.comments?.nodes.map { comment in
            IssueCommentSummary(
                id: comment.id,
                author: comment.author?.login ?? "unknown",
                body: comment.body ?? "",
                createdAt: comment.createdAt
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
        let ciResult = parseCIContexts(ciContexts, excludeFilter: excludeFilter)

        let rollupState = statusCheckRollup?.state
        var ciStatus: CIStatus?
        if ciResult.failureCount > 0 {
            ciStatus = .failure
        } else if ciResult.pendingCount > 0 {
            ciStatus = .pending
        } else if ciResult.successCount > 0 {
            ciStatus = .success
        } else if statusCheckRollup != nil {
            ciStatus = .expected
        } else {
            ciStatus = nil
        }

        // Trust GitHub's rollup state when it says PENDING but we derived success.
        // This handles QUEUED checks not yet visible in individual contexts.
        var effectivePendingCount = ciResult.pendingCount
        var effectiveIsRunning = ciResult.isRunning
        if ciStatus == .success, rollupState?.uppercased() == "PENDING" {
            ciStatus = .pending
            effectivePendingCount = max(effectivePendingCount, 1)
            effectiveIsRunning = true
        }

        let approvalCount = node.latestReviews?.nodes
            .filter { $0.state == "APPROVED" }
            .count ?? 0

        let changesRequestedCount = node.latestReviews?.nodes
            .filter { $0.state == "CHANGES_REQUESTED" }
            .count ?? 0

        let hasBaseConflicts = deriveBaseConflicts(
            mergeable: node.mergeable,
            mergeStateStatus: node.mergeStateStatus
        )

        let ciExtendedInfo: CIExtendedInfo? = ciResult.workflows.isEmpty ? nil : CIExtendedInfo(
            isRunning: effectiveIsRunning,
            workflows: Array(ciResult.workflows.values)
        )

        return PullRequest(
            id: databaseId,
            number: node.number,
            title: node.title,
            author: node.author?.login ?? "unknown",
            authorAvatarURL: node.author?.avatarUrl,
            repositoryOwner: node.repository.owner.login,
            repositoryName: node.repository.name,
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
            reviewThreads: reviewThreads,
            category: category,
            hasBaseConflicts: hasBaseConflicts,
            ciStatus: ciStatus,
            checkSuccessCount: ciResult.successCount,
            checkFailureCount: ciResult.failureCount,
            checkPendingCount: effectivePendingCount,
            githubCIState: rollupState,
            myLastReviewState: nil,
            myLastReviewAt: nil,
            reviewRequestedAt: nil,
            myThreadsAllResolved: false,
            approvalCount: approvalCount,
            changesRequestedCount: changesRequestedCount,
            ciExtendedInfo: ciExtendedInfo
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

    private static func extractOutboundMentionReferences(
        body: String?,
        conversationComments: [IssueCommentSummary],
        reviewThreads: [ReviewThread],
        repositoryOwner: String,
        repositoryName: String,
        sourcePRNumber: Int
    ) -> Set<PullRequestReference> {
        var result = Set<PullRequestReference>()

        if let body, !body.isEmpty {
            result.formUnion(
                extractMentionedPRReferences(
                    from: body,
                    repositoryOwner: repositoryOwner,
                    repositoryName: repositoryName,
                    sourcePRNumber: sourcePRNumber
                )
            )
        }

        for comment in conversationComments {
            result.formUnion(
                extractMentionedPRReferences(
                    from: comment.body,
                    repositoryOwner: repositoryOwner,
                    repositoryName: repositoryName,
                    sourcePRNumber: sourcePRNumber
                )
            )
        }

        for thread in reviewThreads {
            for comment in thread.comments {
                result.formUnion(
                    extractMentionedPRReferences(
                        from: comment.body,
                        repositoryOwner: repositoryOwner,
                        repositoryName: repositoryName,
                        sourcePRNumber: sourcePRNumber
                    )
                )
            }
        }

        return result
    }

    private static func inboundMentionReferences(
        from node: MentionSourceBatchResponse.PRNode,
        currentPR: PullRequestReference
    ) -> Set<PullRequestReference> {
        let currentRepoLower = currentPR.repoFullName.lowercased()
        var result = Set<PullRequestReference>()

        for event in node.crossReferences?.nodes ?? [] {
            if let source = event.source,
               source.state == "OPEN",
               source.repoFullName.lowercased() == currentRepoLower,
               source.number != currentPR.number {
                result.insert(
                    PullRequestReference(
                        owner: source.repository.owner.login,
                        repo: source.repository.name,
                        number: source.number
                    )
                )
            }

            if let target = event.target,
               target.state == "OPEN",
               target.repoFullName.lowercased() == currentRepoLower,
               target.number != currentPR.number {
                result.insert(
                    PullRequestReference(
                        owner: target.repository.owner.login,
                        repo: target.repository.name,
                        number: target.number
                    )
                )
            }
        }

        return result
    }

    private func fetchMentionSourceReferences(for prs: [PullRequest]) async throws -> [Int: Set<PullRequestReference>] {
        let sortedPRs = prs.sorted {
            if $0.repositoryOwner != $1.repositoryOwner { return $0.repositoryOwner < $1.repositoryOwner }
            if $0.repositoryName != $1.repositoryName { return $0.repositoryName < $1.repositoryName }
            return $0.number < $1.number
        }

        let batches: [[PullRequest]] = stride(from: 0, to: sortedPRs.count, by: Self.batchedPRQuerySize).map {
            Array(sortedPRs[$0..<min($0 + Self.batchedPRQuerySize, sortedPRs.count)])
        }

        // Bounded-concurrency task group — mirrors fetchIncremental so mention
        // scanning can't fan out 7-8 concurrent requests on cold start.
        return try await withThrowingTaskGroup(of: [Int: Set<PullRequestReference>].self) { group in
            var iter = batches.makeIterator()
            var inflight = 0
            while inflight < Self.batchedPRQueryConcurrency, let batch = iter.next() {
                group.addTask { try await self.fetchMentionSourceBatch(batch) }
                inflight += 1
            }
            var result: [Int: Set<PullRequestReference>] = [:]
            while let partial = try await group.next() {
                result.merge(partial) { _, new in new }
                inflight -= 1
                if let next = iter.next() {
                    group.addTask { try await self.fetchMentionSourceBatch(next) }
                    inflight += 1
                }
            }
            return result
        }
    }

    /// Fetch only `crossReferences` (inbound mentions) for a batch of PRs. We no
    /// longer re-fetch body/comments/reviewThreads — those are already present on
    /// each `PullRequest` (populated by fetchIncremental from PRDetailCache or the
    /// detail batch), so outbound mentions can be extracted locally.
    private func fetchMentionSourceBatch(_ batch: [PullRequest]) async throws -> [Int: Set<PullRequestReference>] {
        var queryParts: [String] = []
        for (index, pr) in batch.enumerated() {
            queryParts.append(
                """
                pr_\(index): repository(owner: "\(pr.repositoryOwner)", name: "\(pr.repositoryName)") {
                    pullRequest(number: \(pr.number)) {
                        \(buildMentionSourceFieldSelection())
                    }
                }
                """
            )
        }

        let query = "query {\n" + queryParts.joined(separator: "\n") + "\n}"
        let responseData = try await executeGraphQL(query: query, operation: "fetchMentionSourceBatch")

        let decoder = JSONDecoder.githubDecoder
        let response: MentionSourceBatchResponse
        do {
            response = try decoder.decode(MentionSourceBatchResponse.self, from: responseData)
        } catch {
            throw APIError.decoding(error)
        }

        let sourcePRsById = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
        var result: [Int: Set<PullRequestReference>] = [:]

        // Outbound: extract from local fields on the PullRequest we already have.
        for pr in batch {
            let outbound = Self.extractOutboundMentionReferences(
                body: pr.body,
                conversationComments: pr.conversationComments,
                reviewThreads: pr.reviewThreads,
                repositoryOwner: pr.repositoryOwner,
                repositoryName: pr.repositoryName,
                sourcePRNumber: pr.number
            )
            result[pr.id] = outbound
        }

        // Inbound: derive from the fresh crossReferences we just fetched.
        for node in response.data.nodes {
            guard let databaseId = node.databaseId,
                  let sourcePR = sourcePRsById[databaseId] else { continue }
            let currentPR = PullRequestReference(
                owner: sourcePR.repositoryOwner,
                repo: sourcePR.repositoryName,
                number: sourcePR.number
            )
            let inbound = Self.inboundMentionReferences(from: node, currentPR: currentPR)
            result[databaseId, default: []].formUnion(inbound)
        }

        return result
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
            if pr.checkFailureCount > 0 {
                pr.ciStatus = .failure
            } else if pr.checkPendingCount > 0 {
                pr.ciStatus = .pending
            } else if pr.checkSuccessCount > 0 {
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

    private func fetchMentionedPullRequests(references: [PullRequestReference]) async throws -> [PullRequest] {
        let sortedReferences = references.sorted {
            if $0.owner != $1.owner { return $0.owner < $1.owner }
            if $0.repo != $1.repo { return $0.repo < $1.repo }
            return $0.number < $1.number
        }

        let fieldSelection = buildPRFieldSelection(
            includeReviewMetadata: false,
            includeCrossReferences: false,
            includeMentionBodies: false
        )
        let batches: [[PullRequestReference]] = stride(from: 0, to: sortedReferences.count, by: Self.batchedPRQuerySize).map {
            Array(sortedReferences[$0..<min($0 + Self.batchedPRQuerySize, sortedReferences.count)])
        }

        // Bounded-concurrency task group — keeps mentioned-PR detail fetching
        // within the same burst budget as the rest of the refresh path.
        return try await withThrowingTaskGroup(of: [PullRequest].self) { group in
            var iter = batches.makeIterator()
            var inflight = 0
            while inflight < Self.batchedPRQueryConcurrency, let batch = iter.next() {
                group.addTask { [fieldSelection] in
                    try await self.fetchMentionedBatch(batch, fieldSelection: fieldSelection)
                }
                inflight += 1
            }
            var result: [PullRequest] = []
            while let partial = try await group.next() {
                result.append(contentsOf: partial)
                inflight -= 1
                if let next = iter.next() {
                    group.addTask { [fieldSelection] in
                        try await self.fetchMentionedBatch(next, fieldSelection: fieldSelection)
                    }
                    inflight += 1
                }
            }
            return result
        }
    }

    private func fetchMentionedBatch(
        _ batch: [PullRequestReference],
        fieldSelection: String
    ) async throws -> [PullRequest] {
        var queryParts: [String] = []
        for (index, reference) in batch.enumerated() {
            queryParts.append(
                """
                pr_\(index): repository(owner: "\(reference.owner)", name: "\(reference.repo)") {
                    pullRequest(number: \(reference.number)) {
                        \(fieldSelection)
                    }
                }
                """
            )
        }

        let query = "query {\n" + queryParts.joined(separator: "\n") + "\n}"
        let responseData = try await executeGraphQL(query: query, operation: "fetchMentionedPullRequests")

        let decoder = JSONDecoder.githubDecoder
        let response: MentionedBatchResponse
        do {
            response = try decoder.decode(MentionedBatchResponse.self, from: responseData)
        } catch {
            throw APIError.decoding(error)
        }
        let excludeFilter = Self.loadCIStatusExcludeFilter()
        return response.data.nodes.compactMap {
            Self.makeSearchPullRequest(from: $0, category: .mentioned, excludeFilter: excludeFilter)
        }
    }

    private struct CICounts {
        var success: Int
        var failure: Int
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
                let counts = try await fetchFullCIContexts(
                    owner: info.owner,
                    repo: info.repo,
                    commitOid: info.commitOid,
                    startCursor: info.endCursor,
                    initialCount: info.initialContextCount
                )
                results[info.prId] = counts
                logger.info("Enriched CI for PR \(info.prId): \(counts.success) success, \(counts.failure) failure, \(counts.pending) pending, limitReached=\(counts.limitReached)")
            } catch {
                logger.error("Failed to fetch additional CI contexts for PR \(info.prId): \(error.localizedDescription)")
            }
        }

        return results
    }

    /// Fetches all remaining CI contexts for a commit, paginating as needed
    /// Returns counts and whether the limit was reached before exhausting all pages
    private func fetchFullCIContexts(owner: String, repo: String, commitOid: String, startCursor: String, initialCount: Int) async throws -> CICounts {
        var parseResult = CIParseResult()
        var cursor: String? = startCursor
        let excludeFilter = Self.loadCIStatusExcludeFilter()
        var totalFetched = initialCount
        var limitReached = false

        while let currentCursor = cursor {
            let result = try await fetchAdditionalCIContexts(owner: owner, repo: repo, commitOid: commitOid, after: currentCursor)
            totalFetched += result.contexts.count

            parseResult = Self.parseCIContexts(result.contexts, excludeFilter: excludeFilter, existing: parseResult)

            // Check if we've reached the limit
            if totalFetched >= Self.maxCIContextsToFetch {
                if result.hasNextPage {
                    logger.warning("Reached CI context limit (\(Self.maxCIContextsToFetch)) for \(owner)/\(repo)@\(commitOid), more pages available")
                    limitReached = true
                }
                break
            }

            cursor = result.hasNextPage ? result.endCursor : nil
        }

        return CICounts(
            success: parseResult.successCount,
            failure: parseResult.failureCount,
            pending: parseResult.pendingCount,
            limitReached: limitReached,
            isRunning: parseResult.isRunning,
            workflows: parseResult.workflows
        )
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
        reviewThreadEnrichmentInfos: inout [ReviewThreadEnrichmentInfo]
    ) -> PullRequest? {
        guard let databaseId = node.databaseId else { return nil }
        let usernameLower = username?.lowercased()

        let conversationComments = node.comments?.nodes.map { comment in
            IssueCommentSummary(
                id: comment.id,
                author: comment.author?.login ?? "unknown",
                body: comment.body ?? "",
                createdAt: comment.createdAt
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
        if ((upperRollup == "FAILURE" && ciResult.failureCount == 0) ||
            (upperRollup == "PENDING" && ciResult.pendingCount == 0)),
           let pageInfo = statusCheckRollup?.contexts?.pageInfo,
           pageInfo.hasNextPage,
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

        var ciStatus: CIStatus?
        if ciResult.failureCount > 0 {
            ciStatus = .failure
        } else if ciResult.pendingCount > 0 {
            ciStatus = .pending
        } else if ciResult.successCount > 0 {
            ciStatus = .success
        } else if statusCheckRollup != nil {
            ciStatus = .expected
        } else {
            ciStatus = nil
        }

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

        let approvalCount = node.latestReviews?.nodes
            .filter { $0.state == "APPROVED" }
            .count ?? 0

        let changesRequestedCount = node.latestReviews?.nodes
            .filter { $0.state == "CHANGES_REQUESTED" }
            .count ?? 0

        let myThreadsAllResolved: Bool = {
            guard let usernameLower else { return false }
            let myThreads = reviewThreads.filter { thread in
                thread.comments.first?.author.lowercased() == usernameLower
            }
            return !myThreads.isEmpty && myThreads.allSatisfy { $0.isResolved }
        }()

        return PullRequest(
            id: databaseId,
            number: node.number,
            title: node.title,
            author: node.author?.login ?? "unknown",
            authorAvatarURL: node.author?.avatarUrl,
            repositoryOwner: node.repository.owner.login,
            repositoryName: node.repository.name,
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
    }

    func fetchSinglePRCIStatus(owner: String, repo: String, number: Int) async throws -> SinglePRCIResult {
        let query = """
        query {
            repository(owner: "\(owner)", name: "\(repo)") {
                pullRequest(number: \(number)) {
                    commits(last: 1) {
                        nodes {
                            commit {
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
        return try parseSinglePRCIResponse(data: responseData)
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
            return SinglePRCIResult(ciStatus: nil, checkSuccessCount: 0, checkFailureCount: 0, checkPendingCount: 0, ciExtendedInfo: nil)
        }

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

        var ciStatus: CIStatus?
        if ciResult.failureCount > 0 {
            ciStatus = .failure
        } else if ciResult.pendingCount > 0 {
            ciStatus = .pending
        } else if ciResult.successCount > 0 {
            ciStatus = .success
        } else {
            ciStatus = .expected
        }

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
            ciExtendedInfo: ciExtendedInfo
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

        logger.info("Fetching Jira tickets for \(uncached.count) uncached PRs")

        // Batch into groups of 20 to avoid overly large queries
        let batchSize = 20
        for batch in stride(from: 0, to: uncached.count, by: batchSize) {
            let end = min(batch + batchSize, uncached.count)
            let slice = Array(uncached[batch..<end])

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

    /// Selectively rerun failed workflows, skipping workflows in the exclude set.
    /// Groups runs by workflow name and only considers the latest run per workflow.
    /// Returns the names of workflows that were successfully retried.
    func rerunSelectiveFailedWorkflows(owner: String, repo: String, headSHA: String, excludeWorkflows: Set<String>) async throws -> [String] {
        // 1. Fetch workflow runs for this commit
        let runsURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/runs?head_sha=\(headSHA)&per_page=100")!
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

        guard let json = try? JSONSerialization.jsonObject(with: runsData) as? [String: Any],
              let workflowRuns = json["workflow_runs"] as? [[String: Any]] else {
            throw APIError.invalidResponse
        }

        // 2. Group by workflow name, keep the latest run per workflow (highest run_number)
        var latestByWorkflow: [String: [String: Any]] = [:]
        for run in workflowRuns {
            guard let name = run["name"] as? String else { continue }
            let runNumber = run["run_number"] as? Int ?? 0
            if let existing = latestByWorkflow[name],
               let existingNumber = existing["run_number"] as? Int,
               existingNumber >= runNumber {
                continue
            }
            latestByWorkflow[name] = run
        }

        // 3. Filter for latest runs that failed and are not excluded
        var retriedNames: [String] = []
        for (name, run) in latestByWorkflow {
            guard (run["conclusion"] as? String) == "failure",
                  !excludeWorkflows.contains(name),
                  let runId = run["id"] as? Int else { continue }

            let rerunURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/runs/\(runId)/rerun-failed-jobs")!
            var rerunRequest = URLRequest(url: rerunURL)
            rerunRequest.httpMethod = "POST"
            rerunRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            rerunRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            do {
                let (_, rerunResponse) = try await session.data(for: rerunRequest)
                if let rerunHttp = rerunResponse as? HTTPURLResponse, rerunHttp.statusCode == 201 {
                    retriedNames.append(name)
                    logger.info("Selective rerun triggered for workflow '\(name)' (run \(runId))")
                } else if let rerunHttp = rerunResponse as? HTTPURLResponse {
                    logger.warning("Failed to rerun workflow '\(name)' (run \(runId)): HTTP \(rerunHttp.statusCode)")
                }
            } catch {
                logger.warning("Network error rerunning workflow '\(name)': \(error.localizedDescription)")
            }
        }

        return retriedNames
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

// MARK: - GraphQL Response Models

private struct MentionSourceBatchResponse: Decodable {
    let data: BatchData

    struct BatchData: Decodable {
        let nodes: [PRNode]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var collected: [PRNode] = []
            for key in container.allKeys {
                if try container.decodeNil(forKey: key) { continue }
                if let wrapper = try? container.decode(RepositoryWrapper.self, forKey: key),
                   let pr = wrapper.pullRequest {
                    collected.append(pr)
                }
            }
            self.nodes = collected
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
        let databaseId: Int?
        let number: Int
        let updatedAt: Date
        let body: String?
        let repository: Repository
        let comments: IssueCommentsContainer?
        let reviewThreads: ReviewThreadsContainer?
        let crossReferences: CrossReferencesContainer?
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
    }

    struct Owner: Decodable {
        let login: String
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
    }

    struct Author: Decodable {
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
        let nodes: [GraphQLResponse.PRNode]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var collected: [GraphQLResponse.PRNode] = []
            for key in container.allKeys {
                if try container.decodeNil(forKey: key) { continue }
                if let wrapper = try? container.decode(RepositoryWrapper.self, forKey: key),
                   let pr = wrapper.pullRequest {
                    collected.append(pr)
                }
            }
            self.nodes = collected
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

private struct IndexGraphQLResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let authored: SearchResult
        let reviewRequested: SearchResult
        let reviewedBy: SearchResult
        let mergedInvolved: SearchResult
        let rateLimit: RateLimit?
    }

    struct SearchResult: Decodable {
        let nodes: [PRNode]
    }

    struct RateLimit: Decodable {
        let cost: Int
        let remaining: Int
        let resetAt: String?
    }

    struct PRNode: Decodable {
        let databaseId: Int?
        let number: Int
        let title: String
        let url: URL
        let state: String
        let isDraft: Bool
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
        let databaseId: Int?
        let number: Int
        let title: String
        let body: String?
        let url: URL
        let state: String
        let isDraft: Bool
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
    }

    struct Owner: Decodable {
        let login: String
    }

    struct LatestReviewsContainer: Decodable {
        let nodes: [LatestReviewNode]
    }

    struct LatestReviewNode: Decodable {
        let state: String
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
        let databaseId: Int?
        let number: Int
        let title: String
        let body: String?
        let url: URL
        let state: String
        let isDraft: Bool
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
        let crossReferences: CrossReferencesContainer?
    }

    struct Author: Decodable {
        let login: String
        let avatarUrl: URL?
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
    }

    struct Owner: Decodable {
        let login: String
    }

    struct LatestReviewsContainer: Decodable {
        let nodes: [LatestReviewNode]
    }

    struct LatestReviewNode: Decodable {
        let state: String
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

    struct CrossReferencesContainer: Decodable {
        let nodes: [CrossReferenceEventNode]
    }

    struct CrossReferenceEventNode: Decodable {
        let source: ReferencedPullRequest?
        let target: ReferencedPullRequest?
    }

    struct ReferencedPullRequest: Decodable {
        let databaseId: Int?
        let number: Int
        let state: String
        let repository: Repository

        var repoFullName: String {
            "\(repository.owner.login)/\(repository.name)"
        }
    }
}
