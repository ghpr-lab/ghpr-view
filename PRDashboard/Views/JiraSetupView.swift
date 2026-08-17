import SwiftUI

struct JiraSetupView: View {
    @ObservedObject var coordinator: JiraSetupCoordinator

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 360)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect Jira").font(.headline)
                Text(stepTitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: stepIcon).imageScale(.large).foregroundStyle(.tint)
        }
        .padding(20)
    }

    @ViewBuilder private var content: some View {
        switch coordinator.step {
        case .server: serverStep
        case .tokenInstructions: tokenStep
        case .credentials: credentialsStep
        case .testing: testingStep
        case .completed: completedStep
        }
    }

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect your Jira Cloud site")
                .font(.title3.weight(.semibold))
            Text("Use the site address your team visits in a browser. We’ll use it to connect your account.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Jira site URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://example.atlassian.net", text: $coordinator.serverURL)
                    .textFieldStyle(.roundedBorder)
            }
            if let message = coordinator.serverValidationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create an Atlassian API token")
                .font(.title3.weight(.semibold))
            Text("Jira uses an API token instead of your password. Create one in Atlassian, then come back here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                instruction("1", "Open the Atlassian API token page.")
                instruction("2", "Choose Create API token and copy the token.")
                instruction("3", "Return here and select Continue.")
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                Button("Open API Token Page") { coordinator.openTokenPage() }
                    .buttonStyle(.borderedProminent)
                Button("Open Jira Site") { coordinator.openJiraSite() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            Text(text)
                .font(.callout)
        }
    }

    private var credentialsStep: some View {
        JiraSetupForm(
            serverURL: $coordinator.serverURL,
            email: $coordinator.email,
            apiToken: $coordinator.apiToken,
            savedTokenAvailable: coordinator.savedTokenAvailable,
            testState: coordinator.testState,
            canTest: coordinator.canTest,
            onTest: { coordinator.test() },
            onFieldChange: { coordinator.fieldDidChange() }
        )
    }

    private var testingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if coordinator.isTesting {
                ProgressView("Testing Jira connection…")
            } else if let identity = coordinator.identityText {
                Label("Connected as \(identity)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Review the connection, then choose Finish.")
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = coordinator.testState {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    private var completedStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Jira connected!", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
            if let identity = coordinator.identityText {
                Text("Connected as \(identity)").foregroundStyle(.secondary)
            }
            if let issueKey = coordinator.pendingIssueKey {
                Button("Open \(issueKey)") { coordinator.openPendingIssue() }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { coordinator.cancel() }
            if coordinator.step == .tokenInstructions || coordinator.step == .credentials {
                Button("Back") { coordinator.goBack() }
                    .disabled(coordinator.isTesting)
            }
            Spacer()
            switch coordinator.step {
            case .server:
                Button("Continue") { coordinator.continueFromServer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canContinueServer)
            case .tokenInstructions:
                Button("Continue") { coordinator.continueFromTokenInstructions() }
                    .keyboardShortcut(.defaultAction)
            case .testing:
                Button("Finish") { coordinator.finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canFinish)
            case .completed:
                Button("Done") { coordinator.done() }
                    .keyboardShortcut(.defaultAction)
            case .credentials:
                EmptyView()
            }
        }
        .padding(16)
    }

    private var stepTitle: String {
        switch coordinator.step {
        case .server: return "Jira site"
        case .tokenInstructions: return "API token instructions"
        case .credentials: return "Credentials"
        case .testing: return "Testing connection"
        case .completed: return "Connected"
        }
    }

    private var stepIcon: String {
        switch coordinator.step {
        case .server: return "globe"
        case .tokenInstructions: return "key"
        case .credentials: return "person.crop.circle"
        case .testing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        }
    }
}
