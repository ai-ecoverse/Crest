import Foundation

/// What may reach the DevTools port. Browsers obey `Host` and `Origin`, which
/// stops a web page and DNS rebinding; any other program on the device can
/// forge both, so what really lets a client in is the token, which only Crest
/// and the pages it hands the endpoint to know.
struct DevToolsGate: Sendable {
    // MARK: - Types

    /// One HTTP request as the client sent it.
    struct Request: Equatable, Sendable {
        let method: String
        let path: String
        /// By lowercased name.
        let headers: [String: String]

        /// Parses a request head, without the blank line that ends it.
        init?(head: String) {
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
            guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
            method = String(requestLine[0])
            path = String(requestLine[1])
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            self.headers = headers
        }

        var isSocketUpgrade: Bool {
            headers["upgrade"]?.lowercased() == "websocket"
                && headers["connection"]?.lowercased().contains("upgrade") == true
        }
    }

    /// What a request may do once it passed.
    enum Route: Equatable, Sendable {
        case version
        case list
        case preflight
        case socket(key: String)
    }

    /// The gate's answer.
    enum Admission: Equatable, Sendable {
        case refused
        case admitted(Route, origin: String?)
    }

    // MARK: - Variables

    let token: String
    let port: UInt16
    /// The origins whose pages may connect, each `scheme://host[:port]`.
    let allowedOrigins: Set<String>

    // MARK: - Actions - Admission

    func admit(_ request: Request) -> Admission {
        guard isLocalHost(request.headers["host"]) else { return .refused }
        let origin = request.headers["origin"]
        if let origin, !allowedOrigins.contains(origin) { return .refused }
        if request.method == "OPTIONS" {
            guard origin != nil, request.headers["access-control-request-method"] == "GET" else { return .refused }
            return .admitted(.preflight, origin: origin)
        }
        guard request.method == "GET" else { return .refused }
        if request.isSocketUpgrade {
            guard hasToken(request.path, under: "/devtools/browser/", suffix: ""),
                let key = request.headers["sec-websocket-key"], !key.isEmpty,
                request.headers["sec-websocket-version"] == "13"
            else { return .refused }
            return .admitted(.socket(key: key), origin: origin)
        }
        if hasToken(request.path, under: "/", suffix: "/json/version")
            || hasToken(request.path, under: "/", suffix: "/json/version/")
        {
            return .admitted(.version, origin: origin)
        }
        if hasToken(request.path, under: "/", suffix: "/json/list")
            || hasToken(request.path, under: "/", suffix: "/json")
        {
            return .admitted(.list, origin: origin)
        }
        return .refused
    }

    private func isLocalHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host)
    }

    /// Whether `path` is `prefix`, the token and `suffix`, compared without
    /// stopping at the first difference.
    private func hasToken(_ path: String, under prefix: String, suffix: String) -> Bool {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix),
            path.utf8.count >= prefix.utf8.count + suffix.utf8.count
        else { return false }
        let candidate = Array(path.utf8.dropFirst(prefix.utf8.count).dropLast(suffix.utf8.count))
        let expected = Array(token.utf8)
        guard candidate.count == expected.count else { return false }
        return zip(candidate, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: - Actions - Responses

    /// The headers an admitted page may read a response with.
    func crossOriginHeaders(for origin: String?) -> [String] {
        guard let origin else { return [] }
        return [
            "Access-Control-Allow-Origin: \(origin)", "Vary: Origin",
            "Access-Control-Allow-Private-Network: true",
        ]
    }
}
