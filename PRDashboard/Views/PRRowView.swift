import AppKit
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
    var onUpdateBranchWithRebase: (() -> Void)?
    var onLoadHoverDetail: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleCIAutoRetry: (() -> Void)?
    var isPinned: Bool = false
    var isOpening: Bool = false
    var isUpdatingBranch: Bool = false
    var isLoadingHoverDetail: Bool = false
    var ciAutoRetryRound: Int?  // nil = not active, 0-3 = current round
    var showCIStatus: Bool = true
    var showConflictStatus: Bool = true
    var showMyReviewStatus: Bool = false
    var showCmuxStatus: Bool = false
    var onboardingManager: OnboardingManager? = nil
    var approvalOnboardingPRID: Int? = nil
    var reviewStatusOnboardingPRID: Int? = nil

    @ObservedObject private var menuTracker = MenuTracker.shared
    @State private var isHovered = false

    private var updateBranchWithRebaseAction: (() -> Void)? {
        pr.category == .authored ? onUpdateBranchWithRebase : nil
    }

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

                    if showCmuxStatus, pr.isOpenInCmux == true {
                        Text("cmux")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.13))
                            .cornerRadius(4)
                            .delayedHoverTooltip(
                                String(localized: "This PR is currently open as a tab in cmux.")
                            )
                    }
                }

                // PR title
                Text(pr.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundColor(.primary)
                    .prHoverDetail(
                        pr,
                        onUpdateBranchWithRebase: updateBranchWithRebaseAction,
                        onLoadHoverDetail: onLoadHoverDetail,
                        isUpdatingBranch: isUpdatingBranch,
                        isLoadingHoverDetail: isLoadingHoverDetail
                    )

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

private enum PRHoverDetailSide {
    case left
    case right
}

private enum PRHoverDetailMetrics {
    static let cardWidth: CGFloat = 404
    static let rowHeight: CGFloat = 26
    static let rowSpacing: CGFloat = 4
    static let verticalPadding: CGFloat = 10
    static let maxFailedWorkflowRows: Int = 3
    static let failedWorkflowLineHeight: CGFloat = 17
    static let failedWorkflowLineSpacing: CGFloat = 2
    static let arrowWidth: CGFloat = 8
    static let arrowHeight: CGFloat = 16
    static let outsideGap: CGFloat = 0
    static let screenMargin: CGFloat = 8

    static func visibleFailedWorkflowCount(for pr: PullRequest) -> Int {
        min(pr.failedWorkflowNames.count, maxFailedWorkflowRows)
    }

    static func failedWorkflowLineCount(for pr: PullRequest) -> Int {
        let visibleCount = visibleFailedWorkflowCount(for: pr)
        guard visibleCount > 0 else { return 0 }
        return visibleCount + (pr.failedWorkflowNames.count > visibleCount ? 1 : 0)
    }

    static func checksRowHeight(for pr: PullRequest) -> CGFloat {
        let lineCount = failedWorkflowLineCount(for: pr)
        guard lineCount > 0 else { return 0 }
        let contentHeight = CGFloat(lineCount) * failedWorkflowLineHeight +
            CGFloat(max(lineCount - 1, 0)) * failedWorkflowLineSpacing
        return max(rowHeight, contentHeight)
    }

    static func cardHeight(for pr: PullRequest) -> CGFloat {
        let checksHeight = checksRowHeight(for: pr)
        let rowCount = 2 + (checksHeight > 0 ? 1 : 0)
        let rowsHeight = rowHeight * 2 + checksHeight
        return rowsHeight + CGFloat(max(rowCount - 1, 0)) * rowSpacing + verticalPadding * 2
    }

    static func windowSize(for pr: PullRequest) -> CGSize {
        CGSize(width: cardWidth + arrowWidth, height: cardHeight(for: pr))
    }
}

private enum PRHoverDetailPalette {
    private static func darkAware(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let background = darkAware(
        dark: NSColor(calibratedWhite: 0.14, alpha: 0.98),
        light: NSColor(calibratedRed: 1.0, green: 0.997, blue: 0.975, alpha: 0.98)
    )
    static let border = darkAware(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.12),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.14)
    )
    static let hairline = darkAware(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.08),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.055)
    )
    static let shadow = NSColor.black.withAlphaComponent(0.10)
}

