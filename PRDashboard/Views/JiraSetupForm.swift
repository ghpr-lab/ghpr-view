import SwiftUI

struct JiraSetupForm: View {
    @Binding var serverURL: String
    @Binding var email: String
    @Binding var apiToken: String
    let savedTokenAvailable: Bool
    let testState: JiraSetupTestState
    let canTest: Bool
    let onTest: () -> Void
    let onFieldChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Jira site URL", text: $serverURL, prompt: "https://example.atlassian.net")
            field("Atlassian email", text: $email, prompt: "name@example.com")
            VStack(alignment: .leading, spacing: 5) {
                Text("API token").font(.caption).foregroundStyle(.secondary)
                SecureField("Saved in Keychain — leave blank to keep it", text: $apiToken)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiToken) { _ in onFieldChange() }
            }
            if savedTokenAvailable && apiToken.isEmpty {
                Label("Saved in Keychain — leave blank to keep it", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = testState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Test Connection", action: onTest)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canTest)
            }
        }
        .onChange(of: serverURL) { _ in onFieldChange() }
        .onChange(of: email) { _ in onFieldChange() }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
