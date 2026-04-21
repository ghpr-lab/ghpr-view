import AppKit
import SwiftUI

private enum HoverTooltipPalette {
    private static func darkAware(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let background = darkAware(
        dark: NSColor(calibratedWhite: 0.16, alpha: 0.98),
        light: NSColor(calibratedWhite: 0.97, alpha: 0.98)
    )
    static let foreground = NSColor.labelColor
    static let border = darkAware(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.12)
    )
    static let shadow = darkAware(
        dark: NSColor.black.withAlphaComponent(0.32),
        light: NSColor.black.withAlphaComponent(0.16)
    )
}

enum HoverTooltipCoordinateSpace {
    static let name = "hover-tooltip-root"
}

final class HoverTooltipPresenter: ObservableObject {
    struct Tooltip: Equatable {
        let ownerID: UUID
        let text: String
        let point: CGPoint
    }

    @Published private(set) var tooltip: Tooltip?

    func show(ownerID: UUID, text: String, point: CGPoint) {
        tooltip = Tooltip(ownerID: ownerID, text: text, point: point)
    }

    func update(ownerID: UUID, text: String, point: CGPoint) {
        guard let current = tooltip, current.ownerID == ownerID else { return }
        // onContinuousHover fires per mouse movement (~60-120 Hz). Skip sub-pixel
        // updates so the overlay doesn't re-layout on every frame.
        if current.text == text,
           abs(current.point.x - point.x) < 1,
           abs(current.point.y - point.y) < 1
        {
            return
        }
        tooltip = Tooltip(ownerID: ownerID, text: text, point: point)
    }

    func hide(ownerID: UUID) {
        guard tooltip?.ownerID == ownerID else { return }
        tooltip = nil
    }

    func isVisible(for ownerID: UUID) -> Bool {
        tooltip?.ownerID == ownerID
    }
}

private struct HoverTooltipPresenterKey: EnvironmentKey {
    static let defaultValue: HoverTooltipPresenter?
        = nil
}

extension EnvironmentValues {
    var hoverTooltipPresenter: HoverTooltipPresenter? {
        get { self[HoverTooltipPresenterKey.self] }
        set { self[HoverTooltipPresenterKey.self] = newValue }
    }
}

private struct HoverTooltipSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct HoverTooltipOverlay: View {
    @ObservedObject var presenter: HoverTooltipPresenter
    @State private var measuredSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            if let tooltip = presenter.tooltip {
                tooltipBubble(text: tooltip.text)
                    .background(
                        GeometryReader { bubbleGeometry in
                            Color.clear.preference(
                                key: HoverTooltipSizePreferenceKey.self,
                                value: bubbleGeometry.size
                            )
                        }
                    )
                    .onPreferenceChange(HoverTooltipSizePreferenceKey.self) { size in
                        measuredSize = size
                    }
                    .onChange(of: tooltip.ownerID) { _ in
                        measuredSize = .zero
                    }
                    .opacity(measuredSize == .zero ? 0 : 1)
                    .position(position(for: tooltip, in: geometry.size))
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private func tooltipBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: NSFont.smallSystemFontSize))
            .foregroundColor(Color(nsColor: HoverTooltipPalette.foreground))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: Self.tooltipWidth(for: text), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: HoverTooltipPalette.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: HoverTooltipPalette.border), lineWidth: 0.5)
            )
            .shadow(color: Color(nsColor: HoverTooltipPalette.shadow), radius: 6, y: 2)
    }

    private static let tooltipFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    private static func tooltipWidth(for text: String) -> CGFloat {
        // Real glyph measurement so CJK/emoji widths don't fall back to a
        // Latin-only heuristic. +20 accounts for horizontal padding.
        let attrs: [NSAttributedString.Key: Any] = [.font: tooltipFont]
        let single = (text as NSString).size(withAttributes: attrs).width + 20
        return min(max(single, 140), 260)
    }

    private func position(for tooltip: HoverTooltipPresenter.Tooltip, in containerSize: CGSize) -> CGPoint {
        guard measuredSize != .zero else {
            return CGPoint(x: tooltip.point.x, y: tooltip.point.y)
        }
        let margin: CGFloat = 8
        let originX = axisOrigin(
            point: tooltip.point.x,
            size: measuredSize.width,
            container: containerSize.width,
            offset: 14,
            margin: margin
        )
        let originY = axisOrigin(
            point: tooltip.point.y,
            size: measuredSize.height,
            container: containerSize.height,
            offset: 18,
            margin: margin
        )
        return CGPoint(x: originX + measuredSize.width / 2, y: originY + measuredSize.height / 2)
    }

    private func axisOrigin(
        point: CGFloat,
        size: CGFloat,
        container: CGFloat,
        offset: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        let after = point + offset
        let before = point - size - offset
        if after + size <= container - margin { return after }
        if before >= margin { return before }
        let clampMax = max(margin, container - size - margin)
        return min(max(after, margin), clampMax)
    }
}