private extension View {
    func prHoverDetail(
        _ pr: PullRequest,
        onUpdateBranchWithRebase: (() -> Void)?,
        onLoadHoverDetail: (() -> Void)?,
        isUpdatingBranch: Bool,
        isLoadingHoverDetail: Bool
    ) -> some View {
        background(PRHoverDetailTrackingArea(
            pr: pr,
            onUpdateBranchWithRebase: onUpdateBranchWithRebase,
            onLoadHoverDetail: onLoadHoverDetail,
            isUpdatingBranch: isUpdatingBranch,
            isLoadingHoverDetail: isLoadingHoverDetail
        ))
    }
}

private struct PRHoverDetailTrackingArea: NSViewRepresentable {
    let pr: PullRequest
    let onUpdateBranchWithRebase: (() -> Void)?
    let onLoadHoverDetail: (() -> Void)?
    let isUpdatingBranch: Bool
    let isLoadingHoverDetail: Bool

    func makeNSView(context: Context) -> PRHoverDetailTrackingView {
        let view = PRHoverDetailTrackingView()
        view.updatePayload(
            pr: pr,
            onUpdateBranchWithRebase: onUpdateBranchWithRebase,
            onLoadHoverDetail: onLoadHoverDetail,
            isUpdatingBranch: isUpdatingBranch,
            isLoadingHoverDetail: isLoadingHoverDetail
        )
        return view
    }

    func updateNSView(_ nsView: PRHoverDetailTrackingView, context: Context) {
        nsView.updatePayload(
            pr: pr,
            onUpdateBranchWithRebase: onUpdateBranchWithRebase,
            onLoadHoverDetail: onLoadHoverDetail,
            isUpdatingBranch: isUpdatingBranch,
            isLoadingHoverDetail: isLoadingHoverDetail
        )
    }
}

private final class PRHoverDetailTrackingView: NSView {
    private var pr: PullRequest?
    private var onUpdateBranchWithRebase: (() -> Void)?
    private var onLoadHoverDetail: (() -> Void)?
    private var isUpdatingBranch = false
    private var isLoadingHoverDetail = false

    private var trackingArea: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?
    private var isHovered = false
    private var didRequestHoverDetail = false

