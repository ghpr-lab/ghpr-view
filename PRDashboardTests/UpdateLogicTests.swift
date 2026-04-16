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
