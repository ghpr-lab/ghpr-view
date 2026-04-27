import Darwin
import Foundation

enum LocalSocketClientError: LocalizedError {
    case unavailable(String)
    case writeFailed(String)
    case readFailed(String)
    case emptyResponse
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .writeFailed(let message):
            return message
        case .readFailed(let message):
            return message
        case .emptyResponse:
            return "The app closed the socket without sending a response."
        case .invalidResponse(let message):
            return message
        }
    }
}

struct LocalSocketClient {
    private static let maxResponseBytes = 4 * 1024 * 1024

    let socketPath: String

    func send(_ request: LocalAPIRequest) throws -> LocalAPIResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalSocketClientError.unavailable(
                POSIXErrorFormatter.message(function: "socket")
            )
        }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )

        do {
            try UnixSocketAddress.withAddress(path: socketPath) { address, length in
                guard connect(fd, address, length) == 0 else {
                    throw LocalSocketClientError.unavailable(
                        "PRDashboard is not accepting local CLI connections at \(socketPath)."
                    )
                }
            }

            var payload = try LocalAPIJSON.encode(request)
            payload.append(0x0A)
            try Self.writeAll(payload, to: fd)
            shutdown(fd, SHUT_WR)

            let responseData = try Self.readAll(from: fd, maxBytes: Self.maxResponseBytes)
            guard !responseData.isEmpty else {
                throw LocalSocketClientError.emptyResponse
            }

            let response = try LocalAPIJSON.decode(LocalAPIResponse.self, from: responseData)
            guard response.schemaVersion == LocalAPIProtocol.schemaVersion else {
                throw LocalSocketClientError.invalidResponse(
                    "Unsupported local API schema version: \(response.schemaVersion)"
                )
            }
            return response
        } catch let error as LocalSocketClientError {
            throw error
        } catch let error as UnixSocketAddressError {
            throw LocalSocketClientError.unavailable(error.localizedDescription)
        } catch {
            throw LocalSocketClientError.invalidResponse(error.localizedDescription)
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0

            while bytesWritten < rawBuffer.count {
                let result = Darwin.send(
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

    private static func readAll(from fd: Int32, maxBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let result = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
            }

            if result > 0 {
                if data.count + result > maxBytes {
                    throw LocalSocketClientError.readFailed("Local API response is too large.")
                }
                data.append(contentsOf: buffer.prefix(result))
            } else if result == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else {
                throw LocalSocketClientError.readFailed(
                    POSIXErrorFormatter.message(function: "recv")
                )
            }
        }
    }
}
