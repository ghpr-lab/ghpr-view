import Combine
import Foundation
import XCTest
@testable import PRDashboard

@MainActor
final class BrowserBridgeTests: XCTestCase {
    private struct ActionEnvelope: Encodable {
        let page: GitHubPageContext
        let action: BrowserAction
        let confirmed: Bool?
    }

    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testTagPermissionDescriptionsAreExplicitlyLocal() {
        XCTAssertEqual(
            BrowserScope.tagRead.displayName,
            "Read locally stored ghpr tags"
        )
        XCTAssertEqual(
            BrowserScope.tagWrite.displayName,
            "Change locally stored ghpr tags (not GitHub labels)"
        )
    }

    func testLegacyDescriptorDecodingDefaultsRequiredScopes() throws {
        let data = Data(#"{"id":"legacy.client","name":"Legacy","version":"1.0.0","requested_scopes":["pr:read"]}"#.utf8)
        let descriptor = try BrowserJSON.decode(BrowserClientDescriptor.self, from: data)
        XCTAssertEqual(descriptor.requiredScopes, [])
    }

    func testPairingRejectsRequiredScopeOutsideRequestedScopes() {
        let store = ExtensionPlatformStore(storageURL: nil)
        let descriptor = BrowserClientDescriptor(
            id: "required.client",
            name: "Required",
            version: "1.0.0",
            requestedScopes: [.prRead],
            requiredScopes: [.skillRun]
        )
        XCTAssertThrowsError(
            try store.startPairing(
                descriptor: descriptor,
                bridgeBaseURL: URL(string: "http://127.0.0.1:48120")!
            )
        ) { error in
            XCTAssertEqual(error as? ExtensionPlatformStore.StoreError, .invalidScopes)
        }
    }

    func testLocalGrantsAreResourceSpecificAndExposeSanitizedContext() throws {
        let store = ExtensionPlatformStore(storageURL: nil)
        let analysis = CIAnalysis(
            id: "analysis_resource",
            pageKey: "github:owner/repo:pr:42",
            repository: "owner/repo",
            prNumber: 42,
            jobName: nil,
            verdict: .likelyFlaky,
            confidence: .high,
            confidenceScore: 0.9,
            summary: "summary",
            historyMatches: [],
            historyChecked: 0,
            relatednessScore: nil,
            relatednessSummary: nil,
            reproduction: "not rerun",
            failureSignature: nil,
            changedFiles: [],
            suggestedAction: "rerun",
            agent: .codex,
            strictContext: true,
            durationSeconds: 1,
            createdAt: Date()
        )
        store.save(analysis: analysis)
        let token = try store.issueDetailGrant(analysisID: analysis.id)
        XCTAssertTrue(store.validateLocalGrant(token: token, kind: .analysis, resourceID: analysis.id))
        XCTAssertFalse(store.validateLocalGrant(token: token, kind: .analysis, resourceID: "other"))
        XCTAssertFalse(store.validateLocalGrant(token: token, kind: .run, resourceID: analysis.id))
        XCTAssertEqual(store.localCapability(token: token)?.kind, .analysis)
        XCTAssertEqual(store.localCapability(token: token)?.resourceID, analysis.id)
        let encoded = try BrowserJSON.encode(store.localCapability(token: token)!)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("token"))
    }

