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
    @Published private(set) var deviceCode: DeviceCodeInfo?
    @Published private(set) var isAuthenticating: Bool = false
    @Published private(set) var authError: Error?
    @Published private(set) var isValidatingPAT: Bool = false
    @Published private(set) var patError: Error?
    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty

    private let prManager: PRManager
    private let oauthManager: GitHubOAuthManager
    private var cancellables = Set<AnyCancellable>()

    var openSettings: (() -> Void)?

    init(prManager: PRManager, oauthManager: GitHubOAuthManager) {
        self.prManager = prManager
        self.oauthManager = oauthManager

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
    }

    // MARK: - Computed Properties

    var filteredPRs: [PullRequest] {
        let prs = prList.pullRequests

        guard !searchText.isEmpty else { return prs }

        let query = searchText.lowercased()
        return prs.filter { pr in
            pr.title.lowercased().contains(query) ||
            pr.repoFullName.lowercased().contains(query) ||
            pr.author.lowercased().contains(query) ||
            String(pr.number).contains(query)
        }
    }

    var authoredPRs: [PullRequest] {
        filteredPRs.filter { $0.category == .authored }
    }

    var reviewRequestPRs: [PullRequest] {
        filteredPRs.filter { $0.category == .reviewRequest }
    }

    var groupedAuthoredPRs: [(String, [PullRequest])] {
        groupByRepo(authoredPRs)
    }

    var groupedReviewPRs: [(String, [PullRequest])] {
        groupByRepo(reviewRequestPRs)
    }

    private var filteredMergedPRs: [PullRequest] {
        let prs = prList.mergedPullRequests

        guard !searchText.isEmpty else { return prs }

        let query = searchText.lowercased()
        return prs.filter { pr in
            pr.title.lowercased().contains(query) ||
            pr.repoFullName.lowercased().contains(query) ||
            pr.author.lowercased().contains(query) ||
            String(pr.number).contains(query)
        }
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

    // Backward compatibility for views still using the old naming.
    var mergedTodayPRs: [PullRequest] { mergedLast24hPRs }
    var groupedMergedTodayPRs: [(String, [PullRequest])] { groupedMergedLast24hPRs }

    var summaryReadyToMerge: Int {
        authoredPRs.filter { $0.approvalCount > 0 && $0.ciStatus == .success }.count
    }

    var summaryChangesRequested: Int {
        authoredPRs.filter { $0.changesRequestedCount > 0 }.count
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

    func showSettings() {
        openSettings?()
    }

    func openPR(_ pr: PullRequest) {
        NSWorkspace.shared.open(pr.url)
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
