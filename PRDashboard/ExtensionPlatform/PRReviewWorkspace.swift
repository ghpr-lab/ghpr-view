import Darwin
import Foundation

struct PRReviewCommandRequest: Sendable {
    let executable: URL
    let arguments: [String]
    let currentDirectoryURL: URL?
    let timeoutSeconds: TimeInterval
    let maximumStdoutBytes: Int
    let maximumStderrBytes: Int
}

typealias PRReviewCommandRunner = @Sendable (PRReviewCommandRequest) async throws -> ExtensionCommandResult

private final class PRReviewProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        Darwin.kill(-pid, SIGTERM)
        usleep(250_000)
        if process.isRunning {
            Darwin.kill(-pid, SIGKILL)
        }
    }
}

enum PRReviewCommand {
    static func run(_ request: PRReviewCommandRequest) async throws -> ExtensionCommandResult {
        let controller = PRReviewProcessController()
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: ExtensionCommandResult.self) { group in
                    group.addTask {
                        try await execute(request, controller: controller)
                    }
                    group.addTask {
                        try await Task.sleep(
                            nanoseconds: UInt64(request.timeoutSeconds * 1_000_000_000)
                        )
                        throw GitHubSubjectResolverError.commandTimedOut
                    }
                    guard let result = try await group.next() else {
                        throw GitHubSubjectResolverError.commandFailed("The review command did not run.")
                    }
                    group.cancelAll()
                    return result
                }
            } catch {
                controller.terminate()
                throw error
            }
        } onCancel: {
            controller.terminate()
        }
    }

    private static func execute(
        _ request: PRReviewCommandRequest,
        controller: PRReviewProcessController
    ) async throws -> ExtensionCommandResult {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let captureRoot = fileManager.temporaryDirectory
                .appendingPathComponent("ghpr-review-command-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: captureRoot, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: captureRoot) }

            let stdoutURL = captureRoot.appendingPathComponent("stdout")
            let stderrURL = captureRoot.appendingPathComponent("stderr")
            fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            fileManager.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let process = Process()
            process.executableURL = request.executable
            process.arguments = request.arguments
            process.currentDirectoryURL = request.currentDirectoryURL
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try process.run()
            _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
            controller.install(process)
            defer { controller.clear() }
            process.waitUntilExit()
            try stdoutHandle.synchronize()
            try stderrHandle.synchronize()
            try Task.checkCancellation()

            return ExtensionCommandResult(
                exitCode: process.terminationStatus,
                stdout: try capturedString(at: stdoutURL, limit: request.maximumStdoutBytes),
                stderr: try capturedString(at: stderrURL, limit: request.maximumStderrBytes)
            )
        }.value
    }

    private static func capturedString(at url: URL, limit: Int) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else {
            throw GitHubSubjectResolverError.commandOutputTooLarge
        }
        return String(decoding: try Data(contentsOf: url, options: [.mappedIfSafe]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ReviewSkippedFile: Codable, Equatable, Sendable {
    let path: String
    let reason: String
}

struct PRReviewWorkspace: Sendable, Equatable {
    let subject: PullRequestRevisionSubject
    let checkoutURL: URL
    let diff: String
    let mergeBaseSHA: String?
    let reviewedFiles: [String]
    let skippedFiles: [ReviewSkippedFile]
    let blobSHAs: [String: String]
    let cleanupURL: URL?

    init(
        subject: PullRequestRevisionSubject,
        checkoutURL: URL,
        diff: String,
        mergeBaseSHA: String? = nil,
        reviewedFiles: [String] = [],
        skippedFiles: [ReviewSkippedFile] = [],
        blobSHAs: [String: String] = [:],
        cleanupURL: URL? = nil
    ) {
        self.subject = subject
        self.checkoutURL = checkoutURL
        self.diff = diff
        self.mergeBaseSHA = mergeBaseSHA
        self.reviewedFiles = reviewedFiles
        self.skippedFiles = skippedFiles
        self.blobSHAs = blobSHAs
        self.cleanupURL = cleanupURL
    }
}

struct PRReviewWorkspaceManager: Sendable {
    private static let cloneTimeout: TimeInterval = 300
    private static let commandTimeout: TimeInterval = 120
    private static let maximumDiagnosticBytes = 256 * 1_024
    private static let maximumDiffBytes = 32 * 1_024 * 1_024
    private static let maximumInvocationPatchBytes = 768 * 1_024

    private let rootURL: URL
    private let ghURL: URL?
    private let gitURL: URL?
    private let runner: PRReviewCommandRunner

    init(
        rootURL: URL = FileManager.default.temporaryDirectory,
        ghURL: URL? = GitHubSubjectResolver.executable(named: "gh"),
        gitURL: URL? = GitHubSubjectResolver.executable(named: "git"),
        runner: ExtensionCommandRunner? = nil
    ) {
        self.rootURL = rootURL
        self.ghURL = ghURL
        self.gitURL = gitURL
        if let runner {
            self.runner = { request in
                try await runner(
                    request.executable,
                    request.arguments,
                    request.currentDirectoryURL
                )
            }
        } else {
            self.runner = { request in
                try await PRReviewCommand.run(request)
            }
        }
    }

    func prepare(subject: PullRequestRevisionSubject) async throws -> PRReviewWorkspace {
        guard let ghURL else {
            throw GitHubSubjectResolverError.missingExecutable("gh")
        }
        guard let gitURL else {
            throw GitHubSubjectResolverError.missingExecutable("git")
        }
        let fileManager = FileManager.default
        let runRoot = rootURL.appendingPathComponent(
            "ghpr-review-\(UUID().uuidString)",
            isDirectory: true
        )
        let checkoutURL = runRoot.appendingPathComponent("checkout", isDirectory: true)
        try fileManager.createDirectory(at: runRoot, withIntermediateDirectories: true)

        do {
            _ = try await checkedRun(
                ghURL,
                [
                    "repo", "clone", subject.repository, checkoutURL.path,
                    "--", "--filter=blob:none", "--no-checkout"
                ],
                currentDirectoryURL: runRoot,
                timeout: Self.cloneTimeout,
                fallback: "Unable to clone the pull request repository with gh."
            )
            _ = try await checkedRun(
                ghURL,
                [
                    "pr", "checkout", String(subject.prNumber),
                    "--repo", subject.repository, "--detach", "--force"
                ],
                currentDirectoryURL: checkoutURL,
                fallback: "Unable to check out the pull request with gh."
            )
            let resolvedHead = try await checkedRun(
                gitURL,
                ["rev-parse", "HEAD"],
                currentDirectoryURL: checkoutURL,
                fallback: "Unable to verify the pull request review workspace."
            ).stdout.lowercased()
            guard resolvedHead == subject.headSHA else {
                throw GitHubSubjectResolverError.revisionMismatch
            }
            _ = try await checkedRun(
                gitURL,
                ["fetch", "origin", subject.baseSHA, subject.headSHA],
                currentDirectoryURL: checkoutURL,
                fallback: "Unable to fetch the exact pull request revisions."
            )
            for sha in [subject.baseSHA, subject.headSHA] {
                _ = try await checkedRun(
                    gitURL,
                    ["cat-file", "-e", "\(sha)^{commit}"],
                    currentDirectoryURL: checkoutURL,
                    fallback: "The requested pull request revision is unavailable."
                )
            }
            let mergeBaseSHA = try await checkedRun(
                gitURL,
                ["merge-base", subject.baseSHA, subject.headSHA],
                currentDirectoryURL: checkoutURL,
                fallback: "Unable to resolve the pull request merge base."
            ).stdout.lowercased()
            guard Self.isSHA(mergeBaseSHA) else {
                throw GitHubSubjectResolverError.malformedResponse
            }
            let names = try await checkedRun(
                gitURL,
                ["diff", "--name-status", "--find-renames", "\(mergeBaseSHA)..\(subject.headSHA)"],
                currentDirectoryURL: checkoutURL,
                fallback: "Unable to enumerate changed pull request files."
            ).stdout
            let completeDiff = try await checkedRun(
                gitURL,
                [
                    "diff", "--find-renames", "--no-ext-diff", "--unified=3",
                    "\(mergeBaseSHA)..\(subject.headSHA)"
                ],
                currentDirectoryURL: checkoutURL,
                maximumStdoutBytes: Self.maximumDiffBytes,
                fallback: "Unable to generate the exact pull request diff."
            ).stdout
            let changedFiles = Self.changedFiles(fromNameStatus: names)
            let bounded = Self.boundedPatch(completeDiff, changedFiles: changedFiles)
            var blobSHAs: [String: String] = [:]
            for path in bounded.reviewedFiles {
                let blobSHA = try await checkedRun(
                    gitURL,
                    ["rev-parse", "\(subject.headSHA):\(path)"],
                    currentDirectoryURL: checkoutURL,
                    fallback: "Unable to resolve the reviewed file blob."
                ).stdout.lowercased()
                guard Self.isSHA(blobSHA) else {
                    throw GitHubSubjectResolverError.malformedResponse
                }
                blobSHAs[path] = blobSHA
            }
            return PRReviewWorkspace(
                subject: subject,
                checkoutURL: checkoutURL,
                diff: bounded.diff,
                mergeBaseSHA: mergeBaseSHA,
                reviewedFiles: bounded.reviewedFiles,
                skippedFiles: bounded.skippedFiles,
                blobSHAs: blobSHAs,
                cleanupURL: runRoot
            )
        } catch {
            try? fileManager.removeItem(at: runRoot)
            throw error
        }
    }

    private func checkedRun(
        _ executable: URL,
        _ arguments: [String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = PRReviewWorkspaceManager.commandTimeout,
        maximumStdoutBytes: Int = 1 * 1_024 * 1_024,
        fallback: String
    ) async throws -> ExtensionCommandResult {
        let result = try await runner(
            PRReviewCommandRequest(
                executable: executable,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                timeoutSeconds: timeout,
                maximumStdoutBytes: maximumStdoutBytes,
                maximumStderrBytes: Self.maximumDiagnosticBytes
            )
        )
        guard result.succeeded else {
            throw GitHubSubjectResolverError.commandFailed(
                GitHubSubjectResolver.boundedDiagnostic(result.stderr, fallback: fallback)
            )
        }
        return result
    }

    private static func changedFiles(fromNameStatus value: String) -> [String] {
        value.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            return String(fields.last ?? "")
        }
    }

    private static func boundedPatch(
        _ diff: String,
        changedFiles: [String]
    ) -> (diff: String, reviewedFiles: [String], skippedFiles: [ReviewSkippedFile]) {
        let starts = diff.ranges(of: "diff --git ").map(\.lowerBound)
        guard !starts.isEmpty else {
            return (
                "",
                [],
                changedFiles.map { ReviewSkippedFile(path: $0, reason: "diff unavailable") }
            )
        }
        var blocks: [String] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : diff.endIndex
            blocks.append(String(diff[start..<end]))
        }

        var selected: [String] = []
        var reviewed: [String] = []
        var skipped: [ReviewSkippedFile] = []
        var usedBytes = 0
        for (index, block) in blocks.enumerated() {
            let path = index < changedFiles.count ? changedFiles[index] : "unknown-\(index + 1)"
            let blockBytes = block.utf8.count
            let reason: String?
            if block.contains("Binary files ") || block.contains("GIT binary patch") {
                reason = "binary"
            } else if blockBytes > maximumInvocationPatchBytes {
                reason = "file patch exceeds the invocation budget"
            } else if usedBytes + blockBytes > maximumInvocationPatchBytes {
                reason = "invocation budget exhausted"
            } else {
                reason = nil
            }
            if let reason {
                skipped.append(ReviewSkippedFile(path: path, reason: reason))
            } else {
                selected.append(block)
                reviewed.append(path)
                usedBytes += blockBytes
            }
        }
        if changedFiles.count > blocks.count {
            skipped.append(contentsOf: changedFiles.dropFirst(blocks.count).map {
                ReviewSkippedFile(path: $0, reason: "diff unavailable")
            })
        }
        return (selected.joined(), reviewed, skipped)
    }

    private static func isSHA(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = startIndex
        while cursor < endIndex,
              let range = range(of: needle, range: cursor..<endIndex) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }
}
