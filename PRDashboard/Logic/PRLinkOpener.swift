import AppKit
import Darwin
import Foundation
import os

private let prLinkLogger = Logger(subsystem: "com.prdashboard", category: "PRLinkOpener")

@MainActor
protocol PRLinkOpening: AnyObject {
    var opensAtCmuxFirst: Bool { get }
    func open(_ url: URL) async
}

@MainActor
final class PRLinkOpener: PRLinkOpening {
    private let configurationProvider: @MainActor () -> Configuration
    private let cmuxRouter: CmuxBrowserRouting
    private let defaultOpener: @MainActor (URL) -> Void
    private let cmuxActivator: @MainActor () -> Void

    init(
        configurationProvider: @escaping @MainActor () -> Configuration,
        cmuxRouter: CmuxBrowserRouting = CmuxBrowserRouter(),
        defaultOpener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        cmuxActivator: @escaping @MainActor () -> Void = {
            _ = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.cmuxterm.app" }?
                .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    ) {
        self.configurationProvider = configurationProvider
        self.cmuxRouter = cmuxRouter
        self.defaultOpener = defaultOpener
        self.cmuxActivator = cmuxActivator
    }

    var opensAtCmuxFirst: Bool {
        configurationProvider().openAtCmuxFirst
    }

    func open(_ url: URL) async {
        guard opensAtCmuxFirst else {
            defaultOpener(url)
            return
        }

        let router = cmuxRouter
        let handledByCmux = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: router.openExistingPR(url))
            }
        }

        if !handledByCmux {
            defaultOpener(url)
        } else {
            cmuxActivator()
        }
    }
}

protocol CmuxBrowserRouting: Sendable {
    func openExistingPR(_ url: URL) -> Bool
}

protocol CmuxPRStatusProviding: Sendable {
    func openPRIdentities() -> Set<GitHubPRIdentity>
}

struct GitHubPRIdentity: Equatable, Hashable {
    let host: String
    let owner: String
    let repo: String
    let number: Int

    init?(url: URL) {
        guard let rawHost = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 4,
              pathComponents[2].lowercased() == "pull",
              let number = Int(pathComponents[3]) else {
            return nil
        }

        let normalizedHost = rawHost.lowercased() == "www.github.com" ? "github.com" : rawHost.lowercased()
        self.host = normalizedHost
        self.owner = pathComponents[0].lowercased()
        self.repo = pathComponents[1].lowercased()
        self.number = number
    }
}

struct CmuxCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool {
        exitCode == 0 && !timedOut
    }
}

protocol CmuxCommandRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) -> CmuxCommandResult
}

final class CmuxBrowserRouter: CmuxBrowserRouting, CmuxPRStatusProviding {
    private struct Tree: Decodable {
        let windows: [Window]
    }

    private struct Window: Decodable {
        let id: String?
        let ref: String?
        let workspaces: [Workspace]
    }

    private struct Workspace: Decodable {
        let id: String?
        let ref: String?
        let panes: [Pane]
    }

    private struct Pane: Decodable {
        let surfaces: [Surface]
    }

    private struct Surface: Decodable {
        let id: String?
        let ref: String?
        let type: String?
        let url: String?
    }

    private static let browserSurfaceType = "browser"

    struct BrowserMatch: Equatable {
        let windowHandle: String?
        let workspaceHandle: String
        let surfaceHandle: String
    }

    private let commandRunnerProvider: @Sendable () -> CmuxCommandRunning?
    private let timeout: TimeInterval

    init(
        commandRunnerProvider: @escaping @Sendable () -> CmuxCommandRunning? = { ProcessCmuxCommandRunner.makeDefault() },
        timeout: TimeInterval = 2
    ) {
        self.commandRunnerProvider = commandRunnerProvider
        self.timeout = timeout
    }

    convenience init(commandRunner: CmuxCommandRunning?, timeout: TimeInterval = 2) {
        self.init(commandRunnerProvider: { commandRunner }, timeout: timeout)
    }