    func updatePayload(
        pr: PullRequest,
        onUpdateBranchWithRebase: (() -> Void)?,
        onLoadHoverDetail: (() -> Void)?,
        isUpdatingBranch: Bool,
        isLoadingHoverDetail: Bool
    ) {
        let prChanged = self.pr?.id != pr.id
        self.pr = pr
        self.onUpdateBranchWithRebase = onUpdateBranchWithRebase
        self.onLoadHoverDetail = onLoadHoverDetail
        self.isUpdatingBranch = isUpdatingBranch
        self.isLoadingHoverDetail = isLoadingHoverDetail

        if prChanged, isHovered {
            didRequestHoverDetail = false
            hideDetail()
            scheduleDetail()
        } else if PRHoverDetailPanelController.shared.isVisible(for: ownerID) {
            showDetail()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        didRequestHoverDetail = false
        PRHoverDetailPanelController.shared.cancelHide(ownerID: ownerID)
        scheduleDetail()
    }

    override func mouseMoved(with event: NSEvent) {
        guard PRHoverDetailPanelController.shared.isVisible(for: ownerID) else { return }
        showDetail()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        didRequestHoverDetail = false
        hoverTask?.cancel()
        hoverTask = nil
        PRHoverDetailPanelController.shared.scheduleHide(ownerID: ownerID)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            isHovered = false
            hideDetail()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private var ownerID: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    private func scheduleDetail() {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, self.isHovered else { return }
            self.showDetail()
        }
    }

    private func showDetail() {
        guard let pr else { return }
        requestHoverDetailIfNeeded()
        PRHoverDetailPanelController.shared.show(
            pr: pr,
            anchorView: self,
            ownerID: ownerID,
            onUpdateBranchWithRebase: onUpdateBranchWithRebase,
            isUpdatingBranch: isUpdatingBranch,
            isLoadingHoverDetail: isLoadingHoverDetail
        )
    }

    private func requestHoverDetailIfNeeded() {
        guard !didRequestHoverDetail else { return }
        didRequestHoverDetail = true
        onLoadHoverDetail?()
    }

    private func hideDetail() {
        hoverTask?.cancel()
        hoverTask = nil
        PRHoverDetailPanelController.shared.hide(ownerID: ownerID)
    }
}

enum PRHoverDetailPanelVisibilityKey {
    static let isVisible = "isVisible"
}

extension Notification.Name {
    static let prHoverDetailPanelVisibilityDidChange = Notification.Name("PRHoverDetailPanelVisibilityDidChange")
}

@MainActor
private final class PRHoverDetailPanelController {
    static let shared = PRHoverDetailPanelController()

    private var panel: NSPanel?
    private var visibleOwnerID: ObjectIdentifier?
    private weak var anchorView: NSView?
    private var hideTask: Task<Void, Never>?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    func isVisible(for ownerID: ObjectIdentifier) -> Bool {
        visibleOwnerID == ownerID && panel?.isVisible == true
    }

    func show(
        pr: PullRequest,
        anchorView: NSView,
        ownerID: ObjectIdentifier,
        onUpdateBranchWithRebase: (() -> Void)?,
        isUpdatingBranch: Bool,
        isLoadingHoverDetail: Bool
    ) {
        guard let placement = placement(for: anchorView, pr: pr) else { return }
        let wasVisible = visibleOwnerID != nil
        cancelHide(ownerID: ownerID)
        visibleOwnerID = ownerID
        self.anchorView = anchorView
        if !wasVisible {
            notifyVisibilityChanged(isVisible: true)
        }

        let rootView = PRHoverDetailPanelView(
            pr: pr,
            side: placement.side,
            arrowY: placement.arrowY,
            size: placement.frame.size,
            onUpdateBranchWithRebase: onUpdateBranchWithRebase,
            isUpdatingBranch: isUpdatingBranch,
            isLoadingHoverDetail: isLoadingHoverDetail
        )
        let hostingView = PRHoverDetailHostingView(rootView: AnyView(rootView))
        hostingView.ownerID = ownerID
        hostingView.frame = NSRect(origin: .zero, size: placement.frame.size)

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = hostingView
        panel.setFrame(placement.frame, display: true)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            ensureMouseMonitors()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            ensureMouseMonitors()
        }
    }

    func hide(ownerID: ObjectIdentifier) {
        guard visibleOwnerID == ownerID else { return }
        hideTask?.cancel()
        hideTask = nil
        visibleOwnerID = nil
        anchorView = nil
        removeMouseMonitors()
        guard let panel, panel.isVisible else {
            notifyVisibilityChanged(isVisible: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            guard self?.visibleOwnerID == nil else { return }
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            self?.notifyVisibilityChanged(isVisible: false)
        }
    }

    func scheduleHide(ownerID: ObjectIdentifier) {
        guard visibleOwnerID == ownerID else { return }
        guard hideTask == nil else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, self.visibleOwnerID == ownerID else { return }
            self.hideTask = nil
            if self.isPointerInsideHoverRegion() {
                return
            }
            self.hide(ownerID: ownerID)
        }
    }

    func cancelHide(ownerID: ObjectIdentifier) {
        guard visibleOwnerID == ownerID else { return }
        hideTask?.cancel()
        hideTask = nil
    }

