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
            from: "Do not treat other/repo#12 as repo-local #12.",
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
        XCTAssertEqual(list.totalUnresolvedCount, 0)
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

    private func makePullRequest(
        id: Int,
        number: Int,
        category: PRCategory,
        reviewThreads: [ReviewThread] = [],
        hasBaseConflicts: Bool = false
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
            state: .open,
            isDraft: false,
            createdAt: Date(),
            updatedAt: Date(),
            mergedAt: nil,
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

    func testOpenExistingPRFocusesAndReloadsMatchingTab() {
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
            ["--json", "tree", "--all"],
            ["focus-window", "--window", "window:1"],
            ["select-workspace", "--workspace", "workspace:2"],
            ["focus-panel", "--workspace", "workspace:2", "--panel", "surface:3"],
            ["browser", "--surface", "surface:3", "reload"]
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
            ["--json", "tree", "--all"]
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
            ["--json", "tree", "--all"]
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
