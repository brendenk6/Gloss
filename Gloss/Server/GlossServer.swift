import Foundation
@preconcurrency import Network

@MainActor
public final class GlossServer {
    private var listener: NWListener?
    private weak var store: CanvasStore?
    private let idempotency = ServerIdempotencyCache()

    public let port: UInt16 = 7778
    public private(set) var isRunning = false

    public init() {}

    public func start(store: CanvasStore) {
        self.store = store

        if listener != nil {
            return
        }

        do {
            let parameters = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                NSLog("Gloss: invalid server port %d", port)
                return
            }
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handle(connection)
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        NSLog("Gloss: server ready on http://127.0.0.1:%d", self?.port ?? 7778)
                    case .failed(let error):
                        self?.isRunning = false
                        NSLog("Gloss: server failed: %@", error.localizedDescription)
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener.start(queue: .main)
        } catch {
            NSLog("Gloss: failed to start server: %@", error.localizedDescription)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }

                if error != nil {
                    connection.cancel()
                    return
                }

                var accumulated = buffer
                if let data {
                    accumulated.append(data)
                }

                if accumulated.count > 32_000_000 {
                    self.send(connection, GlossHTTPResponse.error(code: "request_too_large", message: "Request exceeded 32 MB.", status: 413))
                    return
                }

                guard let request = HTTPRequest(data: accumulated) else {
                    if isComplete {
                        self.send(connection, GlossHTTPResponse.error(code: "bad_request", message: "Malformed HTTP request.", status: 400))
                    } else {
                        self.receive(connection, buffer: accumulated)
                    }
                    return
                }

                guard request.isComplete else {
                    self.receive(connection, buffer: accumulated)
                    return
                }

                guard let store = self.store else {
                    self.send(connection, GlossHTTPResponse.error(code: "not_ready", message: "Canvas store is not ready.", status: 503))
                    return
                }

                let response = GlossRoutes.handle(
                    method: request.method,
                    path: request.path,
                    query: request.query,
                    body: request.body,
                    store: store,
                    idempotency: self.idempotency
                )
                self.send(connection, response)
            }
        }
    }

    private func send(_ connection: NWConnection, _ response: GlossHTTPResponse) {
        let statusText = Self.statusText(response.status)
        var headerLines = [
            "HTTP/1.1 \(response.status) \(statusText)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type, Idempotency-Key",
            "Connection: close"
        ]

        for (key, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            headerLines.append("\(key): \(value)")
        }

        let head = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data
    let isComplete: Bool

    init?(data: Data) {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        self.method = parts[0].uppercased()

        let split = Self.splitPathAndQuery(parts[1])
        self.path = split.path
        self.query = split.query

        let headers = Self.headerFields(lines.dropFirst())
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let available = data.count - bodyStart
        self.isComplete = available >= contentLength

        if self.isComplete {
            self.body = data[bodyStart..<(bodyStart + contentLength)]
        } else {
            self.body = Data()
        }
    }

    private static func headerFields(_ lines: ArraySlice<String>) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fields
    }

    private static func splitPathAndQuery(_ target: String) -> (path: String, query: [String: String]) {
        guard let question = target.firstIndex(of: "?") else {
            return (target, [:])
        }

        let path = String(target[..<question])
        let queryString = String(target[target.index(after: question)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            query[key.removingPercentEncoding ?? key] = value.removingPercentEncoding ?? value
        }
        return (path, query)
    }
}
