import Foundation
import os

class PRCache {
    static let shared = PRCache()

    private let logger = Logger(subsystem: "com.prdashboard", category: "PRCache")
    private let cacheURL: URL

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.prdashboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheURL = cacheDir.appendingPathComponent("pr_cache.json")
    }

    func save(_ prList: PRList) {
        do {
            let data = try JSONEncoder().encode(prList)
            try data.write(to: cacheURL, options: .atomic)
            logger.debug("Saved \(prList.pullRequests.count) PRs to cache")
        } catch {
            logger.error("Failed to save cache: \(error.localizedDescription)")
        }
    }

    func load() -> PRList? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: cacheURL)
            let prList = try JSONDecoder().decode(PRList.self, from: data)
            logger.debug("Loaded \(prList.pullRequests.count) PRs from cache")
            return prList
        } catch {
            logger.error("Failed to load PR cache: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: cacheURL)
        logger.debug("Cache cleared")
    }
}
final class DirectMentionTrackingCache {
    static let shared = DirectMentionTrackingCache()

    private let logger = Logger(subsystem: "com.prdashboard", category: "DirectMentionTrackingCache")
    private let cacheURL: URL
    private let maxEntries = 500
    private let lock = NSLock()
    private var entries: [Int: DirectMentionTrackingEntry]?
    private var lastPersistedData: Data?
    private var lastPersistedEntries: [Int: DirectMentionTrackingEntry] = [:]
    private var needsPersistenceRetry = false

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.prdashboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheURL = cacheDir.appendingPathComponent("direct_mention_tracking_cache.json")
    }

    func load() -> [Int: DirectMentionTrackingEntry] {
        lock.lock()
        defer { lock.unlock() }

        if let cached = entries { return cached }

        let loaded = readFromDisk()
        entries = loaded
        lastPersistedData = try? encodedData(for: loaded)
        lastPersistedEntries = loaded
        needsPersistenceRetry = false
        return loaded
    }

    func save(_ newEntries: [Int: DirectMentionTrackingEntry], force: Bool = false) {
        let trimmed = trim(newEntries)

        lock.lock()
        defer { lock.unlock() }
        entries = trimmed
        guard force || needsPersistenceRetry || trimmed != lastPersistedEntries else { return }

        do {
            let data = try encodedData(for: trimmed)
            if data != lastPersistedData {
                try data.write(to: cacheURL, options: .atomic)
                lastPersistedData = data
            }
            lastPersistedEntries = trimmed
            needsPersistenceRetry = false
        } catch {
            needsPersistenceRetry = true
            logger.error("Failed to save direct mention tracking cache: \(error.localizedDescription)")
        }
    }

    func clear() {
        lock.lock()
        entries = [:]
        lastPersistedData = nil
        lastPersistedEntries = [:]
        needsPersistenceRetry = false
        lock.unlock()

        try? FileManager.default.removeItem(at: cacheURL)
        logger.debug("Direct mention tracking cache cleared")
    }

    private func encodedData(for entries: [Int: DirectMentionTrackingEntry]) throws -> Data {
        let values = entries.values.sorted { lhs, rhs in
            lhs.prID < rhs.prID
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(values)
    }

    private func trim(_ input: [Int: DirectMentionTrackingEntry]) -> [Int: DirectMentionTrackingEntry] {
        guard input.count > maxEntries else { return input }

        let handledToRemove = input.values
            .filter { $0.state.pendingCount == 0 }
            .sorted {
                if $0.lastSeenAt != $1.lastSeenAt {
                    return $0.lastSeenAt < $1.lastSeenAt
                }
                return $0.prID < $1.prID
            }
            .prefix(input.count - maxEntries)

        guard !handledToRemove.isEmpty else { return input }

        var retained = input
        for entry in handledToRemove {
            retained.removeValue(forKey: entry.prID)
        }
        return retained
    }

    private func readFromDisk() -> [Int: DirectMentionTrackingEntry] {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return [:] }

        do {
            let data = try Data(contentsOf: cacheURL)
            let decoded = try JSONDecoder().decode([DirectMentionTrackingEntry].self, from: data)
            return Dictionary(decoded.map { ($0.prID, $0) }, uniquingKeysWith: { _, last in last })
        } catch {
            logger.error("Failed to load direct mention tracking cache: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: cacheURL)
            return [:]
        }
    }
}
struct AuthoredMentionReferenceCacheEntry: Codable, Equatable {
    let username: String
    let references: [PullRequestReference]
    let updatedAt: Date

