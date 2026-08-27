import Foundation

enum GHPRCLICommand: String, CaseIterable {
    case ping
    case status
    case prs
    case pr
    case snapshot
}

enum GHPRCLISection: String, CaseIterable, Codable {
    case authored
    case review
    case mentioned
    case directMentions = "direct-mentions"
    case merged
    case all
}

struct GHPRCLIOptions: Equatable {
    let command: GHPRCLICommand
    let json: Bool
    let socketPath: String
    let section: GHPRCLISection
    let limit: Int?
    let repository: String?
    let number: Int?
}

enum GHPRCLIParseError: LocalizedError, Equatable {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        }
    }
}

enum GHPRCLIExitCode: Int32 {
    case success = 0
    case usage = 1
    case unavailable = 2
    case protocolError = 3
}

struct GHPRPRsOutput: Codable, Equatable {
    let section: GHPRCLISection
    let pullRequests: [LocalPRSnapshot]
}

private struct GHPRContractExportOutput: Codable, Equatable {
    let skillVersion: String
    let presentationVersion: String
    let browserVersion: String
    let bridgeProtocol: String
    let targets: [SkillTarget]
    let permissions: [BrowserScope]
    let presentationSections: [PresentationSectionType]
    let browserSlots: [BrowserSlot]
    let agents: [SkillAgent]
    let safeDefaults: [String: String]
}

private struct GHPRSkillCommandOutput: Codable, Equatable {
    let operation: String
    let path: String
    let validation: SkillPackageValidation?
    let presentation: String?
    let browserContributions: String?
}

private struct GHPRExtensionArguments {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
}

enum GHPRCLI {
    static let usage = """
    Usage: ghpr [command] [options]

    Commands:
      ping        Check whether PRDashboard is running
      status      Show app health, auth, counts, and rate limit (default)
      prs         Show pull requests from the app snapshot
      pr          Show one pull request by repo and number
      snapshot    Print the current app snapshot
      contract    Inspect or export Extension Platform contracts
      skill       Scaffold, validate, test, preview, install, or pack a Skill
    Options:
      --json                      Print JSON
      --socket PATH               Use a custom Unix socket path
      --section authored|review|mentioned|direct-mentions|merged|all
      --limit N                   Limit PR rows
      --repo OWNER/NAME           Repository for `pr` command
      --number N                  PR number for `pr` command
      -h, --help                  Show this help
    """

    static func parse(
        arguments: [String],
        environment: [String: String]
    ) throws -> GHPRCLIOptions {
        var command: GHPRCLICommand?
        var json = false
        var socketPath: String?
        var section: GHPRCLISection = .all
        var limit: Int?
        var repository: String?
        var number: Int?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            if argument == "--json" {
                json = true
            } else if argument == "--socket" {
                index += 1
                guard index < arguments.count else {
                    throw GHPRCLIParseError.usage("--socket requires a path.")
                }
                socketPath = arguments[index]
            } else if argument.hasPrefix("--socket=") {
                socketPath = String(argument.dropFirst("--socket=".count))
            } else if argument == "--section" {
                index += 1
                guard index < arguments.count else {
                    throw GHPRCLIParseError.usage("--section requires a value.")
                }
                section = try parseSection(arguments[index])
            } else if argument.hasPrefix("--section=") {
                section = try parseSection(String(argument.dropFirst("--section=".count)))
            } else if argument == "--limit" {
                index += 1
                guard index < arguments.count else {
                    throw GHPRCLIParseError.usage("--limit requires a value.")
                }
                limit = try parseLimit(arguments[index])
            } else if argument.hasPrefix("--limit=") {
                limit = try parseLimit(String(argument.dropFirst("--limit=".count)))
            } else if argument == "--repo" {
                index += 1
                guard index < arguments.count else {
                    throw GHPRCLIParseError.usage("--repo requires a value.")
                }
                repository = arguments[index]
            } else if argument.hasPrefix("--repo=") {
                repository = String(argument.dropFirst("--repo=".count))
            } else if argument == "--number" {
                index += 1
                guard index < arguments.count else {
                    throw GHPRCLIParseError.usage("--number requires a value.")
                }
                number = try parseNumber(arguments[index])
            } else if argument.hasPrefix("--number=") {
                number = try parseNumber(String(argument.dropFirst("--number=".count)))
            } else if argument == "-h" || argument == "--help" {
                throw GHPRCLIParseError.usage(usage)
            } else if argument.hasPrefix("-") {
                throw GHPRCLIParseError.usage("Unknown option: \(argument)")
            } else if command == nil, let parsedCommand = GHPRCLICommand(rawValue: argument) {
                command = parsedCommand
            } else if command == nil {
                throw GHPRCLIParseError.usage("Unknown command: \(argument)")
            } else {
                throw GHPRCLIParseError.usage("Unexpected argument: \(argument)")
            }

            index += 1
        }

