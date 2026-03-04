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

    static var empty: RateLimitInfo {
        RateLimitInfo(limit: 5000, remaining: 5000, resetDate: Date())
    }
}

enum APIError: LocalizedError {
    case unauthorized
    case rateLimited(resetDate: Date)
    case network(Error)
    case decoding(Error)
    case invalidResponse
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Invalid GitHub token. Please check your settings."
        case .rateLimited(let resetDate):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Rate limited. Try again after \(formatter.string(from: resetDate))"
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from GitHub"
        case .unknown(let message):
            return message
        }
    }
}

final class GitHubAPIClient: ObservableObject {
    private static let maxCIContextsToFetch = 200
    private let graphQLURL = URL(string: "https://api.github.com/graphql")!
    private var token: String
    private let session: URLSession
    private var lastETag: String?

    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty

    init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func updateToken(_ newToken: String) {
        self.token = newToken
    }

    func fetchPullRequests(username: String, searchQuery: String, category: PRCategory) async throws -> [PullRequest] {
        let query = buildGraphQLQuery(searchQuery: searchQuery)
        let responseData = try await executeGraphQL(query: query)
        return try parseSearchResponse(data: responseData, category: category)
    }

    struct CombinedPRResult {
        let openPRs: [PullRequest]
        let mergedPRs: [PullRequest]
    }

