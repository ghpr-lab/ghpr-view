import Foundation
import SwiftUI

enum FlakyCIProtocolV2 {
    static let protocolName = "ghpr_flaky_ci_analysis"
    static let markerPrefix = "<!-- ghpr-flaky-ci-result:v2:"
    static let externalIDPrefix = "ghpr-flaky-ci:v2:"
    static let checkRunNamePrefix = "Flaky CI Analysis (run "

    static func decodeMarker(from text: String, currentHeadSHA: String? = nil) throws -> FlakyCIAnalysisResultV2? {
        guard let prefixRange = text.range(of: markerPrefix) else { return nil }
        let encodedStart = prefixRange.upperBound
        guard let endRange = text[encodedStart...].range(of: " -->") else { return nil }

        let encoded = String(text[encodedStart..<endRange.lowerBound])
        guard let data = Data(base64URLEncoded: encoded) else { return nil }
        let result = try JSONDecoder.githubDecoder.decode(FlakyCIAnalysisResultV2.self, from: data)
        guard result.schemaVersion == 2, result.protocolName == protocolName else { return nil }

        if let currentHeadSHA, result.target.headSHA.lowercased() != currentHeadSHA.lowercased() {
            return result.withStatus(.stale)
        }
        return result
    }

    static func isFlakyCheckRun(name: String?, externalID: String?) -> Bool {
        if externalID?.hasPrefix(externalIDPrefix) == true { return true }
        return name?.hasPrefix(checkRunNamePrefix) == true
    }
}

enum FlakyCIClassification: String, Codable, Equatable {
    case likelyFlaky = "likely_flaky"
    case likelyBlocker = "likely_blocker"
    case investigate
}

enum FlakyCIAnalysisStatus: String, Codable, Equatable {
    case queued
    case inProgress = "in_progress"
    case completed
    case stale
    case error
}

enum FlakyCIConfidence: String, Codable, Equatable {
    case low
    case medium
    case high
}

enum FlakyCIActionID: String, Codable, Equatable {
    case rerunFailedJobs = "rerun_failed_jobs"
    case openFailedRun = "open_failed_run"
    case openCheckRun = "open_check_run"
    case openArtifact = "open_artifact"
    case openPRComment = "open_pr_comment"
    case analyzeAgain = "analyze_again"
    case investigateManually = "investigate_manually"
}

struct FlakyCIAnalysisResultV2: Codable, Equatable {
    let schemaVersion: Int
    let protocolName: String
    let analysisID: String
    let requestID: String
    let backend: Backend
    let status: FlakyCIAnalysisStatus
    let classification: FlakyCIClassification
    let flakyScore: Int
    let relatednessScore: Double
    let confidence: FlakyCIConfidence
    let historyInfluenced: Bool
    let target: Target
    let failedJobs: [FlakyCIJobResult]
    let summary: Summary
    let evidence: [FlakyCIEvidence]
    let suggestedActions: [FlakyCIAction]
    let links: Links?
    let timestamps: Timestamps

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case protocolName = "protocol"
        case analysisID = "analysis_id"
        case requestID = "request_id"
        case backend
        case status
        case classification
        case flakyScore = "flaky_score"
        case relatednessScore = "relatedness_score"
        case confidence
        case historyInfluenced = "history_influenced"
        case target
        case failedJobs = "failed_jobs"
        case summary
        case evidence
        case suggestedActions = "suggested_actions"
        case links
        case timestamps
    }

    func withStatus(_ replacement: FlakyCIAnalysisStatus) -> FlakyCIAnalysisResultV2 {
        FlakyCIAnalysisResultV2(
            schemaVersion: schemaVersion,
            protocolName: protocolName,
            analysisID: analysisID,
            requestID: requestID,
            backend: backend,
            status: replacement,
            classification: classification,
            flakyScore: flakyScore,
            relatednessScore: relatednessScore,
            confidence: confidence,
            historyInfluenced: historyInfluenced,
            target: target,
            failedJobs: failedJobs,
            summary: summary,
            evidence: evidence,
            suggestedActions: suggestedActions,
            links: links,
            timestamps: timestamps
        )
    }

    func reportState(currentHeadSHA: String?) -> FlakyCIBotReportState {
        if let currentHeadSHA, target.headSHA.lowercased() != currentHeadSHA.lowercased() {
            return .outdated
        }

        switch status {
        case .queued, .inProgress:
            return .analyzing
        case .stale:
            return .outdated
        case .error:
            return .needsInvestigation(score: flakyScore)
        case .completed:
            switch classification {
            case .likelyFlaky:
                return .likelyFlaky(score: flakyScore)
            case .likelyBlocker:
                return .realIssue(score: max(0, 100 - flakyScore))
            case .investigate:
                return .needsInvestigation(score: flakyScore)
            }
        }
    }

    struct Backend: Codable, Equatable {
        let kind: String
        let version: String
    }

    struct Target: Codable, Equatable {
        let ciProvider: String
        let runID: Int
        let workflowName: String?
        let headSHA: String

        enum CodingKeys: String, CodingKey {
            case ciProvider = "ci_provider"
            case runID = "run_id"
            case workflowName = "workflow_name"
            case headSHA = "head_sha"
        }
    }

    struct Summary: Codable, Equatable {
        let title: String
        let evidenceLine: String
        let detail: String

        enum CodingKeys: String, CodingKey {
            case title
            case evidenceLine = "evidence_line"
            case detail
        }
    }

    struct Links: Codable, Equatable {
        let checkRunURL: URL?
        let workflowRunURL: URL?
        let artifactURL: URL?

        enum CodingKeys: String, CodingKey {
            case checkRunURL = "check_run_url"
            case workflowRunURL = "workflow_run_url"
            case artifactURL = "artifact_url"
        }
    }

    struct Timestamps: Codable, Equatable {
        let createdAt: Date
        let completedAt: Date?

        enum CodingKeys: String, CodingKey {
            case createdAt = "created_at"
            case completedAt = "completed_at"
        }
    }
}

