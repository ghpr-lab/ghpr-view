import XCTest
@testable import PRDashboard

final class JiraSetupTests: XCTestCase {
    func testCloudURLNormalizationAndHostValidation() {
        XCTAssertEqual(JiraAPIClient.normalizedServerURL(" https://example.atlassian.net/ "), "https://example.atlassian.net")
        XCTAssertTrue(JiraAPIClient.isSupportedCloudServerURL("https://example.atlassian.net"))
        XCTAssertFalse(JiraAPIClient.isSupportedCloudServerURL("https://jira.example.com"))
    }

    func testIssueRouting() {
        XCTAssertEqual(
            JiraIssueOpenDecision.resolve(state: .notConfigured, serverURL: "", issueKey: "ACME-1"),
            .confirmSetup(issueKey: "ACME-1")
        )
        XCTAssertEqual(
            JiraIssueOpenDecision.resolve(state: .unauthorized, serverURL: "https://example.atlassian.net", issueKey: "ACME-1"),
            .confirmReconnect(issueKey: "ACME-1")
        )
        XCTAssertEqual(
            JiraIssueOpenDecision.resolve(state: .configured, serverURL: "https://example.atlassian.net", issueKey: "ACME-1"),
            .open(URL(string: "https://example.atlassian.net/browse/ACME-1")!)
        )
    }
    @MainActor
    func testConfiguredServerDraftStartsAtCredentials() {
        let coordinator = JiraSetupCoordinator(
            context: JiraSetupContext(source: .settings),
            connectionState: .configured,
            savedServerURL: "https://example.atlassian.net/",
            savedEmail: "user@example.com",
            savedTokenAvailable: true,
            testConnection: { _, _, _ in
                JiraConnectionTestResult(displayName: nil, emailAddress: nil)
            },
            commit: { _, _, _ in },
            openExternalURL: { _ in },
            dismiss: {}
        )

        XCTAssertEqual(coordinator.serverURL, "https://example.atlassian.net")
        XCTAssertEqual(coordinator.email, "user@example.com")
        XCTAssertEqual(coordinator.step, .credentials)
    }

    @MainActor
    func testUnauthorizedDraftStartsAtCredentials() {
        let coordinator = JiraSetupCoordinator(
            context: JiraSetupContext(source: .jiraIssue(key: "ACME-1")),
            connectionState: .unauthorized,
            savedServerURL: "https://example.atlassian.net",
            savedEmail: "user@example.com",
            savedTokenAvailable: true,
            testConnection: { _, _, _ in
                JiraConnectionTestResult(displayName: nil, emailAddress: nil)
            },
            commit: { _, _, _ in },
            openExternalURL: { _ in },
            dismiss: {}
        )

        XCTAssertEqual(coordinator.step, .credentials)
        XCTAssertTrue(coordinator.apiToken.isEmpty)
    }


    @MainActor
    func testSetupFinishCommitsAndOpensPendingIssueOnce() async {
        var commits = 0
        var opened: [URL] = []
        let coordinator = JiraSetupCoordinator(
            context: JiraSetupContext(source: .jiraIssue(key: "ACME-123")),
            savedServerURL: "",
            savedEmail: "",
            savedTokenAvailable: false,
            testConnection: { _, _, _ in JiraConnectionTestResult(displayName: "User", emailAddress: nil) },
            commit: { _, _, _ in commits += 1 },
            openExternalURL: { opened.append($0) },
            dismiss: {}
        )
        coordinator.serverURL = "https://example.atlassian.net/"
        coordinator.continueFromServer()
        coordinator.continueFromTokenInstructions()
        coordinator.email = "user@example.com"
        coordinator.apiToken = "token"
        coordinator.test()
        for _ in 0..<20 where coordinator.isTesting { await Task.yield() }
        XCTAssertTrue(coordinator.canFinish)
        coordinator.finish()
        coordinator.finish()
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(opened, [URL(string: "https://example.atlassian.net/browse/ACME-123")!])
    }
}
