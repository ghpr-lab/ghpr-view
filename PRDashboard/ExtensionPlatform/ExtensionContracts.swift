import Foundation

enum GHPRContract {
    static let skillVersion = "ghpr.dev/skill/v1"
    static let presentationVersion = "ghpr.dev/presentation/v1"
    static let browserVersion = "ghpr.dev/browser/v1"
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

    var id: String { rawValue }

    var risk: BrowserPermissionRisk {
        switch self {
        case .artifactRead, .skillRun, .skillCancel, .tagWrite:
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

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case instanceID
        case appVersion
        case officialUserscriptVersion
        case apiVersions
        case pairingRequired
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

struct GitHubPageContext: Codable, Equatable {
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
}

struct CodeReviewResult: Codable, Equatable {
    let overviewMarkdown: String
    let findings: [ReviewFinding]
    let engine: String?
    let reviewedAt: Date
    let headSHA: String?
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

struct SkillRunLogEntry: Codable, Equatable {
    let timestamp: Date
    let kind: SkillRunLogKind
    let message: String
}

struct SkillRun: Codable, Equatable, Identifiable {
    let id: String
    let skillID: String
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
        browserContract: ["v1"],
        supportedSections: PresentationSectionType.allCases,
        supportedBrowserSlots: BrowserSlot.allCases,
        supportedAgents: [.omp, .claudeCode]
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
