import Foundation

struct Configuration: Codable, Equatable {
    var refreshInterval: TimeInterval  // seconds, minimum 15
    var repositories: [String]         // ["owner/repo", ...] - empty means all
    var showDrafts: Bool
    var notificationsEnabled: Bool
    var refreshOnOpen: Bool            // refresh immediately when popover opens
    var ciStatusExcludeFilter: String  // keywords to exclude from CI status (e.g., "review")
    var pausePollingInLowPowerMode: Bool  // pause background polling when Low Power Mode is enabled
    var pausePollingOnExpensiveNetwork: Bool  // pause background polling on cellular/hotspot
    var showMyReviewStatus: Bool  // show my review status badges on review-requested PRs

    static var `default`: Configuration {
        Configuration(
            refreshInterval: 300,  // 5 minutes
            repositories: [],
            showDrafts: true,
            notificationsEnabled: true,
            refreshOnOpen: false,
            ciStatusExcludeFilter: "review",
            pausePollingInLowPowerMode: true,
            pausePollingOnExpensiveNetwork: true,
            showMyReviewStatus: false
        )
    }

    var isValid: Bool {
        refreshInterval >= 60
    }
}

enum ConfigurationError: LocalizedError {
    case invalidRefreshInterval

    var errorDescription: String? {
        switch self {
        case .invalidRefreshInterval:
            return String(localized: "Refresh interval must be at least 1 minute")
        }
    }
}

// Authentication method
enum AuthMethod: String, Codable {
    case oauth
    case pat  // Personal Access Token
}

// OAuth tokens stored separately in Keychain
struct AuthState: Codable, Equatable {
    var accessToken: String?
    var username: String?
    var authMethod: AuthMethod?

    var isAuthenticated: Bool {
        accessToken != nil
    }

    static var empty: AuthState {
        AuthState(accessToken: nil, username: nil, authMethod: nil)
    }
}
