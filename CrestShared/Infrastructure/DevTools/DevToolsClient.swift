import Foundation

/// One DevTools client on one socket, with the sessions it attached. Slicc's
/// `playwright-cli`, like every client Crest serves, speaks over the browser
/// socket with flat sessions, so this type owns the `Browser` and `Target`
/// domains; everything else belongs to an attached page.
@MainActor
final class DevToolsClient {
    // MARK: - Types

    private struct Session {
        let targetID: String
        let page: any DevToolsPageSession
        /// The command the session answers last, which the next one waits
        /// for, so input and scripts reach a page in the order they were sent.
        var last: Task<Void, Never>?
    }

    private struct TargetReference: Decodable {
        let targetId: String
    }

    private struct Attachment: Decodable {
        let targetId: String
        let flatten: Bool?
    }

    private struct Detachment: Decodable {
        let sessionId: String?
    }

    private struct Creation: Decodable {
        let url: String?
        let background: Bool?
    }

    private struct Discovery: Decodable {
        let discover: Bool
    }

    // MARK: - Static Variables

    /// Commands that may wait on a page for as long as the page likes, which
    /// must not hold back the commands sent after them.
    private static let waitingMethods: Set<String> = [
        "Runtime.evaluate", "Runtime.callFunctionOn", "Runtime.awaitPromise",
        // A navigation can be waiting for exactly this answer.
        "Fetch.continueRequest", "Fetch.failRequest",
    ]

    /// Events that name a session the engine opened under a page.
    private static let childSessionMethods: Set<String> = ["Target.attachedToTarget", "Target.detachedFromTarget"]
    /// The one window a client sees: Crest decides how a page is shown.
    static let windowValue = DevToolsValue.object([
        "windowId": .number(1), "bounds": .object(["windowState": .string("normal")]),
    ])

    // MARK: - Variables

    private let browser: any DevToolsBrowsing
    private let send: @MainActor (String) -> Void
    private var sessions: [String: Session] = [:]
    private var isDiscovering = false
    private var known: [String: DevToolsTarget] = [:]
    private var nextSession = 1
    /// Sessions on the browser itself, which answer as the socket does.
    private var browserSessions: Set<String> = []
    /// Whether this client checks `isTrusted` to learn if its input landed.
    /// Slicc's does, and dispatches the events itself when it sees none, so an
    /// engine that can't make trusted input must not deliver its own as well:
    /// a checkbox would toggle twice. Such input is acknowledged and dropped,
    /// which is what Chromium does to input for a page it isn't showing.
    fileprivate var verifiesInput = false

    // MARK: - Initializers

    init(browser: any DevToolsBrowsing, send: @escaping @MainActor (String) -> Void) {
        self.browser = browser
        self.send = send
    }

    // MARK: - Actions - Commands