    func panelMouseEntered(ownerID: ObjectIdentifier) {
        cancelHide(ownerID: ownerID)
    }

    func panelMouseExited(ownerID: ObjectIdentifier) {
        scheduleHide(ownerID: ownerID)
    }

    func panelMouseMoved(ownerID: ObjectIdentifier) {
        guard visibleOwnerID == ownerID else { return }
        if isPointerInsideHoverRegion() {
            cancelHide(ownerID: ownerID)
        } else {
            scheduleHide(ownerID: ownerID)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: PRHoverDetailMetrics.cardWidth, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func placement(
        for anchorView: NSView,
        pr: PullRequest
    ) -> (frame: NSRect, side: PRHoverDetailSide, arrowY: CGFloat)? {
        guard let window = anchorView.window else { return nil }

        let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorScreen = window.convertToScreen(anchorInWindow)
        let popoverFrame = window.frame
        let screen = window.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? popoverFrame
        let size = PRHoverDetailMetrics.windowSize(for: pr)

        let rightSpace = visibleFrame.maxX - popoverFrame.maxX
        let leftSpace = popoverFrame.minX - visibleFrame.minX
        let side: PRHoverDetailSide = rightSpace >= size.width + PRHoverDetailMetrics.outsideGap || rightSpace >= leftSpace
            ? .right
            : .left

        let rawX: CGFloat
        switch side {
        case .right:
            rawX = popoverFrame.maxX + PRHoverDetailMetrics.outsideGap
        case .left:
            rawX = popoverFrame.minX - PRHoverDetailMetrics.outsideGap - size.width
        }

        let minX = visibleFrame.minX + PRHoverDetailMetrics.screenMargin
        let maxX = visibleFrame.maxX - size.width - PRHoverDetailMetrics.screenMargin
        let x = min(max(rawX, minX), maxX)

        let anchorMidY = anchorScreen.midY
        let rawY = anchorMidY - size.height / 2
        let minY = visibleFrame.minY + PRHoverDetailMetrics.screenMargin
        let maxY = visibleFrame.maxY - size.height - PRHoverDetailMetrics.screenMargin
        let y = min(max(rawY, minY), maxY)

        let arrowY = min(
            max((y + size.height) - anchorMidY, 18),
            size.height - 18
        )

        return (
            NSRect(x: x, y: y, width: size.width, height: size.height),
            side,
            arrowY
        )
    }

    private func ensureMouseMonitors() {
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                Task { @MainActor in
                    self?.handlePointerMoved()
                }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePointerMoved()
                }
            }
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func handlePointerMoved() {
        guard let ownerID = visibleOwnerID else { return }
        if isPointerInsideHoverRegion() {
            cancelHide(ownerID: ownerID)
        } else {
            scheduleHide(ownerID: ownerID)
        }
    }

    private func isPointerInsideHoverRegion() -> Bool {
        guard let panel,
              panel.isVisible,
              let anchorView,
              let window = anchorView.window else {
            return false
        }

        let mouseLocation = NSEvent.mouseLocation
        let anchorFrame = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
            .insetBy(dx: -10, dy: -18)
        let panelFrame = panel.frame.insetBy(dx: -6, dy: -6)

        if anchorFrame.contains(mouseLocation) || panelFrame.contains(mouseLocation) {
            return true
        }

        let minX = min(anchorFrame.minX, panelFrame.minX)
        let maxX = max(anchorFrame.maxX, panelFrame.maxX)
        let minY = min(anchorFrame.minY, panelFrame.minY) - 30
        let maxY = max(anchorFrame.maxY, panelFrame.maxY) + 30
        let bridge = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return bridge.contains(mouseLocation)
    }

    private func notifyVisibilityChanged(isVisible: Bool) {
        NotificationCenter.default.post(
            name: .prHoverDetailPanelVisibilityDidChange,
            object: nil,
            userInfo: [PRHoverDetailPanelVisibilityKey.isVisible: isVisible]
        )
    }
}

private final class PRHoverDetailHostingView: NSHostingView<AnyView> {
    var ownerID: ObjectIdentifier?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard let ownerID else { return }
        PRHoverDetailPanelController.shared.panelMouseEntered(ownerID: ownerID)
    }

