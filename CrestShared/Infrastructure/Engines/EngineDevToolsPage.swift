import Foundation

/// One client's attachment to a page whose engine speaks the protocol itself:
/// messages pass to the page's own DevTools agent unchanged, so everything the
/// engine supports works, including trusted input. Only ids change, so that
/// several commands can wait at once. Commands that reach past the page stay
/// behind: a client sees the browser as `DevToolsClient` shows it.
@MainActor
final class EngineDevToolsPage: DevToolsPageSession {
    // MARK: - Types

    private struct Reply: Decodable {
        let id: Int?
        let method: String?
        let params: DevToolsValue?
        let sessionId: String?
        let result: DevToolsValue?
        let error: DevToolsFailureValue?
    }

    private struct DevToolsFailureValue: Decodable {
        let code: Int?
        let message: String?
    }

    private struct Navigation: Decodable {
        let url: String
    }

    // MARK: - Static Variables

    /// Domains that would reach past this page.
    private static let refusedPrefixes = ["Browser.", "Extensions.", "SystemInfo.", "Tracing."]
    private static let refusedMethods: Set<String> = [
        "Target.createBrowserContext", "Target.createTarget", "Target.closeTarget", "Target.disposeBrowserContext",
        "Target.exposeDevToolsProtocol", "Target.sendMessageToTarget",
    ]

    // MARK: - Variables

    let deliversTrustedInput = true
    private weak var page: EnginePage?
    private let sessionID = UUID()
    private let isProtected: @MainActor (URL) -> Bool
    private let events: @MainActor (DevToolsPageEvent) -> Void
    private var waiting: [Int: CheckedContinuation<DevToolsValue, any Error>] = [:]
    private var nextID = 1

    // MARK: - Initializers

    /// Attaches to `page`, or nil when its engine has no protocol or the page
    /// shows no web content.
    init?(
        page: EnginePage, isProtected: @escaping @MainActor (URL) -> Bool,
        events: @escaping @MainActor (DevToolsPageEvent) -> Void
    ) {
        self.page = page
        self.isProtected = isProtected
        self.events = events
        page.devToolsSessions[sessionID] = self
        guard page.pages.request(OpenPageDevTools(pageID: page.id, sessionID: sessionID)) else {
            page.devToolsSessions[sessionID] = nil
            return nil
        }
    }

    // MARK: - Actions - Commands

    func send(method: String, parameters: DevToolsValue?, childSession: String?) async throws -> DevToolsValue {
        guard !Self.refusedMethods.contains(method), !Self.refusedPrefixes.contains(where: method.hasPrefix) else {
            throw DevToolsFailure.unknownMethod(method)
        }
        if method == "Page.navigate", let parameters,
            let url = URL(string: try parameters.decoded(as: Navigation.self).url), isProtected(url)
        {
            throw DevToolsFailure.refusedTarget
        }
        guard let page else { throw DevToolsFailure.pageGone }
        let id = nextID
        nextID += 1
        var message: [String: DevToolsValue] = [
            "id": .number(Double(id)), "method": .string(method), "params": parameters ?? .object([:]),
        ]
        if let childSession { message["sessionId"] = .string(childSession) }
        let text = try DevToolsValue.object(message).text()
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            guard page.pages.request(SendPageDevTools(pageID: page.id, sessionID: sessionID, message: text)) else {
                waiting[id] = nil
                continuation.resume(throwing: DevToolsFailure.pageGone)
                return
            }
        }
    }

    func detach() {
        guard let page else { return }
        page.pages.request(ClosePageDevTools(pageID: page.id, sessionID: sessionID))
        page.devToolsSessions[sessionID] = nil
        failWaiting()
    }

    // MARK: - Actions - Engine

    /// Takes one message from the page's agent.
    func take(_ text: String) {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)) else { return }
        if let id = reply.id, let continuation = waiting.removeValue(forKey: id) {
            if let error = reply.error {
                continuation.resume(
                    throwing: DevToolsFailure(code: error.code ?? -32000, message: error.message ?? "Unknown error"))
            } else {
                continuation.resume(returning: reply.result ?? .object([:]))
            }
        } else if let method = reply.method {
            events(DevToolsPageEvent(method, reply.params ?? .object([:]), childSession: reply.sessionId))
        }
    }

    /// The engine let the client go, as when the page left the web.
    func engineClosed() {
        page?.devToolsSessions[sessionID] = nil
        failWaiting()
    }

    private func failWaiting() {
        let continuations = waiting.values
        waiting = [:]
        for continuation in continuations { continuation.resume(throwing: DevToolsFailure.pageGone) }
    }
}
