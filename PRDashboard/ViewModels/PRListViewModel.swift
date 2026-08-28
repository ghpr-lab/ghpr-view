import Foundation
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.prdashboard", category: "PRListViewModel")

/// Parses and matches PR search queries. Shared between the ViewModel (filtering)
/// and PRRowView (highlight rendering) so a `jira:` scope and a typed term are
/// interpreted identically in both places.
enum PRSearchScope {
    static let jiraPrefix = "jira:"
    static let ciPrefix = "ci:"
    static let prPrefix = "pr:"
    static let approvalPrefix = "approval:"

    enum Kind {
        case all
        case jira
        case ci
        case pr
        case approval
    }

    struct Parsed {
        let kind: Kind
        /// Trimmed, original-case term (may be empty when the user typed only the scope prefix).
        let term: String
    }

    struct Suggestion: Equatable, Identifiable {
        let title: String
        let query: String
        let systemImage: String

        var id: String { query }
    }

    private struct EnumValueSuggestion {
        let value: String
        let systemImage: String
    }

    private enum CIValue: String, CaseIterable {
        case pass
        case failure
        case running

        var suggestion: EnumValueSuggestion {
            switch self {
            case .pass:
                return EnumValueSuggestion(value: rawValue, systemImage: "checkmark.circle")
            case .failure:
                return EnumValueSuggestion(value: rawValue, systemImage: "xmark.circle")
            case .running:
                return EnumValueSuggestion(value: rawValue, systemImage: "clock")
            }
        }
    }

    private enum PRValue: String, CaseIterable {
        case conflict

        var suggestion: EnumValueSuggestion {
            switch self {
            case .conflict:
                return EnumValueSuggestion(value: rawValue, systemImage: "exclamationmark.triangle")
            }
        }
    }

    private enum EnumSuggestionScope: CaseIterable {
        case ci
        case pr

        var prefix: String {
            switch self {
            case .ci:
                return PRSearchScope.ciPrefix
            case .pr:
                return PRSearchScope.prPrefix
            }
        }

        var values: [EnumValueSuggestion] {
            switch self {
            case .ci:
                return CIValue.allCases.map(\.suggestion)
            case .pr:
                return PRValue.allCases.map(\.suggestion)
            }
        }
    }

