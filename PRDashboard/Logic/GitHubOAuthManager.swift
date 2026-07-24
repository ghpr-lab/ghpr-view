import Foundation
import AppKit

@MainActor
class GitHubOAuthManager: NSObject, ObservableObject {
    // OAuth App credentials
    // Create at: https://github.com/settings/developers
    private let clientID = "Ov23liGCAVv1nOHzVVhf"
    private let scope = "repo read:user workflow"
    // GitHub classic PAT scopes are not strictly prefix-structured.
    // For example, `user` is broader than `read:user`, but does not share
    // a `read:user:` prefix, so we encode those implications explicitly.
    private nonisolated static let impliedScopesByGrantedScope: [String: Set<String>] = [
        "user": ["read:user"]
    ]

    @Published private(set) var authState: AuthState = .empty
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authError: Error?

    // Device Flow properties
    @Published private(set) var deviceCode: DeviceCodeInfo?

    // PAT properties
    @Published private(set) var isValidatingPAT = false
    @Published private(set) var patError: Error?

    private var pollingTask: Task<Void, Never>?
    private let loadPersistedAuthState: () -> AuthState
    private let invalidatePersistedAuthCache: () -> Void


    init(
        loadSavedAuth: Bool = true,
        loadPersistedAuthState: @escaping () -> AuthState = { KeychainHelper.loadAuthState() },
        invalidatePersistedAuthCache: @escaping () -> Void = { KeychainHelper.invalidateAuthStateCache() }
    ) {
        self.loadPersistedAuthState = loadPersistedAuthState
        self.invalidatePersistedAuthCache = invalidatePersistedAuthCache
        super.init()
        if loadSavedAuth {
            self.loadSavedAuth()
        }
    }

    // MARK: - Public Methods

    func signIn() {
        guard !isAuthenticating else { return }

        isAuthenticating = true
        authError = nil
        deviceCode = nil

        Task {
            await startDeviceFlow()
        }
    }

    func cancelSignIn() {
        pollingTask?.cancel()
        pollingTask = nil
        isAuthenticating = false
        deviceCode = nil
    }

    func signOut() {
        cancelSignIn()
        KeychainHelper.deleteAuthState()
        authState = .empty
        authError = nil
        patError = nil
    }

    // MARK: - PAT Authentication

    func signInWithPAT(_ token: String) async {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanToken.isEmpty else {
            patError = PATError.emptyToken
            return
        }

        isValidatingPAT = true
        patError = nil

        do {
            // Validate token and check scopes
            let (isValid, scopes) = try await validatePATWithScopes(token: cleanToken)

            guard isValid else {
                throw PATError.invalidToken
            }

            // Match required scopes through the helper so broader classic scopes
            // like `user` count for narrower requirements like `read:user`.
            let requiredScopes = ["repo", "read:user", "workflow"]
            let missingScopes = requiredScopes.filter { required in
                !Self.grantedScopes(scopes, satisfy: required)
            }

            if !missingScopes.isEmpty {
                throw PATError.insufficientScopes(missing: missingScopes)
            }

            // Fetch username
            let username = try await fetchUsername(token: cleanToken)

            // Save auth state
            let newAuthState = AuthState(
                accessToken: cleanToken,
                username: username,
                authMethod: .pat
            )
            try KeychainHelper.saveAuthState(newAuthState)
            authState = newAuthState

        } catch let error as PATError {
            patError = error
        } catch {
            patError = PATError.networkError(error)
        }

        isValidatingPAT = false
    }

    func clearPATError() {
        patError = nil
    }

    private func validatePATWithScopes(token: String) async throws -> (Bool, [String]) {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return (false, [])
        }

        guard httpResponse.statusCode == 200 else {
            return (false, [])
        }

