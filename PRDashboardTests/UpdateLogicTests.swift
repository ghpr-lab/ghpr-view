import XCTest
@testable import PRDashboard

final class UpdateLogicTests: XCTestCase {
    func testConfigurationMigrationDefaultsAutoCheckToTrue() throws {
        let json = """
        {
          "refreshInterval": 120,
          "repositories": ["owner/repo"],
          "showDrafts": false,
          "notificationsEnabled": true,
          "refreshOnOpen": true,
          "ciStatusExcludeFilter": "lint",
          "pausePollingInLowPowerMode": false,
          "pausePollingOnExpensiveNetwork": true,
          "showMyReviewStatus": true
        }
        """

        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))

        XCTAssertEqual(configuration.refreshInterval, 120)
        XCTAssertEqual(configuration.repositories, ["owner/repo"])
        XCTAssertFalse(configuration.showDrafts)
        XCTAssertTrue(configuration.refreshOnOpen)
        XCTAssertEqual(configuration.ciStatusExcludeFilter, "lint")
        XCTAssertTrue(configuration.automaticallyCheckForUpdates)
        XCTAssertFalse(configuration.openAtCmuxFirst)
    }

    func testConfigurationDecodesOpenAtCmuxFirst() throws {
        let json = """
        {
          "openAtCmuxFirst": true
        }
        """

        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))

        XCTAssertTrue(configuration.openAtCmuxFirst)
    }

    @MainActor
    func testPRLinkOpenerWithoutCmuxFirstOpensDefaultAndSkipsCmuxRouter() async {
        var configuration = Configuration.default
        configuration.openAtCmuxFirst = false
        let router = RecordingCmuxBrowserRouter(result: false)
        let url = URL(string: "https://github.com/owner/repo/pull/123")!
        var openedURLs: [URL] = []
        var activationCount = 0
        let opener = PRLinkOpener(
            configurationProvider: { configuration },
            cmuxRouter: router,
            defaultOpener: { openedURLs.append($0) },
            cmuxActivator: { activationCount += 1 }
        )

        await opener.open(url)

        XCTAssertEqual(openedURLs, [url])
        XCTAssertEqual(activationCount, 0)
        XCTAssertTrue(router.openedURLs.isEmpty)
    }

    @MainActor
    func testPRLinkOpenerWaitsForCmuxMissBeforeFallback() async {
        var configuration = Configuration.default
        configuration.openAtCmuxFirst = true
        let router = ControlledCmuxBrowserRouter(result: false)
        let url = URL(string: "https://github.com/owner/repo/pull/123")!
        var openedURLs: [URL] = []
        var activationCount = 0
        let opener = PRLinkOpener(
            configurationProvider: { configuration },
            cmuxRouter: router,
            defaultOpener: { openedURLs.append($0) },
            cmuxActivator: { activationCount += 1 }
        )

        let task = Task {
            await opener.open(url)
        }
        await Task.yield()
        router.waitUntilCalled()

        XCTAssertEqual(router.openedURLs, [url])
        XCTAssertTrue(openedURLs.isEmpty)

        router.release()
        await task.value

        XCTAssertEqual(openedURLs, [url])
        XCTAssertEqual(activationCount, 0)
    }

    @MainActor
    func testPRLinkOpenerActivatesCmuxWhenCmuxHandlesURL() async {
        var configuration = Configuration.default
        configuration.openAtCmuxFirst = true
        let router = RecordingCmuxBrowserRouter(result: true)
        let url = URL(string: "https://github.com/owner/repo/pull/123")!
        var openedURLs: [URL] = []
        var activationCount = 0
        let opener = PRLinkOpener(
            configurationProvider: { configuration },
            cmuxRouter: router,
            defaultOpener: { openedURLs.append($0) },
            cmuxActivator: { activationCount += 1 }
        )

        await opener.open(url)

        XCTAssertEqual(router.openedURLs, [url])
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(activationCount, 1)
    }

    func testAppVersionComparisonUsesNumericComponents() {
        XCTAssertLessThan(AppVersion("1.2.9"), AppVersion("1.10.0"))
        XCTAssertEqual(AppVersion("v1.2.1"), AppVersion("1.2.1"))
        XCTAssertLessThan(AppVersion("1.2.1-beta"), AppVersion("1.2.1"))
    }

    func testReleaseInfoSelectsSinglePRDashboardZipAsset() throws {
        let release = try makeRelease(
            assets: [
                """
                {
                  "name": "PRDashboard-1.2.2.zip",
                  "browser_download_url": "https://example.com/PRDashboard-1.2.2.zip",
                  "size": 42
                }
                """,
                """
                {
                  "name": "checksums.txt",
                  "browser_download_url": "https://example.com/checksums.txt",
                  "size": 12
                }
                """
            ]
        )

        XCTAssertEqual(try release.preferredZipAsset().name, "PRDashboard-1.2.2.zip")
        XCTAssertEqual(release.displayVersion, "1.2.2")
    }

    func testReleaseInfoRejectsMissingOrDuplicateZipAssets() throws {
        let missingAssetRelease = try makeRelease(
            assets: [
                """
                {
                  "name": "notes.txt",
                  "browser_download_url": "https://example.com/notes.txt",
                  "size": 10
                }
                """
            ]
        )

        XCTAssertThrowsError(try missingAssetRelease.preferredZipAsset()) { error in
            XCTAssertEqual(error as? ReleaseAssetSelectionError, .missingZipAsset)
        }

        let duplicateAssetRelease = try makeRelease(
            assets: [
                """
                {
                  "name": "PRDashboard-1.2.2.zip",
                  "browser_download_url": "https://example.com/PRDashboard-1.2.2.zip",
                  "size": 42
                }
                """,
                """
                {
                  "name": "PRDashboard-1.2.2-arm64.zip",
                  "browser_download_url": "https://example.com/PRDashboard-1.2.2-arm64.zip",
                  "size": 43
                }
                """
            ]
        )

        XCTAssertThrowsError(try duplicateAssetRelease.preferredZipAsset()) { error in
            XCTAssertEqual(error as? ReleaseAssetSelectionError, .multipleZipAssets)
        }
    }

    func testInstallEligibilityAcceptsWritableApplicationsPaths() {
        let homeDirectoryURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        let systemInstall = InstallEligibilityResolver.resolve(
            bundleURL: URL(fileURLWithPath: "/Applications/PRDashboard.app", isDirectory: true),
            appName: "PRDashboard",
            homeDirectoryURL: homeDirectoryURL,
            isBundleWritable: true
        )
        XCTAssertEqual(
            systemInstall,
            .eligible(targetURL: URL(fileURLWithPath: "/Applications/PRDashboard.app"))
        )

        let userInstall = InstallEligibilityResolver.resolve(
            bundleURL: URL(fileURLWithPath: "/Users/tester/Applications/PRDashboard.app", isDirectory: true),
            appName: "PRDashboard",
            homeDirectoryURL: homeDirectoryURL,
            isBundleWritable: true
        )
        XCTAssertEqual(
            userInstall,
            .eligible(targetURL: URL(fileURLWithPath: "/Users/tester/Applications/PRDashboard.app"))
        )
    }

    func testInstallEligibilityRejectsUnsupportedPaths() {
        let homeDirectoryURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        let translocated = InstallEligibilityResolver.resolve(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/PRDashboard.app", isDirectory: true),
            appName: "PRDashboard",
            homeDirectoryURL: homeDirectoryURL,
            isBundleWritable: true
        )
        XCTAssertEqual(
            translocated,
            .unsupported(reason: "This copy is running from an App Translocation path and cannot update itself.")
        )

        let homebrew = InstallEligibilityResolver.resolve(
            bundleURL: URL(fileURLWithPath: "/opt/homebrew/Caskroom/prdashboard/latest/PRDashboard.app", isDirectory: true),
            appName: "PRDashboard",
            homeDirectoryURL: homeDirectoryURL,
            isBundleWritable: true
        )
        XCTAssertEqual(
            homebrew,
            .unsupported(reason: "Homebrew-managed installs are not updated in place by the app.")
        )

        let unwritable = InstallEligibilityResolver.resolve(
            bundleURL: URL(fileURLWithPath: "/Applications/PRDashboard.app", isDirectory: true),
            appName: "PRDashboard",
            homeDirectoryURL: homeDirectoryURL,
            isBundleWritable: false
        )
        XCTAssertEqual(
            unwritable,
            .unsupported(reason: "The current app bundle is not writable, so the update cannot be installed automatically.")
        )
    }

    func testMentionParserRecognizesSameRepositoryReferences() {
        let references = GitHubAPIClient.extractMentionedPRReferences(
            from: "See #12, owner/repo#34, and https://github.com/owner/repo/pull/56 for context.",
            repositoryOwner: "owner",
            repositoryName: "repo",
            sourcePRNumber: 99
        )

        XCTAssertEqual(
            references,
            Set([
                PullRequestReference(owner: "owner", repo: "repo", number: 12),
                PullRequestReference(owner: "owner", repo: "repo", number: 34),
                PullRequestReference(owner: "owner", repo: "repo", number: 56)
            ])
        )
    }

    func testMentionParserIgnoresCrossRepoAndSelfReferences() {
        let references = GitHubAPIClient.extractMentionedPRReferences(
            from: "Cross repo refs like other/repo#12 and https://github.com/other/repo/pull/77 should be ignored. Self refs #99 and owner/repo#99 should also be ignored.",
            repositoryOwner: "owner",
            repositoryName: "repo",
            sourcePRNumber: 99
        )

        XCTAssertTrue(references.isEmpty)
    }

    func testMentionParserDoesNotTreatCrossRepoQualifiedReferenceAsBareSameRepoReference() {
        let references = GitHubAPIClient.extractMentionedPRReferences(
            from: "Do not treat other/repo#12 as a repo-local pull request reference.",
            repositoryOwner: "owner",
            repositoryName: "repo",
            sourcePRNumber: 88
        )

        XCTAssertTrue(references.isEmpty)
    }

    func testPATScopeMatcherAcceptsBroaderUserScopeForReadUserRequirement() {
        XCTAssertTrue(GitHubOAuthManager.grantedScopes(["user"], satisfy: "read:user"))
        XCTAssertTrue(GitHubOAuthManager.grantedScopes(["repo", "user"], satisfy: "read:user"))
        XCTAssertFalse(GitHubOAuthManager.grantedScopes(["read:org"], satisfy: "read:user"))
    }

    func testPRListKeepsMentionedPRsOutOfAuthoredBadgeCount() {
        let mentionedPR = makePullRequest(
            id: 1,
            number: 123,
            category: .mentioned,
            reviewThreads: [
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
            ]
        )

        let list = PRList(
            lastUpdated: Date(),
            pullRequests: [],
            mentionedPullRequests: [mentionedPR],
            mergedPullRequests: [],
            isLoading: false,
            error: nil
        )

        XCTAssertTrue(list.hasUsableData)
        XCTAssertEqual(list.authoredUnresolvedCount, 0)
        XCTAssertEqual(list.authoredUnreadUnresolvedCount, 0)
        XCTAssertEqual(list.totalUnresolvedCount, 0)
    }

    func testPullRequestReadUnreadUnresolvedCountsExcludeResolvedAndOutdated() {
        let pr = makePullRequest(
            id: 10,
            number: 10,
            category: .authored,
            reviewThreads: [
                makeReviewThread(id: "unread-unresolved"),
                makeReviewThread(id: "read-unresolved", isRead: true),
                makeReviewThread(id: "read-resolved", isResolved: true, isRead: true),
                makeReviewThread(id: "unread-outdated", isOutdated: true)
            ]
        )

        XCTAssertEqual(pr.unresolvedCount, 2)
        XCTAssertEqual(pr.unreadUnresolvedCount, 1)
        XCTAssertEqual(pr.readUnresolvedCount, 1)
    }

    func testReviewThreadDecodesMissingReadStateAsUnread() throws {
        let json = """
        {
          "id": "thread-1",
          "isResolved": false,
          "isOutdated": false,
          "path": null,
          "line": null,
          "comments": []
        }
        """

        let thread = try JSONDecoder().decode(ReviewThread.self, from: Data(json.utf8))

        XCTAssertFalse(thread.isRead)
        XCTAssertTrue(thread.isUnreadUnresolved)
    }

    func testPRListAuthoredUnreadUnresolvedCountExcludesReadAndNonAuthoredPRs() {
        let authored = makePullRequest(
            id: 1,
            number: 1,
            category: .authored,
            reviewThreads: [
                makeReviewThread(id: "authored-unread"),
                makeReviewThread(id: "authored-read", isRead: true)
            ]
        )
        let reviewRequest = makePullRequest(
            id: 2,
            number: 2,
            category: .reviewRequest,
            reviewThreads: [
                makeReviewThread(id: "review-unread")
            ]
        )
        let mentioned = makePullRequest(
            id: 3,
            number: 3,
            category: .mentioned,
            reviewThreads: [
                makeReviewThread(id: "mentioned-unread")
            ]
        )

        let list = PRList(
            lastUpdated: Date(),
            pullRequests: [authored, reviewRequest],
            mentionedPullRequests: [mentioned],
            mergedPullRequests: [],
            isLoading: false,
            error: nil
        )

        XCTAssertEqual(list.authoredUnresolvedCount, 2)
        XCTAssertEqual(list.authoredUnreadUnresolvedCount, 1)
        XCTAssertEqual(list.totalUnresolvedCount, 3)
    }

    func testPinnedMajorEventPlannerReportsCIFailureEveryRefresh() {
        var pr = makePullRequest(id: 11, number: 11, category: .authored)
        pr.ciStatus = .failure
        pr.checkFailureCount = 1

        let firstPlan = PinnedMajorPRNotificationPlanner.plans(
            for: [pr],
            pinnedPRIdentifiers: [pr.pinIdentifier]
        )
        let secondPlan = PinnedMajorPRNotificationPlanner.plans(
            for: [pr],
            pinnedPRIdentifiers: [pr.pinIdentifier]
        )

        XCTAssertEqual(firstPlan, secondPlan)
        XCTAssertEqual(firstPlan.first?.events, [.ciFailure])
    }

    func testPinnedMajorEventPlannerTreatsUnknownCIAsFailure() {
        var pr = makePullRequest(id: 12, number: 12, category: .authored)
        pr.ciStatus = .unknown

        let plan = PinnedMajorPRNotificationPlanner.plans(
            for: [pr],
            pinnedPRIdentifiers: [pr.pinIdentifier]
        )

        XCTAssertEqual(plan.first?.events, [.ciFailure])
    }

    func testPinnedMajorEventPlannerReportsChangeRequestsAndApprovals() {
        var pr = makePullRequest(id: 13, number: 13, category: .reviewRequest)
        pr.changesRequestedCount = 2
        pr.approvalCount = 1

        let plan = PinnedMajorPRNotificationPlanner.plans(
            for: [pr],
            pinnedPRIdentifiers: [pr.pinIdentifier]
        )

        XCTAssertEqual(plan.first?.events, [.changeRequests(2), .approvals(1)])
    }

    func testPinnedMajorEventPlannerIgnoresUnpinnedPRs() {
        var pr = makePullRequest(id: 14, number: 14, category: .authored)
        pr.ciStatus = .failure
        pr.checkFailureCount = 1
        pr.changesRequestedCount = 1
        pr.approvalCount = 1

        let plan = PinnedMajorPRNotificationPlanner.plans(
            for: [pr],
            pinnedPRIdentifiers: []
        )

        XCTAssertTrue(plan.isEmpty)
    }

    func testPinnedMajorEventPlannerAggregatesMultipleEvents() {
        var pr = makePullRequest(id: 15, number: 15, category: .reviewRequest)
        pr.ciStatus = .failure
        pr.checkFailureCount = 3
        pr.changesRequestedCount = 2
        pr.approvalCount = 4

        let events = PinnedMajorPRNotificationPlanner.events(for: pr)

        XCTAssertEqual(events, [.ciFailure, .changeRequests(2), .approvals(4)])
        XCTAssertEqual(events.map(\.notificationText).count, 3)
    }

    func testCachedPRDetailInvalidatesWhenCIRollupStateChangesWithoutPRUpdate() {
        let now = Date(timeIntervalSince1970: 1_713_666_108)
        let cachedSnapshot = makeIndexSnapshot(updatedAt: now, ciRollupState: "PENDING")
        let freshSnapshot = makeIndexSnapshot(updatedAt: now, ciRollupState: "FAILURE")
        let cached = CachedPRDetail(
            prId: 17229,
            indexSnapshot: cachedSnapshot,
            detail: makePullRequest(id: 17229, number: 17229, category: .authored),
            detailFetchedAt: now
        )

        XCTAssertFalse(cached.isUsable(against: freshSnapshot, now: now, ttl: PRDetailCache.ttl))
    }

    func testIndexSnapshotDecodeWithoutCIRollupStateForcesCacheMiss() throws {
        struct LegacyIndexSnapshot: Codable {
            let updatedAt: Date
            let headOid: String?
            let reviewThreadTotal: Int
            let commentTotal: Int
            let reviewTotal: Int
            let unresolvedReviewThreadCount: Int
        }

        let now = Date(timeIntervalSince1970: 1_713_666_108)
        let legacy = LegacyIndexSnapshot(
            updatedAt: now,
            headOid: "f574918fa04b0c7ac49de5b1f3876c430d16e81c",
            reviewThreadTotal: 0,
            commentTotal: 0,
            reviewTotal: 0,
            unresolvedReviewThreadCount: 0
        )
        let decoded = try JSONDecoder().decode(IndexSnapshot.self, from: JSONEncoder().encode(legacy))
        let current = makeIndexSnapshot(
            updatedAt: now,
            headOid: "f574918fa04b0c7ac49de5b1f3876c430d16e81c",
            ciRollupState: "PENDING"
        )
        let cached = CachedPRDetail(
            prId: 17229,
            indexSnapshot: decoded,
            detail: makePullRequest(id: 17229, number: 17229, category: .authored),
            detailFetchedAt: now
        )

        XCTAssertNotEqual(decoded, current)
        XCTAssertFalse(cached.isUsable(against: current, now: now, ttl: PRDetailCache.ttl))
    }

    func testCachedPRDetailDoesNotReuseRunningCIWhenSnapshotMatches() {
        let now = Date(timeIntervalSince1970: 1_713_666_108)
        let snapshot = makeIndexSnapshot(updatedAt: now, ciRollupState: "PENDING")
        var pr = makePullRequest(id: 17229, number: 17229, category: .authored)
        pr.ciStatus = .pending
        pr.checkSuccessCount = 42
        pr.checkPendingCount = 1
        pr.githubCIState = "PENDING"
        pr.ciExtendedInfo = CIExtendedInfo(isRunning: true, workflows: [])

        let cached = CachedPRDetail(
            prId: pr.id,
            indexSnapshot: snapshot,
            detail: pr,
            detailFetchedAt: now
        )

        XCTAssertFalse(cached.isUsable(against: snapshot, now: now, ttl: PRDetailCache.ttl))
    }

    func testCachedPRDetailReusesTerminalCIWhenSnapshotMatches() {
        let now = Date(timeIntervalSince1970: 1_713_666_108)
        let snapshot = makeIndexSnapshot(updatedAt: now, ciRollupState: "SUCCESS")
        var pr = makePullRequest(id: 7, number: 7, category: .authored)
        pr.ciStatus = .success
        pr.checkSuccessCount = 12
        pr.checkPendingCount = 0
        pr.githubCIState = "SUCCESS"
        pr.ciExtendedInfo = CIExtendedInfo(isRunning: false, workflows: [])
        pr.graphqlNodeId = "PR_node_7"
        pr.baseRefName = "main"
        pr.headRefName = "feature"

        let cached = CachedPRDetail(
            prId: pr.id,
            indexSnapshot: snapshot,
            detail: pr,
            detailFetchedAt: now
        )

        XCTAssertTrue(cached.isUsable(against: snapshot, now: now, ttl: PRDetailCache.ttl))
    }

    func testKongStyleRunningToFailureSnapshotChangeCausesCacheMiss() {
        let updatedAt = Date(timeIntervalSince1970: 1_713_666_108)
        let headOid = "f574918fa04b0c7ac49de5b1f3876c430d16e81c"
        let pendingSnapshot = makeIndexSnapshot(
            updatedAt: updatedAt,
            headOid: headOid,
            ciRollupState: "PENDING"
        )
        let failedSnapshot = makeIndexSnapshot(
            updatedAt: updatedAt,
            headOid: headOid,
            ciRollupState: "FAILURE"
        )
        var pr = makePullRequest(id: 17229, number: 17229, category: .authored)
        pr.ciStatus = .pending
        pr.checkSuccessCount = 87
        pr.checkPendingCount = 1
        pr.githubCIState = "PENDING"
        pr.ciExtendedInfo = CIExtendedInfo(isRunning: true, workflows: [])
        let cached = CachedPRDetail(
            prId: pr.id,
            indexSnapshot: pendingSnapshot,
            detail: pr,
            detailFetchedAt: Date(timeIntervalSince1970: 1_713_666_200)
        )

        XCTAssertFalse(
            cached.isUsable(
                against: failedSnapshot,
                now: Date(timeIntervalSince1970: 1_713_666_201),
                ttl: PRDetailCache.ttl
            )
        )
    }

    func testPlaceholderPreservesKnownBaseNeedsUpdateWhenIndexStatusIsUnknown() {
        var existing = makePullRequest(id: 17937, number: 17937, category: .authored)
        existing.graphqlNodeId = "PR_node_17937"
        existing.baseRefName = "master"
        existing.headRefName = "fix/mcp-oauth2-jwt"
        existing.baseNeedsUpdate = true

        let indexed = makeIndexedPR(
            id: existing.id,
            number: existing.number,
            baseNeedsUpdate: nil
        )

        let placeholder = indexed.placeholderPullRequest(using: existing)

        XCTAssertEqual(placeholder.baseNeedsUpdate, true)
        XCTAssertEqual(placeholder.baseRefName, "master")
        XCTAssertEqual(placeholder.headRefName, "fix/mcp-oauth2-jwt")
    }

    func testPlaceholderUsesFreshBaseNeedsUpdateWhenIndexHasKnownStatus() {
        var existing = makePullRequest(id: 17912, number: 17912, category: .authored)
        existing.baseNeedsUpdate = true

        let indexed = makeIndexedPR(
            id: existing.id,
            number: existing.number,
            baseNeedsUpdate: false
        )

        let placeholder = indexed.placeholderPullRequest(using: existing)

        XCTAssertEqual(placeholder.baseNeedsUpdate, false)
    }

    func testPlaceholderPreservesVisibleJiraAndApprovalsWithoutDetailCache() {
        var visible = makePullRequest(id: 18001, number: 18001, category: .authored)
        visible.jiraTicket = "AG-1234"
        visible.approvalCount = 2
        visible.approvalAuthors = ["alice", "bob"]
        visible.reviewThreads = [makeReviewThread(id: "thread-1", isRead: true)]

        let indexed = makeIndexedPR(
            id: visible.id,
            number: visible.number,
            baseNeedsUpdate: nil
        )

        let placeholder = indexed.placeholderPullRequest(preserving: visible)

        XCTAssertEqual(placeholder.jiraTicket, "AG-1234")
        XCTAssertEqual(placeholder.approvalCount, 2)
        XCTAssertEqual(placeholder.approvalAuthors, ["alice", "bob"])
        XCTAssertEqual(placeholder.reviewThreads.count, 1)
        XCTAssertEqual(placeholder.reviewThreads.first?.id, "thread-1")
        XCTAssertEqual(placeholder.reviewThreads.first?.isRead, true)
    }

    func testPlaceholderUsesVisibleJiraWhenDetailCacheHasNoJiraTicket() {
        var cached = makePullRequest(id: 18002, number: 18002, category: .authored)
        cached.approvalCount = 1
        cached.approvalAuthors = nil

        var visible = makePullRequest(id: cached.id, number: cached.number, category: .authored)
        visible.jiraTicket = "KAG-456"
        visible.approvalCount = 2
        visible.approvalAuthors = ["reviewer"]

        let indexed = makeIndexedPR(
            id: cached.id,
            number: cached.number,
            baseNeedsUpdate: nil
        )

        let placeholder = indexed.placeholderPullRequest(using: cached, preserving: visible)

        XCTAssertEqual(placeholder.jiraTicket, "KAG-456")
        XCTAssertEqual(placeholder.approvalCount, 2)
        XCTAssertEqual(placeholder.approvalAuthors, ["reviewer"])
    }

    func testPlaceholderFallsBackToCachedDetailWhenVisibleStateIsMissing() {
        var cached = makePullRequest(id: 18003, number: 18003, category: .authored)
        cached.jiraTicket = "CACHE-789"
        cached.approvalCount = 1
        cached.approvalAuthors = ["cached-reviewer"]

        let indexed = makeIndexedPR(
            id: cached.id,
            number: cached.number,
            baseNeedsUpdate: nil
        )

        let placeholder = indexed.placeholderPullRequest(using: cached)

        XCTAssertEqual(placeholder.jiraTicket, "CACHE-789")
        XCTAssertEqual(placeholder.approvalCount, 1)
        XCTAssertEqual(placeholder.approvalAuthors, ["cached-reviewer"])
    }

    func testCompareURLEncodesBranchSlashAsSinglePathComponent() throws {
        let url = try XCTUnwrap(
            GitHubAPIClient.compareURL(
                owner: "Kong",
                repo: "kong-ee",
                base: "master",
                head: "fix/mcp-oauth2-jwt"
            )
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://api.github.com/repos/Kong/kong-ee/compare/master...fix%2Fmcp-oauth2-jwt"
        )
    }

    @MainActor
    func testPRListViewModelSearchMatchesJiraTicketsAcrossOpenAndMergedPRs() {
        let oauthManager = GitHubOAuthManager(loadSavedAuth: false)
        let prManager = PRManager(
            apiClient: GitHubAPIClient(token: ""),
            notificationManager: NotificationManager(),
            oauthManager: oauthManager
        )
        let viewModel = PRListViewModel(
            prManager: prManager,
            oauthManager: oauthManager,
            linkOpener: FakePRLinkOpening(opensAtCmuxFirst: false)
        )
        var matchingOpen = makePullRequest(id: 18004, number: 101, category: .authored)
        matchingOpen.jiraTicket = "AG-1234"
        var nonMatchingOpen = makePullRequest(id: 18005, number: 102, category: .authored)
        nonMatchingOpen.jiraTicket = "KAG-456"
        var matchingMerged = makePullRequest(
            id: 18006,
            number: 103,
            category: .authored,
            mergedAt: Date().addingTimeInterval(-60)
        )
        matchingMerged.jiraTicket = "AG-1234"
        var nonMatchingMerged = makePullRequest(
            id: 18007,
            number: 104,
            category: .authored,
            mergedAt: Date().addingTimeInterval(-60)
        )
        nonMatchingMerged.jiraTicket = "NOPE-999"

        viewModel.prList = PRList(
            lastUpdated: Date(),
            pullRequests: [matchingOpen, nonMatchingOpen],
            mergedPullRequests: [matchingMerged, nonMatchingMerged],
            isLoading: false,
            error: nil
        )
        viewModel.searchText = "ag-1234"

        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [matchingOpen.id])
        XCTAssertEqual(viewModel.mergedLast24hPRs.map(\.id), [matchingMerged.id])
    }

    @MainActor
    func testPRListViewModelSuppressesDuplicateCmuxFirstOpenUntilCompletion() async {
        let oauthManager = GitHubOAuthManager(loadSavedAuth: false)
        let prManager = PRManager(
            apiClient: GitHubAPIClient(token: ""),
            notificationManager: NotificationManager(),
            oauthManager: oauthManager
        )
        let linkOpener = FakePRLinkOpening(opensAtCmuxFirst: true)
        let viewModel = PRListViewModel(
            prManager: prManager,
            oauthManager: oauthManager,
            linkOpener: linkOpener
        )
        let pr = makePullRequest(id: 42, number: 42, category: .authored)

        viewModel.openPR(pr)
        await Task.yield()

        XCTAssertTrue(viewModel.isOpeningPR(pr))
        XCTAssertEqual(linkOpener.openedURLs, [pr.url])

        viewModel.openPR(pr)
        await Task.yield()

        XCTAssertEqual(linkOpener.openedURLs, [pr.url])

        linkOpener.finishOpen()
        for _ in 0..<5 where viewModel.isOpeningPR(pr) {
            await Task.yield()
        }

        XCTAssertFalse(viewModel.isOpeningPR(pr))
    }

    private func makeRelease(assets: [String]) throws -> ReleaseInfo {
        let json = """
        {
          "tag_name": "v1.2.2",
          "name": "PR Dashboard 1.2.2",
          "body": "Bug fixes",
          "published_at": "2026-04-15T05:06:07Z",
          "html_url": "https://github.com/xiaocang/ghpr-view/releases/tag/v1.2.2",
          "assets": [
            \(assets.joined(separator: ","))
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReleaseInfo.self, from: Data(json.utf8))
    }

    private func makeIndexSnapshot(
        updatedAt: Date = Date(timeIntervalSince1970: 1_713_666_108),
        headOid: String? = "abc123",
        ciRollupState: String? = "SUCCESS",
        reviewThreadTotal: Int = 0,
        commentTotal: Int = 0,
        reviewTotal: Int = 0,
        unresolvedReviewThreadCount: Int = 0
    ) -> IndexSnapshot {
        IndexSnapshot(
            updatedAt: updatedAt,
            headOid: headOid,
            ciRollupState: ciRollupState,
            reviewThreadTotal: reviewThreadTotal,
            commentTotal: commentTotal,
            reviewTotal: reviewTotal,
            unresolvedReviewThreadCount: unresolvedReviewThreadCount
        )
    }

    private func makeIndexedPR(
        id: Int,
        number: Int,
        baseNeedsUpdate: Bool?,
        hasBaseConflicts: Bool = false
    ) -> IndexedPR {
        IndexedPR(
            databaseId: id,
            graphqlNodeId: "PR_node_\(id)",
            number: number,
            title: "PR #\(number)",
            url: URL(string: "https://github.com/owner/repo/pull/\(number)")!,
            state: .open,
            isDraft: false,
            createdAt: Date(timeIntervalSince1970: 1_713_666_000),
            updatedAt: Date(timeIntervalSince1970: 1_713_666_108),
            mergedAt: nil,
            author: "tester",
            authorAvatarURL: nil,
            repositoryOwner: "owner",
            repositoryName: "repo",
            baseRefName: "master",
            headRefName: "fix/mcp-oauth2-jwt",
            baseNeedsUpdate: baseNeedsUpdate,
            hasBaseConflicts: hasBaseConflicts,
            category: .authored,
            isMerged: false,
            snapshot: makeIndexSnapshot()
        )
    }

    private func makeReviewThread(
        id: String,
        isResolved: Bool = false,
        isOutdated: Bool = false,
        isRead: Bool = false
    ) -> ReviewThread {
        ReviewThread(
            id: id,
            isResolved: isResolved,
            isOutdated: isOutdated,
            path: nil,
            line: nil,
            comments: [],
            isRead: isRead
        )
    }

    private func makePullRequest(
        id: Int,
        number: Int,
        category: PRCategory,
        reviewThreads: [ReviewThread] = [],
        hasBaseConflicts: Bool = false,
        mergedAt: Date? = nil
    ) -> PullRequest {
        PullRequest(
            id: id,
            number: number,
            title: "PR #\(number)",
            author: "tester",
            authorAvatarURL: nil,
            repositoryOwner: "owner",
            repositoryName: "repo",
            url: URL(string: "https://github.com/owner/repo/pull/\(number)")!,
            state: mergedAt == nil ? .open : .merged,
            isDraft: false,
            createdAt: Date(),
            updatedAt: Date(),
            mergedAt: mergedAt,
            body: nil,
            conversationComments: [],
            lastCommitAt: Date(),
            headCommitOid: "abc123",
            reviewThreads: reviewThreads,
            category: category,
            hasBaseConflicts: hasBaseConflicts,
            ciStatus: .success,
            checkSuccessCount: 1,
            checkFailureCount: 0,
            checkPendingCount: 0,
            githubCIState: "SUCCESS",
            myLastReviewState: nil,
            myLastReviewAt: nil,
            reviewRequestedAt: nil,
            myThreadsAllResolved: false,
            approvalCount: 0,
            changesRequestedCount: 0,
            ciExtendedInfo: nil
        )
    }
}

final class CmuxBrowserRouterTests: XCTestCase {
    func testFindMatchingSurfaceMatchesSamePRSubpage() throws {
        let target = try XCTUnwrap(GitHubPRIdentity(url: URL(string: "https://github.com/Owner/Repo/pull/123")!))

        let match = CmuxBrowserRouter.findMatchingSurface(
            in: Self.treeJSON(
                surfaceURL: "https://github.com/owner/repo/pull/123/files?plain=1#diff"
            ),
            target: target
        )

        XCTAssertEqual(
            match,
            CmuxBrowserRouter.BrowserMatch(
                windowHandle: "window:1",
                workspaceHandle: "workspace:2",
                surfaceHandle: "surface:3"
            )
        )
    }

    func testFindMatchingSurfaceRejectsDifferentPR() throws {
        let target = try XCTUnwrap(GitHubPRIdentity(url: URL(string: "https://github.com/owner/repo/pull/123")!))

        let match = CmuxBrowserRouter.findMatchingSurface(
            in: Self.treeJSON(surfaceURL: "https://github.com/owner/repo/pull/124"),
            target: target
        )

        XCTAssertNil(match)
    }

    func testOpenPRIdentitiesParsesTreeWithoutFocusingCmux() throws {
        let runner = FakeCmuxCommandRunner(results: [
            .success(stdout: Self.treeJSON(surfaceURL: "https://github.com/owner/repo/pull/123/files"))
        ])
        let router = CmuxBrowserRouter(commandRunner: runner, timeout: 0.1)
        let target = try XCTUnwrap(GitHubPRIdentity(url: URL(string: "https://github.com/owner/repo/pull/123")!))

        let identities = router.openPRIdentities()

        XCTAssertEqual(identities, Set([target]))
        XCTAssertEqual(runner.commands, [
            ["--json", "--id-format", "uuids", "tree", "--all"]
        ])
    }

    func testOpenExistingPRFocusesMatchingTabWithoutReloading() {
        let runner = FakeCmuxCommandRunner(results: [
            .success(stdout: Self.treeJSON(surfaceURL: "https://github.com/owner/repo/pull/123")),
            .success(),
            .success(),
            .success()
        ])
        let router = CmuxBrowserRouter(commandRunner: runner, timeout: 0.1)

        let handled = router.openExistingPR(URL(string: "https://github.com/owner/repo/pull/123")!)

        XCTAssertTrue(handled)
        XCTAssertEqual(runner.commands, [
            ["--json", "--id-format", "uuids", "tree", "--all"],
            ["focus-window", "--window", "window:1"],
            ["select-workspace", "--workspace", "workspace:2"],
            ["focus-panel", "--workspace", "workspace:2", "--panel", "surface:3"]
        ])
    }

    func testOpenExistingPRFallsBackWhenNoMatch() {
        let runner = FakeCmuxCommandRunner(results: [
            .success(stdout: Self.treeJSON(surfaceURL: "https://github.com/owner/repo/pull/456"))
        ])
        let router = CmuxBrowserRouter(commandRunner: runner, timeout: 0.1)

        let handled = router.openExistingPR(URL(string: "https://github.com/owner/repo/pull/123")!)

        XCTAssertFalse(handled)
        XCTAssertEqual(runner.commands, [
            ["--json", "--id-format", "uuids", "tree", "--all"]
        ])
    }

    func testOpenExistingPRFallsBackWhenTreeCommandFails() {
        let runner = FakeCmuxCommandRunner(results: [
            CmuxCommandResult(exitCode: 1, stdout: "", stderr: "socket unavailable", timedOut: false)
        ])
        let router = CmuxBrowserRouter(commandRunner: runner, timeout: 0.1)

        let handled = router.openExistingPR(URL(string: "https://github.com/owner/repo/pull/123")!)

        XCTAssertFalse(handled)
        XCTAssertEqual(runner.commands, [
            ["--json", "--id-format", "uuids", "tree", "--all"]
        ])
    }

    func testOpenExistingPRFallsBackWhenTreeCommandTimesOut() {
        let runner = FakeCmuxCommandRunner(results: [
            CmuxCommandResult(exitCode: 0, stdout: "", stderr: "", timedOut: true)
        ])
        let router = CmuxBrowserRouter(commandRunner: runner, timeout: 0.1)

        let handled = router.openExistingPR(URL(string: "https://github.com/owner/repo/pull/123")!)

        XCTAssertFalse(handled)
        XCTAssertEqual(runner.commands, [
            ["--json", "--id-format", "uuids", "tree", "--all"]
        ])
    }

    private static func treeJSON(surfaceURL: String) -> String {
        """
        {
          "windows": [
            {
              "id": "window-id",
              "ref": "window:1",
              "workspaces": [
                {
                  "id": "workspace-id",
                  "ref": "workspace:2",
                  "panes": [
                    {
                      "surfaces": [
                        {
                          "id": "surface-id",
                          "ref": "surface:3",
                          "type": "browser",
                          "url": "\(surfaceURL)"
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
        """
    }
}

private final class RecordingCmuxBrowserRouter: CmuxBrowserRouting, @unchecked Sendable {
    private let result: Bool
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    init(result: Bool) {
        self.result = result
    }

    var openedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    func openExistingPR(_ url: URL) -> Bool {
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
        return result
    }
}

private final class ControlledCmuxBrowserRouter: CmuxBrowserRouting, @unchecked Sendable {
    private let result: Bool
    private let called = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    init(result: Bool) {
        self.result = result
    }

    var openedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    func openExistingPR(_ url: URL) -> Bool {
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
        called.signal()
        releaseSemaphore.wait()
        return result
    }

    func waitUntilCalled(file: StaticString = #filePath, line: UInt = #line) {
        let status = called.wait(timeout: .now() + 1)
        if case .timedOut = status {
            XCTFail("Timed out waiting for cmux router call", file: file, line: line)
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}

@MainActor
private final class FakePRLinkOpening: PRLinkOpening {
    var opensAtCmuxFirst: Bool
    private(set) var openedURLs: [URL] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(opensAtCmuxFirst: Bool) {
        self.opensAtCmuxFirst = opensAtCmuxFirst
    }

    func open(_ url: URL) async {
        openedURLs.append(url)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finishOpen() {
        continuation?.resume()
        continuation = nil
    }
}

private final class FakeCmuxCommandRunner: CmuxCommandRunning, @unchecked Sendable {
    private var results: [CmuxCommandResult]
    private(set) var commands: [[String]] = []

    init(results: [CmuxCommandResult]) {
        self.results = results
    }

    func run(arguments: [String], timeout: TimeInterval) -> CmuxCommandResult {
        commands.append(arguments)
        guard !results.isEmpty else {
            return CmuxCommandResult(exitCode: 1, stdout: "", stderr: "missing fake result", timedOut: false)
        }
        return results.removeFirst()
    }
}

private extension CmuxCommandResult {
    static func success(stdout: String = "") -> CmuxCommandResult {
        CmuxCommandResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false)
    }
}