    override func mouseExited(with event: NSEvent) {
        guard let ownerID else { return }
        PRHoverDetailPanelController.shared.panelMouseExited(ownerID: ownerID)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let ownerID else { return }
        PRHoverDetailPanelController.shared.panelMouseMoved(ownerID: ownerID)
    }
}

private struct PRHoverDetailPanelView: View {
    let pr: PullRequest
    let side: PRHoverDetailSide
    let arrowY: CGFloat
    let size: CGSize
    let onUpdateBranchWithRebase: (() -> Void)?
    let isUpdatingBranch: Bool
    let isLoadingHoverDetail: Bool

    private var cardOffsetX: CGFloat {
        side == .right ? PRHoverDetailMetrics.arrowWidth : 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PRHoverDetailShape(side: side, arrowY: arrowY)
                .fill(Color(nsColor: PRHoverDetailPalette.background))
                .overlay(
                    PRHoverDetailShape(side: side, arrowY: arrowY)
                        .stroke(Color(nsColor: PRHoverDetailPalette.border), lineWidth: 1)
                )
                .shadow(color: Color(nsColor: PRHoverDetailPalette.shadow), radius: 6, y: 1)

            content
                .frame(
                    width: PRHoverDetailMetrics.cardWidth,
                    height: size.height,
                    alignment: .topLeading
                )
                .offset(x: cardOffsetX)
        }
        .frame(width: size.width, height: size.height)
    }

    private var content: some View {
        PRHoverDetailInfoTable(
            pr: pr,
            onUpdateBranchWithRebase: onUpdateBranchWithRebase,
            isUpdatingBranch: isUpdatingBranch,
            isLoadingHoverDetail: isLoadingHoverDetail
        )
            .padding(.horizontal, 12)
            .padding(.vertical, PRHoverDetailMetrics.verticalPadding)
    }
}

