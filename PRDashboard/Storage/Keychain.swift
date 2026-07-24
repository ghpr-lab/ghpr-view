import Foundation
import Security

enum KeychainError: Error {
    case duplicateItem
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case invalidData
}

// Type alias for backward compatibility
typealias KeychainHelper = Keychain

final class Keychain {
    static let shared = Keychain()

    private static let defaultService = "com.xiaocang.PRDashboard"
    private let service: String
    private let authStateKey = "github_auth_state"
    private let proxyPasswordKey = "http_proxy_password"
    private let jiraAPITokenKey = "jira_api_token"

    // Legacy keys for migration
    private let legacyTokenKey = "github_token"
    private let legacyUsernameKey = "github_username"
    private let legacyAuthMethodKey = "github_auth_method"

    private struct CachedValue {
        let value: String?
    }

    private let lock = NSLock()
    private var cachedValues: [String: CachedValue] = [:]

    #if DEBUG
    private var keychainReadCount = 0
    #endif

    private init(service: String = Keychain.defaultService) {
        self.service = service
    }

    // MARK: - AuthState (consolidated as single JSON item)

    static func saveAuthState(_ state: AuthState) throws {
        try shared.saveAuthStateValue(state)
    }

    static func loadAuthState() -> AuthState {
        shared.loadAuthStateValue()
    }

    /// Drops only the process-local auth cache. Persisted Keychain data is untouched.
    static func invalidateAuthStateCache() {
        shared.invalidateAuthStateCacheValue()
    }

    static func deleteAuthState() {
        shared.deleteAuthStateValue()
    }

    // MARK: - HTTP Proxy Password

    static func saveProxyPassword(_ password: String) {
        shared.saveProxyPasswordValue(password)
    }

    static func loadProxyPassword() -> String {
        shared.loadProxyPasswordValue()
    }

    static func deleteProxyPassword() {
        shared.deleteProxyPasswordValue()
    }

    // MARK: - Jira API Token

    static func saveJiraAPIToken(_ token: String) {
        shared.saveJiraAPITokenValue(token)
    }

    static func loadJiraAPIToken() -> String {
        shared.loadJiraAPITokenValue()
    }

    static func invalidateJiraAPITokenCache(rejectedToken: String) {
        shared.invalidateCachedValue(key: shared.jiraAPITokenKey, ifMatching: rejectedToken)
    }

    static func deleteJiraAPIToken() {
        shared.deleteJiraAPITokenValue()
    }

    // MARK: - Private value operations

    private func saveAuthStateValue(_ state: AuthState) throws {
        let data = try JSONEncoder().encode(state)
        guard let json = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        try saveCachedValue(json, key: authStateKey)
    }

    private func loadAuthStateValue() -> AuthState {
        // Try loading from new consolidated key first.
        if let json = try? loadCachedValue(key: authStateKey),
           let data = json.data(using: .utf8),
           let state = try? JSONDecoder().decode(AuthState.self, from: data) {
            return state
        }

        // Migration: try loading from legacy separate keys.
        let token = try? loadCachedValue(key: legacyTokenKey)
        let username = try? loadCachedValue(key: legacyUsernameKey)
        var authMethod: AuthMethod?
        if let methodRaw = try? loadCachedValue(key: legacyAuthMethodKey) {
            authMethod = AuthMethod(rawValue: methodRaw)
        }

        let state = AuthState(accessToken: token, username: username, authMethod: authMethod)

        // If we found legacy data, migrate to new format and clean up.
        if token != nil {
            try? saveAuthStateValue(state)
            deleteCachedValue(key: legacyTokenKey)
            deleteCachedValue(key: legacyUsernameKey)
            deleteCachedValue(key: legacyAuthMethodKey)
        }

        return state
    }

    private func deleteAuthStateValue() {
        deleteCachedValue(key: authStateKey)
        deleteCachedValue(key: legacyTokenKey)
        deleteCachedValue(key: legacyUsernameKey)
        deleteCachedValue(key: legacyAuthMethodKey)
    }

    private func invalidateAuthStateCacheValue() {
        lock.lock()
        cachedValues.removeValue(forKey: authStateKey)
        cachedValues.removeValue(forKey: legacyTokenKey)
        cachedValues.removeValue(forKey: legacyUsernameKey)
        cachedValues.removeValue(forKey: legacyAuthMethodKey)
        lock.unlock()
    }

