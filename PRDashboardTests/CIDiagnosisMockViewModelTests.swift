import XCTest
@testable import PRDashboard

@MainActor
final class CIDiagnosisMockViewModelTests: XCTestCase {
    func testLaunchWithCheckFlakyFirstStartsInLikelyFlaky() {
        let viewModel = CIDiagnosisMockViewModel(context: makeContext(number: 42), launchMode: .checkFlakyFirst)

        XCTAssertEqual(viewModel.state, .likelyFlaky)
    }

    func testLaunchWithRerunNowStartsInRerunTriggered() {
        let viewModel = CIDiagnosisMockViewModel(context: makeContext(number: 42), launchMode: .rerunNow)

        XCTAssertEqual(viewModel.state, .rerunTriggered)
    }

    func testTriggerRerunTransitionsToTriggeredState() {
        let viewModel = CIDiagnosisMockViewModel(context: makeContext(number: 42), launchMode: .checkFlakyFirst)

        viewModel.selectState(.likelyBlocker)
        viewModel.triggerRerun()

        XCTAssertEqual(viewModel.state, .rerunTriggered)
    }

    func testRevealRawEvidenceExpandsAndHighlightsEvidence() {
        let viewModel = CIDiagnosisMockViewModel(context: makeContext(number: 42), launchMode: .checkFlakyFirst)
        let token = viewModel.rawEvidenceFocusToken

        viewModel.revealRawEvidence()

        XCTAssertTrue(viewModel.isRawEvidenceExpanded)
        XCTAssertTrue(viewModel.isHighlightingRawEvidence)
        XCTAssertNotEqual(token, viewModel.rawEvidenceFocusToken)
    }

    func testUpdatingContextResetsStateAndEvidenceDisclosure() {
        let original = makeContext(number: 42, title: "Original title")
        let replacement = makeContext(number: 108, title: "Replacement title")
        let viewModel = CIDiagnosisMockViewModel(context: original, launchMode: .checkFlakyFirst)

        viewModel.selectState(.likelyBlocker)
        viewModel.revealRawEvidence()
        viewModel.update(context: replacement, launchMode: .rerunNow)

        XCTAssertEqual(viewModel.context, replacement)
        XCTAssertEqual(viewModel.state, .rerunTriggered)
        XCTAssertFalse(viewModel.isRawEvidenceExpanded)
        XCTAssertFalse(viewModel.isHighlightingRawEvidence)
    }

    private func makeContext(
        number: Int,
        title: String = "Fix flaky e2e pipeline on linux variants"
    ) -> CIDiagnosisMockContext {
        CIDiagnosisMockContext(
            repoFullName: "openresty/kong",
            number: number,
            title: title,
            url: URL(string: "https://github.com/openresty/kong/pull/\(number)")!
        )
    }
}
