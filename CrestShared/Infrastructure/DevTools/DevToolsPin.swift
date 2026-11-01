import CryptoKit
import Foundation
import Security

/// Which server a page may trust as the DevTools port, and which pages may
/// reach it at all. A page's navigation delegate asks this before the usual
/// certificate rules, so only an allowed origin's page ever completes TLS with
/// the port, and only with exactly the certificate this launch made.
@MainActor
final class DevToolsPin {
    // MARK: - Static Variables

    static let shared = DevToolsPin()
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost"]

    // MARK: - Variables

    private var fingerprint: Data?
    private var port: Int?
    private var allowedOrigins: Set<String> = []
    private var endpoint: DevToolsEndpoint?

    /// Whether a port is open.
    var isOpen: Bool { endpoint != nil }

    // MARK: - Actions - Pinning

    func pin(fingerprint: Data?, endpoint: DevToolsEndpoint, allowedOrigins: Set<String>) {
        self.fingerprint = fingerprint
        self.endpoint = endpoint
        port = Int(endpoint.port)
        self.allowedOrigins = allowedOrigins
    }

    func clear() {
        fingerprint = nil
        endpoint = nil
        port = nil
        allowedOrigins = []
    }

    /// The script that tells a page of an allowed origin where the port is,
    /// which no other page ever receives: it carries the token. The page finds
    /// the endpoint on `crestDevTools`, and hears `crestdevtools` when it
    /// arrives after the page started.
    func clientScript(for pageURL: URL?) -> String? {
        guard let endpoint, let origin = pageURL?.devToolsOrigin, allowedOrigins.contains(origin) else { return nil }
        let value = DevToolsValue.object([
            "discoveryUrl": .string(endpoint.discoveryURL), "webSocketDebuggerUrl": .string(endpoint.socketURL),
        ])
        guard let text = try? value.text() else { return nil }
        return """
            Object.defineProperty(globalThis, "crestDevTools", { configurable: true, value: Object.freeze(\(text)) });
            dispatchEvent(new Event("crestdevtools")); void 0;
            """
    }

    /// The credential that accepts `challenge`, when it is the port's own
    /// certificate and `pageURL`'s origin may reach it.
    func credential(for challenge: URLAuthenticationChallenge, pageURL: URL?) -> URLCredential? {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let fingerprint, space.port == port,
            Self.loopbackHosts.contains(space.host), let pageURL, allowedOrigins.contains(pageURL.devToolsOrigin ?? ""),
            let trust = space.serverTrust,
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else { return nil }
        let presented = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        return presented == fingerprint ? URLCredential(trust: trust) : nil
    }
}

extension URL {
    /// This address's origin as a page's `Origin` header spells it.
    var devToolsOrigin: String? {
        guard let scheme, let host else { return nil }
        return port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}