    var pullRequestReferences: Set<PullRequestReference> {
        Set(references)
    }
}

final class AuthoredMentionReferenceCache {
    static let shared = AuthoredMentionReferenceCache()

    private let logger = Logger(subsystem: "com.prdashboard", category: "AuthoredMentionReferenceCache")
    private let cacheURL: URL
    private let lock = NSLock()
    private var entries: [String: AuthoredMentionReferenceCacheEntry]?
    private var lastPersistedEntries: [String: AuthoredMentionReferenceCacheEntry] = [:]

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.prdashboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheURL = cacheDir.appendingPathComponent("authored_mention_reference_cache.json")
    }

    func entry(for username: String) -> AuthoredMentionReferenceCacheEntry? {
        loadEntries()[Self.key(for: username)]
    }

    func saveEntry(
        username: String,
        references: Set<PullRequestReference>,
        updatedAt: Date
    ) {
        let sortedReferences = references
            .sorted { PullRequestReference.ordered($0, $1, newestFirst: false) }
        let key = Self.key(for: username)
        let entry = AuthoredMentionReferenceCacheEntry(
            username: username,
            references: sortedReferences,
            updatedAt: updatedAt
        )

        lock.lock()
        var updated = entries ?? readFromDisk()
        updated[key] = entry
        let unchanged = updated == lastPersistedEntries
        entries = updated
        if !unchanged {
            lastPersistedEntries = updated
        }
        lock.unlock()

        guard !unchanged else { return }
        do {
            let data = try JSONEncoder().encode(Array(updated.values))
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            logger.error("Failed to save authored mention reference cache: \(error.localizedDescription)")
        }
    }

    func clear() {
        lock.lock()
        entries = [:]
        lastPersistedEntries = [:]
        lock.unlock()

        try? FileManager.default.removeItem(at: cacheURL)
        logger.debug("Authored mention reference cache cleared")
    }

    private func loadEntries() -> [String: AuthoredMentionReferenceCacheEntry] {
        lock.lock()
        defer { lock.unlock() }

        if let entries {
            return entries
        }
        let loaded = readFromDisk()
        entries = loaded
        lastPersistedEntries = loaded
        return loaded
    }

    private func readFromDisk() -> [String: AuthoredMentionReferenceCacheEntry] {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return [:] }

        do {
            let data = try Data(contentsOf: cacheURL)
            let decoded = try JSONDecoder().decode(
                [AuthoredMentionReferenceCacheEntry].self,
                from: data
            )
            return Dictionary(
                decoded.map { (Self.key(for: $0.username), $0) },
                uniquingKeysWith: { _, last in last }
            )
        } catch {
            logger.error("Failed to load authored mention reference cache: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: cacheURL)
            return [:]
        }
    }

    private static func key(for username: String) -> String {
        username.lowercased()
    }
}


struct IndexSnapshot: Codable, Equatable {
    let updatedAt: Date
    let headOid: String?
    /// GitHub PR `updatedAt` does not reliably change when only CI moves, so
    /// cache invalidation needs the latest rollup state as a separate signal.
    let ciRollupState: String?
    let reviewThreadTotal: Int
    let commentTotal: Int
    let reviewTotal: Int
    /// Resolving a review thread on GitHub bumps neither `updatedAt` nor any
    /// count field, so without this extra dimension the cached PR detail
    /// (and its stale `isResolved` flags) would be reused for the full TTL.
    let unresolvedReviewThreadCount: Int
    /// A base-branch conflict appears when the base branch advances, which bumps
    /// none of the other scalars above. Tracking the derived flag here makes a
    /// conflict transition invalidate the cache so the detail (and the conflict
    /// badge) refreshes instead of going stale for the full TTL. `nil` only for
    /// legacy cache entries written before this field existed, which forces a
    /// one-time refetch.
    let hasBaseConflicts: Bool?
}

