import Foundation

struct PRList: Codable {
    var lastUpdated: Date
    var pullRequests: [PullRequest]
    var mergedPullRequests: [PullRequest]
    var isLoading: Bool
    var error: Error?

    // Custom Codable - only encode persistent state, not transient (isLoading, error)
    enum CodingKeys: String, CodingKey {
        case lastUpdated, pullRequests, mergedPullRequests
    }

    init(
        lastUpdated: Date,
        pullRequests: [PullRequest],
        mergedPullRequests: [PullRequest] = [],
        isLoading: Bool,
        error: Error?
    ) {
        self.lastUpdated = lastUpdated
        self.pullRequests = pullRequests
        self.mergedPullRequests = mergedPullRequests
        self.isLoading = isLoading
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        pullRequests = try container.decode([PullRequest].self, forKey: .pullRequests)
        mergedPullRequests = (try? container.decode([PullRequest].self, forKey: .mergedPullRequests)) ?? []
        isLoading = false
        error = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(pullRequests, forKey: .pullRequests)
        try container.encode(mergedPullRequests, forKey: .mergedPullRequests)
    }

    var totalUnresolvedCount: Int {
        pullRequests.reduce(0) { $0 + $1.unresolvedCount }
    }

    var hasUsableData: Bool {
        !pullRequests.isEmpty || !mergedPullRequests.isEmpty
    }

    /// Unresolved comment count for authored PRs only (used for menu bar badge)
    var authoredUnresolvedCount: Int {
        authoredPRs.reduce(0) { $0 + $1.unresolvedCount }
    }

    var authoredPRs: [PullRequest] {
        pullRequests.filter { $0.category == .authored }
    }

    var reviewRequestPRs: [PullRequest] {
        pullRequests.filter { $0.category == .reviewRequest }
    }

    static var empty: PRList {
        PRList(lastUpdated: Date(), pullRequests: [], mergedPullRequests: [], isLoading: false, error: nil)
    }
}

struct IdentifiableError: Identifiable {
    let id = UUID()
    let error: Error

    var localizedDescription: String {
        error.localizedDescription
    }
}
