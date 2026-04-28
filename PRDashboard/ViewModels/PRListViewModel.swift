import Foundation
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.prdashboard", category: "PRListViewModel")

@MainActor
final class PRListViewModel: ObservableObject {
    @Published var prList: PRList = .empty
    @Published var searchText: String = ""
    @Published private(set) var authState: AuthState = .empty
    @Published private(set) var pinnedPRIdentifiers: Set<String> = []
    @Published private(set) var pinChangeToken = UUID()
    @Published private(set) var ciRetryTracking: [String: CIRetryState] = [:]
    @Published private(set) var deviceCode: DeviceCodeInfo?
    @Published private(set) var isAuthenticating: Bool = false
    @Published private(set) var authError: Error?
    @Published private(set) var isValidatingPAT: Bool = false
    @Published private(set) var patError: Error?
    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty

    private let prManager: PRManager
    private let oauthManager: GitHubOAuthManager
    private let linkOpener: PRLinkOpener
    private var cancellables = Set<AnyCancellable>()

    var openSettings: (() -> Void)?

    init(prManager: PRManager, oauthManager: GitHubOAuthManager, linkOpener: PRLinkOpener) {
        self.prManager = prManager
        self.oauthManager = oauthManager
        self.linkOpener = linkOpener

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

        // Match the pin binding above to avoid an extra queue hop for row state.
        prManager.$ciRetryTracking
            .sink { [weak self] tracking in
                self?.ciRetryTracking = tracking
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

    var mentionedPRs: [PullRequest] {
        filterPRs(prList.mentionedPullRequests)
    }

    var groupedAuthoredPRs: [(String, [PullRequest])] {
        groupByRepo(unpinnedAuthoredPRs)
    }

    var groupedReviewPRs: [(String, [PullRequest])] {
        groupByRepo(reviewRequestPRs)
    }

    var groupedMentionedPRs: [(String, [PullRequest])] {
        groupByRepo(mentionedPRs)
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
        authoredPRs.filter { $0.approvalCount > 0 && $0.ciStatus == .success && ($0.changesRequestedCount ?? 0) == 0 }.count
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

    // MARK: - Actions

    func refresh() {
        prManager.refresh()
    }

    func clearCaches() {
        PRCache.shared.clear()
        PRDetailCache.shared.clear()
        MentionCache.shared.clear()
        AvatarCache.shared.clear()
        prManager.refresh()
    }

    func showSettings() {
        openSettings?()
    }

    func openPR(_ pr: PullRequest) {
        linkOpener.open(pr.url)
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

    func togglePin(_ pr: PullRequest) {
        let identifier = pr.pinIdentifier
        prManager.togglePinPR(identifier)
        pinnedPRIdentifiers = prManager.pinnedPRIdentifiers
        logger.info("Pin toggled: \(identifier) → pinned=\(self.pinnedPRIdentifiers.contains(identifier)), total=\(self.pinnedPRIdentifiers.count)")

        // Force SwiftUI to rebuild the authored PRs section after context menu dismisses.
        // Changing pinChangeToken invalidates the .id() on the section container in MainView,
        // causing a full view tree rebuild that cannot be diff-optimized away.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.pinChangeToken = UUID()
        }
    }

    /// Returns nil if auto-retry is not active, otherwise the max retry round (0-3).
    func ciAutoRetryRound(for pr: PullRequest) -> Int? {
        guard let state = ciRetryTracking[pr.pinIdentifier] else { return nil }
        return state.maxRetryRound
    }

    func enableCIAutoRetry(_ pr: PullRequest) {
        prManager.enableCIAutoRetry(for: pr)
    }

    func cancelCIAutoRetry(_ pr: PullRequest) {
        prManager.cancelCIAutoRetry(for: pr)
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

    // MARK: - Private

    private func filterPRs(_ prs: [PullRequest]) -> [PullRequest] {
        guard !searchText.isEmpty else { return prs }

        let query = searchText.lowercased()
        return prs.filter { pr in
            pr.title.lowercased().contains(query) ||
            pr.repoFullName.lowercased().contains(query) ||
            pr.author.lowercased().contains(query) ||
            String(pr.number).contains(query)
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