    func openExistingPR(_ url: URL) -> Bool {
        guard let target = GitHubPRIdentity(url: url) else {
            prLinkLogger.debug("URL is not a GitHub PR URL: \(url.absoluteString, privacy: .public)")
            return false
        }
        guard let commandRunner = commandRunnerProvider() else {
            prLinkLogger.debug("cmux CLI is unavailable; falling back to default browser")
            return false
        }

        guard let treeJSON = fetchTreeJSON(commandRunner: commandRunner),
              let match = Self.findMatchingSurface(in: treeJSON, target: target) else {
            prLinkLogger.debug("No matching cmux browser tab found for \(url.absoluteString, privacy: .public)")
            return false
        }

        if let windowHandle = match.windowHandle {
            let focusWindow = commandRunner.run(
                arguments: ["focus-window", "--window", windowHandle],
                timeout: timeout
            )
            guard focusWindow.succeeded else {
                prLinkLogger.debug("cmux focus-window failed: exit=\(focusWindow.exitCode) stderr=\(focusWindow.stderr, privacy: .public)")
                return false
            }
        }

        let select = commandRunner.run(
            arguments: ["select-workspace", "--workspace", match.workspaceHandle],
            timeout: timeout
        )
        guard select.succeeded else {
            prLinkLogger.debug("cmux select-workspace failed: exit=\(select.exitCode) stderr=\(select.stderr, privacy: .public)")
            return false
        }

        let focusPanel = commandRunner.run(
            arguments: [
                "focus-panel",
                "--workspace", match.workspaceHandle,
                "--panel", match.surfaceHandle
            ],
            timeout: timeout
        )
        guard focusPanel.succeeded else {
            prLinkLogger.debug("cmux focus-panel failed: exit=\(focusPanel.exitCode) stderr=\(focusPanel.stderr, privacy: .public)")
            return false
        }

        return true
    }

    func openPRIdentities() -> Set<GitHubPRIdentity> {
        guard let commandRunner = commandRunnerProvider() else {
            prLinkLogger.debug("cmux CLI is unavailable")
            return []
        }
        guard let treeJSON = fetchTreeJSON(commandRunner: commandRunner) else { return [] }
        return Self.findOpenPRIdentities(in: treeJSON)
    }

    private func fetchTreeJSON(commandRunner: CmuxCommandRunning) -> String? {
        // Use UUIDs everywhere — `focus-window` rejects short refs (`window:1`)
        // and indexes despite its --help claiming otherwise.
        let tree = commandRunner.run(
            arguments: ["--json", "--id-format", "uuids", "tree", "--all"],
            timeout: timeout
        )
        guard tree.succeeded else {
            prLinkLogger.debug("cmux tree failed: exit=\(tree.exitCode) timeout=\(tree.timedOut) stderr=\(tree.stderr, privacy: .public)")
            return nil
        }

        return tree.stdout
    }

    static func findMatchingSurface(in json: String, target: GitHubPRIdentity) -> BrowserMatch? {
        guard let data = json.data(using: .utf8),
              let tree = try? JSONDecoder().decode(Tree.self, from: data) else {
            return nil
        }

        for window in tree.windows {
            for workspace in window.workspaces {
                guard let workspaceHandle = workspace.id ?? workspace.ref else {
                    continue
                }

                for pane in workspace.panes {
                    for surface in pane.surfaces {
                        guard surface.type?.lowercased() == Self.browserSurfaceType,
                              let surfaceHandle = surface.id ?? surface.ref,
                              let urlString = surface.url,
                              let surfaceURL = URL(string: urlString),
                              GitHubPRIdentity(url: surfaceURL) == target else {
                            continue
                        }

                        return BrowserMatch(
                            windowHandle: window.id ?? window.ref,
                            workspaceHandle: workspaceHandle,
                            surfaceHandle: surfaceHandle
                        )
                    }
                }
            }
        }

        return nil
    }

    static func findOpenPRIdentities(in json: String) -> Set<GitHubPRIdentity> {
        guard let data = json.data(using: .utf8),
              let tree = try? JSONDecoder().decode(Tree.self, from: data) else {
            return []
        }

        var identities = Set<GitHubPRIdentity>()
        for window in tree.windows {
            for workspace in window.workspaces {
                for pane in workspace.panes {
                    for surface in pane.surfaces {
                        guard surface.type?.lowercased() == Self.browserSurfaceType,
                              let urlString = surface.url,
                              let surfaceURL = URL(string: urlString),
                              let identity = GitHubPRIdentity(url: surfaceURL) else {
                            continue
                        }
                        identities.insert(identity)
                    }
                }
            }
        }
        return identities
    }
}