    /// Takes one text message from the socket.
    func receive(_ text: String) {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(text.utf8)) else {
            reply(id: nil, sessionID: nil, .failure(.invalidRequest))
            return
        }
        guard let sessionID = request.sessionId, !browserSessions.contains(sessionID.raw) else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                reply(id: request.id, sessionID: request.sessionId?.raw, await self.answer(request))
            }
            return
        }
        guard let session = sessions[sessionID.parent] else {
            reply(id: request.id, sessionID: sessionID.raw, .failure(.noSession))
            return
        }
        if verifiesInput, !session.page.deliversTrustedInput, request.method.hasPrefix("Input.") {
            reply(id: request.id, sessionID: sessionID.raw, .success(.object([:])))
            return
        }
        let previous = Self.waitingMethods.contains(request.method) ? nil : session.last
        let task = Task { @MainActor [weak self] in
            await previous?.value
            let result: Result<DevToolsValue, DevToolsFailure>
            do {
                result = .success(
                    try await session.page.send(
                        method: request.method, parameters: request.params, childSession: sessionID.child))
            } catch let failure as DevToolsFailure {
                result = .failure(failure)
            } catch {
                result = .failure(DevToolsFailure(message: error.localizedDescription))
            }
            self?.reply(id: request.id, sessionID: sessionID.raw, result)
        }
        if !Self.waitingMethods.contains(request.method) {
            sessions[sessionID.parent]?.last = task
        }
    }

    private func answer(_ request: Request) async -> Result<DevToolsValue, DevToolsFailure> {
        do {
            return .success(try await perform(request))
        } catch let failure as DevToolsFailure {
            return .failure(failure)
        } catch is DecodingError {
            return .failure(.invalidParameters(request.method))
        } catch {
            return .failure(DevToolsFailure(message: error.localizedDescription))
        }
    }

    private func perform(_ request: Request) async throws -> DevToolsValue {
        let parameters = request.params ?? .object([:])
        guard let method = BrowserMethod(rawValue: request.method) else {
            throw DevToolsFailure.unknownMethod(request.method)
        }
        return try await method.perform(on: self, parameters)
    }

    // MARK: - Actions - Browser domain

    fileprivate func version() -> DevToolsValue {
        .object([
            "protocolVersion": .string(DevToolsServer.protocolVersion), "product": .string(browser.product),
            "revision": .string(""), "userAgent": .string(browser.userAgent), "jsVersion": .string(""),
        ])
    }

    fileprivate func targetsValue() -> DevToolsValue {
        .object(["targetInfos": .array(browser.targets().map { $0.value(attached: isAttached($0.id)) })])
    }

    fileprivate func targetInfo(_ parameters: DevToolsValue) throws -> DevToolsValue {
        let id = try parameters.decoded(as: TargetReference.self).targetId
        guard let target = browser.targets().first(where: { $0.id == id }) else { throw DevToolsFailure.noTarget }
        return .object(["targetInfo": target.value(attached: isAttached(id))])
    }

    fileprivate func discover(_ parameters: DevToolsValue) throws -> DevToolsValue {
        isDiscovering = try parameters.decoded(as: Discovery.self).discover
        guard isDiscovering else { return .object([:]) }
        known = [:]
        refreshTargets()
        return .object([:])
    }

    fileprivate func attach(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        let attachment = try parameters.decoded(as: Attachment.self)
        guard attachment.flatten == true else {
            throw DevToolsFailure(message: "Crest serves flat sessions only: attach with flatten")
        }
        guard let target = browser.targets().first(where: { $0.id == attachment.targetId }) else {
            throw DevToolsFailure.noTarget
        }
        let sessionID = "crest-session-\(nextSession)"
        nextSession += 1
        let attached = await browser.attach(target.id) { [weak self] event in
            self?.forward(event, from: sessionID)
        }
        guard let attached else { throw DevToolsFailure.refusedTarget }
        sessions[sessionID] = Session(targetID: target.id, page: attached, last: nil)
        emit(
            "Target.attachedToTarget",
            .object([
                "sessionId": .string(sessionID), "targetInfo": target.value(attached: true),
                "waitingForDebugger": .bool(false),
            ]), sessionID: nil)
        return .object(["sessionId": .string(sessionID)])
    }

    fileprivate func attachToBrowser() -> DevToolsValue {
        let sessionID = "crest-session-\(nextSession)"
        nextSession += 1
        browserSessions.insert(sessionID)
        return .object(["sessionId": .string(sessionID)])
    }

    fileprivate func detach(_ parameters: DevToolsValue) throws -> DevToolsValue {
        guard let sessionID = try parameters.decoded(as: Detachment.self).sessionId else {
            throw DevToolsFailure.noSession
        }
        if browserSessions.remove(sessionID) != nil { return .object([:]) }
        guard sessions[sessionID] != nil else { throw DevToolsFailure.noSession }
        end(sessionID)
        return .object([:])
    }

    fileprivate func create(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        let creation = try parameters.decoded(as: Creation.self)
        guard let url = URL(string: creation.url ?? "about:blank") else {
            throw DevToolsFailure.invalidParameters("Target.createTarget")
        }
        guard let id = await browser.openTarget(url: url, inBackground: creation.background ?? false) else {
            throw DevToolsFailure.refusedTarget
        }
        refreshTargets()
        return .object(["targetId": .string(id)])
    }

    fileprivate func close(_ parameters: DevToolsValue) throws -> DevToolsValue {
        let closed = browser.closeTarget(try parameters.decoded(as: TargetReference.self).targetId)
        refreshTargets()
        return .object(["success": .bool(closed)])
    }

    fileprivate func activate(_ parameters: DevToolsValue) throws -> DevToolsValue {
        guard browser.activateTarget(try parameters.decoded(as: TargetReference.self).targetId) else {
            throw DevToolsFailure.noTarget
        }
        return .object([:])
    }

    // MARK: - Actions - Targets

    /// Says what changed since the client last heard, and ends the sessions
    /// of pages that are gone or out of reach now, as when a Space locks.
    func refreshTargets() {
        let targets = browser.targets()
        let ids = Set(targets.map(\.id))
        for (sessionID, session) in sessions where !ids.contains(session.targetID) {
            end(sessionID)
        }
        guard isDiscovering else { return }
        for id in known.keys where !ids.contains(id) {
            known[id] = nil
            emit("Target.targetDestroyed", .object(["targetId": .string(id)]), sessionID: nil)
        }
        for target in targets where known[target.id] != target {
            let method = known[target.id] == nil ? "Target.targetCreated" : "Target.targetInfoChanged"
            known[target.id] = target
            emit(method, .object(["targetInfo": target.value(attached: isAttached(target.id))]), sessionID: nil)
        }
    }

    private func isAttached(_ targetID: String) -> Bool {
        sessions.values.contains { $0.targetID == targetID }
    }

    // MARK: - Actions - Lifecycle

    /// Ends every session, once the socket closes.
    func disconnect() {
        for sessionID in sessions.keys {
            sessions.removeValue(forKey: sessionID)?.page.detach()
        }
    }

    private func end(_ sessionID: String) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        session.page.detach()
        emit(
            "Target.detachedFromTarget",
            .object(["sessionId": .string(sessionID), "targetId": .string(session.targetID)]), sessionID: nil)
    }

    // MARK: - Actions - Output

    /// Passes on what a page said. A session the engine opened under the page
    /// goes by this client's session and its own, so a later command finds
    /// its way back.
    private func forward(_ event: DevToolsPageEvent, from sessionID: String) {
        guard sessions[sessionID] != nil else { return }
        var parameters = event.parameters
        if Self.childSessionMethods.contains(event.method), case .object(var members) = parameters,
            let child = members["sessionId"]?.string
        {
            members["sessionId"] = .string("\(sessionID)/\(child)")
            parameters = .object(members)
        }
        emit(event.method, parameters, sessionID: event.childSession.map { "\(sessionID)/\($0)" } ?? sessionID)
    }

    private func emit(_ method: String, _ parameters: DevToolsValue, sessionID: String?) {
        var message: [String: DevToolsValue] = ["method": .string(method), "params": parameters]
        if let sessionID { message["sessionId"] = .string(sessionID) }
        write(.object(message))
    }

    private func reply(id: Int64?, sessionID: String?, _ result: Result<DevToolsValue, DevToolsFailure>) {
        var message: [String: DevToolsValue] = [:]
        if let id { message["id"] = .number(Double(id)) }
        if let sessionID { message["sessionId"] = .string(sessionID) }
        switch result {
        case .success(let value): message["result"] = value
        case .failure(let failure): message["error"] = failure.value
        }
        write(.object(message))
    }

    private func write(_ value: DevToolsValue) {
        guard let text = try? value.text() else { return }
        send(text)
    }
}