        return GHPRCLIOptions(
            command: command ?? .status,
            json: json,
            socketPath: socketPath ?? LocalSocketPath.resolvedPath(environment: environment),
            section: section,
            limit: limit,
            repository: repository,
            number: number
        )
    }

    static func run(
        arguments: [String],
        environment: [String: String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        if arguments.first == "contract" {
            return runContractCommand(
                arguments: Array(arguments.dropFirst()),
                stdout: stdout,
                stderr: stderr
            )
        }
        if arguments.first == "skill" {
            return runSkillCommand(
                arguments: Array(arguments.dropFirst()),
                stdout: stdout,
                stderr: stderr
            )
        }

        if arguments.contains("-h") || arguments.contains("--help") {
            stdout(usage)
            return GHPRCLIExitCode.success.rawValue
        }

        let options: GHPRCLIOptions
        do {
            options = try parse(arguments: arguments, environment: environment)
        } catch let error as GHPRCLIParseError {
            stderr("\(error.localizedDescription)\n\n\(usage)")
            return GHPRCLIExitCode.usage.rawValue
        } catch {
            stderr(error.localizedDescription)
            return GHPRCLIExitCode.usage.rawValue
        }

        let request: LocalAPIRequest
        switch options.command {
        case .ping:
            request = LocalAPIRequest(command: .ping)
        case .pr:
            guard let repository = options.repository?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !repository.isEmpty,
                  let number = options.number else {
                stderr("`pr` requires --repo OWNER/NAME and --number N.\n\n\(usage)")
                return GHPRCLIExitCode.usage.rawValue
            }
            request = LocalAPIRequest(
                command: .pr,
                repository: repository,
                number: number
            )
        case .status, .prs, .snapshot:
            request = LocalAPIRequest(command: .snapshot)
        }

        let response: LocalAPIResponse
        do {
            response = try LocalSocketClient(socketPath: options.socketPath).send(request)
        } catch let error as LocalSocketClientError {
            stderr(error.localizedDescription)
            switch error {
            case .unavailable:
                return GHPRCLIExitCode.unavailable.rawValue
            case .writeFailed, .readFailed, .emptyResponse, .invalidResponse:
                return GHPRCLIExitCode.protocolError.rawValue
            }
        } catch {
            stderr(error.localizedDescription)
            return GHPRCLIExitCode.protocolError.rawValue
        }

        guard response.ok else {
            stderr(response.error?.message ?? "Local API request failed.")
            return GHPRCLIExitCode.protocolError.rawValue
        }

        do {
            switch options.command {
            case .ping:
                if options.json {
                    stdout(try renderJSON(response))
                } else {
                    stdout("PRDashboard is running.")
                }
            case .status:
                guard let snapshot = response.snapshot else {
                    stderr("Local API response did not include a snapshot.")
                    return GHPRCLIExitCode.protocolError.rawValue
                }
                stdout(options.json ? try renderJSON(snapshot) : renderStatus(snapshot))
            case .prs:
                guard let snapshot = response.snapshot else {
                    stderr("Local API response did not include a snapshot.")
                    return GHPRCLIExitCode.protocolError.rawValue
                }
                if options.json {
                    let output = GHPRPRsOutput(
                        section: options.section,
                        pullRequests: pullRequests(
                            in: snapshot,
                            section: options.section,
                            limit: options.limit
                        )
                    )
                    stdout(try renderJSON(output))
                } else {
                    stdout(
                        renderPRs(
                            snapshot,
                            section: options.section,
                            limit: options.limit
                        )
                    )
                }
            case .snapshot:
                guard let snapshot = response.snapshot else {
                    stderr("Local API response did not include a snapshot.")
                    return GHPRCLIExitCode.protocolError.rawValue
                }
                stdout(options.json ? try renderJSON(snapshot) : renderStatus(snapshot))
            case .pr:
                guard let pullRequest = response.pullRequest else {
                    stderr("Local API response did not include a pull request.")
                    return GHPRCLIExitCode.protocolError.rawValue
                }
                stdout(options.json ? try renderJSON(pullRequest) : renderPR(pullRequest))
            }
        } catch {
            stderr(error.localizedDescription)
            return GHPRCLIExitCode.protocolError.rawValue
        }

        return GHPRCLIExitCode.success.rawValue
    }

    private static let contractUsage = """
    Usage:
      ghpr contract capabilities [--json]
      ghpr contract export [--version latest|v1] [--json]
      ghpr contract examples [--json]
    """

    private static let skillUsage = """
    Usage:
      ghpr skill scaffold --id ID --name NAME [--directory DIR] [--json]
      ghpr skill validate PATH [--json]
      ghpr skill test PATH [--json]
      ghpr skill preview PATH [--json]
      ghpr skill install PATH [--skills-root DIR] [--json]
      ghpr skill pack PATH [--output FILE] [--json]
    """

    private static func runContractCommand(
        arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        do {
            let parsed = try parseExtensionArguments(
                arguments,
                valueOptions: ["--version"]
            )
            if parsed.flags.contains("--help") {
                stdout(contractUsage)
                return GHPRCLIExitCode.success.rawValue
            }
            let operation = parsed.positionals.first ?? "capabilities"
            let json = parsed.flags.contains("--json")
            switch operation {
            case "capabilities":
                if json {
                    stdout(try renderExtensionJSON(ContractCapabilities.current))
                } else {
                    stdout([
                        "Skill contract: \(GHPRContract.skillVersion)",
                        "Presentation contract: \(GHPRContract.presentationVersion)",
                        "Browser contract: \(GHPRContract.browserVersion)",
                        "Browser slots: \(BrowserSlot.allCases.map(\.rawValue).joined(separator: ", "))",
                        "Agents: \(ContractCapabilities.current.supportedAgents.map(\.rawValue).joined(separator: ", "))"
                    ].joined(separator: "\n"))
                }
            case "export":
                let version = parsed.values["--version"] ?? "latest"
                guard version == "latest" || version == "v1" else {
                    throw GHPRCLIParseError.usage("Unsupported contract version: \(version)")
                }
                let export = GHPRContractExportOutput(
                    skillVersion: GHPRContract.skillVersion,
                    presentationVersion: GHPRContract.presentationVersion,
                    browserVersion: GHPRContract.browserVersion,
                    bridgeProtocol: GHPRContract.bridgeProtocol,
                    targets: SkillTarget.allCases,
                    permissions: BrowserScope.allCases,
                    presentationSections: PresentationSectionType.allCases,
                    browserSlots: BrowserSlot.allCases,
                    agents: ContractCapabilities.current.supportedAgents,
                    safeDefaults: [
                        "workspace.checkout": "none",
                        "workspace.cwd": "run_root",
                        "execution.isolation": "strict",
                        "workspace.access": "read_only",
                        "workspace.shell": "denied",
                        "network.access": "denied",
                        "automation.enabled": "false",
                        "tags.auto_apply": "false"
                    ]
                )
                stdout(try renderExtensionJSON(export))
            case "examples":
                let examples = [
                    "ghpr.skill.yaml": contractManifestExample,
                    "browser/contributions.yaml": contractBrowserExample
                ]
                if json {
                    stdout(try renderExtensionJSON(examples))
                } else {
                    stdout(
                        "# ghpr.skill.yaml\n\(contractManifestExample)\n\n" +
                            "# browser/contributions.yaml\n\(contractBrowserExample)"
                    )
                }
            default:
                throw GHPRCLIParseError.usage("Unknown contract command: \(operation)")
            }
            return GHPRCLIExitCode.success.rawValue
        } catch let error as GHPRCLIParseError {
            stderr("\(error.localizedDescription)\n\n\(contractUsage)")
            return GHPRCLIExitCode.usage.rawValue
        } catch {
            stderr(error.localizedDescription)
            return GHPRCLIExitCode.protocolError.rawValue
        }
    }

    private static func runSkillCommand(
        arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        do {
            let parsed = try parseExtensionArguments(
                arguments,
                valueOptions: ["--id", "--name", "--directory", "--output", "--skills-root"]
            )
            if parsed.flags.contains("--help") {
                stdout(skillUsage)
                return GHPRCLIExitCode.success.rawValue
            }
            guard let operation = parsed.positionals.first else {
                throw GHPRCLIParseError.usage("A Skill command is required.")
            }
            let json = parsed.flags.contains("--json")
            let currentDirectory = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            let output: GHPRSkillCommandOutput
            switch operation {
            case "scaffold":
                guard let id = parsed.values["--id"],
                      let name = parsed.values["--name"] else {
                    throw GHPRCLIParseError.usage("scaffold requires --id and --name.")
                }
                let parent = URL(
                    fileURLWithPath: parsed.values["--directory"] ?? currentDirectory.path,
                    isDirectory: true
                )
                let packageURL = try SkillPackageManager.scaffold(
                    at: parent,
                    id: id,
                    displayName: name
                )
                output = GHPRSkillCommandOutput(
                    operation: operation,
                    path: packageURL.path,
                    validation: SkillPackageManager.validate(at: packageURL),
                    presentation: nil,
                    browserContributions: nil
                )
            case "validate", "test", "preview", "install", "pack":
                guard parsed.positionals.count == 2 else {
                    throw GHPRCLIParseError.usage("\(operation) requires one Skill package path.")
                }
                let packageURL = URL(
                    fileURLWithPath: parsed.positionals[1],
                    relativeTo: currentDirectory
                ).standardizedFileURL
                switch operation {
                case "validate":
                    output = GHPRSkillCommandOutput(
                        operation: operation,
                        path: packageURL.path,
                        validation: SkillPackageManager.validate(at: packageURL),
                        presentation: nil,
                        browserContributions: nil
                    )
                case "test":
                    output = GHPRSkillCommandOutput(
                        operation: operation,
                        path: packageURL.path,
                        validation: try SkillPackageManager.testFixture(at: packageURL),
                        presentation: nil,
                        browserContributions: nil
                    )
                case "preview":
                    let package = try SkillPackageManager.load(at: packageURL)
                    let validation = SkillPackageManager.validate(at: packageURL)
                    guard validation.valid else {
                        throw SkillPackageError.invalidManifest(validation.issues)
                    }
                    output = GHPRSkillCommandOutput(
                        operation: operation,
                        path: packageURL.path,
                        validation: validation,
                        presentation: try SkillPackageManager.readTextResource(
                            package.manifest.presentationPath,
                            under: package.rootURL
                        ),
                        browserContributions: try package.manifest.browserContributionsPath.map {
                            try SkillPackageManager.readTextResource(
                                $0,
                                under: package.rootURL
                            )
                        }
                    )
                case "install":
                    let skillsRootURL = parsed.values["--skills-root"].map {
                        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
                    }
                    let installedURL = try SkillPackageManager.install(
                        packageURL: packageURL,
                        skillsRootURL: skillsRootURL ?? SkillPackageManager.defaultInstalledSkillsURL()
                    )
                    output = GHPRSkillCommandOutput(
                        operation: operation,
                        path: installedURL.path,
                        validation: SkillPackageManager.validate(at: installedURL),
                        presentation: nil,
                        browserContributions: nil
                    )
                case "pack":
                    let package = try SkillPackageManager.load(at: packageURL)
                    let destination = URL(
                        fileURLWithPath: parsed.values["--output"] ??
                            currentDirectory
                            .appendingPathComponent(
                                "\(package.manifest.id)-\(package.manifest.version).ghpr-skill.zip"
                            ).path
                    ).standardizedFileURL
                    let packedURL = try SkillPackageManager.pack(
                        packageURL: packageURL,
                        outputURL: destination
                    )
                    output = GHPRSkillCommandOutput(
                        operation: operation,
                        path: packedURL.path,
                        validation: SkillPackageManager.validate(at: packageURL),
                        presentation: nil,
                        browserContributions: nil
                    )
                default:
                    preconditionFailure("Validated Skill command was not handled.")
                }
            default:
                throw GHPRCLIParseError.usage("Unknown Skill command: \(operation)")
            }
            if json {
                stdout(try renderExtensionJSON(output))
            } else {
                var lines = ["\(output.operation.capitalized): \(output.path)"]
                if let validation = output.validation {
                    lines.append(validation.valid ? "Contract: valid" : "Contract: invalid")
                    lines.append(contentsOf: validation.issues.map {
                        "[\($0.severity.rawValue)] \($0.path): \($0.message)"
                    })
                }
                if let presentation = output.presentation {
                    lines.append("\nPresentation\n\(presentation)")
                }
                if let browser = output.browserContributions {
                    lines.append("\nBrowser contributions\n\(browser)")
                }
                stdout(lines.joined(separator: "\n"))
            }
            return output.validation?.valid == false
                ? GHPRCLIExitCode.protocolError.rawValue
                : GHPRCLIExitCode.success.rawValue
        } catch let error as GHPRCLIParseError {
            stderr("\(error.localizedDescription)\n\n\(skillUsage)")
            return GHPRCLIExitCode.usage.rawValue
        } catch {
            stderr(error.localizedDescription)
            return GHPRCLIExitCode.protocolError.rawValue
        }
    }

    private static func parseExtensionArguments(
        _ arguments: [String],
        valueOptions: Set<String>
    ) throws -> GHPRExtensionArguments {
        var parsed = GHPRExtensionArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--json" || argument == "--help" || argument == "-h" {
                parsed.flags.insert(argument == "-h" ? "--help" : argument)
            } else if valueOptions.contains(argument) {
                index += 1
                guard index < arguments.count else {
                    throw GHPRCLIParseError.usage("\(argument) requires a value.")
                }
                parsed.values[argument] = arguments[index]
            } else if let separator = argument.firstIndex(of: "=") {
                let name = String(argument[..<separator])
                guard valueOptions.contains(name) else {
                    throw GHPRCLIParseError.usage("Unknown option: \(name)")
                }
                parsed.values[name] = String(argument[argument.index(after: separator)...])
            } else if argument.hasPrefix("-") {
                throw GHPRCLIParseError.usage("Unknown option: \(argument)")
            } else {
                parsed.positionals.append(argument)
            }
            index += 1
        }
        return parsed
    }

    private static let contractManifestExample = """
    api_version: ghpr.dev/skill/v1
    id: example.ci.check
    version: 1.0.0
    display_name: Example CI Check
    targets:
      - pull_request
      - failed_workflow_run
    execution:
      agents:
        - omp
        - claude_code
      default_agent: omp
      isolation: strict
    workspace:
      checkout: none
      cwd: run_root
      access: read_only
      shell: denied
    network:
      access: denied
    result:
      schema: schemas/result.schema.json
    presentation:
      file: presentation/presentation.yaml
    automation:
      enabled: false
    tags:
      auto_apply: false
    """

    private static let contractBrowserExample = """
    api_version: ghpr.dev/browser/v1
    surfaces:
      - github.pull_request
    contributions:
      - id: example-action
        slot: pr.header.actions
        component:
          type: action
          label: Run Example CI Check
          tone: analysis
        action:
          kind: run_skill
          skill_id: example.ci.check
    """

    static func renderStatus(_ snapshot: LocalSnapshot) -> String {
        let authDescription: String
        if snapshot.auth.isAuthenticated {
            let username = snapshot.auth.username ?? "unknown"
            if let method = snapshot.auth.method {
                authDescription = "\(username) (\(method))"
            } else {
                authDescription = username
            }
        } else {
            authDescription = "not authenticated"
        }

        var refreshDescription = "\(snapshot.refresh.status), updated \(formatDate(snapshot.refresh.lastUpdated))"
        if snapshot.refresh.isLoading {
            refreshDescription += ", loading"
        }
        if let error = snapshot.refresh.error {
            refreshDescription += ", error: \(error)"
        }

        return [
            "PRDashboard: running",
            "Version: \(snapshot.app.version) (\(snapshot.app.build))",
            "Auth: \(authDescription)",
            "Refresh: \(refreshDescription)",
            "Counts: authored \(snapshot.summary.authored), review \(snapshot.summary.reviewRequests), mentioned \(snapshot.summary.mentioned), direct-mentions \(snapshot.summary.directMentions), merged-last-24h \(snapshot.summary.mergedLast24h)",
            "Unresolved: authored \(snapshot.summary.authoredUnresolved), total \(snapshot.summary.totalUnresolved)",
            "CI: ready \(snapshot.summary.readyToMerge), changes-requested \(snapshot.summary.changesRequested), failing \(snapshot.summary.ciFailing), running \(snapshot.summary.ciRunning), waiting-review \(snapshot.summary.waitingForMyReview)",
            "Rate limit: \(snapshot.rateLimit.remaining)/\(snapshot.rateLimit.limit) remaining, resets \(formatDate(snapshot.rateLimit.resetAt))"
        ].joined(separator: "\n")
    }

    static func renderPRs(
        _ snapshot: LocalSnapshot,
        section: GHPRCLISection,
        limit: Int?
    ) -> String {
        let prs = pullRequests(in: snapshot, section: section, limit: limit)
        guard !prs.isEmpty else {
            return "No pull requests."
        }

        let headers = ["Section", "Repo", "PR", "CI", "Unres", "Review", "Title", "URL"]
        let rows = prs.map { pr in
            [
                pr.section.rawValue,
                pr.repository,
                "#\(pr.number)",
                ciDescription(for: pr),
                "\(pr.unresolvedCount)",
                pr.myReviewStatus ?? "-",
                pr.title,
                pr.url
            ]
        }

        return renderTable(headers: headers, rows: rows)
    }

    static func pullRequests(
        in snapshot: LocalSnapshot,
        section: GHPRCLISection,
        limit: Int?
    ) -> [LocalPRSnapshot] {
        let selected: [LocalPRSnapshot]
        switch section {
        case .authored:
            selected = snapshot.pullRequests.authored
        case .review:
            selected = snapshot.pullRequests.reviewRequests
        case .mentioned:
            selected = snapshot.pullRequests.mentioned
        case .directMentions:
            selected = snapshot.pullRequests.directMentions
        case .merged:
            selected = snapshot.pullRequests.mergedLast24h
        case .all:
            selected = snapshot.pullRequests.authored +
                snapshot.pullRequests.reviewRequests +
                snapshot.pullRequests.mentioned +
                snapshot.pullRequests.directMentions +
                snapshot.pullRequests.mergedLast24h
        }

        if let limit {
            return Array(selected.prefix(limit))
        }
        return selected
    }

    static func renderPR(_ pr: LocalPRSnapshot) -> String {
        var lines: [String] = [
            "Repository: \(pr.repository)",
            "Number: #\(pr.number)",
            "Title: \(pr.title)",
            "Author: \(pr.author)",
            "URL: \(pr.url)",
            "Section: \(pr.section.rawValue)",
            "State: \(pr.state)\(pr.isDraft ? " (draft)" : "")",
            "Updated: \(formatDate(pr.updatedAt))"
        ]
        if let mergedAt = pr.mergedAt {
            lines.append("Merged: \(formatDate(mergedAt))")
        }
        lines.append("CI: \(ciDescription(for: pr))")
        let ignoredFailureCount = pr.ciStatus == "SUCCESS" ? pr.checkFailureCount : 0
        let effectiveFailureCount = pr.checkFailureCount - ignoredFailureCount
        let ignoredSuffix = ignoredFailureCount > 0 ? ", ignored \(ignoredFailureCount)" : ""
        lines.append(
            "Checks: success \(pr.checkSuccessCount), failure \(effectiveFailureCount), pending \(pr.checkPendingCount)\(ignoredSuffix)"
        )
        lines.append("Unresolved: \(pr.unresolvedCount)")
        lines.append("Approvals: \(pr.approvalCount)")
        if let changesRequested = pr.changesRequestedCount {
            lines.append("Changes requested: \(changesRequested)")
        }
        if let myReview = pr.myReviewStatus {
            lines.append("My review: \(myReview)")
        }
        if pr.hasBaseConflicts {
            lines.append("Base conflicts: yes")
        }
        if pr.isPinned {
            lines.append("Pinned: yes")
        }
        if let jira = pr.jiraTicket {
            lines.append("Jira: \(jira)")
        }
        return lines.joined(separator: "\n")
    }

    static func renderJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try LocalAPIJSON.encode(value, prettyPrinted: true)
        return String(decoding: data, as: UTF8.self)
    }

    private static func renderExtensionJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func parseSection(_ value: String) throws -> GHPRCLISection {
        guard let section = GHPRCLISection(rawValue: value) else {
            throw GHPRCLIParseError.usage("Unknown section: \(value)")
        }
        return section
    }

    private static func parseLimit(_ value: String) throws -> Int {
        guard let limit = Int(value), limit > 0 else {
            throw GHPRCLIParseError.usage("--limit requires a positive integer.")
        }
        return limit
    }

    private static func parseNumber(_ value: String) throws -> Int {
        guard let number = Int(value), number > 0 else {
            throw GHPRCLIParseError.usage("--number requires a positive integer.")
        }
        return number
    }

    private static func ciDescription(for pr: LocalPRSnapshot) -> String {
        if pr.ciIsRunning {
            return pr.ciStatus.map { "\($0)/running" } ?? "RUNNING"
        }
        return pr.ciStatus ?? "-"
    }

    private static func renderTable(headers: [String], rows: [[String]]) -> String {
        let caps = [10, 32, 8, 16, 7, 16, 60, 80]
        let widths = headers.indices.map { index in
            let rowWidth = rows.map { $0[index].count }.max() ?? 0
            return min(max(headers[index].count, rowWidth), caps[index])
        }

        let header = renderRow(headers, widths: widths)
        let separator = widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-")
        let body = rows.map { renderRow($0, widths: widths) }
        return ([header, separator] + body).joined(separator: "\n")
    }

    private static func renderRow(_ values: [String], widths: [Int]) -> String {
        values.enumerated().map { index, value in
            pad(truncate(value, width: widths[index]), to: widths[index])
        }.joined(separator: " | ")
    }

    private static func truncate(_ value: String, width: Int) -> String {
        guard value.count > width else { return value }
        guard width > 3 else { return String(value.prefix(width)) }
        return "\(value.prefix(width - 3))..."
    }

    private static func pad(_ value: String, to width: Int) -> String {
        guard value.count < width else { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

    private static let iso8601Formatter = ISO8601DateFormatter()

    private static func formatDate(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }
}
