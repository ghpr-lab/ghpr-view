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

struct MentionCacheEntry: Codable, Equatable {
    let sourcePRID: Int
    let sourceUpdatedAt: Date
    let references: [PullRequestReference]
    let cachedAt: Date

    var pullRequestReferences: Set<PullRequestReference> {
        Set(references)
    }

    /// Cache hit (skip network) when: TTL unexpired AND
    /// (source PR unchanged OR still within cooldown window).
    func isUsable(currentUpdatedAt: Date, now: Date, ttl: TimeInterval, cooldown: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(cachedAt)
        guard age < ttl else { return false }
        if sourceUpdatedAt == currentUpdatedAt { return true }
        return age < cooldown
    }
}

struct IndexSnapshot: Codable, Equatable {
    let updatedAt: Date
    let headOid: String?
    let reviewThreadTotal: Int
    let commentTotal: Int
    let reviewTotal: Int
    /// Resolving a review thread on GitHub bumps neither `updatedAt` nor any
    /// count field, so without this extra dimension the cached PR detail
    /// (and its stale `isResolved` flags) would be reused for the full TTL.
    let unresolvedReviewThreadCount: Int
}

extension IndexSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        headOid = try c.decodeIfPresent(String.self, forKey: .headOid)
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
    }
}

struct CachedPRDetail: Codable {
    let prId: Int
    let indexSnapshot: IndexSnapshot
    let detail: PullRequest
    let detailFetchedAt: Date

    /// Cache hit when index scalars match AND within TTL.
    /// updatedAt bumps whenever anything material changes on GitHub's side
    /// (new comment, thread resolved, review added, CI updated), so it's the
    /// primary signal. The TTL is a 24h sanity net against undetected drift.
    func isUsable(against snapshot: IndexSnapshot, now: Date, ttl: TimeInterval) -> Bool {
        guard indexSnapshot == snapshot else { return false }
        return now.timeIntervalSince(detailFetchedAt) < ttl
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

final class MentionCache {
    static let shared = MentionCache()

    static let ttl: TimeInterval = 30 * 60
    static let cooldown: TimeInterval = 5 * 60

    private let logger = Logger(subsystem: "com.prdashboard", category: "MentionCache")
    private let cacheURL: URL
    private let maxEntries = 500
    private let lock = NSLock()
    private var entries: [Int: MentionCacheEntry]?
    private var lastPersistedEntries: [Int: MentionCacheEntry] = [:]

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.prdashboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheURL = cacheDir.appendingPathComponent("mention_cache.json")
    }

    func loadEntries() -> [Int: MentionCacheEntry] {
        lock.lock()
        defer { lock.unlock() }

        if let cached = entries { return cached }

        let loaded = readFromDisk()
        entries = loaded
        lastPersistedEntries = loaded
        return loaded
    }

    func saveEntries(_ newEntries: [Int: MentionCacheEntry]) {
        let trimmed = trim(newEntries)

        lock.lock()
        let unchanged = trimmed == lastPersistedEntries
        entries = trimmed
        if !unchanged { lastPersistedEntries = trimmed }
        lock.unlock()

        if unchanged { return }

        do {
            let data = try JSONEncoder().encode(Array(trimmed.values))
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            logger.error("Failed to save mention cache: \(error.localizedDescription)")
        }
    }

    func clear() {
        lock.lock()
        entries = [:]
        lastPersistedEntries = [:]
        lock.unlock()

        try? FileManager.default.removeItem(at: cacheURL)
        logger.debug("Mention cache cleared")
    }

    private func trim(_ input: [Int: MentionCacheEntry]) -> [Int: MentionCacheEntry] {
        guard input.count > maxEntries else { return input }
        let retained = input.values
            .sorted { $0.cachedAt > $1.cachedAt }
            .prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: retained.map { ($0.sourcePRID, $0) })
    }

    private func readFromDisk() -> [Int: MentionCacheEntry] {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return [:] }

        do {
            let data = try Data(contentsOf: cacheURL)
            let decoded = try JSONDecoder().decode([MentionCacheEntry].self, from: data)
            return Dictionary(uniqueKeysWithValues: decoded.map { ($0.sourcePRID, $0) })
        } catch {
            logger.error("Failed to load mention cache: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: cacheURL)
            return [:]
        }
    }
}