        // Parse X-OAuth-Scopes header for scope checking
        let scopesHeader = httpResponse.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? ""
        let scopes = scopesHeader.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        return (true, scopes)
    }

    // Accept exact matches, prefix-shaped subscopes, and the explicit broader
    // classic-scope implications declared above.
    nonisolated static func grantedScopes(_ scopes: [String], satisfy requiredScope: String) -> Bool {
        scopes.contains { grantedScope in
            if grantedScope == requiredScope || grantedScope.hasPrefix("\(requiredScope):") {
                return true
            }

            return impliedScopesByGrantedScope[grantedScope]?.contains(requiredScope) == true
        }
    }

    func loadSavedAuth() {
        authState = loadPersistedAuthState()

        // If we have a token but no username, fetch it
        if authState.accessToken != nil && authState.username == nil {
            Task {
                await fetchAndUpdateUsername()
            }
        }
    }

    func handleRejectedToken(_ rejectedToken: String) {
        // A late 401 from an older request must not replace a token that the
        // user has already updated.
        guard authState.accessToken == rejectedToken else { return }

        invalidatePersistedAuthCache()
        let refreshedState = loadPersistedAuthState()
        if let refreshedToken = refreshedState.accessToken,
           refreshedToken != rejectedToken {
            authError = nil
            authState = refreshedState
            return
        }

        // Do not retain the rejected value loaded from persistent Keychain.
        if refreshedState.accessToken == rejectedToken {
            invalidatePersistedAuthCache()
        }
        authState = .empty
        authError = APIError.unauthorized
    }

    func openVerificationURL() {
        guard let urlString = deviceCode?.verificationURI,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyUserCode() {
        guard let code = deviceCode?.userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    // MARK: - Device Flow

    private func startDeviceFlow() async {
        do {
            // Step 1: Request device code
            let codeInfo = try await requestDeviceCode()
            deviceCode = codeInfo

            // Step 2: Poll for token
            pollingTask = Task {
                await pollForToken(deviceCode: codeInfo.deviceCode, interval: codeInfo.interval)
            }
        } catch {
            isAuthenticating = false
            authError = error
        }
    }

    private func requestDeviceCode() async throws -> DeviceCodeInfo {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientID,
            "scope": scope
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OAuthError.deviceCodeFailed
        }

        return try JSONDecoder().decode(DeviceCodeInfo.self, from: data)
    }

    private func pollForToken(deviceCode: String, interval: Int) async {
        let pollInterval = max(interval, 5) // Minimum 5 seconds

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)

            if Task.isCancelled { break }

            do {
                let result = try await checkForToken(deviceCode: deviceCode)

                switch result {
                case .success(let token):
                    let username = try await fetchUsername(token: token)
                    let newAuthState = AuthState(accessToken: token, username: username, authMethod: .oauth)
                    try KeychainHelper.saveAuthState(newAuthState)
                    authState = newAuthState
                    self.deviceCode = nil
                    isAuthenticating = false
                    return

                case .pending:
                    // Keep polling
                    continue

                case .slowDown:
                    // Wait extra time
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue

                case .error(let message):
                    throw OAuthError.tokenExchangeFailed(message)
                }
            } catch {
                authError = error
                self.deviceCode = nil
                isAuthenticating = false
                return
            }
        }
    }

    private func checkForToken(deviceCode: String) async throws -> TokenPollResult {
        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed(String(localized: "HTTP error"))
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        if let token = tokenResponse.accessToken {
            return .success(token)
        }

        switch tokenResponse.error {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown
        case "expired_token":
            return .error(String(localized: "Code expired. Please try again."))
        case "access_denied":
            return .error(String(localized: "Access denied by user."))
        default:
            return .error(tokenResponse.error ?? String(localized: "Unknown error"))
        }
    }

    private func fetchAndUpdateUsername() async {
        guard let token = authState.accessToken else { return }

        do {
            let username = try await fetchUsername(token: token)
            var updatedState = authState
            updatedState.username = username
            try KeychainHelper.saveAuthState(updatedState)
            authState = updatedState
        } catch {
            // Silently fail - we still have the token
        }
    }

    private func fetchUsername(token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OAuthError.userFetchFailed
        }

        let user = try JSONDecoder().decode(GitHubUser.self, from: data)
        return user.login
    }
}

// MARK: - Supporting Types

struct DeviceCodeInfo: Codable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private enum TokenPollResult {
    case success(String)
    case pending
    case slowDown
    case error(String)
}

enum OAuthError: LocalizedError {
    case deviceCodeFailed
    case tokenExchangeFailed(String)
    case userFetchFailed

    var errorDescription: String? {
        switch self {
        case .deviceCodeFailed:
            return String(localized: "Failed to get device code from GitHub")
        case .tokenExchangeFailed(let reason):
            return String(localized: "Failed to get access token: \(reason)")
        case .userFetchFailed:
            return String(localized: "Failed to fetch user information")
        }
    }
}

enum PATError: LocalizedError {
    case emptyToken
    case invalidToken
    case insufficientScopes(missing: [String])
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return String(localized: "Please enter a Personal Access Token")
        case .invalidToken:
            return String(localized: "The token is invalid or expired")
        case .insufficientScopes(let missing):
            return String(localized: "Token missing required scopes: \(missing.joined(separator: ", "))")
        case .networkError(let error):
            return String(localized: "Network error: \(error.localizedDescription)")
        }
    }
}

private struct TokenResponse: Codable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case error
        case errorDescription = "error_description"
    }
}

private struct GitHubUser: Codable {
    let login: String
}
