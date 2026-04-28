import Darwin
import Foundation

private func writeLine(_ line: String, to handle: FileHandle) {
    handle.write(Data((line + "\n").utf8))
}

let exitCode = GHPRCLI.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    stdout: { writeLine($0, to: .standardOutput) },
    stderr: { writeLine($0, to: .standardError) }
)

exit(exitCode)
