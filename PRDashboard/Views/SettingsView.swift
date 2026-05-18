import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var viewModel: PRListViewModel
    @ObservedObject var onboardingManager: OnboardingManager
    @ObservedObject var updateManager: UpdateManager
    @Environment(\.dismiss) private var dismiss

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var refreshInterval: Double = 60
    @State private var refreshOnOpen: Bool = true
    @State private var repositories: String = ""
    @State private var showDrafts: Bool = true
    @State private var notificationsEnabled: Bool = true
    @State private var ciStatusExcludeFilter: String = "review"
    @State private var pausePollingInLowPowerMode: Bool = true
    @State private var pausePollingOnExpensiveNetwork: Bool = true
    @State private var showMyReviewStatus: Bool = false
    @State private var automaticallyCheckForUpdates: Bool = true
    @State private var openAtCmuxFirst: Bool = false
    @State private var graphQLEndpoint: String = ""
    @State private var httpProxyURL: String = ""
    @State private var httpProxyUsername: String = ""
    @State private var httpProxyPassword: String = ""
    @State private var showPATSwitchSheet = false
    @State private var newPATToken = ""
    @State private var showClearCacheConfirmation = false

    private let refreshIntervalOptions: [(LocalizedStringKey, Double)] = [
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("15 minutes", 900),
        ("30 minutes", 1800)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    save()
                }
                .keyboardShortcut(.return)
            }
            .padding()

            Divider()

            // Settings form
            Form {
                Section("Account") {
                    if viewModel.authState.isAuthenticated {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.accentColor)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.authState.username ?? "Signed in")
                                    .font(.headline)

                                // Show auth method
                                HStack(spacing: 4) {
                                    Image(systemName: viewModel.authState.authMethod == .pat ? "key" : "person.badge.shield.checkmark")
                                        .font(.system(size: 10))
                                    Text(viewModel.authState.authMethod == .pat ? "Personal Access Token" : "GitHub OAuth")
                                        .font(.caption)
                                }
                                .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button("Sign Out") {
                                viewModel.signOut()
                                dismiss()
                            }
                            .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)

                        // Option to switch auth method
                        Divider()

                        if viewModel.authState.authMethod == .pat {
                            Button("Switch to GitHub OAuth") {
                                viewModel.signOut()
                                viewModel.signIn()
                                dismiss()
                            }
                            .font(.system(size: 12))
                        } else {
                            Button("Switch to Personal Access Token") {
                                showPATSwitchSheet = true
                            }
                            .font(.system(size: 12))
                        }
                    } else {
                        Button("Sign in with GitHub") {
                            viewModel.signIn()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Section("General") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                // Revert toggle on failure
                                launchAtLogin = !newValue
                            }
                        }

                    HStack {
                        Toggle("Open PRs in cmux first", isOn: $openAtCmuxFirst)
                        HelpHint("If the same PR is already open in cmux, switch to it and reload it. Otherwise, open the PR in your default browser.\n\nRequires cmux → Settings → Socket Control set to “Automation” (the default “cmux only” rejects connections from other apps).")
                    }
                }

                Section("Refresh") {
                    Picker("Refresh Interval", selection: $refreshInterval) {
                        ForEach(refreshIntervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }

                    Toggle("Refresh when opened", isOn: $refreshOnOpen)
                }

                Section("Filters") {
                    HStack {
                        TextField("Repositories (comma-separated, leave empty for all)", text: $repositories)
                            .textFieldStyle(.roundedBorder)
                        HelpHint("Filter PRs to specific repos. Format: owner/repo, comma-separated (e.g., owner/repo1, owner/repo2). Leave empty to show PRs from all repos.")
                    }

                    Toggle("Show draft PRs", isOn: $showDrafts)

                    Toggle("Show my review status badges", isOn: $showMyReviewStatus)

                    HStack {
                        TextField("CI status exclude filter", text: $ciStatusExcludeFilter)
                            .textFieldStyle(.roundedBorder)
                        HelpHint("Exclude CI status checks whose name contains this keyword (e.g., \"review\" hides checks like \"code-review\"). Leave empty to include all checks.")
                    }
                }

                Section("Notifications") {
                    Toggle("Enable notifications for new unresolved comments", isOn: $notificationsEnabled)
                }

                Section("Power & Network") {
                    Toggle("Pause background refresh in Low Power Mode", isOn: $pausePollingInLowPowerMode)
                    Toggle("Pause background refresh on cellular/hotspot", isOn: $pausePollingOnExpensiveNetwork)
                }

                Section("Updates") {
                    HStack {
                        Text("Current version")
                        Spacer()
                        Text(currentVersionDescription)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    Toggle("Automatically check for updates", isOn: $automaticallyCheckForUpdates)

                    HStack {
                        Button {
                            updateManager.checkForUpdates(userInitiated: true)
                        } label: {
                            Label(updateCheckButtonTitle, systemImage: "arrow.clockwise")
                        }
                        .disabled(isUpdateBusy)

                        if isUpdateCheckInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer()
                    }
                }

                Section("Developer Options") {
                    Button("Show onboarding again") {
                        onboardingManager.reset()
                        dismiss()
                    }

                    Button("Clear cached PR data") {
                        showClearCacheConfirmation = true
                    }
                    .foregroundColor(.red)
                    .confirmationDialog(
                        "Clear cached PR data?",
                        isPresented: $showClearCacheConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clear", role: .destructive) {
                            viewModel.clearCaches()
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes all cached PRs, details, mentions, and avatars. The next refresh will refetch everything from GitHub.")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("GraphQL endpoint override")
                            HelpHint("Route GitHub GraphQL requests through a proxy URL. Leave empty to use https://api.github.com/graphql. OAuth endpoints are not affected.")
                            Spacer()
                        }
                        TextField(
                            "",
                            text: $graphQLEndpoint,
                            prompt: Text("https://example.com/graphql")
                        )
                        .labelsHidden()
                        .accessibilityLabel("GraphQL endpoint override")
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: graphQLEndpoint) { newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed != newValue {
                                graphQLEndpoint = trimmed
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("HTTP proxy")
                            HelpHint("Route GitHub API requests through an HTTP proxy. Format: http://host:port. Leave empty to connect directly. Username and password are optional.")
                            Spacer()
                        }
                        TextField(
                            "",
                            text: $httpProxyURL,
                            prompt: Text("http://proxy.example.com:8080")
                        )
                        .labelsHidden()
                        .accessibilityLabel("HTTP proxy URL")
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                        .onChange(of: httpProxyURL) { newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed != newValue {
                                httpProxyURL = trimmed
                            }
                        }

                        TextField(
                            "",
                            text: $httpProxyUsername,
                            prompt: Text("Proxy username (optional)")
                        )
                        .labelsHidden()
                        .accessibilityLabel("HTTP proxy username")
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)

                        SecureField(
                            "",
                            text: $httpProxyPassword,
                            prompt: Text("Proxy password (optional)")
                        )
                        .labelsHidden()
                        .accessibilityLabel("HTTP proxy password")
                        .textFieldStyle(.roundedBorder)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 450, height: 520)
        .onAppear {
            loadCurrentSettings()
        }
        .sheet(isPresented: $showPATSwitchSheet) {
            patSwitchSheet
        }
    }

    private var patSwitchSheet: some View {
        VStack(spacing: 20) {
            Text("Switch to Personal Access Token")
                .font(.headline)

            Text("This will sign you out and use a new token for authentication.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Enter Personal Access Token", text: $newPATToken)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if let error = viewModel.patError {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showPATSwitchSheet = false
                    newPATToken = ""
                    viewModel.clearPATError()
                }
                .buttonStyle(.bordered)

                Button("Switch") {
                    viewModel.signOut()
                    viewModel.signInWithPAT(newPATToken)
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPATToken.isEmpty || viewModel.isValidatingPAT)
            }

            if viewModel.isValidatingPAT {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .frame(width: 350, height: 250)
        .padding()
        .onChange(of: viewModel.authState.isAuthenticated) { isAuthenticated in
            if isAuthenticated {
                showPATSwitchSheet = false
                newPATToken = ""
                dismiss()
            }
        }
    }

    private var currentVersionDescription: String {
        let version = updateManager.currentVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = updateManager.currentBuildString.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionPrefix = version.hasPrefix("v") ? version : "v\(version)"

        if build.isEmpty {
            return "\(versionPrefix) [\(GitVersion.displayString)]"
        }

        return "\(versionPrefix) (\(build)) [\(GitVersion.displayString)]"
    }

    private var updateCheckButtonTitle: LocalizedStringKey {
        switch updateManager.state {
        case .checking:
            return "Checking…"
        case .downloading:
            return "Downloading…"
        case .readyToInstall:
            return "Ready to Install"
        case .installing:
            return "Installing…"
        case .idle, .upToDate, .available, .unsupportedInstallLocation, .error:
            return "Check for Updates…"
        }
    }

    private var isUpdateCheckInProgress: Bool {
        if case .checking = updateManager.state {
            return true
        }

        return false
    }

    private var isUpdateBusy: Bool {
        switch updateManager.state {
        case .checking, .downloading, .readyToInstall, .installing:
            return true
        case .idle, .upToDate, .available, .unsupportedInstallLocation, .error:
            return false
        }
    }

    private func loadCurrentSettings() {
        let config = viewModel.configuration
        refreshInterval = config.refreshInterval
        refreshOnOpen = config.refreshOnOpen
        repositories = config.repositories.joined(separator: ", ")
        showDrafts = config.showDrafts
        notificationsEnabled = config.notificationsEnabled
        ciStatusExcludeFilter = config.ciStatusExcludeFilter
        pausePollingInLowPowerMode = config.pausePollingInLowPowerMode
        pausePollingOnExpensiveNetwork = config.pausePollingOnExpensiveNetwork
        showMyReviewStatus = config.showMyReviewStatus
        automaticallyCheckForUpdates = config.automaticallyCheckForUpdates
        openAtCmuxFirst = config.openAtCmuxFirst
        graphQLEndpoint = config.graphQLEndpoint
        httpProxyURL = config.httpProxyURL
        httpProxyUsername = config.httpProxyUsername
        httpProxyPassword = Keychain.loadProxyPassword()
    }

    private struct HelpHint: View {
        let text: String
        @State private var isShown = false
        @State private var hoverTask: Task<Void, Never>?

        init(_ text: String) {
            self.text = text
        }

        var body: some View {
            Image(systemName: "questionmark.circle")
                .foregroundColor(.secondary)
                .accessibilityLabel(Text("Help"))
                .accessibilityHint(Text(text))
                .onHover { hovering in
                    hoverTask?.cancel()
                    if hovering {
                        hoverTask = Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if !Task.isCancelled {
                                await MainActor.run { isShown = true }
                            }
                        }
                    } else {
                        isShown = false
                    }
                }
                .popover(isPresented: $isShown, arrowEdge: .top) {
                    Text(text)
                        .font(.system(size: 12))
                        .padding(10)
                        .frame(width: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onDisappear {
                    hoverTask?.cancel()
                    hoverTask = nil
                }
        }
    }

    private func save() {
        let repos = repositories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let trimmedProxyURL = httpProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProxyUsername = httpProxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)

        let config = Configuration(
            refreshInterval: refreshInterval,
            repositories: repos,
            showDrafts: showDrafts,
            notificationsEnabled: notificationsEnabled,
            refreshOnOpen: refreshOnOpen,
            ciStatusExcludeFilter: ciStatusExcludeFilter,
            pausePollingInLowPowerMode: pausePollingInLowPowerMode,
            pausePollingOnExpensiveNetwork: pausePollingOnExpensiveNetwork,
            showMyReviewStatus: showMyReviewStatus,
            automaticallyCheckForUpdates: automaticallyCheckForUpdates,
            openAtCmuxFirst: openAtCmuxFirst,
            graphQLEndpoint: graphQLEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            httpProxyURL: trimmedProxyURL,
            httpProxyUsername: trimmedProxyUsername
        )

        if trimmedProxyURL.isEmpty {
            Keychain.deleteProxyPassword()
        } else {
            Keychain.saveProxyPassword(httpProxyPassword)
        }

        viewModel.configuration = config
        dismiss()
    }
}
