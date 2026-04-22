import AppKit
import SwiftUI

struct CIDiagnosisMockView: View {
    @ObservedObject var viewModel: CIDiagnosisMockViewModel
    let onClose: () -> Void

    private let rawEvidenceSectionID = "raw-evidence-section"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statePicker
                    summaryCard
                    actionRow
                    evidenceCards
                }
                .padding(20)
            }
            .background(backgroundColor)
            .onChange(of: viewModel.rawEvidenceFocusToken) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(rawEvidenceSectionID, anchor: .bottom)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CI Diagnosis")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.primary)

            Text("\(viewModel.context.repoFullName)  #\(viewModel.context.number)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Text(viewModel.context.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
    }

    private var statePicker: some View {
        Picker(String(localized: "Preview State"), selection: Binding(
            get: { viewModel.state },
            set: { viewModel.selectState($0) }
        )) {
            ForEach(CIDiagnosisMockState.allCases) { state in
                Text(state.pickerTitle).tag(state)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("Preview State"))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                statusPill

                Spacer()

                summarySecondaryLabel
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.presentation.rationaleLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if viewModel.presentation.showsProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for fresh workflow updates…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background(cardBackgroundColor)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(primaryActionTitle) {
                handlePrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.presentation.primaryActionDisabled)

            Button(viewModel.presentation.secondaryActionTitle) {
                handleSecondaryAction()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Close") {
                onClose()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }

    private var evidenceCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            EvidenceCard(title: String(localized: "Failure Pattern")) {
                VStack(alignment: .leading, spacing: 10) {
                    if let callout = viewModel.presentation.failurePatternCallout {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(blockerAccentColor)
                            Text(callout)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(blockerAccentColor)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(blockerAccentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    EvidenceDetailRow(label: String(localized: "Script"), value: viewModel.presentation.failurePatternScript)
                    EvidenceDetailRow(label: String(localized: "Variants"), value: viewModel.presentation.failurePatternVariants)
                    EvidenceDetailRow(label: String(localized: "Summary"), value: viewModel.presentation.failurePatternFailedJobs)
                }
            }

            EvidenceCard(title: String(localized: "Changed Files Relevance")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.presentation.changedFilesVerdict)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    FilenameChipRow(files: viewModel.presentation.changedFiles)
                }
            }

            EvidenceCard(title: String(localized: "Copilot Assessment"), trailingText: String(localized: "via Copilot")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.presentation.copilotHeadline)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text(viewModel.presentation.copilotBody)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            EvidenceCard(
                title: String(localized: "Raw Evidence"),
                highlight: viewModel.isHighlightingRawEvidence
            ) {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { viewModel.isRawEvidenceExpanded },
                        set: { viewModel.setRawEvidenceExpanded($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(viewModel.presentation.rawEvidence.enumerated()), id: \.offset) { _, excerpt in
                            RawEvidenceRow(excerpt: excerpt)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Show failed job excerpts")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .id(rawEvidenceSectionID)
        }
    }

    private var primaryActionTitle: String {
        viewModel.presentation.primaryActionTitle
    }

    private func handlePrimaryAction() {
        switch viewModel.state {
        case .likelyFlaky:
            viewModel.triggerRerun()
        case .likelyBlocker:
            viewModel.revealRawEvidence()
        case .rerunTriggered:
            break
        }
    }

    private func handleSecondaryAction() {
        switch viewModel.state {
        case .likelyFlaky:
            viewModel.revealRawEvidence()
        case .likelyBlocker:
            viewModel.triggerRerun()
        case .rerunTriggered:
            viewModel.revealRawEvidence()
        }
    }

    private var statusPill: some View {
        Text(viewModel.state.statusTitle)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(statusAccentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusAccentColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var summarySecondaryLabel: some View {
        Text(viewModel.presentation.summarySecondaryText)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(viewModel.state == .rerunTriggered ? waitingAccentColor : .secondary)
    }

    private var statusAccentColor: Color {
        switch viewModel.state {
        case .likelyFlaky:
            return flakyAccentColor
        case .likelyBlocker:
            return blockerAccentColor
        case .rerunTriggered:
            return waitingAccentColor
        }
    }

    private var backgroundColor: Color {
        Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.965, blue: 0.955, alpha: 1))
    }

    private var cardBackgroundColor: Color {
        Color.white.opacity(0.98)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.black.opacity(0.08), lineWidth: 1)
    }

    private var flakyAccentColor: Color {
        Color(nsColor: NSColor(calibratedRed: 0.76, green: 0.53, blue: 0.11, alpha: 1))
    }

    private var blockerAccentColor: Color {
        Color(nsColor: NSColor(calibratedRed: 0.73, green: 0.25, blue: 0.22, alpha: 1))
    }

    private var waitingAccentColor: Color {
        Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.44, blue: 0.79, alpha: 1))
    }
}