private struct DelayedHoverTooltipModifier: ViewModifier {
    let text: String
    let delayNanoseconds: UInt64

    @Environment(\.hoverTooltipPresenter) private var presenter

    @State private var ownerID = UUID()
    @State private var isHovered = false
    @State private var latestPoint: CGPoint = .zero
    @State private var showTask: Task<Void, Never>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let presenter {
            content
                .onContinuousHover(coordinateSpace: .named(HoverTooltipCoordinateSpace.name)) { phase in
                    switch phase {
                    case .active(let point):
                        latestPoint = point

                        if !isHovered {
                            isHovered = true
                            scheduleTooltip(presenter: presenter)
                        } else if presenter.isVisible(for: ownerID) {
                            presenter.update(ownerID: ownerID, text: text, point: point)
                        }
                    case .ended:
                        isHovered = false
                        hideTooltip(presenter: presenter)
                    }
                }
                .onDisappear {
                    isHovered = false
                    hideTooltip(presenter: presenter)
                }
        } else {
            content
        }
    }

    private func scheduleTooltip(presenter: HoverTooltipPresenter) {
        showTask?.cancel()
        showTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, isHovered else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                presenter.show(ownerID: ownerID, text: text, point: latestPoint)
            }
        }
    }

    private func hideTooltip(presenter: HoverTooltipPresenter) {
        showTask?.cancel()
        showTask = nil

        withAnimation(.easeOut(duration: 0.08)) {
            presenter.hide(ownerID: ownerID)
        }
    }
}

extension View {
    func delayedHoverTooltip(_ text: String, delayNanoseconds: UInt64 = 500_000_000) -> some View {
        modifier(DelayedHoverTooltipModifier(text: text, delayNanoseconds: delayNanoseconds))
    }
}

struct Badge: View {
    let count: Int
    var color: Color = .red

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(Capsule())
                .animation(.spring(response: 0.25), value: count)
        }
    }
}

struct DraftBadge: View {
    var body: some View {
        Text("Draft")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
            .delayedHoverTooltip(
                String(localized: "This PR is a draft and not ready for review.")
            )
    }
}

struct MyReviewStatusBadge: View {
    let status: MyReviewStatus

    var body: some View {
        HStack(spacing: 2) {
            Text(emoji)
                .font(.system(size: 11))
            Text(abbreviation)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(textColor)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(backgroundColor)
        .clipShape(Capsule())
        .delayedHoverTooltip(
            String(
                localized:
                    "This shows your review state: ⏳ waiting, 🟥 changes requested, 🟨 changes resolved, ✅ approved."
            )
        )
    }

    private var emoji: String {
        switch status {
        case .waiting: return "⏳"
        case .changesRequested: return "🟥"
        case .changesResolved: return "🟨"
        case .approved: return "✅"
        }
    }

    private var abbreviation: String {
        switch status {
        case .waiting: return "W"
        case .changesRequested: return "CR-"
        case .changesResolved: return "CR+"
        case .approved: return "A"
        }
    }

    private var textColor: Color {
        switch status {
        case .waiting: return .secondary
        case .changesRequested: return .red
        case .changesResolved: return .orange
        case .approved: return .green
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .waiting: return Color.secondary.opacity(0.15)
        case .changesRequested: return Color.red.opacity(0.15)
        case .changesResolved: return Color.orange.opacity(0.15)
        case .approved: return Color.green.opacity(0.15)
        }
    }
}

struct ApprovalBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(.green)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.15))
        .clipShape(Capsule())
        .delayedHoverTooltip(
            String(localized: "This shows how many approvals this PR has received.")
        )
    }
}

struct ConflictBadge: View {
    var body: some View {
        Text("Conflict")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.red)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.15))
            .clipShape(Capsule())
            .delayedHoverTooltip(
                String(localized: "This PR has conflicts with the base branch.")
            )
    }
}

#if DEBUG
struct Badge_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 10) {
            Badge(count: 5)
            Badge(count: 99)
            Badge(count: 100)
            DraftBadge()
            MyReviewStatusBadge(status: .waiting)
            MyReviewStatusBadge(status: .changesRequested)
            MyReviewStatusBadge(status: .changesResolved)
            MyReviewStatusBadge(status: .approved)
            ApprovalBadge(count: 2)
            ConflictBadge()
        }
        .padding()
    }
}
#endif
