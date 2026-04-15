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
    var automaticallyCheckForUpdates: Bool

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
            showMyReviewStatus: false,
            automaticallyCheckForUpdates: true
        )
    }

    init(
        refreshInterval: TimeInterval,
        repositories: [String],
        showDrafts: Bool,
        notificationsEnabled: Bool,
        refreshOnOpen: Bool,
        ciStatusExcludeFilter: String,
        pausePollingInLowPowerMode: Bool,
        pausePollingOnExpensiveNetwork: Bool,
        showMyReviewStatus: Bool,
        automaticallyCheckForUpdates: Bool
    ) {
        self.refreshInterval = refreshInterval
        self.repositories = repositories
        self.showDrafts = showDrafts
        self.notificationsEnabled = notificationsEnabled
        self.refreshOnOpen = refreshOnOpen
        self.ciStatusExcludeFilter = ciStatusExcludeFilter
        self.pausePollingInLowPowerMode = pausePollingInLowPowerMode
        self.pausePollingOnExpensiveNetwork = pausePollingOnExpensiveNetwork
        self.showMyReviewStatus = showMyReviewStatus
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
    }

    enum CodingKeys: String, CodingKey {
        case refreshInterval
        case repositories
        case showDrafts
        case notificationsEnabled
        case refreshOnOpen
        case ciStatusExcludeFilter
        case pausePollingInLowPowerMode
        case pausePollingOnExpensiveNetwork
        case showMyReviewStatus
        case automaticallyCheckForUpdates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Configuration.default

        refreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? defaults.refreshInterval
        repositories = try container.decodeIfPresent([String].self, forKey: .repositories) ?? defaults.repositories
        showDrafts = try container.decodeIfPresent(Bool.self, forKey: .showDrafts) ?? defaults.showDrafts
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? defaults.notificationsEnabled
        refreshOnOpen = try container.decodeIfPresent(Bool.self, forKey: .refreshOnOpen) ?? defaults.refreshOnOpen
        ciStatusExcludeFilter = try container.decodeIfPresent(String.self, forKey: .ciStatusExcludeFilter) ?? defaults.ciStatusExcludeFilter
        pausePollingInLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .pausePollingInLowPowerMode) ?? defaults.pausePollingInLowPowerMode
        pausePollingOnExpensiveNetwork = try container.decodeIfPresent(Bool.self, forKey: .pausePollingOnExpensiveNetwork) ?? defaults.pausePollingOnExpensiveNetwork
        showMyReviewStatus = try container.decodeIfPresent(Bool.self, forKey: .showMyReviewStatus) ?? defaults.showMyReviewStatus
        automaticallyCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckForUpdates) ?? defaults.automaticallyCheckForUpdates
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
