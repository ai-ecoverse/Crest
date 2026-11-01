import CryptoKit
import Foundation
import Network

/// One TCP connection to the DevTools port: an HTTP request the gate admits or
/// refuses, which is either answered or becomes a WebSocket.
@MainActor
final class DevToolsConnection {
    // MARK: - Static Variables

    /// The largest request head a client may send.
    private static let maximumHeadBytes = 16 * 1024

    // MARK: - Variables

    private let connection: NWConnection
    private let gate: DevToolsGate
    private let makeClient: @MainActor (@escaping @MainActor (String) -> Void) -> DevToolsClient
    private let answerRoute: @MainActor (DevToolsGate.Route) -> DevToolsValue?
    private let closed: @MainActor (DevToolsConnection) -> Void
    private var head = Data()
    private var socket: DevToolsWebSocket?
    private(set) var client: DevToolsClient?
    private var isClosed = false

    // MARK: - Initializers

    init(
        connection: NWConnection, gate: DevToolsGate,
        makeClient: @escaping @MainActor (@escaping @MainActor (String) -> Void) -> DevToolsClient,
        answerRoute: @escaping @MainActor (DevToolsGate.Route) -> DevToolsValue?,
        closed: @escaping @MainActor (DevToolsConnection) -> Void
    ) {
        self.connection = connection
        self.gate = gate
        self.makeClient = makeClient
        self.answerRoute = answerRoute
        self.closed = closed
    }

    // MARK: - Actions - Lifecycle

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.close() }
            default: break
            }
        }
        connection.start(queue: .main)
        read()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        client?.disconnect()
        client = nil
        connection.cancel()
        closed(self)
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.take(data) }
                if isComplete || error != nil {
                    self.close()
                } else if !self.isClosed {
                    self.read()
                }
            }
        }
    }

    // MARK: - Actions - Input

    private func take(_ data: Data) {
        guard socket == nil else {
            takeFrames(data)
            return
        }
        head.append(data)
        guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
            if head.count > Self.maximumHeadBytes { refuse() }
            return
        }
        let remainder = Data(head[end.upperBound...])
        guard end.lowerBound - head.startIndex <= Self.maximumHeadBytes,
            let request = DevToolsGate.Request(head: String(decoding: head[..<end.lowerBound], as: UTF8.self))
        else {
            refuse()
            return
        }
        guard case .admitted(let route, let origin) = gate.admit(request) else {
            refuse()
            return
        }
        answer(route, origin: origin)
        if !remainder.isEmpty, socket != nil { takeFrames(remainder) }
    }

    private func takeFrames(_ data: Data) {
        guard var current = socket else { return }
        do {
            let messages = try current.receive(data)
            socket = current
            for message in messages {
                switch message {
                case .text(let text): client?.receive(text)
                case .ping(let payload): write(DevToolsWebSocket.pong(payload))
                case .close:
                    write(DevToolsWebSocket.closeFrame)
                    close()
                }
            }
        } catch {
            close()
        }
    }

    // MARK: - Actions - Answers

    private func answer(_ route: DevToolsGate.Route, origin: String?) {
        switch route {
        case .socket(let key):
            let accept = DevToolsWebSocket.acceptance(for: key) { Data(Insecure.SHA1.hash(data: $0)) }
            socket = DevToolsWebSocket()
            write(
                Data(
                    ([
                        "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
                        "Sec-WebSocket-Accept: \(accept)",
                    ] + gate.crossOriginHeaders(for: origin) + ["", ""]).joined(separator: "\r\n").utf8))
            client = makeClient { [weak self] text in self?.write(DevToolsWebSocket.frame(text: text)) }
        case .preflight:
            respond(
                status: "204 No Content", body: nil,
                headers: gate.crossOriginHeaders(for: origin) + [
                    "Access-Control-Allow-Methods: GET", "Access-Control-Max-Age: 600",
                ])
        case .version, .list:
            guard let value = answerRoute(route), let body = try? value.text() else {
                refuse()
                return
            }
            respond(
                status: "200 OK", body: body,
                headers: gate.crossOriginHeaders(for: origin) + ["Content-Type: application/json; charset=UTF-8"])
        }
    }

    private func refuse() {
        respond(status: "403 Forbidden", body: nil, headers: [])
    }

    private func respond(status: String, body: String?, headers: [String]) {
        let bytes = Data((body ?? "").utf8)
        let lines =
            ["HTTP/1.1 \(status)"] + headers + [
                "Content-Length: \(bytes.count)", "Cache-Control: no-store", "Connection: close", "", "",
            ]
        var response = Data(lines.joined(separator: "\r\n").utf8)
        response.append(bytes)
        connection.send(
            content: response,
            completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in self?.close() }
            })
    }

    private func write(_ data: Data) {
        guard !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
