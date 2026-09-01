import Darwin
import Foundation
import os

private let ciLogFetcherLogger = Logger(subsystem: "com.prdashboard", category: "CILogFetcher")

/// Head of the most recent failed CI job log for a pull request, embedded in the
/// agent context as the `failed_job_logs` section. Resolution and download mirror
/// the `kong-ci-log` skill's `fetch-ci-log.sh` script: `gh pr checks` selects the
/// latest failed check link, then the job/run log is downloaded through the gh CLI.
struct FailedJobLogs: Codable, Equatable, Sendable {
    let repository: String
    let prNumber: Int
    let workflowName: String?
    let runID: Int64?
    let jobID: Int64?
    /// Bytes of normalized log content fetched (pre-truncation).
    let capturedBytes: Int
    /// True when `content` was cut at the context size limit (head retained).
    let truncated: Bool
    /// True when the raw log exceeded the capture cap (head retained).
    let capturedOverflow: Bool
    let fetchedAt: Date
    let content: String
}

enum CILogFetcherError: LocalizedError, Equatable {
    case ghNotFound
    case ghNotAuthenticated
    case noFailedCheck(repository: String, prNumber: Int)
    case resolutionFailed(String)
    case logsExpired(String)
    case logFetchFailed(String)
    case processFailed(Int32, String)
    case launchFailed(Int32)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "gh CLI is not installed. Install GitHub CLI (https://cli.github.com/) to fetch CI logs for analysis."
        case .ghNotAuthenticated:
            return "gh CLI is not authenticated. Run `gh auth login` first."
        case .noFailedCheck(let repository, let prNumber):
            return "No failed check found for PR #\(prNumber) on \(repository)."
        case .resolutionFailed(let message):
            return "Could not resolve a failed CI run: \(message)"
        case .logsExpired(let message):
            return "CI logs expired (HTTP 410) — purged by GitHub: \(message)"
        case .logFetchFailed(let message):
            return "Failed to fetch CI log: \(message)"
        case .processFailed(let status, let detail):
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return "gh exited with status \(status)\(suffix)"
        case .launchFailed(let code):
            return "Could not launch gh (error \(code))."
        case .timedOut(let operation):
            return "gh \(operation) timed out."
        }
    }
}

/// Fetches the failed CI log for a pull request through the user's `gh` CLI.
/// Requires `gh` installed and authenticated (`gh auth login`); the app does not
/// hold GitHub credentials for Actions logs, so the CLI is the auth boundary.
enum CILogFetcher {
    static let maximumCaptureBytes = 4 * 1024 * 1024
    static let maximumContextBytes = 256 * 1024
    static let maximumDiagnosticBytes = 256 * 1024
    static let commandTimeoutSeconds = 30
    static let logTimeoutSeconds = 180

    // MARK: - Entry point

    static func fetchFailedJobLogs(
        repository: String,
        prNumber: Int,
        now: Date = Date()
    ) async throws -> FailedJobLogs {
        let gh = try resolveGHExecutable()
        try await verifyAuthentication(gh)
        let allowsEscapeSequences = await apiAllowsEscapeSequences(gh)
        let check = try await resolveFailedCheck(
            gh,
            repository: repository,
            prNumber: prNumber
        )
        let raw = try await downloadFailedLog(
            gh: gh,
            repository: repository,
            runID: check.runID,
            jobID: check.jobID,
            allowsEscapeSequences: allowsEscapeSequences
        )
        let normalized = cleanLog(raw.content)
        let content = sliceAroundFailure(
            normalized,
            byteLimit: maximumContextBytes
        )
        let truncated = normalized.utf8.count > maximumContextBytes
        ciLogFetcherLogger.info(
            "Fetched CI log for \(repository)#\(prNumber): \(normalized.utf8.count) bytes, truncated=\(truncated), overflow=\(raw.overflow)"
        )
        return FailedJobLogs(
            repository: repository,
            prNumber: prNumber,
            workflowName: check.name,
            runID: check.runID,
            jobID: check.jobID,
            capturedBytes: normalized.utf8.count,
            truncated: truncated,
            capturedOverflow: raw.overflow,
            fetchedAt: now,
            content: content
        )
    }

