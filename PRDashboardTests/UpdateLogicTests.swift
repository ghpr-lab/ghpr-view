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
        XCTAssertEqual(configuration.jiraServerURL, "")
        XCTAssertEqual(configuration.jiraEmail, "")
        XCTAssertEqual(configuration.jiraRefreshInterval, 1800)
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

    func testFailurePendingAndSuccessCIRollupsFetchRemainingContextPages() {
        XCTAssertTrue(
            GitHubAPIClient.shouldFetchRemainingCIContexts(rollupState: "FAILURE", hasNextPage: true)
        )
        XCTAssertTrue(
            GitHubAPIClient.shouldFetchRemainingCIContexts(rollupState: "PENDING", hasNextPage: true)
        )
        XCTAssertTrue(
            GitHubAPIClient.shouldFetchRemainingCIContexts(rollupState: "SUCCESS", hasNextPage: true)
        )
        XCTAssertFalse(
            GitHubAPIClient.shouldFetchRemainingCIContexts(rollupState: "FAILURE", hasNextPage: false)
        )
        XCTAssertFalse(
            GitHubAPIClient.shouldFetchRemainingCIContexts(rollupState: "SUCCESS", hasNextPage: false)
        )
    }

    func testWorkflowRunSummaryUsesCurrentRoundLatestAttempt() {
        let olderFailedAttempt = workflowRun(
            id: 1,
            name: "Build",
            workflowId: 10,
            runNumber: 42,
            runAttempt: 1,
            status: "completed",
            conclusion: "failure"
        )
        let latestSuccessfulAttempt = workflowRun(
            id: 2,
            name: "Build",
            workflowId: 10,
            runNumber: 42,
            runAttempt: 2,
            status: "completed",
            conclusion: "success"
        )
        let olderRunNumber = workflowRun(
            id: 3,
            name: "Test",
            workflowId: 11,
            runNumber: 8,
            runAttempt: 1,
            status: "completed",
            conclusion: "success"
        )
        let latestQueuedRun = workflowRun(
            id: 4,
            name: "Test",
            workflowId: 11,
            runNumber: 9,
            runAttempt: 1,
            status: "queued",
            conclusion: nil
        )

        let latest = GitHubAPIClient.latestWorkflowRunsByCurrentRound([
            olderFailedAttempt,
            latestSuccessfulAttempt,
            olderRunNumber,
            latestQueuedRun
        ])
        let summary = GitHubAPIClient.summarizeWorkflowRunCompletion(latest)

        XCTAssertEqual(Set(latest.map(\.id)), [2, 4])
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.inFlightCount, 1)
        XCTAssertEqual(summary.failureLikeCount, 0)
    }

    func testWorkflowRunSummaryKeepsExcludedFailuresVisibleButNonBlocking() {
        let runs = [
            workflowRun(
                id: 1,
                name: "Review CI",
                displayTitle: "PR title",
                workflowId: 10,
                status: "completed",
                conclusion: "failure"
            ),
            workflowRun(
                id: 2,
                name: "Build",
                displayTitle: "Docs-only change",
                workflowId: 11,
                status: "completed",
                conclusion: "failure"
            ),
            workflowRun(
                id: 3,
                name: "Test",
                displayTitle: "PR title",
                workflowId: 12,
                status: "completed",
                conclusion: "success"
            )
        ]

        let summary = GitHubAPIClient.summarizeWorkflowRunCompletion(
            runs,
            excludeFilter: "Review\\s+CI|Docs-only"
        )

        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.completedCount, 3)
        XCTAssertEqual(summary.failureLikeCount, 2)
        XCTAssertEqual(summary.blockingFailureLikeCount, 0)
        XCTAssertEqual(summary.inFlightCount, 0)
    }

    func testWorkflowRunSummaryInvalidRegexFallsBackToContains() {
        let runs = [
            workflowRun(
                id: 1,
                name: "Lint[bot]",
                workflowId: 10,
                status: "completed",
                conclusion: "failure"
            )
        ]

        let summary = GitHubAPIClient.summarizeWorkflowRunCompletion(runs, excludeFilter: "[")

        XCTAssertEqual(summary.failureLikeCount, 1)
        XCTAssertEqual(summary.blockingFailureLikeCount, 0)
    }

    func testWorkflowRunCompletionSummaryFetchesRestPages() async throws {
        let session = makeMockGitHubActionsSession()
        MockGitHubActionsURLProtocol.reset { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "page" })?
                .value
            let body: String
            if page == "1" {
                body = """
                {
                  "total_count": 2,
                  "workflow_runs": [
                    {
                      "id": 1,
                      "name": "Build",
                      "display_title": "PR title",
                      "path": ".github/workflows/build.yml",
                      "workflow_id": 10,
                      "run_number": 1,
                      "run_attempt": 1,
                      "status": "completed",
                      "conclusion": "success",
                      "created_at": "2026-06-02T00:00:00Z",
                      "updated_at": "2026-06-02T00:01:00Z"
                    },
                    {
                      "id": 2,
                      "name": "Lint",
                      "display_title": "Docs-only change",
                      "path": ".github/workflows/lint.yml",
                      "workflow_id": 11,
                      "run_number": 1,
                      "run_attempt": 1,
                      "status": "completed",
                      "conclusion": "failure",
                      "created_at": "2026-06-02T00:00:00Z",
                      "updated_at": "2026-06-02T00:01:00Z"
                    }
                  ]
                }
                """
            } else {
                body = #"{"total_count":2,"workflow_runs":[]}"#
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        defer { MockGitHubActionsURLProtocol.reset() }

        let client = GitHubAPIClient(token: "token", session: session)
        let summary = try await client.fetchWorkflowRunCompletionSummary(
            owner: "owner",
            repo: "repo",
            headSHA: "abc",
            excludeFilter: "Docs-only"
        )

        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.completedCount, 2)
        XCTAssertEqual(summary.failureLikeCount, 1)
        XCTAssertEqual(summary.blockingFailureLikeCount, 0)
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

    @MainActor
    func testAutomaticUpdateCheckFetchesReleaseWhenIdle() async throws {
        let session = makeMockUpdateSession()
        installMockReleaseResponses()
        defer { MockUpdateURLProtocol.reset() }

        let manager = UpdateManager(
            configuration: .default,
            session: session,
            autoCheckInterval: 60,
            initialAutoCheckDelay: 0.01
        )
        var presentationCount = 0
        manager.onRequestPresentation = {
            presentationCount += 1
        }

        manager.checkForUpdates(userInitiated: false)

        await waitForCondition {
            MockUpdateURLProtocol.requestedURLs.count >= 2 && presentationCount == 1
        }
        XCTAssertEqual(manager.displayedRelease?.displayVersion, "999.0.0")
        XCTAssertTrue(MockUpdateURLProtocol.requestedURLs.contains(URL(string: "https://github.com/xiaocang/ghpr-view/releases.atom")!))
        XCTAssertTrue(MockUpdateURLProtocol.requestedURLs.contains(URL(string: "https://api.github.com/repos/xiaocang/ghpr-view/releases/tags/v999.0.0")!))
    }

    @MainActor
    func testStartPerformsLaunchUpdateCheckEvenWhenDailyCheckRecentlyRan() async throws {
        let suiteName = "PRDashboard.UpdateLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(Date(), forKey: "PRDashboard.LastAutoUpdateCheckAt")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            MockUpdateURLProtocol.reset()
        }

        let session = makeMockUpdateSession()
        installMockReleaseResponses()
        let manager = UpdateManager(
            configuration: .default,
            userDefaults: defaults,
            session: session,
            autoCheckInterval: 24 * 60 * 60,
            initialAutoCheckDelay: 0.01
        )

        manager.start()

        await waitForCondition {
            MockUpdateURLProtocol.requestedURLs.count >= 2
        }
        XCTAssertEqual(manager.displayedRelease?.displayVersion, "999.0.0")
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

    func testAuthoredMentionReferenceSearchQueryUsesCreatedWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 29))!

        let yearWindow = GitHubAPIClient.authoredMentionReferenceSearchQuery(
            username: "tester", daysBack: 365, now: now
        )
        let quarterWindow = GitHubAPIClient.authoredMentionReferenceSearchQuery(
            username: "tester", daysBack: 90, now: now
        )
        let gapWindow = GitHubAPIClient.authoredMentionReferenceSearchQuery(
            username: "tester", daysBack: 45, now: now
        )

        XCTAssertEqual(yearWindow, "is:pr author:tester created:>=2025-05-29")
        XCTAssertEqual(quarterWindow, "is:pr author:tester created:>=2026-02-28")
        XCTAssertEqual(gapWindow, "is:pr author:tester created:>=2026-04-14")
    }

    func testBackgroundMentionRefreshDefaultsAreLowPriorityBatches() {
        let options = GitHubAPIClient.MentionRefreshOptions.background(mode: .hot)

        XCTAssertEqual(options.authoredReferenceDaysBack, 30)
        XCTAssertEqual(options.descriptionCandidateDaysBack, 7)
        XCTAssertEqual(options.batchSize, 10)
        XCTAssertEqual(options.boundedBatchSize, 10)
        XCTAssertEqual(options.batchDelay, 60)
    }

    func testBackgroundMentionRefreshExpandsWindowsToCoverGaps() {
        let expanded = GitHubAPIClient.MentionRefreshOptions.background(
            mode: .hot,
            authoredReferenceDaysBack: 45,
            descriptionCandidateDaysBack: 10
        )
        let belowDefault = GitHubAPIClient.MentionRefreshOptions.background(
            mode: .hot,
            authoredReferenceDaysBack: 2,
            descriptionCandidateDaysBack: 3
        )

        XCTAssertEqual(expanded.authoredReferenceDaysBack, 45)
        XCTAssertEqual(expanded.descriptionCandidateDaysBack, 10)
        XCTAssertEqual(belowDefault.authoredReferenceDaysBack, 30)
        XCTAssertEqual(belowDefault.descriptionCandidateDaysBack, 7)
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

    func testCIStatusNotificationPlannerNotifiesForTerminalTransitions() {
        XCTAssertEqual(
            CIStatusNotificationPlanner.notificationStatus(previous: .pending, current: .success),
            .success
        )
        XCTAssertEqual(
            CIStatusNotificationPlanner.notificationStatus(previous: .expected, current: .failure),
            .failure
        )
        XCTAssertEqual(
            CIStatusNotificationPlanner.notificationStatus(previous: nil, current: .success),
            .success
        )
    }

    func testCIStatusNotificationPlannerIgnoresFirstObservationAndNonTerminalChanges() {
        var current = makePullRequest(id: 21, number: 21, category: .authored)
        current.ciStatus = .success

        XCTAssertNil(CIStatusNotificationPlanner.notificationStatus(previous: nil, current: current))
        XCTAssertNil(CIStatusNotificationPlanner.notificationStatus(previous: .pending, current: .pending))
        XCTAssertNil(CIStatusNotificationPlanner.notificationStatus(previous: .success, current: .pending))
        XCTAssertNil(CIStatusNotificationPlanner.notificationStatus(previous: .failure, current: .expected))
    }

    func testCIWatchPlannerWatchesVisibleInFlightPRsAndDedupes() {
        var pendingAuthored = makePullRequest(id: 31, number: 31, category: .authored)
        pendingAuthored.ciStatus = .pending
        pendingAuthored.checkSuccessCount = 0
        pendingAuthored.checkPendingCount = 1
        pendingAuthored.githubCIState = "PENDING"
        pendingAuthored.ciExtendedInfo = CIExtendedInfo(isRunning: true, workflows: [])

        var duplicateMentioned = makePullRequest(id: pendingAuthored.id, number: 31, category: .mentioned)
        duplicateMentioned.ciStatus = .pending
        duplicateMentioned.checkSuccessCount = 0
        duplicateMentioned.checkPendingCount = 1
        duplicateMentioned.githubCIState = "PENDING"
        duplicateMentioned.ciExtendedInfo = CIExtendedInfo(isRunning: true, workflows: [])

        var pendingMentioned = makePullRequest(id: 34, number: 34, category: .mentioned)
        pendingMentioned.ciStatus = .pending
        pendingMentioned.checkSuccessCount = 0
        pendingMentioned.checkPendingCount = 1
        pendingMentioned.githubCIState = "PENDING"
        pendingMentioned.ciExtendedInfo = CIExtendedInfo(isRunning: true, workflows: [])

        var terminal = makePullRequest(id: 32, number: 32, category: .reviewRequest)
        terminal.ciStatus = .success

        var mergedPending = makePullRequest(
            id: 33,
            number: 33,
            category: .authored,
            mergedAt: Date()
        )
        mergedPending.ciStatus = .pending
        mergedPending.checkPendingCount = 1

        let list = PRList(
            lastUpdated: Date(),
            pullRequests: [pendingAuthored, terminal],
            mentionedPullRequests: [duplicateMentioned, pendingMentioned],
            mergedPullRequests: [mergedPending],
            isLoading: false,
            error: nil
        )

        let candidates = CIWatchPlanner.watchCandidates(from: list)

        XCTAssertEqual(candidates.map(\.id), [pendingAuthored.id, pendingMentioned.id])
        XCTAssertTrue(CIWatchPlanner.shouldRun(for: list))
    }

    func testCIWatchPlannerStopsWhenNoVisiblePRHasInFlightCI() {
        var expected = makePullRequest(id: 41, number: 41, category: .authored)
        expected.ciStatus = .expected
        expected.checkPendingCount = 0
        expected.ciExtendedInfo = nil
        let list = PRList(
            lastUpdated: Date(),
            pullRequests: [expected],
            mentionedPullRequests: [],
            mergedPullRequests: [],
            isLoading: false,
            error: nil
        )

        XCTAssertFalse(CIWatchPlanner.shouldRun(for: list))
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

    func testCachedPRDetailInvalidatesWhenBaseConflictsAppearWithoutPRUpdate() {
        let now = Date(timeIntervalSince1970: 1_713_666_108)
        // Base branch advanced into a conflict: none of the other index scalars
        // move, only the derived conflict flag does.
        let cachedSnapshot = makeIndexSnapshot(updatedAt: now, hasBaseConflicts: false)
        let freshSnapshot = makeIndexSnapshot(updatedAt: now, hasBaseConflicts: true)
        let cached = CachedPRDetail(
            prId: 18682,
            indexSnapshot: cachedSnapshot,
            detail: makePullRequest(id: 18682, number: 18682, category: .authored),
            detailFetchedAt: now
        )

        XCTAssertFalse(cached.isUsable(against: freshSnapshot, now: now, ttl: PRDetailCache.ttl))
    }

    func testIndexSnapshotDecodeWithoutBaseConflictsForcesCacheMiss() throws {
        struct LegacyIndexSnapshot: Codable {
            let updatedAt: Date
            let headOid: String?
            let ciRollupState: String?
            let reviewThreadTotal: Int
            let commentTotal: Int
            let reviewTotal: Int
            let unresolvedReviewThreadCount: Int
        }

        let now = Date(timeIntervalSince1970: 1_713_666_108)
        let legacy = LegacyIndexSnapshot(
            updatedAt: now,
            headOid: "f574918fa04b0c7ac49de5b1f3876c430d16e81c",
            ciRollupState: "SUCCESS",
            reviewThreadTotal: 0,
            commentTotal: 0,
            reviewTotal: 0,
            unresolvedReviewThreadCount: 0
        )
        let decoded = try JSONDecoder().decode(IndexSnapshot.self, from: JSONEncoder().encode(legacy))
        let current = makeIndexSnapshot(
            updatedAt: now,
            headOid: "f574918fa04b0c7ac49de5b1f3876c430d16e81c",
            ciRollupState: "SUCCESS",
            hasBaseConflicts: false
        )

        XCTAssertNil(decoded.hasBaseConflicts)
        XCTAssertNotEqual(decoded, current)
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

    func testCachedPRDetailWithoutCIContextParserVersionForcesCacheMiss() throws {
        struct LegacyCachedPRDetail: Codable {
            let prId: Int
            let indexSnapshot: IndexSnapshot
            let detail: PullRequest
            let detailFetchedAt: Date
        }

        let now = Date(timeIntervalSince1970: 1_713_666_108)
        let snapshot = makeIndexSnapshot(updatedAt: now, ciRollupState: "FAILURE")
        var pr = makePullRequest(id: 8, number: 8, category: .authored)
        pr.ciStatus = .failure
        pr.checkFailureCount = 1
        pr.githubCIState = "FAILURE"
        pr.graphqlNodeId = "PR_node_8"
        pr.baseRefName = "main"
        pr.headRefName = "feature"

        let legacy = LegacyCachedPRDetail(
            prId: pr.id,
            indexSnapshot: snapshot,
            detail: pr,
            detailFetchedAt: now
        )
        let cached = try JSONDecoder().decode(CachedPRDetail.self, from: JSONEncoder().encode(legacy))

        XCTAssertFalse(cached.isUsable(against: snapshot, now: now, ttl: PRDetailCache.ttl))
    }

    func testRunningToFailureSnapshotChangeCausesCacheMiss() {
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
        visible.jiraTicket = "EG-1234"
        visible.approvalCount = 2
        visible.approvalAuthors = ["alice", "bob"]
        visible.reviewThreads = [makeReviewThread(id: "thread-1", isRead: true)]

        let indexed = makeIndexedPR(
            id: visible.id,
            number: visible.number,
            baseNeedsUpdate: nil
        )

        let placeholder = indexed.placeholderPullRequest(preserving: visible)

        XCTAssertEqual(placeholder.jiraTicket, "EG-1234")
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
        visible.jiraTicket = "FOO-456"
        visible.approvalCount = 2
        visible.approvalAuthors = ["reviewer"]

        let indexed = makeIndexedPR(
            id: cached.id,
            number: cached.number,
            baseNeedsUpdate: nil
        )

        let placeholder = indexed.placeholderPullRequest(using: cached, preserving: visible)

        XCTAssertEqual(placeholder.jiraTicket, "FOO-456")
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
                owner: "octocat",
                repo: "example-repo",
                base: "master",
                head: "fix/mcp-oauth2-jwt"
            )
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://api.github.com/repos/octocat/example-repo/compare/master...fix%2Fmcp-oauth2-jwt"
        )
    }

    @MainActor
    func testPRListViewModelSearchMatchesJiraTicketsAndMetadataAcrossSections() {
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
        matchingOpen.jiraTicket = "EG-1234"
        matchingOpen.jiraTitle = "Release dashboard cleanup"
        matchingOpen.jiraLabels = ["2.0", "release"]
        var nonMatchingOpen = makePullRequest(id: 18005, number: 102, category: .authored)
        nonMatchingOpen.jiraTicket = "FOO-456"
        var matchingMentioned = makePullRequest(id: 18008, number: 105, category: .mentioned)
        matchingMentioned.jiraTicket = "EG-105"
        matchingMentioned.jiraStatusName = "In Progress"
        var matchingMerged = makePullRequest(
            id: 18006,
            number: 103,
            category: .authored,
            mergedAt: Date().addingTimeInterval(-60)
        )
        matchingMerged.jiraTicket = "EG-1234"
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
            mentionedPullRequests: [matchingMentioned],
            mergedPullRequests: [matchingMerged, nonMatchingMerged],
            isLoading: false,
            error: nil
        )
        viewModel.searchText = "eg-1234"

        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [matchingOpen.id])
        XCTAssertEqual(viewModel.mergedLast24hPRs.map(\.id), [matchingMerged.id])

        viewModel.searchText = "2.0"
        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [matchingOpen.id])

        viewModel.searchText = "progress"
        XCTAssertEqual(viewModel.mentionedPRs.map(\.id), [matchingMentioned.id])

        viewModel.searchText = "jira:dashboard"
        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [matchingOpen.id])

        viewModel.searchText = "jira:tester"
        XCTAssertTrue(viewModel.filteredPRs.isEmpty)
    }

    @MainActor
    func testPRListViewModelSearchMatchesScopedStatusFilters() {
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

        var passing = makePullRequest(id: 18101, number: 201, category: .authored)
        passing.ciStatus = .success
        passing.checkSuccessCount = 3
        passing.approvalCount = 2

        var failing = makePullRequest(id: 18102, number: 202, category: .authored)
        failing.ciStatus = .failure
        failing.checkSuccessCount = 0
        failing.checkFailureCount = 1

        var running = makePullRequest(id: 18103, number: 203, category: .authored)
        running.ciStatus = .pending
        running.checkSuccessCount = 0
        running.checkPendingCount = 1
        running.ciExtendedInfo = CIExtendedInfo(isRunning: true, workflows: [])

        var conflict = makePullRequest(id: 18104, number: 204, category: .authored, hasBaseConflicts: true)
        conflict.approvalCount = 3

        viewModel.prList = PRList(
            lastUpdated: Date(),
            pullRequests: [passing, failing, running, conflict],
            mentionedPullRequests: [],
            mergedPullRequests: [],
            isLoading: false,
            error: nil
        )

        viewModel.searchText = "ci:pass"
        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [passing.id, conflict.id])

        viewModel.searchText = "ci:failure"
        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [failing.id])

        viewModel.searchText = "ci:running"
        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [running.id])

        viewModel.searchText = "pr:conflict"
        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [conflict.id])

        viewModel.searchText = "approval:>=2"
        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [passing.id, conflict.id])

        viewModel.searchText = "approval:<2"
        XCTAssertEqual(viewModel.filteredPRs.map(\.id), [failing.id, running.id])
    }

    func testPRSearchScopeSuggestsEnumValuesOnly() {
        XCTAssertEqual(
            PRSearchScope.suggestions(for: "ci:").map(\.query),
            ["ci:pass", "ci:failure", "ci:running"]
        )
        XCTAssertEqual(PRSearchScope.suggestions(for: "ci:f").map(\.query), ["ci:failure"])
        XCTAssertEqual(PRSearchScope.suggestions(for: "CI:R").map(\.query), ["ci:running"])
        XCTAssertTrue(PRSearchScope.suggestions(for: "ci:failure").isEmpty)

        XCTAssertEqual(PRSearchScope.suggestions(for: "pr:").map(\.query), ["pr:conflict"])
        XCTAssertEqual(PRSearchScope.suggestions(for: "pr:c").map(\.query), ["pr:conflict"])
        XCTAssertTrue(PRSearchScope.suggestions(for: "pr:conflict").isEmpty)

        XCTAssertTrue(PRSearchScope.suggestions(for: "jira:").isEmpty)
        XCTAssertTrue(PRSearchScope.suggestions(for: "approval:").isEmpty)
    }

    func testPullRequestDecodesWhenJiraMetadataFieldsAreMissing() throws {
        let pr = makePullRequest(id: 18100, number: 201, category: .authored)
        let data = try JSONEncoder().encode(pr)

        let decoded = try JSONDecoder().decode(PullRequest.self, from: data)

        XCTAssertEqual(decoded.id, pr.id)
        XCTAssertNil(decoded.jiraTitle)
        XCTAssertNil(decoded.jiraLabels)
        XCTAssertNil(decoded.jiraStatusName)
        XCTAssertNil(decoded.jiraMetadataFetchedAt)
    }

    func testJiraAPIClientParsesLabelsStatusAndUpdated() async throws {
        let suiteName = "PRDashboardTests.Jira.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cache = JiraMetadataCache(defaults: defaults)
        let client = JiraAPIClient(session: Self.makeMockJiraSession(), cache: cache)
        let expectedAuth = "Basic \(Data("me@example.com:token".utf8).base64EncodedString())"
        MockJiraURLProtocol.reset { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://example.atlassian.net/rest/api/3/search/jql")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuth)

            let data = """
            {
              "issues": [
                {
                  "key": "EG-123",
                  "fields": {
                    "summary": "Release dashboard cleanup",
                    "labels": ["2.0", "release"],
                    "status": {
                      "name": "In Progress",
                      "statusCategory": { "key": "indeterminate" }
                    },
                    "updated": "2026-05-20T13:14:15.123+0000"
                  }
                }
              ]
            }
            """.data(using: .utf8)!
            return (Self.httpResponse(for: request, statusCode: 200), data)
        }
        defer { MockJiraURLProtocol.reset() }

        let metadata = try await client.fetchMetadata(
            for: ["EG-123"],
            serverURL: "https://example.atlassian.net",
            email: "me@example.com",
            apiToken: "token",
            refreshInterval: 900
        )

        let issue = try XCTUnwrap(metadata["EG-123"])
        XCTAssertEqual(issue.title, "Release dashboard cleanup")
        XCTAssertEqual(issue.labels, ["2.0", "release"])
        XCTAssertEqual(issue.statusName, "In Progress")
        XCTAssertEqual(issue.statusCategoryKey, "indeterminate")
        XCTAssertNotNil(issue.updatedAt)
    }

    func testJiraAPIClientTestConnectionUsesMyselfEndpoint() async throws {
        let client = JiraAPIClient(session: Self.makeMockJiraSession())
        let expectedAuth = "Basic \(Data("me@example.com:token".utf8).base64EncodedString())"
        MockJiraURLProtocol.reset { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://example.atlassian.net/rest/api/3/myself")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuth)

            let data = """
            {
              "displayName": "Jiahao Wang",
              "emailAddress": "jiahao@example.com"
            }
            """.data(using: .utf8)!
            return (Self.httpResponse(for: request, statusCode: 200), data)
        }
        defer { MockJiraURLProtocol.reset() }

        let result = try await client.testConnection(
            serverURL: "https://example.atlassian.net",
            email: "me@example.com",
            apiToken: "token"
        )

        XCTAssertEqual(result.displayName, "Jiahao Wang")
        XCTAssertEqual(result.emailAddress, "jiahao@example.com")
    }

    func testJiraAPIClientTestConnectionRejectsUnauthorized() async throws {
        let client = JiraAPIClient(session: Self.makeMockJiraSession())
        MockJiraURLProtocol.reset { request in
            (Self.httpResponse(for: request, statusCode: 401), Data())
        }
        defer { MockJiraURLProtocol.reset() }

        do {
            _ = try await client.testConnection(
                serverURL: "https://example.atlassian.net",
                email: "me@example.com",
                apiToken: "bad-token"
            )
            XCTFail("Expected unauthorized Jira test connection to throw")
        } catch JiraAPIError.unauthorized {
            XCTAssertEqual(MockJiraURLProtocol.requestedURLs.count, 1)
        } catch {
            XCTFail("Expected JiraAPIError.unauthorized, got \(error)")
        }
    }

    func testJiraAPIClientUsesFreshCacheWithoutNetworkRequest() async throws {
        let suiteName = "PRDashboardTests.Jira.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cache = JiraMetadataCache(defaults: defaults)
        let now = Date()
        let cached = JiraIssueMetadata(
            key: "EG-123",
            labels: ["2.0"],
            statusName: "Done",
            statusCategoryKey: "done",
            updatedAt: nil,
            fetchedAt: now
        )
        cache.save(["EG-123": cached], serverURL: "https://example.atlassian.net")

        let client = JiraAPIClient(session: Self.makeMockJiraSession(), cache: cache)
        MockJiraURLProtocol.reset { request in
            XCTFail("Fresh Jira cache should avoid a network request: \(String(describing: request.url))")
            return (Self.httpResponse(for: request, statusCode: 500), Data())
        }
        defer { MockJiraURLProtocol.reset() }

        let metadata = try await client.fetchMetadata(
            for: ["EG-123"],
            serverURL: "https://example.atlassian.net",
            email: "me@example.com",
            apiToken: "token",
            refreshInterval: 3600,
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(metadata["EG-123"], cached)
        XCTAssertTrue(MockJiraURLProtocol.requestedURLs.isEmpty)
    }

    func testJiraAPIClientReturnsEmptyMetadataForMissingIssue() async throws {
        let suiteName = "PRDashboardTests.Jira.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = JiraAPIClient(
            session: Self.makeMockJiraSession(),
            cache: JiraMetadataCache(defaults: defaults)
        )
        MockJiraURLProtocol.reset { request in
            let data = #"{"issues":[]}"#.data(using: .utf8)!
            return (Self.httpResponse(for: request, statusCode: 200), data)
        }
        defer { MockJiraURLProtocol.reset() }

        let metadata = try await client.fetchMetadata(
            for: ["EG-404"],
            serverURL: "https://example.atlassian.net",
            email: "me@example.com",
            apiToken: "token",
            refreshInterval: 900
        )

        let issue = try XCTUnwrap(metadata["EG-404"])
        XCTAssertEqual(issue.labels, [])
        XCTAssertNil(issue.statusName)
        XCTAssertNil(issue.statusCategoryKey)
    }

    func testJiraAPIClientSkipsFetchWhenAuthIsIncomplete() async throws {
        let suiteName = "PRDashboardTests.Jira.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = JiraAPIClient(
            session: Self.makeMockJiraSession(),
            cache: JiraMetadataCache(defaults: defaults)
        )
        MockJiraURLProtocol.reset { request in
            XCTFail("Incomplete Jira auth should not hit the network: \(String(describing: request.url))")
            return (Self.httpResponse(for: request, statusCode: 500), Data())
        }
        defer { MockJiraURLProtocol.reset() }

        let metadata = try await client.fetchMetadata(
            for: ["EG-123"],
            serverURL: "https://example.atlassian.net",
            email: "me@example.com",
            apiToken: "",
            refreshInterval: 900
        )

        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(MockJiraURLProtocol.requestedURLs.isEmpty)
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

    private func makeMockUpdateSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeMockGitHubActionsSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubActionsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeMockJiraSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockJiraURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func httpResponse(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func workflowRun(
        id: Int,
        name: String? = nil,
        displayTitle: String? = nil,
        path: String? = nil,
        workflowId: Int? = nil,
        runNumber: Int = 1,
        runAttempt: Int = 1,
        status: String? = nil,
        conclusion: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> GitHubAPIClient.WorkflowRunSnapshot {
        GitHubAPIClient.WorkflowRunSnapshot(
            id: id,
            name: name,
            displayTitle: displayTitle,
            path: path,
            workflowId: workflowId,
            runNumber: runNumber,
            runAttempt: runAttempt,
            status: status,
            conclusion: conclusion,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func installMockReleaseResponses(tag: String = "v999.0.0") {
        MockUpdateURLProtocol.reset { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )

            if url.absoluteString == "https://github.com/xiaocang/ghpr-view/releases.atom" {
                return (response, Self.releaseAtomData(tag: tag))
            }

            if url.absoluteString == "https://api.github.com/repos/xiaocang/ghpr-view/releases/tags/\(tag)" {
                return (response, Self.releaseAssetsData(version: AppVersion(tag).description))
            }

            XCTFail("Unexpected update request URL: \(url.absoluteString)")
            return (response, Data("{}".utf8))
        }
    }

    @MainActor
    private func waitForCondition(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private static func releaseAtomData(tag: String) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>PR Dashboard \(AppVersion(tag).description)</title>
                <updated>2026-05-19T00:00:00Z</updated>
                <link href="https://github.com/xiaocang/ghpr-view/releases/tag/\(tag)" />
                <content type="html">Bug fixes</content>
              </entry>
            </feed>
            """.utf8
        )
    }

    private static func releaseAssetsData(version: String) -> Data {
        Data(
            """
            {
              "assets": [
                {
                  "name": "PRDashboard-\(version).zip",
                  "browser_download_url": "https://example.com/PRDashboard-\(version).zip",
                  "size": 42
                }
              ]
            }
            """.utf8
        )
    }

    private func makeIndexSnapshot(
        updatedAt: Date = Date(timeIntervalSince1970: 1_713_666_108),
        headOid: String? = "abc123",
        ciRollupState: String? = "SUCCESS",
        reviewThreadTotal: Int = 0,
        commentTotal: Int = 0,
        reviewTotal: Int = 0,
        unresolvedReviewThreadCount: Int = 0,
        hasBaseConflicts: Bool? = false
    ) -> IndexSnapshot {
        IndexSnapshot(
            updatedAt: updatedAt,
            headOid: headOid,
            ciRollupState: ciRollupState,
            reviewThreadTotal: reviewThreadTotal,
            commentTotal: commentTotal,
            reviewTotal: reviewTotal,
            unresolvedReviewThreadCount: unresolvedReviewThreadCount,
            hasBaseConflicts: hasBaseConflicts
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
            repositoryIsArchived: nil,
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

private final class MockUpdateURLProtocol: URLProtocol {
    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: RequestHandler?
    private static var recordedURLs: [URL] = []

    static var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    static func reset(handler: RequestHandler? = nil) {
        lock.lock()
        self.handler = handler
        recordedURLs = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.record(request.url)

        guard let handler = Self.currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static var currentHandler: RequestHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    private static func record(_ url: URL?) {
        guard let url else { return }

        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
    }
}

private final class MockGitHubActionsURLProtocol: URLProtocol {
    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: RequestHandler?

    static func reset(handler: RequestHandler? = nil) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static var currentHandler: RequestHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

private final class MockJiraURLProtocol: URLProtocol {
    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: RequestHandler?
    private static var recordedURLs: [URL] = []

    static var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    static func reset(handler: RequestHandler? = nil) {
        lock.lock()
        self.handler = handler
        recordedURLs = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.record(request.url)

        guard let handler = Self.currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static var currentHandler: RequestHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    private static func record(_ url: URL?) {
        guard let url else { return }

        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
    }
}

private extension CmuxCommandResult {
    static func success(stdout: String = "") -> CmuxCommandResult {
        CmuxCommandResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false)
    }
}

// MARK: - Archived Repository Filtering Tests

final class ArchivedRepoFilterTests: XCTestCase {

    /// Helper: minimal IndexSearchResponse JSON for one PR node.
    private func indexSearchJSON(isArchived: Bool) -> Data {
        let json = """
        {
            "data": {
                "search": {
                    "nodes": [
                        {
                            "id": "PR_node_1",
                            "databaseId": 42,
                            "number": 100,
                            "title": "Some PR",
                            "url": "https://github.com/owner/repo/pull/100",
                            "state": "OPEN",
                            "isDraft": false,
                            "baseRefName": "main",
                            "headRefName": "feature",
                            "createdAt": "2026-01-01T00:00:00Z",
                            "updatedAt": "2026-01-02T00:00:00Z",
                            "mergedAt": null,
                            "mergeable": "MERGEABLE",
                            "mergeStateStatus": "CLEAN",
                            "author": { "login": "testuser", "avatarUrl": null },
                            "repository": {
                                "owner": { "login": "owner" },
                                "name": "repo",
                                "isArchived": \(isArchived)
                            },
                            "reviewThreads": { "totalCount": 0, "nodes": [] },
                            "oldestReviewThreads": { "totalCount": 0, "nodes": [] },
                            "comments": { "totalCount": 0 },
                            "reviews": { "totalCount": 0 },
                            "commits": {
                                "nodes": [{
                                    "commit": {
                                        "oid": "abc123",
                                        "committedDate": "2026-01-02T00:00:00Z",
                                        "statusCheckRollup": { "state": "SUCCESS" }
                                    }
                                }]
                            }
                        }
                    ]
                },
                "rateLimit": { "cost": 1, "remaining": 4999, "resetAt": "2026-01-02T01:00:00Z" }
            }
        }
        """
        return Data(json.utf8)
    }

    private func decodeIndexNodes(from data: Data) throws -> [IndexSearchResponse.PRNode] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(IndexSearchResponse.self, from: data)
        return response.data.search.nodes
    }

    private func makePullRequest(isArchived: Bool) throws -> PullRequest {
        let nodes = try decodeIndexNodes(from: indexSearchJSON(isArchived: isArchived))
        let indexed = GitHubAPIClient(token: "fake").buildIndexedPRs(
            authored: nodes,
            reviewRequested: [],
            reviewedBy: [],
            mergedInvolved: [],
            username: "testuser"
        )
        return try XCTUnwrap(indexed.first).placeholderPullRequest()
    }

    func testIndexSearchResponseDecodesIsArchivedTrue() throws {
        let nodes = try decodeIndexNodes(from: indexSearchJSON(isArchived: true))
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.repository.isArchived, true)
    }

    func testIndexSearchResponseDecodesIsArchivedFalse() throws {
        let nodes = try decodeIndexNodes(from: indexSearchJSON(isArchived: false))
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.repository.isArchived, false)
    }

    func testBuildIndexedPRsPreservesArchivedRepositoryStatus() throws {
        let pr = try makePullRequest(isArchived: true)

        XCTAssertEqual(pr.repositoryIsArchived, true)
    }

    func testBuildIndexedPRsPreservesNonArchivedRepositoryStatus() throws {
        let pr = try makePullRequest(isArchived: false)

        XCTAssertEqual(pr.repositoryIsArchived, false)
    }

    func testDefaultFilterExcludesArchivedRepository() throws {
        let pr = try makePullRequest(isArchived: true)

        let result = PullRequestFilter.apply([pr], configuration: .default)

        XCTAssertTrue(result.isEmpty, "Archived repositories should be hidden by default")
    }

    func testDefaultFilterIncludesNonArchivedRepository() throws {
        let pr = try makePullRequest(isArchived: false)

        let result = PullRequestFilter.apply([pr], configuration: .default)

        XCTAssertEqual(result.map(\.id), [pr.id])
    }

    func testExplicitRepositoryFilterIncludesArchivedRepository() throws {
        let pr = try makePullRequest(isArchived: true)
        var configuration = Configuration.default
        configuration.repositories = ["OWNER/REPO"]

        let result = PullRequestFilter.apply([pr], configuration: configuration)

        XCTAssertEqual(result.map(\.id), [pr.id])
    }

    func testOwnerFilterDoesNotExplicitlyIncludeArchivedRepository() throws {
        let pr = try makePullRequest(isArchived: true)
        var configuration = Configuration.default
        configuration.repositories = ["owner/"]

        let result = PullRequestFilter.apply([pr], configuration: configuration)

        XCTAssertTrue(result.isEmpty)
    }

    func testOwnerFilterIncludesNonArchivedRepository() throws {
        let pr = try makePullRequest(isArchived: false)
        var configuration = Configuration.default
        configuration.repositories = ["owner/"]

        let result = PullRequestFilter.apply([pr], configuration: configuration)

        XCTAssertEqual(result.map(\.id), [pr.id])
    }

    func testDifferentRepositoryFilterStillExcludesArchivedRepository() throws {
        let pr = try makePullRequest(isArchived: true)
        var configuration = Configuration.default
        configuration.repositories = ["other/repo"]

        let result = PullRequestFilter.apply([pr], configuration: configuration)

        XCTAssertTrue(result.isEmpty)
    }

    func testDifferentRepositoryFilterExcludesNonArchivedRepository() throws {
        let pr = try makePullRequest(isArchived: false)
        var configuration = Configuration.default
        configuration.repositories = ["other/repo"]

        let result = PullRequestFilter.apply([pr], configuration: configuration)

        XCTAssertTrue(result.isEmpty)
    }

    func testMentionedRefreshArchiveStatusIsImmediatelyFilterable() throws {
        var old = try makePullRequest(isArchived: false)
        var fresh = try makePullRequest(isArchived: true)
        old.ciStatus = .pending
        fresh.ciStatus = .success

        let refreshed = GitHubAPIClient.mergeMentionedRefreshResults(
            existing: [old],
            refreshedByID: [fresh.id: fresh]
        )

        XCTAssertEqual(refreshed.first?.repositoryIsArchived, true)
        XCTAssertEqual(refreshed.first?.ciStatus, .success)
        XCTAssertTrue(PullRequestFilter.apply(refreshed, configuration: .default).isEmpty)
    }

    func testCachedPRListFilterExcludesArchivedRepositoriesFromEverySection() throws {
        let archived = try makePullRequest(isArchived: true)
        let active = try makePullRequest(isArchived: false)
        var cached = PRList(
            lastUpdated: Date(),
            pullRequests: [archived, active],
            mentionedPullRequests: [archived],
            mergedPullRequests: [archived],
            isLoading: false,
            error: nil
        )

        PullRequestFilter.apply(to: &cached, configuration: .default)

        XCTAssertEqual(cached.pullRequests.map(\.repositoryIsArchived), [false])
        XCTAssertTrue(cached.mentionedPullRequests.isEmpty)
        XCTAssertTrue(cached.mergedPullRequests.isEmpty)
    }
}
