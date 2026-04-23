import XCTest
@testable import PRDashboard

final class FlakyCIProtocolV2Tests: XCTestCase {
    func testDecodesCompleteMarker() throws {
        let marker = makeMarker(classification: "likely_flaky", status: "completed", headSHA: "abc123")

        let result = try FlakyCIProtocolV2.decodeMarker(from: marker, currentHeadSHA: "abc123")

        XCTAssertEqual(result?.schemaVersion, 2)
        XCTAssertEqual(result?.protocolName, "ghpr_flaky_ci_analysis")
        XCTAssertEqual(result?.classification, .likelyFlaky)
        XCTAssertEqual(result?.failedJobs.first?.failureSignature, "Error: timeout")
        XCTAssertEqual(result?.failedJobs.first?.history.mainMatches, 2)
        XCTAssertEqual(result?.suggestedActions.first?.id, .rerunFailedJobs)
        XCTAssertEqual(result?.reportState(currentHeadSHA: "abc123"), .likelyFlaky(score: 92))
    }

    func testDecodesMissingOptionalLinks() throws {
        let marker = makeMarker(includeLinks: false)

        let result = try FlakyCIProtocolV2.decodeMarker(from: marker)

        XCTAssertNil(result?.links)
        XCTAssertEqual(result?.target.workflowName, "CI")
    }

    func testRejectsWrongProtocolMarker() throws {
        let marker = makeMarker(protocolName: "wrong_protocol")

        let result = try FlakyCIProtocolV2.decodeMarker(from: marker)

        XCTAssertNil(result)
    }

    func testMarksResultStaleWhenHeadShaDiffers() throws {
        let marker = makeMarker(headSHA: "abc123")

        let result = try FlakyCIProtocolV2.decodeMarker(from: marker, currentHeadSHA: "def456")

        XCTAssertEqual(result?.status, .stale)
        XCTAssertEqual(result?.reportState(currentHeadSHA: "def456"), .outdated)
    }

    func testMapsClassificationAndStatusToUIState() throws {
        let blocker = try XCTUnwrap(FlakyCIProtocolV2.decodeMarker(from: makeMarker(classification: "likely_blocker", flakyScore: 21)))
        let investigate = try XCTUnwrap(FlakyCIProtocolV2.decodeMarker(from: makeMarker(classification: "investigate", flakyScore: 50)))
        let running = try XCTUnwrap(FlakyCIProtocolV2.decodeMarker(from: makeMarker(status: "in_progress")))

        XCTAssertEqual(blocker.reportState(currentHeadSHA: "abc123"), .realIssue(score: 79))
        XCTAssertEqual(investigate.reportState(currentHeadSHA: "abc123"), .needsInvestigation(score: 50))
        XCTAssertEqual(running.reportState(currentHeadSHA: "abc123"), .analyzing)
    }

    func testDetectsFlakyCheckRunIdentity() {
        XCTAssertTrue(FlakyCIProtocolV2.isFlakyCheckRun(name: "Flaky CI Analysis (run 123)", externalID: nil))
        XCTAssertTrue(FlakyCIProtocolV2.isFlakyCheckRun(name: "other", externalID: "ghpr-flaky-ci:v2:owner/repo#1:abc:2:req"))
        XCTAssertFalse(FlakyCIProtocolV2.isFlakyCheckRun(name: "Unit Tests", externalID: nil))
    }

    private func makeMarker(
        protocolName: String = "ghpr_flaky_ci_analysis",
        classification: String = "likely_flaky",
        status: String = "completed",
        flakyScore: Int = 92,
        headSHA: String = "abc123",
        includeLinks: Bool = true
    ) -> String {
        var payload: [String: Any] = [
            "schema_version": 2,
            "protocol": protocolName,
            "analysis_id": "ghpr-flaky-ci:v2:owner/repo#1:\(headSHA):987:req-1",
            "request_id": "req-1",
            "backend": ["kind": "workflow_dispatch", "version": "0.2.0"],
            "status": status,
            "classification": classification,
            "flaky_score": flakyScore,
            "relatedness_score": 0.12,
            "confidence": "high",
            "history_influenced": true,
            "target": [
                "ci_provider": "github_actions",
                "run_id": 987,
                "workflow_name": "CI",
                "head_sha": headSHA
            ],
            "failed_jobs": [[
                "job_id": 111,
                "job_name": "macos / test",
                "conclusion": "failure",
                "failure_signature": "Error: timeout",
                "history": [
                    "main_matches": 2,
                    "main_sampled": 3,
                    "pr_matches": 1,
                    "pr_sampled": 3,
                    "sample_run_urls": ["https://github.com/owner/repo/actions/runs/1"]
                ]
            ]],
            "summary": [
                "title": "Likely flaky",
                "evidence_line": "Same signature is active on main",
                "detail": "The signature has recent history."
            ],
            "evidence": [[
                "kind": "history",
                "message": "Signature matched in 2/3 sampled main failures",
                "url": "https://github.com/owner/repo/actions/runs/1"
            ]],
            "suggested_actions": [[
                "id": "rerun_failed_jobs",
                "label": "Rerun failed jobs",
                "enabled": true
            ]],
            "timestamps": [
                "created_at": "2026-04-23T10:00:00.000Z",
                "completed_at": "2026-04-23T10:01:00.000Z"
            ]
        ]
        if includeLinks {
            payload["links"] = [
                "workflow_run_url": "https://github.com/owner/repo/actions/runs/987"
            ]
        }

        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "<!-- ghpr-flaky-ci-result:v2:\(encoded) -->\n\n## Flaky CI Analysis"
    }
}
