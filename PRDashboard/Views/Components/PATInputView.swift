import SwiftUI

struct PATInputView: View {
    @Binding var token: String
    let isValidating: Bool
    let error: Error?
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onClearError: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Instructions
            VStack(spacing: 8) {
                Text("Enter Personal Access Token")
                    .font(.system(size: 13, weight: .medium))

                Text("Create a classic Personal Access Token at GitHub Settings > Developer settings > Personal access tokens (classic)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("If your organization enforces SAML SSO, authorize this token for it after creation.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Required scopes info
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                Text("Required scopes: repo, read:user, workflow")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)

            // Secure text field
            SecureField("ghp_xxxxxxxxxxxx", text: $token)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)
                .onChange(of: token) { _ in
                    onClearError()
                }

            // Error display
            if let error = error {
                Text(error.localizedDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button(action: onSubmit) {
                    if isValidating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Text("Sign In")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(token.isEmpty || isValidating)
            }
        }
    }
}