private struct PRHoverDetailInfoTable: View {
    let pr: PullRequest
    let onUpdateBranchWithRebase: (() -> Void)?
    let isUpdatingBranch: Bool
    let isLoadingHoverDetail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PRHoverDetailMetrics.rowSpacing) {
            baseRow
            reviewsRow
            if !pr.failedWorkflowNames.isEmpty {
                checksRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var baseRow: some View {
        PRHoverDetailRow(label: "Base") {
            HStack(spacing: 7) {
                Text(baseBranchText)
                    .font(branchFont)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: canUpdateWithRebase ? 98 : 158, alignment: .leading)

                PRHoverDetailInlineStatus(
                    icon: baseStatusIcon,
                    text: baseStatusText,
                    color: baseStatusColor,
                    maxWidth: canUpdateWithRebase ? 86 : 122
                )

                if canUpdateWithRebase {
                    Button(action: { onUpdateBranchWithRebase?() }) {
                        HStack(spacing: 4) {
                            if isUpdatingBranch {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.45)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text("Rebase")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(height: 18)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isUpdatingBranch)
                    .help("Update with rebase")
                }
            }
        }
    }

    private var reviewsRow: some View {
        PRHoverDetailRow(label: "Reviews") {
            if reviewsAreLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.45)
                        .frame(width: 11, height: 11)
                    Text("Loading review details")
                        .font(valueFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 8) {
                    PRHoverDetailInlineStatus(
                        icon: approvalIcon,
                        text: approvalText,
                        color: approvalColor,
                        maxWidth: 206
                    )

                    Text("·")
                        .font(valueFont)
                        .foregroundColor(.secondary)

                    PRHoverDetailInlineStatus(
                        icon: changesIcon,
                        text: changesRequestedText,
                        color: changesColor,
                        maxWidth: 108
                    )
                }
            }
        }
    }

    private var checksRow: some View {
        PRHoverDetailRow(
            label: "Checks",
            height: PRHoverDetailMetrics.checksRowHeight(for: pr),
            topAligned: true
        ) {
            VStack(alignment: .leading, spacing: PRHoverDetailMetrics.failedWorkflowLineSpacing) {
                ForEach(visibleFailedWorkflowNames, id: \.self) { workflowName in
                    PRHoverDetailInlineStatus(
                        icon: "xmark.circle.fill",
                        text: workflowName,
                        color: .red
                    )
                    .frame(height: PRHoverDetailMetrics.failedWorkflowLineHeight, alignment: .leading)
                }

                if hiddenFailedWorkflowCount > 0 {
                    PRHoverDetailInlineStatus(
                        icon: "ellipsis.circle",
                        text: "+\(hiddenFailedWorkflowCount) more failed",
                        color: .secondary
                    )
                    .frame(height: PRHoverDetailMetrics.failedWorkflowLineHeight, alignment: .leading)
                }
            }
        }
    }

    private var valueFont: Font {
        .system(size: 11.5, weight: .medium)
    }

    private var branchFont: Font {
        .system(size: 11, weight: .medium, design: .monospaced)
    }

    private var baseBranchText: String {
        pr.baseRefName?.isEmpty == false ? pr.baseRefName! : "unknown"
    }

    private var reviewsAreLoading: Bool {
        (pr.approvalAuthors == nil || pr.changesRequestedAuthors == nil) && isLoadingHoverDetail
    }

    private var approvalText: String {
        if let authors = pr.approvalAuthors, !authors.isEmpty {
            return "Approved by \(authors.joined(separator: ", "))"
        }
        if pr.approvalCount > 0 {
            return "\(pr.approvalCount) approved"
        }
        return "No approvals"
    }

    private var changesRequestedText: String {
        if let authors = pr.changesRequestedAuthors, !authors.isEmpty {
            return "Changes by \(authors.joined(separator: ", "))"
        }
        let count = pr.changesRequestedCount ?? 0
        if count > 0 {
            return "\(count) requested"
        }
        return "No changes"
    }

    private var baseStatus: (text: String, icon: String, color: Color) {
        if pr.hasBaseConflicts {
            return ("Conflict", "xmark.octagon.fill", .red)
        }
        switch pr.baseNeedsUpdate {
        case .some(true):
            return ("Out-of-date", "arrow.triangle.2.circlepath", .orange)
        case .some(false):
            return ("Up to date", "checkmark.circle.fill", .green)
        case .none:
            if isLoadingHoverDetail {
                return ("Checking", "clock", .secondary)
            }
            return ("Unknown", "questionmark.circle", .secondary)
        }
    }

    private var baseStatusText: String { baseStatus.text }
    private var baseStatusIcon: String { baseStatus.icon }
    private var baseStatusColor: Color { baseStatus.color }

    private var hasApprovals: Bool {
        pr.approvalAuthors?.isEmpty == false || pr.approvalCount > 0
    }

    private var hasChangesRequested: Bool {
        pr.changesRequestedAuthors?.isEmpty == false || (pr.changesRequestedCount ?? 0) > 0
    }

    private var approvalIcon: String {
        hasApprovals ? "checkmark.circle.fill" : "checkmark.circle"
    }

    private var approvalColor: Color {
        hasApprovals ? .green : .secondary
    }

    private var changesIcon: String {
        hasChangesRequested ? "xmark.circle.fill" : "xmark.circle"
    }

    private var changesColor: Color {
        hasChangesRequested ? .red : .secondary
    }

    private var canUpdateWithRebase: Bool {
        pr.category == .authored &&
            pr.baseNeedsUpdate == true &&
            pr.graphqlNodeId != nil &&
            onUpdateBranchWithRebase != nil
    }

    private var visibleFailedWorkflowNames: [String] {
        Array(pr.failedWorkflowNames.prefix(PRHoverDetailMetrics.maxFailedWorkflowRows))
    }

    private var hiddenFailedWorkflowCount: Int {
        max(pr.failedWorkflowNames.count - PRHoverDetailMetrics.maxFailedWorkflowRows, 0)
    }
}

