import Foundation
import os

private let jiraLogger = Logger(subsystem: "com.prdashboard", category: "JiraAPIClient")
private let jiraMetadataCacheSchemaVersion = 2

struct JiraIssueMetadata: Codable, Equatable {
    let key: String
    var title: String? = nil
    var labels: [String]
    var statusName: String?
    var statusCategoryKey: String?
    var updatedAt: Date?
    var fetchedAt: Date
    var metadataSchemaVersion: Int? = jiraMetadataCacheSchemaVersion
}

struct JiraConnectionTestResult: Equatable {
    let displayName: String?
    let emailAddress: String?
}

enum JiraAPIError: LocalizedError {
    case invalidServerURL
    case unauthorized
    case http(statusCode: Int)
    case invalidResponse
    case decoding(Error)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return String(localized: "Invalid Jira server URL")
        case .unauthorized:
            return String(localized: "Invalid Jira email or API token")
        case .http(let statusCode):
            return String(localized: "Jira request failed (HTTP \(statusCode))")
        case .invalidResponse:
            return String(localized: "Invalid response from Jira")
        case .decoding(let error):
            return String(localized: "Failed to parse Jira response: \(error.localizedDescription)")
        case .network(let error):
            return String(localized: "Jira network error: \(error.localizedDescription)")
        }
    }
}

final class JiraMetadataCache {
    static let shared = JiraMetadataCache()

    private let defaults: UserDefaults
    private let cacheKey = "PRDashboard.JiraIssueMetadataCache"
    private let maxCacheSize = 1000
    private let lock = NSLock()
    private var inMemoryCache: [String: JiraIssueMetadata]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func freshMetadata(
        for issueKeys: Set<String>,
        serverURL: String,
        now: Date = Date(),
        refreshInterval: TimeInterval
    ) -> (metadata: [String: JiraIssueMetadata], keysToFetch: [String]) {
        guard let normalizedServer = JiraAPIClient.normalizedServerURL(serverURL) else {
            return ([:], [])
        }

        let cache = loadCache()
        var metadata: [String: JiraIssueMetadata] = [:]
        var keysToFetch: [String] = []
        let ttl = max(refreshInterval, 5 * 60)

        for rawKey in issueKeys {
            let key = Self.normalizeIssueKey(rawKey)
            let storageKey = storageKey(serverURL: normalizedServer, issueKey: key)
            if let cached = cache[storageKey],
               cached.metadataSchemaVersion == jiraMetadataCacheSchemaVersion,
               now.timeIntervalSince(cached.fetchedAt) < ttl {
                metadata[key] = cached
            } else {
                keysToFetch.append(key)
            }
        }

        return (metadata, keysToFetch)
    }

    func save(_ metadata: [String: JiraIssueMetadata], serverURL: String) {
        guard let normalizedServer = JiraAPIClient.normalizedServerURL(serverURL),
              !metadata.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var cache = loadCacheLocked()
        for issue in metadata.values {
            let key = Self.normalizeIssueKey(issue.key)
            cache[storageKey(serverURL: normalizedServer, issueKey: key)] = issue
        }

        if cache.count > maxCacheSize {
            cache = Dictionary(
                uniqueKeysWithValues: cache
                    .sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                    .prefix(maxCacheSize)
                    .map { ($0.key, $0.value) }
            )
        }

        inMemoryCache = cache
        persistLocked(cache)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        inMemoryCache = [:]
        defaults.removeObject(forKey: cacheKey)
    }

    static func normalizeIssueKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func storageKey(serverURL: String, issueKey: String) -> String {
        "\(serverURL)|\(issueKey)"
    }

    private func loadCache() -> [String: JiraIssueMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return loadCacheLocked()
    }

    private func loadCacheLocked() -> [String: JiraIssueMetadata] {
        if let cached = inMemoryCache { return cached }
        guard let data = defaults.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode([String: JiraIssueMetadata].self, from: data) else {
            inMemoryCache = [:]
            return [:]
        }
        inMemoryCache = cache
        return cache
    }

    private func persistLocked(_ cache: [String: JiraIssueMetadata]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}

final class JiraAPIClient {
    private static let batchSize = 50

    private let session: URLSession
    private let cache: JiraMetadataCache

    init(session: URLSession = .shared, cache: JiraMetadataCache = .shared) {
        self.session = session
        self.cache = cache
    }

    func fetchMetadata(
        for issueKeys: Set<String>,
        serverURL: String,
        email: String,
        apiToken: String,
        refreshInterval: TimeInterval,
        now: Date = Date()
    ) async throws -> [String: JiraIssueMetadata] {
        guard let normalizedServer = Self.normalizedServerURL(serverURL) else {
            throw JiraAPIError.invalidServerURL
        }

        let cached = cache.freshMetadata(
            for: issueKeys,
            serverURL: normalizedServer,
            now: now,
            refreshInterval: refreshInterval
        )

        guard !cached.keysToFetch.isEmpty else {
            return cached.metadata
        }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else {
            return cached.metadata
        }

        var result = cached.metadata
        var fetchedAll: [String: JiraIssueMetadata] = [:]
        var firstError: Error?

        for batchStart in stride(from: 0, to: cached.keysToFetch.count, by: Self.batchSize) {
            let end = min(batchStart + Self.batchSize, cached.keysToFetch.count)
            let batch = Array(cached.keysToFetch[batchStart..<end])
            do {
                let fetched = try await fetchBatch(
                    batch,
                    serverURL: normalizedServer,
                    email: trimmedEmail,
                    apiToken: trimmedToken,
                    now: now
                )
                result.merge(fetched) { _, new in new }
                fetchedAll.merge(fetched) { _, new in new }
            } catch {
                jiraLogger.error("Failed to fetch Jira batch: \(error.localizedDescription, privacy: .public)")
                firstError = firstError ?? error
            }
        }

        if !fetchedAll.isEmpty {
            cache.save(fetchedAll, serverURL: normalizedServer)
        }

        // Only throw when every batch failed AND we have nothing else to return.
        if result.isEmpty, let firstError {
            throw firstError
        }

        return result
    }

