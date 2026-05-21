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
    var openAtCmuxFirst: Bool  // switch to an existing cmux PR browser tab before falling back to the default browser
    var graphQLEndpoint: String  // developer override for GitHub GraphQL URL; empty = default
    var httpProxyURL: String     // e.g. "http://host:port"; empty = no proxy
    var httpProxyUsername: String  // empty = no auth; password stored in Keychain
    var jiraServerURL: String    // e.g. "https://company.atlassian.net"; empty = disabled
    var jiraEmail: String        // Atlassian account email; token stored in Keychain
    var jiraRefreshInterval: TimeInterval  // seconds

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
            automaticallyCheckForUpdates: true,
            openAtCmuxFirst: false,
            graphQLEndpoint: "",
            httpProxyURL: "",
            httpProxyUsername: "",
            jiraServerURL: "",
            jiraEmail: "",
            jiraRefreshInterval: 1800
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
        automaticallyCheckForUpdates: Bool,
        openAtCmuxFirst: Bool,
        graphQLEndpoint: String,
        httpProxyURL: String,
        httpProxyUsername: String,
        jiraServerURL: String,
        jiraEmail: String,
        jiraRefreshInterval: TimeInterval
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
        self.openAtCmuxFirst = openAtCmuxFirst
        self.graphQLEndpoint = graphQLEndpoint
        self.httpProxyURL = httpProxyURL
        self.httpProxyUsername = httpProxyUsername
        self.jiraServerURL = jiraServerURL
        self.jiraEmail = jiraEmail
        self.jiraRefreshInterval = jiraRefreshInterval
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
        case openAtCmuxFirst
        case graphQLEndpoint
        case httpProxyURL
        case httpProxyUsername
        case jiraServerURL
        case jiraEmail
        case jiraRefreshInterval
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
        openAtCmuxFirst = try container.decodeIfPresent(Bool.self, forKey: .openAtCmuxFirst) ?? defaults.openAtCmuxFirst
        graphQLEndpoint = try container.decodeIfPresent(String.self, forKey: .graphQLEndpoint) ?? defaults.graphQLEndpoint
        httpProxyURL = try container.decodeIfPresent(String.self, forKey: .httpProxyURL) ?? defaults.httpProxyURL
        httpProxyUsername = try container.decodeIfPresent(String.self, forKey: .httpProxyUsername) ?? defaults.httpProxyUsername
        jiraServerURL = try container.decodeIfPresent(String.self, forKey: .jiraServerURL) ?? defaults.jiraServerURL
        jiraEmail = try container.decodeIfPresent(String.self, forKey: .jiraEmail) ?? defaults.jiraEmail
        jiraRefreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .jiraRefreshInterval) ?? defaults.jiraRefreshInterval
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
