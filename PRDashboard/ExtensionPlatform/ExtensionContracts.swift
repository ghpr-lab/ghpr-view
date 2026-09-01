import Foundation
import CryptoKit

enum GHPRContract {
    static let skillVersion = "ghpr.dev/skill/v1"
    static let presentationVersion = "ghpr.dev/presentation/v1"
    static let browserVersion = "ghpr.dev/browser/v1"
    static let browserVersionV2 = "ghpr.dev/browser/v2"
    static let bridgeProtocol = "ghpr.browser-bridge/v1"
    static let bridgeAPIVersion = 1
}

enum BrowserPermissionRisk: String, Codable {
    case standard
    case elevated
    case unavailable
}

enum BrowserScope: String, Codable, CaseIterable, Hashable, Identifiable {
    case prRead = "pr:read"
    case ciRead = "ci:read"
    case analysisRead = "analysis:read"
    case artifactRead = "artifact:read"
    case skillList = "skill:list"
    case skillRun = "skill:run"
    case skillCancel = "skill:cancel"
    case tagRead = "tag:read"
    case tagWrite = "tag:write"
    case uiContribute = "ui:contribute"
    case detailOpen = "detail:open"
    case appOpen = "app:open"
    case findingWrite = "finding:write"

    var id: String { rawValue }

    var risk: BrowserPermissionRisk {
        switch self {
        case .artifactRead, .skillRun, .skillCancel, .tagWrite, .findingWrite:
            return .elevated
        default:
            return .standard
        }
    }

    var displayName: String {
        switch self {
        case .prRead: return "Read current PR"
        case .ciRead: return "Read CI status"
        case .analysisRead: return "Read analysis results"
        case .artifactRead: return "Read Skill artifacts"
        case .skillList: return "List configured Skills"
        case .skillRun: return "Run configured Skills"
        case .skillCancel: return "Cancel Skill runs"
        case .tagRead: return "Read locally stored ghpr tags"
        case .tagWrite: return "Change locally stored ghpr tags (not GitHub labels)"
        case .uiContribute: return "Add GitHub page UI"
        case .detailOpen: return "Open local analysis"
        case .appOpen: return "Open ghpr-view"
        case .findingWrite: return "Dismiss findings"
        }
    }

    static let firstPartyDefaults: Set<BrowserScope> = [
        .prRead,
        .ciRead,
        .analysisRead,
        .skillList,
        .uiContribute,
        .detailOpen
    ]
}

struct BrowserBridgeDiscovery: Codable, Equatable {
    let protocolName: String
    let instanceID: String
    let appVersion: String
    let officialUserscriptVersion: String?
    let apiVersions: [Int]
    let pairingRequired: Bool
    var githubSurfaceV2: Bool = true

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case instanceID
        case appVersion
        case officialUserscriptVersion
        case apiVersions
        case pairingRequired
        case githubSurfaceV2
    }
}

struct BrowserClientDescriptor: Codable, Equatable {
    let id: String
    let name: String
    let version: String
    let requestedScopes: Set<BrowserScope>
    let requiredScopes: Set<BrowserScope>

    init(
        id: String,
        name: String,
        version: String,
        requestedScopes: Set<BrowserScope>,
        requiredScopes: Set<BrowserScope> = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.requestedScopes = requestedScopes
        self.requiredScopes = requiredScopes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case requestedScopes
        case requiredScopes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        requestedScopes = try container.decode(Set<BrowserScope>.self, forKey: .requestedScopes)
        requiredScopes = try container.decodeIfPresent(Set<BrowserScope>.self, forKey: .requiredScopes) ?? []
    }
}

enum LocalCapabilityKind: String, Codable {
    case analysis
    case run
    case workbench
}

struct LocalCapabilityContext: Codable, Equatable {
    let kind: LocalCapabilityKind
    let resourceID: String?
    let expiresAt: Date
}

struct PairingStatusResponse: Codable, Equatable {
    let descriptor: BrowserClientDescriptor
    let state: PairingState
    let client: BrowserClient?
    let expiresAt: Date
}

struct BrowserClient: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var version: String
    var scopes: Set<BrowserScope>
    let createdAt: Date
    var lastSeenAt: Date?
    var revokedAt: Date?

    var isRevoked: Bool { revokedAt != nil }
}

enum PairingState: String, Codable {
    case pending
    case approved
    case denied
    case expired
}

struct PairingStartResponse: Codable, Equatable {
    let requestID: String
    let pairingSecret: String
    let pairingURL: String
    let expiresAt: Date
}

struct PairingPollResponse: Codable, Equatable {
    let state: PairingState
    let token: String?
    let client: BrowserClient?
}

