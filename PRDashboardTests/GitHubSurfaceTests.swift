import Foundation
import XCTest
@testable import PRDashboard

/// Coverage for the exact-subject model (`GitHubSubject` and friends) introduced to
/// replace page/job-name identity, plus the compatibility surfaces that must keep
/// working while the GitHub-native v2 rollout is incomplete.
final class GitHubSurfaceTests: XCTestCase {

    // MARK: - PullRequestRevisionSubject validation

    func testPullRequestRevisionSubjectRejectsInvalidRepository() {
        XCTAssertThrowsError(
            try PullRequestRevisionSubject(
                repository: "not-a-repo",
                prNumber: 42,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40)
            )
        ) { error in
            XCTAssertEqual(error as? SubjectValidationError, .invalid("repository"))
        }
    }

    func testPullRequestRevisionSubjectRejectsNonPositivePRNumber() {
        XCTAssertThrowsError(
            try PullRequestRevisionSubject(
                repository: "owner/repo",
                prNumber: 0,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40)
            )
        ) { error in
            XCTAssertEqual(error as? SubjectValidationError, .invalid("prNumber"))
        }
    }

    func testPullRequestRevisionSubjectRejectsMalformedSHAs() {
        XCTAssertThrowsError(
            try PullRequestRevisionSubject(
                repository: "owner/repo",
                prNumber: 1,
                baseSHA: "short",
                headSHA: String(repeating: "b", count: 40)
            )
        ) { error in
            XCTAssertEqual(error as? SubjectValidationError, .invalid("sha"))
        }
    }

    func testPullRequestRevisionSubjectLowercasesSHAs() throws {
        let subject = try PullRequestRevisionSubject(
            repository: "Owner/Repo",
            prNumber: 7,
            baseSHA: String(repeating: "A", count: 40),
            headSHA: String(repeating: "B", count: 40)
        )
        XCTAssertEqual(subject.baseSHA, String(repeating: "a", count: 40))
        XCTAssertEqual(subject.headSHA, String(repeating: "b", count: 40))
    }

    // MARK: - WorkflowJobSubject validation

    func testWorkflowJobSubjectRejectsNonPositiveIdentifiers() {
        XCTAssertThrowsError(
            try WorkflowJobSubject(
                repository: "owner/repo",
                workflowRunID: 0,
                workflowAttempt: 1,
                workflowJobID: 1,
                headSHA: String(repeating: "a", count: 40)
            )
        ) { error in
            XCTAssertEqual(error as? SubjectValidationError, .invalid("workflowRunID"))
        }
    }

    func testWorkflowJobSubjectRejectsMalformedHeadSHA() {
        XCTAssertThrowsError(
            try WorkflowJobSubject(
                repository: "owner/repo",
                workflowRunID: 1,
                workflowAttempt: 1,
                workflowJobID: 1,
                headSHA: "not-a-sha"
            )
        ) { error in
            XCTAssertEqual(error as? SubjectValidationError, .invalid("headSHA"))
        }
    }

    // MARK: - DiffAnchor validation

    func testDiffAnchorRejectsPathTraversal() {
        XCTAssertThrowsError(
            try DiffAnchor(
                repository: "owner/repo",
                prNumber: 1,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40),
                filePath: "../etc/passwd",
                side: .right,
                startLine: 1,
                endLine: 1
            )
        ) { error in
            XCTAssertEqual(error as? SubjectValidationError, .invalid("diff anchor"))
        }
    }

    func testDiffAnchorRejectsInvertedLineRange() {
        XCTAssertThrowsError(
            try DiffAnchor(
                repository: "owner/repo",
                prNumber: 1,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40),
                filePath: "src/main.swift",
                side: .right,
                startLine: 10,
                endLine: 5
            )
        ) { error in
            XCTAssertEqual(error as? SubjectValidationError, .invalid("diff anchor"))
        }
    }

    func testDiffAnchorRejectsMalformedBlobSHA() {
        XCTAssertThrowsError(
            try DiffAnchor(
                repository: "owner/repo",
                prNumber: 1,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40),
                blobSHA: "not-a-sha",
                filePath: "src/main.swift",
                side: .right,
                startLine: 1,
                endLine: 1
            )
        ) { error in
            XCTAssertEqual(error as? SubjectValidationError, .invalid("blobSHA"))
        }
    }

    func testDiffAnchorAcceptsValidLeftAndRightAnchors() throws {
        let anchor = try DiffAnchor(
            repository: "owner/repo",
            prNumber: 1,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40),
            blobSHA: String(repeating: "c", count: 40),
            filePath: "src/main.swift",
            side: .left,
            startLine: 3,
            endLine: 5,
            hunkFingerprint: "fingerprint",
            quotedCode: "let x = 1"
        )
        XCTAssertEqual(anchor.side, .left)
        XCTAssertEqual(anchor.startLine, 3)
        XCTAssertEqual(anchor.endLine, 5)
        XCTAssertEqual(anchor.blobSHA, String(repeating: "c", count: 40))
    }

    // MARK: - GitHubSubject.subjectKey stability and distinctness

    func testPullRequestRevisionSubjectKeyIsStableAndScopedToRevision() throws {
        let base = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40)
        )
        let sameAgain = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40)
        )
        let newHead = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "d", count: 40)
        )
        XCTAssertEqual(
            GitHubSubject.pullRequestRevision(base).subjectKey,
            GitHubSubject.pullRequestRevision(sameAgain).subjectKey
        )
        XCTAssertNotEqual(
            GitHubSubject.pullRequestRevision(base).subjectKey,
            GitHubSubject.pullRequestRevision(newHead).subjectKey
        )
    }

    func testWorkflowJobSubjectKeyIsDistinctByRunAttemptJobAndHead() throws {
        func job(runID: Int64 = 1, attempt: Int = 1, jobID: Int64 = 1, head: String = String(repeating: "a", count: 40)) throws -> GitHubSubject {
            .workflowJob(try WorkflowJobSubject(
                repository: "owner/repo",
                workflowRunID: runID,
                workflowAttempt: attempt,
                workflowJobID: jobID,
                headSHA: head
            ))
        }
        let base = try job()
        XCTAssertEqual(base.subjectKey, (try job()).subjectKey, "Identical inputs must produce identical keys.")
        XCTAssertNotEqual(base.subjectKey, (try job(runID: 2)).subjectKey, "Different run IDs are different jobs.")
        XCTAssertNotEqual(base.subjectKey, (try job(attempt: 2)).subjectKey, "A retried attempt must not collide with the original.")
        XCTAssertNotEqual(base.subjectKey, (try job(jobID: 2)).subjectKey, "Different jobs within the same run are distinct.")
        XCTAssertNotEqual(base.subjectKey, (try job(head: String(repeating: "e", count: 40))).subjectKey, "A new head SHA must not reuse a stale job's key.")
    }

    func testDiffLineSubjectKeyIsContentAddressedAndDistinctBySideAndRange() throws {
        func anchor(side: DiffSide = .right, start: Int = 10, end: Int = 10) throws -> GitHubSubject {
            .diffLine(try DiffAnchor(
                repository: "owner/repo",
                prNumber: 1,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40),
                filePath: "src/main.swift",
                side: side,
                startLine: start,
                endLine: end
            ))
        }
        let base = try anchor()
        XCTAssertEqual(base.subjectKey, (try anchor()).subjectKey)
        XCTAssertTrue(base.subjectKey.hasPrefix("github:diff-line:"))
        XCTAssertNotEqual(base.subjectKey, (try anchor(side: .left)).subjectKey)
        XCTAssertNotEqual(base.subjectKey, (try anchor(start: 11, end: 11)).subjectKey)
    }

    func testLegacyPageSubjectKeyIsDerivedFromPageKey() {
        let page = GitHubPageContext.pullRequest(repository: "owner/repo", number: 9)
        let subject = GitHubSubject.legacyPage(page)
        XCTAssertEqual(subject.subjectKey, "github:legacy-page:\(page.key)")
    }

    // MARK: - GitHubSubject.page derivation

    func testSubjectPageDerivesFromEachExactKind() throws {
        let pr = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 5,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40)
        )
        XCTAssertEqual(
            GitHubSubject.pullRequestRevision(pr).page,
            .pullRequest(repository: "owner/repo", number: 5)
        )

        let job = try WorkflowJobSubject(
            repository: "owner/repo",
            workflowRunID: 100,
            workflowAttempt: 1,
            workflowJobID: 200,
            headSHA: String(repeating: "a", count: 40)
        )
        XCTAssertEqual(
            GitHubSubject.workflowJob(job).page,
            .workflowRun(repository: "owner/repo", runID: 100)
        )

        let diff = try DiffAnchor(
            repository: "owner/repo",
            prNumber: 5,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40),
            filePath: "a.swift",
            side: .right,
            startLine: 1,
            endLine: 1
        )
        XCTAssertEqual(
            GitHubSubject.diffLine(diff).page,
            .pullRequest(repository: "owner/repo", number: 5)
        )
    }

    // MARK: - Finding lifecycle resolution

    func testFindingResolverUsesUniqueQuotedCodeWhenHunkContextIsAmbiguous() throws {
        let reviewedPatch = ReviewPatchIndex(
            """
            diff --git a/a.swift b/a.swift
            --- a/a.swift
            +++ b/a.swift
            @@ -10,3 +10,3 @@
             let context = true
            -let target = false
            +let target = true
             let tail = true
            """
        )
        let fingerprint = try XCTUnwrap(
            reviewedPatch.hunkFingerprint(
                file: "a.swift",
                side: .right,
                startLine: 11,
                endLine: 11
            )
        )
        let originalAnchor = try DiffAnchor(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40),
            filePath: "a.swift",
            side: .right,
            startLine: 11,
            endLine: 11,
            hunkFingerprint: fingerprint,
            quotedCode: "let target = true"
        )
        let originalSubject = GitHubSubject.diffLine(originalAnchor)
        let finding = SkillFinding(
            id: "finding-remap",
            subjectKey: originalSubject.subjectKey,
            subject: originalSubject,
            kind: .reviewFinding,
            severity: .warning,
            title: "Target changed",
            summary: "Review the target.",
            details: nil,
            confidence: 0.9,
            lifecycle: .exact,
            createdAt: Date(timeIntervalSince1970: 0),
            fingerprint: "finding-fingerprint"
        )
        let currentRevision = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "c", count: 40),
            headSHA: String(repeating: "d", count: 40)
        )
        let currentPatch = ReviewPatchIndex(
            """
            diff --git a/a.swift b/a.swift
            --- a/a.swift
            +++ b/a.swift
            @@ -30,3 +30,3 @@
             let context = true
            -let target = false
            +let target = true
             let tail = true
            """
        )

        let resolution = FindingResolver.resolve(
            finding: finding,
            currentRevision: currentRevision,
            patch: currentPatch
        )

        XCTAssertEqual(resolution.lifecycle, .remapped)
        XCTAssertEqual(resolution.resolvedAnchor?.startLine, 31)
        XCTAssertEqual(resolution.resolvedAnchor?.headSHA, currentRevision.headSHA)
        XCTAssertEqual(resolution.confidence, 0.6)
    }

    func testReviewPatchIndexBuildsBoundedLeftAndRightMiniDiffs() {
        let patch = ReviewPatchIndex(
            """
            diff --git a/a.swift b/a.swift
            --- a/a.swift
            +++ b/a.swift
            @@ -10,7 +10,8 @@
             let before = true
            -let oldValue = true
            +let html = "<script>alert(1)</script>"
            +let newValue = true
             let first = true
             let second = true
             let third = true
             let fourth = true
             let after = true
            """
        )

        let removed = patch.snippet(
            file: "a.swift",
            side: .left,
            startLine: 11,
            endLine: 11
        )
        XCTAssertNil(removed.unavailableReason)
        XCTAssertTrue(
            removed.lines.contains {
                $0.kind == .removed && $0.oldLine == 11 && $0.text == "let oldValue = true"
            }
        )

        let range = patch.snippet(
            file: "a.swift",
            side: .right,
            startLine: 11,
            endLine: 15
        )
        XCTAssertNil(range.unavailableReason)
        XCTAssertLessThanOrEqual(range.lines.count, 7)
        XCTAssertTrue(range.lines.contains { $0.kind == .ellipsis })
        XCTAssertEqual(
            patch.targetCode(
                file: "a.swift",
                side: .right,
                startLine: 11,
                endLine: 11
            ),
            #"let html = "<script>alert(1)</script>""#
        )
    }

    // MARK: - GitHubSubject Codable round trip (flat, type-discriminated wire form)

    func testPullRequestRevisionSubjectRoundTripsThroughJSON() throws {
        let subject = GitHubSubject.pullRequestRevision(
            try PullRequestRevisionSubject(
                repository: "owner/repo",
                prNumber: 42,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40)
            )
        )
        let data = try JSONEncoder().encode(subject)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "pull_request_revision")
        XCTAssertEqual(object["repository"] as? String, "owner/repo")
        XCTAssertEqual(object["subjectKey"] as? String, subject.subjectKey)

        let decoded = try JSONDecoder().decode(GitHubSubject.self, from: data)
        XCTAssertEqual(decoded, subject)
    }

    func testWorkflowJobSubjectRoundTripsThroughJSON() throws {
        let subject = GitHubSubject.workflowJob(
            try WorkflowJobSubject(
                repository: "owner/repo",
                workflowRunID: 111,
                workflowAttempt: 2,
                workflowJobID: 222,
                headSHA: String(repeating: "a", count: 40)
            )
        )
        let data = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(GitHubSubject.self, from: data)
        XCTAssertEqual(decoded, subject)
    }

    func testDiffLineSubjectRoundTripsThroughJSON() throws {
        let subject = GitHubSubject.diffLine(
            try DiffAnchor(
                repository: "owner/repo",
                prNumber: 1,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40),
                blobSHA: String(repeating: "c", count: 40),
                filePath: "src/main.swift",
                side: .right,
                startLine: 4,
                endLine: 6,
                hunkFingerprint: "fp",
                quotedCode: "code"
            )
        )
        let data = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(GitHubSubject.self, from: data)
        XCTAssertEqual(decoded, subject)
    }

    func testLegacyPageSubjectDecodesForBackwardCompatibility() throws {
        let page = GitHubPageContext.pullRequest(repository: "owner/repo", number: 3)
        let subject = GitHubSubject.legacyPage(page)
        let data = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(GitHubSubject.self, from: data)
        XCTAssertEqual(decoded, subject)
        guard case .legacyPage(let decodedPage) = decoded else {
            return XCTFail("Expected a decoded .legacyPage case.")
        }
        XCTAssertEqual(decodedPage, page)
    }

    // MARK: - Legacy/mismatch rejection

    func testGitHubSubjectDecodeRejectsSuppliedSubjectKeyMismatch() throws {
        let subject = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40)
        )
        var object: [String: Any] = [
            "type": "pull_request_revision",
            "repository": subject.repository,
            "prNumber": subject.prNumber,
            "baseSHA": subject.baseSHA,
            "headSHA": subject.headSHA,
            "subjectKey": "github:pull-request-revision:owner/repo#42@tampered..tampered"
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(GitHubSubject.self, from: data)) { error in
            XCTAssertEqual(error as? SubjectValidationError, .subjectKeyMismatch)
        }

        // Sanity: the same payload without a mismatched key decodes fine.
        object.removeValue(forKey: "subjectKey")
        let cleanData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNoThrow(try JSONDecoder().decode(GitHubSubject.self, from: cleanData))
    }

    func testGitHubSubjectDecodeRejectsUnknownType() throws {
        let object: [String: Any] = ["type": "something_unsupported"]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(GitHubSubject.self, from: data)) { error in
            XCTAssertEqual(error as? SubjectValidationError, .invalid("type"))
        }
    }

    // MARK: - SkillFinding model

    func testSkillFindingRoundTripsEverySeverityLifecycleAndKind() throws {
        let subject = GitHubSubject.pullRequestRevision(
            try PullRequestRevisionSubject(
                repository: "owner/repo",
                prNumber: 8,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40)
            )
        )
        for severity: FindingSeverity in [.error, .warning, .info] {
            for lifecycle: FindingLifecycle in [.exact, .remapped, .outdated, .unavailable] {
                for kind: FindingKind in [.ciFailureExplanation, .ciFlakyClassification, .reviewFinding] {
                    let finding = SkillFinding(
                        id: "finding_1",
                        subjectKey: subject.subjectKey,
                        subject: subject,
                        kind: kind,
                        severity: severity,
                        title: "Title",
                        summary: "Summary",
                        details: nil,
                        confidence: 0.5,
                        lifecycle: lifecycle,
                        createdAt: Date(timeIntervalSince1970: 0),
                        fingerprint: "fp"
                    )
                    let data = try JSONEncoder().encode(finding)
                    let decoded = try JSONDecoder().decode(SkillFinding.self, from: data)
                    XCTAssertEqual(decoded, finding)
                    XCTAssertEqual(decoded.severity, severity)
                    XCTAssertEqual(decoded.lifecycle, lifecycle)
                    XCTAssertEqual(decoded.kind, kind)
                }
            }
        }
    }

    func testSkillFindingKindWireValuesMapToStableInsightViews() {
        // These raw values are the wire contract consumed by CI Insight / review
        // summary renderers (ci_insight/job_verdict, review_finding/review_summary).
        XCTAssertEqual(FindingKind.ciFailureExplanation.rawValue, "ci_failure_explanation")
        XCTAssertEqual(FindingKind.ciFlakyClassification.rawValue, "ci_flaky_classification")
        XCTAssertEqual(FindingKind.reviewFinding.rawValue, "review_finding")
    }

    func testSkillFindingConfidenceIsOptionalAndPreservedWhenPresent() throws {
        let subject = GitHubSubject.legacyPage(.pullRequest(repository: "owner/repo", number: 1))
        let withoutConfidence = SkillFinding(
            id: "finding_no_conf",
            subjectKey: subject.subjectKey,
            subject: subject,
            kind: .reviewFinding,
            severity: .info,
            title: "t",
            summary: "s",
            details: nil,
            confidence: nil,
            lifecycle: .exact,
            createdAt: Date(timeIntervalSince1970: 0),
            fingerprint: "fp"
        )
        let data = try JSONEncoder().encode(withoutConfidence)
        let decoded = try JSONDecoder().decode(SkillFinding.self, from: data)
        XCTAssertNil(decoded.confidence)
    }

    // MARK: - Legacy page-run identity preserved for v1/raw diagnostics

    func testSkillRunPageOnlyIdentityRemainsGroupedByLegacyPageKey() {
        let page = GitHubPageContext.pullRequest(repository: "owner/repo", number: 77)
        let run = SkillRun(
            id: "run_1",
            skillID: "dev.example.skill",
            page: page,
            requestedByClientID: "client",
            createdAt: Date(timeIntervalSince1970: 0),
            startedAt: nil,
            completedAt: nil,
            status: .queued,
            progressMessage: nil,
            progressCurrent: nil,
            progressTotal: nil,
            result: nil,
            error: nil,
            retryOfRunID: nil
        )
        XCTAssertEqual(run.subjectKey, "github:legacy-page:\(page.key)")
    }

    func testSkillRunDerivesPageFromPreciseSubject() throws {
        let revision = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40)
        )
        let run = SkillRun(
            id: "run_exact",
            skillID: "pr.review",
            page: .pullRequest(repository: "wrong/repo", number: 1),
            requestedByClientID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            startedAt: nil,
            completedAt: nil,
            status: .queued,
            progressMessage: nil,
            progressCurrent: nil,
            progressTotal: nil,
            result: nil,
            error: nil,
            retryOfRunID: nil,
            subject: .pullRequestRevision(revision)
        )

        XCTAssertEqual(
            run.page,
            .pullRequest(repository: revision.repository, number: revision.prNumber)
        )
    }

    // MARK: - Surface health compatibility (legacy v1 slot reporting must survive)

    func testSlotHealthReportRemainsCodableAndIdentifiableForV1Clients() throws {
        // PLAN §10 requires keeping SlotHealthReport/`/api/v1/slot-health` for v1
        // clients even after v2 lands; this guards it from being deleted outright.
        let report = SlotHealthReport(
            clientID: "client-1",
            pageKey: "github:owner/repo:pr:1",
            slot: .prHeaderActions,
            healthy: false,
            detail: "anchor missing",
            observedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(report.id, "client-1:github:owner/repo:pr:1:pr.header.actions")
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(SlotHealthReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    // MARK: - Browser Contract v2 validation and adaptation

    func testSkillPackageValidatorAcceptsAndAdaptsStrictBrowserContractV2() throws {
        let root = try makeTemporarySkillPackageRoot(
            browserContractYAML: """
            api_version: \(GHPRContract.browserVersionV2)
            target_kinds:
              - github.workflow_job
              - github.diff_line
            placements:
              - id: ci-insight
                surface: github.pr.checks.job.insight
                bind_to: result.analysis
                view:
                  type: ci_insight
              - id: inline-findings
                surface: github.pr.files.diff.line.after
                repeat:
                  source: result.findings
                bind_to: item.anchor
                view:
                  type: review_finding
            """
        )
        let validation = SkillPackageManager.validate(at: root)
        XCTAssertFalse(
            validation.issues.contains { $0.path.hasSuffix("browser.yaml") },
            "Expected a valid strict v2 contract; got: \(validation.issues.map(\.message))"
        )
        let package = try SkillPackageManager.load(at: root)
        let contract = try XCTUnwrap(SkillPackageManager.browserContractV2(for: package))
        XCTAssertEqual(contract.targetKinds, [.workflowJob, .diffLine])
        XCTAssertEqual(contract.placements.count, 2)
        XCTAssertEqual(contract.placements[0].surface, .checksJobInsight)
        XCTAssertEqual(contract.placements[1].repeatBinding?.source, "result.findings")
        XCTAssertEqual(contract.placements[1].bindTo, "item.anchor")
    }

    func testSkillPackageValidatorRejectsBrowserContractV2DOMAndUnsafeBindings() throws {
        let root = try makeTemporarySkillPackageRoot(
            browserContractYAML: """
            api_version: \(GHPRContract.browserVersionV2)
            selector: ".js-check-run"
            target_kinds:
              - github.workflow_job
            placements:
              - id: unsafe
                surface: github.pr.checks.job.insight
                bind_to: window.document.body
                view:
                  type: ci_insight
                  html: "<script>alert(1)</script>"
            """
        )
        let validation = SkillPackageManager.validate(at: root)
        let messages = validation.issues.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("unknown root field 'selector'") })
        XCTAssertTrue(messages.contains { $0.contains("unknown field 'view.html'") })
        XCTAssertTrue(messages.contains { $0.contains("dotted result.* binding") })
        let package = try SkillPackageManager.load(at: root)
        XCTAssertNil(SkillPackageManager.browserContractV2(for: package))
    }

    func testSkillPackageValidatorAcceptsBrowserContractV1APIVersion() throws {
        let root = try makeTemporarySkillPackageRoot(
            browserContractYAML: """
            api_version: \(GHPRContract.browserVersion)
            surfaces:
              - github.pr.mergebox.after
            contributions:
              - id: card
                slot: github.pr.mergebox.after
            """
        )
        let validation = SkillPackageManager.validate(at: root)
        XCTAssertFalse(
            validation.issues.contains { $0.message.contains("must use") && $0.path.hasSuffix("browser.yaml") },
            "A v1 browser contract must not be rejected for its api_version; got: \(validation.issues.map { $0.message })"
        )
    }

    @MainActor
    func testSkillRuntimeRejectsSubjectKindTheSkillDoesNotSupport() throws {
        let runtime = SkillRuntime(store: ExtensionPlatformStore(storageURL: nil))
        let revision = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40)
        )

        XCTAssertThrowsError(
            try runtime.start(
                skillID: "ci.failure.explain",
                page: .pullRequest(repository: "owner/repo", number: 42),
                pullRequest: nil,
                requestedByClientID: nil,
                subject: .pullRequestRevision(revision)
            )
        ) { error in
            guard case SkillRuntime.RuntimeError.subjectTargetMismatch = error else {
                return XCTFail("Expected subjectTargetMismatch, got \(error)")
            }
        }
    }

    // MARK: - Canonical resolver and review workspace

    func testGitHubSubjectResolverUsesCanonicalGitHubPayloads() async throws {
        let shaA = String(repeating: "a", count: 40)
        let shaB = String(repeating: "b", count: 40)
        let resolver = GitHubSubjectResolver(
            ghURL: URL(fileURLWithPath: "/usr/bin/gh"),
            runner: { _, arguments, _ in
                if arguments.first == "pr" {
                    return ExtensionCommandResult(
                        exitCode: 0,
                        stdout: #"{"baseRefOid":"\#(shaA)","headRefOid":"\#(shaB)"}"#,
                        stderr: ""
                    )
                }
                return ExtensionCommandResult(
                    exitCode: 0,
                    stdout: #"{"id":2001,"run_id":1001,"run_attempt":2,"head_sha":"\#(shaB)"}"#,
                    stderr: ""
                )
            }
        )

        let revision = try await resolver.resolvePullRequestRevision(
            repository: "Owner/Repo",
            prNumber: 42
        )
        XCTAssertEqual(revision.repository, "owner/repo")
        XCTAssertEqual(revision.baseSHA, shaA)
        XCTAssertEqual(revision.headSHA, shaB)

        let job = try await resolver.resolveWorkflowJob(
            repository: "Owner/Repo",
            workflowJobID: 2001
        )
        XCTAssertEqual(job.repository, "owner/repo")
        XCTAssertEqual(job.workflowRunID, 1001)
        XCTAssertEqual(job.workflowAttempt, 2)
        XCTAssertEqual(job.workflowJobID, 2001)
        XCTAssertEqual(job.headSHA, shaB)
    }

    func testReviewWorkspaceVerifiesHeadAndReturnsExactDiff() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghpr-review-workspace-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let shaA = String(repeating: "a", count: 40)
        let shaB = String(repeating: "b", count: 40)
        let subject = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: shaA,
            headSHA: shaB
        )
        let manager = PRReviewWorkspaceManager(
            rootURL: root,
            ghURL: URL(fileURLWithPath: "/usr/bin/gh"),
            gitURL: URL(fileURLWithPath: "/usr/bin/git"),
            runner: { _, arguments, _ in
                if arguments.contains("rev-parse") {
                    return ExtensionCommandResult(exitCode: 0, stdout: shaB, stderr: "")
                }
                if arguments.contains("merge-base") {
                    return ExtensionCommandResult(exitCode: 0, stdout: shaA, stderr: "")
                }
                if arguments.contains("--name-status") {
                    return ExtensionCommandResult(exitCode: 0, stdout: "M\ta.swift", stderr: "")
                }
                if arguments.contains("diff") {
                    return ExtensionCommandResult(
                        exitCode: 0,
                        stdout: "diff --git a/a.swift b/a.swift\n+let fixed = true",
                        stderr: ""
                    )
                }
                return ExtensionCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let workspace = try await manager.prepare(subject: subject)
        XCTAssertEqual(workspace.subject, subject)
        XCTAssertEqual(workspace.diff, "diff --git a/a.swift b/a.swift\n+let fixed = true")
        XCTAssertTrue(workspace.checkoutURL.path.hasPrefix(root.path))
        XCTAssertEqual(workspace.mergeBaseSHA, shaA)
        XCTAssertEqual(workspace.reviewedFiles, ["a.swift"])
        XCTAssertEqual(workspace.skippedFiles, [])
        XCTAssertNotNil(workspace.cleanupURL)
    }

    /// Builds a minimal-but-complete Skill package directory (manifest, SKILL.md,
    /// result schema, presentation contract, and the given browser contract) so
    /// `SkillPackage.validate(at:)` exercises real file/YAML parsing rather than a
    /// hand-built in-memory model.
    private func makeTemporarySkillPackageRoot(browserContractYAML: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghpr-skill-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        try """
        api_version: \(GHPRContract.skillVersion)
        id: dev.example.contract-v2-probe
        version: 1.0.0
        display_name: Contract V2 Probe
        targets:
          - pull_request
        execution:
          agents:
            - omp
          default_agent: omp
          isolation: strict
        result:
          schema: result.schema.json
        presentation:
          file: presentation.yaml
        browser:
          contributions: browser.yaml
        """.write(to: root.appendingPathComponent("ghpr.skill.yaml"), atomically: true, encoding: .utf8)

        try "# Contract V2 Probe".write(
            to: root.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: root.appendingPathComponent("result.schema.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        api_version: \(GHPRContract.presentationVersion)
        summary:
          - id: summary_1
            type: markdown
            value_path: result.markdown
        detail:
          - id: detail_1
            type: markdown
            value_path: result.markdown
        """.write(to: root.appendingPathComponent("presentation.yaml"), atomically: true, encoding: .utf8)

        try browserContractYAML.write(
            to: root.appendingPathComponent("browser.yaml"),
            atomically: true,
            encoding: .utf8
        )

        return root
    }

    // MARK: - Legacy slot health presentation

    @MainActor
    func testLegacySlotHealthIsHiddenWhileGitHubNativeSurfacesAreEnabled() {
        let store = ExtensionPlatformStore(storageURL: nil)
        store.githubSurfaceV2Enabled = true
        store.reportSlotHealth(
            clientID: "client-1",
            pageKey: "github:pr:owner/repo#42",
            slot: .prHeaderActions,
            healthy: false,
            detail: "Semantic anchor was not found."
        )

        XCTAssertTrue(
            store.unhealthySlots.isEmpty,
            "Stale v1 placement reports must not be surfaced while v2 anchors are the mounted ones"
        )
    }

    @MainActor
    func testLegacySlotHealthKeepsOnlyNewestReportPerSlot() {
        let store = ExtensionPlatformStore(storageURL: nil)
        store.githubSurfaceV2Enabled = false
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(60)
        for (index, page) in ["pull/42", "pull/42/files", "pull/42/checks"].enumerated() {
            store.reportSlotHealth(
                clientID: "client-1",
                pageKey: "github:\(page)",
                slot: .prHeaderActions,
                healthy: false,
                detail: "missing \(index)",
                now: index == 2 ? newer : older
            )
        }
        store.reportSlotHealth(
            clientID: "client-1",
            pageKey: "github:pull/42/files",
            slot: .filesToolbarActions,
            healthy: false,
            detail: "missing files toolbar",
            now: older
        )

        let reports = store.unhealthySlots
        XCTAssertEqual(
            reports.map(\.slot),
            [.prHeaderActions, .filesToolbarActions],
            "Each missing slot must be listed once, newest first, not once per visited page"
        )
        XCTAssertEqual(
            reports.first?.detail,
            "missing 2",
            "The retained report for a slot must be the most recent observation"
        )
    }

    @MainActor
    func testPlacementCountRollsUpUnhealthyGitHubNativeSurfaces() {
        let controller = ExtensionPlatformController(
            snapshotProvider: {
                LocalSnapshotFactory.makeSnapshot(
                    input: LocalSnapshotInput(
                        appVersion: "1.0.0",
                        buildVersion: "1",
                        bundleIdentifier: "com.example.tests",
                        authState: .empty,
                        prList: .empty,
                        rateLimitInfo: .empty,
                        pinnedPRIdentifiers: [],
                        minimumApprovalsForReadyToMerge: 1,
                        refreshStatus: "idle",
                        refreshError: nil
                    )
                )
            },
            storageURL: nil,
            appVersion: "1.0.0"
        )
        controller.githubSurfaceV2Enabled = true
        XCTAssertEqual(controller.unhealthyPlacementCount, 0, "A clean store must read as healthy")

        controller.store.reportSurfaceHealth(
            surface: BrowserSurfaceV2.conversationReviewSummary.rawValue,
            state: SurfaceHealthState.missing,
            detail: "No Conversation timeline anchor was found."
        )

        XCTAssertEqual(
            controller.unhealthyPlacementCount,
            1,
            "A missing GitHub-native surface must count as a placement needing attention, not read as Ready"
        )
    }
}
