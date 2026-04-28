import Foundation

enum GHPRCLICommand: String, CaseIterable {
    case ping
    case status
    case prs
    case snapshot
}

enum GHPRCLISection: String, CaseIterable, Codable {
    case authored
    case review
    case mentioned
    case merged
    case all
}

struct GHPRCLIOptions: Equatable {
    let command: GHPRCLICommand
    let json: Bool
    let socketPath: String
    let section: GHPRCLISection
    let limit: Int?
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

enum GHPRCLI {
    static let usage = """
    Usage: ghpr [command] [options]

    Commands:
      ping        Check whether PRDashboard is running
      status      Show app health, auth, counts, and rate limit (default)
      prs         Show pull requests from the app snapshot
      snapshot    Print the current app snapshot

    Options:
      --json                      Print JSON
      --socket PATH               Use a custom Unix socket path
      --section authored|review|mentioned|merged|all
      --limit N                   Limit PR rows
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
            limit: limit
        )
    }

    static func run(
        arguments: [String],
        environment: [String: String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
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

        let request = LocalAPIRequest(
            command: options.command == .ping ? .ping : .snapshot
        )

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
            }
        } catch {
            stderr(error.localizedDescription)
            return GHPRCLIExitCode.protocolError.rawValue
        }

        return GHPRCLIExitCode.success.rawValue
    }

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
            "Counts: authored \(snapshot.summary.authored), review \(snapshot.summary.reviewRequests), mentioned \(snapshot.summary.mentioned), merged-last-24h \(snapshot.summary.mergedLast24h)",
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
        case .merged:
            selected = snapshot.pullRequests.mergedLast24h
        case .all:
            selected = snapshot.pullRequests.authored +
                snapshot.pullRequests.reviewRequests +
                snapshot.pullRequests.mentioned +
                snapshot.pullRequests.mergedLast24h
        }

        if let limit {
            return Array(selected.prefix(limit))
        }
        return selected
    }

    static func renderJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try LocalAPIJSON.encode(value, prettyPrinted: true)
        return String(decoding: data, as: UTF8.self)
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
