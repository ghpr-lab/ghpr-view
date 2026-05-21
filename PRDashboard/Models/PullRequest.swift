import Foundation

enum PRCategory: String, Codable {
    case authored       // PRs created by user
    case reviewRequest  // PRs where user is requested reviewer
    case mentioned      // PRs related via body/comments/cross references
}

enum PRState: String, Codable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}

enum CIStatus: String, Codable {
    case success = "SUCCESS"
    case pending = "PENDING"
    case failure = "FAILURE"
    case expected = "EXPECTED"
    case unknown = "UNKNOWN"  // GitHub says FAILURE but we reached limit without finding failures
}

/// GitHub review state from API
enum ReviewState: String, Codable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case pending = "PENDING"
    case dismissed = "DISMISSED"
}

/// Display status for my review on review-requested PRs
enum MyReviewStatus: String, Codable {
    case waiting           // No review or COMMENTED/PENDING/DISMISSED
    case changesRequested  // CHANGES_REQUESTED, not resolved
    case changesResolved   // CHANGES_REQUESTED but newer commit pushed
    case approved          // APPROVED
}

struct CIWorkflowInfo: Codable, Equatable {
    let name: String
    let isWorkflow: Bool  // true = GitHub Actions workflow, false = standalone check/status
    var successCount: Int
    var failureCount: Int
    var pendingCount: Int

    var totalCount: Int { successCount + failureCount + pendingCount }

    var status: CIStatus {
        if failureCount > 0 { return .failure }
        if pendingCount > 0 { return .pending }
        if successCount > 0 { return .success }
        return .expected
    }
}

struct CIExtendedInfo: Codable, Equatable {
    var isRunning: Bool
    var workflows: [CIWorkflowInfo]
}

struct IssueCommentSummary: Identifiable, Codable, Equatable {
    let id: String
    let author: String
    let body: String
    let createdAt: Date
}

struct PullRequestReference: Hashable, Codable {
    let owner: String
    let repo: String
    let number: Int

    var repoFullName: String {
        "\(owner)/\(repo)"
    }
}

struct PullRequest: Identifiable, Codable, Equatable {
    let id: Int
    var graphqlNodeId: String? = nil
    let number: Int
    let title: String
    let author: String
    let authorAvatarURL: URL?
    let repositoryOwner: String
    let repositoryName: String
    let url: URL
    let state: PRState
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let mergedAt: Date?
    let body: String?
    let conversationComments: [IssueCommentSummary]
    var lastCommitAt: Date?
    var headCommitOid: String?
    var baseRefName: String? = nil
    var headRefName: String? = nil
    var baseNeedsUpdate: Bool? = nil
    var approvalAuthors: [String]? = nil
    var changesRequestedAuthors: [String]? = nil
    var reviewThreads: [ReviewThread]
    let category: PRCategory
    let hasBaseConflicts: Bool
    var ciStatus: CIStatus?
    var checkSuccessCount: Int
    var checkFailureCount: Int
    var checkPendingCount: Int
    var githubCIState: String?  // Raw state from GitHub: "SUCCESS", "FAILURE", "PENDING", etc.
    var myLastReviewState: ReviewState?
    var myLastReviewAt: Date?
    var reviewRequestedAt: Date?
    var myThreadsAllResolved: Bool
    var approvalCount: Int
    var changesRequestedCount: Int?
    var ciExtendedInfo: CIExtendedInfo?
    var jiraTicket: String? = nil
    var jiraTitle: String? = nil
    var jiraLabels: [String]? = nil
    var jiraStatusName: String? = nil
    var jiraStatusCategoryKey: String? = nil
    var jiraUpdatedAt: Date? = nil
    var jiraMetadataFetchedAt: Date? = nil
    var isOpenInCmux: Bool? = nil

    var ciIsRunning: Bool { ciExtendedInfo?.isRunning ?? false }
    var ciWorkflows: [CIWorkflowInfo] { ciExtendedInfo?.workflows ?? [] }
    var failedWorkflowNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for workflow in ciWorkflows where workflow.isWorkflow && workflow.status == .failure {
            guard seen.insert(workflow.name.lowercased()).inserted else { continue }
            result.append(workflow.name)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    var ciIsInFlight: Bool {
        ciStatus == .pending || checkPendingCount > 0 || ciIsRunning
    }

    var checkTotalCount: Int {
        checkSuccessCount + checkFailureCount + checkPendingCount
    }

    var unresolvedCount: Int {
        reviewThreads.lazy.filter(\.isUnresolved).count
    }

    var unreadUnresolvedCount: Int {
        reviewThreads.lazy.filter(\.isUnreadUnresolved).count
    }

    var readUnresolvedCount: Int {
        reviewThreads.lazy.filter(\.isReadUnresolved).count
    }

    var repoFullName: String {
        "\(repositoryOwner)/\(repositoryName)"
    }

    var hasHoverDetailMetadata: Bool {
        graphqlNodeId != nil &&
            baseRefName != nil &&
            headRefName != nil
    }

    /// Stable identifier used for pinning (e.g. "owner/repo#123")
    var pinIdentifier: String {
        "\(repoFullName)#\(number)"
    }

    /// Computed review status for review-requested PRs (returns nil for authored PRs)
    var myReviewStatus: MyReviewStatus? {
        guard category == .reviewRequest else { return nil }
        guard let state = myLastReviewState else { return .waiting }

        switch state {
        case .approved:
            return .approved
        case .changesRequested:
            // Condition 1: All my threads are resolved
            if myThreadsAllResolved {
                return .changesResolved
            }
            // Condition 2: New commit pushed after our review
            if let reviewedAt = myLastReviewAt,
               let commitAt = lastCommitAt,
               commitAt > reviewedAt {
                return .changesResolved
            }
            // Condition 3: Re-requested for review after our last review
            if let requestedAt = reviewRequestedAt,
               let reviewedAt = myLastReviewAt,
               requestedAt > reviewedAt {
                return .changesResolved
            }
            return .changesRequested
        case .dismissed:
            // DISMISSED means my review was resolved/dismissed by author or others
            return .changesResolved
        case .commented, .pending:
            return .waiting
        }
    }

    static func == (lhs: PullRequest, rhs: PullRequest) -> Bool {
        lhs.id == rhs.id
    }
}
