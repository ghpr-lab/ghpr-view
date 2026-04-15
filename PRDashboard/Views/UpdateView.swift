import SwiftUI

struct UpdateView: View {
    @ObservedObject var updateManager: UpdateManager
    @Environment(\.dismiss) private var dismiss

    private static let publishedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    versionSection
                    statusSection

                    if let release = updateManager.displayedRelease {
                        releaseSection(release)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footer
        }
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Software Update")
                    .font(.headline)
                Text("Checks the latest GitHub release for PR Dashboard.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Version")
                .font(.caption)
                .foregroundColor(.secondary)

            let buildSuffix = updateManager.currentBuildString.isEmpty ? "" : " (\(updateManager.currentBuildString))"
            Text("\(updateManager.currentVersionString)\(buildSuffix)")
                .font(.title3.weight(.semibold))
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch updateManager.state {
        case .idle:
            statusCard(
                title: "Ready to Check",
                message: "Use the button below to fetch the latest GitHub release."
            )
        case .checking:
            VStack(alignment: .leading, spacing: 12) {
                statusCard(
                    title: "Checking for Updates",
                    message: "Fetching the latest release metadata from GitHub."
                )
                ProgressView()
                    .controlSize(.small)
            }
        case let .upToDate(release):
            statusCard(
                title: "You’re Up to Date",
                message: "PR Dashboard \(updateManager.currentVersionString) already matches the latest release (\(release.displayVersion))."
            )
        case let .available(release):
            statusCard(
                title: "Update Available",
                message: "Version \(release.displayVersion) is available to download."
            )
        case let .downloading(_, bytesReceived, totalBytes):
            VStack(alignment: .leading, spacing: 12) {
                statusCard(
                    title: "Downloading Update",
                    message: downloadSummary(bytesReceived: bytesReceived, totalBytes: totalBytes)
                )

                ProgressView(
                    value: totalBytes > 0 ? Double(bytesReceived) : 0,
                    total: totalBytes > 0 ? Double(totalBytes) : 1
                )
            }
        case let .readyToInstall(release, targetURL):
            statusCard(
                title: "Ready to Install",
                message: "Version \(release.displayVersion) is staged and ready to replace \(targetURL.path)."
            )
        case let .installing(release, targetURL):
            VStack(alignment: .leading, spacing: 12) {
                statusCard(
                    title: "Installing and Restarting",
                    message: "PR Dashboard \(release.displayVersion) is being installed to \(targetURL.path). The app will relaunch automatically."
                )
                ProgressView()
                    .controlSize(.small)
            }
        case let .unsupportedInstallLocation(_, reason):
            statusCard(
                title: "Automatic Install Unavailable",
                message: reason
            )
        case let .error(displayError):
            statusCard(
                title: displayError.title,
                message: displayError.message
            )
        }
    }

    private func releaseSection(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest Release")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(release.displayName)
                    .font(.title3.weight(.semibold))

                Text("Version \(release.displayVersion) • Published \(Self.publishedAtFormatter.string(from: release.publishedAt))")
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Release Notes")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScrollView {
                    Text(release.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No release notes were provided for this release." : release.body)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 180, maxHeight: 220)
                .padding(10)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.escape)
            .disabled(isInstalling)

            Spacer()

            footerButtons
        }
        .padding(20)
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch updateManager.state {
        case .idle:
            Button("Check for Updates") {
                updateManager.checkForUpdates(userInitiated: true)
            }
            .buttonStyle(.borderedProminent)
        case .checking:
            EmptyView()
        case .upToDate:
            Button("Check Again") {
                updateManager.checkForUpdates(userInitiated: true)
            }
            .buttonStyle(.borderedProminent)
        case .available:
            secondaryReleaseButton
            Button("Download Update") {
                updateManager.downloadAvailableUpdate()
            }
            .buttonStyle(.borderedProminent)
        case .downloading:
            Button("Cancel") {
                updateManager.cancelDownload()
            }
        case .readyToInstall:
            secondaryReleaseButton
            Button("Install and Restart") {
                updateManager.installAndRestart()
            }
            .buttonStyle(.borderedProminent)
        case .installing:
            EmptyView()
        case .unsupportedInstallLocation:
            secondaryReleaseButton
        case .error:
            if updateManager.canOpenLatestReleasePage {
                secondaryReleaseButton
            }
            Button("Check Again") {
                updateManager.checkForUpdates(userInitiated: true)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var secondaryReleaseButton: some View {
        Button("Open Latest Release") {
            updateManager.openLatestReleasePage()
        }
    }

    private var isInstalling: Bool {
        if case .installing = updateManager.state {
            return true
        }
        return false
    }

    private func downloadSummary(bytesReceived: Int64, totalBytes: Int64) -> String {
        if totalBytes > 0 {
            return "\(Self.byteFormatter.string(fromByteCount: bytesReceived)) of \(Self.byteFormatter.string(fromByteCount: totalBytes))"
        }

        return Self.byteFormatter.string(fromByteCount: bytesReceived)
    }

    private func statusCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(10)
    }
}