struct FlakyCIJobResult: Codable, Equatable {
    let jobID: Int
    let jobName: String
    let conclusion: String?
    let failureSignature: String
    let history: FlakyCIHistory

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case jobName = "job_name"
        case conclusion
        case failureSignature = "failure_signature"
        case history
    }
}

struct FlakyCIHistory: Codable, Equatable {
    let mainMatches: Int
    let mainSampled: Int
    let prMatches: Int
    let prSampled: Int
    let sampleRunURLs: [URL]

    enum CodingKeys: String, CodingKey {
        case mainMatches = "main_matches"
        case mainSampled = "main_sampled"
        case prMatches = "pr_matches"
        case prSampled = "pr_sampled"
        case sampleRunURLs = "sample_run_urls"
    }
}

struct FlakyCIEvidence: Codable, Equatable {
    let kind: String
    let message: String
    let url: URL?
}

struct FlakyCIAction: Codable, Equatable {
    let id: FlakyCIActionID
    let label: String
    let enabled: Bool
    let url: URL?
}

struct FlakyCIAnalysisCheckRun: Codable, Equatable {
    let databaseID: Int
    let name: String
    let status: String?
    let conclusion: String?
    let detailsURL: URL?
    let externalID: String?
    let completedAt: Date?

    var isCompleted: Bool {
        status?.uppercased() == "COMPLETED"
    }

    var reportState: FlakyCIBotReportState? {
        switch status?.uppercased() {
        case "QUEUED", "IN_PROGRESS", "REQUESTED", "WAITING", "PENDING":
            return .analyzing
        default:
            return nil
        }
    }
}

extension FlakyCIBotReportState {
    var accentColor: Color {
        switch self {
        case .likelyFlaky:
            return Color(nsColor: NSColor(calibratedRed: 0.73, green: 0.50, blue: 0.12, alpha: 1))
        case .realIssue:
            return Color(nsColor: NSColor(calibratedRed: 0.73, green: 0.25, blue: 0.22, alpha: 1))
        case .needsInvestigation:
            return Color(nsColor: NSColor(calibratedRed: 0.44, green: 0.38, blue: 0.28, alpha: 1))
        case .analyzing:
            return Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.44, blue: 0.79, alpha: 1))
        case .outdated:
            return .secondary
        }
    }
}

private extension Data {
    init?(base64URLEncoded input: String) {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}