extension IndexSnapshot {
    private enum CodingKeys: String, CodingKey {
        case updatedAt
        case headOid
        case ciRollupState
        case reviewThreadTotal
        case commentTotal
        case reviewTotal
        case unresolvedReviewThreadCount
        case hasBaseConflicts
    }

    private static let missingCIRollupStateSentinel = "__missing_ci_rollup_state__"

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        headOid = try c.decodeIfPresent(String.self, forKey: .headOid)
        // Sentinel for pre-upgrade cache entries that never recorded CI rollup
        // state: forces a one-time cache miss so stale CI status does not keep
        // getting reused solely because `updatedAt` and `headOid` stayed flat.
        ciRollupState = try c.decodeIfPresent(
            String.self,
            forKey: .ciRollupState
        ) ?? Self.missingCIRollupStateSentinel
        reviewThreadTotal = try c.decode(Int.self, forKey: .reviewThreadTotal)
        commentTotal = try c.decode(Int.self, forKey: .commentTotal)
        reviewTotal = try c.decode(Int.self, forKey: .reviewTotal)
        // Sentinel (-1) for pre-upgrade cache entries that never recorded this
        // field: forces one-time cache-miss so the cached detail (which may
        // carry stale `isResolved` flags) is refetched once, not silently
        // reused because both old and new snapshots happen to read 0.
        unresolvedReviewThreadCount = try c.decodeIfPresent(
            Int.self,
            forKey: .unresolvedReviewThreadCount
        ) ?? -1
        // Absent in pre-upgrade entries: decoding to `nil` leaves the snapshot
        // unequal to any freshly-built one (which always carries a concrete
        // Bool), forcing a one-time refetch so the conflict badge is correct.
        hasBaseConflicts = try c.decodeIfPresent(Bool.self, forKey: .hasBaseConflicts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(headOid, forKey: .headOid)
        // Never persist the migration sentinel: it's a one-shot decode-time
        // marker. Writing it back would leave legacy entries permanently
        // unequal to any real rollup state, defeating a future read where
        // the field *is* present.
        let rollupForEncode = ciRollupState == Self.missingCIRollupStateSentinel ? nil : ciRollupState
        try c.encodeIfPresent(rollupForEncode, forKey: .ciRollupState)
        try c.encode(reviewThreadTotal, forKey: .reviewThreadTotal)
        try c.encode(commentTotal, forKey: .commentTotal)
        try c.encode(reviewTotal, forKey: .reviewTotal)
        try c.encode(unresolvedReviewThreadCount, forKey: .unresolvedReviewThreadCount)
        try c.encodeIfPresent(hasBaseConflicts, forKey: .hasBaseConflicts)
    }
}

struct CachedPRDetail: Codable {
    private static let currentCIContextParserVersion = 4

    let prId: Int
    let indexSnapshot: IndexSnapshot
    let detail: PullRequest
    let detailFetchedAt: Date
    let ciContextParserVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case prId
        case indexSnapshot
        case detail
        case detailFetchedAt
        case ciContextParserVersion
    }

    init(
        prId: Int,
        indexSnapshot: IndexSnapshot,
        detail: PullRequest,
        detailFetchedAt: Date,
        ciContextParserVersion: Int? = Self.currentCIContextParserVersion
    ) {
        self.prId = prId
        self.indexSnapshot = indexSnapshot
        var sanitizedDetail = detail
        sanitizedDetail.mentionCount = nil
        self.detail = sanitizedDetail
        self.detailFetchedAt = detailFetchedAt
        self.ciContextParserVersion = ciContextParserVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prId = try container.decode(Int.self, forKey: .prId)
        indexSnapshot = try container.decode(IndexSnapshot.self, forKey: .indexSnapshot)
        var sanitizedDetail = try container.decode(PullRequest.self, forKey: .detail)
        sanitizedDetail.mentionCount = nil
        detail = sanitizedDetail
        detailFetchedAt = try container.decode(Date.self, forKey: .detailFetchedAt)
        ciContextParserVersion = try container.decodeIfPresent(Int.self, forKey: .ciContextParserVersion)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prId, forKey: .prId)
        try container.encode(indexSnapshot, forKey: .indexSnapshot)
        var sanitizedDetail = detail
        sanitizedDetail.mentionCount = nil
        try container.encode(sanitizedDetail, forKey: .detail)
        try container.encode(detailFetchedAt, forKey: .detailFetchedAt)
        try container.encodeIfPresent(ciContextParserVersion, forKey: .ciContextParserVersion)
    }

    /// Cache hit when index scalars match, the entry is still within TTL, and
    /// the cached CI state is terminal. GitHub PR `updatedAt` is not a reliable
    /// signal for CI-only changes, so in-flight CI results are always refreshed
    /// on the next normal poll instead of being reused for the full TTL.
    func isUsable(against snapshot: IndexSnapshot, now: Date, ttl: TimeInterval) -> Bool {
        guard ciContextParserVersion == Self.currentCIContextParserVersion else { return false }
        guard indexSnapshot == snapshot else { return false }
        guard now.timeIntervalSince(detailFetchedAt) < ttl else { return false }
        guard detail.hasHoverDetailMetadata else { return false }
        return !detail.ciIsInFlight
    }
}

