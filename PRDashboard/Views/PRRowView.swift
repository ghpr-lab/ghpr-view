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
    var onRerunFailedCI: (() -> Void)?
    var showCIStatus: Bool = true
    var showMyReviewStatus: Bool = false

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
                    Text(pr.repoFullName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("#\(pr.number)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
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
                        ApprovalBadge(count: pr.approvalCount)
                    }

                    Spacer()

                    if pr.category == .authored {
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
                            MyReviewStatusBadge(status: reviewStatus)
                        }
                    }

                    if pr.unresolvedCount > 0 {
                        Badge(count: pr.unresolvedCount)
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
            onOpen()
        }
        .contextMenu {
            Button("Open in Browser") {
                onOpen()
            }
            Button("Copy URL") {
                onCopyURL()
            }
            if pr.category == .authored && pr.checkFailureCount > 0 {
                Divider()
                Button {
                    onRerunFailedCI?()
                } label: {
                    Label("Rerun Failed CI", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

#Preview {
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
                lastCommitAt: Date(),
                headCommitOid: nil,
                reviewThreads: [
                    ReviewThread(id: "1", isResolved: false, isOutdated: false, path: nil, line: nil, comments: [])
                ],
                category: .authored,
                ciStatus: .failure,
                checkSuccessCount: 3,
                checkFailureCount: 2,
                checkPendingCount: 0,
                myLastReviewState: nil,
                myLastReviewAt: nil,
                reviewRequestedAt: nil,
                myThreadsAllResolved: false,
                approvalCount: 2
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
                lastCommitAt: Date(),
                headCommitOid: nil,
                reviewThreads: [],
                category: .reviewRequest,
                ciStatus: .success,
                checkSuccessCount: 5,
                checkFailureCount: 0,
                checkPendingCount: 0,
                myLastReviewState: .changesRequested,
                myLastReviewAt: Date().addingTimeInterval(-3600),
                reviewRequestedAt: nil,
                myThreadsAllResolved: false,
                approvalCount: 0
            ),
            onOpen: {},
            onCopyURL: {},
            showMyReviewStatus: true
        )
    }
    .frame(width: 350)
    .padding()
}
