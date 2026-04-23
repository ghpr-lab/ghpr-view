import XCTest
@testable import PRDashboard

@MainActor
final class FlakyCIBotReportViewModelTests: XCTestCase {
    func testAnalyzeLaunchStartsInAnalyzingState() {
        let viewModel = FlakyCIBotReportViewModel(context: makeContext(number: 42), launchMode: .analyze)

        XCTAssertEqual(viewModel.state, .analyzing)
    }

    func testOpenReportLaunchStartsWithLatestBotResult() {
        let viewModel = FlakyCIBotReportViewModel(
            context: makeContext(number: 42),
            launchMode: .openReport(result: .realIssue(score: 64))
        )

        XCTAssertEqual(viewModel.state, .realIssue(score: 64))
    }

    func testRerunNowLaunchStartsInAnalyzingState() {
        let viewModel = FlakyCIBotReportViewModel(context: makeContext(number: 42), launchMode: .rerunNow)

        XCTAssertEqual(viewModel.state, .analyzing)
    }

    func testAnalyzeAgainTransitionsToAnalyzingState() {
        let viewModel = FlakyCIBotReportViewModel(
            context: makeContext(number: 42),
            launchMode: .openReport(result: .likelyFlaky(score: 78))
        )

        viewModel.analyzeAgain()

        XCTAssertEqual(viewModel.state, .analyzing)
    }

    func testRerunFailedCITransitionsToAnalyzingState() {
        let viewModel = FlakyCIBotReportViewModel(
            context: makeContext(number: 42),
            launchMode: .openReport(result: .likelyFlaky(score: 78))
        )

        viewModel.rerunFailedCI()

        XCTAssertEqual(viewModel.state, .analyzing)
    }

    func testUpdatingContextResetsStateForNewLaunchMode() {
        let original = makeContext(number: 42, title: "Original title")
        let replacement = makeContext(number: 108, title: "Replacement title")
        let viewModel = FlakyCIBotReportViewModel(
            context: original,
            launchMode: .openReport(result: .outdated)
        )

        viewModel.analyzeAgain()
        viewModel.update(context: replacement, launchMode: .openReport(result: .likelyFlaky(score: 78)))

        XCTAssertEqual(viewModel.context, replacement)
        XCTAssertEqual(viewModel.state, .likelyFlaky(score: 78))
    }

    private func makeContext(
        number: Int,
        title: String = "Fix flaky e2e pipeline on linux variants"
    ) -> FlakyCIBotContext {
        FlakyCIBotContext(
            repoFullName: "openresty/kong",
            number: number,
            title: title,
            url: URL(string: "https://github.com/openresty/kong/pull/\(number)")!
        )
    }
}