struct PendingPairingApproval: Equatable, Identifiable {
    let id: String
    let descriptor: BrowserClientDescriptor
    let expiresAt: Date
}

enum BrowserBridgeActionError: LocalizedError {
    case pullRequestUnavailable

    var errorDescription: String? {
        "The pull request is no longer available in ghpr."
    }
}

struct BrowserBridgeStatus: Equatable {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    var state: State

    var port: UInt16? {
        guard case .running(let port) = state else { return nil }
        return port
    }
}

enum GitHubPageType: String, Codable, CaseIterable {
    case pullRequest = "pull_request"
    case workflowRun = "workflow_run"
}

struct GitHubPageContext: Codable, Equatable, Hashable {
    let type: GitHubPageType
    let key: String
    let repository: String
    let prNumber: Int?
    let workflowRunID: Int64?

    static func pullRequest(repository: String, number: Int) -> GitHubPageContext {
        GitHubPageContext(
            type: .pullRequest,
            key: "github:\(repository.lowercased()):pr:\(number)",
            repository: repository,
            prNumber: number,
            workflowRunID: nil
        )
    }

    static func workflowRun(repository: String, runID: Int64) -> GitHubPageContext {
        GitHubPageContext(
            type: .workflowRun,
            key: "github:\(repository.lowercased()):run:\(runID)",
            repository: repository,
            prNumber: nil,
            workflowRunID: runID
        )
    }
}

extension GitHubPageContext {
    var githubURL: URL? {
        switch type {
        case .pullRequest:
            guard let prNumber else { return nil }
            return URL(string: "https://github.com/\(repository)/pull/\(prNumber)")
        case .workflowRun:
            guard let workflowRunID else { return nil }
            return URL(string: "https://github.com/\(repository)/actions/runs/\(workflowRunID)")
        }
    }
}
enum SubjectValidationError: Error, Equatable {
    case invalid(String)
    case subjectKeyMismatch
}

private func ghprSHA256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func validateGitHubIdentity(repository: String, positive values: [(String, Int64)]) throws {
    guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
        throw SubjectValidationError.invalid("repository")
    }
    for (name, value) in values where value <= 0 {
        throw SubjectValidationError.invalid(name)
    }
}

struct PullRequestRevisionSubject: Codable, Equatable, Hashable {
    let repository: String
    let prNumber: Int
    let baseSHA: String
    let headSHA: String

    init(repository: String, prNumber: Int, baseSHA: String, headSHA: String) throws {
        try validateGitHubIdentity(repository: repository, positive: [("prNumber", Int64(prNumber))])
        guard baseSHA.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil,
              headSHA.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil else {
            throw SubjectValidationError.invalid("sha")
        }
        self.repository = repository
        self.prNumber = prNumber
        self.baseSHA = baseSHA.lowercased()
        self.headSHA = headSHA.lowercased()
    }
}

struct WorkflowJobSubject: Codable, Equatable, Hashable {
    let repository: String
    let workflowRunID: Int64
    let workflowAttempt: Int
    let workflowJobID: Int64
    let headSHA: String

    init(repository: String, workflowRunID: Int64, workflowAttempt: Int, workflowJobID: Int64, headSHA: String) throws {
        try validateGitHubIdentity(repository: repository, positive: [("workflowRunID", workflowRunID), ("workflowAttempt", Int64(workflowAttempt)), ("workflowJobID", workflowJobID)])
        guard headSHA.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil else {
            throw SubjectValidationError.invalid("headSHA")
        }
        self.repository = repository
        self.workflowRunID = workflowRunID
        self.workflowAttempt = workflowAttempt
        self.workflowJobID = workflowJobID
        self.headSHA = headSHA.lowercased()
    }
}

enum DiffSide: String, Codable, Hashable { case left, right }

struct DiffAnchor: Codable, Equatable, Hashable {
    let repository: String
    let prNumber: Int
    let baseSHA: String
    let headSHA: String
    let blobSHA: String?
    let filePath: String
    let side: DiffSide
    let startLine: Int
    let endLine: Int
    let hunkFingerprint: String?
    let quotedCode: String?

