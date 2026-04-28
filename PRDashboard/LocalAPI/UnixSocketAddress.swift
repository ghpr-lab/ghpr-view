import Darwin
import Foundation

enum UnixSocketAddressError: LocalizedError {
    case pathTooLong(String)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Unix socket path is too long: \(path)"
        }
    }
}

enum UnixSocketAddress {
    static func withAddress<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)

        guard pathBytes.count <= maxPathLength else {
            throw UnixSocketAddressError.pathTooLong(path)
        }

        address.sun_family = sa_family_t(AF_UNIX)
        let addressLength = socklen_t((MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2) + pathBytes.count)
        address.sun_len = UInt8(min(Int(addressLength), MemoryLayout<sockaddr_un>.size))

        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    _ = memset(destination, 0, maxPathLength)
                    _ = memcpy(destination, source, pathBytes.count)
                }
            }
        }

        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                try body(socketAddress, addressLength)
            }
        }
    }
}

enum POSIXErrorFormatter {
    static func message(function: String, errno errorCode: Int32 = Darwin.errno) -> String {
        "\(function) failed: \(String(cString: strerror(errorCode)))"
    }
}
