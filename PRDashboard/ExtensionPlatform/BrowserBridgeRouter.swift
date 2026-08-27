import Foundation
import AppKit

struct BrowserHTTPRequest: Equatable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    init(
        method: String,
        target: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method.uppercased()
        self.target = target
        self.headers = Dictionary(
            uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }
        )
        self.body = body
    }

    var urlComponents: URLComponents? {
        URLComponents(string: "http://127.0.0.1\(target)")
    }

    var path: String {
        urlComponents?.path ?? target
    }

    func queryValue(_ name: String) -> String? {
        urlComponents?.queryItems?.first { $0.name == name }?.value
    }

    var bearerToken: String? {
        guard let authorization = headers["authorization"],
              authorization.lowercased().hasPrefix("bearer ") else {
            return nil
        }
        return String(authorization.dropFirst(7))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct BrowserHTTPResponse: Equatable {
    let status: Int
    var headers: [String: String]
    let body: Data

    static func text(
        _ text: String,
        status: Int = 200,
        contentType: String = "text/plain; charset=utf-8"
    ) -> BrowserHTTPResponse {
        BrowserHTTPResponse(
            status: status,
            headers: [
                "Content-Type": contentType,
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff"
            ],
            body: Data(text.utf8)
        )
    }
}

struct BrowserAssetProvider {
    let roots: [URL]

    init(roots: [URL]) {
        self.roots = roots
    }

    static func bundled() -> BrowserAssetProvider {
        guard let resourceURL = Bundle.main.resourceURL else {
            return BrowserAssetProvider(roots: [])
        }
        return BrowserAssetProvider(roots: [resourceURL])
    }

    func data(relativePath: String) -> Data? {
        url(relativePath: relativePath).flatMap { try? Data(contentsOf: $0) }
    }

    func url(relativePath: String) -> URL? {
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else {
            return nil
        }
        for root in roots {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let flattened = root.appendingPathComponent(
                URL(fileURLWithPath: relativePath).lastPathComponent
            )
            if FileManager.default.fileExists(atPath: flattened.path) {
                return flattened
            }
        }
        return nil
    }
}

@MainActor
final class BrowserBridgeRouter {
    typealias SnapshotProvider = @MainActor () -> LocalSnapshot
    typealias ApplicationIconProvider = @MainActor () -> Data?
    typealias RerunFailedJobsHandler = @MainActor (LocalPRSnapshot) async throws -> Int

    private struct EmptyResponse: Codable, Equatable {
        let ok: Bool
    }


    private struct RunSkillBody: Codable {
        let skillID: String
        let page: GitHubPageContext
    }

    private struct TagBody: Codable {
        let pageKey: String
        let tag: PRTag
    }

    private struct TagsResponse: Codable, Equatable {
        let tags: Set<PRTag>
    }

    private struct RunsResponse: Codable, Equatable {
        let runs: [SkillRun]
    }

    private struct SkillsResponse: Codable, Equatable {
        let skills: [SkillDefinition]
    }

    private struct AnalysesResponse: Codable, Equatable {
        let analyses: [CIAnalysis]
    }

    private struct ContributionsResponse: Codable, Equatable {
        let contributions: [BrowserContribution]
    }

    private struct EventsResponse: Codable, Equatable {
        let events: [BrowserEvent]
        let cursor: Int64
    }

    private struct SlotHealthBody: Codable {
        let pageKey: String
        let slot: BrowserSlot
        let healthy: Bool
        let detail: String?
    }

    private struct OpenDetailResponse: Codable, Equatable {
        let url: String
    }

    private struct ActionBody: Codable {
        let page: GitHubPageContext
        let action: BrowserAction
        let confirmed: Bool?
    }

    private struct ActionResponse: Codable, Equatable {
        let run: SkillRun?
        let url: String?
        let tags: Set<PRTag>?
        let rerunCount: Int?
        let event: BrowserEvent?
    }

    private struct WorkbenchRequest: Codable {
        let operation: String
        let id: String?
        let displayName: String?
        let sourcePath: String?
        let packagePath: String?
        let slot: BrowserSlot?
        let agents: Set<SkillAgent>?
        let files: [String: String]?
    }

    private struct WorkbenchResponse: Codable, Equatable {
        let path: String?
        let validation: SkillPackageValidation?
        let installStatuses: [WorkbenchInstallStatus]?
        let preview: WorkbenchPreview?
    }

    private struct WorkbenchDiscoveryResponse: Codable, Equatable {
        let skills: [DiscoveredAgentSkill]
    }


    private struct WorkbenchPreview: Codable, Equatable {
        let id: String
        let version: String
        let displayName: String
        let manifest: String
        let resultSchema: String
        let presentation: String
        let browserContributions: String?
        let expectedResult: String?
        let requestedCapabilities: [String]
    }

    private struct WorkbenchInstallStatus: Codable, Equatable {
        let agent: SkillAgent
        let path: String
        let installed: Bool
    }

    let store: ExtensionPlatformStore
    let runtime: SkillRuntime

    private let snapshotProvider: SnapshotProvider
    private let rerunFailedJobs: RerunFailedJobsHandler?
    private let assetProvider: BrowserAssetProvider
    private let applicationIconProvider: ApplicationIconProvider
    private let appVersion: String
    private let draftsRootURL: URL
    private let agentSkillsHomeURL: URL

    init(
        store: ExtensionPlatformStore,
        runtime: SkillRuntime,
        snapshotProvider: @escaping SnapshotProvider,
        rerunFailedJobs: RerunFailedJobsHandler? = nil,
        assetProvider: BrowserAssetProvider = .bundled(),
        appVersion: String,
        draftsRootURL: URL? = nil,
        agentSkillsHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationIconProvider: @escaping ApplicationIconProvider =
            BrowserBridgeRouter.defaultApplicationIconPNG
    ) {
        self.store = store
        self.runtime = runtime
        self.snapshotProvider = snapshotProvider
        self.rerunFailedJobs = rerunFailedJobs
        self.assetProvider = assetProvider
        self.applicationIconProvider = applicationIconProvider
        self.appVersion = appVersion
        self.draftsRootURL = draftsRootURL ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ghpr/drafts", isDirectory: true)
        self.agentSkillsHomeURL = agentSkillsHomeURL
    }

    private var officialUserscriptVersion: String? {
        guard let data = assetProvider.data(relativePath: "browser/ghpr.user.js"),
              let script = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in script.split(separator: "\n", omittingEmptySubsequences: false).prefix(20) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 3, fields[0] == "//", fields[1] == "@version" {
                return String(fields[2])
            }
        }
        return nil
    }

    func response(
        for request: BrowserHTTPRequest,
        baseURL: URL
    ) async -> BrowserHTTPResponse {
        if request.method == "OPTIONS" {
            return preflightResponse(for: request)
        }
        if request.path.hasPrefix("/api/"),
           let origin = request.headers["origin"],
           !isAllowedOrigin(origin, baseURL: baseURL) {
            return error(status: 403, code: "origin_forbidden", message: "Origin is not allowed.")
        }

        let response: BrowserHTTPResponse
        do {
            response = try await route(request, baseURL: baseURL)
        } catch RouterError.unauthorized {
            response = error(
                status: 401,
                code: "unauthorized",
                message: "A valid browser capability token is required."
            )
        } catch RouterError.scopeDenied(let scopes) {
            response = error(
                status: 403,
                code: "scope_denied",
                message: "Missing scope: \(scopes.map(\.rawValue).joined(separator: ", "))."
            )
        } catch {
            response = self.error(
                status: 400,
                code: "invalid_request",
                message: error.localizedDescription
            )
        }
        return addingCORSHeaders(response, request: request, baseURL: baseURL)
    }

    private func route(
        _ request: BrowserHTTPRequest,
        baseURL: URL
    ) async throws -> BrowserHTTPResponse {
        if request.method == "GET", request.path == "/.well-known/ghpr-browser-bridge" {
            return json(
                BrowserBridgeDiscovery(
                    protocolName: GHPRContract.bridgeProtocol,
                    instanceID: store.instanceID,
                    appVersion: appVersion,
                    officialUserscriptVersion: officialUserscriptVersion,
                    apiVersions: [GHPRContract.bridgeAPIVersion],
                    pairingRequired: true
                )
            )
        }

        if request.method == "GET", request.path == "/install/ghpr.user.js" {
            return asset(
                relativePath: "browser/ghpr.user.js",
                contentType: "application/javascript; charset=utf-8"
            )
        }
        if request.method == "GET", request.path == "/install/ghpr-sdk.js" {
            return asset(
                relativePath: "userscript-sdk/index.js",
                contentType: "application/javascript; charset=utf-8"
            )
        }
        if request.method == "GET", request.path == "/assets/app.js" {
            return asset(
                relativePath: "browser/app.js",
                contentType: "application/javascript; charset=utf-8"
            )
        }
        if request.method == "GET", request.path == "/assets/styles.css" {
            return asset(relativePath: "browser/styles.css", contentType: "text/css; charset=utf-8")
        }
        if request.method == "GET", request.path == "/assets/app-icon.png" {
            return applicationIcon()
        }


        if request.method == "GET",
           request.path == "/ui" || request.path == "/ui/" {
            return htmlShell(title: "Browser Bridge", page: "home")
        }

        let components = request.path.split(separator: "/").map(String.init)
        if request.method == "GET",
           components.count == 3,
           components[0] == "ui",
           components[1] == "pair" {
            return htmlShell(title: "Connect to ghpr", page: "pairing")
        }
        if request.method == "GET",
           components.count == 3,
           components[0] == "ui",
           components[1] == "analysis" {
            return htmlShell(title: "CI Analysis", page: "analysis")
        }
        if request.method == "GET",
           components.count == 3,
           components[0] == "ui",
           components[1] == "run" {
            return htmlShell(title: "Skill Run", page: "run")
        }
        if request.method == "GET", request.path == "/ui/workbench" {
            return htmlShell(title: "Skill Workbench", page: "workbench")
        }
        if request.method == "GET", request.path == "/ui/github-preview" {
            return htmlShell(title: "GitHub PR Integration Preview", page: "github-preview")
        }
        if request.method == "GET", request.path == "/ui/browser-test" {
            return htmlShell(title: "Browser Integration Test", page: "browser-test")
        }

        if request.method == "POST", request.path == "/api/v1/pairings" {
            let descriptor = try BrowserJSON.decode(BrowserClientDescriptor.self, from: request.body)
            return json(
                try store.startPairing(descriptor: descriptor, bridgeBaseURL: baseURL),
                status: 201
            )
        }
        if components.count == 4,
           components[0] == "api",
           components[1] == "v1",
           components[2] == "pairings",
           let secret = request.queryValue("secret"),
           request.method == "GET" {
            return json(try store.pollPairing(id: components[3], secret: secret))
        }

        if request.method == "GET", request.path == "/api/v1/local-capability" {
            guard let capability = store.localCapability(token: request.bearerToken) else {
                return error(status: 401, code: "unauthorized", message: "A local capability is required.")
            }
            return json(capability)
        }

        if components.count == 5,
           components[0] == "api",
           components[1] == "v1",
           components[2] == "pairings",
           components[4] == "status",
           request.method == "GET",
           let secret = request.queryValue("secret") {
            return json(try store.pairingStatus(id: components[3], secret: secret))
        }
        if components.count == 5,
           components[0] == "api",
           components[1] == "v1",
           components[2] == "pairings",
           components[4] == "descriptor",
           request.method == "GET",
           let secret = request.queryValue("secret") {
            return json(try store.pairingRequest(id: components[3], secret: secret))
        }

        if request.method == "GET", request.path == "/api/v1/contracts/capabilities" {
            return json(ContractCapabilities.current)
        }

        if request.method == "GET", request.path == "/api/v1/client" {
            let client = try authenticatedClient(request)
            return json(client)
        }
        if request.method == "GET", request.path == "/api/v1/page" {
            let client = try authenticatedClient(request, requiring: [.prRead])
            guard let page = pageContext(from: request) else {
                return error(
                    status: 400,
                    code: "missing_page",
                    message: "repository plus number or run_id are required."
                )
            }
            let snapshot = snapshotProvider()
            let pullRequest = page.prNumber.flatMap {
                LocalAPIHandler.findPullRequest(
                    in: snapshot,
                    repository: page.repository,
                    number: $0
                )
            }
            let contributions: [BrowserContribution]
            if client.scopes.contains(.uiContribute) {
                store.replaceManagedContributions(
                    clientID: client.id,
                    pageKey: page.key,
                    idPrefix: "skill.",
                    registrations: runtime.declarativeContributions(
                        page: page,
                        pullRequest: pullRequest
                    )
                )
                contributions = store.contributions(pageKey: page.key)
            } else {
                contributions = []
            }
            return json(
                PageExtensionSnapshot(
                    page: page,
                    pullRequest: pullRequest,
                    analyses: client.scopes.contains(.analysisRead) ? store.analyses(pageKey: page.key) : [],
                    tags: client.scopes.contains(.tagRead) ? store.tags(for: page.key) : [],
                    runs: client.scopes.contains(.analysisRead)
                        ? store.runs(pageKey: page.key).map {
                            runForResponse(
                                $0,
                                includeArtifacts: client.scopes.contains(.artifactRead)
                            )
                        }
                        : [],
                    skills: client.scopes.contains(.skillList) ? runtime.skills : [],
                    contributions: contributions
                )
            )
        }
        if request.method == "GET", request.path == "/api/v1/skills" {
            _ = try authenticatedClient(request, requiring: [.skillList])
            return json(SkillsResponse(skills: runtime.skills))
        }
        if request.method == "POST", request.path == "/api/v1/runs" {
            let client = try authenticatedClient(request, requiring: [.skillRun])
            let body = try BrowserJSON.decode(RunSkillBody.self, from: request.body)
            let pullRequest = pullRequest(for: body.page)
            return json(
                runForResponse(
                    try runtime.start(
                        skillID: body.skillID,
                        page: body.page,
                        pullRequest: pullRequest,
                        requestedByClientID: client.id
                    ),
                    includeArtifacts: client.scopes.contains(.artifactRead)
                )
            )
        }
        if request.method == "GET", request.path == "/api/v1/runs" {
            let client = try authenticatedClient(request, requiring: [.analysisRead])
            guard let pageKey = request.queryValue("page_key") else {
                return error(status: 400, code: "missing_page_key", message: "page_key is required.")
            }
            let includeArtifacts = client.scopes.contains(.artifactRead)
            return json(
                RunsResponse(
                    runs: store.runs(pageKey: pageKey).map {
                        runForResponse($0, includeArtifacts: includeArtifacts)
                    }
                )
            )
        }
        if components.count == 5,
           components[0] == "api",
           components[1] == "v1",
           components[2] == "runs" {
            let runID = components[3]
            if components[4] == "cancel", request.method == "POST" {
                let client = try authenticatedClient(request, requiring: [.skillCancel])
                return json(
                    runForResponse(
                        try runtime.cancel(runID: runID),
                        includeArtifacts: client.scopes.contains(.artifactRead)
                    )
                )
            }
            if components[4] == "retry", request.method == "POST" {
                let client = try authenticatedClient(request, requiring: [.skillRun])
                guard let run = store.run(id: runID) else {
                    return error(status: 404, code: "run_not_found", message: "Run was not found.")
                }
                return json(
                    runForResponse(
                        try runtime.retry(
                            runID: runID,
                            pullRequest: pullRequest(for: run.page),
                            requestedByClientID: client.id
                        ),
                        includeArtifacts: client.scopes.contains(.artifactRead)
                    )
                )
            }
            if components[4] == "open-detail", request.method == "POST" {
                _ = try authenticatedClient(request, requiring: [.detailOpen])
                return json(try runDetailURL(runID: runID, baseURL: baseURL))
            }
        }
        if components.count == 4,
           components[0] == "api",
           components[1] == "v1",
           components[2] == "runs",
           request.method == "GET" {
            let runID = components[3]
            let browserClient = store.authenticate(
                bearerToken: request.bearerToken,
                requiring: [.analysisRead]
            )?.client
            let detailAuthorized = store.validateLocalGrant(
                token: request.bearerToken,
                kind: .run,
                resourceID: runID
            )
            guard browserClient != nil || detailAuthorized else {
                return error(status: 401, code: "unauthorized", message: "A valid run capability is required.")
            }
            guard let run = store.run(id: runID) else {
                return error(status: 404, code: "run_not_found", message: "Run was not found.")
            }
            return json(
                runForResponse(
                    run,
                    includeArtifacts: detailAuthorized ||
                        (browserClient?.scopes.contains(.artifactRead) == true)
                )
            )
        }

        if request.method == "GET", request.path == "/api/v1/analyses" {
            _ = try authenticatedClient(request, requiring: [.analysisRead])
            guard let pageKey = request.queryValue("page_key") else {
                return error(status: 400, code: "missing_page_key", message: "page_key is required.")
            }
            return json(AnalysesResponse(analyses: store.analyses(pageKey: pageKey)))
        }
        if components.count == 4,
           components[0] == "api",
           components[1] == "v1",
           components[2] == "analyses",
           request.method == "GET" {
            let analysisID = components[3]
            let browserAuthorized = store.authenticate(
                bearerToken: request.bearerToken,
                requiring: [.analysisRead]
            ) != nil
            let detailAuthorized = store.validateLocalGrant(
                token: request.bearerToken,
                kind: .analysis,
                resourceID: analysisID
            )
            guard browserAuthorized || detailAuthorized else {
                return error(status: 401, code: "unauthorized", message: "A valid analysis capability is required.")
            }
            guard let analysis = store.analysis(id: analysisID) else {
                return error(status: 404, code: "analysis_not_found", message: "Analysis was not found.")
            }
            return json(analysis)
        }
        if components.count == 5,
           components[0] == "api",
           components[1] == "v1",
           components[2] == "analyses",
           components[4] == "open-detail",
           request.method == "POST" {
            _ = try authenticatedClient(request, requiring: [.detailOpen])
            return json(try detailURL(analysisID: components[3], baseURL: baseURL))
        }

        if request.path == "/api/v1/tags" {
            if request.method == "GET" {
                _ = try authenticatedClient(request, requiring: [.tagRead])
                guard let pageKey = request.queryValue("page_key") else {
                    return error(status: 400, code: "missing_page_key", message: "page_key is required.")
                }
                return json(TagsResponse(tags: store.tags(for: pageKey)))
            }
            let client = try authenticatedClient(request, requiring: [.tagWrite])
            let body = try BrowserJSON.decode(TagBody.self, from: request.body)
            if request.method == "PUT" {
                store.setTag(body.tag, pageKey: body.pageKey, clientID: client.id)
            } else if request.method == "DELETE" {
                store.removeTag(body.tag, pageKey: body.pageKey, clientID: client.id)
            } else {
                return methodNotAllowed()
            }
            return json(TagsResponse(tags: store.tags(for: body.pageKey)))
        }

        if request.method == "POST", request.path == "/api/v1/contributions" {
            let client = try authenticatedClient(request, requiring: [.uiContribute])
            let registration = try BrowserJSON.decode(ContributionRegistration.self, from: request.body)
            return json(store.registerContribution(clientID: client.id, registration: registration))
        }
        if request.method == "GET", request.path == "/api/v1/contributions" {
            _ = try authenticatedClient(request, requiring: [.uiContribute])
            guard let pageKey = request.queryValue("page_key") else {
                return error(status: 400, code: "missing_page_key", message: "page_key is required.")
            }
            return json(ContributionsResponse(contributions: store.contributions(pageKey: pageKey)))
        }
        if components.count == 4,
           components[0] == "api",
           components[1] == "v1",
           components[2] == "contributions",
           request.method == "DELETE" {
            let client = try authenticatedClient(request, requiring: [.uiContribute])
            store.unregisterContribution(
                clientID: client.id,
                id: components[3],
                pageKey: request.queryValue("page_key")
            )
            return json(EmptyResponse(ok: true))
        }
        if components.count == 6,
           components[0] == "api",
           components[1] == "v1",
           components[2] == "contributions",
           components[5] == "invoke",
           request.method == "POST" {
            let caller = try authenticatedClient(request, requiring: [.uiContribute])
            guard let pageKey = request.queryValue("page_key") else {
                return error(status: 400, code: "missing_page_key", message: "page_key is required.")
            }
            return await invokeContribution(
                clientID: components[3],
                pageKey: pageKey,
                contributionID: components[4],
                caller: caller,
                baseURL: baseURL
            )
        }
        if request.method == "POST", request.path == "/api/v1/slot-health" {
            let client = try authenticatedClient(request, requiring: [.uiContribute])
            let body = try BrowserJSON.decode(SlotHealthBody.self, from: request.body)
            store.reportSlotHealth(
                clientID: client.id,
                pageKey: body.pageKey,
                slot: body.slot,
                healthy: body.healthy,
                detail: body.detail
            )
            return json(EmptyResponse(ok: true))
        }
        if request.method == "GET", request.path == "/api/v1/events" {
            let client = try authenticatedClient(request, requiring: [.uiContribute])
            let cursor = Int64(request.queryValue("cursor") ?? "") ?? 0
            let events = store.events(clientID: client.id, after: cursor)
            return json(EventsResponse(events: events, cursor: events.last?.id ?? cursor))
        }
        if request.method == "POST", request.path == "/api/v1/actions" {
            let client = try authenticatedClient(request)
            let body = try BrowserJSON.decode(ActionBody.self, from: request.body)
            return await perform(
                action: body.action,
                page: body.page,
                client: client,
                confirmed: body.confirmed == true,
                baseURL: baseURL
            )
        }

        if request.method == "POST", request.path == "/api/v1/workbench" {
            guard store.validateLocalGrant(
                token: request.bearerToken,
                kind: .workbench,
                resourceID: nil
            ) else {
                return error(status: 401, code: "unauthorized", message: "A Workbench capability is required.")
            }
            return try workbench(
                try BrowserJSON.decode(WorkbenchRequest.self, from: request.body)
            )
        }
        if request.method == "GET", request.path == "/api/v1/workbench/skills" {
            guard store.validateLocalGrant(
                token: request.bearerToken,
                kind: .workbench,
                resourceID: nil
            ) else {
                return error(status: 401, code: "unauthorized", message: "A Workbench capability is required.")
            }
            return json(SkillsResponse(skills: runtime.skills))
        }

        return error(status: 404, code: "not_found", message: "Route was not found.")
    }

    private func perform(
        action: BrowserAction,
        page: GitHubPageContext,
        client: BrowserClient,
        confirmed: Bool,
        baseURL: URL
    ) async -> BrowserHTTPResponse {
        do {
            switch action.kind {
            case .runSkill:
                guard client.scopes.contains(.skillRun), let skillID = action.skillID else {
                    return scopeDenied(.skillRun)
                }
                let run = try runtime.start(
                    skillID: skillID,
                    page: page,
                    pullRequest: pullRequest(for: page),
                    requestedByClientID: client.id
                )
                return json(
                    ActionResponse(
                        run: runForResponse(run, includeArtifacts: client.scopes.contains(.artifactRead)),
                        url: nil,
                        tags: nil,
                        rerunCount: nil,
                        event: nil
                    )
                )
            case .cancelRun:
                guard client.scopes.contains(.skillCancel), let runID = action.runID else {
                    return scopeDenied(.skillCancel)
                }
                let run = try runtime.cancel(runID: runID)
                return json(
                    ActionResponse(
                        run: runForResponse(run, includeArtifacts: client.scopes.contains(.artifactRead)),
                        url: nil,
                        tags: nil,
                        rerunCount: nil,
                        event: nil
                    )
                )
            case .retryRun:
                guard client.scopes.contains(.skillRun), let runID = action.runID,
                      let previous = store.run(id: runID) else {
                    return scopeDenied(.skillRun)
                }
                let run = try runtime.retry(
                    runID: runID,
                    pullRequest: pullRequest(for: previous.page),
                    requestedByClientID: client.id
                )
                return json(
                    ActionResponse(
                        run: runForResponse(run, includeArtifacts: client.scopes.contains(.artifactRead)),
                        url: nil,
                        tags: nil,
                        rerunCount: nil,
                        event: nil
                    )
                )
            case .setTag:
                guard client.scopes.contains(.tagWrite), let tag = action.tag else {
                    return scopeDenied(.tagWrite)
                }
                store.setTag(tag, pageKey: page.key, clientID: client.id)
                return json(
                    ActionResponse(
                        run: nil,
                        url: nil,
                        tags: store.tags(for: page.key),
                        rerunCount: nil,
                        event: nil
                    )
                )
            case .removeTag:
                guard client.scopes.contains(.tagWrite), let tag = action.tag else {
                    return scopeDenied(.tagWrite)
                }
                store.removeTag(tag, pageKey: page.key, clientID: client.id)
                return json(
                    ActionResponse(
                        run: nil,
                        url: nil,
                        tags: store.tags(for: page.key),
                        rerunCount: nil,
                        event: nil
                    )
                )
            case .openDetail:
                guard client.scopes.contains(.detailOpen) else {
                    return scopeDenied(.detailOpen)
                }
                let url: OpenDetailResponse
                if let analysisID = action.analysisID {
                    url = try detailURL(analysisID: analysisID, baseURL: baseURL)
                } else if let runID = action.runID {
                    url = try runDetailURL(runID: runID, baseURL: baseURL)
                } else {
                    return error(status: 400, code: "missing_detail", message: "A run or analysis id is required.")
                }
                return json(ActionResponse(run: nil, url: url.url, tags: nil, rerunCount: nil, event: nil))
            case .openApp, .showPR:
                guard client.scopes.contains(.appOpen) else {
                    return scopeDenied(.appOpen)
                }
                let url = "ghpr://show?repository=\(urlEncode(page.repository))&number=\(page.prNumber ?? 0)"
                return json(ActionResponse(run: nil, url: url, tags: nil, rerunCount: nil, event: nil))
            case .rerunFailedJobs:
                guard client.scopes.contains(.skillRun) else {
                    return scopeDenied(.skillRun)
                }
                guard confirmed else {
                    return error(
                        status: 409,
                        code: "confirmation_required",
                        message: "Rerunning GitHub jobs requires explicit confirmation."
                    )
                }
                guard let rerunFailedJobs, let pullRequest = pullRequest(for: page) else {
                    return error(status: 409, code: "unavailable", message: "Rerun is unavailable.")
                }
                let count = try await rerunFailedJobs(pullRequest)
                return json(ActionResponse(run: nil, url: nil, tags: nil, rerunCount: count, event: nil))
            case .clientEvent:
                let event = store.appendEvent(
                    clientID: client.id,
                    pageKey: page.key,
                    name: action.event ?? "client_event",
                    payload: [:]
                )
                return json(ActionResponse(run: nil, url: nil, tags: nil, rerunCount: nil, event: event))
            }
        } catch {
            return self.error(status: 400, code: "action_failed", message: error.localizedDescription)
        }
    }

    private func invokeContribution(
        clientID: String,
        pageKey: String,
        contributionID: String,
        caller: BrowserClient,
        baseURL: URL
    ) async -> BrowserHTTPResponse {
        guard let contribution = store.contribution(
            clientID: clientID,
            pageKey: pageKey,
            id: contributionID
        ),
        let action = contribution.action,
        let owner = store.authorizedClient(id: clientID) else {
            return error(status: 404, code: "contribution_not_found", message: "Contribution was not found.")
        }
        if action.kind == .clientEvent {
            let event = store.appendEvent(
                clientID: owner.id,
                pageKey: contribution.pageKey,
                name: action.event ?? "client_event",
                payload: ["contribution_id": contributionID]
            )
            return json(ActionResponse(run: nil, url: nil, tags: nil, rerunCount: nil, event: event))
        }
        if let requiredScope = requiredScope(for: action.kind),
           !owner.scopes.contains(requiredScope) {
            return scopeDenied(requiredScope)
        }
        guard let page = pageContext(from: contribution.pageKey) else {
            return error(status: 400, code: "invalid_page_key", message: "Contribution page key is invalid.")
        }
        return await perform(
            action: action,
            page: page,
            client: caller,
            confirmed: false,
            baseURL: baseURL
        )
    }

    private func requiredScope(for action: BrowserActionKind) -> BrowserScope? {
        switch action {
        case .runSkill, .retryRun, .rerunFailedJobs:
            return .skillRun
        case .cancelRun:
            return .skillCancel
        case .openDetail:
            return .detailOpen
        case .openApp, .showPR:
            return .appOpen
        case .setTag, .removeTag:
            return .tagWrite
        case .clientEvent:
            return nil
        }
    }

    private func workbench(_ request: WorkbenchRequest) throws -> BrowserHTTPResponse {
        switch request.operation {
        case "discover_skills":
            return json(
                WorkbenchDiscoveryResponse(
                    skills: SkillAgentDiscovery.discover(homeURL: agentSkillsHomeURL)
                )
            )
        case "scaffold":
            guard let id = request.id, let displayName = request.displayName else {
                return error(status: 400, code: "missing_fields", message: "id and display_name are required.")
            }
            let url = try SkillPackageManager.scaffold(
                at: draftsRootURL,
                id: id,
                displayName: displayName
            )
            return json(
                WorkbenchResponse(
                    path: url.path,
                    validation: SkillPackageManager.validate(at: url),
                    installStatuses: nil,
                    preview: nil
                )
            )
        case "migrate":
            guard let sourcePath = request.sourcePath, let id = request.id else {
                return error(status: 400, code: "missing_fields", message: "source_path and id are required.")
            }
            let url = try SkillPackageManager.migrate(
                sourceURL: URL(
                    fileURLWithPath: (sourcePath as NSString).expandingTildeInPath
                ),
                destinationParentURL: draftsRootURL,
                id: id
            )
            return json(
                WorkbenchResponse(
                    path: url.path,
                    validation: SkillPackageManager.validate(at: url),
                    installStatuses: nil,
                    preview: nil
                )
            )
        case "enhance":
            guard let packagePath = request.packagePath else {
                return error(status: 400, code: "missing_path", message: "package_path is required.")
            }
            let expandedPath = (packagePath as NSString).expandingTildeInPath
            let sourceURL = URL(fileURLWithPath: expandedPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let browserSlot = request.slot ?? .prMergeboxAfter
            let url: URL
            if let editableURL = try? editableDraftPackageURL(expandedPath),
               (try? SkillPackageManager.load(at: editableURL)) != nil {
                url = editableURL
                try SkillPackageManager.enhance(at: url, browserSlot: browserSlot)
            } else {
                let enhancementRoot = draftsRootURL
                    .appendingPathComponent("enhancements", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                if (try? SkillPackageManager.load(at: sourceURL)) != nil {
                    url = try SkillPackageManager.install(
                        packageURL: sourceURL,
                        skillsRootURL: enhancementRoot
                    )
                    try SkillPackageManager.enhance(at: url, browserSlot: browserSlot)
                } else {
                    let discovered = SkillAgentDiscovery
                        .discover(homeURL: agentSkillsHomeURL)
                        .first { $0.path == sourceURL.path }
                    url = try SkillPackageManager.prepareNativeEnhancementCopy(
                        sourceURL: sourceURL,
                        destinationParentURL: enhancementRoot,
                        agents: discovered?.agents ?? SkillAgentDiscovery.supportedAgents,
                        displayName: discovered?.displayName,
                        browserSlot: browserSlot
                    )
                }
            }
            return json(
                WorkbenchResponse(
                    path: url.path,
                    validation: SkillPackageManager.validate(at: url),
                    installStatuses: nil,
                    preview: nil
                )
            )
        case "save":
            guard let packagePath = request.packagePath,
                  let files = request.files,
                  !files.isEmpty else {
                return error(
                    status: 400,
                    code: "missing_files",
                    message: "package_path and files are required."
                )
            }
            let packageURL = try editableDraftPackageURL(packagePath)
            let allowedFiles: Set<String> = [
                "ghpr.skill.yaml",
                "SKILL.md",
                "schemas/result.schema.json",
                "presentation/presentation.yaml",
                "browser/contributions.yaml",
                "fixtures/failed-run.json",
                "fixtures/expected-result.json"
            ]
            guard files.count <= allowedFiles.count,
                  files.keys.allSatisfy(allowedFiles.contains),
                  files.values.allSatisfy({ $0.utf8.count <= 1_048_576 }) else {
                return error(
                    status: 400,
                    code: "invalid_files",
                    message: "Only generated Skill files up to 1 MiB may be edited."
                )
            }
            let destinations = try files.map { path, contents in
                (
                    try SkillPackageManager.resolvedPackagePath(
                        path,
                        under: packageURL
                    ),
                    contents
                )
            }
            for (destination, contents) in destinations {
                try Data(contents.utf8).write(to: destination, options: .atomic)
            }
            let validation = SkillPackageManager.validate(at: packageURL)
            return json(
                WorkbenchResponse(
                    path: packageURL.path,
                    validation: validation,
                    installStatuses: nil,
                    preview: validation.valid ? try workbenchPreview(at: packageURL) : nil
                )
            )
        case "preview":
            guard let packagePath = request.packagePath else {
                return error(status: 400, code: "missing_path", message: "package_path is required.")
            }
            let packageURL = URL(fileURLWithPath: packagePath)
            let validation = SkillPackageManager.validate(at: packageURL)
            return json(
                WorkbenchResponse(
                    path: packageURL.path,
                    validation: validation,
                    installStatuses: nil,
                    preview: validation.valid ? try workbenchPreview(at: packageURL) : nil
                )
            )
        case "validate":
            guard let packagePath = request.packagePath else {
                return error(status: 400, code: "missing_path", message: "package_path is required.")
            }
            let url = URL(fileURLWithPath: packagePath)
            return json(
                WorkbenchResponse(
                    path: url.path,
                    validation: SkillPackageManager.validate(at: url),
                    installStatuses: nil,
                    preview: nil
                )
            )
        case "test":
            guard let packagePath = request.packagePath else {
                return error(status: 400, code: "missing_path", message: "package_path is required.")
            }
            let url = URL(fileURLWithPath: packagePath)
            return json(
                WorkbenchResponse(
                    path: url.path,
                    validation: try SkillPackageManager.testFixture(at: url),
                    installStatuses: nil,
                    preview: nil
                )
            )
        case "pack":
            guard let packagePath = request.packagePath else {
                return error(status: 400, code: "missing_path", message: "package_path is required.")
            }
            let packageURL = URL(fileURLWithPath: packagePath)
            let package = try SkillPackageManager.load(at: packageURL)
            let outputURL = draftsRootURL.appendingPathComponent(
                "\(package.manifest.id)-\(package.manifest.version).ghpr-skill.zip"
            )
            let packed = try SkillPackageManager.pack(
                packageURL: packageURL,
                outputURL: outputURL
            )
            return json(
                WorkbenchResponse(
                    path: packed.path,
                    validation: SkillPackageManager.validate(at: packageURL),
                    installStatuses: nil,
                    preview: nil
                )
            )
        case "install":
            guard let packagePath = request.packagePath else {
                return error(status: 400, code: "missing_path", message: "package_path is required.")
            }
            let installed = try SkillPackageManager.install(
                packageURL: URL(fileURLWithPath: packagePath)
            )
            return json(
                WorkbenchResponse(
                    path: installed.path,
                    validation: SkillPackageManager.validate(at: installed),
                    installStatuses: nil,
                    preview: nil
                )
            )
        case "install_builder":
            guard let source = assetProvider.url(relativePath: "ghpr-skill-builder/SKILL.md") else {
                return error(status: 500, code: "asset_missing", message: "Skill Builder asset is missing.")
            }
            let agents = request.agents ?? [.claudeCode, .codex, .omp]
            let statuses = try SkillBuilderInstaller.install(sourceSkillURL: source, agents: agents)
                .map {
                    WorkbenchInstallStatus(
                        agent: $0.agent,
                        path: $0.destination.path,
                        installed: $0.installed
                    )
                }
            return json(
                WorkbenchResponse(
                    path: nil,
                    validation: nil,
                    installStatuses: statuses,
                    preview: nil
                )
            )
        default:
            return error(status: 400, code: "unknown_operation", message: "Unknown Workbench operation.")
        }
    }

    private func workbenchPreview(at packageURL: URL) throws -> WorkbenchPreview {
        let package = try SkillPackageManager.load(at: packageURL)
        let manifest = package.manifest
        var requestedCapabilities: [String] = []
        if manifest.workspaceAccess != "read_only" {
            requestedCapabilities.append("Writable PR worktree")
        }
        if manifest.shellAccess != "denied" {
            requestedCapabilities.append("Run shell or test commands")
        }
        if manifest.networkAccess != "denied" {
            requestedCapabilities.append("Network access: \(manifest.networkAccess)")
        }
        if manifest.automationEnabled {
            requestedCapabilities.append("Automatic execution")
        }
        if manifest.autoApplyTags {
            requestedCapabilities.append("Automatic PR tags")
        }
        if manifest.browserCompanionPath != nil {
            requestedCapabilities.append("Companion userscript")
        }
        if let browserContract = SkillPackageManager.browserContract(for: package) {
            let slots = Set(browserContract.contributions.map(\.slot.rawValue)).sorted()
            if !slots.isEmpty {
                requestedCapabilities.append("GitHub page UI: \(slots.joined(separator: ", "))")
            }
            let actions = Set(browserContract.contributions.compactMap(\.action?.kind))
            if !actions.intersection([.runSkill, .retryRun, .rerunFailedJobs]).isEmpty {
                requestedCapabilities.append("Run Skills from GitHub pages")
            }
            if actions.contains(.cancelRun) {
                requestedCapabilities.append("Cancel Skill runs from GitHub pages")
            }
            if !actions.intersection([.setTag, .removeTag]).isEmpty {
                requestedCapabilities.append("Write PR tags from GitHub pages")
            }
        }
        let expectedResult = try? SkillPackageManager.readTextResource(
            "fixtures/expected-result.json",
            under: package.rootURL
        )
        return WorkbenchPreview(
            id: manifest.id,
            version: manifest.version,
            displayName: manifest.displayName,
            manifest: try SkillPackageManager.readTextResource(
                "ghpr.skill.yaml",
                under: package.rootURL
            ),
            resultSchema: try SkillPackageManager.readTextResource(
                manifest.resultSchemaPath,
                under: package.rootURL
            ),
            presentation: try SkillPackageManager.readTextResource(
                manifest.presentationPath,
                under: package.rootURL
            ),
            browserContributions: try manifest.browserContributionsPath.map {
                try SkillPackageManager.readTextResource($0, under: package.rootURL)
            },
            expectedResult: expectedResult,
            requestedCapabilities: requestedCapabilities
        )
    }

    private func editableDraftPackageURL(_ path: String) throws -> URL {
        let draftsRoot = draftsRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let packageURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard packageURL.path.hasPrefix(draftsRoot.path + "/") else {
            throw RouterError.invalidWorkbenchPath
        }
        return packageURL
    }

    private func authenticatedClient(
        _ request: BrowserHTTPRequest,
        requiring scopes: Set<BrowserScope> = []
    ) throws -> BrowserClient {
        guard let authenticated = store.authenticate(bearerToken: request.bearerToken) else {
            throw RouterError.unauthorized
        }
        guard scopes.isSubset(of: authenticated.client.scopes) else {
            throw RouterError.scopeDenied(scopes.sorted { $0.rawValue < $1.rawValue })
        }
        return authenticated.client
    }

    private func runForResponse(
        _ run: SkillRun,
        includeArtifacts: Bool
    ) -> SkillRun {
        var redacted = run
        let allowedMessages = Set(SkillRuntime.LogEvent.allCases.map(\.message))
        if let progressMessage = redacted.progressMessage,
           !allowedMessages.contains(progressMessage) {
            redacted.progressMessage = logEvent(for: redacted.status).message
        }
        if redacted.error != nil {
            redacted.error = redacted.status == .failed
                ? SkillRuntime.LogEvent.failed.message
                : nil
        }
        if let entries = redacted.logEntries {
            var safeEntries: [SkillRunLogEntry] = []
            for entry in entries.suffix(SkillRuntime.maximumLogEntries) {
                let message = allowedMessages.contains(entry.message)
                    ? entry.message
                    : logEvent(for: entry.kind).message
                if let last = safeEntries.last,
                   last.kind == entry.kind,
                   last.message == message {
                    continue
                }
                safeEntries.append(
                    SkillRunLogEntry(
                        timestamp: entry.timestamp,
                        kind: entry.kind,
                        message: message
                    )
                )
            }
            redacted.logEntries = safeEntries
        }
        if !includeArtifacts, let result = redacted.result {
            redacted.result = SkillResult(
                kind: result.kind,
                title: result.title,
                summary: result.summary,
                analysis: result.analysis,
                codeReview: result.codeReview,
                markdown: result.markdown,
                artifacts: [],
                payload: result.payload?.redactingArtifactData()
            )
        }
        return redacted
    }

    private func logEvent(for status: SkillRunStatus) -> SkillRuntime.LogEvent {
        switch status {
        case .queued: return .queued
        case .running: return .executing
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    private func logEvent(for kind: SkillRunLogKind) -> SkillRuntime.LogEvent {
        switch kind {
        case .queued: return .queued
        case .running: return .executing
        case .success: return .completed
        case .warning: return .cancelled
        case .error: return .failed
        }
    }

    private func pullRequest(for page: GitHubPageContext) -> LocalPRSnapshot? {
        guard let number = page.prNumber else { return nil }
        return LocalAPIHandler.findPullRequest(
            in: snapshotProvider(),
            repository: page.repository,
            number: number
        )
    }

    private func pageContext(from request: BrowserHTTPRequest) -> GitHubPageContext? {
        guard let repository = request.queryValue("repository") else {
            return nil
        }
        if let number = Int(request.queryValue("number") ?? ""), number > 0 {
            return .pullRequest(repository: repository, number: number)
        }
        if let runID = Int64(request.queryValue("run_id") ?? ""), runID > 0 {
            return .workflowRun(repository: repository, runID: runID)
        }
        return nil
    }

    private func pageContext(from pageKey: String) -> GitHubPageContext? {
        let prefix = "github:"
        guard pageKey.hasPrefix(prefix) else { return nil }
        if let marker = pageKey.range(of: ":pr:", options: .backwards),
           let number = Int(pageKey[marker.upperBound...]) {
            let repository = String(
                pageKey[pageKey.index(pageKey.startIndex, offsetBy: prefix.count)..<marker.lowerBound]
            )
            return .pullRequest(repository: repository, number: number)
        }
        if let marker = pageKey.range(of: ":run:", options: .backwards),
           let runID = Int64(pageKey[marker.upperBound...]) {
            let repository = String(
                pageKey[pageKey.index(pageKey.startIndex, offsetBy: prefix.count)..<marker.lowerBound]
            )
            return .workflowRun(repository: repository, runID: runID)
        }
        return nil
    }

    private func detailURL(analysisID: String, baseURL: URL) throws -> OpenDetailResponse {
        let grant = try store.issueDetailGrant(analysisID: analysisID)
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("ui")
                .appendingPathComponent("analysis")
                .appendingPathComponent(analysisID),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "cap", value: grant)]
        if let returnURL = store.analysis(id: analysisID).flatMap({ pageContext(from: $0.pageKey)?.githubURL }) {
            queryItems.append(URLQueryItem(name: "return", value: returnURL.absoluteString))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw RouterError.invalidURL }
        return OpenDetailResponse(url: url.absoluteString)
    }

    private func runDetailURL(runID: String, baseURL: URL) throws -> OpenDetailResponse {
        let grant = try store.issueRunDetailGrant(runID: runID)
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("ui")
                .appendingPathComponent("run")
                .appendingPathComponent(runID),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "cap", value: grant)]
        if let returnURL = store.run(id: runID)?.page.githubURL {
            queryItems.append(URLQueryItem(name: "return", value: returnURL.absoluteString))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw RouterError.invalidURL }
        return OpenDetailResponse(url: url.absoluteString)
    }

    private func asset(relativePath: String, contentType: String) -> BrowserHTTPResponse {
        guard let data = assetProvider.data(relativePath: relativePath) else {
            return error(status: 404, code: "asset_not_found", message: "Asset was not found.")
        }
        return BrowserHTTPResponse(
            status: 200,
            headers: [
                "Content-Type": contentType,
                "Cache-Control": "no-cache",
                "X-Content-Type-Options": "nosniff"
            ],
            body: data
        )
    }

    private func applicationIcon() -> BrowserHTTPResponse {
        guard let png = applicationIconProvider() else {
            return error(
                status: 404,
                code: "app_icon_unavailable",
                message: "The application icon is unavailable."
            )
        }
        return BrowserHTTPResponse(
            status: 200,
            headers: [
                "Content-Type": "image/png",
                "Cache-Control": "public, max-age=86400",
                "X-Content-Type-Options": "nosniff"
            ],
            body: png
        )
    }

    private static func defaultApplicationIconPNG() -> Data? {
        guard let tiff = NSApplication.shared.applicationIconImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }


    private func htmlShell(title: String, page: String) -> BrowserHTTPResponse {
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          <title>\(htmlEscape(title)) · ghpr</title>
          <link rel="stylesheet" href="/assets/styles.css">
        </head>
        <body data-ghpr-page="\(htmlEscape(page))">
          <div id="ghpr-app" aria-live="polite">
            <div class="boot-state"><img class="pulse-mark" src="/assets/app-icon.png" alt="" aria-hidden="true"> Loading \(htmlEscape(title))…</div>
          </div>
          <script src="/assets/app.js" defer></script>
        </body>
        </html>
        """
        var response = BrowserHTTPResponse.text(
            html,
            contentType: "text/html; charset=utf-8"
        )
        response.headers["Content-Security-Policy"] =
            "default-src 'self'; connect-src 'self'; img-src 'self' data: https://avatars.githubusercontent.com; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response
    }

    private func json<T: Encodable>(_ value: T, status: Int = 200) -> BrowserHTTPResponse {
        do {
            return BrowserHTTPResponse(
                status: status,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Cache-Control": "no-store",
                    "X-Content-Type-Options": "nosniff"
                ],
                body: try BrowserJSON.encode(value)
            )
        } catch {
            return self.error(
                status: 500,
                code: "encoding_failed",
                message: error.localizedDescription
            )
        }
    }

    private func error(status: Int, code: String, message: String) -> BrowserHTTPResponse {
        let object: [String: Any] = [
            "ok": false,
            "error": [
                "code": code,
                "message": message
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ??
            Data(#"{"ok":false}"#.utf8)
        return BrowserHTTPResponse(
            status: status,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff"
            ],
            body: data
        )
    }

    private func methodNotAllowed() -> BrowserHTTPResponse {
        error(status: 405, code: "method_not_allowed", message: "Method is not allowed.")
    }

    private func scopeDenied(_ scope: BrowserScope) -> BrowserHTTPResponse {
        error(
            status: 403,
            code: "scope_denied",
            message: "The client does not have \(scope.rawValue)."
        )
    }

    private func preflightResponse(for request: BrowserHTTPRequest) -> BrowserHTTPResponse {
        guard let origin = request.headers["origin"],
              origin.hasPrefix("http://127.0.0.1:") ||
                origin.hasPrefix("http://localhost:") else {
            return error(status: 403, code: "origin_forbidden", message: "Origin is not allowed.")
        }
        return BrowserHTTPResponse(
            status: 204,
            headers: [
                "Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Headers": "Authorization, Content-Type",
                "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
                "Access-Control-Max-Age": "600",
                "Vary": "Origin"
            ],
            body: Data()
        )
    }

    private func addingCORSHeaders(
        _ response: BrowserHTTPResponse,
        request: BrowserHTTPRequest,
        baseURL: URL
    ) -> BrowserHTTPResponse {
        guard let origin = request.headers["origin"],
              isAllowedOrigin(origin, baseURL: baseURL) else {
            return response
        }
        var headers = response.headers
        headers["Access-Control-Allow-Origin"] = origin
        headers["Vary"] = "Origin"
        return BrowserHTTPResponse(status: response.status, headers: headers, body: response.body)
    }

    private func isAllowedOrigin(_ origin: String, baseURL: URL) -> Bool {
        origin == "\(baseURL.scheme ?? "http")://\(baseURL.host ?? "127.0.0.1"):\(baseURL.port ?? 80)" ||
            origin == "http://localhost:\(baseURL.port ?? 80)"
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }

    private func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private enum RouterError: LocalizedError {
        case unauthorized
        case scopeDenied([BrowserScope])
        case invalidURL
        case invalidWorkbenchPath

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "A valid browser capability token is required."
            case .scopeDenied(let scopes):
                return "Missing scope: \(scopes.map(\.rawValue).joined(separator: ", "))."
            case .invalidURL:
                return "Unable to create a local detail URL."
            case .invalidWorkbenchPath:
                return "Only Skill packages created in the ghpr Workbench may be edited."
            }
        }
    }
}
