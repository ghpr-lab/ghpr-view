import Foundation
import Combine

struct JiraSetupContext: Identifiable, Equatable {
    enum Source: Equatable {
        case settings
        case jiraIssue(key: String)
    }

    let id: UUID
    let source: Source
    let initialServerURL: String?

    init(
        id: UUID = UUID(),
        source: Source,
        initialServerURL: String? = nil
    ) {
        self.id = id
        self.source = source
        self.initialServerURL = initialServerURL
    }
}

enum JiraSetupStep: Equatable {
    case server
    case tokenInstructions
    case credentials
    case testing
    case completed
}

enum JiraSetupTestState: Equatable {
    case idle
    case testing
    case succeeded
    case failed(String)
}

@MainActor
final class JiraSetupCoordinator: ObservableObject {
    typealias TestConnection = (String, String, String) async throws -> JiraConnectionTestResult
    typealias CommitCredentials = (String, String, String) -> Void
    typealias URLHandler = (URL) -> Void
    typealias DismissHandler = () -> Void

    let context: JiraSetupContext
    let connectionState: JiraConnectionState
    let savedTokenAvailable: Bool
    let savedServerURL: String
    let savedEmail: String

    @Published var serverURL: String
    @Published var email: String
    @Published var apiToken: String = ""
    @Published private(set) var step: JiraSetupStep
    @Published private(set) var testState: JiraSetupTestState = .idle
    @Published private(set) var connectionResult: JiraConnectionTestResult?
    @Published private(set) var verifiedTuple: CredentialsTuple?
    @Published private(set) var isTesting = false

    private var committedServerURL: String?
    private var didAutoOpenPendingIssue = false
    private let testConnection: TestConnection
    private let commitCredentials: CommitCredentials
    private let openExternalURL: URLHandler
    private let dismissHandler: DismissHandler
    private var testTask: Task<Void, Never>?

    struct CredentialsTuple: Equatable {
        let serverURL: String
        let email: String
        let apiToken: String
    }

    init(
        context: JiraSetupContext,
        connectionState: JiraConnectionState = .notConfigured,
        savedServerURL: String,
        savedEmail: String,
        savedTokenAvailable: Bool,
        testConnection: @escaping TestConnection,
        commit: @escaping CommitCredentials,
        openExternalURL: @escaping URLHandler,
        dismiss: @escaping DismissHandler
    ) {
        let normalizedServerURL =
            JiraAPIClient.normalizedServerURL(savedServerURL) ?? savedServerURL

        self.context = context
        self.connectionState = connectionState
        self.savedServerURL = savedServerURL
        self.savedEmail = savedEmail
        self.savedTokenAvailable = savedTokenAvailable
        self.testConnection = testConnection
        self.commitCredentials = commit
        self.openExternalURL = openExternalURL
        self.dismissHandler = dismiss
        self.serverURL = normalizedServerURL
        self.email = savedEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        switch connectionState {
        case .configured, .unauthorized:
            self.step = .credentials
        case .notConfigured:
            self.step = .server
        }
    }

    var pendingIssueKey: String? {
        guard case .jiraIssue(let key) = context.source else { return nil }
        return key
    }

    var canContinueServer: Bool {
        normalizedDraftServerURL != nil && isSupportedCloudURL(normalizedDraftServerURL ?? "")
    }

    var serverValidationMessage: String? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let normalized = JiraAPIClient.normalizedServerURL(trimmed) else {
            return "Enter a valid Jira site URL."
        }
        return isSupportedCloudURL(normalized) ? nil : "Only Jira Cloud sites (*.atlassian.net) are supported."
    }

    var canTest: Bool {
        !isTesting && !normalizedCredentials.serverURL.isEmpty && !normalizedCredentials.email.isEmpty && !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canFinish: Bool {
        step == .testing && verifiedTuple == normalizedCredentials
    }

    var identityText: String? {
        connectionResult?.displayName ?? connectionResult?.emailAddress ?? verifiedTuple?.email
    }

    private var normalizedDraftServerURL: String? {
        JiraAPIClient.normalizedServerURL(serverURL)
    }

    private var normalizedCredentials: CredentialsTuple {
        CredentialsTuple(
            serverURL: normalizedDraftServerURL ?? serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            apiToken: apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func isSupportedCloudURL(_ normalized: String) -> Bool {
        guard let host = URL(string: normalized)?.host?.lowercased() else { return false }
        let labels = host.split(separator: ".")
        return labels.count >= 3 && host.hasSuffix(".atlassian.net") && !labels[labels.count - 3].isEmpty
    }

    func continueFromServer() {
        guard let normalized = normalizedDraftServerURL else { return }
        guard isSupportedCloudURL(normalized) else { return }
        serverURL = normalized
        step = .tokenInstructions
    }

    func continueFromTokenInstructions() {
        step = .credentials
    }

    func openTokenPage() {
        if let url = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens") {
            openExternalURL(url)
        }
    }

    func openJiraSite() {
        guard let normalized = normalizedDraftServerURL, let url = URL(string: normalized) else { return }
        openExternalURL(url)
    }

    func openPendingIssue() {
        guard let key = pendingIssueKey,
              let server = committedServerURL ?? normalizedDraftServerURL,
              let url = JiraAPIClient.issueURL(serverURL: server, issueKey: key) else { return }
        openExternalURL(url)
    }

    func fieldDidChange() {
        verifiedTuple = nil
        connectionResult = nil
        if step == .completed { return }
        if testState != .idle { testState = .idle }
    }

    func goBack() {
        guard !isTesting else { return }
        switch step {
        case .tokenInstructions:
            step = .server
        case .credentials:
            step = .tokenInstructions
        default:
            break
        }
    }

    func test() {
        guard canTest else { return }
        let tuple = normalizedCredentials
        serverURL = tuple.serverURL
        email = tuple.email
        apiToken = tuple.apiToken
        testTask?.cancel()
        isTesting = true
        testState = .testing
        step = .testing
        testTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.testConnection(tuple.serverURL, tuple.email, tuple.apiToken)
                guard !Task.isCancelled else { return }
                self.connectionResult = result
                self.verifiedTuple = tuple
                self.testState = .succeeded
                self.isTesting = false
            } catch {
                guard !Task.isCancelled else { return }
                self.connectionResult = nil
                self.verifiedTuple = nil
                self.testState = .failed(Self.message(for: error))
                self.isTesting = false
                self.step = .credentials
            }
        }
    }

    func finish() {
        guard canFinish, let tuple = verifiedTuple else { return }
        commitCredentials(tuple.serverURL, tuple.email, tuple.apiToken)
        committedServerURL = tuple.serverURL
        step = .completed
        if pendingIssueKey != nil, !didAutoOpenPendingIssue {
            didAutoOpenPendingIssue = true
            openPendingIssue()
        }
    }

    func cancel() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
        dismissHandler()
    }

    func done() { dismissHandler() }

    deinit { testTask?.cancel() }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
