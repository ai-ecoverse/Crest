import Foundation
import Network
import Security

/// Where a running server answers, which only Crest and the pages it hands the
/// endpoint to know.
struct DevToolsEndpoint: Equatable, Sendable {
    let port: UInt16
    let token: String
    let isSecure: Bool

    /// What a client discovers the browser from.
    var discoveryURL: String { "\(isSecure ? "https" : "http")://127.0.0.1:\(port)/\(token)" }
    /// The browser socket.
    var socketURL: String { "\(isSecure ? "wss" : "ws")://127.0.0.1:\(port)/devtools/browser/\(token)" }
}

/// The port that speaks the Chrome DevTools Protocol, on loopback only, while
/// the person leaves it on. WebKit refuses `http` and `ws` to loopback from an
/// `https` page, so a server for pages in `WKWebView` speaks TLS with a
/// certificate of its own, which only Crest's own pages accept.
@MainActor
final class DevToolsServer {
    // MARK: - Types

    enum Failure: Error, Equatable {
        /// Something else holds every port in `ports`.
        case noFreePort
    }

    // MARK: - Static Variables

    static let protocolVersion = "1.3"
    /// The ports clients probe for a browser.
    static let ports: ClosedRange<UInt16> = 9222...9229
    /// How often a client hears which pages opened, closed or changed.
    private static let refreshInterval: Duration = .seconds(1)

    // MARK: - Variables

    private let browser: any DevToolsBrowsing
    private let allowedOrigins: Set<String>
    private let identity: SecIdentity?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: DevToolsConnection] = [:]
    private var refresh: Task<Void, Never>?
    private(set) var endpoint: DevToolsEndpoint?

    // MARK: - Initializers

    /// A server for `browser`, which pages of `allowedOrigins` may reach. With
    /// `identity` it speaks TLS.
    init(browser: any DevToolsBrowsing, allowedOrigins: Set<String>, identity: SecIdentity?) {
        self.browser = browser
        self.allowedOrigins = allowedOrigins
        self.identity = identity
    }

    // MARK: - Actions - Lifecycle

    /// Opens the first free port, and answers where.
    func start() async throws -> DevToolsEndpoint {
        if let endpoint { return endpoint }
        let token = Self.makeToken()
        for port in Self.ports {
            guard let listener = await open(port, token: token) else { continue }
            self.listener = listener
            let endpoint = DevToolsEndpoint(port: port, token: token, isSecure: identity != nil)
            self.endpoint = endpoint
            startRefreshing()
            return endpoint
        }
        throw Failure.noFreePort
    }

    /// Closes the port and every client. Nothing a client attached survives.
    func stop() {
        refresh?.cancel()
        refresh = nil
        listener?.cancel()
        listener = nil
        endpoint = nil
        for connection in connections.values { connection.close() }
        connections = [:]
        browser.releaseSessions()
    }

    private func open(_ port: UInt16, token: String) async -> NWListener? {
        guard let parameters = parameters(port: port), let listener = try? NWListener(using: parameters) else {
            return nil
        }
        let gate = DevToolsGate(token: token, port: port, allowedOrigins: allowedOrigins)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection, gate: gate) }
        }
        let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer = Once(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: answer.resume(true)
                case .failed, .cancelled: answer.resume(false)
                default: break
                }
            }
            listener.start(queue: .main)
        }
        guard opened else {
            listener.cancel()
            return nil
        }
        return listener
    }

    private func parameters(port: UInt16) -> NWParameters? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters: NWParameters
        if let identity, let secureIdentity = sec_identity_create(identity) {
            let security = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(security.securityProtocolOptions, secureIdentity)
            parameters = NWParameters(tls: security)
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        return parameters
    }

    private func accept(_ connection: NWConnection, gate: DevToolsGate) {
        let handler = DevToolsConnection(
            connection: connection, gate: gate,
            makeClient: { [browser] send in DevToolsClient(browser: browser, send: send) },
            answerRoute: { [weak self] route in self?.answer(route) },
            closed: { [weak self] closed in self?.connections[ObjectIdentifier(closed)] = nil })
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    // MARK: - Actions - Discovery

    private func answer(_ route: DevToolsGate.Route) -> DevToolsValue? {
        switch route {
        case .version:
            guard let endpoint else { return nil }
            return .object([
                "Browser": .string(browser.product), "Protocol-Version": .string(Self.protocolVersion),
                "User-Agent": .string(browser.userAgent), "webSocketDebuggerUrl": .string(endpoint.socketURL),
            ])
        case .list:
            return .array(browser.targets().map(\.listing))
        case .preflight, .socket:
            return nil
        }
    }

    private func startRefreshing() {
        refresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard let self else { return }
                for connection in self.connections.values { connection.client?.refreshTargets() }
            }
        }
    }

    // MARK: - Mutators

    /// 256 random bits, as URL-safe text.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Answers a continuation once, however many states arrive.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
