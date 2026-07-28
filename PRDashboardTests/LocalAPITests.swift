import XCTest
@testable import PRDashboard

final class LocalAPITests: XCTestCase {
    func testSnapshotFactoryBuildsCountsSectionsAndPinnedState() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let authored = makePullRequest(
            id: 101,
            number: 101,
            title: "Ready to merge",
            category: .authored,
            updatedAt: now.addingTimeInterval(-60),
            reviewThreads: [makeUnresolvedThread()],
            ciStatus: .success,
            approvalCount: 1
        )
        let review = makePullRequest(
            id: 202,
            number: 202,
            title: "Needs my review",
            category: .reviewRequest,
            updatedAt: now.addingTimeInterval(-120),
            ciStatus: .pending,
            checkPendingCount: 1,
            ciExtendedInfo: CIExtendedInfo(isRunning: true, workflows: [])
        )
        let mentioned = makePullRequest(
            id: 303,
            number: 303,
            title: "Mentioned PR",
            category: .mentioned,
            updatedAt: now.addingTimeInterval(-180)
        )
        let directMention = makePullRequest(
            id: 304,
            number: 304,
            title: "Directly mentioned PR",
            category: .directMention,
            updatedAt: now.addingTimeInterval(-200)
        )
        let mergedRecent = makePullRequest(
            id: 404,
            number: 404,
            title: "Merged recently",
            category: .authored,
            updatedAt: now.addingTimeInterval(-240),
            mergedAt: now.addingTimeInterval(-60 * 60)
        )
        let mergedOld = makePullRequest(
            id: 505,
            number: 505,
            title: "Merged too long ago",
            category: .authored,
            updatedAt: now.addingTimeInterval(-300),
            mergedAt: now.addingTimeInterval(-25 * 60 * 60)
        )

        let prList = PRList(
            lastUpdated: now.addingTimeInterval(-30),
            pullRequests: [authored, review],
            mentionedPullRequests: [mentioned],
            directMentionPullRequests: [directMention],
            mergedPullRequests: [mergedRecent, mergedOld],
            isLoading: false,
            error: nil
        )

        let snapshot = LocalSnapshotFactory.makeSnapshot(
            input: makeInput(
                authState: AuthState(accessToken: "token", username: "tester", authMethod: .oauth),
                prList: prList,
                pinnedPRIdentifiers: [authored.pinIdentifier],
                rateLimitInfo: RateLimitInfo(
                    limit: 5000,
                    remaining: 4321,
                    resetDate: now.addingTimeInterval(600)
                )
            ),
            now: now
        )