    init(repository: String, prNumber: Int, baseSHA: String, headSHA: String, blobSHA: String? = nil, filePath: String, side: DiffSide, startLine: Int, endLine: Int, hunkFingerprint: String? = nil, quotedCode: String? = nil) throws {
        _ = try PullRequestRevisionSubject(repository: repository, prNumber: prNumber, baseSHA: baseSHA, headSHA: headSHA)
        guard !filePath.isEmpty, !filePath.hasPrefix("/"), !filePath.split(separator: "/").contains(".."), startLine > 0, endLine >= startLine else {
            throw SubjectValidationError.invalid("diff anchor")
        }
        if let blobSHA, blobSHA.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) == nil {
            throw SubjectValidationError.invalid("blobSHA")
        }
        self.repository = repository
        self.prNumber = prNumber
        self.baseSHA = baseSHA.lowercased()
        self.headSHA = headSHA.lowercased()
        self.blobSHA = blobSHA?.lowercased()
        self.filePath = filePath
        self.side = side
        self.startLine = startLine
        self.endLine = endLine
        self.hunkFingerprint = hunkFingerprint
        self.quotedCode = quotedCode
    }
}

enum GitHubSubject: Codable, Equatable, Hashable {
    case pullRequestRevision(PullRequestRevisionSubject)
    case workflowJob(WorkflowJobSubject)
    case diffLine(DiffAnchor)
    case legacyPage(GitHubPageContext)

    var subjectKey: String {
        switch self {
        case .pullRequestRevision(let s): return "github:pull-request-revision:\(s.repository.lowercased())#\(s.prNumber)@\(s.baseSHA)..\(s.headSHA)"
        case .workflowJob(let s): return "github:workflow-job:\(s.repository.lowercased()):run:\(s.workflowRunID):attempt:\(s.workflowAttempt):job:\(s.workflowJobID)@\(s.headSHA)"
        case .diffLine(let a):
            let raw = ["v1", a.repository.lowercased(), "\(a.prNumber)", a.baseSHA, a.headSHA, a.blobSHA ?? "-", a.filePath, a.side.rawValue, "\(a.startLine)", "\(a.endLine)"].joined(separator: "\0")
            return "github:diff-line:\(ghprSHA256(raw))"
        case .legacyPage(let page): return "github:legacy-page:\(page.key)"
        }
    }

    var page: GitHubPageContext? {
        switch self {
        case .pullRequestRevision(let s):
            return .pullRequest(repository: s.repository, number: s.prNumber)
        case .diffLine(let a):
            return .pullRequest(repository: a.repository, number: a.prNumber)
        case .workflowJob(let s):
            return .workflowRun(repository: s.repository, runID: s.workflowRunID)
        case .legacyPage(let page): return page
        }
    }

    var isLegacy: Bool {
        if case .legacyPage = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey { case type, repository, prNumber, baseSHA, headSHA, workflowRunID, workflowAttempt, workflowJobID, blobSHA, filePath, side, startLine, endLine, hunkFingerprint, quotedCode, page, subjectKey }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "pull_request_revision": self = .pullRequestRevision(try PullRequestRevisionSubject(repository: c.decode(String.self, forKey: .repository), prNumber: c.decode(Int.self, forKey: .prNumber), baseSHA: c.decode(String.self, forKey: .baseSHA), headSHA: c.decode(String.self, forKey: .headSHA)))
        case "workflow_job": self = .workflowJob(try WorkflowJobSubject(repository: c.decode(String.self, forKey: .repository), workflowRunID: c.decode(Int64.self, forKey: .workflowRunID), workflowAttempt: c.decode(Int.self, forKey: .workflowAttempt), workflowJobID: c.decode(Int64.self, forKey: .workflowJobID), headSHA: c.decode(String.self, forKey: .headSHA)))
        case "diff_line": self = .diffLine(try DiffAnchor(repository: c.decode(String.self, forKey: .repository), prNumber: c.decode(Int.self, forKey: .prNumber), baseSHA: c.decode(String.self, forKey: .baseSHA), headSHA: c.decode(String.self, forKey: .headSHA), blobSHA: c.decodeIfPresent(String.self, forKey: .blobSHA), filePath: c.decode(String.self, forKey: .filePath), side: c.decode(DiffSide.self, forKey: .side), startLine: c.decode(Int.self, forKey: .startLine), endLine: c.decode(Int.self, forKey: .endLine), hunkFingerprint: c.decodeIfPresent(String.self, forKey: .hunkFingerprint), quotedCode: c.decodeIfPresent(String.self, forKey: .quotedCode)))
        case "legacy_page": self = .legacyPage(try c.decode(GitHubPageContext.self, forKey: .page))
        default: throw SubjectValidationError.invalid("type")
        }
        if let supplied = try c.decodeIfPresent(String.self, forKey: .subjectKey), supplied != subjectKey { throw SubjectValidationError.subjectKeyMismatch }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pullRequestRevision(let s): try c.encode("pull_request_revision", forKey: .type); try c.encode(s.repository, forKey: .repository); try c.encode(s.prNumber, forKey: .prNumber); try c.encode(s.baseSHA, forKey: .baseSHA); try c.encode(s.headSHA, forKey: .headSHA)
        case .workflowJob(let s): try c.encode("workflow_job", forKey: .type); try c.encode(s.repository, forKey: .repository); try c.encode(s.workflowRunID, forKey: .workflowRunID); try c.encode(s.workflowAttempt, forKey: .workflowAttempt); try c.encode(s.workflowJobID, forKey: .workflowJobID); try c.encode(s.headSHA, forKey: .headSHA)
        case .diffLine(let a): try c.encode("diff_line", forKey: .type); try c.encode(a.repository, forKey: .repository); try c.encode(a.prNumber, forKey: .prNumber); try c.encode(a.baseSHA, forKey: .baseSHA); try c.encode(a.headSHA, forKey: .headSHA); try c.encodeIfPresent(a.blobSHA, forKey: .blobSHA); try c.encode(a.filePath, forKey: .filePath); try c.encode(a.side, forKey: .side); try c.encode(a.startLine, forKey: .startLine); try c.encode(a.endLine, forKey: .endLine); try c.encodeIfPresent(a.hunkFingerprint, forKey: .hunkFingerprint); try c.encodeIfPresent(a.quotedCode, forKey: .quotedCode)
        case .legacyPage(let p): try c.encode("legacy_page", forKey: .type); try c.encode(p, forKey: .page)
        }
        try c.encode(subjectKey, forKey: .subjectKey)
    }
}
enum FindingSeverity: String, Codable { case error, warning, info }
enum FindingLifecycle: String, Codable { case exact, remapped, outdated, unavailable }
enum FindingKind: String, Codable { case ciFailureExplanation = "ci_failure_explanation", ciFlakyClassification = "ci_flaky_classification", reviewFinding = "review_finding" }
struct SkillFinding: Codable, Equatable, Identifiable {
    let id: String
    let subjectKey: String
    let subject: GitHubSubject
    let kind: FindingKind
    let severity: FindingSeverity
    let title: String
    let summary: String
    let details: String?
    let confidence: Double?
    let lifecycle: FindingLifecycle
    let createdAt: Date
    let fingerprint: String
    var resolvedSubject: GitHubSubject? = nil
}