private enum CmuxExecutableResolver {
    static func resolve(fileManager: FileManager = .default) -> URL? {
        // Prefer the CLI bundled with the *running* cmux process. cmux's
        // socketControlMode=cmuxOnly validates the connecting binary's code
        // signing identifier against the server's, so a CLI from a different
        // build (e.g. /Applications vs ~/Applications) is rejected with
        // "Failed to write to socket".
        let runningCmuxApps = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.cmuxterm.app" }
        for app in runningCmuxApps {
            guard let bundleURL = app.bundleURL else { continue }
            let cliURL = bundleURL.appendingPathComponent("Contents/Resources/bin/cmux")
            if fileManager.isExecutableFile(atPath: cliURL.path) {
                return cliURL
            }
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cmuxterm.app") {
            let cliURL = appURL.appendingPathComponent("Contents/Resources/bin/cmux")
            if fileManager.isExecutableFile(atPath: cliURL.path) {
                return cliURL
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Applications/cmux.app/Contents/Resources/bin/cmux",
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "/opt/homebrew/bin/cmux",
            "/usr/local/bin/cmux",
            "\(home)/.local/bin/cmux",
            "\(home)/.bin/cmux"
        ]

        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func resolveSocketPath(fileManager: FileManager = .default) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let canonical = "\(home)/Library/Application Support/cmux/cmux.sock"
        if fileManager.fileExists(atPath: canonical) {
            return canonical
        }
        return nil
    }
}

private final class DrainedOutput: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
}

final class ProcessCmuxCommandRunner: CmuxCommandRunning {
    private static let processTerminationGracePeriod: TimeInterval = 0.5
    private static let outputDrainGracePeriod: TimeInterval = 0.25
    private static let pipeCloseGracePeriod: TimeInterval = 0.1

    private let executableURL: URL
    private let socketPath: String?

    init(executableURL: URL, socketPath: String?) {
        self.executableURL = executableURL
        self.socketPath = socketPath
    }

    static func makeDefault() -> ProcessCmuxCommandRunner? {
        guard let executableURL = CmuxExecutableResolver.resolve() else {
            return nil
        }
        return ProcessCmuxCommandRunner(
            executableURL: executableURL,
            socketPath: CmuxExecutableResolver.resolveSocketPath()
        )
    }

    func run(arguments: [String], timeout: TimeInterval) -> CmuxCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        // GUI apps inherit CMUX_SOCKET_PATH from the shell that launched them;
        // when cmux later restarts on a different socket, that inherited value
        // points at a dead socket and `tree` hangs until SIGTERM. Always pin
        // to the canonical production socket when we can locate it.
        var env = ProcessInfo.processInfo.environment
        if let socketPath {
            env["CMUX_SOCKET_PATH"] = socketPath
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain pipes concurrently — Foundation's pipe buffer is ~64 KB on
        // macOS, so a `tree --all` response (~70 KB) blocks the child on
        // write() unless we read while it runs.
        let drained = DrainedOutput()
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue.global(qos: .utility)

        drainGroup.enter()
        drainQueue.async {
            drained.stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        drainQueue.async {
            drained.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        func closePipeEnds() {
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
        }

        func collectOutput() -> (stdout: String, stderr: String) {
            guard drainGroup.wait(
                timeout: .now() + Self.outputDrainGracePeriod
            ) == .success else {
                closePipeEnds()
                _ = drainGroup.wait(timeout: .now() + Self.pipeCloseGracePeriod)
                prLinkLogger.warning("cmux command output drain timed out; returning without captured output")
                return ("", "")
            }

            return (
                String(data: drained.stdout, encoding: .utf8) ?? "",
                String(data: drained.stderr, encoding: .utf8) ?? ""
            )
        }

        do {
            try process.run()
        } catch {
            closePipeEnds()
            _ = drainGroup.wait(timeout: .now() + Self.pipeCloseGracePeriod)
            return CmuxCommandResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }

        let exitGroup = DispatchGroup()
        exitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exitGroup.leave()
        }

        let requestTimeout = max(timeout, 0)
        var processDidExit = exitGroup.wait(
            timeout: .now() + requestTimeout
        ) == .success
        let timedOut = !processDidExit

        if timedOut {
            if process.isRunning {
                process.terminate()
            }
            processDidExit = exitGroup.wait(
                timeout: .now() + Self.processTerminationGracePeriod
            ) == .success

            if !processDidExit {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                processDidExit = exitGroup.wait(
                    timeout: .now() + Self.processTerminationGracePeriod
                ) == .success
            }

            if !processDidExit {
                prLinkLogger.warning("cmux command did not exit after bounded termination")
            }
        }

        let output = collectOutput()
        return CmuxCommandResult(
            exitCode: processDidExit ? process.terminationStatus : -1,
            stdout: output.stdout,
            stderr: output.stderr,
            timedOut: timedOut
        )
    }
}
