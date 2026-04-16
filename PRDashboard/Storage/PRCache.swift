import Foundation
import os

class PRCache {
    static let shared = PRCache()

    private let logger = Logger(subsystem: "com.prdashboard", category: "PRCache")
    private let cacheURL: URL
    private let maxAge: TimeInterval = 3600  // 1 hour

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

    /// Load cache. If ignoreExpiry is true, returns cache even if > 1 hour old (for fallback)
    func load(ignoreExpiry: Bool = false) -> PRList? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: cacheURL)
            let prList = try JSONDecoder().decode(PRList.self, from: data)

            // Check expiry (1 hour) unless ignoring for fallback
            if !ignoreExpiry && Date().timeIntervalSince(prList.lastUpdated) > maxAge {
                logger.info("Cache expired (older than 1 hour)")
                return nil
            }

            logger.debug("Loaded \(prList.pullRequests.count) PRs from cache")
            return prList
        } catch {
            // Corrupted cache - silently delete
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
