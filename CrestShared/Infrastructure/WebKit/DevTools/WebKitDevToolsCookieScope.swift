import Foundation

/// Which cookies a URL gets, by the rules a server's own request follows.
/// Clients decide what a cookie reaches from these answers, so one that's too
/// generous would misstate where a value goes.
enum WebKitDevToolsCookieScope {
    // MARK: - Actions - Matching

    /// Whether a cookie for `domain` goes to `host`. A cookie's domain has a
    /// leading dot when it covers subdomains, and none when it's only its host's.
    static func matches(domain: String, host: String) -> Bool {
        let host = host.lowercased()
        let domain = domain.lowercased()
        guard domain.hasPrefix(".") else { return host == domain }
        let parent = domain.dropFirst()
        return host == parent || host.hasSuffix(domain)
    }

    /// Whether a request to `url` carries `cookie`.
    static func applies(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host, matches(domain: cookie.domain, host: host) else { return false }
        guard !cookie.isSecure || url.scheme == "https" || url.scheme == "wss" else { return false }
        return matches(path: cookie.path, requestPath: url.path.isEmpty ? "/" : url.path)
    }

    private static func matches(path: String, requestPath: String) -> Bool {
        guard requestPath.hasPrefix(path) else { return false }
        return requestPath == path || path.hasSuffix("/") || requestPath.dropFirst(path.count).hasPrefix("/")
    }

    // MARK: - Actions - Writing

    /// The path a cookie set for `url` gets when a client names none.
    static func defaultPath(for url: URL?) -> String {
        guard let path = url?.path, path.hasPrefix("/"), let last = path.lastIndex(of: "/"), last != path.startIndex
        else { return "/" }
        return String(path[..<last])
    }

    /// Whether `domain`, as a client named it, is one `url` may set. A write
    /// naming both must not quietly pick one of them.
    static func agrees(domain: String, with url: URL?) -> Bool {
        guard let host = url?.host else { return true }
        let parent = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return matches(domain: "." + parent, host: host)
    }

    /// `domain` without the dot that says it covers subdomains.
    static func bare(_ domain: String) -> String {
        domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    }
}
