import AppKit
import Darwin
import Foundation
import os

private let prLinkLogger = Logger(subsystem: "com.prdashboard", category: "PRLinkOpener")

@MainActor
final class PRLinkOpener {
    private let configurationProvider: @MainActor () -> Configuration
    private let cmuxRouter: CmuxBrowserRouting

    init(
        configurationProvider: @escaping @MainActor () -> Configuration,
        cmuxRouter: CmuxBrowserRouting = CmuxBrowserRouter()
    ) {
        self.configurationProvider = configurationProvider
        self.cmuxRouter = cmuxRouter
    }

    func open(_ url: URL) {
        guard configurationProvider().openAtCmuxFirst else {
            NSWorkspace.shared.open(url)
            return
        }

        let router = cmuxRouter
        DispatchQueue.global(qos: .userInitiated).async {
            let handledByCmux = router.openExistingPR(url)
            DispatchQueue.main.async {
                if !handledByCmux {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

protocol CmuxBrowserRouting: Sendable {
    func openExistingPR(_ url: URL) -> Bool
}

struct GitHubPRIdentity: Equatable {
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

final class CmuxBrowserRouter: CmuxBrowserRouting {
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

    struct BrowserMatch: Equatable {
        let windowHandle: String?
        let workspaceHandle: String
        let surfaceHandle: String
    }

    private let commandRunner: CmuxCommandRunning?
    private let timeout: TimeInterval

    init(
        commandRunner: CmuxCommandRunning? = ProcessCmuxCommandRunner.makeDefault(),
        timeout: TimeInterval = 2
    ) {
        self.commandRunner = commandRunner
        self.timeout = timeout
    }

    func openExistingPR(_ url: URL) -> Bool {
        guard let commandRunner else {
            prLinkLogger.debug("cmux CLI is unavailable; falling back to default browser")
            return false
        }
        guard let target = GitHubPRIdentity(url: url) else {
            prLinkLogger.debug("URL is not a GitHub PR URL: \(url.absoluteString, privacy: .public)")
            return false
        }

        // Use UUIDs everywhere — `focus-window` rejects short refs (`window:1`)
        // and indexes despite its --help claiming otherwise.
        let tree = commandRunner.run(
            arguments: ["--json", "--id-format", "uuids", "tree", "--all"],
            timeout: timeout
        )
        guard tree.succeeded else {
            prLinkLogger.debug("cmux tree failed: exit=\(tree.exitCode) timeout=\(tree.timedOut) stderr=\(tree.stderr, privacy: .public)")
            return false
        }

        guard let match = Self.findMatchingSurface(in: tree.stdout, target: target) else {
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

        let reload = commandRunner.run(
            arguments: ["browser", "--surface", match.surfaceHandle, "reload"],
            timeout: timeout
        )
        if !reload.succeeded {
            prLinkLogger.debug("cmux browser reload failed after focus: exit=\(reload.exitCode) stderr=\(reload.stderr, privacy: .public)")
        }

        return true
    }

    static func findMatchingSurface(in json: String, target: GitHubPRIdentity) -> BrowserMatch? {
        guard let data = json.data(using: .utf8),
              let tree = try? JSONDecoder().decode(Tree.self, from: data) else {
            return nil
        }

        for window in tree.windows {
            for workspace in window.workspaces {
                guard let workspaceHandle = workspace.ref ?? workspace.id else {
                    continue
                }

                for pane in workspace.panes {
                    for surface in pane.surfaces {
                        guard surface.type?.lowercased() == "browser",
                              let surfaceHandle = surface.ref ?? surface.id,
                              let urlString = surface.url,
                              let surfaceURL = URL(string: urlString),
                              GitHubPRIdentity(url: surfaceURL) == target else {
                            continue
                        }

                        return BrowserMatch(
                            windowHandle: window.ref ?? window.id,
                            workspaceHandle: workspaceHandle,
                            surfaceHandle: surfaceHandle
                        )
                    }
                }
            }
        }

        return nil
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

private final class ProcessCmuxCommandRunner: CmuxCommandRunning {
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

        // GUI apps inherit a minimal environment, so cmux's auto-discovery may
        // attach to a stale/debug socket recorded in last-socket-path. Pin to
        // the production socket explicitly when we can locate it.
        var env = ProcessInfo.processInfo.environment
        if env["CMUX_SOCKET_PATH"] == nil, let socketPath {
            env["CMUX_SOCKET_PATH"] = socketPath
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CmuxCommandResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if group.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                group.wait()
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return CmuxCommandResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