    private func saveProxyPasswordValue(_ password: String) {
        if password.isEmpty {
            deleteProxyPasswordValue()
            return
        }
        try? saveCachedValue(password, key: proxyPasswordKey)
    }

    private func loadProxyPasswordValue() -> String {
        (try? loadCachedValue(key: proxyPasswordKey)) ?? ""
    }

    private func deleteProxyPasswordValue() {
        deleteCachedValue(key: proxyPasswordKey)
    }

    private func saveJiraAPITokenValue(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteJiraAPITokenValue()
            return
        }
        try? saveCachedValue(trimmed, key: jiraAPITokenKey)
    }

    private func loadJiraAPITokenValue() -> String {
        (try? loadCachedValue(key: jiraAPITokenKey)) ?? ""
    }

    private func deleteJiraAPITokenValue() {
        deleteCachedValue(key: jiraAPITokenKey)
    }

    private func invalidateCachedValue(key: String, ifMatching value: String) {
        lock.lock()
        if cachedValues[key]?.value == value {
            cachedValues.removeValue(forKey: key)
        }
        lock.unlock()
    }

    // MARK: - In-memory cache

    private func saveCachedValue(_ value: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        do {
            try save(value: value, key: key)
            cachedValues[key] = CachedValue(value: value)
        } catch {
            // The save implementation deletes the old item before adding the
            // new one, so an unsuccessful save must not leave stale memory.
            cachedValues.removeValue(forKey: key)
            throw error
        }
    }

    private func loadCachedValue(key: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedValues[key] {
            guard let value = cached.value else {
                throw KeychainError.itemNotFound
            }
            return value
        }

        do {
            let value = try load(key: key)
            cachedValues[key] = CachedValue(value: value)
            return value
        } catch let error as KeychainError {
            if case .itemNotFound = error {
                // Cache absence as well as presence, so repeated optional
                // credential reads do not hit SecItemCopyMatching.
                cachedValues[key] = CachedValue(value: nil)
            }
            throw error
        }
    }

    private func deleteCachedValue(key: String) {
        lock.lock()
        // Clear memory before touching Keychain. Even if deletion fails, the
        // current process must not continue using the deleted secret.
        cachedValues.removeValue(forKey: key)
        defer { lock.unlock() }
        try? delete(key: key)
    }

    // MARK: - Keychain I/O

    private func save(value: String, key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // Delete existing item first.
        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            if status == errSecDuplicateItem {
                throw KeychainError.duplicateItem
            }
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func load(key: String) throws -> String {
        #if DEBUG
        keychainReadCount += 1
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return value
    }

    private func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    #if DEBUG
    // Test-only isolated Keychain instance. It uses a unique service supplied
    // by the test and never touches the application's credential entries.
    init(serviceForTesting: String) {
        self.service = serviceForTesting
    }

    var keychainReadCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return keychainReadCount
    }

    func saveAuthStateForTesting(_ state: AuthState) throws {
        try saveAuthStateValue(state)
    }

    func loadAuthStateForTesting() -> AuthState {
        loadAuthStateValue()
    }

    func invalidateAuthStateCacheForTesting() {
        invalidateAuthStateCacheValue()
    }

    func deleteAuthStateForTesting() {
        deleteAuthStateValue()
    }

    func saveProxyPasswordForTesting(_ password: String) {
        saveProxyPasswordValue(password)
    }

    func loadProxyPasswordForTesting() -> String {
        loadProxyPasswordValue()
    }

    func deleteProxyPasswordForTesting() {
        deleteProxyPasswordValue()
    }

    func saveJiraAPITokenForTesting(_ token: String) {
        saveJiraAPITokenValue(token)
    }

    func loadJiraAPITokenForTesting() -> String {
        loadJiraAPITokenValue()
    }

    func invalidateJiraAPITokenCacheForTesting(rejectedToken: String) {
        invalidateCachedValue(key: jiraAPITokenKey, ifMatching: rejectedToken)
    }

    func deleteJiraAPITokenForTesting() {
        deleteJiraAPITokenValue()
    }
    #endif
}
