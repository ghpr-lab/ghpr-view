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

    private let service = "com.xiaocang.PRDashboard"
    private let authStateKey = "github_auth_state"
    private let proxyPasswordKey = "http_proxy_password"
    private let jiraAPITokenKey = "jira_api_token"

    // Legacy keys for migration
    private let legacyTokenKey = "github_token"
    private let legacyUsernameKey = "github_username"
    private let legacyAuthMethodKey = "github_auth_method"

    private init() {}

    // MARK: - Legacy methods (kept for migration only)

    // MARK: - AuthState (consolidated as single JSON item)

    static func saveAuthState(_ state: AuthState) throws {
        let data = try JSONEncoder().encode(state)
        guard let json = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        try shared.save(value: json, key: shared.authStateKey)
    }

    static func loadAuthState() -> AuthState {
        // Try loading from new consolidated key first
        if let json = try? shared.load(key: shared.authStateKey),
           let data = json.data(using: .utf8),
           let state = try? JSONDecoder().decode(AuthState.self, from: data) {
            return state
        }

        // Migration: try loading from legacy separate keys
        let token = try? shared.load(key: shared.legacyTokenKey)
        let username = try? shared.load(key: shared.legacyUsernameKey)
        var authMethod: AuthMethod?
        if let methodRaw = try? shared.load(key: shared.legacyAuthMethodKey) {
            authMethod = AuthMethod(rawValue: methodRaw)
        }

        let state = AuthState(accessToken: token, username: username, authMethod: authMethod)

        // If we found legacy data, migrate to new format and clean up
        if token != nil {
            try? saveAuthState(state)
            try? shared.delete(key: shared.legacyTokenKey)
            try? shared.delete(key: shared.legacyUsernameKey)
            try? shared.delete(key: shared.legacyAuthMethodKey)
        }

        return state
    }

    static func deleteAuthState() {
        try? shared.delete(key: shared.authStateKey)
        // Also clean up any legacy keys
        try? shared.delete(key: shared.legacyTokenKey)
        try? shared.delete(key: shared.legacyUsernameKey)
        try? shared.delete(key: shared.legacyAuthMethodKey)
    }

    // MARK: - HTTP Proxy Password

    static func saveProxyPassword(_ password: String) {
        if password.isEmpty {
            try? shared.delete(key: shared.proxyPasswordKey)
            return
        }
        try? shared.save(value: password, key: shared.proxyPasswordKey)
    }

    static func loadProxyPassword() -> String {
        (try? shared.load(key: shared.proxyPasswordKey)) ?? ""
    }

    static func deleteProxyPassword() {
        try? shared.delete(key: shared.proxyPasswordKey)
    }

    // MARK: - Jira API Token

    static func saveJiraAPIToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? shared.delete(key: shared.jiraAPITokenKey)
            return
        }
        try? shared.save(value: trimmed, key: shared.jiraAPITokenKey)
    }

    static func loadJiraAPIToken() -> String {
        (try? shared.load(key: shared.jiraAPITokenKey)) ?? ""
    }

    static func deleteJiraAPIToken() {
        try? shared.delete(key: shared.jiraAPITokenKey)
    }

    // MARK: - Private

    private func save(value: String, key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // Delete existing item first
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
}
