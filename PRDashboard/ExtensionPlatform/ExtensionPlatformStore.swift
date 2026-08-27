import Combine
import CryptoKit
import Foundation
import Security

private func defaultExtensionStoreURL() -> URL? {
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
final class ExtensionPlatformStore: ObservableObject {
    enum StoreError: LocalizedError, Equatable {
        case invalidClient
        case invalidScopes
        case pairingNotFound
        case pairingExpired
        case pairingSecretMismatch
        case pairingNotApproved
        case clientRevoked
        case runNotFound
        case analysisNotFound

        var errorDescription: String? {
            switch self {
            case .invalidClient: return "The browser client identity is invalid."
            case .invalidScopes: return "The browser client requested an unavailable scope."
            case .pairingNotFound: return "The pairing request no longer exists."
            case .pairingExpired: return "The pairing request expired."
            case .pairingSecretMismatch: return "The pairing secret is invalid."
            case .pairingNotApproved: return "The pairing request has not been approved."
            case .clientRevoked: return "The browser client has been revoked."
            case .runNotFound: return "The Skill run was not found."
            case .analysisNotFound: return "The analysis was not found."
            }
        }
    }

    enum LocalGrantKind: String {
        case analysis
        case run
        case workbench
    }

    struct AuthenticatedClient: Equatable {
        let client: BrowserClient
        let tokenHash: String
    }

    private struct PersistedState: Codable {
        var clients: [String: BrowserClient] = [:]
        var tokenHashes: [String: String] = [:]
        var tags: [String: TaggedPR] = [:]
        var runs: [String: SkillRun] = [:]
        var analyses: [String: CIAnalysis] = [:]
        var contributions: [String: BrowserContribution] = [:]
        var slotHealth: [String: SlotHealthReport] = [:]
        var events: [BrowserEvent] = []
        var nextEventID: Int64 = 1
        var agentRuntime: [AgentRuntimeSetting]?
        var agentCatalogs: [AgentCapabilityCatalog]?
    }

    private struct PendingPairing {
        let descriptor: BrowserClientDescriptor
        let secretHash: String
        let expiresAt: Date
        var state: PairingState
        var approvedClient: BrowserClient?
        var issuedToken: String?
    }

    private struct CompletedPairing {
        let descriptor: BrowserClientDescriptor
        let secretHash: String
        let state: PairingState
        let client: BrowserClient?
        let expiresAt: Date
        let retainedUntil: Date
    }

    private struct LocalGrant {
        let tokenHash: String
        let kind: LocalGrantKind
        let resourceID: String?
        let expiresAt: Date
    }

    @Published private(set) var revision: UInt64 = 0

    let instanceID: String
    private let storageURL: URL?
    private var state: PersistedState
    private var pendingPairings: [String: PendingPairing] = [:]
    private var completedPairings: [String: CompletedPairing] = [:]
    private var localGrants: [String: LocalGrant] = [:]

    init(storageURL: URL? = defaultExtensionStoreURL()) {
        self.storageURL = storageURL
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let decoded = try? BrowserJSON.decode(PersistedState.self, from: data) {
            state = decoded
        } else {
            state = PersistedState()
        }
        state.contributions = Dictionary(
            state.contributions.values.map {
                (
                    Self.contributionKey(
                        clientID: $0.clientID,
                        pageKey: $0.pageKey,
                        id: $0.id
                    ),
                    $0
                )
            },
            uniquingKeysWith: { current, candidate in
                current.expiresAt >= candidate.expiresAt ? current : candidate
            }
        )

        let defaultsKey = "ghpr.browserBridge.instanceID"
        if storageURL == nil {
            instanceID = "ghpr-\(Self.randomToken(byteCount: 8))"
        } else if let saved = UserDefaults.standard.string(forKey: defaultsKey), !saved.isEmpty {
            instanceID = saved
        } else {
            let created = "ghpr-\(Self.randomToken(byteCount: 8))"
            UserDefaults.standard.set(created, forKey: defaultsKey)
            instanceID = created
        }
        prune()
    }

    var pairedClients: [BrowserClient] {
        state.clients.values.sorted {
            if $0.isRevoked != $1.isRevoked {
                return !$0.isRevoked
            }
            return $0.createdAt < $1.createdAt
        }
    }

    var pendingApprovals: [PendingPairingApproval] {
        pendingPairings
            .filter { $0.value.state == .pending && $0.value.expiresAt > Date() }
            .map {
                PendingPairingApproval(
                    id: $0.key,
                    descriptor: $0.value.descriptor,
                    expiresAt: $0.value.expiresAt
                )
            }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    var allAnalyses: [CIAnalysis] {
        state.analyses.values.sorted { $0.createdAt > $1.createdAt }
    }

    var allRuns: [SkillRun] {
        state.runs.values.sorted { $0.createdAt > $1.createdAt }
    }

    var unhealthySlots: [SlotHealthReport] {
        state.slotHealth.values
            .filter { !$0.healthy }
            .sorted { $0.observedAt > $1.observedAt }
    }

    func startPairing(
        descriptor: BrowserClientDescriptor,
        bridgeBaseURL: URL,
        now: Date = Date()
    ) throws -> PairingStartResponse {
        prune(now: now)
        guard Self.isValidClientID(descriptor.id),
              !descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !descriptor.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalidClient
        }
        guard descriptor.requestedScopes.allSatisfy(BrowserScope.allCases.contains),
              descriptor.requiredScopes.isSubset(of: descriptor.requestedScopes) else {
            throw StoreError.invalidScopes
        }

        let requestID = Self.randomToken(byteCount: 18)
        let secret = Self.randomToken(byteCount: 32)
        let expiresAt = now.addingTimeInterval(10 * 60)
        pendingPairings[requestID] = PendingPairing(
            descriptor: descriptor,
            secretHash: Self.hash(secret),
            expiresAt: expiresAt,
            state: .pending,
            approvedClient: nil,
            issuedToken: nil
        )
        revision &+= 1

        var components = URLComponents(
            url: bridgeBaseURL
                .appendingPathComponent("ui")
                .appendingPathComponent("pair")
                .appendingPathComponent(requestID),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "secret", value: secret)]
        guard let pairingURL = components?.url else {
            throw StoreError.invalidClient
        }

        return PairingStartResponse(
            requestID: requestID,
            pairingSecret: secret,
            pairingURL: pairingURL.absoluteString,
            expiresAt: expiresAt
        )
    }

    func pairingRequest(
        id: String,
        secret: String,
        now: Date = Date()
    ) throws -> BrowserClientDescriptor {
        prune(now: now)
        if let pairing = pendingPairings[id] {
            try validate(pairing: pairing, secret: secret, now: now)
            return pairing.descriptor
        }
        guard let completed = completedPairings[id] else {
            throw StoreError.pairingNotFound
        }
        guard Self.constantTimeEqual(completed.secretHash, Self.hash(secret)) else {
            throw StoreError.pairingSecretMismatch
        }
        return completed.descriptor
    }

    func pairingStatus(
        id: String,
        secret: String,
        now: Date = Date()
    ) throws -> PairingStatusResponse {
        prune(now: now)
        if let pairing = pendingPairings[id] {
            try validate(pairing: pairing, secret: secret, now: now)
            return PairingStatusResponse(
                descriptor: pairing.descriptor,
                state: pairing.state,
                client: pairing.approvedClient,
                expiresAt: pairing.expiresAt
            )
        }
        guard let completed = completedPairings[id],
              Self.constantTimeEqual(completed.secretHash, Self.hash(secret)) else {
            throw StoreError.pairingNotFound
        }
        return PairingStatusResponse(
            descriptor: completed.descriptor,
            state: completed.state,
            client: completed.client,
            expiresAt: completed.expiresAt
        )
    }

    @discardableResult
    func approvePairing(
        id: String,
        secret: String,
        approvedScopes: Set<BrowserScope>,
        now: Date = Date()
    ) throws -> BrowserClient {
        guard var pairing = pendingPairings[id] else {
            throw StoreError.pairingNotFound
        }
        try validate(pairing: pairing, secret: secret, now: now)
        guard approvedScopes.isSubset(of: pairing.descriptor.requestedScopes) else {
            throw StoreError.invalidScopes
        }

        let token = Self.randomToken(byteCount: 32)
        let client = BrowserClient(
            id: pairing.descriptor.id,
            name: pairing.descriptor.name,
            version: pairing.descriptor.version,
            scopes: approvedScopes,
            createdAt: state.clients[pairing.descriptor.id]?.createdAt ?? now,
            lastSeenAt: now,
            revokedAt: nil
        )
        state.clients[client.id] = client
        state.tokenHashes[client.id] = Self.hash(token)
        pairing.state = .approved
        pairing.approvedClient = client
        pairing.issuedToken = token
        pendingPairings[id] = pairing
        touch()
        return client
    }

    @discardableResult
    func approvePairingFromNative(
        id: String,
        approvedScopes: Set<BrowserScope>,
        now: Date = Date()
    ) throws -> BrowserClient {
        guard var pairing = pendingPairings[id] else {
            throw StoreError.pairingNotFound
        }
        guard pairing.expiresAt > now else {
            throw StoreError.pairingExpired
        }
        guard pairing.state == .pending,
              approvedScopes.isSubset(of: pairing.descriptor.requestedScopes) else {
            throw StoreError.invalidScopes
        }
        let token = Self.randomToken(byteCount: 32)
        let client = BrowserClient(
            id: pairing.descriptor.id,
            name: pairing.descriptor.name,
            version: pairing.descriptor.version,
            scopes: approvedScopes,
            createdAt: state.clients[pairing.descriptor.id]?.createdAt ?? now,
            lastSeenAt: now,
            revokedAt: nil
        )
        state.clients[client.id] = client
        state.tokenHashes[client.id] = Self.hash(token)
        pairing.state = .approved
        pairing.approvedClient = client
        pairing.issuedToken = token
        pendingPairings[id] = pairing
        touch()
        return client
    }

    func denyPairingFromNative(id: String, now: Date = Date()) throws {
        guard var pairing = pendingPairings[id] else {
            throw StoreError.pairingNotFound
        }
        guard pairing.expiresAt > now else {
            throw StoreError.pairingExpired
        }
        pairing.state = .denied
        pendingPairings[id] = pairing
        revision &+= 1
    }

    func denyPairing(id: String, secret: String, now: Date = Date()) throws {
        guard var pairing = pendingPairings[id] else {
            throw StoreError.pairingNotFound
        }
        try validate(pairing: pairing, secret: secret, now: now)
        pairing.state = .denied
        pendingPairings[id] = pairing
    }

    func pollPairing(
        id: String,
        secret: String,
        now: Date = Date()
    ) throws -> PairingPollResponse {
        prune(now: now)
        guard let pairing = pendingPairings[id] else {
            if let completed = completedPairings[id],
               Self.constantTimeEqual(completed.secretHash, Self.hash(secret)) {
                return PairingPollResponse(state: completed.state, token: nil, client: completed.client)
            }
            throw StoreError.pairingNotFound
        }
        try validate(pairing: pairing, secret: secret, now: now)
        let response = PairingPollResponse(
            state: pairing.state,
            token: pairing.issuedToken,
            client: pairing.approvedClient
        )
        if pairing.state == .approved || pairing.state == .denied {
            completedPairings[id] = CompletedPairing(
                descriptor: pairing.descriptor,
                secretHash: pairing.secretHash,
                state: pairing.state,
                client: pairing.approvedClient,
                expiresAt: pairing.expiresAt,
                retainedUntil: now.addingTimeInterval(5 * 60)
            )
            pendingPairings.removeValue(forKey: id)
        }
        return response
    }

    func authenticate(
        bearerToken: String?,
        requiring requiredScopes: Set<BrowserScope> = [],
        now: Date = Date()
    ) -> AuthenticatedClient? {
        guard let bearerToken, !bearerToken.isEmpty else { return nil }
        let candidate = Self.hash(bearerToken)
        guard let pair = state.tokenHashes.first(where: { Self.constantTimeEqual($0.value, candidate) }),
              var client = state.clients[pair.key],
              !client.isRevoked,
              requiredScopes.isSubset(of: client.scopes) else {
            return nil
        }
        if client.lastSeenAt.map({ now.timeIntervalSince($0) > 30 }) ?? true {
            client.lastSeenAt = now
            state.clients[client.id] = client
            touch()
        }
        return AuthenticatedClient(client: client, tokenHash: candidate)
    }

    func authorizedClient(
        id: String,
        requiring requiredScopes: Set<BrowserScope> = []
    ) -> BrowserClient? {
        guard let client = state.clients[id],
              !client.isRevoked,
              requiredScopes.isSubset(of: client.scopes) else {
            return nil
        }
        return client
    }

    func revokeClient(id: String, now: Date = Date()) {
        guard var client = state.clients[id] else { return }
        client.revokedAt = now
        state.clients[id] = client
        state.tokenHashes.removeValue(forKey: id)
        state.contributions = state.contributions.filter { $0.value.clientID != id }
        touch()
    }

    func tags(for pageKey: String) -> Set<PRTag> {
        state.tags[pageKey]?.tags ?? []
    }

    func setTag(
        _ tag: PRTag,
        pageKey: String,
        clientID: String?,
        now: Date = Date()
    ) {
        var tagged = state.tags[pageKey] ?? TaggedPR(
            pageKey: pageKey,
            tags: [],
            updatedAt: now,
            updatedByClientID: clientID
        )
        tagged.tags.insert(tag)
        tagged.updatedAt = now
        tagged.updatedByClientID = clientID
        state.tags[pageKey] = tagged
        touch()
    }

    func removeTag(
        _ tag: PRTag,
        pageKey: String,
        clientID: String?,
        now: Date = Date()
    ) {
        guard var tagged = state.tags[pageKey] else { return }
        tagged.tags.remove(tag)
        tagged.updatedAt = now
        tagged.updatedByClientID = clientID
        if tagged.tags.isEmpty {
            state.tags.removeValue(forKey: pageKey)
        } else {
            state.tags[pageKey] = tagged
        }
        touch()
    }

    func save(run: SkillRun) {
        state.runs[run.id] = run
        touch()
    }

    func run(id: String) -> SkillRun? {
        state.runs[id]
    }

    func runs(pageKey: String) -> [SkillRun] {
        state.runs.values
            .filter { $0.page.key == pageKey }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(analysis: CIAnalysis) {
        state.analyses[analysis.id] = analysis
        touch()
    }

    func analysis(id: String) -> CIAnalysis? {
        state.analyses[id]
    }

    func analyses(pageKey: String) -> [CIAnalysis] {
        state.analyses.values
            .filter { $0.pageKey == pageKey }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func agentRuntimePreference(for agent: SkillAgent) -> AgentRuntimePreference {
        state.agentRuntime?.first { $0.agent == agent }?.preference ?? .unset
    }

    func save(
        agentRuntimePreference preference: AgentRuntimePreference,
        for agent: SkillAgent
    ) {
        var settings = (state.agentRuntime ?? []).filter { $0.agent != agent }
        if !preference.isUnset {
            settings.append(AgentRuntimeSetting(agent: agent, preference: preference))
        }
        state.agentRuntime = settings.isEmpty
            ? nil
            : settings.sorted { $0.agent.rawValue < $1.agent.rawValue }
        touch()
    }

    func agentCapabilityCatalog(for agent: SkillAgent) -> AgentCapabilityCatalog? {
        state.agentCatalogs?.first { $0.agent == agent }
    }

    func save(agentCapabilityCatalog catalog: AgentCapabilityCatalog) {
        var catalogs = (state.agentCatalogs ?? []).filter { $0.agent != catalog.agent }
        catalogs.append(catalog)
        state.agentCatalogs = catalogs.sorted { $0.agent.rawValue < $1.agent.rawValue }
        touch()
    }

    func registerContribution(
        clientID: String,
        registration: ContributionRegistration,
        now: Date = Date()
    ) -> BrowserContribution {
        let boundedTTL = min(max(registration.ttlSeconds, 10), 3600)
        let contribution = BrowserContribution(
            id: registration.contribution.id,
            clientID: clientID,
            pageKey: registration.pageKey,
            slot: registration.slot,
            component: registration.contribution.component,
            action: registration.contribution.action,
            createdAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(boundedTTL))
        )
        state.contributions[
            Self.contributionKey(
                clientID: clientID,
                pageKey: contribution.pageKey,
                id: contribution.id
            )
        ] = contribution
        touch()
        return contribution
    }

    func unregisterContribution(clientID: String, id: String, pageKey: String? = nil) {
        state.contributions = state.contributions.filter { _, contribution in
            guard contribution.clientID == clientID, contribution.id == id else {
                return true
            }
            return pageKey.map { contribution.pageKey != $0 } ?? false
        }
        touch()
    }

    func contribution(
        clientID: String,
        pageKey: String,
        id: String,
        now: Date = Date()
    ) -> BrowserContribution? {
        prune(now: now)
        let key = Self.contributionKey(clientID: clientID, pageKey: pageKey, id: id)
        let contribution = state.contributions[key]
        guard contribution?.expiresAt ?? .distantPast > now else { return nil }
        return contribution
    }

    func replaceManagedContributions(
        clientID: String,
        pageKey: String,
        idPrefix: String,
        registrations: [ContributionRegistration],
        now: Date = Date()
    ) {
        state.contributions = state.contributions.filter { _, contribution in
            !(contribution.clientID == clientID &&
                contribution.pageKey == pageKey &&
                contribution.id.hasPrefix(idPrefix))
        }
        for registration in registrations where registration.pageKey == pageKey {
            _ = registerContribution(clientID: clientID, registration: registration, now: now)
        }
        touch()
    }

    func contributions(pageKey: String, now: Date = Date()) -> [BrowserContribution] {
        prune(now: now)
        return state.contributions.values
            .filter { $0.pageKey == pageKey && $0.expiresAt > now }
            .sorted {
                if $0.slot.rawValue != $1.slot.rawValue {
                    return $0.slot.rawValue < $1.slot.rawValue
                }
                return $0.createdAt < $1.createdAt
            }
    }

    @discardableResult
    func appendEvent(
        clientID: String,
        pageKey: String,
        name: String,
        payload: [String: String],
        now: Date = Date()
    ) -> BrowserEvent {
        let event = BrowserEvent(
            id: state.nextEventID,
            clientID: clientID,
            pageKey: pageKey,
            name: name,
            payload: payload,
            createdAt: now
        )
        state.nextEventID += 1
        state.events.append(event)
        if state.events.count > 500 {
            state.events.removeFirst(state.events.count - 500)
        }
        touch()
        return event
    }

    func events(clientID: String, after cursor: Int64) -> [BrowserEvent] {
        state.events.filter { $0.clientID == clientID && $0.id > cursor }
    }

    func reportSlotHealth(
        clientID: String,
        pageKey: String,
        slot: BrowserSlot,
        healthy: Bool,
        detail: String?,
        now: Date = Date()
    ) {
        let report = SlotHealthReport(
            clientID: clientID,
            pageKey: pageKey,
            slot: slot,
            healthy: healthy,
            detail: detail,
            observedAt: now
        )
        state.slotHealth[report.id] = report
        touch()
    }

    func issueDetailGrant(analysisID: String, now: Date = Date()) throws -> String {
        guard state.analyses[analysisID] != nil else { throw StoreError.analysisNotFound }
        return issueLocalGrant(kind: .analysis, resourceID: analysisID, now: now)
    }

    func issueRunDetailGrant(runID: String, now: Date = Date()) throws -> String {
        guard state.runs[runID] != nil else { throw StoreError.runNotFound }
        return issueLocalGrant(kind: .run, resourceID: runID, now: now)
    }

    func issueWorkbenchGrant(now: Date = Date()) -> String {
        issueLocalGrant(kind: .workbench, resourceID: nil, now: now)
    }

    func localCapability(token: String?, now: Date = Date()) -> LocalCapabilityContext? {
        prune(now: now)
        guard let token, let grant = localGrants[Self.hash(token)], grant.expiresAt > now else { return nil }
        return LocalCapabilityContext(
            kind: LocalCapabilityKind(rawValue: grant.kind.rawValue)!,
            resourceID: grant.resourceID,
            expiresAt: grant.expiresAt
        )
    }

    func validateLocalGrant(
        token: String?,
        kind: LocalGrantKind,
        resourceID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let capability = localCapability(token: token, now: now) else { return false }
        return capability.kind.rawValue == kind.rawValue && capability.resourceID == resourceID
    }

    func removeAllDataForTesting() {
        state = PersistedState()
        pendingPairings.removeAll()
        completedPairings.removeAll()
        localGrants.removeAll()
        touch()
    }

    private func issueLocalGrant(
        kind: LocalGrantKind,
        resourceID: String?,
        now: Date
    ) -> String {
        let token = Self.randomToken(byteCount: 32)
        let hash = Self.hash(token)
        localGrants[hash] = LocalGrant(
            tokenHash: hash,
            kind: kind,
            resourceID: resourceID,
            expiresAt: now.addingTimeInterval(15 * 60)
        )
        return token
    }

    private func validate(pairing: PendingPairing, secret: String, now: Date) throws {
        guard pairing.expiresAt > now else { throw StoreError.pairingExpired }
        guard Self.constantTimeEqual(pairing.secretHash, Self.hash(secret)) else {
            throw StoreError.pairingSecretMismatch
        }
    }

    private static func contributionKey(clientID: String, pageKey: String, id: String) -> String {
        "contribution:\(hash("\(clientID)\u{0}\(pageKey)\u{0}\(id)"))"
    }

    private func prune(now: Date = Date()) {
        for (id, pairing) in pendingPairings where pairing.expiresAt <= now {
            completedPairings[id] = CompletedPairing(
                descriptor: pairing.descriptor,
                secretHash: pairing.secretHash,
                state: .expired,
                client: nil,
                expiresAt: pairing.expiresAt,
                retainedUntil: pairing.expiresAt.addingTimeInterval(5 * 60)
            )
        }
        pendingPairings = pendingPairings.filter { $0.value.expiresAt > now }
        completedPairings = completedPairings.filter { $0.value.retainedUntil > now }
        localGrants = localGrants.filter { $0.value.expiresAt > now }
        state.contributions = state.contributions.filter { $0.value.expiresAt > now }
        let slotHealthCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        state.slotHealth = state.slotHealth.filter { $0.value.observedAt > slotHealthCutoff }
    }

    private func touch() {
        revision &+= 1
        persist()
    }

    private func persist() {
        guard let storageURL,
              let data = try? BrowserJSON.encode(state, prettyPrinted: true) else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // The runtime remains usable in memory. Callers surface bridge errors,
            // while persistence failure must not terminate the menu bar app.
        }
    }

    private static func isValidClientID(_ value: String) -> Bool {
        guard value.count >= 3, value.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

}

enum BrowserJSON {
    static func encode<T: Encodable>(_ value: T, prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .custom { codingPath in
            let source = codingPath.last?.stringValue ?? ""
            let components = source.split(separator: "_").map(String.init)
            guard let first = components.first else {
                return BrowserCodingKey(source)
            }
            let value = components.dropFirst().reduce(first) { result, component in
                switch component {
                case "id": return result + "ID"
                case "url": return result + "URL"
                case "sha": return result + "SHA"
                case "ci": return result + "CI"
                default:
                    return result + component.prefix(1).uppercased() + component.dropFirst()
                }
            }
            return BrowserCodingKey(value)
        }
        return try decoder.decode(type, from: data)
    }

    private struct BrowserCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(_ stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