    static func parse(_ rawSearchText: String) -> Parsed {
        let trimmed = rawSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix(jiraPrefix) {
            let term = String(trimmed.dropFirst(jiraPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(kind: .jira, term: term)
        }
        if trimmed.lowercased().hasPrefix(ciPrefix) {
            let term = String(trimmed.dropFirst(ciPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(kind: .ci, term: term)
        }
        if trimmed.lowercased().hasPrefix(prPrefix) {
            let term = String(trimmed.dropFirst(prPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(kind: .pr, term: term)
        }
        if trimmed.lowercased().hasPrefix(approvalPrefix) {
            let term = String(trimmed.dropFirst(approvalPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(kind: .approval, term: term)
        }
        return Parsed(kind: .all, term: trimmed)
    }

    static func suggestions(for rawSearchText: String) -> [Suggestion] {
        let trimmed = rawSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard let scope = EnumSuggestionScope.allCases.first(where: { lowered.hasPrefix($0.prefix) }) else {
            return []
        }

        let typedValue = String(lowered.dropFirst(scope.prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = "\(scope.prefix)\(typedValue)"

        return scope.values
            .filter { typedValue.isEmpty || $0.value.hasPrefix(typedValue) }
            .map { value in
                Suggestion(
                    title: value.value,
                    query: "\(scope.prefix)\(value.value)",
                    systemImage: value.systemImage
                )
            }
            .filter { suggestion in
                suggestion.query != normalizedQuery
            }
    }

    static func contains(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        return text.range(
            of: term,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
    }
}

enum JiraIssueOpenDecision: Equatable {
    case open(URL)
    case confirmSetup(issueKey: String)
    case confirmReconnect(issueKey: String)

    static func resolve(
        state: JiraConnectionState,
        serverURL: String,
        issueKey: String
    ) -> JiraIssueOpenDecision {
        let key = issueKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .unauthorized:
            return .confirmReconnect(issueKey: key)
        case .notConfigured:
            return .confirmSetup(issueKey: key)
        case .configured:
            guard let url = JiraAPIClient.issueURL(serverURL: serverURL, issueKey: key),
                  JiraAPIClient.isSupportedCloudServerURL(serverURL) else {
                return .confirmSetup(issueKey: key)
            }
            return .open(url)
        }
    }
}

enum JiraPrompt: Identifiable, Equatable {
    case setup(issueKey: String)
    case reconnect(issueKey: String)

    var id: String {
        switch self {
        case .setup(let key): return "setup-\(key)"
        case .reconnect(let key): return "reconnect-\(key)"
        }
    }
}

@MainActor
final class PRListViewModel: ObservableObject {
    @Published var prList: PRList = .empty
    @Published var searchText: String = ""
    @Published private(set) var activeFacetSelections: [FacetFieldID: Set<String>] = [:]
    @Published var isFacetPanelPresented = false
    @Published private(set) var authState: AuthState = .empty
    @Published private(set) var pinnedPRIdentifiers: Set<String> = []
    @Published private(set) var pinChangeToken = UUID()
    @Published private(set) var deviceCode: DeviceCodeInfo?
    @Published private(set) var isAuthenticating: Bool = false
    @Published private(set) var authError: Error?
    @Published private(set) var isValidatingPAT: Bool = false
    @Published private(set) var patError: Error?
    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty
    @Published private(set) var openingPRIDs: Set<Int> = []
    @Published private(set) var updatingBranchPRIDs: Set<Int> = []
    @Published private(set) var loadingHoverDetailPRIDs: Set<Int> = []
    @Published private(set) var jiraConnectionState: JiraConnectionState = .notConfigured
    @Published var jiraPrompt: JiraPrompt?
    @Published private(set) var jiraCredentialRevision: Int = 0

    private let prManager: PRManager
    private let oauthManager: GitHubOAuthManager
    private let linkOpener: PRLinkOpening
    private let jiraURLOpener: (URL) -> Void
    private let savedViewStore: SavedViewStore
    private var cancellables = Set<AnyCancellable>()

    var isJiraConfigured: Bool { jiraConnectionState == .configured }
    var openSettings: (() -> Void)?
    init(
        prManager: PRManager,
        oauthManager: GitHubOAuthManager,
        linkOpener: PRLinkOpening,
        jiraURLOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        savedViewStore: SavedViewStore = SavedViewStore()
    ) {
        self.prManager = prManager
        self.oauthManager = oauthManager
        self.linkOpener = linkOpener
        self.jiraURLOpener = jiraURLOpener
        self.savedViewStore = savedViewStore
        setupBindings()
    }

    private func setupBindings() {
        // Bind prList from manager
        prManager.$prList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prList in
                self?.prList = prList
            }
            .store(in: &cancellables)

        // Bind rate limit info
        prManager.$rateLimitInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.rateLimitInfo = info
            }
            .store(in: &cancellables)

        // Bind auth state
        oauthManager.$authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authState in
                self?.authState = authState
            }
            .store(in: &cancellables)

        // Bind device code
        oauthManager.$deviceCode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceCode in
                self?.deviceCode = deviceCode
            }
            .store(in: &cancellables)

        // Bind authenticating state
        oauthManager.$isAuthenticating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAuthenticating in
                self?.isAuthenticating = isAuthenticating
            }
            .store(in: &cancellables)

        // Bind auth error
        oauthManager.$authError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authError in
                self?.authError = authError
            }
            .store(in: &cancellables)

        // Bind PAT validating state
        oauthManager.$isValidatingPAT
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isValidating in
                self?.isValidatingPAT = isValidating
            }
            .store(in: &cancellables)

        // Bind PAT error
        oauthManager.$patError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.patError = error
            }
            .store(in: &cancellables)

        // Keep pin-related manager updates synchronous on the main actor so rows
        // can move sections immediately after a context-menu action.
        prManager.$pinnedPRIdentifiers
            .sink { [weak self] identifiers in
                self?.pinnedPRIdentifiers = identifiers
            }
            .store(in: &cancellables)

        prManager.$updatingBranchPRIDs
            .removeDuplicates()
            .sink { [weak self] updatingIDs in
                self?.updatingBranchPRIDs = updatingIDs
            }
            .store(in: &cancellables)

        prManager.$loadingHoverDetailPRIDs
            .removeDuplicates()
            .sink { [weak self] loadingIDs in
                self?.loadingHoverDetailPRIDs = loadingIDs
            }
            .store(in: &cancellables)

        prManager.$jiraConnectionState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.jiraConnectionState = state
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed Properties

    var filteredPRs: [PullRequest] {
        filterPRs(prList.pullRequests)
    }

    var authoredPRs: [PullRequest] {
        filteredPRs.filter { $0.category == .authored }
    }

    var pinnedAuthoredPRs: [PullRequest] {
        authoredPRs.filter { pinnedPRIdentifiers.contains($0.pinIdentifier) }
    }

    var unpinnedAuthoredPRs: [PullRequest] {
        authoredPRs.filter { !pinnedPRIdentifiers.contains($0.pinIdentifier) }
    }

    var reviewRequestPRs: [PullRequest] {
        filteredPRs.filter { $0.category == .reviewRequest }
    }

    var pinnedReviewRequestPRs: [PullRequest] {
        reviewRequestPRs.filter { pinnedPRIdentifiers.contains($0.pinIdentifier) }
    }

    var unpinnedReviewRequestPRs: [PullRequest] {
        reviewRequestPRs.filter { !pinnedPRIdentifiers.contains($0.pinIdentifier) }
    }

    var mentionedPRs: [PullRequest] {
        filterPRs(prList.mentionedPullRequests)
    }
    var directMentionPRs: [PullRequest] {
        filterPRs(prList.directMentionPullRequests)
    }

    var groupedAuthoredPRs: [(String, [PullRequest])] {
        groupByRepo(unpinnedAuthoredPRs)
    }

    var groupedReviewPRs: [(String, [PullRequest])] {
        groupByRepo(unpinnedReviewRequestPRs)
    }

    var groupedMentionedPRs: [(String, [PullRequest])] {
        groupByRepo(mentionedPRs)
    }
    var groupedDirectMentionPRs: [(String, [PullRequest])] {
        groupByRepo(directMentionPRs)
    }

    private var filteredMergedPRs: [PullRequest] {
        filterPRs(prList.mergedPullRequests)
    }

    /// Merged within last 24 hours (rolling window), deduped by PR id.
    var mergedLast24hPRs: [PullRequest] {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        var seen = Set<Int>()
        let filtered = filteredMergedPRs.filter { pr in
            guard let mergedAt = pr.mergedAt else { return false }
            return mergedAt >= cutoff
        }.filter { pr in
            seen.insert(pr.id).inserted
        }

        return filtered.sorted { ($0.mergedAt ?? $0.updatedAt) > ($1.mergedAt ?? $1.updatedAt) }
    }

    var groupedMergedLast24hPRs: [(String, [PullRequest])] {
        groupByRepo(mergedLast24hPRs, sortByMergedDate: true)
    }

    var summaryReadyToMerge: Int {
        authoredPRs.filter {
            $0.meetsReadyToMergeCriteria(
                minimumApprovals: configuration.minimumApprovalsForReadyToMerge
            )
        }.count
    }

    var summaryChangesRequested: Int {
        authoredPRs.filter { ($0.changesRequestedCount ?? 0) > 0 }.count
    }

    var summaryCIFailing: Int {
        filteredPRs.filter { $0.ciStatus == .failure || $0.ciStatus == .unknown }.count
    }

    var summaryCIRunning: Int {
        filteredPRs.filter { $0.ciIsRunning }.count
    }

    var sourcePRs: [PullRequest] {
        var seen = Set<Int>()
        return (prList.pullRequests + prList.mentionedPullRequests + prList.directMentionPullRequests + prList.mergedPullRequests)
            .filter { seen.insert($0.id).inserted }
    }

    var facetChips: [FacetChip] {
        activeFacetSelections.flatMap { field, keys in
            keys.sorted().map { key in
                let option = facetOptions(for: field).first { $0.key == key }
                return FacetChip(field: field, key: key, displayName: option?.displayName ?? key, provider: field.provider)
            }
        }.sorted { $0.field.rawValue < $1.field.rawValue }
    }

    func facetOptions(for field: FacetFieldID) -> [FacetOption] {
        FacetIndexBuilder(sourcePRs: sourcePRs, searchText: searchText, selections: activeFacetSelections).options(for: field)
    }

    func toggleFacet(field: FacetFieldID, key: String) {
        var updated = activeFacetSelections
        var keys = updated[field] ?? []
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        if keys.isEmpty { updated.removeValue(forKey: field) } else { updated[field] = keys }
        activeFacetSelections = updated
    }

    func clearFacetField(_ field: FacetFieldID) {
        var updated = activeFacetSelections
        updated.removeValue(forKey: field)
        activeFacetSelections = updated
    }

    func clearAllFacets() { activeFacetSelections = [:] }

    var savedViews: [SavedView] { savedViewStore.views }
    @discardableResult func saveCurrentView(name: String) -> SavedView? {
        savedViewStore.create(name: name, selections: activeFacetSelections.map { ActiveFacetSelection(field: $0.key, selectedKeys: $0.value) }, searchText: searchText)
    }
    func applySavedView(_ view: SavedView) {
        searchText = view.searchText
        activeFacetSelections = Dictionary(uniqueKeysWithValues: view.selections.map { ($0.field, $0.selectedKeys) })
    }
    func renameSavedView(_ view: SavedView, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = view; updated.name = trimmed; savedViewStore.update(updated)
    }
    func deleteSavedView(_ view: SavedView) { savedViewStore.delete(view) }

    var summaryWaitingForMyReview: Int {
        reviewRequestPRs.filter { $0.myReviewStatus == .waiting }.count
    }


    var totalUnresolvedCount: Int {
        prList.totalUnresolvedCount
    }

    var lastUpdatedFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: prList.lastUpdated, relativeTo: Date())
    }

    var isLoading: Bool {
        prList.isLoading
    }

    var error: Error? {
        prList.error
    }

    var configuration: Configuration {
        get { prManager.configuration }
        set { prManager.updateConfiguration(newValue) }
    }

    var hasAnyJiraTicket: Bool {
        let lists = [
            prList.pullRequests,
            prList.mentionedPullRequests,
            prList.directMentionPullRequests,
            prList.mergedPullRequests
        ]
        for list in lists {
            if list.contains(where: { $0.jiraTicket?.isEmpty == false }) {
                return true
            }
        }
        return false
    }

    func updateJiraCredentials(
        serverURL: String,
        email: String,
        apiToken: String,
        refreshInterval: TimeInterval
    ) {
        prManager.updateJiraCredentials(
            serverURL: serverURL,
            email: email,
            apiToken: apiToken,
            refreshInterval: refreshInterval
        )
        jiraCredentialRevision += 1
    }


    func openJiraIssue(_ issueKey: String) {
        let decision = JiraIssueOpenDecision.resolve(
            state: jiraConnectionState,
            serverURL: prManager.configuration.jiraServerURL,
            issueKey: issueKey
        )
        switch decision {
        case .open(let url):
            jiraURLOpener(url)
        case .confirmSetup(let key):
            jiraPrompt = .setup(issueKey: key)
        case .confirmReconnect(let key):
            jiraPrompt = .reconnect(issueKey: key)
        }
    }

    // MARK: - Actions

    func refresh() {
        prManager.refresh()
    }

    func clearCaches() {
        prManager.clearDirectMentionTracking()
        PRCache.shared.clear()
        PRDetailCache.shared.clear()
        AvatarCache.shared.clear()
        JiraMetadataCache.shared.clear()
        prManager.refresh()
    }

    func showSettings() {
        openSettings?()
    }

    func openPR(_ pr: PullRequest) {
        guard linkOpener.opensAtCmuxFirst else {
            Task { @MainActor [linkOpener] in
                await linkOpener.open(pr.url)
            }
            return
        }

        guard !openingPRIDs.contains(pr.id) else { return }
        markOpeningPR(pr.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearOpeningPR(pr.id) }
            await self.linkOpener.open(pr.url)
        }
    }

