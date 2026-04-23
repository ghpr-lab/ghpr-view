import Foundation

enum FlakyCIBotReportState: Equatable {
    case likelyFlaky(score: Int)
    case realIssue(score: Int)
    case needsInvestigation(score: Int)
    case analyzing
    case outdated

    var title: String {
        switch self {
        case .likelyFlaky:
            return String(localized: "Likely flaky")
        case .realIssue:
            return String(localized: "Likely real failure")
        case .needsInvestigation:
            return String(localized: "Needs investigation")
        case .analyzing:
            return String(localized: "Analysis in progress")
        case .outdated:
            return String(localized: "Result outdated")
        }
    }

    var compactLabel: String {
        switch self {
        case let .likelyFlaky(score):
            return String(localized: "Flaky \(score)")
        case let .realIssue(score):
            return String(localized: "Real issue \(score)")
        case let .needsInvestigation(score):
            return String(localized: "Investigate \(score)")
        case .analyzing:
            return String(localized: "Analyzing")
        case .outdated:
            return String(localized: "Outdated")
        }
    }
}

enum FlakyCIBotLaunchMode {
    case analyze
    case openReport(result: FlakyCIBotReportState)
    case rerunNow
}

struct FlakyCIBotContext: Equatable {
    let repoFullName: String
    let number: Int
    let title: String
    let url: URL
}

struct FlakyCIBotReportPresentation: Equatable {
    let state: FlakyCIBotReportState
    let scoreText: String
    let evidenceLine: String
    let updatedText: String
    let detailLine: String
    let primaryActionTitle: String
    let primaryActionDisabled: Bool
    let secondaryActionTitle: String
}

@MainActor
final class FlakyCIBotReportViewModel: ObservableObject {
    @Published private(set) var context: FlakyCIBotContext
    @Published private(set) var state: FlakyCIBotReportState

    init(context: FlakyCIBotContext, launchMode: FlakyCIBotLaunchMode) {
        self.context = context
        self.state = Self.initialState(for: launchMode)
    }

    func update(context: FlakyCIBotContext, launchMode: FlakyCIBotLaunchMode) {
        self.context = context
        state = Self.initialState(for: launchMode)
    }

    func analyzeAgain() {
        state = .analyzing
    }

    func rerunFailedCI() {
        state = .analyzing
    }

    var presentation: FlakyCIBotReportPresentation {
        switch state {
        case let .likelyFlaky(score):
            return FlakyCIBotReportPresentation(
                state: state,
                scoreText: String(localized: "Score \(score)/100"),
                evidenceLine: String(localized: "Based on 3 failed jobs across 2 images"),
                updatedText: String(localized: "Updated 2m ago"),
                detailLine: String(localized: "Bot report is available on GitHub as a Check Run and PR comment."),
                primaryActionTitle: String(localized: "Open Check Run"),
                primaryActionDisabled: false,
                secondaryActionTitle: String(localized: "Open PR Comment")
            )
        case let .realIssue(score):
            return FlakyCIBotReportPresentation(
                state: state,
                scoreText: String(localized: "Score \(score)/100"),
                evidenceLine: String(localized: "Repeated failure signature after rerun"),
                updatedText: String(localized: "Updated 4m ago"),
                detailLine: String(localized: "The bot found moderate overlap with helper and CI files."),
                primaryActionTitle: String(localized: "Open Check Run"),
                primaryActionDisabled: false,
                secondaryActionTitle: String(localized: "Open PR Comment")
            )
        case let .needsInvestigation(score):
            return FlakyCIBotReportPresentation(
                state: state,
                scoreText: String(localized: "Score \(score)/100"),
                evidenceLine: String(localized: "Signals are inconclusive"),
                updatedText: String(localized: "Updated recently"),
                detailLine: String(localized: "Open the report evidence before rerunning or marking this as a real failure."),
                primaryActionTitle: String(localized: "Open Check Run"),
                primaryActionDisabled: false,
                secondaryActionTitle: String(localized: "Open PR Comment")
            )
        case .analyzing:
            return FlakyCIBotReportPresentation(
                state: state,
                scoreText: String(localized: "Score pending"),
                evidenceLine: String(localized: "Flaky CI Bot is reading failed jobs and workflow logs"),
                updatedText: String(localized: "Queued just now"),
                detailLine: String(localized: "Results will be written back to GitHub when analysis completes."),
                primaryActionTitle: String(localized: "Open Check Run"),
                primaryActionDisabled: true,
                secondaryActionTitle: String(localized: "Open PR Comment")
            )
        case .outdated:
            return FlakyCIBotReportPresentation(
                state: state,
                scoreText: String(localized: "Previous commit"),
                evidenceLine: String(localized: "The PR head changed after this bot report was produced"),
                updatedText: String(localized: "Updated 18m ago"),
                detailLine: String(localized: "Analyze again to refresh the bot result for the current commit."),
                primaryActionTitle: String(localized: "Analyze again"),
                primaryActionDisabled: false,
                secondaryActionTitle: String(localized: "Open old report")
            )
        }
    }

    private static func initialState(for launchMode: FlakyCIBotLaunchMode) -> FlakyCIBotReportState {
        switch launchMode {
        case .analyze, .rerunNow:
            return .analyzing
        case let .openReport(result):
            return result
        }
    }
}
