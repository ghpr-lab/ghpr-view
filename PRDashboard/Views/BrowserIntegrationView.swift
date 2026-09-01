import AppKit
import SwiftUI

struct BrowserIntegrationView: View {
    @ObservedObject var controller: ExtensionPlatformController
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: browserSummarySymbol)
                    .foregroundColor(browserSummaryColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(browserSummaryTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text(browserSummaryDetail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(activeClientCount) paired")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Browser Integration status")
            .accessibilityValue("\(browserSummaryTitle). Browser Bridge \(bridgeStatusText). \(activeClientCount) paired clients.")
            .accessibilityIdentifier("browser-bridge-status")

            if controller.officialUserscriptClient == nil {
                Label(
                    "Tip: Install the Tampermonkey userscript to add ghpr actions on GitHub.",
                    systemImage: "puzzlepiece.extension"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("userscript-reminder")
            }

            if !controller.unhealthySlots.isEmpty {
                Label(
                    "\(controller.unhealthySlots.count) GitHub placement\(controller.unhealthySlots.count == 1 ? "" : "s") need attention",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
                .accessibilityIdentifier("browser-slot-health-warning")
            }

            if controller.officialUserscriptClient == nil {
                Button {
                    open(controller.installUserscriptURL())
                } label: {
                    Label("Install Userscript in Browser", systemImage: "arrow.up.right.square")
                }
                .disabled(controller.installUserscriptURL() == nil)
                .accessibilityIdentifier("install-userscript")

                Text("Installation opens in your default browser.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button {
                showingDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showingDetails ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("Connection details")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
            .accessibilityIdentifier("browser-integration-details-toggle")
            .accessibilityValue(showingDetails ? "Expanded" : "Collapsed")

            if showingDetails {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow(
                        title: "Browser Bridge",
                        value: bridgeStatusText,
                        symbol: bridgeStatusSymbol,
                        color: bridgeStatusColor
                    )
                    statusRow(
                        title: "Official Userscript",
                        value: officialUserscriptText,
                        symbol: controller.officialUserscriptClient == nil
                            ? "square.and.arrow.down"
                            : "checkmark.circle.fill",
                        color: controller.officialUserscriptClient == nil ? .secondary : .green
                    )
                    statusRow(
                        title: "GitHub Page",
                        value: controller.isGitHubPageConnected ? "Connected" : "Waiting for a GitHub tab",
                        symbol: controller.isGitHubPageConnected ? "link.circle.fill" : "link.circle",
                        color: controller.isGitHubPageConnected ? .green : .secondary
                    )

                    Divider()

                    Text("Paired clients")
                        .font(.caption)
                        .fontWeight(.medium)

                    if controller.pairedClients.isEmpty {
                        Text("No browser clients are paired.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 7) {
                            ForEach(controller.pairedClients) { client in
                                clientRow(client)
                            }
                        }
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Button {
                            open(controller.browserTestURL())
                        } label: {
                            Label("Open Browser Test", systemImage: "arrow.up.right.square")
                        }
                        .disabled(controller.browserTestURL() == nil)
                        .accessibilityIdentifier("open-browser-test")

                        if controller.officialUserscriptClient != nil {
                            Button {
                                open(controller.installUserscriptURL())
                            } label: {
                                Label("Reinstall Userscript", systemImage: "arrow.up.right.square")
                            }
                            .disabled(controller.installUserscriptURL() == nil)
                            .accessibilityIdentifier("install-userscript")
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-integration-settings")
    }

    private func clientRow(_ client: BrowserClient) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: client.isRevoked ? "xmark.shield" : "person.badge.shield.checkmark")
                .foregroundColor(client.isRevoked ? .secondary : .purple)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(client.name)
                        .font(.system(size: 12, weight: .medium))
                    Text("v\(client.version)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(scopeSummary(client.scopes))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if client.isRevoked {
                Text("Revoked")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Button("Revoke") {
                    controller.revoke(client: client)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .accessibilityIdentifier("revoke-\(client.id)")
            }
        }
        .padding(.vertical, 2)
    }

    private func statusRow(
        title: LocalizedStringKey,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .foregroundColor(color)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    private var activeClientCount: Int {
        controller.pairedClients.lazy.filter { !$0.isRevoked }.count
    }

    private var browserSummaryTitle: String {
        switch controller.bridgeStatus.state {
        case .failed:
            return "Needs attention"
        case .starting:
            return "Starting…"
        case .stopped:
            return "Browser integration unavailable"
        case .running:
            if controller.officialUserscriptClient == nil {
                return "Finish browser setup"
            }
            if !controller.unhealthySlots.isEmpty {
                return "Needs attention"
            }
            return "Ready"
        }
    }

    private var browserSummaryDetail: String {
        switch controller.bridgeStatus.state {
        case .failed:
            return "Open connection details to diagnose the Browser Bridge."
        case .starting:
            return "Starting the local Browser Bridge."
        case .stopped:
            return "The local Browser Bridge is not running."
        case .running:
            if controller.officialUserscriptClient == nil {
                return "Install the userscript once to connect ghpr with GitHub."
            }
            if !controller.unhealthySlots.isEmpty {
                return "Some ghpr actions could not attach to GitHub."
            }
            return controller.isGitHubPageConnected
                ? "A GitHub page is connected."
                : "Ready when you open a GitHub pull request."
        }
    }

    private var browserSummarySymbol: String {
        switch controller.bridgeStatus.state {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .starting:
            return "clock.fill"
        case .stopped:
            return "bolt.slash.fill"
        case .running:
            if controller.officialUserscriptClient == nil {
                return "puzzlepiece.extension"
            }
            if !controller.unhealthySlots.isEmpty {
                return "exclamationmark.triangle.fill"
            }
            return "checkmark.circle.fill"
        }
    }

    private var browserSummaryColor: Color {
        switch controller.bridgeStatus.state {
        case .failed:
            return .red
        case .starting:
            return .orange
        case .stopped:
            return .secondary
        case .running:
            return controller.officialUserscriptClient == nil || !controller.unhealthySlots.isEmpty
                ? .orange
                : .green
        }
    }

    private var bridgeStatusText: String {
        switch controller.bridgeStatus.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running(let port): return "Running · \(port)"
        case .failed(let message): return message
        }
    }

    private var bridgeStatusSymbol: String {
        switch controller.bridgeStatus.state {
        case .running: return "bolt.horizontal.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .starting: return "clock"
        case .stopped: return "bolt.slash"
        }
    }

    private var bridgeStatusColor: Color {
        switch controller.bridgeStatus.state {
        case .running: return .green
        case .failed: return .red
        case .starting: return .orange
        case .stopped: return .secondary
        }
    }

    private var officialUserscriptText: String {
        guard let client = controller.officialUserscriptClient else {
            return "Not paired"
        }
        return "Installed · v\(client.version)"
    }

    private func scopeSummary(_ scopes: Set<BrowserScope>) -> String {
        scopes
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

struct SkillBuilderSettingsView: View {
    @ObservedObject var controller: ExtensionPlatformController
    @State private var statuses = SkillBuilderInstaller.statuses()
    @State private var errorMessage: String?
    @State private var showingDetails = false


    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: skillBuilderSummarySymbol)
                    .foregroundColor(skillBuilderSummaryColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(skillBuilderSummaryTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text("Create and extend ghpr Skills with Claude Code, Codex, or OMP.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("skill-builder-status")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityIdentifier("skill-builder-install-error")
            }

            HStack(spacing: 8) {
                Button {
                    if let url = controller.workbenchURL() {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Workbench in Browser", systemImage: "arrow.up.right.square")
                }
                .disabled(controller.workbenchURL() == nil)
                .accessibilityIdentifier("open-skill-workbench")

                if !allAgentsInstalled {
                    Button("Install for All Agents") {
                        install()
                    }
                    .accessibilityIdentifier("install-skill-builder")
                }
            }

            Text("Skill Workbench opens in your default browser.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Button {
                showingDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showingDetails ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("Installation details")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
            .accessibilityIdentifier("skill-builder-details-toggle")
            .accessibilityValue(showingDetails ? "Expanded" : "Collapsed")

            if showingDetails {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(statuses) { status in
                        HStack {
                            Text(status.agent.displayName)
                            Spacer()
                            Label(
                                status.installed ? "Installed" : "Not installed",
                                systemImage: status.installed ? "checkmark.circle.fill" : "circle"
                            )
                            .font(.caption)
                            .foregroundColor(status.installed ? .green : .secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        if allAgentsInstalled {
                            Button("Reinstall for All Agents") {
                                install()
                            }
                            .accessibilityIdentifier("install-skill-builder")
                        }

                        Button {
                            if let url = controller.workbenchURL() {
                                NSWorkspace.shared.open(url.appending(fragment: "contract"))
                            }
                        } label: {
                            Label("View Contract in Browser", systemImage: "arrow.up.right.square")
                        }
                        .disabled(controller.workbenchURL() == nil)
                    }
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-builder-settings")
    }

    private var installedAgentCount: Int {
        statuses.lazy.filter(\.installed).count
    }

    private var allAgentsInstalled: Bool {
        !statuses.isEmpty && installedAgentCount == statuses.count
    }

    private var skillBuilderSummaryTitle: String {
        if allAgentsInstalled {
            return "Ready for all coding agents"
        }
        if installedAgentCount == 0 {
            return "Skill Builder is not installed"
        }
        return "Installed for \(installedAgentCount) of \(statuses.count) agents"
    }

    private var skillBuilderSummarySymbol: String {
        allAgentsInstalled ? "checkmark.circle.fill" : "hammer.circle"
    }

    private var skillBuilderSummaryColor: Color {
        allAgentsInstalled ? .green : .secondary
    }

    private func install() {
        guard let source = Bundle.main.resourceURL?
            .appendingPathComponent("ghpr-skill-builder/SKILL.md"),
              FileManager.default.fileExists(atPath: source.path) else {
            errorMessage = "The bundled Skill Builder is missing."
            return
        }
        do {
            statuses = try SkillBuilderInstaller.install(
                sourceSkillURL: source,
                agents: [.claudeCode, .codex, .omp]
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

struct AgentRuntimeSettingsView: View {
    @ObservedObject var controller: ExtensionPlatformController

    @State private var expanded = false
    @State private var selectedAgent: SkillAgent = .claudeCode
    @State private var loadingAgents: Set<SkillAgent> = []
    @State private var errors: [SkillAgent: String] = [:]
    @State private var freeformModel: String?

    private let agents: [SkillAgent] = [.claudeCode, .codex, .omp]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "cpu")
                    .foregroundColor(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryTitle)
                        .font(.system(size: 13, weight: .medium))
                    Text("Pick a coding agent, then choose the model and reasoning effort ghpr passes to it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agent-runtime-status")

            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("Model and reasoning effort")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
            .accessibilityIdentifier("agent-runtime-toggle")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Coding agent", selection: $selectedAgent) {
                        ForEach(agents, id: \.self) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("agent-runtime-agent-picker")
                    .accessibilityValue(selectedAgent.displayName)

                    agentConfiguration(selectedAgent)
                }
                .padding(.top, 2)
            }
        }
        .task(id: TaskKey(expanded: expanded, agent: selectedAgent)) {
            guard expanded else { return }
            freeformModel = nil
            guard AgentCapabilityProbe.probeArguments(for: selectedAgent) != nil,
                  controller.cachedAgentCapabilityCatalog(for: selectedAgent) == nil else {
                return
            }
            await load(selectedAgent, forceRefresh: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-runtime-settings")
    }

    private struct TaskKey: Equatable {
        let expanded: Bool
        let agent: SkillAgent
    }

    @ViewBuilder
    private func agentConfiguration(_ agent: SkillAgent) -> some View {
        let catalog = controller.cachedAgentCapabilityCatalog(for: agent)
        VStack(alignment: .leading, spacing: 6) {
            if let catalog, catalog.listsModels {
                Picker("Model", selection: modelBinding(for: agent)) {
                    Text("Agent default").tag("")
                    ForEach(catalog.models) { model in
                        Text(model.displayName).tag(model.slug)
                    }
                }
                .accessibilityIdentifier("agent-model-picker")

                let efforts = catalog.reasoningEfforts(
                    forModel: controller.agentRuntimePreference(for: agent).model
                )
                if efforts.isEmpty {
                    Text("\(agent.displayName) exposes no reasoning effort levels.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Reasoning effort", selection: effortBinding(for: agent)) {
                        Text("Agent default").tag("")
                        ForEach(efforts) { effort in
                            Text(effort.effort).tag(effort.effort)
                        }
                    }
                    .accessibilityIdentifier("agent-effort-picker")
                }
            } else {
                TextField(
                    "Model name",
                    text: Binding(
                        get: {
                            freeformModel
                                ?? controller.agentRuntimePreference(for: agent).model
                                ?? ""
                        },
                        set: { freeformModel = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitFreeformModel(agent) }
                .accessibilityIdentifier("agent-model-field")

                Button("Apply Model") { commitFreeformModel(agent) }
                    .font(.caption)
                    .accessibilityIdentifier("agent-model-apply")
            }

            HStack(spacing: 8) {
                if loadingAgents.contains(agent) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading the \(agent.displayName) CLI…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if AgentCapabilityProbe.probeArguments(for: agent) != nil {
                    Button(catalog == nil ? "Load Models" : "Refresh Models") {
                        Task { await load(agent, forceRefresh: true) }
                    }
                    .font(.caption)
                    .accessibilityIdentifier("agent-runtime-refresh")
                }

                Text(sourceCaption(agent, catalog: catalog))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if agent == .codex {
                Text("Codex runs read-only inside the private Skill run directory, with tools, shell, checkout, and network denied by the strict contract.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let message = errors[agent] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityIdentifier("agent-runtime-error")
            }
        }
    }

    private var summaryTitle: String {
        let preference = controller.agentRuntimePreference(for: selectedAgent)
        guard let model = preference.model else {
            return "\(selectedAgent.displayName) uses its own default model"
        }
        guard let effort = preference.reasoningEffort else {
            return "\(selectedAgent.displayName) · \(model)"
        }
        return "\(selectedAgent.displayName) · \(model) · \(effort)"
    }

    private func sourceCaption(
        _ agent: SkillAgent,
        catalog: AgentCapabilityCatalog?
    ) -> String {
        if agent == .omp {
            return "OMP resolves fuzzy names such as opus or openai/gpt-5.2."
        }
        guard let catalog else {
            return "Model and effort lists come from the \(agent.displayName) CLI."
        }
        let updated = catalog.refreshedAt.formatted(date: .abbreviated, time: .shortened)
        return "From `\(catalog.source)` · updated \(updated)"
    }

    private func modelBinding(for agent: SkillAgent) -> Binding<String> {
        Binding(
            get: { controller.agentRuntimePreference(for: agent).model ?? "" },
            set: { value in
                var preference = controller.agentRuntimePreference(for: agent)
                preference.model = value.isEmpty ? nil : value
                if let effort = preference.reasoningEffort,
                   let catalog = controller.cachedAgentCapabilityCatalog(for: agent),
                   !catalog.reasoningEfforts(forModel: preference.model)
                       .contains(where: { $0.effort == effort }) {
                    preference.reasoningEffort = nil
                }
                controller.setAgentRuntimePreference(preference, for: agent)
            }
        )
    }

    private func effortBinding(for agent: SkillAgent) -> Binding<String> {
        Binding(
            get: { controller.agentRuntimePreference(for: agent).reasoningEffort ?? "" },
            set: { value in
                var preference = controller.agentRuntimePreference(for: agent)
                preference.reasoningEffort = value.isEmpty ? nil : value
                controller.setAgentRuntimePreference(preference, for: agent)
            }
        )
    }

    private func commitFreeformModel(_ agent: SkillAgent) {
        guard let entered = freeformModel?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }
        var preference = controller.agentRuntimePreference(for: agent)
        preference.model = entered.isEmpty ? nil : entered
        controller.setAgentRuntimePreference(preference, for: agent)
        freeformModel = nil
    }

    private func load(_ agent: SkillAgent, forceRefresh: Bool) async {
        guard !loadingAgents.contains(agent) else { return }
        loadingAgents.insert(agent)
        errors[agent] = nil
        do {
            _ = try await controller.loadAgentCapabilityCatalog(
                for: agent,
                forceRefresh: forceRefresh
            )
        } catch {
            errors[agent] = error.localizedDescription
        }
        loadingAgents.remove(agent)
    }
}

struct BrowserPairingApprovalView: View {
    @ObservedObject var controller: ExtensionPlatformController
    let approval: PendingPairingApproval
    let dismiss: () -> Void

    @State private var selectedScopes: Set<BrowserScope>
    @State private var errorMessage: String?

    init(
        controller: ExtensionPlatformController,
        approval: PendingPairingApproval,
        dismiss: @escaping () -> Void
    ) {
        self.controller = controller
        self.approval = approval
        self.dismiss = dismiss
        let requested = approval.descriptor.requestedScopes
        let existing = controller.pairedClients.first { $0.id == approval.descriptor.id }?.scopes ?? []
        _selectedScopes = State(
            initialValue: requested.filter { $0.risk == .standard || existing.contains($0) }
        )
    }

    private var missingRequiredScopes: Set<BrowserScope> {
        approval.descriptor.requiredScopes.subtracting(selectedScopes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.shield.checkmark")
                    .font(.system(size: 28))
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect “\(approval.descriptor.name)” to ghpr?")
                        .font(.headline)
                        .accessibilityIdentifier("pairing-client-name")
                    Text("Version \(approval.descriptor.version) · \(approval.descriptor.id)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text("Requested permissions")
                .font(.subheadline.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(
                        approval.descriptor.requestedScopes.sorted { $0.rawValue < $1.rawValue }
                    ) { scope in
                        Toggle(isOn: binding(for: scope)) {
                            HStack(spacing: 7) {
                                Image(
                                    systemName: scope.risk == .elevated
                                        ? "exclamationmark.triangle.fill"
                                        : "checkmark.shield.fill"
                                )
                                .foregroundColor(scope.risk == .elevated ? .orange : .green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(scope.displayName)
                                        .accessibilityIdentifier("pairing-scope-name-\(scope.rawValue)")
                                    if approval.descriptor.requiredScopes.contains(scope) {
                                        Text("Required for this action")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(.orange)
                                    }
                                    Text(scope.rawValue)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("pairing-scope-\(scope.rawValue)")
                    }
                }
            }

            if !missingRequiredScopes.isEmpty {
                Text("Select \(missingRequiredScopes.map(\.displayName).joined(separator: ", ")) to continue.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Deny", role: .cancel) {
                    do {
                        try controller.denyPairing(approval)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Allow") {
                    do {
                        try controller.approvePairing(approval, scopes: selectedScopes)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!missingRequiredScopes.isEmpty)
                .keyboardShortcut(.return)
                .accessibilityIdentifier("allow-pairing")
            }
        }
        .padding(22)
        .frame(width: 460, height: 430)
    }

    private func binding(for scope: BrowserScope) -> Binding<Bool> {
        Binding(
            get: { selectedScopes.contains(scope) },
            set: { selected in
                if selected {
                    selectedScopes.insert(scope)
                } else {
                    selectedScopes.remove(scope)
                }
            }
        )
    }
}

private extension URL {
    func appending(fragment: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = fragment
        return components?.url ?? self
    }
}