        XCTAssertEqual(snapshot.summary.authored, 1)
        XCTAssertEqual(snapshot.summary.reviewRequests, 1)
        XCTAssertEqual(snapshot.summary.mentioned, 1)
        XCTAssertEqual(snapshot.summary.directMentions, 1)
        XCTAssertEqual(snapshot.summary.mergedLast24h, 1)
        XCTAssertEqual(snapshot.summary.authoredUnresolved, 1)
        XCTAssertEqual(snapshot.summary.totalUnresolved, 1)
        XCTAssertEqual(snapshot.summary.readyToMerge, 1)
        XCTAssertEqual(snapshot.summary.ciRunning, 1)
        XCTAssertEqual(snapshot.summary.waitingForMyReview, 1)
        XCTAssertEqual(snapshot.auth.username, "tester")
        XCTAssertEqual(snapshot.auth.method, "oauth")
        XCTAssertEqual(snapshot.rateLimit.remaining, 4321)
        XCTAssertEqual(snapshot.pullRequests.authored.first?.isPinned, true)
        XCTAssertEqual(snapshot.pullRequests.authored.first?.ciStatus, "SUCCESS")
        XCTAssertEqual(snapshot.pullRequests.reviewRequests.first?.myReviewStatus, "waiting")
        XCTAssertEqual(snapshot.pullRequests.directMentions.map(\.number), [304])
        XCTAssertEqual(
            GHPRCLI.pullRequests(in: snapshot, section: .directMentions, limit: nil).map(\.number),
            [304]
        )
        XCTAssertEqual(snapshot.pullRequests.mergedLast24h.map(\.number), [404])
    }

    func testSnapshotFactoryUsesMinimumApprovalsForReadyToMerge() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let oneApproval = makePullRequest(
            id: 601,
            number: 601,
            title: "One approval",
            category: .authored,
            updatedAt: now,
            approvalCount: 1
        )
        let twoApprovals = makePullRequest(
            id: 602,
            number: 602,
            title: "Two approvals",
            category: .authored,
            updatedAt: now,
            approvalCount: 2
        )

        let snapshot = LocalSnapshotFactory.makeSnapshot(
            input: makeInput(
                prList: PRList(
                    lastUpdated: now,
                    pullRequests: [oneApproval, twoApprovals],
                    isLoading: false,
                    error: nil
                ),
                minimumApprovalsForReadyToMerge: 2
            ),
            now: now
        )

        XCTAssertEqual(
            snapshot.summary.readyToMerge,
            1,
            "Only the PR with two approvals should be ready to merge"
        )
    }

    func testSnapshotFactoryReportsUnauthenticatedEmptyState() {
        let snapshot = LocalSnapshotFactory.makeSnapshot(
            input: makeInput(authState: .empty, prList: .empty),
            now: Date(timeIntervalSince1970: 1_775_000_000)
        )

        XCTAssertFalse(snapshot.auth.isAuthenticated)
        XCTAssertNil(snapshot.auth.username)
        XCTAssertNil(snapshot.auth.method)
        XCTAssertEqual(snapshot.summary.authored, 0)
        XCTAssertTrue(snapshot.pullRequests.authored.isEmpty)
    }

    func testSnapshotFactoryPinsReviewRequestsWithinReviewSection() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let unpinned = makePullRequest(
            id: 201,
            number: 201,
            title: "Newer review request",
            category: .reviewRequest,
            updatedAt: now
        )
        let pinned = makePullRequest(
            id: 202,
            number: 202,
            title: "Pinned review request",
            category: .reviewRequest,
            updatedAt: now.addingTimeInterval(-3600)
        )
        let prList = PRList(
            lastUpdated: now,
            pullRequests: [unpinned, pinned],
            mentionedPullRequests: [],
            mergedPullRequests: [],
            isLoading: false,
            error: nil
        )

        let snapshot = LocalSnapshotFactory.makeSnapshot(
            input: makeInput(
                prList: prList,
                pinnedPRIdentifiers: [pinned.pinIdentifier]
            ),
            now: now
        )

        XCTAssertEqual(snapshot.pullRequests.reviewRequests.map(\.number), [202, 201])
        XCTAssertEqual(snapshot.pullRequests.reviewRequests.first?.isPinned, true)
        XCTAssertTrue(snapshot.pullRequests.authored.isEmpty)
    }

    func testCLIParserUsesEnvironmentSocketAndFlags() throws {
        let envOptions = try GHPRCLI.parse(
            arguments: ["status"],
            environment: [LocalSocketPath.environmentVariable: "/tmp/env.sock"]
        )
        XCTAssertEqual(envOptions.command, .status)
        XCTAssertEqual(envOptions.socketPath, "/tmp/env.sock")

        let options = try GHPRCLI.parse(
            arguments: ["prs", "--json", "--section", "review", "--limit", "2", "--socket", "/tmp/explicit.sock"],
            environment: [LocalSocketPath.environmentVariable: "/tmp/env.sock"]
        )
        XCTAssertEqual(options.command, .prs)
        XCTAssertTrue(options.json)
        XCTAssertEqual(options.section, .review)
        XCTAssertEqual(options.limit, 2)
        XCTAssertEqual(options.socketPath, "/tmp/explicit.sock")

        let directMentionOptions = try GHPRCLI.parse(
            arguments: ["prs", "--section", "direct-mentions"],
            environment: [:]
        )
        XCTAssertEqual(directMentionOptions.section, .directMentions)
    }

    func testCLIRendersStatusAndFilteredPRRows() throws {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let authored = makePullRequest(
            id: 101,
            number: 101,
            title: "Ready to merge",
            category: .authored,
            updatedAt: now,
            ciStatus: .success
        )
        let review = makePullRequest(
            id: 202,
            number: 202,
            title: "Review me",
            category: .reviewRequest,
            updatedAt: now.addingTimeInterval(-60)
        )
        let snapshot = LocalSnapshotFactory.makeSnapshot(
            input: makeInput(
                authState: AuthState(accessToken: "token", username: "tester", authMethod: .pat),
                prList: PRList(
                    lastUpdated: now,
                    pullRequests: [authored, review],
                    isLoading: false,
                    error: nil
                )
            ),
            now: now
        )

        let status = GHPRCLI.renderStatus(snapshot)
        XCTAssertTrue(status.contains("Auth: tester (pat)"))
        XCTAssertTrue(status.contains("authored 1, review 1"))

        let authoredTable = GHPRCLI.renderPRs(snapshot, section: .authored, limit: nil)
        XCTAssertTrue(authoredTable.contains("#101"))
        XCTAssertTrue(authoredTable.contains("Ready to merge"))
        XCTAssertFalse(authoredTable.contains("#202"))

        let json = try GHPRCLI.renderJSON(
            GHPRPRsOutput(
                section: .authored,
                pullRequests: GHPRCLI.pullRequests(in: snapshot, section: .authored, limit: 1)
            )
        )
        let decoded = try LocalAPIJSON.decode(GHPRPRsOutput.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.pullRequests.map(\.number), [101])
    }

    func testCLIRendersIgnoredFailuresSeparatelyFromEffectiveFailureCount() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        var pr = makePullRequest(
            id: 303,
            number: 303,
            title: "Ignored workflow failure",
            category: .authored,
            updatedAt: now,
            ciStatus: .success
        )
        pr.checkFailureCount = 1

        let snapshot = LocalSnapshotFactory.makeSnapshot(
            input: makeInput(
                prList: PRList(
                    lastUpdated: now,
                    pullRequests: [pr],
                    isLoading: false,
                    error: nil
                )
            ),
            now: now
        )

        guard let snapshotPR = snapshot.pullRequests.authored.first else {
            XCTFail("Expected authored PR in snapshot")
            return
        }
        let output = GHPRCLI.renderPR(snapshotPR)

        XCTAssertTrue(output.contains("CI: SUCCESS"))
        XCTAssertTrue(output.contains("Checks: success 1, failure 0, pending 0, ignored 1"))
    }

    func testLocalAPIRejectsUnsupportedCommandsWithoutBuildingSnapshot() {
        var didBuildSnapshot = false
        let response = LocalAPIHandler.response(
            for: LocalAPIRequest(command: "bogus"),
            snapshotProvider: {
                didBuildSnapshot = true
                return LocalSnapshotFactory.makeSnapshot(input: makeInput())
            }
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, LocalAPIErrorCode.unsupportedCommand.rawValue)
        XCTAssertFalse(didBuildSnapshot)
    }

    func testLocalAPIDecodingRejectsInvalidJSON() {
        XCTAssertThrowsError(
            try LocalAPIJSON.decode(LocalAPIRequest.self, from: Data("{".utf8))
        )
    }

    func testLocalAPIPrCommandReturnsMatchingPullRequest() {
        let snapshot = makeTwoPRSnapshot()

        let response = LocalAPIHandler.response(
            for: LocalAPIRequest(command: .pr, repository: "OWNER/repo", number: 202),
            snapshotProvider: { snapshot }
        )

        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.pullRequest?.number, 202)
        XCTAssertEqual(response.pullRequest?.section, .review)
    }

    func testLocalAPIPrCommandReturnsNotFoundWhenMissing() {
        let snapshot = makeTwoPRSnapshot()

        let response = LocalAPIHandler.response(
            for: LocalAPIRequest(command: .pr, repository: "owner/repo", number: 999),
            snapshotProvider: { snapshot }
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, LocalAPIErrorCode.notFound.rawValue)
    }

    func testLocalAPIPrCommandRequiresRepositoryAndNumber() {
        let response = LocalAPIHandler.response(
            for: LocalAPIRequest(command: .pr, repository: "  ", number: nil),
            snapshotProvider: { fatalError("snapshot should not be built") }
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, LocalAPIErrorCode.invalidRequest.rawValue)
    }

    func testCLIParsesPrCommandWithRepoAndNumber() throws {
        let options = try GHPRCLI.parse(
            arguments: ["pr", "--repo", "owner/repo", "--number", "42", "--json"],
            environment: [:]
        )
        XCTAssertEqual(options.command, .pr)
        XCTAssertEqual(options.repository, "owner/repo")
        XCTAssertEqual(options.number, 42)
        XCTAssertTrue(options.json)

        let equalsOptions = try GHPRCLI.parse(
            arguments: ["pr", "--repo=owner/repo", "--number=7"],
            environment: [:]
        )
        XCTAssertEqual(equalsOptions.repository, "owner/repo")
        XCTAssertEqual(equalsOptions.number, 7)
    }

    func testCLIRejectsPrNumberThatIsNotPositive() {
        XCTAssertThrowsError(
            try GHPRCLI.parse(
                arguments: ["pr", "--repo", "owner/repo", "--number", "0"],
                environment: [:]
            )
        )
    }

    private func makeTwoPRSnapshot() -> LocalSnapshot {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let authored = makePullRequest(
            id: 101,
            number: 101,
            title: "Authored",
            category: .authored,
            updatedAt: now
        )
        let review = makePullRequest(
            id: 202,
            number: 202,
            title: "Review",
            category: .reviewRequest,
            updatedAt: now.addingTimeInterval(-60)
        )
        return LocalSnapshotFactory.makeSnapshot(
            input: makeInput(
                authState: AuthState(accessToken: "token", username: "tester", authMethod: .pat),
                prList: PRList(
                    lastUpdated: now,
                    pullRequests: [authored, review],
                    isLoading: false,
                    error: nil
                )
            ),
            now: now
        )
    }

    private func makeInput(
        authState: AuthState = .empty,
        prList: PRList = .empty,
        pinnedPRIdentifiers: Set<String> = [],
        rateLimitInfo: RateLimitInfo = .empty,
        minimumApprovalsForReadyToMerge: Int = 1
    ) -> LocalSnapshotInput {
        LocalSnapshotInput(
            appVersion: "1.2.3",
            buildVersion: "42",
            bundleIdentifier: "com.xiaocang.PRDashboard",
            authState: authState,
            prList: prList,
            rateLimitInfo: rateLimitInfo,
            pinnedPRIdentifiers: pinnedPRIdentifiers,
            minimumApprovalsForReadyToMerge: minimumApprovalsForReadyToMerge,
            refreshStatus: "idle",
            refreshError: nil
        )
    }

    private func makeUnresolvedThread() -> ReviewThread {
        ReviewThread(
            id: "thread-1",
            isResolved: false,
            isOutdated: false,
            path: nil,
            line: nil,
            comments: [
                ReviewComment(
                    id: "comment-1",
                    author: "reviewer",
                    body: "Needs follow-up",
                    createdAt: Date()
                )
            ]
        )
    }

    private func makePullRequest(
        id: Int,
        number: Int,
        title: String,
        category: PRCategory,
        updatedAt: Date,
        mergedAt: Date? = nil,
        reviewThreads: [ReviewThread] = [],
        ciStatus: CIStatus? = .success,
        checkPendingCount: Int = 0,
        ciExtendedInfo: CIExtendedInfo? = nil,
        approvalCount: Int = 0
    ) -> PullRequest {
        PullRequest(
            id: id,
            number: number,
            title: title,
            author: "tester",
            authorAvatarURL: nil,
            repositoryOwner: "owner",
            repositoryName: "repo",
            url: URL(string: "https://github.com/owner/repo/pull/\(number)")!,
            state: mergedAt == nil ? .open : .merged,
            isDraft: false,
            createdAt: updatedAt.addingTimeInterval(-3600),
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            body: nil,
            conversationComments: [],
            lastCommitAt: updatedAt,
            headCommitOid: "abc123",
            reviewThreads: reviewThreads,
            category: category,
            hasBaseConflicts: false,
            ciStatus: ciStatus,
            checkSuccessCount: ciStatus == .success ? 1 : 0,
            checkFailureCount: ciStatus == .failure ? 1 : 0,
            checkPendingCount: checkPendingCount,
            githubCIState: ciStatus?.rawValue,
            myLastReviewState: nil,
            myLastReviewAt: nil,
            reviewRequestedAt: nil,
            myThreadsAllResolved: false,
            approvalCount: approvalCount,
            changesRequestedCount: 0,
            ciExtendedInfo: ciExtendedInfo
        )
    }
}