extension SkillFinding {
    private enum CodingKeys: String, CodingKey {
        case id, subjectKey, subject, kind, severity, title, summary, details
        case confidence, lifecycle, createdAt, fingerprint, resolvedSubject
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        subject = try container.decode(GitHubSubject.self, forKey: .subject)
        subjectKey = try container.decode(String.self, forKey: .subjectKey)
        guard subjectKey == subject.subjectKey else {
            throw SubjectValidationError.subjectKeyMismatch
        }
        kind = try container.decode(FindingKind.self, forKey: .kind)
        severity = try container.decode(FindingSeverity.self, forKey: .severity)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        lifecycle = try container.decode(FindingLifecycle.self, forKey: .lifecycle)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        resolvedSubject = try container.decodeIfPresent(GitHubSubject.self, forKey: .resolvedSubject)
    }

    func encode(to encoder: Encoder) throws {
        guard subjectKey == subject.subjectKey else {
            throw SubjectValidationError.subjectKeyMismatch
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(subjectKey, forKey: .subjectKey)
        try container.encode(subject, forKey: .subject)
        try container.encode(kind, forKey: .kind)
        try container.encode(severity, forKey: .severity)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(details, forKey: .details)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encodeIfPresent(resolvedSubject, forKey: .resolvedSubject)
    }
}

enum PRTag: String, Codable, CaseIterable, Identifiable {
    case flaky
    case notFlaky = "not_flaky"
    case needsInvestigation = "needs_investigation"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flaky: return "Flaky"
        case .notFlaky: return "Not flaky"
        case .needsInvestigation: return "Needs investigation"
        }
    }
}

struct TaggedPR: Codable, Equatable {
    let pageKey: String
    var tags: Set<PRTag>
    var updatedAt: Date
    var updatedByClientID: String?
}

enum SkillTarget: String, Codable, CaseIterable {
    case pullRequestRevision = "pull_request_revision"
    case workflowJob = "workflow_job"
    case diffLine = "diff_line"
    case pullRequest = "pull_request"
    case failedWorkflowRun = "failed_workflow_run"
    case reviewFinding = "review_finding"
}

enum SkillAgent: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude_code"
    case codex
    case omp
    case external
}

extension SkillAgent {
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .omp: return "OMP"
        case .external: return "External"
        }
    }
}

struct AgentReasoningEffortOption: Codable, Equatable, Sendable, Identifiable {
    let effort: String
    let detail: String?

