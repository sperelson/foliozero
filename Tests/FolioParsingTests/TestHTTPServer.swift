import Foundation
import Network
import Synchronization

/// A tiny HTTP/1.0 server on 127.0.0.1 for URL capture tests.
final class TestHTTPServer: Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var contentType: String
        var body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestHTTPServer")
    let port: UInt16

    init(routes: [String: Response]) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            TestHTTPServer.receive(connection, buffer: Data(), routes: routes)
        }
        port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                switch state {
                case .ready where first:
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error) where first:
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func stop() {
        listener.cancel()
    }

    private static func receive(_ connection: NWConnection, buffer: Data, routes: [String: Response]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(connection, request: buffer, routes: routes)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                receive(connection, buffer: buffer, routes: routes)
            }
        }
    }

    private static func respond(_ connection: NWConnection, request: Data, routes: [String: Response]) {
        let line = String(decoding: request.prefix { $0 != 0x0D && $0 != 0x0A }, as: UTF8.self)
        let parts = line.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let response = routes[path] ?? Response(status: 404, contentType: "text/plain", body: Data("not found".utf8))
        var head = "HTTP/1.0 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if parts.first != "HEAD" { payload.append(response.body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
