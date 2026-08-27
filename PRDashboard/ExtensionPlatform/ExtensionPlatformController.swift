import Combine
import Foundation
import os

private let extensionPlatformLogger = Logger(
    subsystem: "com.prdashboard",
    category: "ExtensionPlatform"
)

func defaultExtensionPlatformStorageURL() -> URL? {
    guard let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else {
        return nil
    }
    return applicationSupport
        .appendingPathComponent("ghpr", isDirectory: true)
        .appendingPathComponent("extension-platform.json")
}

@MainActor
final class ExtensionPlatformController: ObservableObject {
    @Published private(set) var bridgeStatus = BrowserBridgeStatus(state: .stopped)
    @Published private(set) var revision: UInt64 = 0

    let store: ExtensionPlatformStore
    let runtime: SkillRuntime
    let router: BrowserBridgeRouter
    let server: BrowserBridgeServer

    var onPendingPairing: ((PendingPairingApproval) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var announcedPairingIDs = Set<String>()
    private let snapshotProvider: BrowserBridgeRouter.SnapshotProvider

    init(
        snapshotProvider: @escaping BrowserBridgeRouter.SnapshotProvider,
        rerunFailedJobs: BrowserBridgeRouter.RerunFailedJobsHandler? = nil,
        storageURL: URL? = defaultExtensionPlatformStorageURL(),
        assetProvider: BrowserAssetProvider = .bundled(),
        appVersion: String,
        ports: [UInt16] = Array(48120...48129),
        draftsRootURL: URL? = nil,
        installedSkillsRootURL: URL = SkillPackageManager.defaultInstalledSkillsURL(),
        bundledSkillsRootURL: URL? = nil
    ) {
        let store = ExtensionPlatformStore(storageURL: storageURL)
        let runtime = SkillRuntime(
            store: store,
            installedSkillsRootURL: installedSkillsRootURL,
            bundledSkillsRootURL: bundledSkillsRootURL
        )
        let router = BrowserBridgeRouter(
            store: store,
            runtime: runtime,
            snapshotProvider: snapshotProvider,
            rerunFailedJobs: rerunFailedJobs,
            assetProvider: assetProvider,
            appVersion: appVersion,
            draftsRootURL: draftsRootURL
        )
        self.snapshotProvider = snapshotProvider
        self.store = store
        self.runtime = runtime
        self.router = router
        server = BrowserBridgeServer(router: router, ports: ports)

        server.$status
            .sink { [weak self] status in
                self?.bridgeStatus = status
            }
            .store(in: &cancellables)

        store.$revision
            .sink { [weak self] revision in
                guard let self else { return }
                self.revision = revision
                self.announcePendingPairingIfNeeded()
            }
            .store(in: &cancellables)
    }

    var pairedClients: [BrowserClient] {
        _ = revision
        return store.pairedClients
    }

    var pendingApprovals: [PendingPairingApproval] {
        _ = revision
        return store.pendingApprovals
    }

    var unhealthySlots: [SlotHealthReport] {
        _ = revision
        return store.unhealthySlots
    }

    var skills: [SkillDefinition] {
        runtime.skills
    }

    var officialUserscriptClient: BrowserClient? {
        pairedClients.first { $0.id == "dev.ghpr.official-userscript" && !$0.isRevoked }
    }

    var isGitHubPageConnected: Bool {
        guard let lastSeen = officialUserscriptClient?.lastSeenAt else { return false }
        return Date().timeIntervalSince(lastSeen) < 5 * 60
    }

    func start() {
        server.start()
    }

    func stop() {
        server.stop()
    }

    func approvePairing(_ approval: PendingPairingApproval, scopes: Set<BrowserScope>) throws {
        _ = try store.approvePairingFromNative(id: approval.id, approvedScopes: scopes)
        announcedPairingIDs.remove(approval.id)
    }

    func denyPairing(_ approval: PendingPairingApproval) throws {
        try store.denyPairingFromNative(id: approval.id)
        announcedPairingIDs.remove(approval.id)
    }

    func revoke(client: BrowserClient) {
        store.revokeClient(id: client.id)
    }

    func agentRuntimePreference(for agent: SkillAgent) -> AgentRuntimePreference {
        _ = revision
        return store.agentRuntimePreference(for: agent)
    }

    func setAgentRuntimePreference(
        _ preference: AgentRuntimePreference,
        for agent: SkillAgent
    ) {
        store.save(agentRuntimePreference: preference, for: agent)
    }

    func cachedAgentCapabilityCatalog(for agent: SkillAgent) -> AgentCapabilityCatalog? {
        _ = revision
        return store.agentCapabilityCatalog(for: agent)
    }

    @discardableResult
    func loadAgentCapabilityCatalog(
        for agent: SkillAgent,
        forceRefresh: Bool
    ) async throws -> AgentCapabilityCatalog {
        if !forceRefresh, let cached = store.agentCapabilityCatalog(for: agent) {
            return cached
        }
        let catalog = try await AgentCapabilityProbe.catalog(for: agent)
        store.save(agentCapabilityCatalog: catalog)
        return catalog
    }

    func installUserscriptURL() -> URL? {
        server.baseURL?.appendingPathComponent("install/ghpr.user.js")
    }

    func installSDKURL() -> URL? {
        server.baseURL?.appendingPathComponent("install/ghpr-sdk.js")
    }

    func workbenchURL() -> URL? {
        localWorkbenchURL(path: "workbench")
    }

    func githubPreviewURL() -> URL? {
        localWorkbenchURL(path: "github-preview")
    }

    func browserTestURL() -> URL? {
        localWorkbenchURL(path: "browser-test")
    }

    func analysisURL(for analysis: CIAnalysis) -> URL? {
        guard let baseURL = server.baseURL,
              let grant = try? store.issueDetailGrant(analysisID: analysis.id) else {
            return nil
        }
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("ui")
                .appendingPathComponent("analysis")
                .appendingPathComponent(analysis.id),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "cap", value: grant)]
        if let returnURL: URL = {
            let parts = analysis.pageKey.split(separator: ":")
            guard parts.count == 4, parts[2] == "pr", let number = Int(parts[3]) else { return nil }
            return URL(string: "https://github.com/\(parts[1])/pull/\(number)")
        }() {
            queryItems.append(URLQueryItem(name: "return", value: returnURL.absoluteString))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    func latestAnalysisURL(repository: String, number: Int) -> URL? {
        let page = GitHubPageContext.pullRequest(repository: repository, number: number)
        guard let analysis = store.analyses(pageKey: page.key).first else {
            return nil
        }
        return analysisURL(for: analysis)
    }

    @discardableResult
    func runSkill(
        id: String,
        repository: String,
        number: Int
    ) throws -> SkillRun {
        let page = GitHubPageContext.pullRequest(repository: repository, number: number)
        let pullRequest = LocalAPIHandler.findPullRequest(
            in: snapshotProvider(),
            repository: repository,
            number: number
        )
        return try runtime.start(
            skillID: id,
            page: page,
            pullRequest: pullRequest,
            requestedByClientID: nil
        )
    }

    func latestAnalysis(repository: String, number: Int) -> CIAnalysis? {
        let page = GitHubPageContext.pullRequest(repository: repository, number: number)
        return store.analyses(pageKey: page.key).first
    }

    func activeRun(repository: String, number: Int) -> SkillRun? {
        let page = GitHubPageContext.pullRequest(repository: repository, number: number)
        return store.runs(pageKey: page.key).first {
            $0.status == .queued || $0.status == .running
        }
    }

    func runnableSkills(forFailedCI hasFailedCI: Bool) -> [SkillDefinition] {
        runtime.skills.filter {
            $0.isRunnable &&
                ($0.targets.contains(.pullRequest) ||
                    (hasFailedCI && $0.targets.contains(.failedWorkflowRun)))
        }
    }


    func setTag(
        _ tag: PRTag,
        repository: String,
        number: Int
    ) {
        let page = GitHubPageContext.pullRequest(repository: repository, number: number)
        store.setTag(tag, pageKey: page.key, clientID: nil)
    }

    func removeTag(
        _ tag: PRTag,
        repository: String,
        number: Int
    ) {
        let page = GitHubPageContext.pullRequest(repository: repository, number: number)
        store.removeTag(tag, pageKey: page.key, clientID: nil)
    }

    func tags(repository: String, number: Int) -> Set<PRTag> {
        let page = GitHubPageContext.pullRequest(repository: repository, number: number)
        return store.tags(for: page.key)
    }

    private func localWorkbenchURL(path: String) -> URL? {
        guard let baseURL = server.baseURL else { return nil }
        let grant = store.issueWorkbenchGrant()
        var components = URLComponents(
            url: baseURL.appendingPathComponent("ui").appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "cap", value: grant)]
        return components?.url
    }

    private func announcePendingPairingIfNeeded() {
        guard let approval = store.pendingApprovals.first(where: {
            !announcedPairingIDs.contains($0.id)
        }) else {
            return
        }
        announcedPairingIDs.insert(approval.id)
        onPendingPairing?(approval)
    }
}