final class PRDetailCache {
    static let shared = PRDetailCache()

    static let ttl: TimeInterval = 24 * 60 * 60

    private let logger = Logger(subsystem: "com.prdashboard", category: "PRDetailCache")
    private let cacheURL: URL
    private let maxEntries = 500
    private let lock = NSLock()
    private var entries: [Int: CachedPRDetail]?
    private var lastPersistedEntries: [Int: CachedPRDetail] = [:]

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.prdashboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheURL = cacheDir.appendingPathComponent("pr_detail_cache.json")
    }

    func loadEntries() -> [Int: CachedPRDetail] {
        lock.lock()
        defer { lock.unlock() }

        if let cached = entries { return cached }

        let loaded = readFromDisk()
        entries = loaded
        lastPersistedEntries = loaded
        return loaded
    }

    /// Merge updates into the cache and persist. Returns the trimmed, persisted set.
    @discardableResult
    func upsert(_ updates: [CachedPRDetail]) -> [Int: CachedPRDetail] {
        lock.lock()
        var merged = entries ?? readFromDisk()
        for entry in updates {
            merged[entry.prId] = entry
        }
        let trimmed = trim(merged)
        entries = trimmed
        let shouldPersist = trimmed != lastPersistedEntries
        if shouldPersist {
            lastPersistedEntries = trimmed
        }
        lock.unlock()

        if shouldPersist {
            persist(trimmed)
        }
        return trimmed
    }

    func clear() {
        lock.lock()
        entries = [:]
        lastPersistedEntries = [:]
        lock.unlock()

        try? FileManager.default.removeItem(at: cacheURL)
        logger.debug("PR detail cache cleared")
    }

    private func persist(_ snapshot: [Int: CachedPRDetail]) {
        do {
            let data = try JSONEncoder().encode(Array(snapshot.values))
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            logger.error("Failed to save PR detail cache: \(error.localizedDescription)")
        }
    }

    private func trim(_ input: [Int: CachedPRDetail]) -> [Int: CachedPRDetail] {
        guard input.count > maxEntries else { return input }
        let retained = input.values
            .sorted { $0.detailFetchedAt > $1.detailFetchedAt }
            .prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: retained.map { ($0.prId, $0) })
    }

    private func readFromDisk() -> [Int: CachedPRDetail] {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return [:] }

        do {
            let data = try Data(contentsOf: cacheURL)
            let decoded = try JSONDecoder().decode([CachedPRDetail].self, from: data)
            return Dictionary(uniqueKeysWithValues: decoded.map { ($0.prId, $0) })
        } catch {
            logger.error("Failed to load PR detail cache: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: cacheURL)
            return [:]
        }
    }
}

extension CachedPRDetail: Equatable {
    static func == (lhs: CachedPRDetail, rhs: CachedPRDetail) -> Bool {
        lhs.prId == rhs.prId
            && lhs.indexSnapshot == rhs.indexSnapshot
            && lhs.detailFetchedAt == rhs.detailFetchedAt
            && lhs.detail.id == rhs.detail.id
    }
}