    func testRouterCapabilityAndPairingStatusBoundaries() async throws {
        let store = ExtensionPlatformStore(storageURL: nil)
        let root = temporaryDirectory()
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil
        )
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: []),
            appVersion: "1.0.0",
            draftsRootURL: root.appendingPathComponent("drafts")
        )
        let baseURL = URL(string: "http://127.0.0.1:48120")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let descriptor = BrowserClientDescriptor(
            id: "status.client",
            name: "Status Client",
            version: "1.0.0",
            requestedScopes: [.prRead],
            requiredScopes: []
        )
        let start = try store.startPairing(descriptor: descriptor, bridgeBaseURL: baseURL, now: now)
        let pending = try store.pairingStatus(id: start.requestID, secret: start.pairingSecret, now: now)
        XCTAssertEqual(pending.state, .pending)
        let pendingJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BrowserJSON.encode(pending)) as? [String: Any]
        )
        XCTAssertNil(pendingJSON["token"])
        _ = try store.approvePairing(
            id: start.requestID,
            secret: start.pairingSecret,
            approvedScopes: [.prRead],
            now: now
        )
        let poll = try store.pollPairing(id: start.requestID, secret: start.pairingSecret, now: now)
        XCTAssertEqual(poll.state, .approved)
        let afterPoll = try store.pairingStatus(id: start.requestID, secret: start.pairingSecret, now: now)
        XCTAssertEqual(afterPoll.state, .approved)
        let afterPollJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BrowserJSON.encode(afterPoll)) as? [String: Any]
        )
        XCTAssertNil(afterPollJSON["token"])

        let expiredStart = try store.startPairing(descriptor: descriptor, bridgeBaseURL: baseURL, now: now)
        let expired = try store.pairingStatus(
            id: expiredStart.requestID,
            secret: expiredStart.pairingSecret,
            now: now.addingTimeInterval(11 * 60)
        )
        XCTAssertEqual(expired.state, .expired)

        let capabilityToken = store.issueWorkbenchGrant(now: now)
        let capability = await router.response(
            for: BrowserHTTPRequest(
                method: "GET",
                target: "/api/v1/local-capability",
                headers: ["Authorization": "Bearer \(capabilityToken)"]
            ),
            baseURL: baseURL
        )
        XCTAssertEqual(capability.status, 200)
        let capabilityContext = try BrowserJSON.decode(LocalCapabilityContext.self, from: capability.body)
        XCTAssertEqual(capabilityContext.kind, .workbench)
        XCTAssertThrowsError(
            try store.pairingStatus(
                id: expiredStart.requestID,
                secret: expiredStart.pairingSecret,
                now: now.addingTimeInterval(16 * 60)
            )
        )
        let shell = await router.response(
            for: BrowserHTTPRequest(method: "GET", target: "/ui/workbench"),
            baseURL: baseURL
        )
        XCTAssertEqual(shell.status, 200)
        let protected = await router.response(
            for: BrowserHTTPRequest(method: "GET", target: "/api/v1/workbench/skills"),
            baseURL: baseURL
        )
        XCTAssertEqual(protected.status, 401)
    }

    func testExplainFailureUsesReviewCodingAgentChoices() throws {
        let root = temporaryDirectory()
        let runtime = SkillRuntime(
            store: ExtensionPlatformStore(storageURL: nil),
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil
        )
        let explain = try XCTUnwrap(
            runtime.skills.first { $0.id == SkillRuntime.explainFailureSkillID }
        )
        let review = try XCTUnwrap(
            runtime.skills.first { $0.id == SkillRuntime.reviewPRSkillID }
        )

        XCTAssertEqual(explain.agents, review.agents)
        XCTAssertTrue(explain.agents.contains(.codex))
    }

    func testSkillRunPersistsQueuedRunningAndFailureLogEntries() async throws {
        let root = temporaryDirectory()
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil
        )
        let queued = try runtime.start(
            skillID: SkillRuntime.explainFailureSkillID,
            page: .pullRequest(repository: "owner/repo", number: 42),
            pullRequest: nil,
            requestedByClientID: "dev.ghpr.official-test"
        )
        XCTAssertEqual(queued.logEntries?.map(\.kind), [.queued])
        XCTAssertEqual(queued.logEntries?.map(\.message), ["Queued"])

        var terminal: SkillRun?
        for _ in 0..<100 {
            if let run = store.run(id: queued.id), run.status.isTerminal {
                terminal = run
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let failed = try XCTUnwrap(terminal)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(
            failed.logEntries?.map(\.kind),
            [.queued, .running, .error]
        )
        XCTAssertEqual(
            failed.logEntries?.dropFirst().first?.message,
            "Preparing strict context"
        )
        XCTAssertEqual(
            failed.logEntries?.last?.message,
            "The PR is not available in the current ghpr snapshot."
        )
        XCTAssertEqual(failed.error, "The PR is not available in the current ghpr snapshot.")
    }

    func testSkillRunLogContractUsesFixedBoundedDeduplicatedEvents() throws {
        XCTAssertEqual(
            SkillRuntime.ProgressEvent.allCases.map(\.logEvent.message),
            [
                "Starting Skill runtime",
                "Executing Skill",
                "Receiving Agent output",
                "Finalizing result"
            ]
        )
        XCTAssertTrue(
            SkillRuntime.LogEvent.allCases.allSatisfy {
                $0.message.count <= SkillRuntime.maximumLogMessageLength &&
                    !$0.message.contains("\n") &&
                    !$0.message.contains("\r")
            }
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var run = SkillRun(
            id: "run_bounded_log",
            skillID: "dev.example.safe-progress",
            page: .pullRequest(repository: "owner/repo", number: 42),
            requestedByClientID: "dev.ghpr.official-test",
            createdAt: now,
            startedAt: now,
            completedAt: nil,
            status: .running,
            progressMessage: "Executing Skill",
            progressCurrent: 2,
            progressTotal: 3,
            logEntries: [],
            result: nil,
            error: nil,
            retryOfRunID: nil
        )
        for index in 0..<(SkillRuntime.maximumLogEntries + 50) {
            SkillRuntime.recordLogEvent(
                index.isMultiple(of: 2) ? .executing : .finalizing,
                at: now.addingTimeInterval(Double(index)),
                to: &run
            )
        }
        XCTAssertEqual(run.logEntries?.count, SkillRuntime.maximumLogEntries)

        let countBeforeDuplicate = run.logEntries?.count
        SkillRuntime.recordLogEvent(.finalizing, at: now, to: &run)
        XCTAssertEqual(run.logEntries?.count, countBeforeDuplicate)

        let store = ExtensionPlatformStore(storageURL: nil)
        store.save(run: run)
        XCTAssertEqual(
            store.run(id: run.id)?.logEntries?.count,
            SkillRuntime.maximumLogEntries
        )
    }

    func testAgentOutputPreviewExtractsTextAndRedactsSecrets() {
        let data = Data(
            """
            {"type":"item.completed","item":{"type":"agent_message","text":"Inspecting cache writes"}}
            {"type":"result","result":"Finding at /Users/example/private token=secret"}
            """.utf8
        )

        XCTAssertEqual(
            AgentCLIAdapter.outputPreviewLines(from: data),
            [
                "Inspecting cache writes",
                "Output: Finding at [local path] token=[redacted]"
            ]
        )
    }

    func testAgentOutputStreamDecoderBuffersSplitUTF8AndOMPStructuredOutput() async throws {
        let decoder = AgentOutputStreamDecoder(maximumPendingBytes: 4_096)
        let event = Data(
            """
            {"type":"item.completed","item":{"type":"agent_message","text":"Inspecting 缓存 writes"}}

            """.utf8
        )
        let marker = try XCTUnwrap(event.range(of: Data("缓存".utf8)))
        let splitIndex = marker.lowerBound + 1

        let firstChunk = await decoder.append(Data(event[..<splitIndex]))
        XCTAssertTrue(firstChunk.isEmpty)
        let secondChunk = await decoder.append(Data(event[splitIndex...]))
        XCTAssertEqual(secondChunk, ["Inspecting 缓存 writes"])

        let ompResult = Data(
            """
            {"type":"result","structured_output":{"status":"needs_investigation","summary":"Agent examined strict context.","findings":[{"file":"src/cache.ts","line":42,"title":"Lost update"}]}}
            """.utf8
        )
        let bufferedResult = await decoder.append(ompResult)
        XCTAssertTrue(bufferedResult.isEmpty)
        let completedResult = await decoder.finish()
        XCTAssertEqual(
            completedResult,
            [
                "Status: needs_investigation",
                "Summary: Agent examined strict context.",
                "Findings: 1",
                "src/cache.ts:42 · Lost update"
            ]
        )
    }

    func testBrowserSafeLogLineRedactsBearerGitHubAndAWSCredentials() {
        let source = """
        Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature \
        ghp_abcdefghijklmnopqrstuvwxyz123456 \
        github_pat_abcdefghijklmnopqrstuvwxyz123456 \
        AKIA1234567890ABCDEF
        """
        let safe = SkillRuntime.browserSafeLogLine(source)

        XCTAssertTrue(safe.contains("Authorization: [redacted]"))
        XCTAssertTrue(safe.contains("[redacted github token]"))
        XCTAssertTrue(safe.contains("[redacted aws key]"))
        XCTAssertFalse(safe.contains("signature"))
        XCTAssertFalse(safe.contains("ghp_"))
        XCTAssertFalse(safe.contains("github_pat_"))
        XCTAssertFalse(safe.contains("AKIA"))
    }

    func testRealLoopbackDiscoveryEndpoint() async throws {
        let root = temporaryDirectory()
        let browserRoot = root.appendingPathComponent("browser", isDirectory: true)
        try FileManager.default.createDirectory(
            at: browserRoot,
            withIntermediateDirectories: true
        )
        try """
        // ==UserScript==
        // @name ghpr for GitHub
        // @version 7.6.5
        // ==/UserScript==
        """.write(
            to: browserRoot.appendingPathComponent("ghpr.user.js"),
            atomically: true,
            encoding: .utf8
        )
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil
        )
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: [root]),
            appVersion: "9.8.7",
            draftsRootURL: root.appendingPathComponent("drafts")
        )
        let server = BrowserBridgeServer(router: router, ports: [0])
        let ready = expectation(description: "Browser Bridge is listening")
        var cancellable: AnyCancellable?
        cancellable = server.$status.sink { status in
            if case .running = status.state {
                ready.fulfill()
            }
        }

        server.start()
        await fulfillment(of: [ready], timeout: 5)
        let baseURL = try XCTUnwrap(server.baseURL)
        let discoveryURL = baseURL.appendingPathComponent(
            ".well-known/ghpr-browser-bridge"
        )

        let (data, response) = try await URLSession.shared.data(from: discoveryURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200, "Discovery must answer on the loopback socket")
        let discovery = try BrowserJSON.decode(BrowserBridgeDiscovery.self, from: data)
        XCTAssertEqual(discovery.protocolName, GHPRContract.bridgeProtocol)
        XCTAssertEqual(discovery.appVersion, "9.8.7")
        XCTAssertEqual(
            discovery.officialUserscriptVersion,
            "7.6.5",
            "Discovery must report the installable userscript version exposed by this server."
        )
        XCTAssertEqual(baseURL.host, "127.0.0.1", "Bridge must never advertise a non-loopback host")

        server.stop()
        cancellable?.cancel()
    }

    func testUIOverviewAndApplicationIconUseTheSharedAppIdentity() async throws {
        let root = temporaryDirectory()
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil
        )
        let iconPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: []),
            appVersion: "1.5.0",
            draftsRootURL: root.appendingPathComponent("drafts"),
            applicationIconProvider: { iconPNG }
        )
        let baseURL = URL(string: "http://127.0.0.1:48120")!

        let overview = await router.response(
            for: BrowserHTTPRequest(method: "GET", target: "/ui"),
            baseURL: baseURL
        )
        XCTAssertEqual(overview.status, 200)
        XCTAssertEqual(overview.headers["Content-Type"], "text/html; charset=utf-8")
        let html = try XCTUnwrap(String(data: overview.body, encoding: .utf8))
        XCTAssertTrue(html.contains(#"data-ghpr-page="home""#))
        XCTAssertTrue(html.contains(#"src="/assets/app-icon.png""#))

        let icon = await router.response(
            for: BrowserHTTPRequest(method: "GET", target: "/assets/app-icon.png"),
            baseURL: baseURL
        )
        XCTAssertEqual(icon.status, 200)
        XCTAssertEqual(icon.headers["Content-Type"], "image/png")
        XCTAssertEqual(
            icon.body,
            iconPNG,
            "The Browser Bridge must serve the macOS app identity supplied by the app."
        )
    }

    func testPairingTokenIsOnlyReturnedAfterNativeApproval() async throws {
        let root = temporaryDirectory()
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil
        )
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: []),
            appVersion: "1.0",
            draftsRootURL: root.appendingPathComponent("drafts")
        )
        let baseURL = URL(string: "http://127.0.0.1:48120")!
        let descriptor = BrowserClientDescriptor(
            id: "com.example.tests",
            name: "Test Client",
            version: "1.2.3",
            requestedScopes: [.prRead, .analysisRead, .skillRun]
        )
        let startRequest = BrowserHTTPRequest(
            method: "POST",
            target: "/api/v1/pairings",
            headers: ["Content-Type": "application/json"],
            body: try BrowserJSON.encode(descriptor)
        )
        let startResponse = await router.response(for: startRequest, baseURL: baseURL)
        XCTAssertEqual(startResponse.status, 201)
        let started = try decodeValue(PairingStartResponse.self, from: startResponse.body)

        let pendingResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "GET",
                target: "/api/v1/pairings/\(started.requestID)?secret=\(started.pairingSecret)"
            ),
            baseURL: baseURL
        )
        let pending = try decodeValue(PairingPollResponse.self, from: pendingResponse.body)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertNil(pending.token, "Pending browser requests must not mint their own token")

        let approval = try XCTUnwrap(store.pendingApprovals.first)
        let approvedClient = try store.approvePairingFromNative(
            id: approval.id,
            approvedScopes: [.prRead, .analysisRead]
        )
        XCTAssertEqual(approvedClient.scopes, [.prRead, .analysisRead])

        let approvedResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "GET",
                target: "/api/v1/pairings/\(started.requestID)?secret=\(started.pairingSecret)"
            ),
            baseURL: baseURL
        )
        let approved = try decodeValue(PairingPollResponse.self, from: approvedResponse.body)
        XCTAssertEqual(approved.state, .approved)
        XCTAssertNotNil(approved.token)
        XCTAssertFalse(
            approved.client?.scopes.contains(.skillRun) ?? true,
            "Native approval must be able to withhold an elevated scope"
        )
        let subject = GitHubSubject.pullRequestRevision(
            try PullRequestRevisionSubject(
                repository: "owner/repo",
                prNumber: 42,
                baseSHA: String(repeating: "a", count: 40),
                headSHA: String(repeating: "b", count: 40)
            )
        )
        let finding = SkillFinding(
            id: "finding-envelope",
            subjectKey: subject.subjectKey,
            subject: subject,
            kind: .reviewFinding,
            severity: .warning,
            title: "Test finding",
            summary: "Envelope test",
            details: nil,
            confidence: 0.9,
            lifecycle: .exact,
            createdAt: Date(),
            fingerprint: "fingerprint-envelope"
        )
        store.save(finding: finding)
        let encodedSubjectKey = try XCTUnwrap(
            finding.subjectKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let findingsResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "GET",
                target: "/api/v1/findings?subject_key=\(encodedSubjectKey)",
                headers: ["Authorization": "Bearer \(try XCTUnwrap(approved.token))"]
            ),
            baseURL: baseURL
        )
        XCTAssertEqual(findingsResponse.status, 200)
        struct FindingsEnvelope: Codable, Equatable {
            let findings: [SkillFinding]
        }
        let envelope = try decodeValue(FindingsEnvelope.self, from: findingsResponse.body)
        XCTAssertEqual(envelope.findings.count, 1)
        XCTAssertEqual(envelope.findings.first?.id, finding.id)
        XCTAssertEqual(envelope.findings.first?.subjectKey, finding.subjectKey)
        let legacySubject = GitHubSubject.legacyPage(
            .pullRequest(repository: "owner/repo", number: 42)
        )
        let encodedLegacySubjectKey = try XCTUnwrap(
            legacySubject.subjectKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let legacyFindingsResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "GET",
                target: "/api/v1/findings?subject_key=\(encodedLegacySubjectKey)",
                headers: ["Authorization": "Bearer \(try XCTUnwrap(approved.token))"]
            ),
            baseURL: baseURL
        )
        XCTAssertEqual(legacyFindingsResponse.status, 400)

        let readOnlyToken = try XCTUnwrap(approved.token)
        let deniedResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "POST",
                target: "/api/v1/actions",
                headers: [
                    "Authorization": "Bearer \(readOnlyToken)",
                    "Content-Type": "application/json"
                ],
                body: try BrowserJSON.encode(
                    ActionEnvelope(
                        page: .pullRequest(repository: "owner/repo", number: 42),
                        action: BrowserAction(
                            kind: .runSkill,
                            skillID: "ci.failure.classify_flaky",
                            runID: nil,
                            analysisID: nil,
                            tag: nil,
                            event: nil
                        ),
                        confirmed: nil
                    )
                )
            ),
            baseURL: baseURL
        )
        XCTAssertEqual(
            deniedResponse.status,
            403,
            "A client without skill:run must not execute a privileged action"
        )

        store.revokeClient(id: approvedClient.id)
        let revokedResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "GET",
                target: "/api/v1/client",
                headers: ["Authorization": "Bearer \(readOnlyToken)"]
            ),
            baseURL: baseURL
        )
        XCTAssertEqual(
            revokedResponse.status,
            401,
            "Revoking a paired client must immediately invalidate its capability"
        )
    }

    func testCustomPullRequestSkillRunsThroughRouterWithExactRevisionSubject() async throws {
        let root = temporaryDirectory()
        let installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        let draft = try SkillPackageManager.scaffold(
            at: root.appendingPathComponent("source", isDirectory: true),
            id: "team.release-risk",
            displayName: "Release Risk"
        )
        _ = try SkillPackageManager.install(packageURL: draft, skillsRootURL: installedRoot)

        let store = ExtensionPlatformStore(storageURL: nil)
        let recorder = RequestRecorder()
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: installedRoot,
            bundledSkillsRootURL: nil,
            agentRunner: { request, _ in
                await recorder.record(request)
                return SkillResult(
                    kind: .generic,
                    title: "Release Risk",
                    summary: "No release risk found.",
                    analysis: nil,
                    codeReview: nil,
                    markdown: nil,
                    artifacts: [],
                    payload: .object(["status": .string("completed")])
                )
            }
        )
        let customSkill = try XCTUnwrap(runtime.skills.first { $0.id == "team.release-risk" })
        XCTAssertTrue(customSkill.targets.contains(.pullRequest))
        XCTAssertFalse(customSkill.targets.contains(.pullRequestRevision))

        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: []),
            appVersion: "1.0",
            draftsRootURL: root.appendingPathComponent("drafts")
        )
        let token = try approveClient(
            store: store,
            id: "dev.ghpr.custom-skill-test",
            scopes: [.skillRun]
        )
        let page = GitHubPageContext.pullRequest(repository: "owner/repo", number: 42)
        let revision = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "a", count: 40),
            headSHA: String(repeating: "b", count: 40)
        )
        let baseURL = URL(string: "http://127.0.0.1:48120")!
        let response = await router.response(
            for: BrowserHTTPRequest(
                method: "POST",
                target: "/api/v1/actions",
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json"
                ],
                body: try BrowserJSON.encode(
                    ActionEnvelope(
                        page: page,
                        action: BrowserAction(
                            kind: .runSkill,
                            skillID: customSkill.id,
                            runID: nil,
                            analysisID: nil,
                            tag: nil,
                            event: nil,
                            subject: .pullRequestRevision(revision)
                        ),
                        confirmed: false
                    )
                )
            ),
            baseURL: baseURL
        )

        XCTAssertEqual(response.status, 200)
        let run = try XCTUnwrap(store.allRuns.first { $0.skillID == customSkill.id })
        XCTAssertEqual(run.subject, .pullRequestRevision(revision))
        XCTAssertEqual(run.subjectKey, GitHubSubject.pullRequestRevision(revision).subjectKey)
        _ = try await terminalRun(store: store, id: run.id)
        let recordedRequest = await recorder.request
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.context.target.type, "pull_request_revision")
        XCTAssertEqual(request.context.target.baseSHA, revision.baseSHA)
        XCTAssertEqual(request.context.target.headSHA, revision.headSHA)
        XCTAssertEqual(
            request.context.target.subjectKey,
            GitHubSubject.pullRequestRevision(revision).subjectKey
        )

        let mismatchedResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "POST",
                target: "/api/v1/actions",
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json"
                ],
                body: try BrowserJSON.encode(
                    ActionEnvelope(
                        page: page,
                        action: BrowserAction(
                            kind: .runSkill,
                            skillID: SkillRuntime.classifyFlakySkillID,
                            runID: nil,
                            analysisID: nil,
                            tag: nil,
                            event: nil,
                            subject: .pullRequestRevision(revision)
                        ),
                        confirmed: false
                    )
                )
            ),
            baseURL: baseURL
        )
        XCTAssertEqual(
            mismatchedResponse.status,
            400,
            "Exact revision compatibility must not allow workflow-only Skills."
        )
    }

    func testGitHubOriginIsRejectedForPrivilegedAPI() async throws {
        let root = temporaryDirectory()
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root,
            bundledSkillsRootURL: nil
        )
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: []),
            appVersion: "1.0",
            draftsRootURL: root
        )
        let response = await router.response(
            for: BrowserHTTPRequest(
                method: "GET",
                target: "/api/v1/contracts/capabilities",
                headers: ["Origin": "https://github.com"]
            ),
            baseURL: URL(string: "http://127.0.0.1:48120")!
        )

        XCTAssertEqual(
            response.status,
            403,
            "Page-context JavaScript must not read Browser Bridge APIs through CORS"
        )
        XCTAssertNil(response.headers["Access-Control-Allow-Origin"])
    }


    func testWorkbenchCapabilityDrivesScaffoldFixtureTestAndPreview() async throws {
        let root = temporaryDirectory()
        let nativeSkillURL = root
            .appendingPathComponent(".claude/skills/native-helper", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nativeSkillURL,
            withIntermediateDirectories: true
        )
        let nativeInstructions = Data(
            "# Native Helper\n\nReturn the same free-form result used by Claude Code.".utf8
        )
        try nativeInstructions.write(
            to: nativeSkillURL.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil
        )
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: []),
            appVersion: "1.0",
            draftsRootURL: root.appendingPathComponent("drafts"),
            agentSkillsHomeURL: root
        )
        let baseURL = URL(string: "http://127.0.0.1:48120")!
        let grant = store.issueWorkbenchGrant()

        func perform(_ payload: [String: Any]) async throws -> BrowserHTTPResponse {
            await router.response(
                for: BrowserHTTPRequest(
                    method: "POST",
                    target: "/api/v1/workbench",
                    headers: [
                        "Authorization": "Bearer \(grant)",
                        "Content-Type": "application/json"
                    ],
                    body: try JSONSerialization.data(withJSONObject: payload)
                ),
                baseURL: baseURL
            )
        }

        let discoveryResponse = try await perform(["operation": "discover_skills"])
        XCTAssertEqual(discoveryResponse.status, 200)
        let discovery = try XCTUnwrap(
            JSONSerialization.jsonObject(with: discoveryResponse.body) as? [String: Any]
        )
        let discoveredSkills = try XCTUnwrap(discovery["skills"] as? [[String: Any]])
        XCTAssertEqual(discoveredSkills.count, 1)
        XCTAssertEqual(discoveredSkills[0]["path"] as? String, nativeSkillURL.path)
        XCTAssertEqual(discoveredSkills[0]["agents"] as? [String], ["claude_code"])
        XCTAssertEqual(discoveredSkills[0]["is_ghpr_package"] as? Bool, false)

        let scaffoldResponse = try await perform([
            "operation": "scaffold",
            "id": "dev.example.workbench",
            "display_name": "Workbench Skill"
        ])
        XCTAssertEqual(scaffoldResponse.status, 200)
        let scaffold = try XCTUnwrap(
            JSONSerialization.jsonObject(with: scaffoldResponse.body) as? [String: Any]
        )
        let packagePath = try XCTUnwrap(scaffold["path"] as? String)
        XCTAssertTrue(
            packagePath.hasPrefix(root.appendingPathComponent("drafts").path),
            "Workbench drafts must stay inside the app-controlled root."
        )

        let testResponse = try await perform([
            "operation": "test",
            "package_path": packagePath
        ])
        XCTAssertEqual(
            testResponse.status,
            200,
            "A generated fixture should pass its declared schema."
        )
        let tested = try XCTUnwrap(
            JSONSerialization.jsonObject(with: testResponse.body) as? [String: Any]
        )
        XCTAssertEqual(
            (tested["validation"] as? [String: Any])?["valid"] as? Bool,
            true
        )

        let previewResponse = try await perform([
            "operation": "preview",
            "package_path": packagePath
        ])
        XCTAssertEqual(previewResponse.status, 200)
        let previewed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: previewResponse.body) as? [String: Any]
        )
        let preview = try XCTUnwrap(previewed["preview"] as? [String: Any])
        XCTAssertEqual(preview["id"] as? String, "dev.example.workbench")
        XCTAssertTrue(
            (preview["presentation"] as? String)?.contains(
                GHPRContract.presentationVersion
            ) == true,
            "Preview should return the versioned presentation source rendered by the UI."
        )
        let capabilities = preview["requested_capabilities"] as? [String] ?? []
        XCTAssertTrue(
            capabilities.contains(where: { $0.hasPrefix("GitHub page UI:") }),
            "Permission review must disclose declarative GitHub UI slots."
        )
        XCTAssertTrue(
            capabilities.contains("Run Skills from GitHub pages"),
            "Permission review must disclose privileged browser actions."
        )

        let sourceURL = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.enhance-source",
            displayName: "Enhance Source"
        )
        let sourceBrowserURL = sourceURL.appendingPathComponent("browser/contributions.yaml")
        let sourceBrowser = try Data(contentsOf: sourceBrowserURL)
        let enhanceResponse = try await perform([
            "operation": "enhance",
            "package_path": sourceURL.path,
            "slot": BrowserSlot.checksJobTrailing.rawValue
        ])
        XCTAssertEqual(enhanceResponse.status, 200)
        let enhanced = try XCTUnwrap(
            JSONSerialization.jsonObject(with: enhanceResponse.body) as? [String: Any]
        )
        let enhancedPath = try XCTUnwrap(enhanced["path"] as? String)
        XCTAssertNotEqual(
            enhancedPath,
            sourceURL.path,
            "Workbench enhancement should modify a managed draft, not the source package."
        )
        XCTAssertEqual(
            try Data(contentsOf: sourceBrowserURL),
            sourceBrowser,
            "Enhance mode must preserve the source package."
        )
        XCTAssertTrue(
            try String(
                contentsOf: URL(fileURLWithPath: enhancedPath)
                    .appendingPathComponent("browser/contributions.yaml"),
                encoding: .utf8
            ).contains(BrowserSlot.checksJobTrailing.rawValue)
        )

        let nativeEnhanceResponse = try await perform([
            "operation": "enhance",
            "package_path": nativeSkillURL.path,
            "slot": BrowserSlot.checksSummaryActions.rawValue
        ])
        XCTAssertEqual(nativeEnhanceResponse.status, 200)
        let nativeEnhanced = try XCTUnwrap(
            JSONSerialization.jsonObject(with: nativeEnhanceResponse.body) as? [String: Any]
        )
        let nativeEnhancedPath = try XCTUnwrap(nativeEnhanced["path"] as? String)
        let nativeEnhancedURL = URL(fileURLWithPath: nativeEnhancedPath)
        XCTAssertNotEqual(nativeEnhancedPath, nativeSkillURL.path)
        XCTAssertEqual(
            try Data(contentsOf: nativeEnhancedURL.appendingPathComponent("SKILL.md")),
            nativeInstructions,
            "The managed adapter must preserve native execution instructions byte-for-byte."
        )
        XCTAssertEqual(
            try Data(contentsOf: nativeSkillURL.appendingPathComponent("SKILL.md")),
            nativeInstructions
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: nativeSkillURL.appendingPathComponent("ghpr.skill.yaml").path
            ),
            "Enhance must not add platform files to the agent-owned source."
        )
        let nativeSchema = try String(
            contentsOf: nativeEnhancedURL.appendingPathComponent(
                "schemas/result.schema.json"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(nativeSchema.contains(#""type""#))
        XCTAssertFalse(nativeSchema.contains(#""required""#))
        XCTAssertTrue(
            try String(
                contentsOf: nativeEnhancedURL.appendingPathComponent(
                    "browser/contributions.yaml"
                ),
                encoding: .utf8
            ).contains(BrowserSlot.checksSummaryActions.rawValue)
        )
        XCTAssertTrue(
            SkillPackageManager.validate(at: nativeEnhancedURL).valid,
            "The managed native copy must pass package validation."
        )
        let nativeFixtureResponse = try await perform([
            "operation": "test",
            "package_path": nativeEnhancedPath
        ])
        XCTAssertEqual(
            nativeFixtureResponse.status,
            200,
            "The pass-through fixture must preserve the native result contract."
        )
        let nativePreviewResponse = try await perform([
            "operation": "preview",
            "package_path": nativeEnhancedPath
        ])
        XCTAssertEqual(nativePreviewResponse.status, 200)
        let nativePreview = try XCTUnwrap(
            JSONSerialization.jsonObject(with: nativePreviewResponse.body) as? [String: Any]
        )
        XCTAssertNotNil(nativePreview["preview"])
    }

    func testCodingAgentIntegrationInstallsSkillAndManagedMCPForEveryAgent() throws {
        let homeURL = temporaryDirectory()
        let sourceSkillURL = homeURL.appendingPathComponent("source-SKILL.md")
        try "# ghpr Skill Builder\n\nRead contracts from the installed ghpr CLI."
            .write(to: sourceSkillURL, atomically: true, encoding: .utf8)
        let sourceMCPServerURL = homeURL.appendingPathComponent("bundled-mcp-ghpr.js")
        try "#!/usr/bin/env node\nconsole.log('standalone ghpr MCP');\n"
            .write(to: sourceMCPServerURL, atomically: true, encoding: .utf8)

        let configDestinations = CodingAgentIntegrationInstaller.mcpConfigDestinations(
            homeURL: homeURL
        )
        let existingJSON: [String: Any] = [
            "mcpServers": ["existing": ["command": "keep-me"]]
        ]
        let existingJSONData = try JSONSerialization.data(withJSONObject: existingJSON)
        for agent in [SkillAgent.claudeCode, .omp] {
            let configURL = try XCTUnwrap(configDestinations[agent])
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try existingJSONData.write(to: configURL)
        }
        let codexConfigURL = try XCTUnwrap(configDestinations[.codex])
        try FileManager.default.createDirectory(
            at: codexConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        model = "gpt-5.6"

        [mcp_servers.ghpr]
        command = "legacy-ghpr"

        [mcp_servers.existing]
        command = "keep-me"
        """.write(to: codexConfigURL, atomically: true, encoding: .utf8)

        let installableAgents: Set<SkillAgent> = [.claudeCode, .codex, .omp]
        let statuses = try CodingAgentIntegrationInstaller.install(
            sourceSkillURL: sourceSkillURL,
            sourceMCPServerURL: sourceMCPServerURL,
            agents: installableAgents,
            homeURL: homeURL
        )

        XCTAssertEqual(
            Set(statuses.filter(\.installed).map(\.agent)),
            installableAgents,
            "Install for All Agents must install both the Skill Builder and review-import MCP"
        )
        let managedMCPURL = CodingAgentIntegrationInstaller.managedMCPServerURL(
            homeURL: homeURL
        )
        XCTAssertEqual(
            try Data(contentsOf: managedMCPURL),
            try Data(contentsOf: sourceMCPServerURL),
            "Agent configurations must use a stable managed copy, not the movable app bundle"
        )
        for status in statuses {
            let installedText = try String(
                contentsOf: status.skillDestination.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            )
            XCTAssertTrue(
                installedText.contains(SkillPackageManager.generatedMarker),
                "\(status.agent.rawValue) must receive a ghpr-managed Skill Builder"
            )
            XCTAssertTrue(
                installedText.contains("Read contracts from the installed ghpr CLI."),
                "\(status.agent.rawValue) must receive the complete builder workflow"
            )
            XCTAssertTrue(status.skillInstalled)
            XCTAssertTrue(status.mcpInstalled)
        }

        for agent in [SkillAgent.claudeCode, .omp] {
            let configURL = try XCTUnwrap(configDestinations[agent])
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
                    as? [String: Any]
            )
            let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
            XCTAssertNotNil(servers["existing"], "\(agent.rawValue) config must preserve other MCPs")
            let ghpr = try XCTUnwrap(servers["ghpr"] as? [String: Any])
            XCTAssertEqual(ghpr["command"] as? String, "node")
            XCTAssertEqual(ghpr["args"] as? [String], [managedMCPURL.path])
        }

        let codexConfig = try String(contentsOf: codexConfigURL, encoding: .utf8)
        XCTAssertTrue(codexConfig.contains("[mcp_servers.existing]"))
        XCTAssertTrue(codexConfig.contains("command = \"keep-me\""))
        XCTAssertTrue(codexConfig.contains("args = [\"\(managedMCPURL.path)\"]"))
        XCTAssertFalse(codexConfig.contains("legacy-ghpr"))

        try "// updated bundle\n".write(
            to: sourceMCPServerURL,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(
            CodingAgentIntegrationInstaller.statuses(
                sourceMCPServerURL: sourceMCPServerURL,
                homeURL: homeURL
            ).allSatisfy { !$0.mcpInstalled },
            "A newer bundled MCP must make every stale managed copy reinstallable"
        )
    }
    func testWorkbenchInstallBuilderInstallsCodingAgentIntegrationInInjectedHome() async throws {
        let root = temporaryDirectory()
        let assetsURL = root.appendingPathComponent("assets", isDirectory: true)
        let skillURL = assetsURL.appendingPathComponent(
            "ghpr-skill-builder/SKILL.md"
        )
        let mcpURL = assetsURL.appendingPathComponent(
            "mcp-ghpr-bundle/index.mjs"
        )
        for url in [skillURL, mcpURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try "# ghpr Skill Builder".write(
            to: skillURL,
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env node\n".write(
            to: mcpURL,
            atomically: true,
            encoding: .utf8
        )

        let homeURL = root.appendingPathComponent("home", isDirectory: true)
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil
        )
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: [assetsURL]),
            appVersion: "1.0",
            draftsRootURL: root.appendingPathComponent("drafts"),
            agentSkillsHomeURL: homeURL
        )
        let response = await router.response(
            for: BrowserHTTPRequest(
                method: "POST",
                target: "/api/v1/workbench",
                headers: [
                    "Authorization": "Bearer \(store.issueWorkbenchGrant())",
                    "Content-Type": "application/json"
                ],
                body: try JSONSerialization.data(withJSONObject: [
                    "operation": "install_builder",
                    "agents": ["codex"]
                ])
            ),
            baseURL: URL(string: "http://127.0.0.1:48120")!
        )

        XCTAssertEqual(response.status, 200)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        let statuses = try XCTUnwrap(payload["install_statuses"] as? [[String: Any]])
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0]["agent"] as? String, "codex")
        XCTAssertEqual(statuses[0]["installed"] as? Bool, true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: homeURL.appendingPathComponent(
                    ".codex/skills/ghpr-skill-builder/SKILL.md"
                ).path
            )
        )
        let managedMCPURL = CodingAgentIntegrationInstaller.managedMCPServerURL(
            homeURL: homeURL
        )
        XCTAssertEqual(
            try String(contentsOf: managedMCPURL, encoding: .utf8),
            "#!/usr/bin/env node\n"
        )
        let codexConfig = try String(
            contentsOf: homeURL.appendingPathComponent(".codex/config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(codexConfig.contains(managedMCPURL.path))
    }


    func testAgentSkillDiscoveryScansClaudeCodeCodexAndOMPUserScopes() throws {
        let homeURL = temporaryDirectory()
        let roots = SkillAgentDiscovery.roots(homeURL: homeURL)

        func writeNativeSkill(agent: SkillAgent, name: String) throws {
            let root = try XCTUnwrap(roots[agent])
            let skillURL = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: skillURL,
                withIntermediateDirectories: true
            )
            try "# \(name)".write(
                to: skillURL.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        try writeNativeSkill(agent: .claudeCode, name: "claude-helper")
        try writeNativeSkill(agent: .omp, name: "omp-helper")
        let codexRoot = try XCTUnwrap(roots[.codex])
        _ = try SkillPackageManager.scaffold(
            at: codexRoot,
            id: "team.codex-policy",
            displayName: "Codex Policy"
        )
        for root in roots.values {
            let builderURL = root.appendingPathComponent(
                "ghpr-skill-builder",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: builderURL,
                withIntermediateDirectories: true
            )
            try "# Builder".write(
                to: builderURL.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let discovered = SkillAgentDiscovery.discover(homeURL: homeURL)
        XCTAssertEqual(discovered.count, 3)
        XCTAssertEqual(
            Set(discovered.flatMap(\.agents)),
            Set([SkillAgent.claudeCode, .codex, .omp]),
            "Discovery must cover every supported coding-agent user scope."
        )
        XCTAssertTrue(
            discovered.first(where: { $0.displayName == "Codex Policy" })?.isGHPRPackage == true
        )
        XCTAssertTrue(
            discovered.filter(\.isGHPRPackage).allSatisfy {
                $0.agents == [.codex]
            },
            "Enhance mode should be able to distinguish ghpr packages from native agent Skills."
        )
        XCTAssertFalse(
            discovered.contains(where: { $0.path.contains("ghpr-skill-builder") }),
            "The builder itself is not an enhancement target."
        )
    }

    func testExtensionStorePersistsTagsContributionsAndClientEventCursors() throws {
        let root = temporaryDirectory()
        let storageURL = root.appendingPathComponent("extension-platform.json")
        let page = GitHubPageContext.pullRequest(repository: "owner/repo", number: 42)
        let now = Date()
        var store: ExtensionPlatformStore? = ExtensionPlatformStore(storageURL: storageURL)

        store?.setTag(.flaky, pageKey: page.key, clientID: "client.one", now: now)
        _ = store?.registerContribution(
            clientID: "client.one",
            registration: ContributionRegistration(
                pageKey: page.key,
                ttlSeconds: 15,
                slot: .checksRunTrailing,
                contribution: ContributionInput(
                    id: "history-badge",
                    component: BrowserComponent(
                        type: .badge,
                        label: nil,
                        text: "Likely flaky",
                        tone: .warning,
                        presentationRef: nil
                    ),
                    action: nil
                )
            ),
            now: now
        )
        _ = store?.appendEvent(
            clientID: "client.one",
            pageKey: page.key,
            name: "team-policy-check:clicked",
            payload: ["source": "checks"],
            now: now
        )
        _ = store?.appendEvent(
            clientID: "client.two",
            pageKey: page.key,
            name: "other",
            payload: [:],
            now: now
        )

        store = ExtensionPlatformStore(storageURL: storageURL)
        XCTAssertEqual(store?.tags(for: page.key), [.flaky])
        XCTAssertEqual(
            store?.contributions(pageKey: page.key, now: now.addingTimeInterval(10)).count,
            1,
            "A live declarative contribution should survive an app restart."
        )
        XCTAssertEqual(
            store?.contributions(pageKey: page.key, now: now.addingTimeInterval(16)).count,
            0,
            "Expired browser contributions must not remain visible."
        )
        XCTAssertEqual(
            store?.events(clientID: "client.one", after: 0).map(\.name),
            ["team-policy-check:clicked"],
            "Event polling must isolate each third-party client."
        )
        XCTAssertTrue(
            store?.events(clientID: "client.one", after: 1).isEmpty == true,
            "A cursor should suppress events that the client already consumed."
        )
    }


    func testSkillMigrationUsesLevelZeroContractAndPreservesOriginal() throws {
        let root = temporaryDirectory()
        let sourceURL = root.appendingPathComponent("legacy-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let sourceSkillURL = sourceURL.appendingPathComponent("SKILL.md")
        let original = "# Legacy Skill\n\nReturn an unstructured report."
        try original.write(to: sourceSkillURL, atomically: true, encoding: .utf8)

        let migratedURL = try SkillPackageManager.migrate(
            sourceURL: sourceURL,
            destinationParentURL: root.appendingPathComponent("drafts"),
            id: "dev.example.migrated"
        )

        XCTAssertEqual(
            try String(contentsOf: sourceSkillURL, encoding: .utf8),
            original,
            "Migration must never modify the user's source Skill."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: migratedURL
                    .appendingPathComponent("legacy/legacy-skill/SKILL.md").path
            ),
            "The managed copy should retain the original Skill under legacy/."
        )
        XCTAssertTrue(
            try SkillPackageManager.testFixture(at: migratedURL).valid,
            "Level 0 output, artifacts, and logs should form a complete fallback contract."
        )
        let schema = try String(
            contentsOf: migratedURL.appendingPathComponent("schemas/result.schema.json"),
            encoding: .utf8
        )
        XCTAssertTrue(schema.contains(#""required": ["status", "output", "artifacts", "logs"]"#))
        XCTAssertFalse(schema.contains(#""summary""#))
    }

    func testSkillEnhancementChangesOnlyPresentationBrowserAndMissingFixture() throws {
        let root = temporaryDirectory()
        let packageURL = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.enhanced",
            displayName: "Enhanced"
        )
        let manifestURL = packageURL.appendingPathComponent("ghpr.skill.yaml")
        let skillURL = packageURL.appendingPathComponent("SKILL.md")
        let schemaURL = packageURL.appendingPathComponent("schemas/result.schema.json")
        let manifest = try Data(contentsOf: manifestURL)
        let instructions = try Data(contentsOf: skillURL)
        let schema = try Data(contentsOf: schemaURL)

        try SkillPackageManager.enhance(
            at: packageURL,
            browserSlot: .checksSummaryActions
        )

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
        XCTAssertEqual(try Data(contentsOf: skillURL), instructions)
        XCTAssertEqual(try Data(contentsOf: schemaURL), schema)
        XCTAssertTrue(
            try String(
                contentsOf: packageURL.appendingPathComponent("browser/contributions.yaml"),
                encoding: .utf8
            ).contains(BrowserSlot.checksSummaryActions.rawValue),
            "Enhance mode should apply the requested semantic Browser slot."
        )
    }


    func testSkillPackageRejectsManifestPathTraversal() throws {
        let root = temporaryDirectory()
        let packageURL = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.traversal",
            displayName: "Traversal"
        )
        let manifestURL = packageURL.appendingPathComponent("ghpr.skill.yaml")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(
                of: "schema: schemas/result.schema.json",
                with: "schema: ../outside.json"
            )
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        try #"{"type":"object"}"#.write(
            to: root.appendingPathComponent("outside.json"),
            atomically: true,
            encoding: .utf8
        )

        let validation = SkillPackageManager.validate(at: packageURL)
        XCTAssertFalse(validation.valid, "A manifest path must never escape its package")
        XCTAssertTrue(
            validation.issues.contains { $0.message.contains("escapes the Skill directory") },
            "Validation should explain the rejected traversal"
        )
        XCTAssertThrowsError(try SkillPackageManager.load(at: packageURL))
    }

    func testSkillPackageRejectsSymlinkEscapeBeforeInstall() throws {
        let root = temporaryDirectory()
        let packageURL = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.symlink",
            displayName: "Symlink"
        )
        let externalURL = root.appendingPathComponent("external-presentation.yaml")
        try "api_version: ghpr.dev/presentation/v1".write(
            to: externalURL,
            atomically: true,
            encoding: .utf8
        )
        let presentationURL = packageURL.appendingPathComponent(
            "presentation/presentation.yaml"
        )
        try FileManager.default.removeItem(at: presentationURL)
        try FileManager.default.createSymbolicLink(
            at: presentationURL,
            withDestinationURL: externalURL
        )
        let installRoot = root.appendingPathComponent("installed", isDirectory: true)

        let validation = SkillPackageManager.validate(at: packageURL)
        XCTAssertFalse(validation.valid, "A symlink must not escape its package")
        XCTAssertThrowsError(
            try SkillPackageManager.install(
                packageURL: packageURL,
                skillsRootURL: installRoot
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installRoot.appendingPathComponent("dev.example.symlink").path
            ),
            "An unsafe package must not be copied into the installed Skills directory"
        )
    }

    func testSkillPackagePackRejectsSourceAsOutputWithoutDeletingIt() throws {
        let root = temporaryDirectory()
        let packageURL = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.pack-source",
            displayName: "Pack Source"
        )
        let manifestURL = packageURL.appendingPathComponent("ghpr.skill.yaml")

        XCTAssertThrowsError(
            try SkillPackageManager.pack(
                packageURL: packageURL,
                outputURL: packageURL
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "Rejecting an unsafe output must preserve the source package"
        )
        XCTAssertTrue(
            SkillPackageManager.validate(at: packageURL).valid,
            "The preserved source package should remain valid"
        )
    }

    func testSkillPackageInstallRejectsSourceDestinationWithoutDeletingIt() throws {
        let root = temporaryDirectory()
        let packageURL = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.install-source",
            displayName: "Install Source"
        )
        let manifestURL = packageURL.appendingPathComponent("ghpr.skill.yaml")

        XCTAssertThrowsError(
            try SkillPackageManager.install(
                packageURL: packageURL,
                skillsRootURL: root
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "Rejecting an unsafe install destination must preserve the source package"
        )
        XCTAssertTrue(
            SkillPackageManager.validate(at: packageURL).valid,
            "The preserved source package should remain valid"
        )
    }

    func testSkillFixtureRejectsEnumTypeAndAdditionalPropertyViolations() throws {
        let root = temporaryDirectory()
        let packageURL = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.invalid-fixture",
            displayName: "Invalid Fixture"
        )
        let fixtureURL = packageURL.appendingPathComponent(
            "fixtures/expected-result.json"
        )
        try """
        {
          "status": "definitely_related",
          "summary": 42,
          "evidence": [1],
          "unexpected": true
        }
        """.write(to: fixtureURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SkillPackageManager.testFixture(at: packageURL)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(
                message.contains("$.status is not one of the declared enum values"),
                "Fixture test should enforce enum constraints: \(message)"
            )
            XCTAssertTrue(
                message.contains("$.summary must be string"),
                "Fixture test should enforce property types: \(message)"
            )
            XCTAssertTrue(
                message.contains("$.evidence[0] must be string"),
                "Fixture test should enforce array item schemas: \(message)"
            )
            XCTAssertTrue(
                message.contains("$.unexpected is not allowed"),
                "Fixture test should enforce additionalProperties: \(message)"
            )
        }
    }

    func testDeclarativeSkillResultCardOpensLocalRunDetailAndRedactsArtifacts() async throws {
        let root = temporaryDirectory()
        let installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        let draft = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.result-card",
            displayName: "Result Card"
        )
        _ = try SkillPackageManager.install(packageURL: draft, skillsRootURL: installedRoot)
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: installedRoot,
            bundledSkillsRootURL: nil
        )
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: []),
            appVersion: "1.0",
            draftsRootURL: root.appendingPathComponent("drafts")
        )
        let page = GitHubPageContext.pullRequest(repository: "owner/repo", number: 42)
        let result = SkillResult(
            kind: .generic,
            title: "Policy result",
            summary: "The policy check completed.",
            analysis: nil,
            codeReview: nil,
            markdown: "Structured output",
            artifacts: [
                SkillArtifact(
                    id: "artifact-1",
                    name: "report.json",
                    mediaType: "application/json",
                    relativePath: "artifacts/report.json",
                    inlineText: nil
                )
            ],
            payload: .object([
                "status": .string("completed"),
                "artifacts": .array([
                    .object([
                        "relative_path": .string("artifacts/report.json"),
                        "inline_text": .string("private artifact body")
                    ])
                ])
            ])
        )
        store.save(
            run: SkillRun(
                id: "run_result_card",
                skillID: "dev.example.result-card",
                page: page,
                requestedByClientID: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                startedAt: Date(timeIntervalSince1970: 1_700_000_001),
                completedAt: Date(timeIntervalSince1970: 1_700_000_003),
                status: .completed,
                progressMessage: "/Users/example/private token=secret",
                progressCurrent: 3,
                progressTotal: 3,
                logEntries: [
                    SkillRunLogEntry(
                        timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                        kind: .running,
                        message: "/Users/example/private token=secret"
                    ),
                    SkillRunLogEntry(
                        timestamp: Date(timeIntervalSince1970: 1_700_000_002),
                        kind: .running,
                        message: "credential=secret"
                    ),
                    SkillRunLogEntry(
                        timestamp: Date(timeIntervalSince1970: 1_700_000_002),
                        kind: .running,
                        message: "Target owner/repo#42 token=secret",
                        stream: .skillInput
                    ),
                    SkillRunLogEntry(
                        timestamp: Date(timeIntervalSince1970: 1_700_000_002),
                        kind: .running,
                        message: "Finding at /Users/example/private credential=secret",
                        stream: .agentOutput
                    ),
                    SkillRunLogEntry(
                        timestamp: Date(timeIntervalSince1970: 1_700_000_003),
                        kind: .success,
                        message: "Completed"
                    )
                ],
                result: result,
                error: "Process failed at /Users/example/private with token=secret",
                retryOfRunID: nil
            )
        )
        store.save(
            agentRuntimePreference: AgentRuntimePreference(
                model: "gpt-5.6",
                reasoningEffort: "high"
            ),
            for: .codex
        )
        store.save(
            agentCapabilityCatalog: AgentCapabilityCatalog(
                agent: .codex,
                models: [
                    AgentModelOption(
                        slug: "gpt-5.6",
                        displayName: "GPT-5.6",
                        detail: nil,
                        defaultEffort: "high",
                        reasoningEfforts: [
                            AgentReasoningEffortOption(effort: "high", detail: "Thorough")
                        ]
                    )
                ],
                reasoningEfforts: [
                    AgentReasoningEffortOption(effort: "high", detail: "Thorough")
                ],
                listsModels: true,
                listsReasoningEfforts: true,
                source: "test",
                refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let officialToken = try approveClient(
            store: store,
            id: "dev.ghpr.official-test",
            scopes: [.prRead, .analysisRead, .uiContribute, .detailOpen, .skillList]
        )
        let baseURL = URL(string: "http://127.0.0.1:48120")!
        let pageResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "GET",
                target: "/api/v1/page?repository=owner/repo&number=42",
                headers: ["Authorization": "Bearer \(officialToken)"]
            ),
            baseURL: baseURL
        )
        XCTAssertEqual(pageResponse.status, 200)
        let snapshot = try decodeValue(PageExtensionSnapshot.self, from: pageResponse.body)
        XCTAssertEqual(snapshot.agentRuntime.first { $0.agent == .codex }?.preference.model, "gpt-5.6")
        XCTAssertEqual(snapshot.agentCatalogs.first { $0.agent == .codex }?.models.first?.slug, "gpt-5.6")
        let card = try XCTUnwrap(
            snapshot.contributions.first { $0.component.type == .resultCard }
        )
        XCTAssertEqual(card.component.label, "Policy result")
        XCTAssertEqual(card.component.text, "The policy check completed.")
        XCTAssertEqual(card.action?.runID, "run_result_card")
        XCTAssertEqual(
            snapshot.runs.first?.result?.artifacts,
            [],
            "analysis:read must not disclose artifact metadata without artifact:read"
        )
        guard case .object(let redactedPayload)? = snapshot.runs.first?.result?.payload,
              case .array(let redactedPayloadArtifacts)? = redactedPayload["artifacts"] else {
            return XCTFail("Browser result payload must remain structured.")
        }
        XCTAssertTrue(
            redactedPayloadArtifacts.isEmpty,
            "artifact:read redaction must also cover the raw structured payload."
        )
        XCTAssertEqual(snapshot.runs.first?.progressMessage, "Completed")
        XCTAssertNil(snapshot.runs.first?.error)
        XCTAssertEqual(
            snapshot.runs.first?.logEntries?.map(\.message),
            [
                "Executing Skill",
                "Target owner/repo#42 token=[redacted]",
                "Finding at [local path] credential=[redacted]",
                "Completed"
            ],
            "Only fixed lifecycle events and bounded, sanitized input/output lines may cross the Browser Bridge"
        )
        XCTAssertEqual(
            snapshot.runs.first?.logEntries?.compactMap(\.stream),
            [.skillInput, .agentOutput]
        )

        let pageKey = page.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let invokeResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "POST",
                target: "/api/v1/contributions/\(card.clientID)/\(card.id)/invoke?page_key=\(pageKey)",
                headers: ["Authorization": "Bearer \(officialToken)"]
            ),
            baseURL: baseURL
        )
        XCTAssertEqual(invokeResponse.status, 200)
        let actionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: invokeResponse.body) as? [String: Any]
        )
        let detailURL = try XCTUnwrap(actionObject["url"] as? String)
        XCTAssertTrue(detailURL.contains("/ui/run/run_result_card?cap="))
        let detailComponents = try XCTUnwrap(URLComponents(string: detailURL))
        let detailToken = try XCTUnwrap(
            detailComponents.queryItems?.first { $0.name == "cap" }?.value
        )
        let detailResponse = await router.response(
            for: BrowserHTTPRequest(
                method: "GET",
                target: "/api/v1/runs/run_result_card",
                headers: ["Authorization": "Bearer \(detailToken)"]
            ),
            baseURL: baseURL
        )
        let detailedRun = try decodeValue(SkillRun.self, from: detailResponse.body)
        XCTAssertEqual(
            detailedRun.result?.artifacts.count,
            1,
            "The short-lived local detail capability may render the run's artifacts"
        )
        guard case .object(let detailedPayload)? = detailedRun.result?.payload,
              case .array(let detailedPayloadArtifacts)? = detailedPayload["artifacts"] else {
            return XCTFail("Local run detail must retain its structured payload.")
        }
        XCTAssertEqual(detailedPayloadArtifacts.count, 1)
        XCTAssertEqual(detailedRun.progressMessage, "Completed")
        XCTAssertNil(detailedRun.error)
        XCTAssertEqual(
            detailedRun.logEntries?.map(\.message),
            [
                "Executing Skill",
                "Target owner/repo#42 token=[redacted]",
                "Finding at [local path] credential=[redacted]",
                "Completed"
            ]
        )
    }

    func testContributionInvocationCannotBorrowOwnerScopes() async throws {
        let root = temporaryDirectory()
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil
        )
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: Self.emptySnapshot,
            assetProvider: BrowserAssetProvider(roots: []),
            appVersion: "1.0",
            draftsRootURL: root.appendingPathComponent("drafts")
        )
        let ownerToken = try approveClient(
            store: store,
            id: "com.example.owner",
            scopes: [.uiContribute, .skillRun]
        )
        XCTAssertFalse(ownerToken.isEmpty)
        let callerToken = try approveClient(
            store: store,
            id: "com.example.read-only-caller",
            scopes: [.uiContribute]
        )
        let page = GitHubPageContext.pullRequest(repository: "owner/repo", number: 42)
        _ = store.registerContribution(
            clientID: "com.example.owner",
            registration: ContributionRegistration(
                pageKey: page.key,
                ttlSeconds: 300,
                slot: .prHeaderActions,
                contribution: ContributionInput(
                    id: "privileged-run",
                    component: BrowserComponent(
                        type: .action,
                        label: "Run",
                        text: nil,
                        tone: .analysis,
                        presentationRef: nil
                    ),
                    action: BrowserAction(
                        kind: .runSkill,
                        skillID: SkillRuntime.classifyFlakySkillID,
                        runID: nil,
                        analysisID: nil,
                        tag: nil,
                        event: nil
                    )
                )
            )
        )
        let pageKey = page.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let response = await router.response(
            for: BrowserHTTPRequest(
                method: "POST",
                target: "/api/v1/contributions/com.example.owner/privileged-run/invoke?page_key=\(pageKey)",
                headers: ["Authorization": "Bearer \(callerToken)"]
            ),
            baseURL: URL(string: "http://127.0.0.1:48120")!
        )
        XCTAssertEqual(
            response.status,
            403,
            "A ui:contribute-only caller must not borrow the contribution owner's skill:run scope"
        )
    }


    func testSkillPackageValidationRejectsUnknownPresentationTypeAndBrowserSlot() throws {
        let root = temporaryDirectory()
        let packageURL = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.invalid-contracts",
            displayName: "Invalid Contracts"
        )
        let presentationURL = packageURL.appendingPathComponent(
            "presentation/presentation.yaml"
        )
        let browserURL = packageURL.appendingPathComponent(
            "browser/contributions.yaml"
        )
        try String(contentsOf: presentationURL, encoding: .utf8)
            .replacingOccurrences(of: "type: hero", with: "type: carousel")
            .write(to: presentationURL, atomically: true, encoding: .utf8)
        try String(contentsOf: browserURL, encoding: .utf8)
            .replacingOccurrences(
                of: "slot: pr.header.actions",
                with: "slot: pr.sidebar.magic"
            )
            .write(to: browserURL, atomically: true, encoding: .utf8)

        let validation = SkillPackageManager.validate(at: packageURL)
        XCTAssertFalse(validation.valid)
        XCTAssertTrue(
            validation.issues.contains {
                $0.message.contains("unsupported presentation type")
            },
            "Validation must reject presentation components the renderer cannot display."
        )
        XCTAssertTrue(
            validation.issues.contains {
                $0.message.contains("unsupported Browser slot")
            },
            "Validation must reject unknown semantic mount slots."
        )
    }

    func testSkillRuntimeExecutesInstalledSkillThroughOMPAdapter() async throws {
        let root = temporaryDirectory()
        let installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        let packageURL = try SkillPackageManager.scaffold(
            at: root.appendingPathComponent("source", isDirectory: true),
            id: "dev.example.agent-runtime",
            displayName: "Agent Runtime"
        )
        _ = try SkillPackageManager.install(
            packageURL: packageURL,
            skillsRootURL: installedRoot
        )
        let executable = try executableScript(
            """
            #!/bin/sh
            case " $* " in
              *" --mode=json "*) ;;
              *) exit 64 ;;
            esac
            printf '%s\\n' '{"type":"result","structured_output":{"status":"needs_investigation","summary":"Agent examined strict context.","evidence":["Only supplied context was used."]}}'
            """
        )
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: installedRoot,
            bundledSkillsRootURL: nil,
            agentExecutableURLs: [.omp: executable]
        )

        let queued = try runtime.start(
            skillID: "dev.example.agent-runtime",
            page: .pullRequest(repository: "owner/repo", number: 42),
            pullRequest: nil,
            requestedByClientID: "dev.ghpr.official-test"
        )
        XCTAssertEqual(queued.status, .queued)
        XCTAssertNil(queued.result)
        XCTAssertEqual(queued.agent, .omp, "Queued runs must expose the concrete Agent backend.")

        let completed = try await terminalRun(store: store, id: queued.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.agent, .omp, "Completed runs must retain the concrete Agent backend.")
        XCTAssertEqual(completed.result?.summary, "Agent examined strict context.")
        XCTAssertEqual(
            completed.logEntries?
                .filter { $0.stream == nil }
                .map(\.message),
            [
                "Queued",
                "Preparing strict context",
                "Starting Skill runtime",
                "Executing Skill",
                "Receiving Agent output",
                "Finalizing result",
                "Completed"
            ]
        )
        XCTAssertFalse(
            completed.logEntries?.filter { $0.stream == .skillInput }.isEmpty ?? true
        )
        XCTAssertFalse(
            completed.logEntries?.filter { $0.stream == .agentOutput }.isEmpty ?? true
        )
        guard case .object(let payload)? = completed.result?.payload,
              case .string(let status)? = payload["status"] else {
            return XCTFail("Completed Agent result must retain its structured payload.")
        }
        XCTAssertEqual(status, "needs_investigation")
    }

    func testAgentAdapterPassesControlledContextAndAcceptsStructuredResult() async throws {
        let root = temporaryDirectory()
        let promptCaptureURL = root.appendingPathComponent("prompt.txt")
        let executable = try executableScript(
            """
            #!/bin/sh
            for argument in "$@"; do
              case "$argument" in
                @*) /bin/cp "${argument#@}" "\(promptCaptureURL.path)" ;;
              esac
            done
            printf '%s\\n' '{"type":"result","structured_output":{"status":"needs_investigation","summary":"Controlled context received.","evidence":["Envelope decoded."]}}'
            """
        )
        let request = AgentExecutionRequest(
            skillID: "dev.example.controlled-context",
            displayName: "Controlled Context",
            agent: .omp,
            timeoutSeconds: 30,
            instructions: "Use only the supplied context.",
            resultSchema: Data(
                #"{"type":"object","required":["status","summary","evidence"],"properties":{"status":{"type":"string"},"summary":{"type":"string"},"evidence":{"type":"array","items":{"type":"string"}}},"additionalProperties":false}"#.utf8
            ),
            context: AgentSkillInvocationContext.make(
                skillID: "dev.example.controlled-context",
                requestedSections: ["pr_metadata", "failed_job_logs"],
                page: .pullRequest(repository: "owner/repo", number: 42),
                pullRequest: nil,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        let result = try await AgentCLIAdapter.run(
            request: request,
            executableURL: executable,
            progress: SkillRuntime.ProgressReporter { _ in }
        )

        XCTAssertEqual(result.summary, "Controlled context received.")
        guard case .object(let payload)? = result.payload,
              case .string(let status)? = payload["status"] else {
            return XCTFail("The validated structured Agent result must be retained.")
        }
        XCTAssertEqual(status, "needs_investigation")

        let capturedPrompt = try String(contentsOf: promptCaptureURL, encoding: .utf8)
        let markerRange = try XCTUnwrap(capturedPrompt.range(of: "INVOCATION_ENVELOPE"))
        let envelopeText = capturedPrompt[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envelopeData = Data(envelopeText.utf8)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any]
        )
        XCTAssertEqual(
            envelope["skill_instructions"] as? String,
            "Use only the supplied context."
        )
        let context = try XCTUnwrap(envelope["ghpr_context"] as? [String: Any])
        XCTAssertEqual(
            context["requested_sections"] as? [String],
            ["pr_metadata", "failed_job_logs"]
        )
        XCTAssertEqual(
            context["unavailable_sections"] as? [String],
            ["pr_metadata", "failed_job_logs"]
        )
        let target = try XCTUnwrap(context["target"] as? [String: Any])
        XCTAssertEqual(target["repository"] as? String, "owner/repo")
        XCTAssertEqual(target["pull_request_number"] as? Int, 42)
        XCTAssertNil(context["pull_request"])
        XCTAssertNil(context["ci_status"])
        let resultSchema = try XCTUnwrap(
            envelope["result_schema"] as? [String: Any]
        )
        XCTAssertEqual(resultSchema["type"] as? String, "object")
        XCTAssertEqual(
            resultSchema["required"] as? [String],
            ["status", "summary", "evidence"]
        )
    }

    func testSkillRuntimePublishesExecutingStateWhileAgentCLIIsRunning() async throws {
        let root = temporaryDirectory()
        let installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        let packageURL = try SkillPackageManager.scaffold(
            at: root.appendingPathComponent("source", isDirectory: true),
            id: "dev.example.live-agent-runtime",
            displayName: "Live Agent Runtime"
        )
        _ = try SkillPackageManager.install(
            packageURL: packageURL,
            skillsRootURL: installedRoot
        )
        let startedURL = root.appendingPathComponent("agent-started")
        let allowOutputURL = root.appendingPathComponent("allow-agent-output")
        let outputStartedURL = root.appendingPathComponent("agent-output-started")
        let finishURL = root.appendingPathComponent("finish-agent")
        defer {
            try? Data().write(to: allowOutputURL)
            try? Data().write(to: finishURL)
        }
        let executable = try executableScript(
            """
            #!/bin/sh
            printf 'started\n' > "\(startedURL.path)"
            while [ ! -f "\(allowOutputURL.path)" ]; do
              /bin/sleep 0.01
            done
            printf '%s' '{"status":"needs_investigation","summary":"'
            printf 'output-started\n' > "\(outputStartedURL.path)"
            while [ ! -f "\(finishURL.path)" ]; do
              /bin/sleep 0.01
            done
            printf '%s\n' 'Live execution completed.","evidence":["Lifecycle observed."]}'
            """
        )
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: installedRoot,
            bundledSkillsRootURL: nil,
            agentExecutableURLs: [.omp: executable]
        )
        let queued = try runtime.start(
            skillID: "dev.example.live-agent-runtime",
            page: .pullRequest(repository: "owner/repo", number: 42),
            pullRequest: nil,
            requestedByClientID: "dev.ghpr.official-test"
        )

        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: startedURL.path),
               store.run(id: queued.id)?.progressMessage == "Executing Skill" {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let executing = try XCTUnwrap(store.run(id: queued.id))
        XCTAssertEqual(executing.status, .running)
        XCTAssertEqual(executing.progressMessage, "Executing Skill")
        XCTAssertEqual(executing.progressCurrent, 2)
        XCTAssertEqual(
            executing.logEntries?.last { $0.stream == nil }?.message,
            "Executing Skill"
        )
        XCTAssertNil(executing.result)

        try Data().write(to: allowOutputURL)
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: outputStartedURL.path),
               store.run(id: queued.id)?.progressMessage == "Receiving Agent output" {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let receivingOutput = try XCTUnwrap(store.run(id: queued.id))
        XCTAssertEqual(receivingOutput.status, .running)
        XCTAssertEqual(receivingOutput.progressMessage, "Receiving Agent output")
        XCTAssertEqual(receivingOutput.progressCurrent, 2)
        XCTAssertEqual(
            receivingOutput.logEntries?.last { $0.stream == nil }?.message,
            "Receiving Agent output"
        )
        XCTAssertTrue(
            receivingOutput.logEntries?
                .filter { $0.stream == .agentOutput }
                .isEmpty ?? false,
            "An incomplete JSON event must remain buffered until its terminating newline arrives."
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        let stillExecuting = try XCTUnwrap(store.run(id: queued.id))
        XCTAssertEqual(stillExecuting.status, .running)
        XCTAssertEqual(stillExecuting.progressMessage, "Receiving Agent output")
        XCTAssertNil(stillExecuting.result)

        try Data().write(to: finishURL)
        let completed = try await terminalRun(store: store, id: queued.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.result?.summary, "Live execution completed.")
        XCTAssertEqual(
            completed.logEntries?
                .filter { $0.stream == nil }
                .map(\.message),
            [
                "Queued",
                "Preparing strict context",
                "Starting Skill runtime",
                "Executing Skill",
                "Receiving Agent output",
                "Finalizing result",
                "Completed"
            ]
        )
        XCTAssertTrue(
            completed.logEntries?.contains {
                $0.stream == .agentOutput &&
                    $0.message == "Output: Live execution completed."
            } ?? false
        )
    }

    func testSkillRuntimeRejectsMalformedAgentOutputWithoutPublishingRawText() async throws {
        let root = temporaryDirectory()
        let installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        let packageURL = try SkillPackageManager.scaffold(
            at: root.appendingPathComponent("source", isDirectory: true),
            id: "dev.example.malformed-result",
            displayName: "Malformed Result"
        )
        _ = try SkillPackageManager.install(
            packageURL: packageURL,
            skillsRootURL: installedRoot
        )
        let executable = try executableScript(
            """
            #!/bin/sh
            printf '%s\\n' 'private malformed output'
            """
        )
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: installedRoot,
            bundledSkillsRootURL: nil,
            agentExecutableURLs: [.omp: executable]
        )
        let queued = try runtime.start(
            skillID: "dev.example.malformed-result",
            page: .pullRequest(repository: "owner/repo", number: 42),
            pullRequest: nil,
            requestedByClientID: "dev.ghpr.official-test"
        )

        let failed = try await terminalRun(store: store, id: queued.id)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertNil(failed.result)
        XCTAssertEqual(failed.error, "The Agent result is not valid contract JSON.")
        XCTAssertFalse(
            failed.logEntries?.contains {
                $0.stream == .agentOutput &&
                    $0.message.contains("private malformed output")
            } ?? true,
            "Non-protocol stdout must never enter Browser-visible execution logs."
        )
        XCTAssertFalse(
            failed.error?.contains("private malformed output") ?? true,
            "Agent stdout must not leak into the run error channel."
        )
    }

    func testSkillRuntimeCancellationTerminatesAgentProcess() async throws {
        let root = temporaryDirectory()
        let installedRoot = root.appendingPathComponent("installed", isDirectory: true)
        let packageURL = try SkillPackageManager.scaffold(
            at: root.appendingPathComponent("source", isDirectory: true),
            id: "dev.example.cancel-agent",
            displayName: "Cancel Agent"
        )
        _ = try SkillPackageManager.install(
            packageURL: packageURL,
            skillsRootURL: installedRoot
        )
        let markerURL = root.appendingPathComponent("agent.pid")
        let executable = try executableScript(
            """
            #!/bin/sh
            ( trap '' TERM; while :; do :; done ) &
            child_pid=$!
            printf '%s %s\\n' "$$" "$child_pid" > "\(markerURL.path)"
            wait "$child_pid"
            """
        )
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: installedRoot,
            bundledSkillsRootURL: nil,
            agentExecutableURLs: [.omp: executable]
        )
        let queued = try runtime.start(
            skillID: "dev.example.cancel-agent",
            page: .pullRequest(repository: "owner/repo", number: 42),
            pullRequest: nil,
            requestedByClientID: "dev.ghpr.official-test"
        )
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: markerURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let processIDs = try String(contentsOf: markerURL, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .map {
                try XCTUnwrap(Int32($0))
            }
        XCTAssertEqual(processIDs.count, 2)
        _ = try runtime.cancel(runID: queued.id)

        let cancelled = try await terminalRun(store: store, id: queued.id)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.logEntries?.last?.message, "Cancelled")
        XCTAssertNil(cancelled.result)
        for processID in processIDs {
            for _ in 0..<100 where Darwin.kill(processID, 0) == 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(
                Darwin.kill(processID, 0),
                -1,
                "Cancelling the Skill run must terminate every Agent process."
            )
        }
    }

    func testClaudeAdapterUsesToollessNonPersistentInvocation() async throws {
        let markerURL = temporaryDirectory().appendingPathComponent("claude-arguments")
        let executable = try executableScript(
            """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(markerURL.path)"
            cat >/dev/null
            printf '%s\\n' '{"type":"result","structured_output":{"summary":"Claude completed strict analysis."}}'
            """
        )
        let request = AgentExecutionRequest(
            skillID: "dev.example.claude-runtime",
            displayName: "Claude Runtime",
            agent: .claudeCode,
            timeoutSeconds: 30,
            instructions: "Summarize the supplied context.",
            resultSchema: Data(
                #"{"type":"object","required":["summary"],"properties":{"summary":{"type":"string"}},"additionalProperties":false}"#.utf8
            ),
            context: AgentSkillInvocationContext.make(
                skillID: "dev.example.claude-runtime",
                requestedSections: [],
                page: .pullRequest(repository: "owner/repo", number: 42),
                pullRequest: nil
            )
        )

        let result = try await AgentCLIAdapter.run(
            request: request,
            executableURL: executable,
            progress: SkillRuntime.ProgressReporter { _ in }
        )
        XCTAssertEqual(result.summary, "Claude completed strict analysis.")
        let arguments = try String(contentsOf: markerURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        for required in [
            "--bare",
            "-p",
            "--tools",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--json-schema",
            "stream-json"
        ] {
            XCTAssertTrue(
                arguments.contains(required),
                "Claude invocation must include \(required)."
            )
        }
        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
    }

    func testAgentCatalogsComeFromTheAgentCLIListings() async throws {
        let claudeHelp = """
        Options:
          --effort <level>                      Effort level for the current session
                                                (low, medium, high, xhigh, max)
          --fallback-model <model>              Enable automatic fallback
          --model <model>                       Model for the current session. Provide
                                                an alias for the latest model (e.g.
                                                'fable', 'opus', or 'sonnet') or a
                                                model's full name (e.g.
                                                'claude-fable-5').
          --name <name>                         Set a display name
        """
        let codexCatalog = """
        {"models":[
          {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Frontier coding model.",
           "default_reasoning_level":"low","visibility":"list",
           "supported_reasoning_levels":[{"effort":"low","description":"Fast"},{"effort":"high","description":"Deep"}]},
          {"slug":"gpt-5.6-terra","display_name":"GPT-5.6-Terra","description":"Balanced model.",
           "default_reasoning_level":"medium","visibility":"list",
           "supported_reasoning_levels":[{"effort":"medium","description":"Balanced"}]},
          {"slug":"internal-preview","display_name":"Internal","description":"Hidden.",
           "default_reasoning_level":null,"visibility":"hidden","supported_reasoning_levels":[]}
        ]}
        """
        var requested: [(SkillAgent, [String])] = []
        let runner: AgentCapabilityProbe.Runner = { agent, _, arguments in
            requested.append((agent, arguments))
            switch agent {
            case .claudeCode: return Data(claudeHelp.utf8)
            case .codex: return Data(codexCatalog.utf8)
            default: throw AgentCapabilityCatalogError.unsupportedAgent(agent)
            }
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let claude = try await AgentCapabilityProbe.catalog(
            for: .claudeCode,
            executableURL: try executableScript("#!/bin/sh\nexit 0"),
            now: now,
            runner: runner
        )
        XCTAssertEqual(claude.source, "claude --help")
        XCTAssertEqual(
            claude.models.map(\.slug),
            ["fable", "opus", "sonnet", "claude-fable-5"]
        )
        XCTAssertEqual(
            claude.reasoningEfforts.map(\.effort),
            ["low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertTrue(claude.listsModels)
        XCTAssertTrue(claude.listsReasoningEfforts)

        let codex = try await AgentCapabilityProbe.catalog(
            for: .codex,
            executableURL: try executableScript("#!/bin/sh\nexit 0"),
            now: now,
            runner: runner
        )
        XCTAssertEqual(codex.source, "codex debug models")
        XCTAssertEqual(codex.models.map(\.slug), ["gpt-5.6-sol", "gpt-5.6-terra"])
        XCTAssertEqual(codex.models.first?.displayName, "GPT-5.6-Sol")
        XCTAssertEqual(codex.models.first?.defaultEffort, "low")
        XCTAssertEqual(
            codex.reasoningEfforts.map(\.effort),
            ["low", "high", "medium"]
        )
        XCTAssertEqual(
            codex.reasoningEfforts(forModel: "gpt-5.6-terra").map(\.effort),
            ["medium"]
        )
        XCTAssertEqual(
            codex.reasoningEfforts(forModel: nil).map(\.effort),
            ["low", "high", "medium"]
        )

        let omp = try await AgentCapabilityProbe.catalog(
            for: .omp,
            now: now,
            runner: runner
        )
        XCTAssertFalse(omp.listsModels, "OMP must stay a free-form model entry.")
        XCTAssertTrue(omp.models.isEmpty)
        XCTAssertNil(AgentCapabilityProbe.probeArguments(for: .omp))
        XCTAssertEqual(
            requested.map { ($0.0, $0.1) }.map { "\($0.0.rawValue):\($0.1.joined(separator: " "))" },
            ["claude_code:--help", "codex:debug models"],
            "Only Claude Code and Codex may be listed through their CLI."
        )
    }

    func testAgentRuntimeSelectionPersistsAcrossStoreReloads() throws {
        let storageURL = temporaryDirectory().appendingPathComponent("extension-platform.json")
        let store = ExtensionPlatformStore(storageURL: storageURL)
        store.save(
            agentRuntimePreference: AgentRuntimePreference(
                model: "claude-fable-5",
                reasoningEffort: "xhigh"
            ),
            for: .claudeCode
        )
        store.save(
            agentRuntimePreference: AgentRuntimePreference(model: "opus", reasoningEffort: nil),
            for: .omp
        )
        store.save(
            agentCapabilityCatalog: AgentCapabilityCatalog(
                agent: .claudeCode,
                models: [
                    AgentModelOption(
                        slug: "claude-fable-5",
                        displayName: "claude-fable-5",
                        detail: nil,
                        defaultEffort: nil,
                        reasoningEfforts: []
                    )
                ],
                reasoningEfforts: [AgentReasoningEffortOption(effort: "xhigh", detail: nil)],
                listsModels: true,
                listsReasoningEfforts: true,
                source: "claude --help",
                refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        let reloaded = ExtensionPlatformStore(storageURL: storageURL)
        XCTAssertEqual(
            reloaded.agentRuntimePreference(for: .claudeCode),
            AgentRuntimePreference(model: "claude-fable-5", reasoningEffort: "xhigh"),
            "Claude Code runtime selection must survive a restart."
        )
        XCTAssertEqual(reloaded.agentRuntimePreference(for: .omp).model, "opus")
        XCTAssertEqual(reloaded.agentRuntimePreference(for: .codex), .unset)
        XCTAssertEqual(
            reloaded.agentCapabilityCatalog(for: .claudeCode)?.models.map(\.slug),
            ["claude-fable-5"],
            "The cached catalog must be reusable without probing the CLI again."
        )

        reloaded.save(agentRuntimePreference: .unset, for: .claudeCode)
        XCTAssertEqual(
            ExtensionPlatformStore(storageURL: storageURL)
                .agentRuntimePreference(for: .claudeCode),
            .unset
        )
    }

    func testSelectedModelAndEffortReachTheAgentInvocation() async throws {
        let claudeArgumentsURL = temporaryDirectory()
            .appendingPathComponent("claude-model-arguments")
        let claudeExecutable = try executableScript(
            """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(claudeArgumentsURL.path)"
            cat >/dev/null
            printf '%s\\n' '{"type":"result","structured_output":{"summary":"Pinned model completed."}}'
            """
        )
        let schema = Data(
            #"{"type":"object","required":["summary"],"properties":{"summary":{"type":"string"}},"additionalProperties":false}"#.utf8
        )
        let context = AgentSkillInvocationContext.make(
            skillID: "dev.example.model-selection",
            requestedSections: [],
            page: .pullRequest(repository: "owner/repo", number: 42),
            pullRequest: nil
        )
        var claudeRequest = AgentExecutionRequest(
            skillID: "dev.example.model-selection",
            displayName: "Model Selection",
            agent: .claudeCode,
            timeoutSeconds: 30,
            instructions: "Summarize the supplied context.",
            resultSchema: schema,
            context: context
        )
        claudeRequest.model = "claude-fable-5"
        claudeRequest.reasoningEffort = "xhigh"
        _ = try await AgentCLIAdapter.run(
            request: claudeRequest,
            executableURL: claudeExecutable,
            progress: SkillRuntime.ProgressReporter { _ in }
        )
        let claudeArguments = try String(contentsOf: claudeArgumentsURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        XCTAssertEqual(
            claudeArguments.firstIndex(of: "claude-fable-5").map { $0 - 1 },
            claudeArguments.firstIndex(of: "--model")
        )
        XCTAssertEqual(
            claudeArguments.firstIndex(of: "xhigh").map { $0 - 1 },
            claudeArguments.firstIndex(of: "--effort")
        )

        let ompArgumentsURL = temporaryDirectory()
            .appendingPathComponent("omp-model-arguments")
        let ompExecutable = try executableScript(
            """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(ompArgumentsURL.path)"
            printf '%s\\n' '{"type":"result","structured_output":{"summary":"Pinned model completed."}}'
            """
        )
        var ompRequest = AgentExecutionRequest(
            skillID: "dev.example.model-selection",
            displayName: "Model Selection",
            agent: .omp,
            timeoutSeconds: 30,
            instructions: "Summarize the supplied context.",
            resultSchema: schema,
            context: context
        )
        ompRequest.model = "anthropic/claude-opus-5"
        ompRequest.reasoningEffort = "high"
        _ = try await AgentCLIAdapter.run(
            request: ompRequest,
            executableURL: ompExecutable,
            progress: SkillRuntime.ProgressReporter { _ in }
        )
        let ompArguments = try String(contentsOf: ompArgumentsURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        XCTAssertTrue(ompArguments.contains("--model=anthropic/claude-opus-5"))
        XCTAssertFalse(
            ompArguments.contains { $0.hasPrefix("--thinking") },
            "OMP selection is model-only; no reasoning effort flag may be invented."
        )
        XCTAssertEqual(ompArguments.last { !$0.isEmpty }?.hasPrefix("@"), true)

        var rejectedRequest = ompRequest
        rejectedRequest.model = "--dangerously-skip-permissions"
        _ = try await AgentCLIAdapter.run(
            request: rejectedRequest,
            executableURL: ompExecutable,
            progress: SkillRuntime.ProgressReporter { _ in }
        )
        let sanitized = try String(contentsOf: ompArgumentsURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        XCTAssertFalse(
            sanitized.contains { $0.contains("dangerously-skip-permissions") },
            "A hostile model string must never reach the Agent argument vector."
        )
    }

    func testAgentEnvironmentUsesExplicitProviderAllowlist() {
        let runRoot = temporaryDirectory()
        let environment = AgentCLIAdapter.sanitizedEnvironment(
            [
                "ANTHROPIC_API_KEY": "model-provider-key",
                "GH_TOKEN": "github-secret",
                "GITHUB_TOKEN": "github-secret",
                "GHPR_SOCKET_PATH": "/tmp/private.sock",
                "GIT_ASKPASS": "/tmp/credential-helper",
                "HOME": "/Users/test",
                "JIRA_API_TOKEN": "jira-secret",
                "PATH": "/tmp/untrusted-bin",
                "PRDASHBOARD_GITHUB_TOKEN": "app-secret",
                "SSH_AUTH_SOCK": "/tmp/agent.sock",
                "UNRELATED_SECRET": "ambient-secret"
            ],
            runRoot: runRoot
        )

        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "model-provider-key")
        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertFalse(environment["PATH"]?.contains("/tmp/untrusted-bin") ?? true)
        XCTAssertTrue(environment["PATH"]?.contains("/usr/bin") == true)
        XCTAssertEqual(environment["PWD"], runRoot.path)
        XCTAssertEqual(environment["TMPDIR"], runRoot.path + "/")
        XCTAssertEqual(environment["NO_COLOR"], "1")
        XCTAssertEqual(environment["TERM"], "dumb")
        for deniedKey in [
            "GH_TOKEN",
            "GITHUB_TOKEN",
            "GHPR_SOCKET_PATH",
            "GIT_ASKPASS",
            "JIRA_API_TOKEN",
            "PRDASHBOARD_GITHUB_TOKEN",
            "SSH_AUTH_SOCK",
            "UNRELATED_SECRET"
        ] {
            XCTAssertNil(
                environment[deniedKey],
                "\(deniedKey) must not enter the Agent process."
            )
        }
    }

    func testStrictCodexManifestAllowsExecutionAndStartsInRunRoot() async throws {
        let manifest = """
        api_version: ghpr.dev/skill/v1
        id: dev.example.safe-codex
        version: 1.0.0
        display_name: Safe Codex
        targets:
          - pull_request
        execution:
          agents:
            - codex
          default_agent: codex
          isolation: strict
        result:
          schema: schemas/result.schema.json
        presentation:
          file: presentation/presentation.yaml
        """
        let parsed = try SkillPackageManager.parseManifest(manifest)
        XCTAssertEqual(parsed.definition.defaultAgent, .codex)
        XCTAssertTrue(parsed.definition.isRunnable, "A strict read-only Codex Skill must be runnable")

        let markerURL = temporaryDirectory().appendingPathComponent("codex-invocation")
        let executable = try executableScript(
            """
            #!/bin/sh
            {
              printf 'PWD=%s\\n' "$PWD"
              printf '%s\\n' "$@"
            } > "\(markerURL.path)"
            cat >/dev/null
            printf '%s\\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\\"status\\":\\"needs_investigation\\",\\"summary\\":\\"Codex started in the run root.\\"}"}}'
            """
        )
        var request = AgentExecutionRequest(
            skillID: "dev.example.safe-codex",
            displayName: "Safe Codex",
            agent: .codex,
            timeoutSeconds: 30,
            instructions: "Return a result.",
            resultSchema: Data(
                #"{"type":"object","required":["status","summary"],"properties":{"status":{"type":"string"},"summary":{"type":"string"}},"additionalProperties":false}"#.utf8
            ),
            context: AgentSkillInvocationContext.make(
                skillID: "dev.example.safe-codex",
                requestedSections: [],
                page: .pullRequest(repository: "owner/repo", number: 42),
                pullRequest: nil
            )
        )
        request.model = "gpt-5.4-mini"
        request.reasoningEffort = "high"
        let result = try await AgentCLIAdapter.run(
            request: request,
            executableURL: executable,
            progress: SkillRuntime.ProgressReporter { _ in }
        )
        XCTAssertEqual(result.summary, "Codex started in the run root.")

        let invocation = try String(contentsOf: markerURL, encoding: .utf8)
        let lines = invocation.components(separatedBy: .newlines)
        let pwd = try XCTUnwrap(lines.first { $0.hasPrefix("PWD=") })
        let runRoot = URL(fileURLWithPath: String(pwd.dropFirst(4)))
        let baseName = runRoot.deletingLastPathComponent().lastPathComponent
        XCTAssertEqual(baseName, "ghpr-skill-runs", "Codex must start with the private run root as its working directory")
        let arguments = Array(lines.dropFirst().filter { !$0.isEmpty })
        for required in [
            "exec",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--ephemeral",
            "--json",
            "-C",
            runRoot.path,
            "-m",
            "gpt-5.4-mini",
            "-c",
            "model_reasoning_effort=high",
            "-"
        ] {
            XCTAssertTrue(
                arguments.contains(required),
                "The Codex invocation must include \(required)."
            )
        }
        XCTAssertFalse(arguments.contains("--full-auto"))
        XCTAssertFalse(arguments.contains("workspace-write"))
        XCTAssertFalse(
            arguments.contains("--output-schema"),
            "Codex requires every schema property to be required, which breaks optional-field ghpr schemas; runtime validation covers the contract."
        )
        XCTAssertFalse(arguments.contains("@"), "Codex reads its prompt from stdin, not an OMP-style @ file.")

        var defaultRequest = request
        defaultRequest.model = nil
        defaultRequest.reasoningEffort = nil
        _ = try await AgentCLIAdapter.run(
            request: defaultRequest,
            executableURL: executable,
            progress: SkillRuntime.ProgressReporter { _ in }
        )
        let defaultArguments = try String(contentsOf: markerURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        XCTAssertFalse(
            defaultArguments.contains { $0.hasPrefix("model_reasoning_effort=") },
            "Without a selected effort, Codex must keep its own model default."
        )
        XCTAssertFalse(
            defaultArguments.contains("-m"),
            "Without a selected model, Codex must keep its own model default."
        )
    }
    func testStrictRuntimePackageRejectsCheckoutClaim() throws {
        let root = temporaryDirectory()
        let packageURL = try SkillPackageManager.scaffold(
            at: root,
            id: "dev.example.checkout-claim",
            displayName: "Checkout Claim"
        )
        let manifestURL = packageURL.appendingPathComponent("ghpr.skill.yaml")
        try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "checkout: none", with: "checkout: pr_head")
            .write(to: manifestURL, atomically: true, encoding: .utf8)

        let validation = SkillPackageManager.validate(at: packageURL)
        XCTAssertFalse(validation.valid)
        XCTAssertTrue(
            validation.issues.contains {
                $0.message.contains("workspace.checkout must be 'none'")
            },
            "Strict data-only Skills must not claim that ghpr supplies a checkout."
        )
    }


    func testCILogFetcherCleansANSIEscapesAndNormalizesLineEndings() throws {
        let raw = "\u{001B}[31mFAILED\u{001B}[0m spec\r\n\u{001B}]0;ghpr\u{0007}next\rprogress"
        XCTAssertEqual(
            CILogFetcher.cleanLog(raw),
            "FAILED spec\nnext\nprogress"
        )
        XCTAssertEqual(
            CILogFetcher.cleanLog("plain text, no escapes"),
            "plain text, no escapes"
        )
    }

    func testCILogFetcherSlicesAroundFirstFailureWithElisionMarkers() throws {
        let prefix = String(repeating: "startup banner\n", count: 400)
        let failure = "##[error]Unable to download artifact(s): not found\n"
        let suffix = String(repeating: "cleanup noise\n", count: 400)
        let text = prefix + failure + suffix
        let slice = CILogFetcher.sliceAroundFailure(text, byteLimit: 1024)
        XCTAssertTrue(slice.contains("Unable to download artifact"))
        XCTAssertTrue(slice.contains("bytes elided before first failure"))
        XCTAssertTrue(slice.contains("bytes elided after"))
        XCTAssertLessThanOrEqual(slice.utf8.count, 1024 + 256)
    }

    func testCILogFetcherSkipsFalsePositiveWordsBeforeRealError() throws {
        // "error" inside package names and "failed" inside env var names early
        // in the log must not anchor the slice; the ##[error] annotation is the
        // anchor, with neutral lines between the false positives and the failure.
        let prefix = String(repeating: "Installing libgpg-error (1.47-r2)\n", count: 200)
        let middle = String(repeating: "startup banner\n", count: 400)
        let failure = "##[error]Unable to download artifact(s): Artifact not found\n"
        let suffix = String(repeating: "cleanup\n", count: 300)
        let slice = CILogFetcher.sliceAroundFailure(
            prefix + middle + failure + suffix,
            byteLimit: 1024
        )
        XCTAssertTrue(slice.contains("Unable to download artifact"))
        XCTAssertFalse(slice.contains("libgpg-error"))
        XCTAssertTrue(slice.hasPrefix("… ("))
        XCTAssertTrue(slice.contains("bytes elided before first failure"))
    }

    func testCILogFetcherFallsBackToStrongFailureWordWhenNoAnnotation() throws {
        let prefix = String(repeating: "Installing libgpg-error (1.47-r2)\n", count: 300)
        let middle = String(repeating: "startup banner\n", count: 400)
        let failure = "FATAL:  role \"root\" does not exist\n"
        let suffix = String(repeating: "cleanup\n", count: 300)
        let slice = CILogFetcher.sliceAroundFailure(
            prefix + middle + failure + suffix,
            byteLimit: 1024
        )
        XCTAssertTrue(slice.contains("FATAL:  role \"root\" does not exist"))
        XCTAssertFalse(slice.contains("libgpg-error"))
        XCTAssertTrue(slice.contains("bytes elided before first failure"))
    }

    func testCILogFetcherTailTruncatesWhenNoFailureLineMatches() throws {
        let text = String(repeating: "no failures here\n", count: 500)
        let slice = CILogFetcher.sliceAroundFailure(text, byteLimit: 1024)
        XCTAssertTrue(slice.hasPrefix("… (truncated, showing last 1024 bytes)"))
        XCTAssertTrue(slice.contains("no failures here"))
        XCTAssertLessThanOrEqual(slice.utf8.count, 1024 + 256)
    }

    func testCILogFetcherLeavesSmallLogsUntouched() throws {
        let text = "one line\n"
        XCTAssertEqual(CILogFetcher.sliceAroundFailure(text, byteLimit: 1024), text)
        XCTAssertEqual(CILogFetcher.tailTruncate(text, byteLimit: 1024), text)
    }

    func testCILogFetcherExtractsRunAndJobIDsFromCheckLinks() throws {
        let jobLink = "https://github.com/Kong/kong-ee/actions/runs/123456789/job/987654321"
        XCTAssertEqual(CILogFetcher.extractRunID(from: jobLink), Int64(123456789))
        XCTAssertEqual(CILogFetcher.extractJobID(from: jobLink), Int64(987654321))

        let runLink = "https://github.com/Kong/kong-ee/actions/runs/123456789"
        XCTAssertEqual(CILogFetcher.extractRunID(from: runLink), Int64(123456789))
        XCTAssertNil(CILogFetcher.extractJobID(from: runLink))

        XCTAssertNil(CILogFetcher.extractRunID(from: "not-a-link"))
    }

    actor RequestRecorder {
        private(set) var request: AgentExecutionRequest?
        private(set) var fetchRepository: String?
        private(set) var fetchPRNumber: Int?
        private(set) var exactSubject: WorkflowJobSubject?

        func record(_ request: AgentExecutionRequest) {
            self.request = request
        }

        func recordFetch(repository: String, prNumber: Int) {
            fetchRepository = repository
            fetchPRNumber = prNumber
        }

        func recordExactSubject(_ subject: WorkflowJobSubject) {
            exactSubject = subject
        }
    }

    func testBuiltInSkillsFetchAndEmbedCIJobLogsInStrictContext() async throws {
        let root = temporaryDirectory()
        let store = ExtensionPlatformStore(storageURL: nil)
        let snapshot = LocalPRSnapshot(
            id: 42,
            section: .authored,
            repository: "owner/repo",
            number: 42,
            title: "Strip multipart metadata",
            author: "xiaocang",
            url: "https://github.com/owner/repo/pull/42",
            state: "OPEN",
            isDraft: false,
            isPinned: false,
            hasBaseConflicts: false,
            unresolvedCount: 0,
            ciStatus: "FAILURE",
            checkSuccessCount: 44,
            checkFailureCount: 6,
            checkPendingCount: 0,
            ciIsRunning: false,
            approvalCount: 0,
            changesRequestedCount: nil,
            myReviewStatus: nil,
            jiraTicket: nil,
            ciWorkflows: [
                LocalCIWorkflowSnapshot(
                    name: "Build & Test",
                    isWorkflow: true,
                    successCount: 44,
                    failureCount: 1,
                    pendingCount: 0
                )
            ],
            updatedAt: Date(),
            mergedAt: nil
        )
        let recorder = RequestRecorder()
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: root.appendingPathComponent("installed"),
            bundledSkillsRootURL: nil,
            agentRunner: { request, _ in
                await recorder.record(request)
                return SkillResult(
                    kind: .ciAnalysis,
                    title: "Likely related",
                    summary: "The log attributes the failure to a packaging step.",
                    analysis: nil,
                    codeReview: nil,
                    markdown: nil,
                    artifacts: [],
                    payload: .object([
                        "status": .string("likely_related"),
                        "summary": .string("The log attributes the failure to a packaging step."),
                        "evidence": .array([.string("Error: packaging failed")]),
                        "suggested_action": .string("Rerun the failed job.")
                    ])
                )
            },
            ciLogFetch: { repository, prNumber in
                await recorder.recordFetch(
                    repository: repository,
                    prNumber: prNumber
                )
                return FailedJobLogs(
                    repository: repository,
                    prNumber: prNumber,
                    workflowName: "Package & Release",
                    runID: Int64(123456789),
                    jobID: Int64(987654321),
                    capturedBytes: 1024,
                    truncated: false,
                    capturedOverflow: false,
                    fetchedAt: Date(),
                    content: "Error: packaging failed\n  at make-bundle.sh:12"
                )
            }
        )
        let queued = try runtime.start(
            skillID: SkillRuntime.classifyFlakySkillID,
            page: .pullRequest(repository: "owner/repo", number: 42),
            pullRequest: snapshot,
            requestedByClientID: "dev.ghpr.official-test"
        )
        let completed = try await terminalRun(store: store, id: queued.id)
        XCTAssertEqual(completed.status, .completed)
        let analysis = try XCTUnwrap(completed.result?.analysis)
        XCTAssertEqual(analysis.verdict, .likelyRelated)
        XCTAssertEqual(analysis.jobName, "Package & Release")
        XCTAssertEqual(analysis.summary, "The log attributes the failure to a packaging step.")
        guard case .object(let payload) = completed.result?.payload,
              case .object(let jobMetadata) = payload["_ghpr_job"] else {
            return XCTFail("The normalized result must retain its resolved workflow job.")
        }
        XCTAssertEqual(jobMetadata["repository"], .string("owner/repo"))
        XCTAssertEqual(jobMetadata["workflow_name"], .string("Package & Release"))
        XCTAssertEqual(jobMetadata["workflow_run_id"], .string("123456789"))
        XCTAssertEqual(jobMetadata["workflow_job_id"], .string("987654321"))


        let recorded = await recorder.request
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.skillID, SkillRuntime.classifyFlakySkillID)
        XCTAssertEqual(request.context.requestedSections, ["pr_metadata", "ci_status", "failed_job_logs"])
        XCTAssertFalse(
            request.context.unavailableSections.contains("failed_job_logs"),
            "The fetched log must mark failed_job_logs as available."
        )
        XCTAssertEqual(request.context.ciStatus?.failureCount, 6)
        let logs = try XCTUnwrap(request.context.failedJobLogs)
        XCTAssertEqual(logs.workflowName, "Package & Release")
        XCTAssertEqual(logs.jobID, Int64(987654321))
        XCTAssertTrue(logs.content.contains("packaging failed"))
        let fetchRepository = await recorder.fetchRepository
        let fetchPRNumber = await recorder.fetchPRNumber
        XCTAssertEqual(fetchRepository, "owner/repo")
        XCTAssertEqual(fetchPRNumber, 42)
    }


    func testExactWorkflowJobRunFetchesByCanonicalSubjectAndRejectsDuplicate() async throws {
        let store = ExtensionPlatformStore(storageURL: nil)
        let recorder = RequestRecorder()
        let subject = try WorkflowJobSubject(
            repository: "owner/repo",
            workflowRunID: 1001,
            workflowAttempt: 2,
            workflowJobID: 2001,
            headSHA: String(repeating: "a", count: 40)
        )
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: temporaryDirectory(),
            bundledSkillsRootURL: nil,
            agentRunner: { request, _ in
                await recorder.record(request)
                return SkillResult(
                    kind: .generic,
                    title: "Explain CI Failure",
                    summary: "The exact job failed.",
                    analysis: nil,
                    codeReview: nil,
                    markdown: nil,
                    artifacts: [],
                    payload: .object([
                        "status": .string("needs_investigation"),
                        "summary": .string("The exact job failed."),
                        "evidence": .array([.string("exit code 1")]),
                        "suggested_action": .string("Inspect the failing step.")
                    ])
                )
            },
            exactCILogFetch: { repository, prNumber, exactSubject in
                XCTAssertEqual(repository, "owner/repo")
                XCTAssertEqual(prNumber, 42)
                await recorder.recordExactSubject(exactSubject)
                return FailedJobLogs(
                    repository: repository,
                    prNumber: prNumber,
                    workflowName: nil,
                    runID: exactSubject.workflowRunID,
                    jobID: exactSubject.workflowJobID,
                    capturedBytes: 11,
                    truncated: false,
                    capturedOverflow: false,
                    fetchedAt: Date(),
                    content: "exit code 1"
                )
            }
        )
        let page = GitHubPageContext.pullRequest(repository: "owner/repo", number: 42)
        let queued = try runtime.start(
            skillID: SkillRuntime.explainFailureSkillID,
            page: page,
            pullRequest: nil,
            requestedByClientID: "dev.ghpr.test",
            subject: .workflowJob(subject),
            agent: .codex,
            model: "gpt-5.6",
            reasoningEffort: "high"
        )
        XCTAssertThrowsError(
            try runtime.start(
                skillID: SkillRuntime.explainFailureSkillID,
                page: page,
                pullRequest: nil,
                requestedByClientID: "dev.ghpr.test",
                subject: .workflowJob(subject)
            )
        ) { error in
            guard case SkillRuntime.RuntimeError.duplicateActiveRun = error else {
                return XCTFail("Expected duplicateActiveRun, got \(error)")
            }
        }

        let completed = try await terminalRun(store: store, id: queued.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.subject, .workflowJob(subject))
        let recordedSubject = await recorder.exactSubject
        XCTAssertEqual(recordedSubject, subject)
        let recordedRequest = await recorder.request
        let executionRequest = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(executionRequest.agent, .codex)
        XCTAssertEqual(executionRequest.model, "gpt-5.6")
        XCTAssertEqual(executionRequest.reasoningEffort, "high")
        guard case .object(let payload) = completed.result?.payload,
              case .string(let summary) = payload["summary"] else {
            return XCTFail("Expected the exact CI result payload.")
        }
        XCTAssertEqual(summary, "The exact job failed.")
    }

    func testReviewPRPersistsExactDiffFindings() async throws {
        let store = ExtensionPlatformStore(storageURL: nil)
        let recorder = RequestRecorder()
        let revision = try PullRequestRevisionSubject(
            repository: "owner/repo",
            prNumber: 42,
            baseSHA: String(repeating: "b", count: 40),
            headSHA: String(repeating: "a", count: 40)
        )
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: temporaryDirectory(),
            bundledSkillsRootURL: nil,
            agentRunner: { request, progress in
                await recorder.record(request)
                await progress(.executing)
                await progress.output("Inspecting Sources/Worker.swift")
                await progress(.receivingOutput)
                await progress.output("Finding: lost update at Sources/Worker.swift:18")
                return SkillResult(
                    kind: .generic,
                    title: "Review PR",
                    summary: "One correctness issue.",
                    analysis: nil,
                    codeReview: nil,
                    markdown: nil,
                    artifacts: [],
                    payload: .object([
                        "overview_markdown": .string("One correctness issue."),
                        "findings": .array([
                            .object([
                                "file": .string("Sources/Worker.swift"),
                                "start_line": .number(18),
                                "end_line": .number(18),
                                "side": .string("right"),
                                "title": .string("Lost update"),
                                "summary": .string("The write drops concurrent changes."),
                                "why": .string("Both tasks replace the same stale value."),
                                "suggested_fix": .string("Perform the mutation atomically."),
                                "quoted_code": .string("+state = next"),
                                "severity": .string("error"),
                                "confidence": .number(0.95),
                                "category": .string("concurrency")
                            ])
                        ])
                    ])
                )
            },
            reviewWorkspace: { subject in
                PRReviewWorkspace(
                    subject: subject,
                    checkoutURL: URL(fileURLWithPath: "/tmp/exact-review"),
                    diff: """
                    diff --git a/Sources/Worker.swift b/Sources/Worker.swift
                    --- a/Sources/Worker.swift
                    +++ b/Sources/Worker.swift
                    @@ -18,1 +18,1 @@
                    -state = current
                    +state = next
                    """,
                    reviewedFiles: ["Sources/Worker.swift"],
                    blobSHAs: ["Sources/Worker.swift": String(repeating: "c", count: 40)]
                )
            }
        )
        let queued = try runtime.start(
            skillID: SkillRuntime.reviewPRSkillID,
            page: .pullRequest(repository: "owner/repo", number: 42),
            pullRequest: nil,
            requestedByClientID: "dev.ghpr.test",
            subject: .pullRequestRevision(revision),
            agent: .codex,
            model: "gpt-5.6",
            reasoningEffort: "high"
        )
        let completed = try await terminalRun(store: store, id: queued.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.result?.kind, .codeReview)
        XCTAssertEqual(completed.result?.codeReview?.headSHA, revision.headSHA)
        XCTAssertEqual(completed.agent, .codex)
        XCTAssertEqual(completed.model, "gpt-5.6")
        XCTAssertEqual(completed.reasoningEffort, "high")
        XCTAssertEqual(completed.result?.codeReview?.findings.first?.file, "Sources/Worker.swift")
        let inputLines = completed.logEntries?
            .filter { $0.stream == .skillInput }
            .map(\.message) ?? []
        XCTAssertTrue(inputLines.contains("Skill: Review PR (pr.review)"))
        XCTAssertTrue(
            inputLines.contains {
                $0 == "Target: pull_request_revision · owner/repo#42 @ aaaaaaa"
            }
        )
        XCTAssertTrue(
            inputLines.contains {
                $0.hasPrefix("Diff: 1 file · ") && $0.hasSuffix(" bytes")
            }
        )
        XCTAssertTrue(inputLines.contains("File: Sources/Worker.swift"))
        let outputLines = completed.logEntries?
            .filter { $0.stream == .agentOutput }
            .map(\.message) ?? []
        XCTAssertTrue(outputLines.contains("Inspecting Sources/Worker.swift"))
        XCTAssertTrue(
            outputLines.contains("Finding: lost update at Sources/Worker.swift:18")
        )
        XCTAssertTrue(outputLines.contains("Overview: One correctness issue."))
        XCTAssertTrue(outputLines.contains("Findings: 1"))

        let finding = try XCTUnwrap(store.allFindings.first)
        XCTAssertEqual(finding.title, "Lost update")
        XCTAssertEqual(finding.lifecycle, .exact)
        guard case .diffLine(let anchor) = finding.subject else {
            return XCTFail("Expected an exact diff-line subject.")
        }
        XCTAssertEqual(anchor.baseSHA, revision.baseSHA)
        XCTAssertEqual(anchor.headSHA, revision.headSHA)
        XCTAssertEqual(anchor.side, .right)
        XCTAssertEqual(anchor.startLine, 18)
        XCTAssertEqual(anchor.endLine, 18)

        let recordedRequest = await recorder.request
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.context.reviewRevision?.baseSHA, revision.baseSHA)
        XCTAssertTrue(request.context.reviewRevision?.unifiedDiff.contains("state = next") == true)
        XCTAssertEqual(request.agent, .codex)
        XCTAssertEqual(request.model, "gpt-5.6")
        XCTAssertEqual(request.reasoningEffort, "high")
    }

    func testImportReviewPersistsCompletedRunAndMatchingFinding() throws {
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(store: store, installedSkillsRootURL: temporaryDirectory())
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let payload = LocalReviewImportPayload(
            baseSHA: String(repeating: "b", count: 40),
            headSHA: String(repeating: "a", count: 40),
            engine: "claude-code",
            overviewMarkdown: "## Overview\nOne correctness issue.",
            findings: [
                LocalReviewImportFinding(
                    file: "Sources/Worker.swift",
                    startLine: 18,
                    endLine: 18,
                    side: .right,
                    title: "Lost update",
                    summary: "The write drops concurrent changes.",
                    why: "Both tasks replace the same stale value.",
                    suggestedFix: "Perform the mutation atomically.",
                    background: nil,
                    quotedCode: "state = next",
                    severity: .error,
                    confidence: 0.95,
                    category: "concurrency"
                )
            ]
        )

        let revisionBefore = store.revision
        let result = try runtime.importReview(
            repository: "owner/repo",
            number: 42,
            payload: payload,
            now: now
        )

        XCTAssertFalse(result.alreadyImported)
        XCTAssertEqual(result.repository, "owner/repo")
        XCTAssertEqual(result.number, 42)
        XCTAssertEqual(result.headSHA, payload.headSHA)
        XCTAssertEqual(result.findingCount, 1)
        XCTAssertEqual(store.revision, revisionBefore + 1)

        let run = try XCTUnwrap(store.run(id: result.runID))
        XCTAssertEqual(run.skillID, SkillRuntime.reviewPRSkillID)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.requestedByClientID, "mcp-ghpr")
        XCTAssertEqual(run.result?.kind, .codeReview)
        XCTAssertEqual(run.result?.codeReview?.engine, "claude-code")
        XCTAssertEqual(run.result?.codeReview?.reviewedBaseSHA, payload.baseSHA)
        XCTAssertEqual(run.result?.codeReview?.reviewedHeadSHA, payload.headSHA)
        XCTAssertEqual(run.result?.codeReview?.headSHA, payload.headSHA)

        let displayFinding = try XCTUnwrap(run.result?.codeReview?.findings.first)
        let persistedFinding = try XCTUnwrap(store.allFindings.first)
        XCTAssertEqual(displayFinding.id, persistedFinding.id)
        XCTAssertEqual(persistedFinding.lifecycle, .exact)
        guard case .diffLine(let anchor) = persistedFinding.subject else {
            return XCTFail("Expected an exact diff-line subject.")
        }
        XCTAssertEqual(anchor.repository, "owner/repo")
        XCTAssertEqual(anchor.prNumber, 42)
        XCTAssertEqual(anchor.baseSHA, payload.baseSHA)
        XCTAssertEqual(anchor.headSHA, payload.headSHA)
        XCTAssertEqual(anchor.filePath, "Sources/Worker.swift")
        XCTAssertEqual(anchor.side, .right)
        XCTAssertEqual(anchor.startLine, 18)
        XCTAssertEqual(anchor.endLine, 18)
    }

    func testImportReviewIsIdempotentForIdenticalPayload() throws {
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(store: store, installedSkillsRootURL: temporaryDirectory())
        let payload = LocalReviewImportPayload(
            baseSHA: String(repeating: "b", count: 40),
            headSHA: String(repeating: "a", count: 40),
            engine: "claude-code",
            overviewMarkdown: "## Overview\nAll good.",
            findings: [
                LocalReviewImportFinding(
                    file: "Sources/Worker.swift",
                    startLine: 18,
                    endLine: 18,
                    side: .right,
                    title: "Lost update",
                    summary: "The write drops concurrent changes.",
                    why: nil,
                    suggestedFix: nil,
                    background: nil,
                    quotedCode: nil,
                    severity: .warning,
                    confidence: 0.5,
                    category: "concurrency"
                )
            ]
        )

        let first = try runtime.importReview(repository: "owner/repo", number: 42, payload: payload)
        let revisionAfterFirst = store.revision
        let runCountAfterFirst = store.allRuns.count
        let findingCountAfterFirst = store.allFindings.count

        let second = try runtime.importReview(repository: "owner/repo", number: 42, payload: payload)

        XCTAssertEqual(second.runID, first.runID)
        XCTAssertTrue(second.alreadyImported)
        XCTAssertFalse(first.alreadyImported)
        XCTAssertEqual(store.revision, revisionAfterFirst)
        XCTAssertEqual(store.allRuns.count, runCountAfterFirst)
        XCTAssertEqual(store.allFindings.count, findingCountAfterFirst)
    }

    func testImportReviewRejectsInvalidFindingWithoutPartialWrite() {
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(store: store, installedSkillsRootURL: temporaryDirectory())
        let payload = LocalReviewImportPayload(
            baseSHA: String(repeating: "b", count: 40),
            headSHA: String(repeating: "a", count: 40),
            engine: "claude-code",
            overviewMarkdown: "## Overview\nAll good.",
            findings: [
                LocalReviewImportFinding(
                    file: "Sources/Worker.swift",
                    startLine: 20,
                    endLine: 10,
                    side: .right,
                    title: "Invalid range",
                    summary: "end_line is before start_line.",
                    why: nil,
                    suggestedFix: nil,
                    background: nil,
                    quotedCode: nil,
                    severity: .warning,
                    confidence: 0.5,
                    category: "concurrency"
                )
            ]
        )

        let revisionBefore = store.revision
        XCTAssertThrowsError(
            try runtime.importReview(repository: "owner/repo", number: 42, payload: payload)
        ) { error in
            XCTAssertTrue(error is LocalReviewImportError)
        }
        XCTAssertEqual(store.revision, revisionBefore)
        XCTAssertTrue(store.allRuns.isEmpty)
        XCTAssertTrue(store.allFindings.isEmpty)
    }

    func testRerunFailedJobsRequiresConfirmationButNotSkillRun() async throws {
        let store = ExtensionPlatformStore(storageURL: nil)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: temporaryDirectory(),
            bundledSkillsRootURL: nil
        )
        let pullRequest = LocalPRSnapshot(
            id: 42,
            section: .authored,
            repository: "owner/repo",
            number: 42,
            title: "Make CI deterministic",
            author: "xiaocang",
            url: "https://github.com/owner/repo/pull/42",
            state: "OPEN",
            isDraft: false,
            isPinned: false,
            hasBaseConflicts: false,
            unresolvedCount: 0,
            ciStatus: "FAILURE",
            checkSuccessCount: 1,
            checkFailureCount: 2,
            checkPendingCount: 0,
            ciIsRunning: false,
            approvalCount: 0,
            changesRequestedCount: nil,
            myReviewStatus: nil,
            jiraTicket: nil,
            ciWorkflows: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            mergedAt: nil
        )
        var rerunRequests: [Int] = []
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: { Self.snapshot(authored: [pullRequest]) },
            rerunFailedJobs: { requested in
                rerunRequests.append(requested.number)
                return 2
            },
            assetProvider: BrowserAssetProvider(roots: []),
            appVersion: "1.0",
            draftsRootURL: temporaryDirectory()
        )
        let baseURL = URL(string: "http://127.0.0.1:48120")!
        let token = try approveClient(
            store: store,
            id: "dev.ghpr.checks-only",
            scopes: [.prRead, .ciRead]
        )
        func rerun(confirmed: Bool?) async throws -> BrowserHTTPResponse {
            await router.response(
                for: BrowserHTTPRequest(
                    method: "POST",
                    target: "/api/v1/actions",
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "application/json"
                    ],
                    body: try BrowserJSON.encode(
                        ActionEnvelope(
                            page: .pullRequest(repository: "owner/repo", number: 42),
                            action: BrowserAction(
                                kind: .rerunFailedJobs,
                                skillID: nil,
                                runID: nil,
                                analysisID: nil,
                                tag: nil,
                                event: nil
                            ),
                            confirmed: confirmed
                        )
                    )
                ),
                baseURL: baseURL
            )
        }

        let unconfirmed = try await rerun(confirmed: nil)
        XCTAssertEqual(
            unconfirmed.status,
            409,
            "Rerunning GitHub jobs must still require explicit confirmation"
        )
        XCTAssertTrue(rerunRequests.isEmpty)

        let confirmed = try await rerun(confirmed: true)
        XCTAssertEqual(
            confirmed.status,
            200,
            "A confirmed rerun must not require the skill:run scope"
        )
        XCTAssertEqual(rerunRequests, [42])
    }

    private func approveClient(
        store: ExtensionPlatformStore,
        id: String,
        scopes: Set<BrowserScope>
    ) throws -> String {
        let started = try store.startPairing(
            descriptor: BrowserClientDescriptor(
                id: id,
                name: id,
                version: "1.0.0",
                requestedScopes: scopes
            ),
            bridgeBaseURL: URL(string: "http://127.0.0.1:48120")!
        )
        _ = try store.approvePairingFromNative(
            id: started.requestID,
            approvedScopes: scopes
        )
        return try XCTUnwrap(
            store.pollPairing(
                id: started.requestID,
                secret: started.pairingSecret
            ).token
        )
    }

    private func executableScript(_ source: String) throws -> URL {
        let url = temporaryDirectory().appendingPathComponent("agent")
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }

    private func terminalRun(
        store: ExtensionPlatformStore,
        id: String
    ) async throws -> SkillRun {
        for _ in 0..<500 {
            if let run = store.run(id: id), run.status.isTerminal {
                return run
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(
            domain: "BrowserBridgeTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Skill run \(id)."]
        )
    }

    @MainActor
    func testCatalogWarmUpProbesEveryUncachedProbeCapableAgent() async throws {
        let cachedClaude = AgentCapabilityCatalog(
            agent: .claudeCode,
            models: [AgentModelOption(slug: "cached", displayName: "Cached", detail: nil, defaultEffort: nil, reasoningEfforts: [])],
            reasoningEfforts: [],
            listsModels: true,
            listsReasoningEfforts: false,
            source: "cache",
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var probed: [SkillAgent] = []
        let controller = ExtensionPlatformController(
            snapshotProvider: { Self.emptySnapshot() },
            storageURL: nil,
            appVersion: "1.0.0",
            agentCapabilityProbe: { agent in
                probed.append(agent)
                return AgentCapabilityCatalog(
                    agent: agent,
                    models: [AgentModelOption(
                        slug: "gpt-5.6",
                        displayName: "GPT-5.6",
                        detail: nil,
                        defaultEffort: "high",
                        reasoningEfforts: [AgentReasoningEffortOption(effort: "high", detail: "Thorough")]
                    )],
                    reasoningEfforts: [AgentReasoningEffortOption(effort: "high", detail: "Thorough")],
                    listsModels: true,
                    listsReasoningEfforts: true,
                    source: "probe",
                    refreshedAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
            }
        )
        controller.store.save(agentCapabilityCatalog: cachedClaude)

        await controller.warmAgentCapabilityCatalogs()

        XCTAssertEqual(probed, [.codex], "Only uncached probe-capable agents may be probed")
        XCTAssertEqual(
            controller.cachedAgentCapabilityCatalog(for: .codex)?.models.first?.slug,
            "gpt-5.6",
            "The review dialog reads codex models from the cached catalog"
        )
        XCTAssertEqual(
            controller.cachedAgentCapabilityCatalog(for: .claudeCode)?.models.first?.slug,
            "cached",
            "An existing catalog must not be re-probed or overwritten"
        )
        XCTAssertNil(controller.cachedAgentCapabilityCatalog(for: .omp))

        await controller.warmAgentCapabilityCatalogs()
        XCTAssertEqual(probed, [.codex], "Warm-up must run once per launch")
    }

    private func decodeValue<Value: Codable & Equatable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        try BrowserJSON.decode(Value.self, from: data)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghpr-browser-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private static func emptySnapshot() -> LocalSnapshot {
        snapshot(authored: [])
    }

    private static func snapshot(authored: [LocalPRSnapshot]) -> LocalSnapshot {
        LocalSnapshot(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            app: LocalAppSnapshot(
                version: "1.0",
                build: "1",
                bundleIdentifier: "com.example.tests"
            ),
            auth: LocalAuthSnapshot(
                isAuthenticated: true,
                username: "octocat",
                method: "pat"
            ),
            refresh: LocalRefreshSnapshot(
                status: "idle",
                isLoading: false,
                lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
                error: nil
            ),
            rateLimit: LocalRateLimitSnapshot(
                limit: 5_000,
                remaining: 4_999,
                resetAt: Date(timeIntervalSince1970: 1_700_003_600),
                isLow: false
            ),
            summary: LocalSummarySnapshot(
                authored: 0,
                reviewRequests: 0,
                mentioned: 0,
                directMentions: 0,
                mergedLast24h: 0,
                totalUnresolved: 0,
                authoredUnresolved: 0,
                readyToMerge: 0,
                changesRequested: 0,
                ciFailing: 0,
                ciRunning: 0,
                waitingForMyReview: 0
            ),
            pullRequests: LocalPRSectionsSnapshot(
                authored: authored,
                reviewRequests: [],
                mentioned: [],
                directMentions: [],
                mergedLast24h: []
            )
        )
    }
}
