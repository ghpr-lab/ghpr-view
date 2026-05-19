import AppKit
import Foundation
import Security
import os

private let updateLogger = Logger(subsystem: "com.prdashboard", category: "UpdateManager")

@MainActor
final class UpdateManager: ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    private var lastAutoCheckAt: Date?

    var onRequestPresentation: (() -> Void)?

    private struct StagedUpdate {
        let release: ReleaseInfo
        let releaseDirectoryURL: URL
        let archiveURL: URL
        let appURL: URL

        func matches(_ release: ReleaseInfo) -> Bool {
            self.release.version == release.version
        }
    }

    private struct GitHubErrorResponse: Decodable {
        let message: String?
        let documentationURL: URL?

        enum CodingKeys: String, CodingKey {
            case message
            case documentationURL = "documentation_url"
        }
    }

    private enum UpdateManagerError: LocalizedError {
        case latestReleaseNotFound
        case latestReleaseRateLimited(String)
        case latestReleaseRequestFailed(statusCode: Int, message: String)
        case missingBundleVersion
        case invalidDownloadedApp
        case bundleIdentifierMismatch(String?)
        case stagedVersionMissing
        case stagedVersionOlderThanRelease(String)
        case extractionFailed(Int32)
        case helperLaunchFailed
        case codeSignatureInvalid(OSStatus)

        var errorDescription: String? {
            switch self {
            case .latestReleaseNotFound:
                return "GitHub does not currently have a published stable release for PR Dashboard."
            case let .latestReleaseRateLimited(message):
                return message
            case let .latestReleaseRequestFailed(statusCode, message):
                return "GitHub returned HTTP \(statusCode): \(message)"
            case .missingBundleVersion:
                return "The current app version is missing from the bundle metadata."
            case .invalidDownloadedApp:
                return "The downloaded archive did not contain a valid PRDashboard.app bundle."
            case let .bundleIdentifierMismatch(identifier):
                return "The downloaded app bundle identifier was \(identifier ?? "missing"), not com.xiaocang.PRDashboard."
            case .stagedVersionMissing:
                return "The downloaded app bundle is missing its version number."
            case let .stagedVersionOlderThanRelease(version):
                return "The downloaded app version (\(version)) is older than the GitHub release."
            case let .extractionFailed(status):
                return "Failed to extract the update archive (ditto exited with status \(status))."
            case .helperLaunchFailed:
                return "The installer helper could not be launched."
            case let .codeSignatureInvalid(status):
                return "The downloaded update failed code signature verification (OSStatus \(status))."
            }
        }
    }

    private let bundle: Bundle
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let session: URLSession
    private let latestReleaseURL = URL(string: "https://github.com/xiaocang/ghpr-view/releases.atom")!
    private let repositoryReleasesURL = URL(string: "https://github.com/xiaocang/ghpr-view/releases")!
    private let apiReleasesURL = URL(string: "https://api.github.com/repos/xiaocang/ghpr-view/releases")!
    private let autoCheckInterval: TimeInterval
    private let initialAutoCheckDelay: TimeInterval
    private let lastAutoCheckKey = "PRDashboard.LastAutoUpdateCheckAt"
    private let appName = "PRDashboard"

    private var configuration: Configuration
    private var launchDate = Date()
    private var launchAutomaticCheckPending = false
    private var automaticCheckTimer: Timer?
    private var checkTask: Task<Void, Never>?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadProgressObservation: NSKeyValueObservation?
    private var stagedUpdate: StagedUpdate?
    private var isCancellingDownload = false

    init(
        configuration: Configuration,
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        autoCheckInterval: TimeInterval = 24 * 60 * 60,
        initialAutoCheckDelay: TimeInterval = 10
    ) {
        self.configuration = configuration
        self.bundle = bundle
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.session = session
        self.autoCheckInterval = autoCheckInterval
        self.initialAutoCheckDelay = initialAutoCheckDelay
        self.lastAutoCheckAt = userDefaults.object(forKey: lastAutoCheckKey) as? Date
    }

    deinit {
        automaticCheckTimer?.invalidate()
        checkTask?.cancel()
        downloadTask?.cancel()
        downloadProgressObservation?.invalidate()
    }

    var currentVersionString: String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var currentBuildString: String {
        bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    var displayedRelease: ReleaseInfo? {
        errorDisplayedRelease ?? currentDisplayedRelease ?? stagedUpdate?.release
    }

    var canOpenLatestReleasePage: Bool {
        displayedRelease != nil || errorReleaseURL != nil
    }

    func start() {
        scheduleAutomaticCheckIfNeeded(resetLaunchDate: true)
    }

    func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
        scheduleAutomaticCheckIfNeeded(resetLaunchDate: false)
    }

    func checkForUpdates(userInitiated: Bool) {
        if userInitiated {
            onRequestPresentation?()
        }

        guard downloadTask == nil else {
            if !userInitiated {
                scheduleAutomaticCheck(at: Date().addingTimeInterval(60 * 60))
            }
            return
        }

        guard checkTask == nil else {
            if userInitiated {
                state = .checking(userInitiated: true)
            } else {
                scheduleAutomaticCheck(at: Date().addingTimeInterval(60 * 60))
            }
            return
        }

        if userInitiated {
            state = .checking(userInitiated: true)
        }

        checkTask = Task { [weak self] in
            guard let self else { return }
            await self.performLatestReleaseCheck(userInitiated: userInitiated)
        }
    }

    func cancelDownload() {
        guard let downloadTask, let release = currentDisplayedRelease else { return }

        isCancellingDownload = true
        downloadProgressObservation?.invalidate()
        downloadProgressObservation = nil
        self.downloadTask = nil
        downloadTask.cancel()
        state = stateForUpdateAvailability(release)
    }

    func downloadAvailableUpdate() {
        guard downloadTask == nil else { return }

        let release: ReleaseInfo
        switch state {
        case let .available(value):
            release = value
        case let .unsupportedInstallLocation(value, _):
            release = value
        case let .error(displayError):
            guard let stagedRelease = currentDisplayedRelease ?? stagedUpdate?.release else {
                return
            }
            if displayError.releasePageURL == stagedRelease.htmlURL {
                release = stagedRelease
            } else {
                return
            }
        default:
            guard let displayedRelease = currentDisplayedRelease else { return }
            release = displayedRelease
        }

        do {
            let asset = try release.preferredZipAsset()
            beginDownload(for: release, asset: asset)
        } catch {
            presentError(
                title: "Update Download Unavailable",
                message: error.localizedDescription,
                release: release,
                releasePageURL: release.htmlURL,
                userInitiated: true
            )
        }
    }

    func installAndRestart() {
        guard case let .readyToInstall(release, targetURL) = state,
              let stagedUpdate,
              stagedUpdate.matches(release) else {
            return
        }

        do {
            state = .installing(release: release, targetURL: targetURL)
            try launchInstallerHelper(for: stagedUpdate, targetURL: targetURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            presentError(
                title: "Install Failed",
                message: error.localizedDescription,
                release: release,
                releasePageURL: release.htmlURL,
                userInitiated: true
            )
        }
    }

    func openLatestReleasePage() {
        let url = currentDisplayedRelease?.htmlURL ??
            stagedUpdate?.release.htmlURL ??
            errorReleaseURL ??
            repositoryReleasesURL

        NSWorkspace.shared.open(url)
    }

    private func performLatestReleaseCheck(userInitiated: Bool) async {
        defer { checkTask = nil }

        if !userInitiated {
            if isBusyForAutomaticCheck {
                scheduleAutomaticCheck(at: Date().addingTimeInterval(60 * 60))
                return
            }

            recordAutomaticCheckAttempt()
        }

        do {
            let atomRelease = try await fetchLatestRelease()
            let currentVersion = try currentAppVersion()

            guard atomRelease.version > currentVersion else {
                updateLogger.info("Latest release \(atomRelease.displayVersion) is not newer than current version \(self.currentVersionString)")
                if userInitiated {
                    state = .upToDate(release: atomRelease)
                }
                return
            }

            let assets = try await fetchReleaseAssets(tag: atomRelease.tagName)
            let release = ReleaseInfo(
                tagName: atomRelease.tagName,
                name: atomRelease.name,
                body: atomRelease.body,
                publishedAt: atomRelease.publishedAt,
                htmlURL: atomRelease.htmlURL,
                assets: assets
            )

            do {
                _ = try release.preferredZipAsset()
            } catch {
                updateLogger.error("Latest release \(release.displayVersion) is missing a usable zip asset: \(error.localizedDescription)")
                if userInitiated {
                    presentError(
                        title: "Update Download Unavailable",
                        message: error.localizedDescription,
                        release: release,
                        releasePageURL: release.htmlURL,
                        userInitiated: true
                    )
                }
                return
            }

            if let stagedUpdate, stagedUpdate.matches(release), fileManager.fileExists(atPath: stagedUpdate.appURL.path) {
                state = readyStateForStagedUpdate(stagedUpdate, release: release)
            } else {
                stagedUpdate = nil
                state = stateForUpdateAvailability(release)
            }

            if !userInitiated {
                onRequestPresentation?()
            }
        } catch {
            updateLogger.error("Update check failed: \(error.localizedDescription)")
            if userInitiated {
                presentError(
                    title: "Update Check Failed",
                    message: error.localizedDescription,
                    release: currentDisplayedRelease ?? stagedUpdate?.release,
                    releasePageURL: currentDisplayedRelease?.htmlURL ?? repositoryReleasesURL,
                    userInitiated: true
                )
            }
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.setValue("PRDashboard/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            let httpResponse = response as? HTTPURLResponse
            throw latestReleaseRequestError(from: httpResponse, data: data)
        }

        guard let entry = ReleasesAtomFeedParser.parseFirstEntry(from: data) else {
            throw UpdateManagerError.latestReleaseNotFound
        }

        return ReleaseInfo(
            tagName: entry.tagName,
            name: entry.title,
            body: entry.body,
            publishedAt: entry.updated,
            htmlURL: entry.htmlURL,
            assets: []
        )
    }

    private func fetchReleaseAssets(tag: String) async throws -> [ReleaseAsset] {
        let tagURL = apiReleasesURL
            .appendingPathComponent("tags")
            .appendingPathComponent(tag)
        var request = URLRequest(url: tagURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PRDashboard/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw latestReleaseRequestError(from: response as? HTTPURLResponse, data: data)
        }

        struct ReleaseAssetsResponse: Decodable {
            let assets: [ReleaseAsset]
        }
        return try JSONDecoder().decode(ReleaseAssetsResponse.self, from: data).assets
    }

    private func beginDownload(for release: ReleaseInfo, asset: ReleaseAsset) {
        cleanupStagedUpdate(except: release.version)

        let request = URLRequest(url: asset.browserDownloadURL)
        let task = session.downloadTask(with: request) { [weak self] temporaryURL, _, error in
            Task { @MainActor [weak self] in
                self?.handleDownloadCompletion(
                    temporaryURL: temporaryURL,
                    release: release,
                    error: error
                )
            }
        }

        downloadTask = task
        observeDownloadProgress(for: task, release: release)
        state = .downloading(release: release, bytesReceived: 0, totalBytes: asset.size ?? 0)
        task.resume()
    }

    private func observeDownloadProgress(for task: URLSessionDownloadTask, release: ReleaseInfo) {
        downloadProgressObservation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                guard let self, self.downloadTask != nil else { return }
                let total = max(progress.totalUnitCount, 0)
                self.state = .downloading(
                    release: release,
                    bytesReceived: max(progress.completedUnitCount, 0),
                    totalBytes: total
                )
            }
        }
    }

    private func handleDownloadCompletion(
        temporaryURL: URL?,
        release: ReleaseInfo,
        error: Error?
    ) {
        downloadProgressObservation?.invalidate()
        downloadProgressObservation = nil
        downloadTask = nil

        if isCancellingDownload {
            isCancellingDownload = false
            return
        }

        if let nsError = error as NSError? {
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                state = stateForUpdateAvailability(release)
                return
            }

            presentError(
                title: "Download Failed",
                message: nsError.localizedDescription,
                release: release,
                releasePageURL: release.htmlURL,
                userInitiated: true
            )
            return
        }

        guard let temporaryURL else {
            presentError(
                title: "Download Failed",
                message: "GitHub did not return a downloadable archive.",
                release: release,
                releasePageURL: release.htmlURL,
                userInitiated: true
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.stageDownloadedRelease(from: temporaryURL, release: release)
        }
    }

    private func stageDownloadedRelease(from temporaryURL: URL, release: ReleaseInfo) async {
        do {
            let releaseDirectoryURL = try releaseDirectory(for: release)
            try createCleanDirectory(at: releaseDirectoryURL)

            let archiveURL = releaseDirectoryURL.appendingPathComponent("\(appName)-\(release.displayVersion).zip")
            try? fileManager.removeItem(at: archiveURL)
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)

            let appURL = try await Task.detached(priority: .userInitiated) {
                try Self.extractArchive(at: archiveURL, into: releaseDirectoryURL)
            }.value

            try validateDownloadedApp(at: appURL, for: release)

            let stagedUpdate = StagedUpdate(
                release: release,
                releaseDirectoryURL: releaseDirectoryURL,
                archiveURL: archiveURL,
                appURL: appURL
            )
            self.stagedUpdate = stagedUpdate
            state = readyStateForStagedUpdate(stagedUpdate, release: release)
        } catch {
            cleanupStagedUpdate(except: nil)
            presentError(
                title: "Update Preparation Failed",
                message: error.localizedDescription,
                release: release,
                releasePageURL: release.htmlURL,
                userInitiated: true
            )
        }
    }

    private func validateDownloadedApp(at appURL: URL, for release: ReleaseInfo) throws {
        guard appURL.lastPathComponent == "\(appName).app",
              let appBundle = Bundle(url: appURL) else {
            throw UpdateManagerError.invalidDownloadedApp
        }

        let identifier = appBundle.bundleIdentifier
        guard identifier == "com.xiaocang.PRDashboard" else {
            throw UpdateManagerError.bundleIdentifierMismatch(identifier)
        }

        guard let versionString = appBundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            throw UpdateManagerError.stagedVersionMissing
        }

        let downloadedVersion = AppVersion(versionString)
        guard downloadedVersion >= release.version else {
            throw UpdateManagerError.stagedVersionOlderThanRelease(versionString)
        }

        try verifyCodeSignature(at: appURL)
    }

    private func verifyCodeSignature(at stagedAppURL: URL) throws {
        var stagedStaticCode: SecStaticCode?
        let stagedStatus = SecStaticCodeCreateWithPath(stagedAppURL as CFURL, [], &stagedStaticCode)
        guard stagedStatus == errSecSuccess, let stagedStaticCode else {
            throw UpdateManagerError.codeSignatureInvalid(stagedStatus)
        }

        let validity = SecStaticCodeCheckValidity(stagedStaticCode, [], nil)
        guard validity == errSecSuccess else {
            throw UpdateManagerError.codeSignatureInvalid(validity)
        }
    }

    private func launchInstallerHelper(for stagedUpdate: StagedUpdate, targetURL: URL) throws {
        let helperDirectory = try updatesRootDirectory()
        let helperName = "install-update-\(UUID().uuidString).sh"
        let scriptURL = helperDirectory.appendingPathComponent(helperName)
        let backupURL = helperDirectory.appendingPathComponent("\(appName)-backup-\(UUID().uuidString).app")

        let script = """
        #!/bin/sh
        PID="$1"
        SOURCE_APP="$2"
        TARGET_APP="$3"
        BACKUP_APP="$4"
        SCRIPT_PATH="$5"

        cleanup() {
          rm -f "$SCRIPT_PATH"
        }

        trap cleanup EXIT

        while kill -0 "$PID" 2>/dev/null; do
          sleep 1
        done

        if [ -d "$TARGET_APP" ]; then
          rm -rf "$BACKUP_APP"
          mv "$TARGET_APP" "$BACKUP_APP" || exit 1
        fi

        if /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"; then
          /usr/bin/open "$TARGET_APP"
          rm -rf "$BACKUP_APP"
          rm -rf "$(dirname "$SOURCE_APP")"
        else
          rm -rf "$TARGET_APP"
          if [ -d "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "$TARGET_APP"
          fi
          exit 1
        fi
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            stagedUpdate.appURL.path,
            targetURL.path,
            backupURL.path,
            scriptURL.path
        ]
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
        } catch {
            throw UpdateManagerError.helperLaunchFailed
        }
    }

    private func currentAppVersion() throws -> AppVersion {
        guard let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            throw UpdateManagerError.missingBundleVersion
        }

        return AppVersion(version)
    }

    private func readyStateForStagedUpdate(_ stagedUpdate: StagedUpdate, release: ReleaseInfo) -> UpdateState {
        switch currentInstallEligibility {
        case let .eligible(targetURL):
            return .readyToInstall(release: release, targetURL: targetURL)
        case let .unsupported(reason):
            return .unsupportedInstallLocation(release: release, reason: reason)
        }
    }

    private func stateForUpdateAvailability(_ release: ReleaseInfo) -> UpdateState {
        switch currentInstallEligibility {
        case .eligible:
            return .available(release: release)
        case let .unsupported(reason):
            return .unsupportedInstallLocation(release: release, reason: reason)
        }
    }

    private var currentInstallEligibility: InstallEligibility {
        InstallEligibilityResolver.resolve(
            bundleURL: bundle.bundleURL,
            appName: appName,
            isBundleWritable: fileManager.isWritableFile(atPath: bundle.bundleURL.path)
        )
    }

    private var currentDisplayedRelease: ReleaseInfo? {
        state.releaseInfo
    }

    private var errorReleaseURL: URL? {
        guard case let .error(displayError) = state else { return nil }
        return displayError.release?.htmlURL ?? displayError.releasePageURL
    }

    private var errorDisplayedRelease: ReleaseInfo? {
        guard case let .error(displayError) = state else { return nil }
        return displayError.release
    }

    private var isBusyForAutomaticCheck: Bool {
        if downloadTask != nil {
            return true
        }

        switch state {
        case .installing:
            return true
        default:
            return false
        }
    }

    private func presentError(
        title: String,
        message: String,
        release: ReleaseInfo? = nil,
        releasePageURL: URL?,
        userInitiated: Bool
    ) {
        state = .error(
            UpdateDisplayError(
                title: title,
                message: message,
                releasePageURL: releasePageURL,
                release: release
            )
        )

        if userInitiated {
            onRequestPresentation?()
        }
    }

    private func latestReleaseRequestError(from response: HTTPURLResponse?, data: Data) -> Error {
        guard let response else {
            return UpdateManagerError.latestReleaseRequestFailed(
                statusCode: -1,
                message: "GitHub did not return an HTTP response."
            )
        }

        let statusCode = response.statusCode
        let apiMessage = parsedGitHubMessage(from: data)

        if statusCode == 404 {
            return UpdateManagerError.latestReleaseNotFound
        }

        if statusCode == 403 || statusCode == 429 {
            if let rateLimitMessage = rateLimitMessage(from: response, apiMessage: apiMessage) {
                return UpdateManagerError.latestReleaseRateLimited(rateLimitMessage)
            }
        }

        let fallbackMessage = apiMessage ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        return UpdateManagerError.latestReleaseRequestFailed(
            statusCode: statusCode,
            message: fallbackMessage
        )
    }

    private func parsedGitHubMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let payload = try? JSONDecoder().decode(GitHubErrorResponse.self, from: data),
           let message = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message.replacingOccurrences(of: "\n", with: " ")
        }

        if let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message.replacingOccurrences(of: "\n", with: " ")
        }

        return nil
    }

    private func rateLimitMessage(from response: HTTPURLResponse, apiMessage: String?) -> String? {
        let retryAfterSeconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let resetEpoch = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        let lowercasedMessage = apiMessage?.lowercased() ?? ""

        let isRateLimited = retryAfterSeconds != nil ||
            remaining == "0" ||
            lowercasedMessage.contains("rate limit")

        guard isRateLimited else { return nil }

        if let retryAfterSeconds {
            let retryDate = Date().addingTimeInterval(retryAfterSeconds)
            return "GitHub rate limit exceeded. Try again after \(Self.rateLimitDateFormatter.string(from: retryDate))."
        }

        if let resetEpoch {
            let resetDate = Date(timeIntervalSince1970: resetEpoch)
            return "GitHub rate limit exceeded. Try again after \(Self.rateLimitDateFormatter.string(from: resetDate))."
        }

        if let apiMessage, !apiMessage.isEmpty {
            return apiMessage
        }

        return "GitHub rate limit exceeded. Try again later."
    }

    private static let rateLimitDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func recordAutomaticCheckAttempt() {
        let now = Date()
        lastAutoCheckAt = now
        userDefaults.set(now, forKey: lastAutoCheckKey)
        scheduleAutomaticCheck(at: now.addingTimeInterval(autoCheckInterval))
    }

    private func scheduleAutomaticCheckIfNeeded(resetLaunchDate: Bool) {
        if resetLaunchDate {
            launchDate = Date()
            launchAutomaticCheckPending = true
        }

        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil

        guard configuration.automaticallyCheckForUpdates else { return }

        let nextDueDate: Date
        if launchAutomaticCheckPending {
            nextDueDate = launchDate.addingTimeInterval(initialAutoCheckDelay)
        } else if let lastAutoCheckAt {
            nextDueDate = lastAutoCheckAt.addingTimeInterval(autoCheckInterval)
        } else {
            nextDueDate = Date()
        }

        scheduleAutomaticCheck(at: nextDueDate)
    }

    private func scheduleAutomaticCheck(at date: Date) {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil

        guard configuration.automaticallyCheckForUpdates else { return }

        let interval = max(date.timeIntervalSinceNow, 0.1)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runAutomaticCheck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        automaticCheckTimer = timer
    }

    private func runAutomaticCheck() {
        if launchAutomaticCheckPending {
            launchAutomaticCheckPending = false
        }

        checkForUpdates(userInitiated: false)
    }

    private func updatesRootDirectory() throws -> URL {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let updatesDirectory = cachesDirectory
            .appendingPathComponent(bundle.bundleIdentifier ?? "com.prdashboard", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)

        try fileManager.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)
        return updatesDirectory
    }

    private func releaseDirectory(for release: ReleaseInfo) throws -> URL {
        try updatesRootDirectory()
            .appendingPathComponent(release.displayVersion, isDirectory: true)
    }

    private func createCleanDirectory(at url: URL) throws {
        try? fileManager.removeItem(at: url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func cleanupStagedUpdate(except version: AppVersion?) {
        guard let stagedUpdate else { return }

        if let version, stagedUpdate.release.version == version {
            return
        }

        try? fileManager.removeItem(at: stagedUpdate.releaseDirectoryURL)
        self.stagedUpdate = nil
    }

    nonisolated private static func extractArchive(at archiveURL: URL, into releaseDirectoryURL: URL) throws -> URL {
        let extractionDirectory = releaseDirectoryURL.appendingPathComponent("expanded", isDirectory: true)
        let fileManager = FileManager.default

        try? fileManager.removeItem(at: extractionDirectory)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, extractionDirectory.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateManagerError.extractionFailed(process.terminationStatus)
        }

        let appURL = extractionDirectory.appendingPathComponent("PRDashboard.app", isDirectory: true)
        guard fileManager.fileExists(atPath: appURL.path) else {
            throw UpdateManagerError.invalidDownloadedApp
        }

        return appURL
    }
}

struct ReleasesAtomEntry {
    let tagName: String
    let title: String?
    let updated: Date
    let htmlURL: URL
    let body: String

    var version: AppVersion { AppVersion(tagName) }
}

final class ReleasesAtomFeedParser: NSObject, XMLParserDelegate {
    static func parseFirstEntry(from data: Data) -> ReleasesAtomEntry? {
        let parser = XMLParser(data: data)
        let delegate = ReleasesAtomFeedParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.makeEntry()
    }

    private var inEntry = false
    private var finishedFirstEntry = false
    private var currentPath: [String] = []
    private var titleBuffer = ""
    private var updatedBuffer = ""
    private var contentBuffer = ""
    private var entryLinkHref: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard !finishedFirstEntry else { return }

        if elementName == "entry" {
            inEntry = true
            currentPath = []
            return
        }

        if inEntry {
            currentPath.append(elementName)
            if currentPath == ["link"] {
                if entryLinkHref == nil, let href = attributeDict["href"] {
                    entryLinkHref = href
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry, !finishedFirstEntry else { return }

        switch currentPath {
        case ["title"]:
            titleBuffer += string
        case ["updated"]:
            updatedBuffer += string
        case ["content"]:
            contentBuffer += string
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !finishedFirstEntry else { return }

        if elementName == "entry" {
            finishedFirstEntry = true
            inEntry = false
            return
        }

        if inEntry, !currentPath.isEmpty {
            currentPath.removeLast()
        }
    }

    private func makeEntry() -> ReleasesAtomEntry? {
        guard let href = entryLinkHref,
              let url = URL(string: href),
              let updated = DateFormatters.parseISO8601(updatedBuffer.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        let tag = url.lastPathComponent
        guard !tag.isEmpty else { return nil }

        let trimmedTitle = titleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Self.htmlToPlainText(contentBuffer)

        return ReleasesAtomEntry(
            tagName: tag,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            updated: updated,
            htmlURL: url,
            body: body
        )
    }

    private static func htmlToPlainText(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return "" }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
