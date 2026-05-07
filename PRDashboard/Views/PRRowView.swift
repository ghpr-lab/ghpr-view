import SwiftUI
import Combine

private class MenuTracker: ObservableObject {
    static let shared = MenuTracker()
    @Published private(set) var isTracking = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.isTracking = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.isTracking = false }
            .store(in: &cancellables)
    }
}

struct PRRowView: View {
    let pr: PullRequest
    let onOpen: () -> Void
    let onCopyURL: () -> Void
    var onMarkReviewCommentsRead: (() -> Void)?
    var onMarkReviewCommentsUnread: (() -> Void)?
    var onRerunFailedCI: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleCIAutoRetry: (() -> Void)?
    var isPinned: Bool = false
    var isOpening: Bool = false
    var ciAutoRetryRound: Int?  // nil = not active, 0-3 = current round
    var showCIStatus: Bool = true
    var showConflictStatus: Bool = true
    var showMyReviewStatus: Bool = false
    var onboardingManager: OnboardingManager? = nil
    var approvalOnboardingPRID: Int? = nil
    var reviewStatusOnboardingPRID: Int? = nil

    @ObservedObject private var menuTracker = MenuTracker.shared
    @State private var isHovered = false

    private var timeDisplay: String {
        let displayDate = pr.lastCommitAt ?? pr.updatedAt
        let prefix = pr.lastCommitAt == nil ? "~" : ""

        if abs(displayDate.timeIntervalSinceNow) < 24 * 60 * 60 {
            return prefix + DateFormatters.relativeString(from: displayDate)
        } else {
            return prefix + DateFormatters.shortDateTime.string(from: displayDate)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Author avatar
            CachedAvatarView(url: pr.authorAvatarURL, authorInitial: pr.author)
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                // Repo and PR number
                HStack(spacing: 4) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }

                    Text(pr.repoFullName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("#\(pr.number)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    if let ticket = pr.jiraTicket {
                        Text(ticket)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(4)
                            .delayedHoverTooltip(
                                String(localized: "This is the Jira ticket linked to this PR.")
                            )
                    }
                }

                // PR title
                Text(pr.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundColor(.primary)

                // Author and badges
                HStack(spacing: 6) {
                    Text(pr.author)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text(timeDisplay)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if pr.isDraft {
                        DraftBadge()
                    }

                    if pr.approvalCount > 0 {
                        approvalBadge
                    }

                    if showConflictStatus, pr.hasBaseConflicts {
                        ConflictBadge()
                    }

                    Spacer()

                    if isOpening {
                        ProgressView()
                            .scaleEffect(0.45)
                            .frame(width: 14, height: 14)
                            .help("Opening PR")
                    }

                    if pr.category == .authored || pr.category == .mentioned {
                        if showCIStatus, let ciStatus = pr.ciStatus {
                            CIStatusIcon(
                                status: ciStatus,
                                successCount: pr.checkSuccessCount,
                                failureCount: pr.checkFailureCount,
                                pendingCount: pr.checkPendingCount,
                                isRunning: pr.ciIsRunning,
                                workflows: pr.ciWorkflows
                            )
                        }
                    } else if pr.category == .reviewRequest {
                        if showMyReviewStatus, let reviewStatus = pr.myReviewStatus {
                            reviewStatusBadge(reviewStatus)
                        }
                    }

                    if pr.unreadUnresolvedCount > 0 {
                        Badge(count: pr.unreadUnresolvedCount)
                            .delayedHoverTooltip(
                                String(
                                    localized:
                                        "This shows how many unread unresolved review comments this PR has."
                                )
                            )
                    } else if pr.readUnresolvedCount > 0 {
                        Badge(count: pr.readUnresolvedCount, color: .gray)
                            .delayedHoverTooltip(
                                String(
                                    localized:
                                        "All current unresolved review comments on this PR are marked as read."
                                )
                            )
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { hovering in
            if !menuTracker.isTracking {
                isHovered = hovering
            }
        }
        .onChange(of: menuTracker.isTracking) { isTracking in
            if !isTracking {
                isHovered = false
            }
        }
        .onTapGesture {
            guard !isOpening else { return }
            onOpen()
        }
        .contextMenu {
            Button("Open in Browser") {
                onOpen()
            }
            .disabled(isOpening)
            Button("Copy URL") {
                onCopyURL()
            }
            let canMarkRead = pr.unreadUnresolvedCount > 0 && onMarkReviewCommentsRead != nil
            let canMarkUnread = pr.readUnresolvedCount > 0 && onMarkReviewCommentsUnread != nil
            if canMarkRead || canMarkUnread {
                Divider()
                if canMarkRead, let onMarkReviewCommentsRead {
                    Button {
                        DispatchQueue.main.async { onMarkReviewCommentsRead() }
                    } label: {
                        Label("Mark as Read", systemImage: "checkmark.circle")
                    }
                }
                if canMarkUnread, let onMarkReviewCommentsUnread {
                    Button {
                        DispatchQueue.main.async { onMarkReviewCommentsUnread() }
                    } label: {
                        Label("Mark as Unread", systemImage: "circle.fill")
                    }
                }
            }
            if let onTogglePin {
                Divider()
                Button {
                    DispatchQueue.main.async { onTogglePin() }
                } label: {
                    Label(
                        isPinned ? "Unpin" : "Pin to Top",
                        systemImage: isPinned ? "pin.slash" : "pin"
                    )
                }
            }
            if let onToggleCIAutoRetry, pr.category == .authored,
                (ciAutoRetryRound != nil || pr.ciIsRunning || pr.checkFailureCount > 0) {
                Divider()
                if let round = ciAutoRetryRound {
                    Button {
                        DispatchQueue.main.async { onToggleCIAutoRetry() }
                    } label: {
                        Label("Cancel Auto-retry (\(round)/3)", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        DispatchQueue.main.async { onToggleCIAutoRetry() }
                    } label: {
                        Label("Auto-retry CI (3x)", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            if pr.category == .authored && pr.checkFailureCount > 0 {
                if onToggleCIAutoRetry == nil {
                    Divider()
                }
                Button {
                    DispatchQueue.main.async { onRerunFailedCI?() }
                } label: {
                    Label("Rerun Failed CI", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder
    private var approvalBadge: some View {
        let badge = ApprovalBadge(count: pr.approvalCount)
            .preference(key: FirstApprovalBadgeIDPreferenceKey.self, value: pr.id)

        if let onboardingManager, approvalOnboardingPRID == pr.id {
            badge.onboardingAnchor(onboardingManager, step: .approvals)
        } else {
            badge
        }
    }

    @ViewBuilder
    private func reviewStatusBadge(_ reviewStatus: MyReviewStatus) -> some View {
        let badge = MyReviewStatusBadge(status: reviewStatus)
            .preference(key: FirstReviewStatusBadgeIDPreferenceKey.self, value: pr.id)

        if let onboardingManager, reviewStatusOnboardingPRID == pr.id {
            badge.onboardingAnchor(onboardingManager, step: .myReviewStatus)
        } else {
            badge
        }
    }
}

#if DEBUG
struct PRRowView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            PRRowView(
                pr: PullRequest(
                    id: 1,
                    number: 123,
                    title: "Add new feature for user authentication with OAuth 2.0",
                    author: "xiaocang",
                    authorAvatarURL: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"),
                    repositoryOwner: "owner",
                    repositoryName: "repo",
                    url: URL(string: "https://github.com/owner/repo/pull/123")!,
                    state: .open,
                    isDraft: true,
                    createdAt: Date(),
                    updatedAt: Date(),
                    mergedAt: nil,
                    body: "Mentions #456",
                    conversationComments: [],
                    lastCommitAt: Date(),
                    headCommitOid: nil,
                    reviewThreads: [
                        ReviewThread(id: "1", isResolved: false, isOutdated: false, path: nil, line: nil, comments: [])
                    ],
                    category: .authored,
                    hasBaseConflicts: true,
                    ciStatus: .failure,
                    checkSuccessCount: 3,
                    checkFailureCount: 2,
                    checkPendingCount: 0,
                    myLastReviewState: nil,
                    myLastReviewAt: nil,
                    reviewRequestedAt: nil,
                    myThreadsAllResolved: false,
                    approvalCount: 2,
                    changesRequestedCount: 0,
                    jiraTicket: "AG-1234"
                ),
                onOpen: {},
                onCopyURL: {}
            )
            PRRowView(
                pr: PullRequest(
                    id: 2,
                    number: 456,
                    title: "Review requested: Fix bug in payment processing",
                    author: "otherdev",
                    authorAvatarURL: nil,
                    repositoryOwner: "owner",
                    repositoryName: "repo",
                    url: URL(string: "https://github.com/owner/repo/pull/456")!,
                    state: .open,
                    isDraft: false,
                    createdAt: Date(),
                    updatedAt: Date(),
                    mergedAt: nil,
                    body: nil,
                    conversationComments: [],
                    lastCommitAt: Date(),
                    headCommitOid: nil,
                    reviewThreads: [],
                    category: .reviewRequest,
                    hasBaseConflicts: false,
                    ciStatus: .success,
                    checkSuccessCount: 5,
                    checkFailureCount: 0,
                    checkPendingCount: 0,
                    myLastReviewState: .changesRequested,
                    myLastReviewAt: Date().addingTimeInterval(-3600),
                    reviewRequestedAt: nil,
                    myThreadsAllResolved: false,
                    approvalCount: 0,
                    changesRequestedCount: 0
                ),
                onOpen: {},
                onCopyURL: {},
                showMyReviewStatus: true
            )
        }
        .frame(width: 350)
        .padding()
    }
}
#endif