    static func normalizedServerURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        guard let normalized = components.url?.absoluteString else { return nil }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func issueURL(serverURL: String, issueKey: String?) -> URL? {
        guard let issueKey = issueKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !issueKey.isEmpty,
              let normalizedServer = normalizedServerURL(serverURL) else {
            return nil
        }
        return URL(string: "\(normalizedServer)/browse/\(issueKey)")
    }

    func testConnection(
        serverURL: String,
        email: String,
        apiToken: String
    ) async throws -> JiraConnectionTestResult {
        guard let normalizedServer = Self.normalizedServerURL(serverURL),
              let url = URL(string: "\(normalizedServer)/rest/api/3/myself") else {
            throw JiraAPIError.invalidServerURL
        }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else {
            throw JiraAPIError.unauthorized
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.basicAuthHeader(email: trimmedEmail, apiToken: trimmedToken), forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JiraAPIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw JiraAPIError.invalidResponse
        }
        guard http.statusCode != 401 && http.statusCode != 403 else {
            throw JiraAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JiraAPIError.http(statusCode: http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(JiraMyselfResponse.self, from: data)
            return JiraConnectionTestResult(
                displayName: decoded.displayName,
                emailAddress: decoded.emailAddress
            )
        } catch {
            throw JiraAPIError.decoding(error)
        }
    }

    private func fetchBatch(
        _ issueKeys: [String],
        serverURL: String,
        email: String,
        apiToken: String,
        now: Date
    ) async throws -> [String: JiraIssueMetadata] {
        guard let url = URL(string: "\(serverURL)/rest/api/3/search/jql") else {
            throw JiraAPIError.invalidServerURL
        }

        let jql = "key in (\(issueKeys.joined(separator: ",")))"
        let payload: [String: Any] = [
            "jql": jql,
            "fields": ["summary", "labels", "status", "updated"],
            "maxResults": issueKeys.count
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.basicAuthHeader(email: email, apiToken: apiToken), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JiraAPIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw JiraAPIError.invalidResponse
        }
        guard http.statusCode != 401 && http.statusCode != 403 else {
            throw JiraAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JiraAPIError.http(statusCode: http.statusCode)
        }

        let decoded: JiraSearchResponse
        do {
            decoded = try JSONDecoder().decode(JiraSearchResponse.self, from: data)
        } catch {
            throw JiraAPIError.decoding(error)
        }

        var metadata: [String: JiraIssueMetadata] = [:]
        for issue in decoded.issues {
            let key = JiraMetadataCache.normalizeIssueKey(issue.key)
            metadata[key] = JiraIssueMetadata(
                key: key,
                title: issue.fields.summary,
                labels: issue.fields.labels ?? [],
                statusName: issue.fields.status?.name,
                statusCategoryKey: issue.fields.status?.statusCategory?.key,
                updatedAt: Self.parseJiraDate(issue.fields.updated),
                fetchedAt: now
            )
        }

        for key in issueKeys where metadata[key] == nil {
            metadata[key] = JiraIssueMetadata(
                key: key,
                title: nil,
                labels: [],
                statusName: nil,
                statusCategoryKey: nil,
                updatedAt: nil,
                fetchedAt: now
            )
        }

        jiraLogger.info("Fetched Jira metadata for \(metadata.count, privacy: .public) issue(s)")
        return metadata
    }

    private static func basicAuthHeader(email: String, apiToken: String) -> String {
        let raw = "\(email):\(apiToken)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    // Jira returns timestamps like "2026-05-20T13:14:15.123+0000" (RFC 822 offset);
    // ISO8601DateFormatter requires the "+00:00" form, so we keep a dedicated parser.
    private static let jiraDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    private static func parseJiraDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return jiraDateFormatter.date(from: raw)
            ?? DateFormatters.parseISO8601(raw)
    }
}

private struct JiraMyselfResponse: Decodable {
    let displayName: String?
    let emailAddress: String?
}

private struct JiraSearchResponse: Decodable {
    let issues: [Issue]

    struct Issue: Decodable {
        let key: String
        let fields: Fields
    }

    struct Fields: Decodable {
        let summary: String?
        let labels: [String]?
        let status: Status?
        let updated: String?
    }

    struct Status: Decodable {
        let name: String?
        let statusCategory: StatusCategory?
    }

    struct StatusCategory: Decodable {
        let key: String?
    }
}
