import Combine
import Foundation
import Network
import os

private let browserBridgeLogger = Logger(
    subsystem: "com.prdashboard",
    category: "BrowserBridgeServer"
)

@MainActor
final class BrowserBridgeServer: ObservableObject {
    static let discoveryPorts: [UInt16] = Array(48120...48129)

    @Published private(set) var status = BrowserBridgeStatus(state: .stopped)

    private let router: BrowserBridgeRouter
    private let ports: [UInt16]
    private let queue = DispatchQueue(label: "com.prdashboard.browser-bridge", qos: .userInitiated)
    private var listener: NWListener?
    private var portIndex = 0
    private var generation: UInt64 = 0
    private var activeConnections: [UUID: BrowserHTTPConnection] = [:]

    init(
        router: BrowserBridgeRouter,
        ports: [UInt16] = Array(48120...48129)
    ) {
        self.router = router
        self.ports = ports.isEmpty ? Self.discoveryPorts : ports
    }

    var baseURL: URL? {
        guard case .running(let port) = status.state else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    func start() {
        guard listener == nil else { return }
        generation &+= 1
        portIndex = 0
        status = BrowserBridgeStatus(state: .starting)
        startNextPort(generation: generation)
    }

    func stop() {
        generation &+= 1
        listener?.cancel()
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
        listener = nil
        status = BrowserBridgeStatus(state: .stopped)
    }

    private func startNextPort(generation expectedGeneration: UInt64) {
        guard expectedGeneration == generation else { return }
        guard portIndex < ports.count else {
            status = BrowserBridgeStatus(
                state: .failed("No available port in 48120–48129.")
            )
            return
        }
        let requestedPort = ports[portIndex]
        portIndex += 1

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = false
            let port = requestedPort == 0
                ? NWEndpoint.Port.any
                : NWEndpoint.Port(rawValue: requestedPort)!
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: port
            )
            let candidate = try NWListener(using: parameters)
            listener = candidate
            candidate.newConnectionHandler = { [weak self] connection in
                guard Self.isLoopback(connection.endpoint) else {
                    connection.cancel()
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, let baseURL = self.baseURL else {
                        connection.cancel()
                        return
                    }
                    let id = UUID()
                    let handler = BrowserHTTPConnection(
                        connection: connection,
                        router: self.router,
                        baseURL: baseURL,
                        queue: self.queue
                    ) { [weak self] in
                        Task { @MainActor in
                            self?.activeConnections.removeValue(forKey: id)
                        }
                    }
                    self.activeConnections[id] = handler
                    handler.start()
                }
            }
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                Task { @MainActor in
                    guard let self,
                          expectedGeneration == self.generation,
                          self.listener === candidate else {
                        return
                    }
                    switch state {
                    case .ready:
                        guard let actualPort = candidate?.port?.rawValue else {
                            self.status = BrowserBridgeStatus(
                                state: .failed("Browser Bridge did not publish its port.")
                            )
                            return
                        }
                        self.status = BrowserBridgeStatus(state: .running(port: actualPort))
                        browserBridgeLogger.info("Browser Bridge listening on 127.0.0.1:\(actualPort)")
                    case .failed(let error):
                        browserBridgeLogger.info(
                            "Browser Bridge port \(requestedPort) unavailable: \(error.localizedDescription)"
                        )
                        candidate?.cancel()
                        self.listener = nil
                        self.startNextPort(generation: expectedGeneration)
                    case .cancelled:
                        if case .starting = self.status.state {
                            self.listener = nil
                            self.startNextPort(generation: expectedGeneration)
                        }
                    default:
                        break
                    }
                }
            }
            candidate.start(queue: queue)
        } catch {
            listener = nil
            startNextPort(generation: expectedGeneration)
        }
    }

    private nonisolated static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address == .loopback
        case .ipv6(let address):
            return address == .loopback
        case .name(let name, _):
            return name == "localhost" || name == "127.0.0.1" || name == "::1"
        @unknown default:
            return false
        }
    }
}

private final class BrowserHTTPConnection: @unchecked Sendable {
    private static let maximumRequestBytes = 1024 * 1024

    private let connection: NWConnection
    private let router: BrowserBridgeRouter
    private let baseURL: URL
    private let queue: DispatchQueue
    private var buffer = Data()
    private var completed = false
    private var released = false
    private let completion: @Sendable () -> Void

    init(
        connection: NWConnection,
        router: BrowserBridgeRouter,
        baseURL: URL,
        queue: DispatchQueue,
        completion: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.router = router
        self.baseURL = baseURL
        self.queue = queue
        self.completion = completion
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.completed = true
                self.release()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.completed else { return }
            self.send(
                BrowserHTTPResponse.text(
                    #"{"ok":false,"error":{"code":"request_timeout","message":"Request timed out."}}"#,
                    status: 408,
                    contentType: "application/json; charset=utf-8"
                )
            )
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.completed = true
            self.release()
        }
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self, !self.completed else { return }
            if let data {
                self.buffer.append(data)
            }
            if self.buffer.count > Self.maximumRequestBytes {
                self.send(
                    BrowserHTTPResponse.text(
                        #"{"ok":false,"error":{"code":"request_too_large","message":"Request is too large."}}"#,
                        status: 413,
                        contentType: "application/json; charset=utf-8"
                    )
                )
                return
            }
            do {
                if let request = try self.parseRequestIfComplete() {
                    Task { @MainActor in
                        let response = await self.router.response(
                            for: request,
                            baseURL: self.baseURL
                        )
                        self.queue.async {
                            self.send(response)
                        }
                    }
                    return
                }
            } catch {
                self.send(
                    BrowserHTTPResponse.text(
                        #"{"ok":false,"error":{"code":"malformed_http","message":"Malformed HTTP request."}}"#,
                        status: 400,
                        contentType: "application/json; charset=utf-8"
                    )
                )
                return
            }
            if error != nil || isComplete {
                self.completed = true
                self.release()
                return
            }
            self.receive()
        }
    }

    private func parseRequestIfComplete() throws -> BrowserHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else {
            return nil
        }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.invalidEncoding
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPParseError.invalidRequestLine
        }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0",
              requestParts[1].hasPrefix("/") else {
            throw HTTPParseError.invalidRequestLine
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPParseError.invalidHeader
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, headers[name] == nil else {
                throw HTTPParseError.invalidHeader
            }
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0, contentLength <= Self.maximumRequestBytes else {
            throw HTTPParseError.invalidContentLength
        }
        let bodyStart = headerRange.upperBound
        let requiredCount = bodyStart + contentLength
        guard buffer.count >= requiredCount else {
            return nil
        }
        let body = buffer[bodyStart..<requiredCount]
        return BrowserHTTPRequest(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            headers: headers,
            body: Data(body)
        )
    }

    private func send(_ response: BrowserHTTPResponse) {
        guard !completed else { return }
        completed = true
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Server"] = "ghpr-browser-bridge"
        let reason = Self.reasonPhrase(for: response.status)
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.release()
        })
    }

    private func release() {
        guard !released else { return }
        released = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion()
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 500: return "Internal Server Error"
        default: return "Response"
        }
    }

    private enum HTTPParseError: Error {
        case invalidEncoding
        case invalidRequestLine
        case invalidHeader
        case invalidContentLength
    }
}
