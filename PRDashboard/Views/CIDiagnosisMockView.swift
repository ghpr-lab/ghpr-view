import AppKit
import SwiftUI

struct FlakyCIBotReportView: View {
    @ObservedObject var viewModel: FlakyCIBotReportViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summary
            actions
        }
        .padding(18)
        .frame(width: 320)
        .background(backgroundColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Flaky CI Bot", systemImage: "ladybug")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }

            Text("\(viewModel.context.repoFullName)  #\(viewModel.context.number)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Text(viewModel.context.title)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                statusPill

                Spacer()

                Text(viewModel.presentation.scoreText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            if viewModel.state == .analyzing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.presentation.evidenceLine)
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(viewModel.presentation.evidenceLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(viewModel.presentation.detailLine)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(viewModel.presentation.updatedText)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.9))
        }
        .padding(14)
        .background(Color.white.opacity(0.98))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(viewModel.presentation.primaryActionTitle) {
                    handlePrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.presentation.primaryActionDisabled)

                Button(viewModel.presentation.secondaryActionTitle) {
                    openPR()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.state == .analyzing)
            }

            HStack(spacing: 12) {
                Button("Analyze again") {
                    viewModel.analyzeAgain()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button("Rerun Failed CI") {
                    viewModel.rerunFailedCI()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .font(.system(size: 12))
        }
    }

    private var statusPill: some View {
        Text(viewModel.state.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(viewModel.state.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(viewModel.state.accentColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private func handlePrimaryAction() {
        if viewModel.state == .outdated {
            viewModel.analyzeAgain()
        } else {
            openPR()
        }
    }

    private func openPR() {
        NSWorkspace.shared.open(viewModel.context.url)
    }

    private var backgroundColor: Color {
        Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.965, blue: 0.955, alpha: 1))
    }
}

struct FlakyCIBotStatusLabel: View {
    let state: FlakyCIBotReportState

    var body: some View {
        HStack(spacing: 4) {
            if state == .analyzing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.45)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(state.accentColor)
                    .frame(width: 5, height: 5)
            }

            Text(state.compactLabel)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(state.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(state.accentColor.opacity(0.1))
        .clipShape(Capsule())
        .delayedHoverTooltip(helpText)
    }

    private var helpText: String {
        switch state {
        case let .likelyFlaky(score):
            return String(
                localized:
                    "Flaky CI Bot: likely flaky, score \(score)/100. The latest bot report says this failure looks more like CI flakiness than a PR blocker. Right-click this PR and choose Open Bot Report for evidence."
            )
        case let .realIssue(score):
            return String(
                localized:
                    "Flaky CI Bot: likely real failure, score \(score)/100. The bot found signals that are less consistent with flakiness. Review the report before rerunning. Right-click this PR and choose Open Bot Report for details."
            )
        case let .needsInvestigation(score):
            return String(
                localized:
                    "Flaky CI Bot: needs investigation, score \(score)/100. Signals are inconclusive, so check the bot evidence before deciding whether to rerun or debug. Right-click this PR and choose Open Bot Report."
            )
        case .analyzing:
            return String(
                localized:
                    "Flaky CI Bot is analyzing failed GitHub Actions jobs and workflow logs for this PR. This tag does not rerun CI. Right-click this PR and choose Open Bot Report to track the result."
            )
        case .outdated:
            return String(
                localized:
                    "Flaky CI Bot result is outdated because the PR head changed after the report was produced. Right-click this PR and choose Analyze Flaky CI to refresh it."
            )
        }
    }
}

struct FlakyCIBotRetryConfirmationView: View {
    let context: FlakyCIBotContext
    let onAnalyze: () -> Void
    let onRerunNow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Before rerunning")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(context.repoFullName)  #\(context.number)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Text(context.title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                Text("Would you like Flaky CI Bot to analyze whether this failure is flaky before rerunning?")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {
                Button("Analyze Flaky CI") {
                    onAnalyze()
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
        .frame(width: 315)
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
struct FlakyCIBotReportView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ZStack {
                Color(nsColor: NSColor.windowBackgroundColor)
                    .opacity(0.95)
                FlakyCIBotRetryConfirmationView(
                    context: sampleContext,
                    onAnalyze: {},
                    onRerunNow: {},
                    onCancel: {}
                )
            }
            .frame(width: 400, height: 500)
            .previewDisplayName("Retry Confirmation")

            FlakyCIBotReportView(
                viewModel: FlakyCIBotReportViewModel(context: sampleContext, launchMode: .openReport(result: .likelyFlaky(score: 78))),
                onClose: {}
            )
            .previewDisplayName("Bot Report")

            FlakyCIBotReportView(
                viewModel: FlakyCIBotReportViewModel(context: sampleContext, launchMode: .analyze),
                onClose: {}
            )
            .previewDisplayName("Analyzing")

            HStack {
                FlakyCIBotStatusLabel(state: .likelyFlaky(score: 78))
                FlakyCIBotStatusLabel(state: .realIssue(score: 64))
                FlakyCIBotStatusLabel(state: .needsInvestigation(score: 50))
                FlakyCIBotStatusLabel(state: .analyzing)
                FlakyCIBotStatusLabel(state: .outdated)
            }
            .padding()
            .previewDisplayName("Row Labels")
        }
    }

    static var sampleContext: FlakyCIBotContext {
        FlakyCIBotContext(
            repoFullName: "openresty/kong",
            number: 1234,
            title: "Fix flaky e2e pipeline on linux variants",
            url: URL(string: "https://github.com/openresty/kong/pull/1234")!
        )
    }
}
#endif