// MARK: - Request

/// One command from a client.
private struct Request: Decodable {
    /// The session a command names: one this client attached, or one the
    /// engine opened under it, which arrives in the engine's own spelling.
    struct SessionName {
        let raw: String
        let parent: String
        let child: String?
    }

    let id: Int64
    let method: String
    let params: DevToolsValue?
    private let rawSessionId: String?

    var sessionId: SessionName? {
        rawSessionId.map { raw in
            let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
            return SessionName(raw: raw, parent: parts.first ?? raw, child: parts.count > 1 ? parts[1] : nil)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, method, params
        case rawSessionId = "sessionId"
    }
}

// MARK: - Browser methods

/// The commands the browser target answers itself, which know what they do.
private struct BrowserMethod {
    private static let all: [String: @MainActor (DevToolsClient, DevToolsValue) async throws -> DevToolsValue] = [
        "Browser.getVersion": { client, _ in client.version() },
        "Slicc.action": { client, _ in
            client.verifiesInput = true
            return .object([:])
        },
        "Browser.getWindowForTarget": { _, _ in DevToolsClient.windowValue },
        "Target.getTargets": { client, _ in client.targetsValue() },
        "Target.getTargetInfo": { client, parameters in try client.targetInfo(parameters) },
        "Target.setDiscoverTargets": { client, parameters in try client.discover(parameters) },
        "Target.setAutoAttach": { _, _ in .object([:]) },
        "Target.attachToTarget": { client, parameters in try await client.attach(parameters) },
        "Target.attachToBrowserTarget": { client, _ in client.attachToBrowser() },
        "Target.detachFromTarget": { client, parameters in try client.detach(parameters) },
        "Target.createTarget": { client, parameters in try await client.create(parameters) },
        "Target.closeTarget": { client, parameters in try client.close(parameters) },
        "Target.activateTarget": { client, parameters in try client.activate(parameters) },
    ]

    private let run: @MainActor (DevToolsClient, DevToolsValue) async throws -> DevToolsValue

    init?(rawValue: String) {
        guard let run = Self.all[rawValue] else { return nil }
        self.run = run
    }

    @MainActor func perform(on client: DevToolsClient, _ parameters: DevToolsValue) async throws -> DevToolsValue {
        try await run(client, parameters)
    }
}
