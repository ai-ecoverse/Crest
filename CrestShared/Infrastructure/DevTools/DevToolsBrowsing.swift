import Foundation

/// A page a DevTools client can see, as the protocol's `TargetInfo` lists it.
struct DevToolsTarget: Equatable, Sendable {
    let id: String
    let title: String
    let url: String

    /// This target as the protocol's `TargetInfo`.
    func value(attached: Bool) -> DevToolsValue {
        .object([
            "targetId": .string(id), "type": .string("page"), "title": .string(title), "url": .string(url),
            "attached": .bool(attached), "canAccessOpener": .bool(false), "browserContextId": .string("default"),
        ])
    }

    /// This target as `/json/list` shows it. It names no socket: clients
    /// attach over the one browser socket.
    var listing: DevToolsValue {
        .object([
            "id": .string(id), "type": .string("page"), "title": .string(title), "url": .string(url),
        ])
    }
}

/// One client's attachment to a page. An engine answers commands for it and
/// reports events through the sink it was attached with. WebKit's binding
/// emulates the protocol over `WKWebView`; Chromium's passes it through to the
/// engine's own DevTools agent for exactly that page.
@MainActor
protocol DevToolsPageSession: AnyObject {
    /// Whether input reaches the page as trusted events.
    var deliversTrustedInput: Bool { get }
    /// Answers `method`. `childSession` names a session the engine itself
    /// opened under this page, such as an out-of-process frame's.
    func send(method: String, parameters: DevToolsValue?, childSession: String?) async throws -> DevToolsValue
    /// Ends the attachment. No event follows it.
    func detach()
}

/// What an attached page says without being asked.
struct DevToolsPageEvent: Sendable {
    let method: String
    let parameters: DevToolsValue
    /// The session the engine opened under the page that raised it, if any.
    let childSession: String?

    init(_ method: String, _ parameters: DevToolsValue = .object([:]), childSession: String? = nil) {
        self.method = method
        self.parameters = parameters
        self.childSession = childSession
    }
}

/// The browser a DevTools server exposes: what is open in the Spaces a client
/// may reach, and the tab operations it may ask for. Each platform's composition
/// supplies it, so tabs open and close through the same stores the person's own
/// commands use, and a private window or locked Space is simply never listed.
@MainActor
protocol DevToolsBrowsing: AnyObject {
    /// What `Browser.getVersion` and `/json/version` name.
    var product: String { get }
    var userAgent: String { get }
    /// The pages a client can reach now, in tab order.
    func targets() -> [DevToolsTarget]
    /// Attaches to target `id`, or nil when it is gone or out of reach.
    func attach(
        _ id: String, events: @escaping @MainActor (DevToolsPageEvent) -> Void
    ) async -> (any DevToolsPageSession)?
    /// Opens a tab at `url` and answers its target id.
    func openTarget(url: URL, inBackground: Bool) async -> String?
    func closeTarget(_ id: String) -> Bool
    /// Brings target `id` forward.
    func activateTarget(_ id: String) -> Bool
    /// Takes out of every page what sessions left there, once the port closes.
    func releaseSessions()
}