    func copyURL(_ pr: PullRequest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
    }

    func signIn() {
        oauthManager.signIn()
    }

    func signOut() {
        oauthManager.signOut()
    }

    func cancelSignIn() {
        oauthManager.cancelSignIn()
    }

    func openVerificationURL() {
        oauthManager.openVerificationURL()
    }

    func copyUserCode() {
        oauthManager.copyUserCode()
    }

    func signInWithPAT(_ token: String) {
        Task {
            await oauthManager.signInWithPAT(token)
        }
    }

    func clearPATError() {
        oauthManager.clearPATError()
    }

    func isPinned(_ pr: PullRequest) -> Bool {
        pinnedPRIdentifiers.contains(pr.pinIdentifier)
    }

    func isOpeningPR(_ pr: PullRequest) -> Bool {
        openingPRIDs.contains(pr.id)
    }

    func isUpdatingBranch(_ pr: PullRequest) -> Bool {
        updatingBranchPRIDs.contains(pr.id)
    }

    func isLoadingHoverDetail(_ pr: PullRequest) -> Bool {
        loadingHoverDetailPRIDs.contains(pr.id)
    }

    func togglePin(_ pr: PullRequest) {
        let identifier = pr.pinIdentifier
        prManager.togglePinPR(identifier)
        pinnedPRIdentifiers = prManager.pinnedPRIdentifiers
        logger.info("Pin toggled: \(identifier) → pinned=\(self.pinnedPRIdentifiers.contains(identifier)), total=\(self.pinnedPRIdentifiers.count)")

        // Force SwiftUI to rebuild PR sections after context menu dismisses.
        // Changing pinChangeToken invalidates the .id() on the list container in MainView,
        // causing a full view tree rebuild that cannot be diff-optimized away.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.pinChangeToken = UUID()
        }
    }

    func markReviewCommentsRead(_ pr: PullRequest) {
        prManager.markReviewCommentsRead(for: pr)
    }

    func markReviewCommentsUnread(_ pr: PullRequest) {
        prManager.markReviewCommentsUnread(for: pr)
    }

    func rerunFailedCI(_ pr: PullRequest) {
        Task {
            do {
                let count = try await prManager.rerunFailedCI(for: pr)
                logger.info("Re-triggered \(count) failed workflow(s) for PR #\(pr.number)")
            } catch {
                logger.error("Failed to rerun CI for PR #\(pr.number): \(error.localizedDescription)")
            }
        }
    }

    func updateBranchWithRebase(_ pr: PullRequest) {
        Task {
            do {
                try await prManager.updateBranchWithRebase(for: pr)
                logger.info("Requested branch rebase update for PR #\(pr.number)")
            } catch {
                logger.error("Failed to update branch for PR #\(pr.number): \(error.localizedDescription)")
            }
        }
    }

    func loadHoverDetailIfNeeded(_ pr: PullRequest) {
        prManager.loadHoverDetailIfNeeded(for: pr)
    }

    // MARK: - Private

    private func markOpeningPR(_ id: Int) {
        var updated = openingPRIDs
        updated.insert(id)
        openingPRIDs = updated
    }

    private func clearOpeningPR(_ id: Int) {
        var updated = openingPRIDs
        updated.remove(id)
        openingPRIDs = updated
    }

    private func filterPRs(_ prs: [PullRequest]) -> [PullRequest] {
        return prs.filter { pr in
            FacetPredicate.matches(pr, searchText: searchText, selections: activeFacetSelections) { legacyFilterPRs([$0]).contains($0) }
        }
    }
    private func legacyFilterPRs(_ prs: [PullRequest]) -> [PullRequest] {
        let parsed = PRSearchScope.parse(searchText)
        switch parsed.kind {
        case .all:
            guard !parsed.term.isEmpty else { return prs }
            let term = parsed.term
            return prs.filter { pr in
                PRSearchScope.contains(term, in: pr.title) ||
                PRSearchScope.contains(term, in: pr.repoFullName) ||
                PRSearchScope.contains(term, in: pr.author) ||
                matchesJiraFields(pr, term: term) ||
                String(pr.number).contains(term)
            }
        case .jira:
            return prs.filter { pr in
                parsed.term.isEmpty ? hasAnyJiraField(pr) : matchesJiraFields(pr, term: parsed.term)
            }
        case .ci:
            return prs.filter { pr in
                matchesCIState(pr, term: parsed.term)
            }
        case .pr:
            return prs.filter { pr in
                matchesPRState(pr, term: parsed.term)
            }
        case .approval:
            return prs.filter { pr in
                matchesApprovalCount(pr, term: parsed.term)
            }
        }
    }

    private func hasAnyJiraField(_ pr: PullRequest) -> Bool {
        pr.jiraTicket?.isEmpty == false ||
            pr.jiraTitle?.isEmpty == false ||
            pr.jiraStatusName?.isEmpty == false ||
            pr.jiraStatusCategoryKey?.isEmpty == false ||
            pr.jiraLabels?.isEmpty == false
    }

    private func matchesJiraFields(_ pr: PullRequest, term: String) -> Bool {
        if let ticket = pr.jiraTicket, PRSearchScope.contains(term, in: ticket) { return true }
        if let title = pr.jiraTitle, PRSearchScope.contains(term, in: title) { return true }
        if let status = pr.jiraStatusName, PRSearchScope.contains(term, in: status) { return true }
        if let category = pr.jiraStatusCategoryKey, PRSearchScope.contains(term, in: category) { return true }
        if let labels = pr.jiraLabels, labels.contains(where: { PRSearchScope.contains(term, in: $0) }) { return true }
        return false
    }

    private func matchesCIState(_ pr: PullRequest, term: String) -> Bool {
        switch term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "any", "value":
            return pr.ciStatus != nil || pr.checkTotalCount > 0 || pr.ciIsRunning
        case "pass", "passed", "success", "green":
            return pr.ciStatus == .success
        case "failure", "fail", "failed", "failing", "red":
            return pr.ciStatus == .failure || pr.ciStatus == .unknown || pr.checkFailureCount > 0
        case "running", "pending", "inflight", "in-flight":
            return pr.ciIsInFlight
        default:
            return false
        }
    }

    private func matchesPRState(_ pr: PullRequest, term: String) -> Bool {
        switch term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "conflict", "conflicts":
            return pr.hasBaseConflicts
        default:
            return false
        }
    }

    private func matchesApprovalCount(_ pr: PullRequest, term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pr.approvalCount > 0 }

        let operators = [">=", "<=", "==", ">", "<", "="]
        let matchedOperator = operators.first { trimmed.hasPrefix($0) }
        let op = matchedOperator ?? "="
        let numberText = String(trimmed.dropFirst(matchedOperator?.count ?? 0))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let expected = Int(numberText) else { return false }

        switch op {
        case ">=":
            return pr.approvalCount >= expected
        case ">":
            return pr.approvalCount > expected
        case "<=":
            return pr.approvalCount <= expected
        case "<":
            return pr.approvalCount < expected
        case "=", "==":
            return pr.approvalCount == expected
        default:
            return false
        }
    }

    private func groupByRepo(_ prs: [PullRequest], sortByMergedDate: Bool = false) -> [(String, [PullRequest])] {
        let grouped = Dictionary(grouping: prs) { $0.repoFullName }
        return grouped
            .map { repo, prs in
                let sorted = prs.sorted {
                    let lhsDate = sortByMergedDate ? ($0.mergedAt ?? $0.updatedAt) : $0.updatedAt
                    let rhsDate = sortByMergedDate ? ($1.mergedAt ?? $1.updatedAt) : $1.updatedAt
                    return lhsDate > rhsDate
                }
                return (repo, sorted)
            }
            .sorted { $0.0 < $1.0 }
    }
}