    var id: String { effort }
}

struct AgentModelOption: Codable, Equatable, Sendable, Identifiable {
    let slug: String
    let displayName: String
    let detail: String?
    let defaultEffort: String?
    let reasoningEfforts: [AgentReasoningEffortOption]

    var id: String { slug }
}

struct AgentCapabilityCatalog: Codable, Equatable, Sendable {
    let agent: SkillAgent
    let models: [AgentModelOption]
    let reasoningEfforts: [AgentReasoningEffortOption]
    let listsModels: Bool
    let listsReasoningEfforts: Bool
    let source: String
    let refreshedAt: Date

    func reasoningEfforts(forModel slug: String?) -> [AgentReasoningEffortOption] {
        guard let slug,
              let model = models.first(where: { $0.slug == slug }),
              !model.reasoningEfforts.isEmpty else {
            return reasoningEfforts
        }
        return model.reasoningEfforts
    }
}

struct AgentRuntimePreference: Codable, Equatable, Sendable {
    var model: String?
    var reasoningEffort: String?

    static let unset = AgentRuntimePreference(model: nil, reasoningEffort: nil)

    var isUnset: Bool { model == nil && reasoningEffort == nil }
}

struct AgentRuntimeSetting: Codable, Equatable, Sendable {
    let agent: SkillAgent
    var preference: AgentRuntimePreference
}

struct SkillDefinition: Codable, Equatable, Identifiable {
    let id: String
    let version: String
    let displayName: String
    let summary: String
    let targets: [SkillTarget]
    let agents: [SkillAgent]
    let defaultAgent: SkillAgent
    let isBuiltIn: Bool
    let hasBrowserCompanion: Bool
    let isRunnable: Bool
}

enum SkillRunStatus: String, Codable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

enum SkillResultKind: String, Codable {
    case ciAnalysis = "ci_analysis"
    case codeReview = "code_review"
    case generic
}

enum AnalysisVerdict: String, Codable, CaseIterable {
    case likelyFlaky = "likely_flaky"
    case likelyRelated = "likely_related"
    case needsInvestigation = "needs_investigation"

    var displayName: String {
        switch self {
        case .likelyFlaky: return "Likely flaky"
        case .likelyRelated: return "Likely related"
        case .needsInvestigation: return "Needs investigation"
        }
    }
}

enum AnalysisConfidence: String, Codable, CaseIterable {
    case low
    case medium
    case high
}

struct AnalysisHistoryMatch: Codable, Equatable, Identifiable {
    let id: String
    let runNumber: Int?
    let branch: String
    let date: Date
    let similarity: Double
    let result: String
}

struct CIAnalysis: Codable, Equatable, Identifiable {
    let id: String
    let pageKey: String
    let repository: String
    let prNumber: Int
    let jobName: String?
    let verdict: AnalysisVerdict
    let confidence: AnalysisConfidence
    let confidenceScore: Double
    let summary: String
    let historyMatches: [AnalysisHistoryMatch]
    let historyChecked: Int
    let relatednessScore: Double?
    let relatednessSummary: String?
    let reproduction: String
    let failureSignature: String?
    let changedFiles: [String]
    let suggestedAction: String
    let agent: SkillAgent
    let strictContext: Bool
    let durationSeconds: Double
    let createdAt: Date
}

enum ReviewSeverity: String, Codable, CaseIterable {
    case error
    case warning
    case info
}

struct ReviewFindingDetails: Codable, Equatable {
    let why: String?
    let suggestedFix: String?
    let background: String?
    let triggerScenarios: [String]
}

enum DiffSnippetLineKind: String, Codable, Equatable {
    case context
    case added
    case removed
    case ellipsis
}

struct DiffSnippetLine: Codable, Equatable {
    let kind: DiffSnippetLineKind
    let oldLine: Int?
    let newLine: Int?
    let text: String
}

struct DiffSnippet: Codable, Equatable {
    let lines: [DiffSnippetLine]
    let unavailableReason: String?
}

struct ReviewFinding: Codable, Equatable, Identifiable {
    let id: String
    let file: String
    let line: Int?
    let body: String
    let quotedCode: String?
    let details: ReviewFindingDetails?
    let severity: ReviewSeverity
    let confidence: Double
    let category: String
    var title: String? = nil
    var side: DiffSide? = nil
    var startLine: Int? = nil
    var endLine: Int? = nil
    var snippet: DiffSnippet? = nil
}