    func fetchAllPullRequests(username: String) async throws -> CombinedPRResult {
        // Combined query using GraphQL aliases - single API call instead of 4
        let query = buildCombinedQuery(username: username)
        let responseData = try await executeGraphQL(query: query)
        return try await parseCombinedResponse(data: responseData, username: username)
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
            _ = try await executeGraphQL(query: query)
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

        let responseData = try await executeGraphQL(query: query)
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

    private func buildCombinedQuery(username: String) -> String {
        let prFragment = """
                nodes {
                    ... on PullRequest {
                        databaseId
                        number
                        title
                        url
                        state
                        isDraft
                        createdAt
                        updatedAt
                        mergedAt
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
                        reviews(author: "\(username)", last: 1) {
                            nodes {
                                state
                                submittedAt
                            }
                        }
                        latestReviews(first: 20) {
                            nodes {
                                state
                            }
                        }
                        timelineItems(last: 10, itemTypes: [REVIEW_REQUESTED_EVENT]) {
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
                    }
                }
        """

        let mergedSince = Self.dateStringForSearch(daysBack: 2)

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
        }
        """
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
                        databaseId
                        number
                        title
                        url
                        state
                        isDraft
                        createdAt
                        updatedAt
                        mergedAt
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

    private func executeGraphQL(query: String) async throws -> Data {
        var request = URLRequest(url: graphQLURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let body = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // Parse rate limit headers
        if let limitStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Limit"),
           let remainingStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let resetStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"),
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

        switch httpResponse.statusCode {
        case 200:
            // Check for GraphQL errors in response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = json["errors"] as? [[String: Any]],
               let firstError = errors.first,
               let message = firstError["message"] as? String {
                throw APIError.unknown(message)
            }
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            // Check for rate limiting
            if let resetTime = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"),
               let timestamp = TimeInterval(resetTime) {
                let resetDate = Date(timeIntervalSince1970: timestamp)
                throw APIError.rateLimited(resetDate: resetDate)
            }
            throw APIError.unauthorized
        default:
            throw APIError.unknown("HTTP \(httpResponse.statusCode)")
        }
    }

    private func parseSearchResponse(data: Data, category: PRCategory) throws -> [PullRequest] {
        let decoder = JSONDecoder.githubDecoder

        do {
            let response = try decoder.decode(GraphQLResponse.self, from: data)
            return response.data.search.nodes.compactMap { node in
                guard let databaseId = node.databaseId else { return nil }

                let reviewThreads = node.reviewThreads?.nodes.map { thread -> ReviewThread in
                    let comments = thread.comments.nodes.map { comment -> ReviewComment in
                        ReviewComment(
                            id: comment.id,
                            author: comment.author?.login ?? "unknown",
                            body: comment.body,
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

                // Extract CI status and counts from the last commit
                let lastCommit = node.commits?.nodes.first?.commit
                let statusCheckRollup = lastCommit?.statusCheckRollup
                let lastCommitAt = lastCommit?.committedDate

                // Parse CI contexts using shared helper
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
                let excludeFilter = Self.loadCIStatusExcludeFilter()
                let ciResult = Self.parseCIContexts(ciContexts, excludeFilter: excludeFilter)

                // Derive CI status from our counts (not GitHub's rollup which may include excluded checks)
                let rollupState = statusCheckRollup?.state
                let ciStatus: CIStatus?
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

                let approvalCount = node.latestReviews?.nodes
                    .filter { $0.state == "APPROVED" }
                    .count ?? 0

                let changesRequestedCount = node.latestReviews?.nodes
                    .filter { $0.state == "CHANGES_REQUESTED" }
                    .count ?? 0

                let ciExtendedInfo: CIExtendedInfo? = ciResult.workflows.isEmpty ? nil : CIExtendedInfo(
                    isRunning: ciResult.isRunning,
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
                    lastCommitAt: lastCommitAt,
                    headCommitOid: lastCommit?.oid,
                    reviewThreads: reviewThreads,
                    category: category,
                    ciStatus: ciStatus,
                    checkSuccessCount: ciResult.successCount,
                    checkFailureCount: ciResult.failureCount,
                    checkPendingCount: ciResult.pendingCount,
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
        } catch {
            throw APIError.decoding(error)
        }
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

    private func parseCombinedResponse(data: Data, username: String) async throws -> CombinedPRResult {
        let decoder = JSONDecoder.githubDecoder

        do {
            let response = try decoder.decode(CombinedGraphQLResponse.self, from: data)

            logger.info("Raw response node counts - authored: \(response.data.authored.nodes.count), reviewRequested: \(response.data.reviewRequested.nodes.count), reviewedBy: \(response.data.reviewedBy.nodes.count), mergedInvolved: \(response.data.mergedInvolved.nodes.count)")

            // Log first few merged nodes for debugging
            for (idx, node) in response.data.mergedInvolved.nodes.prefix(3).enumerated() {
                logger.debug("mergedInvolved[\(idx)]: #\(node.number) databaseId=\(node.databaseId.map { String($0) } ?? "nil") state=\(node.state) mergedAt=\(node.mergedAt.map { String(describing: $0) } ?? "nil")")
            }

            // Collect enrichment info from all nodes
            var enrichmentInfos: [CIEnrichmentInfo] = []
            var reviewThreadEnrichmentInfos: [ReviewThreadEnrichmentInfo] = []

            // Parse authored PRs
            var authoredPRs = parseNodes(response.data.authored.nodes, category: .authored, enrichmentInfos: &enrichmentInfos, reviewThreadEnrichmentInfos: &reviewThreadEnrichmentInfos)

            // Parse review requested PRs
            var reviewRequestedPRs = parseNodes(response.data.reviewRequested.nodes, category: .reviewRequest, enrichmentInfos: &enrichmentInfos, reviewThreadEnrichmentInfos: &reviewThreadEnrichmentInfos)

            // Parse reviewed-by PRs (PRs user has already reviewed)
            var reviewedByPRs = parseNodes(response.data.reviewedBy.nodes, category: .reviewRequest, enrichmentInfos: &enrichmentInfos, reviewThreadEnrichmentInfos: &reviewThreadEnrichmentInfos)

            // Parse merged PRs where user is involved (author or reviewer)
            // Determine category based on whether user is author
            var mergedInvolvedPRs = parseNodes(
                response.data.mergedInvolved.nodes,
                category: .reviewRequest,
                usernameForAuthoredCheck: username,
                enrichmentInfos: &enrichmentInfos,
                reviewThreadEnrichmentInfos: &reviewThreadEnrichmentInfos
            )
            logger.info("Parsed mergedInvolvedPRs count: \(mergedInvolvedPRs.count)")

            // Enrich PRs where rollup state disagrees with first-page counts (e.g. FAILURE/PENDING not found in first 20 contexts)
            if !enrichmentInfos.isEmpty {
                logger.info("Need to fetch additional CI contexts for \(enrichmentInfos.count) PRs")
                let enrichedCounts = await fetchAllAdditionalCIContexts(enrichmentInfos: enrichmentInfos)

                // Update PR counts with enriched data (add to existing counts from first page)
                func updatePRs(_ prs: inout [PullRequest]) {
                    prs = prs.map { pr in
                        guard let counts = enrichedCounts[pr.id] else { return pr }
                        var updated = pr
                        updated.checkSuccessCount += counts.success
                        updated.checkFailureCount += counts.failure
                        updated.checkPendingCount += counts.pending
                        // Re-derive CI status based on total counts
                        if updated.checkFailureCount > 0 {
                            updated.ciStatus = .failure
                        } else if updated.checkPendingCount > 0 {
                            updated.ciStatus = .pending
                        } else if updated.checkSuccessCount > 0 {
                            updated.ciStatus = .success
                        } else if counts.limitReached && updated.githubCIState?.uppercased() == "FAILURE" {
                            // GitHub says FAILURE but we hit limit without finding failures
                            updated.ciStatus = .unknown
                            logger.info("PR \(updated.id) set to unknown: GitHub says FAILURE but limit reached without finding failures")
                        }
                        // Merge workflow data from enrichment into existing ciExtendedInfo
                        if !counts.workflows.isEmpty {
                            var mergedWorkflows = updated.ciExtendedInfo?.workflows.reduce(into: [String: CIWorkflowInfo]()) {
                                $0[$1.name] = $1
                            } ?? [:]
                            for (key, wf) in counts.workflows {
                                if var existing = mergedWorkflows[key] {
                                    existing.successCount += wf.successCount
                                    existing.failureCount += wf.failureCount
                                    existing.pendingCount += wf.pendingCount
                                    mergedWorkflows[key] = existing
                                } else {
                                    mergedWorkflows[key] = wf
                                }
                            }
                            let isRunning = (updated.ciExtendedInfo?.isRunning ?? false) || counts.isRunning
                            updated.ciExtendedInfo = CIExtendedInfo(
                                isRunning: isRunning,
                                workflows: Array(mergedWorkflows.values)
                            )
                        }
                        return updated
                    }
                }

                updatePRs(&authoredPRs)
                updatePRs(&reviewRequestedPRs)
                updatePRs(&reviewedByPRs)
                updatePRs(&mergedInvolvedPRs)
            }

            // Enrich PRs that have more review threads beyond the first page
            if !reviewThreadEnrichmentInfos.isEmpty {
                logger.info("Need to fetch additional review threads for \(reviewThreadEnrichmentInfos.count) PRs")
                let additionalThreads = await fetchAllAdditionalReviewThreads(enrichmentInfos: reviewThreadEnrichmentInfos)

                func enrichReviewThreads(_ prs: inout [PullRequest]) {
                    prs = prs.map { pr in
                        guard let extra = additionalThreads[pr.id] else { return pr }
                        var updated = pr
                        updated.reviewThreads = extra + pr.reviewThreads
                        return updated
                    }
                }

                enrichReviewThreads(&authoredPRs)
                enrichReviewThreads(&reviewRequestedPRs)
                enrichReviewThreads(&reviewedByPRs)
                enrichReviewThreads(&mergedInvolvedPRs)
            }

            // Combine review requested and reviewed-by, deduplicating by ID
            var reviewPRsById: [Int: PullRequest] = [:]
            for pr in reviewRequestedPRs {
                reviewPRsById[pr.id] = pr
            }
            for pr in reviewedByPRs {
                if reviewPRsById[pr.id] == nil {
                    reviewPRsById[pr.id] = pr
                }
            }

            // Combine open PRs and sort by updatedAt (most recent first)
            let openPRs = authoredPRs + Array(reviewPRsById.values)

            // Deduplicate merged results, keep only last 24h by mergedAt, and sort by mergedAt/updatedAt
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            var mergedById: [Int: PullRequest] = [:]
            for pr in mergedInvolvedPRs {
                guard let mergedAt = pr.mergedAt, mergedAt >= cutoff else { continue }
                mergedById[pr.id] = pr
            }
            let mergedPRs = Array(mergedById.values).sorted { ($0.mergedAt ?? $0.updatedAt) > ($1.mergedAt ?? $1.updatedAt) }

            return CombinedPRResult(
                openPRs: openPRs.sorted { $0.updatedAt > $1.updatedAt },
                mergedPRs: mergedPRs
            )
        } catch {
            throw APIError.decoding(error)
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

        let responseData = try await executeGraphQL(query: query)
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
        let usernameLower = usernameForAuthoredCheck?.lowercased()
        return nodes.compactMap { node in
            guard let databaseId = node.databaseId else { return nil }

            let reviewThreads = node.reviewThreads?.nodes.map { thread -> ReviewThread in
                let comments = thread.comments.nodes.map { comment -> ReviewComment in
                    ReviewComment(
                        id: comment.id,
                        author: comment.author?.login ?? "unknown",
                        body: comment.body,
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

            // Check if we need to fetch more review threads
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

            // Extract CI status and counts from the last commit
            let lastCommit = node.commits?.nodes.first?.commit
            let statusCheckRollup = lastCommit?.statusCheckRollup
            let lastCommitAt = lastCommit?.committedDate

            // Parse CI contexts using shared helper
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
            let excludeFilter = Self.loadCIStatusExcludeFilter()
            let ciResult = Self.parseCIContexts(ciContexts, excludeFilter: excludeFilter)

            // Check if we need to fetch more CI contexts:
            // - Rollup state disagrees with first-page counts (FAILURE with no failures, or PENDING with no pending)
            // - And there are more pages to fetch
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

            // Derive CI status from our counts (not GitHub's rollup which may include excluded checks)
            let ciStatus: CIStatus?
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

            let ciExtendedInfo: CIExtendedInfo? = ciResult.workflows.isEmpty ? nil : CIExtendedInfo(
                isRunning: ciResult.isRunning,
                workflows: Array(ciResult.workflows.values)
            )

            // Determine category - if username provided, check if user is author
            let resolvedCategory: PRCategory
            if let usernameLower {
                if node.author?.login.lowercased() == usernameLower {
                    resolvedCategory = .authored
                } else {
                    resolvedCategory = category
                }
            } else {
                resolvedCategory = category
            }

            // Extract my review data
            let lastReview = node.reviews?.nodes.first
            let myLastReviewState: ReviewState? = lastReview.flatMap { ReviewState(rawValue: $0.state) }
            let myLastReviewAt: Date? = lastReview?.submittedAt

            // Extract the most recent review request for the current user
            let reviewRequestedAt: Date? = node.timelineItems?.nodes
                .filter { $0.requestedReviewer?.login?.lowercased() == usernameLower }
                .compactMap { $0.createdAt }
                .max()

            // Count approvals from latestReviews
            let approvalCount = node.latestReviews?.nodes
                .filter { $0.state == "APPROVED" }
                .count ?? 0

            let changesRequestedCount = node.latestReviews?.nodes
                .filter { $0.state == "CHANGES_REQUESTED" }
                .count ?? 0

            // Check if all threads started by user are resolved
            let myThreadsAllResolved: Bool = {
                guard let usernameLower else { return false }
                let myThreads = reviewThreads.filter { thread in
                    thread.comments.first?.author.lowercased() == usernameLower
                }
                // If no threads started by user, don't consider it "resolved" (vacuously true would be misleading)
                // Only return true if user has threads AND all are resolved
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
                lastCommitAt: lastCommitAt,
                headCommitOid: lastCommit?.oid,
                reviewThreads: reviewThreads,
                category: resolvedCategory,
                ciStatus: ciStatus,
                checkSuccessCount: ciResult.successCount,
                checkFailureCount: ciResult.failureCount,
                checkPendingCount: ciResult.pendingCount,
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

        let responseData = try await executeGraphQL(query: query)
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

        let ciStatus: CIStatus?
        if ciResult.failureCount > 0 {
            ciStatus = .failure
        } else if ciResult.pendingCount > 0 {
            ciStatus = .pending
        } else if ciResult.successCount > 0 {
            ciStatus = .success
        } else {
            ciStatus = .expected
        }

        let ciExtendedInfo: CIExtendedInfo? = ciResult.workflows.isEmpty ? nil : CIExtendedInfo(
            isRunning: ciResult.isRunning,
            workflows: Array(ciResult.workflows.values)
        )

        return SinglePRCIResult(
            ciStatus: ciStatus,
            checkSuccessCount: ciResult.successCount,
            checkFailureCount: ciResult.failureCount,
            checkPendingCount: ciResult.pendingCount,
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
            throw APIError.unknown("Failed to fetch workflow runs: HTTP \(httpResponse.statusCode)")
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

    private static let jiraTicketRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "[A-Z][A-Z0-9]+-\\d+")
        } catch {
            fatalError("Invalid Jira ticket regex: \(error)")
        }
    }()

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
                let responseData = try await executeGraphQL(query: query)
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
            throw APIError.unknown("Failed to fetch workflow runs: HTTP \(httpResponse.statusCode)")
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
        let url: URL
        let state: String
        let isDraft: Bool
        let createdAt: Date
        let updatedAt: Date
        let mergedAt: Date?
        let author: Author?
        let repository: Repository
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
        let body: String
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
        let url: URL
        let state: String
        let isDraft: Bool
        let createdAt: Date
        let updatedAt: Date
        let mergedAt: Date?
        let author: Author?
        let repository: Repository
        let reviewThreads: ReviewThreadsContainer?
        let commits: CommitsContainer?
        let reviews: ReviewsContainer?
        let latestReviews: LatestReviewsContainer?
        let timelineItems: TimelineItemsContainer?
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
        let body: String
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

    struct TimelineItemsContainer: Decodable {
        let nodes: [TimelineItemNode]
    }

    struct TimelineItemNode: Decodable {
        let createdAt: Date?
        let requestedReviewer: RequestedReviewer?
    }

    struct RequestedReviewer: Decodable {
        let login: String?
    }
}
