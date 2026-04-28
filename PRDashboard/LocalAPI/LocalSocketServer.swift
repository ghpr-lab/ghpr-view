import Darwin
import Dispatch
import Foundation
import os

private let localSocketLogger = Logger(subsystem: "com.prdashboard", category: "LocalSocketServer")

enum LocalSocketServerError: LocalizedError {
    case alreadyRunning(String)
    case posix(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning(let path):
            return "Another PRDashboard local socket server is already listening at \(path)."
        case .posix(let message):
            return message
        }
    }
}

final class LocalSocketServer {
    private static let maxRequestBytes = 1024 * 1024

    private let socketPath: String
    private let snapshotProvider: @MainActor () -> LocalSnapshot
    private let queue = DispatchQueue(label: "com.prdashboard.local-socket-server")

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(
        socketPath: String = LocalSocketPath.defaultPath(),
        snapshotProvider: @escaping @MainActor () -> LocalSnapshot
    ) {
        self.socketPath = socketPath
        self.snapshotProvider = snapshotProvider
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    private func startOnQueue() {
        guard listenFD < 0 else { return }

        do {
            try removeStaleSocketIfNeeded()

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw LocalSocketServerError.posix(
                    POSIXErrorFormatter.message(function: "socket")
                )
            }

            do {
                try configureListeningSocket(fd)
                try UnixSocketAddress.withAddress(path: socketPath) { address, length in
                    guard bind(fd, address, length) == 0 else {
                        throw LocalSocketServerError.posix(
                            POSIXErrorFormatter.message(function: "bind")
                        )
                    }
                }

                guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
                    throw LocalSocketServerError.posix(
                        POSIXErrorFormatter.message(function: "chmod")
                    )
                }

                guard listen(fd, SOMAXCONN) == 0 else {
                    throw LocalSocketServerError.posix(
                        POSIXErrorFormatter.message(function: "listen")
                    )
                }

                listenFD = fd
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in
                    self?.acceptPendingConnections()
                }
                source.setCancelHandler {
                    close(fd)
                }
                acceptSource = source
                source.resume()

                localSocketLogger.info("Local CLI socket listening at \(self.socketPath, privacy: .public)")
            } catch {
                close(fd)
                unlink(socketPath)
                throw error
            }
        } catch {
            localSocketLogger.error("Failed to start local CLI socket: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopOnQueue() {
        if let acceptSource {
            acceptSource.cancel()
            self.acceptSource = nil
        } else if listenFD >= 0 {
            close(listenFD)
        }

        listenFD = -1
        unlink(socketPath)
    }

    private func configureListeningSocket(_ fd: Int32) throws {
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LocalSocketServerError.posix(
                POSIXErrorFormatter.message(function: "fcntl")
            )
        }
    }

    private func removeStaleSocketIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        if socketAcceptsConnections(at: socketPath) {
            throw LocalSocketServerError.alreadyRunning(socketPath)
        }

        guard unlink(socketPath) == 0 || errno == ENOENT else {
            throw LocalSocketServerError.posix(
                POSIXErrorFormatter.message(function: "unlink")
            )
        }
    }

    private func socketAcceptsConnections(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        return (try? UnixSocketAddress.withAddress(path: path) { address, length in
            connect(fd, address, length) == 0
        }) ?? false
    }

    private func acceptPendingConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD >= 0 {
                Self.configureAcceptedSocket(clientFD)
                processConnection(clientFD)
            } else if errno == EWOULDBLOCK || errno == EAGAIN {
                return
            } else if errno == EINTR {
                continue
            } else {
                localSocketLogger.error("accept failed: \(String(cString: strerror(errno)), privacy: .public)")
                return
            }
        }
    }

    // accept() on Darwin inherits O_NONBLOCK from the listening socket,
    // but the per-connection handlers below use blocking recv/send.
    private static func configureAcceptedSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
    }

    private func processConnection(_ fd: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { close(fd) }

            guard Self.authorizePeer(fd) else {
                let response = LocalAPIResponse.failure(
                    code: .unauthorizedPeer,
                    message: "Local API peer UID does not match the app UID."
                )
                try? Self.writeResponse(response, to: fd)
                return
            }

            let response: LocalAPIResponse
            do {
                let request = try Self.readRequest(from: fd)
                response = self?.makeResponseSynchronously(for: request) ??
                    .failure(code: .internalError, message: "Local socket server stopped.")
            } catch {
                response = .failure(
                    code: .invalidRequest,
                    message: error.localizedDescription
                )
            }

            do {
                try Self.writeResponse(response, to: fd)
            } catch {
                localSocketLogger.error("Failed to write local CLI response: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func authorizePeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            return false
        }
        return uid == getuid()
    }

    private func makeResponseSynchronously(for request: LocalAPIRequest) -> LocalAPIResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var response: LocalAPIResponse?

        Task { @MainActor in
            response = LocalAPIHandler.response(
                for: request,
                snapshotProvider: snapshotProvider
            )
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success,
              let response else {
            return .failure(
                code: .internalError,
                message: "Timed out while building local app snapshot."
            )
        }

        return response
    }

    private static func readRequest(from fd: Int32) throws -> LocalAPIRequest {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let result = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
            }

            if result > 0 {
                if let newlineIndex = buffer.prefix(result).firstIndex(of: 0x0A) {
                    data.append(contentsOf: buffer.prefix(newlineIndex))
                    break
                }

                if data.count + result > maxRequestBytes {
                    throw LocalSocketClientError.invalidResponse("Local API request is too large.")
                }
                data.append(contentsOf: buffer.prefix(result))
            } else if result == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw LocalSocketClientError.readFailed(
                    POSIXErrorFormatter.message(function: "recv")
                )
            }
        }

        guard !data.isEmpty else {
            throw LocalSocketClientError.invalidResponse("Local API request is empty.")
        }

        return try LocalAPIJSON.decode(LocalAPIRequest.self, from: data)
    }

    private static func writeResponse(_ response: LocalAPIResponse, to fd: Int32) throws {
        var payload = try LocalAPIJSON.encode(response)
        payload.append(0x0A)

        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0

            while bytesWritten < rawBuffer.count {
                let result = send(
                    fd,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten,
                    0
                )

                if result > 0 {
                    bytesWritten += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else {
                    throw LocalSocketClientError.writeFailed(
                        POSIXErrorFormatter.message(function: "send")
                    )
                }
            }
        }
    }
}
