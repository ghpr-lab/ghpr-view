import CryptoKit
import Foundation

struct ExtensionCommandResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

typealias ExtensionCommandRunner = @Sendable (
    URL,
    [String],
    URL?
) async throws -> ExtensionCommandResult

enum ExtensionCommand {
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) async throws -> ExtensionCommandResult {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let captureRoot = fileManager.temporaryDirectory
                .appendingPathComponent("ghpr-command-\(UUID().uuidString)", isDirectory: true)
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
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try process.run()
            process.waitUntilExit()
            try stdoutHandle.synchronize()
            try stderrHandle.synchronize()

            let maximumCaptureBytes = 2 * 1_024 * 1_024
            func capturedString(at url: URL) throws -> String {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= maximumCaptureBytes else {
                    throw GitHubSubjectResolverError.commandOutputTooLarge
                }
                return String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return try ExtensionCommandResult(
                exitCode: process.terminationStatus,
                stdout: capturedString(at: stdoutURL),
                stderr: capturedString(at: stderrURL)
            )
        }.value
    }
}

enum GitHubSubjectResolverError: LocalizedError, Equatable {
    case missingExecutable(String)
    case commandFailed(String)
    case malformedResponse
    case commandOutputTooLarge
    case commandTimedOut
    case revisionMismatch

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name):
            return "Required executable '\(name)' is unavailable."
        case .commandFailed(let message):
            return message
        case .malformedResponse:
            return "GitHub returned an invalid pull request revision."
        case .commandOutputTooLarge:
            return "A local command returned more output than ghpr can safely capture."
        case .commandTimedOut:
            return "A local review command timed out."
        case .revisionMismatch:
            return "The prepared checkout does not match the requested pull request revision."
        }
    }
}

private actor GitHubSubjectCache {
    private struct Entry {
        let subject: GitHubSubject
        let expiresAt: Date
    }
    private var entries: [String: Entry] = [:]

    func value(for key: String, now: Date = Date()) -> GitHubSubject? {
        guard let entry = entries[key], entry.expiresAt > now else {
            entries[key] = nil
            return nil
        }
        return entry.subject
    }

    func insert(_ subject: GitHubSubject, for key: String, now: Date = Date()) {
        entries[key] = Entry(subject: subject, expiresAt: now.addingTimeInterval(30))
    }
}

struct GitHubSubjectResolver: Sendable {
    private struct PullResponse: Decodable {
        let baseRefOid: String
        let headRefOid: String
    }

    private struct WorkflowJobResponse: Decodable {
        let id: Int64
        let runID: Int64?
        let runAttempt: Int?
        let headSHA: String?
        let runURL: String?

        enum CodingKeys: String, CodingKey {
            case id
            case runID = "run_id"
            case runAttempt = "run_attempt"
            case headSHA = "head_sha"
            case runURL = "run_url"
        }
    }

    private struct WorkflowRunResponse: Decodable {
        let id: Int64
        let runAttempt: Int
        let headSHA: String

        enum CodingKeys: String, CodingKey {
            case id
            case runAttempt = "run_attempt"
            case headSHA = "head_sha"
        }
    }

    private let ghURL: URL?
    private let runner: ExtensionCommandRunner
    private let cache: GitHubSubjectCache

    init(
        ghURL: URL? = GitHubSubjectResolver.executable(named: "gh"),
        runner: @escaping ExtensionCommandRunner = { executable, arguments, directory in
            try await ExtensionCommand.run(
                executable: executable,
                arguments: arguments,
                currentDirectoryURL: directory
            )
        }
    ) {
        self.ghURL = ghURL
        self.runner = runner
        self.cache = GitHubSubjectCache()
    }

    func resolvePullRequestRevision(
        repository: String,
        prNumber: Int
    ) async throws -> PullRequestRevisionSubject {
        guard let ghURL else {
            throw GitHubSubjectResolverError.missingExecutable("gh")
        }
        let normalizedRepository = repository.lowercased()
        let cacheKey = "pr:\(normalizedRepository)#\(prNumber)"
        if let cached = await cache.value(for: cacheKey),
           case .pullRequestRevision(let revision) = cached {
            return revision
        }
        let result = try await runner(
            ghURL,
            [
                "pr", "view", "\(prNumber)",
                "--repo", normalizedRepository,
                "--json", "baseRefOid,headRefOid"
            ],
            nil
        )
        guard result.succeeded else {
            throw GitHubSubjectResolverError.commandFailed(
                Self.boundedDiagnostic(
                    result.stderr,
                    fallback: "Unable to resolve the pull request revision with gh."
                )
            )
        }
        guard let data = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(PullResponse.self, from: data) else {
            throw GitHubSubjectResolverError.malformedResponse
        }
        let revision = try PullRequestRevisionSubject(
            repository: normalizedRepository,
            prNumber: prNumber,
            baseSHA: response.baseRefOid,
            headSHA: response.headRefOid
        )
        await cache.insert(.pullRequestRevision(revision), for: cacheKey)
        return revision
    }

    func resolveWorkflowJob(
        repository: String,
        workflowRunID expectedRunID: Int64? = nil,
        workflowJobID: Int64
    ) async throws -> WorkflowJobSubject {
        guard let ghURL else {
            throw GitHubSubjectResolverError.missingExecutable("gh")
        }
        let normalizedRepository = repository.lowercased()
        let cacheKey = "job:\(normalizedRepository)#\(workflowJobID)"
        if let cached = await cache.value(for: cacheKey),
           case .workflowJob(let job) = cached,
           expectedRunID == nil || expectedRunID == job.workflowRunID {
            return job
        }
        let result = try await runner(
            ghURL,
            ["api", "repos/\(normalizedRepository)/actions/jobs/\(workflowJobID)"],
            nil
        )
        guard result.succeeded else {
            throw GitHubSubjectResolverError.commandFailed(
                Self.boundedDiagnostic(
                    result.stderr,
                    fallback: "Unable to resolve the workflow job with gh."
                )
            )
        }
        guard let data = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(WorkflowJobResponse.self, from: data),
              response.id == workflowJobID,
              let runID = response.runID ?? Self.runID(from: response.runURL),
              expectedRunID == nil || expectedRunID == runID else {
            throw GitHubSubjectResolverError.malformedResponse
        }
        let runAttempt: Int
        let headSHA: String
        if let jobAttempt = response.runAttempt, let jobHeadSHA = response.headSHA {
            runAttempt = jobAttempt
            headSHA = jobHeadSHA
        } else {
            let runResult = try await runner(
                ghURL,
                ["api", "repos/\(normalizedRepository)/actions/runs/\(runID)"],
                nil
            )
            guard runResult.succeeded,
                  let runData = runResult.stdout.data(using: .utf8),
                  let run = try? JSONDecoder().decode(WorkflowRunResponse.self, from: runData),
                  run.id == runID else {
                throw GitHubSubjectResolverError.malformedResponse
            }
            runAttempt = run.runAttempt
            headSHA = run.headSHA
        }
        let job = try WorkflowJobSubject(
            repository: normalizedRepository,
            workflowRunID: runID,
            workflowAttempt: runAttempt,
            workflowJobID: response.id,
            headSHA: headSHA
        )
        await cache.insert(.workflowJob(job), for: cacheKey)
        return job
    }

    private static func runID(from runURL: String?) -> Int64? {
        guard let runURL,
              let component = URL(string: runURL)?.pathComponents.last else {
            return nil
        }
        return Int64(component)
    }

    static func executable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    static func boundedDiagnostic(_ value: String, fallback: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return fallback }
        return String(normalized.prefix(1_000))
    }
}