struct CodeReviewResult: Codable, Equatable {
    let overviewMarkdown: String
    let findings: [ReviewFinding]
    let engine: String?
    let reviewedAt: Date
    let headSHA: String?
    var reviewedBaseSHA: String? = nil
    var reviewedHeadSHA: String? = nil
    var reviewedFiles: [String]? = nil
    var skippedFiles: [ReviewSkippedFile]? = nil
}

enum SkillStructuredValue: Codable, Equatable, Sendable {
    case object([String: SkillStructuredValue])
    case array([SkillStructuredValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: SkillStructuredValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([SkillStructuredValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported structured Skill result value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    func redactingArtifactData() -> SkillStructuredValue {
        switch self {
        case .object(let object):
            return .object(
                object.reduce(into: [:]) { redacted, entry in
                    if entry.key == "artifacts" {
                        redacted[entry.key] = .array([])
                    } else {
                        redacted[entry.key] = entry.value.redactingArtifactData()
                    }
                }
            )
        case .array(let values):
            return .array(values.map { $0.redactingArtifactData() })
        case .string, .number, .bool, .null:
            return self
        }
    }
}


struct SkillResult: Codable, Equatable {
    let kind: SkillResultKind
    let title: String
    let summary: String
    let analysis: CIAnalysis?
    let codeReview: CodeReviewResult?
    let markdown: String?
    let artifacts: [SkillArtifact]
    let payload: SkillStructuredValue?

    init(
        kind: SkillResultKind,
        title: String,
        summary: String,
        analysis: CIAnalysis?,
        codeReview: CodeReviewResult?,
        markdown: String?,
        artifacts: [SkillArtifact],
        payload: SkillStructuredValue? = nil
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.analysis = analysis
        self.codeReview = codeReview
        self.markdown = markdown
        self.artifacts = artifacts
        self.payload = payload
    }
}

struct SkillArtifact: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let mediaType: String
    let relativePath: String?
    let inlineText: String?
}

enum SkillRunLogKind: String, Codable, Equatable {
    case queued
    case running
    case success
    case warning
    case error
}

enum SkillRunLogStream: String, Codable, Equatable {
    case skillInput = "skill_input"
    case agentOutput = "agent_output"
}

struct SkillRunLogEntry: Codable, Equatable {
    let timestamp: Date
    let kind: SkillRunLogKind
    let message: String
    let stream: SkillRunLogStream?

    init(
        timestamp: Date,
        kind: SkillRunLogKind,
        message: String,
        stream: SkillRunLogStream? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.stream = stream
    }
}

struct SkillRun: Codable, Equatable, Identifiable {
    let id: String
    let skillID: String
    let agent: SkillAgent?
    let subject: GitHubSubject
    var subjectKey: String { subject.subjectKey }
    let page: GitHubPageContext
    let requestedByClientID: String?
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var status: SkillRunStatus
    var progressMessage: String?
    var progressCurrent: Int?
    var progressTotal: Int?
    var logEntries: [SkillRunLogEntry]? = nil
    var result: SkillResult?
    var error: String?
    var retryOfRunID: String?
    init(
        id: String,
        skillID: String,
        agent: SkillAgent? = nil,
        page: GitHubPageContext,
        requestedByClientID: String?,
        createdAt: Date,
        startedAt: Date?,
        completedAt: Date?,
        status: SkillRunStatus,
        progressMessage: String?,
        progressCurrent: Int?,
        progressTotal: Int?,
        logEntries: [SkillRunLogEntry]? = nil,
        result: SkillResult?,
        error: String?,
        retryOfRunID: String?,
        subject: GitHubSubject? = nil
    ) {
        self.id = id
        self.skillID = skillID
        self.agent = agent
        let effectiveSubject = subject ?? .legacyPage(page)
        self.subject = effectiveSubject
        self.page = effectiveSubject.page ?? page
        self.requestedByClientID = requestedByClientID
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.progressMessage = progressMessage
        self.progressCurrent = progressCurrent
        self.progressTotal = progressTotal
        self.logEntries = logEntries
        self.result = result
        self.error = error
        self.retryOfRunID = retryOfRunID
    }

    private enum CodingKeys: String, CodingKey {
        case id, skillID, agent, subject, subjectKey, page, requestedByClientID, createdAt, startedAt, completedAt
        case status, progressMessage, progressCurrent, progressTotal, logEntries
        case result, error, retryOfRunID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        skillID = try container.decode(String.self, forKey: .skillID)
        agent = try container.decodeIfPresent(SkillAgent.self, forKey: .agent)
        let decodedPage = try container.decode(GitHubPageContext.self, forKey: .page)
        subject = try container.decodeIfPresent(GitHubSubject.self, forKey: .subject) ?? .legacyPage(decodedPage)
        page = subject.page ?? decodedPage
        if let supplied = try container.decodeIfPresent(String.self, forKey: .subjectKey),
           supplied != subject.subjectKey {
            throw SubjectValidationError.subjectKeyMismatch
        }
        requestedByClientID = try container.decodeIfPresent(String.self, forKey: .requestedByClientID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        status = try container.decode(SkillRunStatus.self, forKey: .status)
        progressMessage = try container.decodeIfPresent(String.self, forKey: .progressMessage)
        progressCurrent = try container.decodeIfPresent(Int.self, forKey: .progressCurrent)
        progressTotal = try container.decodeIfPresent(Int.self, forKey: .progressTotal)
        logEntries = try container.decodeIfPresent([SkillRunLogEntry].self, forKey: .logEntries)
        result = try container.decodeIfPresent(SkillResult.self, forKey: .result)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        retryOfRunID = try container.decodeIfPresent(String.self, forKey: .retryOfRunID)
    }
}

extension SkillRun {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(skillID, forKey: .skillID)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encode(subject, forKey: .subject)
        try container.encode(subjectKey, forKey: .subjectKey)
        try container.encode(page, forKey: .page)
        try container.encodeIfPresent(requestedByClientID, forKey: .requestedByClientID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(progressMessage, forKey: .progressMessage)
        try container.encodeIfPresent(progressCurrent, forKey: .progressCurrent)
        try container.encodeIfPresent(progressTotal, forKey: .progressTotal)
        try container.encodeIfPresent(logEntries, forKey: .logEntries)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(retryOfRunID, forKey: .retryOfRunID)
    }
}

enum BrowserSlot: String, Codable, CaseIterable, Identifiable {
    case prHeaderActions = "pr.header.actions"
    case prHeaderStatus = "pr.header.status"
    case prMergeboxAfter = "pr.mergebox.after"
    case prConversationAfterChecks = "pr.conversation.after-checks"
    case checksSummaryActions = "checks.summary.actions"
    case checksRunTrailing = "checks.run.trailing"
    case checksJobTrailing = "checks.job.trailing"
    case filesToolbarActions = "files.toolbar.actions"
    case filesDiffLineDecoration = "files.diff.line-decoration"

    var id: String { rawValue }
}

enum BrowserComponentType: String, Codable, CaseIterable {
    case action
    case badge
    case resultCard = "result_card"
}

enum BrowserTone: String, Codable, CaseIterable {
    case neutral
    case info
    case success
    case warning
    case danger
    case analysis
}

struct BrowserComponent: Codable, Equatable {
    let type: BrowserComponentType
    let label: String?
    let text: String?
    let tone: BrowserTone
    let presentationRef: String?
}

enum BrowserActionKind: String, Codable, CaseIterable {
    case runSkill = "run_skill"
    case cancelRun = "cancel_run"
    case retryRun = "retry_run"
    case openDetail = "open_detail"
    case openApp = "open_app"
    case showPR = "show_pr"
    case setTag = "set_tag"
    case removeTag = "remove_tag"
    case rerunFailedJobs = "rerun_failed_jobs"
    case clientEvent = "client_event"
}

struct BrowserAction: Codable, Equatable {
    let kind: BrowserActionKind
    let skillID: String?
    let runID: String?
    let analysisID: String?
    let tag: PRTag?
    let event: String?
    var subject: GitHubSubject? = nil
}

struct BrowserContribution: Codable, Equatable, Identifiable {
    let id: String
    let clientID: String
    let pageKey: String
    let slot: BrowserSlot
    let component: BrowserComponent
    let action: BrowserAction?
    let createdAt: Date
    let expiresAt: Date
}

struct ContributionRegistration: Codable, Equatable {
    let pageKey: String
    let ttlSeconds: Int
    let slot: BrowserSlot
    let contribution: ContributionInput
}

struct ContributionInput: Codable, Equatable {
    let id: String
    let component: BrowserComponent
    let action: BrowserAction?
}

struct SlotHealthReport: Codable, Equatable, Identifiable {
    var id: String { "\(clientID):\(pageKey):\(slot.rawValue)" }
    let clientID: String
    let pageKey: String
    let slot: BrowserSlot
    let healthy: Bool
    let detail: String?
    let observedAt: Date
}
enum SurfaceHealthState: String, Codable { case healthy, missing, ambiguous }

struct SurfaceHealthReport: Codable, Equatable, Identifiable {
    let surface: String
    let state: SurfaceHealthState
    let detail: String?
    let observedAt: Date
    var id: String { surface }
}


struct BrowserEvent: Codable, Equatable, Identifiable {
    let id: Int64
    let clientID: String
    let pageKey: String
    let name: String
    let payload: [String: String]
    let createdAt: Date
}

struct PageExtensionSnapshot: Codable, Equatable {
    let page: GitHubPageContext
    let pullRequest: LocalPRSnapshot?
    let analyses: [CIAnalysis]
    let tags: Set<PRTag>
    let runs: [SkillRun]
    let skills: [SkillDefinition]
    let contributions: [BrowserContribution]
    var findings: [SkillFinding] = []
    var currentRevisionSubject: GitHubSubject? = nil
    var githubSurfaceV2: Bool = true
    var surfaceHealth: [SurfaceHealthReport] = []
}

enum PresentationSectionType: String, Codable, CaseIterable {
    case hero
    case metricGrid = "metric_grid"
    case markdown
    case table
    case timeline
    case code
    case log
    case artifactList = "artifact_list"
}

struct PresentationSection: Codable, Equatable, Identifiable {
    let id: String
    let type: PresentationSectionType
    let title: String?
    let valuePath: String?
    let columns: [String]?
}

struct PresentationContract: Codable, Equatable {
    let apiVersion: String
    let summary: [PresentationSection]
    let detail: [PresentationSection]
}

struct BrowserContract: Codable, Equatable {
    let apiVersion: String
    let surfaces: [String]
    let contributions: [BrowserContributionDeclaration]
}

struct BrowserContributionDeclaration: Codable, Equatable, Identifiable {
    let id: String
    let slot: BrowserSlot
    let visibleWhen: [String: String]
    let component: BrowserComponent
    let action: BrowserAction?
}

enum BrowserTargetKindV2: String, Codable, CaseIterable {
    case pullRequestRevision = "github.pull_request_revision"
    case workflowJob = "github.workflow_job"
    case diffLine = "github.diff_line"
}

enum BrowserSurfaceV2: String, Codable, CaseIterable {
    case conversationReviewSummary = "github.pr.conversation.review-summary"
    case checksJobTrailing = "github.pr.checks.job.trailing"
    case checksJobInsight = "github.pr.checks.job.insight"
    case actionsJobAfterFailureSummary = "github.actions.job.after-failure-summary"
    case filesFileHeader = "github.pr.files.file.header"
    case filesDiffLineAfter = "github.pr.files.diff.line.after"
    case findingDrawer = "github.page.finding-drawer"
}

enum BrowserViewTypeV2: String, Codable, CaseIterable {
    case jobVerdict = "job_verdict"
    case ciInsight = "ci_insight"
    case reviewSummary = "review_summary"
    case reviewFindingPreview = "review_finding_preview"
    case findingCount = "finding_count"
    case reviewFinding = "review_finding"
    case diffSnippet = "diff_snippet"
    case detailDrawer = "detail_drawer"
}

struct BrowserRepeatV2: Codable, Equatable {
    let source: String
}

struct BrowserPlacementV2: Codable, Equatable, Identifiable {
    let id: String
    let surface: BrowserSurfaceV2
    let bindTo: String?
    let repeatBinding: BrowserRepeatV2?
    let view: BrowserViewTypeV2
}

struct BrowserContractV2: Codable, Equatable {
    let apiVersion: String
    let targetKinds: [BrowserTargetKindV2]
    let placements: [BrowserPlacementV2]
}


struct ContractCapabilities: Codable, Equatable {
    let skillContract: [String]
    let presentationContract: [String]
    let browserContract: [String]
    let supportedSections: [PresentationSectionType]
    let supportedBrowserSlots: [BrowserSlot]
    let supportedAgents: [SkillAgent]

    static let current = ContractCapabilities(
        skillContract: ["v1"],
        presentationContract: ["v1"],
        browserContract: ["v1", "v2"],
        supportedSections: PresentationSectionType.allCases,
        supportedBrowserSlots: BrowserSlot.allCases,
        supportedAgents: [.claudeCode, .codex, .omp]
    )
}

struct BrowserAPIErrorPayload: Codable, Equatable {
    let code: String
    let message: String
}

struct BrowserAPIEnvelope<Value: Codable & Equatable>: Codable, Equatable {
    let ok: Bool
    let value: Value?
    let error: BrowserAPIErrorPayload?

    static func success(_ value: Value) -> BrowserAPIEnvelope<Value> {
        BrowserAPIEnvelope(ok: true, value: value, error: nil)
    }

    static func failure(code: String, message: String) -> BrowserAPIEnvelope<Value> {
        BrowserAPIEnvelope(
            ok: false,
            value: nil,
            error: BrowserAPIErrorPayload(code: code, message: message)
        )
    }
}