private struct PRHoverDetailRow<Content: View>: View {
    let label: String
    let height: CGFloat
    let topAligned: Bool
    let content: Content

    init(
        label: String,
        height: CGFloat = PRHoverDetailMetrics.rowHeight,
        topAligned: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.height = height
        self.topAligned = topAligned
        self.content = content()
    }

    var body: some View {
        HStack(alignment: topAligned ? .top : .center, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)
                .padding(.top, topAligned ? 1 : 0)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height, alignment: topAligned ? .topLeading : .center)
    }
}

private struct PRHoverDetailInlineStatus: View {
    let icon: String
    let text: String
    let color: Color
    var maxWidth: CGFloat?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 12)

            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

private struct PRHoverDetailShape: Shape {
    let side: PRHoverDetailSide
    let arrowY: CGFloat

    func path(in rect: CGRect) -> Path {
        let arrowWidth = PRHoverDetailMetrics.arrowWidth
        let arrowHalfHeight = PRHoverDetailMetrics.arrowHeight / 2
        let radius: CGFloat = 12
        let cardRect: CGRect

        switch side {
        case .right:
            cardRect = CGRect(
                x: rect.minX + arrowWidth,
                y: rect.minY,
                width: rect.width - arrowWidth,
                height: rect.height
            )
        case .left:
            cardRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width - arrowWidth,
                height: rect.height
            )
        }

        let arrowCenterY = min(max(arrowY, radius + arrowHalfHeight), rect.height - radius - arrowHalfHeight)
        var path = Path()

        path.move(to: CGPoint(x: cardRect.minX + radius, y: cardRect.minY))
        path.addLine(to: CGPoint(x: cardRect.maxX - radius, y: cardRect.minY))
        path.addQuadCurve(
            to: CGPoint(x: cardRect.maxX, y: cardRect.minY + radius),
            control: CGPoint(x: cardRect.maxX, y: cardRect.minY)
        )

        if side == .left {
            path.addLine(to: CGPoint(x: cardRect.maxX, y: arrowCenterY - arrowHalfHeight))
            path.addLine(to: CGPoint(x: cardRect.maxX + arrowWidth, y: arrowCenterY))
            path.addLine(to: CGPoint(x: cardRect.maxX, y: arrowCenterY + arrowHalfHeight))
        }

        path.addLine(to: CGPoint(x: cardRect.maxX, y: cardRect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: cardRect.maxX - radius, y: cardRect.maxY),
            control: CGPoint(x: cardRect.maxX, y: cardRect.maxY)
        )
        path.addLine(to: CGPoint(x: cardRect.minX + radius, y: cardRect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: cardRect.minX, y: cardRect.maxY - radius),
            control: CGPoint(x: cardRect.minX, y: cardRect.maxY)
        )

        if side == .right {
            path.addLine(to: CGPoint(x: cardRect.minX, y: arrowCenterY + arrowHalfHeight))
            path.addLine(to: CGPoint(x: cardRect.minX - arrowWidth, y: arrowCenterY))
            path.addLine(to: CGPoint(x: cardRect.minX, y: arrowCenterY - arrowHalfHeight))
        }

        path.addLine(to: CGPoint(x: cardRect.minX, y: cardRect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: cardRect.minX + radius, y: cardRect.minY),
            control: CGPoint(x: cardRect.minX, y: cardRect.minY)
        )
        path.closeSubpath()
        return path
    }
}