private struct EvidenceCard<Content: View>: View {
    let title: String
    var trailingText: String? = nil
    var highlight = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            content
        }
        .padding(14)
        .background(Color.white.opacity(0.98))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(highlight ? Color.accentColor.opacity(0.55) : Color.black.opacity(0.07), lineWidth: highlight ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 8, x: 0, y: 3)
    }
}

private struct EvidenceDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FilenameChipRow: View {
    let files: [String]

    var body: some View {
        FlexibleChipLayout(items: files) { file in
            Text(file)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary.opacity(0.88))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.05))
                .clipShape(Capsule())
        }
    }
}

private struct FlexibleChipLayout<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RawEvidenceRow: View {
    let excerpt: CIDiagnosisMockRawExcerpt

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(excerpt.jobName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer()

                Text(excerpt.stepName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Text(excerpt.message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary.opacity(0.92))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct CIDiagnosisEntryConfirmationView: View {
    let context: CIDiagnosisMockContext
    let onCheckFlakyFirst: () -> Void
    let onRerunNow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rerun Failed CI")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 5) {
                Text("\(context.repoFullName)  #\(context.number)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Text(context.title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                Text("Choose whether to open the CI diagnosis prototype first or jump straight to the waiting state.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {
                Button("Check flaky first") {
                    onCheckFlakyFirst()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button("Rerun Failed CI now") {
                    onRerunNow()
                }
                .buttonStyle(.bordered)
            }

            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(18)
        .frame(width: 310)
        .background(Color.white.opacity(0.98))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 8)
    }
}

#if DEBUG
struct CIDiagnosisMockView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ZStack {
                Color(nsColor: NSColor.windowBackgroundColor)
                    .opacity(0.95)
                CIDiagnosisEntryConfirmationView(
                    context: sampleContext,
                    onCheckFlakyFirst: {},
                    onRerunNow: {},
                    onCancel: {}
                )
            }
            .frame(width: 400, height: 500)
            .previewDisplayName("Entry Confirmation")

            CIDiagnosisMockView(
                viewModel: CIDiagnosisMockViewModel(context: sampleContext, launchMode: .checkFlakyFirst),
                onClose: {}
            )
            .frame(width: 620, height: 480)
            .previewDisplayName("Likely Flaky")

            CIDiagnosisMockView(
                viewModel: blockerPreviewModel,
                onClose: {}
            )
            .frame(width: 620, height: 480)
            .previewDisplayName("Likely Blocker")

            CIDiagnosisMockView(
                viewModel: CIDiagnosisMockViewModel(context: sampleContext, launchMode: .rerunNow),
                onClose: {}
            )
            .frame(width: 620, height: 480)
            .previewDisplayName("Rerun Triggered")
        }
    }

    static var sampleContext: CIDiagnosisMockContext {
        CIDiagnosisMockContext(
            repoFullName: "openresty/kong",
            number: 1234,
            title: "Fix flaky e2e pipeline on linux variants",
            url: URL(string: "https://github.com/openresty/kong/pull/1234")!
        )
    }

    static var blockerPreviewModel: CIDiagnosisMockViewModel {
        let model = CIDiagnosisMockViewModel(context: sampleContext, launchMode: .checkFlakyFirst)
        model.selectState(.likelyBlocker)
        return model
    }
}
#endif