    // MARK: - gh resolution & authentication

    static func resolveGHExecutable() throws -> URL {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/gh"),
            home.appendingPathComponent(".bin/gh"),
            URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
            URL(fileURLWithPath: "/usr/local/bin/gh")
        ]
        candidates.append(contentsOf:
            (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map {
                    URL(fileURLWithPath: String($0), isDirectory: true)
                        .appendingPathComponent("gh")
                }
        )
        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw CILogFetcherError.ghNotFound
        }
        return executable
    }

    static func verifyAuthentication(_ gh: URL) async throws {
        let result = try await run(
            gh,
            arguments: ["auth", "token"],
            operation: "auth token",
            timeoutSeconds: commandTimeoutSeconds,
            maximumOutputBytes: 4 * 1024
        )
        guard result.success else {
            throw CILogFetcherError.ghNotAuthenticated
        }
    }

    /// gh >= 2.94 refuses to emit response content containing terminal escape
    /// sequences to a non-TTY unless `--allow-escape-sequences` is passed. Older
    /// gh does not know the flag, so probe `gh api --help` once (mirrors
    /// fetch-ci-log.sh).
    static func apiAllowsEscapeSequences(_ gh: URL) async -> Bool {
        guard let result = try? await run(
            gh,
            arguments: ["api", "--help"],
            operation: "api --help",
            timeoutSeconds: commandTimeoutSeconds,
            maximumOutputBytes: 64 * 1024
        ), result.success else {
            return false
        }
        return result.stdout.contains("--allow-escape-sequences")
    }

    // MARK: - Failed check resolution

    struct FailedCheck {
        let runID: Int64
        let jobID: Int64?
        let name: String?
    }

    static func resolveFailedCheck(
        _ gh: URL,
        repository: String,
        prNumber: Int
    ) async throws -> FailedCheck {
        let jq = """
        [.[] | select(.bucket=="fail" and .link != null)] | sort_by(.completedAt) \
        | last | [.link, .name] | @tsv
        """
        let result = try await run(
            gh,
            arguments: [
                "pr", "checks", "\(prNumber)",
                "--repo", repository,
                "--json", "name,bucket,link,completedAt",
                "--jq", jq
            ],
            operation: "pr checks",
            timeoutSeconds: commandTimeoutSeconds,
            maximumOutputBytes: 64 * 1024
        )
        // `gh pr checks` exits 1 when any check failed and 8 when checks are
        // pending — the exact states this fetcher runs in — so the exit code is
        // not a pass/fail signal. Judge the parsed stdout; only a non-zero exit
        // with empty output is a resolution error (mirrors fetch-ci-log.sh).
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            if result.status != 0 {
                throw CILogFetcherError.resolutionFailed(trimmedDiagnostic(result.stderr))
            }
            throw CILogFetcherError.noFailedCheck(
                repository: repository,
                prNumber: prNumber
            )
        }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        let link = parts.first.map(String.init) ?? ""
        let name = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        guard let runID = extractRunID(from: link) else {
            throw CILogFetcherError.resolutionFailed(
                "could not extract a workflow run id from \(link)"
            )
        }
        return FailedCheck(runID: runID, jobID: extractJobID(from: link), name: name)
    }

    /// Check links look like `…/actions/runs/<RUN_ID>/job/<JOB_ID>`.
    static func extractRunID(from link: String) -> Int64? {
        guard let range = link.range(of: "/actions/runs/") else { return nil }
        let digits = link[range.upperBound...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int64(digits)
    }

    static func extractJobID(from link: String) -> Int64? {
        guard let range = link.range(of: "/job/") else { return nil }
        let digits = link[range.upperBound...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int64(digits)
    }

    // MARK: - Log download (mirrors fetch-ci-log.sh's job-first, run fallback)

    /// Raw downloaded log plus whether the capture cap was exceeded (head kept).
    struct DownloadedLog {
        let content: String
        let overflow: Bool
    }

    static func downloadFailedLog(
        gh: URL,
        repository: String,
        runID: Int64,
        jobID: Int64?,
        allowsEscapeSequences: Bool
    ) async throws -> DownloadedLog {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw CILogFetcherError.resolutionFailed(
                "invalid repository \(repository)"
            )
        }
        let owner = parts[0]
        let name = parts[1]

        if let jobID {
            let jobResult = try await run(
                gh,
                arguments: [
                    "run", "view", "--repo", repository,
                    "--job", "\(jobID)", "--log"
                ],
                operation: "run view --job",
                timeoutSeconds: logTimeoutSeconds,
                maximumOutputBytes: maximumCaptureBytes
            )
            if jobResult.status == 0, !jobResult.stdout.isEmpty {
                return DownloadedLog(
                    content: jobResult.stdout,
                    overflow: jobResult.stdoutOverflow
                )
            }
            if isExpired(jobResult.stderr) {
                throw CILogFetcherError.logsExpired("job \(jobID)")
            }
            let apiResult = try await run(
                gh,
                arguments: apiLogArguments(
                    owner: owner,
                    name: name,
                    jobID: jobID,
                    allowsEscapeSequences: allowsEscapeSequences
                ),
                operation: "job logs API",
                timeoutSeconds: logTimeoutSeconds,
                maximumOutputBytes: maximumCaptureBytes
            )
            if isExpired(apiResult.stderr) {
                throw CILogFetcherError.logsExpired("job \(jobID)")
            }
            if apiResult.status == 0, !apiResult.stdout.isEmpty {
                return DownloadedLog(
                    content: apiResult.stdout,
                    overflow: apiResult.stdoutOverflow
                )
            }
            throw CILogFetcherError.logFetchFailed(
                trimmedDiagnostic(apiResult.stderr.isEmpty ? jobResult.stderr : apiResult.stderr)
            )
        }

        // No job id in the check link: download the run's failed-job log.
        let runResult = try await run(
            gh,
            arguments: ["run", "view", "\(runID)", "--repo", repository, "--log-failed"],
            operation: "run view --log-failed",
            timeoutSeconds: logTimeoutSeconds,
            maximumOutputBytes: maximumCaptureBytes
        )
        if runResult.status == 0, !runResult.stdout.isEmpty {
            return DownloadedLog(
                content: runResult.stdout,
                overflow: runResult.stdoutOverflow
            )
        }
        if isExpired(runResult.stderr) {
            throw CILogFetcherError.logsExpired("run \(runID)")
        }

        // Per-job fallback: concatenate every unsuccessful job's log via the API.
        let jobsJQ = """
        .jobs[] | select((.conclusion // "") as $c | $c != "" and $c != "success" \
        and $c != "skipped" and $c != "neutral") | .databaseId
        """
        let jobsResult = try await run(
            gh,
            arguments: [
                "run", "view", "\(runID)", "--repo", repository,
                "--json", "jobs", "--jq", jobsJQ
            ],
            operation: "run jobs list",
            timeoutSeconds: commandTimeoutSeconds,
            maximumOutputBytes: 256 * 1024
        )
        let jobIDs = jobsResult.stdout
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int64($0) }
        guard !jobIDs.isEmpty else {
            if jobsResult.status != 0 {
                throw CILogFetcherError.logFetchFailed(
                    trimmedDiagnostic("\(runResult.stderr) \(jobsResult.stderr)")
                )
            }
            throw CILogFetcherError.logFetchFailed(
                "no unsuccessful jobs found for run \(runID)"
            )
        }
        var combined = ""
        var overflow = false
        for id in jobIDs {
            combined += "=== Job \(id) ===\n"
            let apiResult = try await run(
                gh,
                arguments: apiLogArguments(
                    owner: owner,
                    name: name,
                    jobID: id,
                    allowsEscapeSequences: allowsEscapeSequences
                ),
                operation: "job logs API",
                timeoutSeconds: logTimeoutSeconds,
                maximumOutputBytes: maximumCaptureBytes
            )
            if isExpired(apiResult.stderr) {
                throw CILogFetcherError.logsExpired("job \(id)")
            }
            if apiResult.status == 0, !apiResult.stdout.isEmpty {
                combined += apiResult.stdout
                overflow = overflow || apiResult.stdoutOverflow
            } else {
                combined += "[failed to fetch job \(id)]"
            }
            combined += "\n"
        }
        return DownloadedLog(content: combined, overflow: overflow)
    }

    static func apiLogArguments(
        owner: String,
        name: String,
        jobID: Int64,
        allowsEscapeSequences: Bool
    ) -> [String] {
        var arguments = ["api"]
        if allowsEscapeSequences {
            arguments.append("--allow-escape-sequences")
        }
        arguments.append("repos/\(owner)/\(name)/actions/jobs/\(jobID)/logs")
        return arguments
    }

    private static func isExpired(_ stderr: String) -> Bool {
        stderr.contains("HTTP 410")
    }

    private static func trimmedDiagnostic(_ stderr: String) -> String {
        let collapsed = stderr
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(300))
    }

    // MARK: - Log normalization & bounding (pure, testable)

    /// Strips ANSI CSI/OSC escape sequences and normalizes CR line endings so the
    /// agent receives plain text instead of terminal control noise.
    static func cleanLog(_ raw: String) -> String {
        var text = raw
        if let osc = try? NSRegularExpression(
            pattern: "\u{1B}\\]((?:[^\u{0007}\u{001B}]|\u{001B}(?!\\\\))*?)(?:\u{0007}|\u{001B}\\\\)"
        ) {
            text = osc.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        if let csi = try? NSRegularExpression(
            pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
        ) {
            text = csi.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        return text
    }

    /// Keeps the last `byteLimit` bytes, dropping a possibly mangled first line
    /// at the cut boundary. Mirrors flaky-analyzer's `tailTruncate`.
    static func tailTruncate(_ input: String, byteLimit: Int) -> String {
        let data = Data(input.utf8)
        guard data.count > byteLimit else { return input }
        let trimmed = data.suffix(byteLimit)
        var text = String(decoding: trimmed, as: UTF8.self)
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return "… (truncated, showing last \(byteLimit) bytes)\n\(text)"
    }

    /// Locates the failure anchor for `sliceAroundFailure`. Tiered to avoid false
    /// positives: `##[error]` GitHub annotations are definitive; strong uppercase
    /// failure words (`FAILED`, `FATAL`, …) come next; a case-insensitive
    /// `Error`/`fatal` scan is the last resort. flaky-analyzer's single loose
    /// pattern anchors on package names like `libgpg-error` or env vars like
    /// `FAILED_TEST_FILES_FILE`, which would slice the wrong region of a real
    /// Kong log (the `##[error]` annotation sits at line ~11662 of ~22600).
    static func failureAnchor(in text: String) -> Range<String.Index>? {
        if let range = text.range(
            of: "##\\[error\\]",
            options: .regularExpression
        ) {
            return range
        }
        if let range = text.range(
            of: "\\b(?:FAILED|FAILURE|FATAL|PANIC|EXCEPTION)\\b",
            options: .regularExpression
        ) {
            return range
        }
        if let range = text.range(
            of: "\\b(?:Error|fatal)\\b",
            options: [.regularExpression, .caseInsensitive]
        ) {
            return range
        }
        return nil
    }

    /// Keeps a window around the first failure-like line when the log exceeds
    /// `byteLimit`, falling back to `tailTruncate` when no failure line matches.
    /// Mirrors flaky-analyzer's `sliceAroundFailure` (window math, elision
    /// markers, tail fallback); the anchor itself is tiered via
    /// `failureAnchor(in:)`. Failure markers in real Kong logs (e.g.
    /// `##[error]Unable to download artifact(s)…`) can sit past the halfway
    /// point, so head-truncation would lose the signal entirely.
    static func sliceAroundFailure(_ input: String, byteLimit: Int) -> String {
        let data = Data(input.utf8)
        guard data.count > byteLimit else { return input }

        guard let match = failureAnchor(in: input),
              let failUTF8Index = match.lowerBound.samePosition(in: input.utf8) else {
            return tailTruncate(input, byteLimit: byteLimit)
        }
        let failByte = input.utf8.distance(from: input.startIndex, to: failUTF8Index)
        let beforeBudget = byteLimit * 3 / 10
        let afterBudget = byteLimit - beforeBudget
        var start = max(0, failByte - beforeBudget)
        var end = min(data.count, failByte + afterBudget)
        // Rebalance if one side is clipped.
        if start == 0 {
            end = min(data.count, end + (beforeBudget - failByte))
        }
        if end == data.count {
            start = max(0, start - (afterBudget - (data.count - failByte)))
        }
        var slice = String(decoding: data[start..<end], as: UTF8.self)
        if start > 0, let firstNewline = slice.firstIndex(of: "\n") {
            slice = String(slice[slice.index(after: firstNewline)...])
        }
        if end < data.count, let lastNewline = slice.lastIndex(of: "\n") {
            slice = String(slice[..<lastNewline])
        }
        let head = start > 0 ? "… (\(start) bytes elided before first failure)\n" : ""
        let tail = end < data.count ? "\n… (\(data.count - end) bytes elided after)" : ""
        return head + slice + tail
    }

    // MARK: - Bounded process runner

    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let stdoutOverflow: Bool

        var success: Bool {
            // A non-zero exit is a failure; output overflow is not — a log larger
            // than the capture cap still yields a usable head.
            status == 0
        }
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        operation: String,
        timeoutSeconds: Int,
        maximumOutputBytes: Int
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = AgentCLIAdapter.sanitizedEnvironment()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw CILogFetcherError.launchFailed(Int32((error as NSError).code))
        }
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutTask = Task.detached(priority: .utility) {
            drain(stdoutHandle, maximumBytes: maximumOutputBytes)
        }
        let stderrTask = Task.detached(priority: .utility) {
            drain(stderrHandle, maximumBytes: maximumDiagnosticBytes)
        }
        let timeoutBox = TimeoutBox()
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(1, timeoutSeconds)) * 1_000_000_000
                )
                guard !Task.isCancelled else { return }
                timeoutBox.markTimedOut()
                terminate(process)
            } catch {
                return
            }
        }
        defer { timeoutTask.cancel() }
        while process.isRunning {
            if Task.isCancelled {
                terminate(process)
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = await stdoutTask.result
        _ = await stderrTask.result
        if timeoutBox.didTimeOut {
            throw CILogFetcherError.timedOut(operation)
        }
        let status = process.terminationReason == .exit
            ? process.terminationStatus
            : 1
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        return CommandResult(
            status: status,
            stdout: String(decoding: stdout.data, as: UTF8.self),
            stderr: String(decoding: stderr.data, as: UTF8.self),
            stdoutOverflow: stdout.overflow
        )
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // SIGTERM first; escalate to SIGKILL after a short grace period.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private struct BoundedData {
        let data: Data
        let overflow: Bool
    }

    private static func drain(_ handle: FileHandle, maximumBytes: Int) -> BoundedData {
        defer { try? handle.close() }
        var data = Data()
        var overflow = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            let remaining = maximumBytes - data.count
            if remaining > 0 {
                data.append(contentsOf: buffer.prefix(min(count, remaining)))
            }
            if count > remaining {
                overflow = true
            }
        }
        return BoundedData(data: data, overflow: overflow)
    }

    private final class TimeoutBox: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }
    }
}
