import Darwin
import Foundation

enum LocalAPIProtocol {
    static let schemaVersion = 2
}

enum LocalAPICommand: String, CaseIterable, Codable {
    case ping
    case snapshot
    case pr
}

struct LocalAPIRequest: Codable, Equatable {
    let command: String
    let repository: String?
    let number: Int?

    init(
        command: LocalAPICommand,
        repository: String? = nil,
        number: Int? = nil
    ) {
        self.command = command.rawValue
        self.repository = repository
        self.number = number
    }

    init(
        command: String,
        repository: String? = nil,
        number: Int? = nil
    ) {
        self.command = command
        self.repository = repository
        self.number = number
    }
}

enum LocalAPIErrorCode: String, Codable {
    case invalidRequest = "invalid_request"
    case unsupportedCommand = "unsupported_command"
    case internalError = "internal_error"
    case unauthorizedPeer = "unauthorized_peer"
    case notFound = "not_found"
}

struct LocalAPIErrorPayload: Codable, Equatable {
    let code: String
    let message: String
}

struct LocalAPIResponse: Codable, Equatable {
    let schemaVersion: Int
    let ok: Bool
    let snapshot: LocalSnapshot?
    let pullRequest: LocalPRSnapshot?
    let error: LocalAPIErrorPayload?

    static func success(
        snapshot: LocalSnapshot? = nil,
        pullRequest: LocalPRSnapshot? = nil
    ) -> LocalAPIResponse {
        LocalAPIResponse(
            schemaVersion: LocalAPIProtocol.schemaVersion,
            ok: true,
            snapshot: snapshot,
            pullRequest: pullRequest,
            error: nil
        )
    }

    static func failure(code: LocalAPIErrorCode, message: String) -> LocalAPIResponse {
        LocalAPIResponse(
            schemaVersion: LocalAPIProtocol.schemaVersion,
            ok: false,
            snapshot: nil,
            pullRequest: nil,
            error: LocalAPIErrorPayload(code: code.rawValue, message: message)
        )
    }
}

enum LocalAPIHandler {
    static func response(
        for request: LocalAPIRequest,
        snapshotProvider: () -> LocalSnapshot
    ) -> LocalAPIResponse {
        guard let command = LocalAPICommand(rawValue: request.command) else {
            return .failure(
                code: .unsupportedCommand,
                message: "Unsupported command: \(request.command)"
            )
        }

        switch command {
        case .ping:
            return .success()
        case .snapshot:
            return .success(snapshot: snapshotProvider())
        case .pr:
            guard let repository = request.repository?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !repository.isEmpty,
                  let number = request.number else {
                return .failure(
                    code: .invalidRequest,
                    message: "pr command requires 'repository' and 'number'."
                )
            }
            let snapshot = snapshotProvider()
            guard let match = findPullRequest(in: snapshot, repository: repository, number: number) else {
                return .failure(
                    code: .notFound,
                    message: "No PR found for \(repository)#\(number)."
                )
            }
            return .success(pullRequest: match)
        }
    }

    static func findPullRequest(
        in snapshot: LocalSnapshot,
        repository: String,
        number: Int
    ) -> LocalPRSnapshot? {
        let sections = [
            snapshot.pullRequests.authored,
            snapshot.pullRequests.reviewRequests,
            snapshot.pullRequests.mentioned,
            snapshot.pullRequests.directMentions,
            snapshot.pullRequests.mergedLast24h
        ]
        for section in sections {
            if let match = section.first(where: {
                $0.repository.caseInsensitiveCompare(repository) == .orderedSame &&
                $0.number == number
            }) {
                return match
            }
        }
        return nil
    }
}

enum LocalAPIJSON {
    static func encode<T: Encodable>(_ value: T, prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

enum LocalSocketPath {
    static let environmentVariable = "GHPR_SOCKET_PATH"

    static func defaultPath(uid: uid_t = getuid()) -> String {
        "/tmp/com.xiaocang.PRDashboard.\(uid).sock"
    }

    static func resolvedPath(environment: [String: String]) -> String {
        guard let override = environment[environmentVariable],
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultPath()
        }
        return override
    }
}

struct LocalSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let app: LocalAppSnapshot
    let auth: LocalAuthSnapshot
    let refresh: LocalRefreshSnapshot
    let rateLimit: LocalRateLimitSnapshot
    let summary: LocalSummarySnapshot
    let pullRequests: LocalPRSectionsSnapshot
}

struct LocalAppSnapshot: Codable, Equatable {
    let version: String
    let build: String
    let bundleIdentifier: String
}

struct LocalAuthSnapshot: Codable, Equatable {
    let isAuthenticated: Bool
    let username: String?
    let method: String?
}

struct LocalRefreshSnapshot: Codable, Equatable {
    let status: String
    let isLoading: Bool
    let lastUpdated: Date
    let error: String?
}

struct LocalRateLimitSnapshot: Codable, Equatable {
    let limit: Int
    let remaining: Int
    let resetAt: Date
    let isLow: Bool
}

struct LocalSummarySnapshot: Codable, Equatable {
    let authored: Int
    let reviewRequests: Int
    let mentioned: Int
    let directMentions: Int
    let mergedLast24h: Int
    let totalUnresolved: Int
    let authoredUnresolved: Int
    let readyToMerge: Int
    let changesRequested: Int
    let ciFailing: Int
    let ciRunning: Int
    let waitingForMyReview: Int
}

struct LocalPRSectionsSnapshot: Codable, Equatable {
    let authored: [LocalPRSnapshot]
    let reviewRequests: [LocalPRSnapshot]
    let mentioned: [LocalPRSnapshot]
    let directMentions: [LocalPRSnapshot]
    let mergedLast24h: [LocalPRSnapshot]
}

enum LocalPRSection: String, Codable, CaseIterable {
    case authored
    case review
    case mentioned
    case directMentions
    case merged
}

struct LocalPRSnapshot: Codable, Equatable {
    let id: Int
    let section: LocalPRSection
    let repository: String
    let number: Int
    let title: String
    let author: String
    let url: String
    let state: String
    let isDraft: Bool
    let isPinned: Bool
    let hasBaseConflicts: Bool
    let unresolvedCount: Int
    let ciStatus: String?
    let checkSuccessCount: Int
    let checkFailureCount: Int
    let checkPendingCount: Int
    let ciIsRunning: Bool
    let approvalCount: Int
    let changesRequestedCount: Int?
    let myReviewStatus: String?
    let jiraTicket: String?
    let ciWorkflows: [LocalCIWorkflowSnapshot]?
    let updatedAt: Date
    let mergedAt: Date?
}

struct LocalCIWorkflowSnapshot: Codable, Equatable {
    let name: String
    let isWorkflow: Bool
    let successCount: Int
    let failureCount: Int
    let pendingCount: Int
}
