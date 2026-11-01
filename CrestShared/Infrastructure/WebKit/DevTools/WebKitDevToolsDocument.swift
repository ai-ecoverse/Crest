import Foundation
import WebKit

/// What every DevTools session on one page shares. In the protocol a page owns
/// its execution contexts and document, not a session: Slicc's client makes a
/// world on one session and proves it on another. So this keeps the worlds,
/// the runtime and the loader, follows the page from one document to the next,
/// and reports to each session what it asked to hear.
@MainActor
final class WebKitDevToolsDocument: NSObject {
    // MARK: - Types

    /// What the page's owner lets a session do, which goes through the same
    /// paths as the person's own commands.
    struct Host {
        let navigate: @MainActor (URL) -> Void
        let reload: @MainActor () -> Void
        /// Moves through the page's history by `offset`, which the core keeps:
        /// stepping `WKWebView` itself would leave the two apart.
        let stepHistory: @MainActor (_ offset: Int) -> Void
        /// Whether `url` belongs to an origin no client may drive, such as a
        /// client's own.
        let isProtected: @MainActor (URL) -> Bool
    }

    /// A JavaScript world of the page.
    struct World {
        let contextID: Int
        let name: String
        let world: WKContentWorld
        var isDefault: Bool { world === WKContentWorld.page }
    }

    /// What the runtime reports from inside the document.
    private enum ReportKind: String, Decodable {
        case console
        case exception
        case binding
        case document
        case domContent
        case resource
    }

    private struct Report: Decodable {
        let kind: ReportKind
        let level: String?
        let args: [DevToolsValue]?
        let details: DevToolsValue?
        let name: String?
        let payload: String?
        let url: String?
        let initiator: String?
        let status: Double?
        let mimeType: String?
        let encodedBytes: Double?
        /// When the page said it, in milliseconds.
        let time: Double?
    }

    // MARK: - Static Variables

    private static let mainContextID = 1
    /// How many node ids each world has to itself. A world can't hold another
    /// world's objects, so a node id says which world it came from.
    private static let nodeSpan = 1_000_000
    /// How long a document takes to give way to the next one.
    private static let transitionWait: Duration = .milliseconds(150)
    /// How long a load has to start before it isn't coming.
    private static let loadStartWait: Duration = .seconds(2)
    /// How long a client has to answer a page's dialog.
    private static let dialogWait: Duration = .seconds(10)
    /// How long a client has to answer for a paused document.
    private static let pauseWait: Duration = .seconds(10)
    /// How long a load has to reach a new document.
    private static let commitWait: Duration = .seconds(30)
    /// How long a page that was just made has to reach a document.
    private static let firstDocumentWait: Duration = .seconds(10)
    /// The documents sessions are attached to now, one per page.
    private static var attached = NSMapTable<WKWebView, WebKitDevToolsDocument>.weakToStrongObjects()
    /// Addresses each page's frames went to in its current document.
    private static var frameAddresses = NSMapTable<WKWebView, FrameAddresses>.weakToStrongObjects()

    // MARK: - Variables

    private(set) weak var webView: WKWebView?
    let host: Host
    private let targetID: String
    private let observesPage: Bool
    /// The name the runtime keeps itself under in a document.
    private let runtimeKey = "__crest_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let handlerName = "crestDevTools" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var sessions: [WebKitDevToolsPage] = []
    private(set) var worlds = [World(contextID: mainContextID, name: "", world: .page)]
    private var nextContextID = mainContextID + 1
    private var observations: [NSKeyValueObservation] = []
    private var scripts: [String: String] = [:]
    private var nextScript = 1
    private var nextRequest = 1
    private var loader = 1
    private var isLoaderAhead = false
    private var isSyncing = false
    private var syncAgain = false
    private var hasReadDocument = false
    private var hasDocumentStartRuntime = false
    /// The runtime's name for the document it last answered from.
    private var documentID: String?
    private var didReportLoad = false
    private var didReportContent = false
    /// A load was asked for and hasn't finished. `isLoading` stays false for a
    /// moment after one is asked for, which must not read as the old document
    /// loading again.
    private var isAwaitingLoad = false
    private var sawLoadStart = false
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private var openDialog: CheckedContinuation<(accepted: Bool, text: String?), Never>?
    /// Navigations held for a client's answer, by request.
    private var paused: [String: (session: WebKitDevToolsPage, answer: CheckedContinuation<Bool, Never>)] = [:]
    private var nextPause = 1
    private var lastURL: String?

    /// As in Chromium, a page's main frame goes by its target's id; clients
    /// look one up as the other.
    var frameID: String { targetID }
    var loaderID: String { "crest-loader-\(loader)" }
    var isObservingNetwork: Bool { sessions.contains(where: \.isObservingNetwork) }

    // MARK: - Initializers

    private init(webView: WKWebView, targetID: String, observesPage: Bool, host: Host) {
        self.webView = webView
        self.targetID = targetID
        self.observesPage = observesPage
        self.host = host
        super.init()
        lastURL = webView.url?.absoluteString
    }

    /// The document of `webView`, shared with any session already attached.
    /// `observesPage` says whether the page owns its content controller,
    /// which console and network reports travel through.
    static func shared(for webView: WKWebView, targetID: String, observesPage: Bool, host: Host) -> Self {
        if let document = attached.object(forKey: webView) as? Self { return document }
        let document = Self(webView: webView, targetID: targetID, observesPage: observesPage, host: host)
        attached.setObject(document, forKey: webView)
        return document
    }

    /// Waits for the page in `webView` to have left its first blank document
    /// for `expected`, the address its tab keeps. A tab no window showed has no
    /// page until it is attached to, and the page starts blank.
    static func awaitFirstDocument(in webView: WKWebView, expected: URL?) async {
        let deadline = ContinuousClock.now + firstDocumentWait
        let leavesBlank = expected != nil && expected?.scheme != "about"
        while ContinuousClock.now < deadline {
            // Only the document can say: `url` moves ahead of a load.
            let scheme = try? await webView.callAsyncJavaScript(
                "return location.protocol;", arguments: [:], in: nil, contentWorld: .page)
            if let scheme = scheme as? String, !leavesBlank || scheme != "about:" { return }
            try? await Task.sleep(for: transitionWait)
        }
    }

    /// Whether a session paused the page's document requests, so a navigation
    /// must wait for `allows(_:in:)`.
    static func holdsNavigation(in webView: WKWebView) -> Bool {
        attached.object(forKey: webView)?.sessions.contains(where: \.pausesDocuments) ?? false
    }

    /// Whether the client lets `request` go ahead. `WKWebView` can't pause a
    /// request, but a navigation delegate can hold a navigation for as long as
    /// it likes, so a document that's held never loads and nothing can race it.
    /// A client that doesn't answer is refused.
    static func allows(_ request: URLRequest, in webView: WKWebView) async -> Bool {
        guard let document = attached.object(forKey: webView) else { return true }
        for session in document.sessions where session.pausesDocuments {
            guard await document.ask(session, about: request) else { return false }
        }
        return true
    }

    /// Whether a client listening to the page answers its dialogs. A dialog
    /// holds the page's scripts until it's answered, and an agent's tab is
    /// usually off screen, where no person would see it.
    static func answersDialogs(in webView: WKWebView) -> Bool {
        attached.object(forKey: webView)?.sessions.contains(where: \.isPageEnabled) ?? false
    }

    /// Asks the client to answer a dialog. One that doesn't answer in time has
    /// it dismissed, as Chromium's clients do by default.
    static func askClient(
        type: String, message: String, defaultText: String?, in webView: WKWebView
    ) async -> (accepted: Bool, text: String?) {
        guard let document = attached.object(forKey: webView) else { return (false, nil) }
        let reply = await withCheckedContinuation { continuation in
            document.openDialog?.resume(returning: (false, nil))
            document.openDialog = continuation
            for session in document.sessions {
                session.report(
                    "Page.javascriptDialogOpening",
                    [
                        "url": .string(webView.url?.absoluteString ?? ""), "message": .string(message),
                        "type": .string(type), "hasBrowserHandler": .bool(false),
                        "defaultPrompt": .string(defaultText ?? ""),
                    ], when: session.isPageEnabled)
            }
            Task { @MainActor [weak document] in
                try? await Task.sleep(for: dialogWait)
                document?.answerDialog(accepted: false, text: nil)
            }
        }
        for session in document.sessions {
            session.report(
                "Page.javascriptDialogClosed",
                ["result": .bool(reply.accepted), "userInput": .string(reply.text ?? "")],
                when: session.isPageEnabled)
        }
        return reply
    }

    /// Answers the open dialog, or false when none is open.
    @discardableResult
    func answerDialog(accepted: Bool, text: String?) -> Bool {
        guard let dialog = openDialog else { return false }
        openDialog = nil
        dialog.resume(returning: (accepted, text))
        return true
    }

    /// Notes a frame's navigation while the port is open, whether or not a
    /// client attached yet. A page can't always see its frames for itself: a
    /// closed shadow root hides them from every script, and no script reaches
    /// into a cross-origin frame, so a frame nested in one is known only here.
    /// A client that attaches later still hears about a protected frame the
    /// page loaded first. A blank frame has no address to add.
    static func noteFrame(_ url: URL?, in webView: WKWebView) {
        guard DevToolsPin.shared.isOpen, let url, url.scheme != "about" else { return }
        let addresses = frameAddresses.object(forKey: webView) ?? FrameAddresses()
        addresses.urls.insert(url.absoluteString)
        frameAddresses.setObject(addresses, forKey: webView)
    }

    /// Forgets the frames of the document `webView` replaced.
    static func documentCommitted(in webView: WKWebView) {
        frameAddresses.removeObject(forKey: webView)
    }

    /// Whether a client attached to the page in `webView`.
    static func isTouched(_ webView: WKWebView) -> Bool {
        attached.object(forKey: webView) != nil
    }

    /// Whether a page a client touched must not go to `url`. A navigation
    /// delegate asks this first, so a script or a link can't take such a page
    /// into an origin no client may drive.
    static func refuses(_ url: URL?, in webView: WKWebView) -> Bool {
        guard let url, let document = attached.object(forKey: webView) else { return false }
        return document.host.isProtected(url)
    }

    // MARK: - Actions - Paused documents

    private func ask(_ session: WebKitDevToolsPage, about request: URLRequest) async -> Bool {
        let requestID = "crest-document-\(nextPause)"
        nextPause += 1
        return await withCheckedContinuation { continuation in
            paused[requestID] = (session, continuation)
            let headers = (request.allHTTPHeaderFields ?? [:]).mapValues(DevToolsValue.string)
            session.report(
                "Fetch.requestPaused",
                [
                    "requestId": .string(requestID), "frameId": .string(frameID), "resourceType": .string("Document"),
                    "networkId": .string(requestID),
                    "request": .object([
                        "url": .string(request.url?.absoluteString ?? ""),
                        "method": .string(request.httpMethod ?? "GET"), "headers": .object(headers),
                        "initialPriority": .string("VeryHigh"), "referrerPolicy": .string("no-referrer-when-downgrade"),
                    ]),
                ])
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.pauseWait)
                self?.settle(requestID, allowed: false)
            }
        }
    }

    /// Answers paused request `requestID`, or false when no such request waits.
    @discardableResult
    func settle(_ requestID: String, allowed: Bool) -> Bool {
        guard let waiting = paused.removeValue(forKey: requestID) else { return false }
        waiting.answer.resume(returning: allowed)
        return true
    }

    // MARK: - Actions - Sessions

    func add(_ session: WebKitDevToolsPage) {
        sessions.append(session)
        if sessions.count == 1 { startFollowing() }
    }

    /// Lets `session` go. Node ids outlive a session, as they do in Chromium:
    /// a client refers to a node it found over an earlier connection. So the
    /// runtime stays in the document, which only stops being followed, until
    /// the document ends or `releaseAll` takes it out.
    func remove(_ session: WebKitDevToolsPage) {
        sessions.removeAll { $0 === session }
        if !sessions.contains(where: \.isPageEnabled) { answerDialog(accepted: false, text: nil) }
        for (requestID, waiting) in paused where waiting.session === session { settle(requestID, allowed: false) }
        if sessions.isEmpty { stopFollowing() }
    }

    /// Takes the runtime out of every page, once the port closes.
    static func releaseAll() {
        for document in attached.objectEnumerator()?.allObjects as? [WebKitDevToolsDocument] ?? [] {
            document.release()
        }
        attached.removeAllObjects()
    }

    private func startFollowing() {
        guard let webView else { return }
        if observesPage {
            let controller = webView.configuration.userContentController
            controller.add(WebKitDevToolsReports(self), contentWorld: .page, name: handlerName)
            addDocumentStartRuntime(to: controller)
        }
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.syncDocument() }
        }
        observations = [
            webView.observe(\.url, options: [.new]) { _, _ in changed() },
            webView.observe(\.isLoading, options: [.new]) { _, _ in changed() },
            webView.observe(\.title, options: [.new]) { _, _ in changed() },
            webView.observe(\.estimatedProgress, options: [.new]) { _, _ in changed() },
        ]
        syncDocument()
    }

    /// A content controller can't drop one script, and the page's controller
    /// holds Crest's own too, so this stays for the life of a page a client
    /// attached to. With no session it only keeps its own bounded history;
    /// nothing leaves the document.
    private func addDocumentStartRuntime(to controller: WKUserContentController) {
        guard !hasDocumentStartRuntime,
            let source = try? WebKitDevToolsRuntime.documentStartSource(
                key: runtimeKey, handler: handlerName, context: Self.mainContextID, nodeSpan: Self.nodeSpan,
                frame: frameID)
        else { return }
        hasDocumentStartRuntime = true
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    private func stopFollowing() {
        observations = []
        guard observesPage, let webView else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: handlerName, contentWorld: .page)
    }

    private func release() {
        guard let webView else { return }
        if !sessions.isEmpty { stopFollowing() }
        sessions = []
        for world in worlds {
            webView.evaluateJavaScript(
                "delete globalThis[\(jsonString(runtimeKey))]; void 0", in: nil, in: world.world, completionHandler: nil
            )
        }
    }

    // MARK: - Actions - Runtime

    /// Runs operation `name` of the document's runtime in `world`. WebKit fails
    /// a script caught between two documents, so one that fails runs once more
    /// in the document that follows.
    func run(_ name: String, _ parameters: DevToolsValue, in world: World? = nil) async throws -> DevToolsValue {
        let world = world ?? worlds[0]
        let body = "return JSON.stringify(await globalThis[__key][__name](JSON.parse(__request)));"
        do {
            try await installRuntime(in: world)
            return try await answer(body, name: name, parameters, in: world)
        } catch let failure as DevToolsFailure {
            throw failure
        } catch {
            try await Task.sleep(for: Self.transitionWait)
            try await installRuntime(in: world)
            return try await answer(body, name: name, parameters, in: world)
        }
    }

    func answer(
        _ body: String, name: String = "", _ parameters: DevToolsValue, in world: World, program: String = ""
    ) async throws -> DevToolsValue {
        guard let webView else { throw DevToolsFailure.pageGone }
        let value = try await webView.callAsyncJavaScript(
            body,
            arguments: [
                "__key": runtimeKey, "__name": name, "__request": try parameters.text(), "__program": program,
            ], in: nil, contentWorld: world.world)
        guard let text = value as? String else { return .object([:]) }
        let answer = try JSONDecoder().decode(DevToolsValue.self, from: Data(text.utf8))
        if let message = answer["__failure"]?.string { throw DevToolsFailure(message: message) }
        return answer
    }

    func installRuntime(in world: World) async throws {
        guard let webView else { throw DevToolsFailure.pageGone }
        _ = try await webView.callAsyncJavaScript(
            WebKitDevToolsRuntime.source,
            arguments: [
                "__key": runtimeKey, "__handler": handlerName, "__context": world.contextID,
                "__observes": observesPage && world.isDefault, "__nodeSpan": Self.nodeSpan, "__frame": frameID,
            ], in: nil, contentWorld: world.world)
    }

    // MARK: - Actions - Worlds

    func world(context: Int?, unique: String?) throws -> World {
        if let unique {
            guard let world = worlds.first(where: { uniqueID(of: $0) == unique }) else {
                throw DevToolsFailure(message: "Cannot find context with specified id")
            }
            return world
        }
        guard let context else { return worlds[0] }
        guard let world = worlds.first(where: { $0.contextID == context }) else {
            throw DevToolsFailure(message: "Cannot find context with specified id")
        }
        return world
    }

    func world(ofObject objectID: String?) -> World {
        let context = objectID?.split(separator: ".").dropFirst().first.flatMap { Int($0) }
        return worlds.first { $0.contextID == context } ?? worlds[0]
    }

    /// The world a DOM command belongs in: the one its object or node came
    /// from.
    func world(ofNodeIn parameters: DevToolsValue) -> World {
        if let objectID = parameters["objectId"]?.string { return world(ofObject: objectID) }
        let id = parameters["backendNodeId"] ?? parameters["nodeId"]
        guard case .number(let number)? = id else { return worlds[0] }
        let context = Int(number) / Self.nodeSpan
        return worlds.first { $0.contextID == context } ?? worlds[0]
    }

    /// Adds a world and tells every session about it.
    func addWorld(named name: String) -> World {
        let world = World(
            contextID: nextContextID, name: name, world: .world(name: "Crest.DevTools.\(runtimeKey).\(nextContextID)"))
        nextContextID += 1
        worlds.append(world)
        for session in sessions { reportContext(world, to: session) }
        return world
    }

    private func uniqueID(of world: World) -> String {
        "\(loaderID).\(world.contextID)"
    }

    // MARK: - Actions - Scripts

    /// Scripts run once the new document commits, since a user script can't be
    /// removed from a content controller on its own: a page's first inline
    /// scripts may run before one of these does.
    func addScript(_ source: String) -> String {
        let identifier = String(nextScript)
        nextScript += 1
        scripts[identifier] = source
        return identifier
    }

    func removeScript(_ identifier: String) {
        scripts[identifier] = nil
    }

    // MARK: - Actions - Frame

    func frameValue() -> DevToolsValue {
        let url = webView?.url
        let origin = url.flatMap { url -> String? in
            guard let scheme = url.scheme, let host = url.host else { return nil }
            return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        }
        return .object([
            "id": .string(frameID), "loaderId": .string(loaderID), "url": .string(url?.absoluteString ?? "about:blank"),
            "domainAndRegistry": .string(""), "securityOrigin": .string(origin ?? "null"),
            "mimeType": .string("text/html"), "secureContextType": .string("Secure"),
            "crossOriginIsolatedContextType": .string("NotIsolated"), "gatedAPIFeatures": .array([]),
        ])
    }

    /// The page's frames as the protocol's tree. They're listed so a client can
    /// tell what the page embeds, and can't be driven: `WKWebView` reaches only
    /// the main frame. An address alone is all a closed shadow root gives up.
    func frameTree() async throws -> DevToolsValue {
        let navigated = webView.flatMap { Self.frameAddresses.object(forKey: $0)?.urls } ?? []
        let request = DevToolsValue.object(["navigated": .array(navigated.sorted().map(DevToolsValue.string))])
        let listed = try await run("frames", request)
        guard case .array(let frames)? = listed["frames"] else { return .object(["frame": frameValue()]) }
        let children = frames.map { frame -> DevToolsValue in
            let url = frame["url"]?.string ?? "about:blank"
            let origin = URL(string: url)?.devToolsOrigin ?? "null"
            return .object([
                "frame": .object([
                    "id": frame["id"] ?? .string(""), "parentId": .string(frameID), "loaderId": .string(loaderID),
                    "url": .string(url), "domainAndRegistry": .string(""), "securityOrigin": .string(origin),
                    "mimeType": .string("text/html"), "secureContextType": .string("Secure"),
                    "crossOriginIsolatedContextType": .string("NotIsolated"), "gatedAPIFeatures": .array([]),
                ])
            ])
        }
        guard !children.isEmpty else { return .object(["frame": frameValue()]) }
        return .object(["frame": frameValue(), "childFrames": .array(children)])
    }

    /// Says a load was asked for, which a loader id names ahead of its
    /// document.
    func willLoad() {
        loader += 1
        isLoaderAhead = true
        didReportLoad = false
        didReportContent = false
        isAwaitingLoad = true
        sawLoadStart = false
        Task { @MainActor [weak self] in
            // A load to the same document, such as a fragment, never starts.
            try? await Task.sleep(for: Self.loadStartWait)
            guard let self, self.isAwaitingLoad, !self.sawLoadStart else { return }
            self.isAwaitingLoad = false
            self.resumeCommitWaiters()
            self.syncDocument()
        }
    }

    /// Returns once the load just asked for commits, fails or isn't coming.
    /// As in Chromium, a navigation answers only then: a client reads the
    /// document right after, and must not find the one being replaced.
    func awaitCommit() async {
        guard isAwaitingLoad else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.commitWait)
            self?.resumeCommitWaiters()
        }
        await withCheckedContinuation { commitWaiters.append($0) }
    }

    private func resumeCommitWaiters() {
        let waiters = commitWaiters
        commitWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Actions - Document

    /// Finds out whether a new document committed, which holds no runtime
    /// yet, and says what changed. A session can't take the page's navigation
    /// delegate, which is the page's own, so it reads what `WKWebView` publishes.
    private func syncDocument() {
        guard !sessions.isEmpty || !hasReadDocument else { return }
        guard !isSyncing else {
            syncAgain = true
            return
        }
        isSyncing = true
        Task { @MainActor [weak self] in
            await self?.readDocument()
            guard let self else { return }
            self.isSyncing = false
            if self.syncAgain {
                self.syncAgain = false
                self.syncDocument()
            }
        }
    }

    private func readDocument() async {
        guard let webView else { return }
        if let url = webView.url, host.isProtected(url) {
            webView.stopLoading()
            if let blank = URL(string: "about:blank") { host.navigate(blank) }
            return
        }
        let probe = try? await webView.callAsyncJavaScript(
            "return globalThis[__key]?.documentID ?? '';", arguments: ["__key": runtimeKey], in: nil,
            contentWorld: .page)
        let current = probe as? String
        if !hasReadDocument {
            // The document was there before the first session; nothing about
            // it is new, and a world a client just made stays.
            hasReadDocument = true
            try? await installRuntime(in: worlds[0])
            documentID = await readDocumentID()
        } else if let current, current != documentID {
            await beginDocument()
        } else if !webView.isLoading, let url = webView.url?.absoluteString, url != lastURL {
            // `url` moves ahead of a load before its document commits, so only
            // a settled page can have moved within its document.
            lastURL = url
            for session in sessions {
                session.report(
                    "Page.navigatedWithinDocument", ["frameId": .string(frameID), "url": .string(url)],
                    when: session.isPageEnabled)
            }
        }
        if webView.isLoading {
            sawLoadStart = true
        } else if !isAwaitingLoad || sawLoadStart {
            isAwaitingLoad = false
            resumeCommitWaiters()
            reportLoad()
        }
    }

    private func readDocumentID() async -> String? {
        let value = try? await webView?.callAsyncJavaScript(
            "return globalThis[__key]?.documentID ?? '';", arguments: ["__key": runtimeKey], in: nil,
            contentWorld: .page)
        return value as? String
    }

    private func beginDocument() async {
        guard let webView else { return }
        lastURL = webView.url?.absoluteString
        if !isLoaderAhead { loader += 1 }
        isLoaderAhead = false
        didReportLoad = false
        didReportContent = false
        worlds = [worlds[0]]
        for session in sessions { session.report("Runtime.executionContextsCleared", when: session.isRuntimeEnabled) }
        try? await installRuntime(in: worlds[0])
        documentID = await readDocumentID()
        if isObservingNetwork { _ = try? await run("observeNetwork", .object(["observing": .bool(true)])) }
        resumeCommitWaiters()
        for session in sessions {
            session.report(
                "Page.frameNavigated", ["frame": frameValue(), "type": .string("Navigation")],
                when: session.isPageEnabled)
            reportLifecycle("commit", to: session)
            reportContext(worlds[0], to: session)
        }
        for source in scripts.values {
            _ = try? await webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
        }
    }

    private func reportLoad() {
        guard !didReportLoad else { return }
        didReportLoad = true
        reportContentLoaded()
        let time = Self.now
        for session in sessions {
            session.report("Page.loadEventFired", ["timestamp": time], when: session.isPageEnabled)
            reportLifecycle("load", to: session)
            reportLifecycle("networkIdle", to: session)
        }
    }

    private func reportContentLoaded() {
        guard !didReportContent else { return }
        didReportContent = true
        let time = Self.now
        for session in sessions {
            session.report("Page.domContentEventFired", ["timestamp": time], when: session.isPageEnabled)
            reportLifecycle("DOMContentLoaded", to: session)
        }
    }

    private func reportLifecycle(_ name: String, to session: WebKitDevToolsPage) {
        session.report(
            "Page.lifecycleEvent",
            [
                "frameId": .string(frameID), "loaderId": .string(loaderID), "name": .string(name),
                "timestamp": Self.now,
            ], when: session.isPageEnabled)
    }

    func reportContext(_ world: World, to session: WebKitDevToolsPage) {
        session.report(
            "Runtime.executionContextCreated",
            [
                "context": .object([
                    "id": .number(Double(world.contextID)), "name": .string(world.name),
                    "origin": frameValue()["securityOrigin"] ?? .string("null"),
                    "uniqueId": .string(uniqueID(of: world)),
                    "auxData": .object([
                        "isDefault": .bool(world.isDefault), "type": .string(world.isDefault ? "default" : "isolated"),
                        "frameId": .string(frameID), "loaderId": .string(loaderID),
                    ]),
                ])
            ], when: session.isRuntimeEnabled)
    }

    private static var now: DevToolsValue {
        .number(Date().timeIntervalSince1970)
    }

    // MARK: - Actions - Reports

    /// Says what the document's console already showed to a client that just
    /// enabled `Runtime`, as Chromium replays it.
    func replayConsole(to session: WebKitDevToolsPage) async throws {
        let answer = try await run("history", .object([:]))
        guard case .array(let entries)? = answer["entries"] else { return }
        for entry in entries {
            guard let report = try? entry.decoded(as: Report.self) else { continue }
            deliver(report, to: [session])
        }
    }

    /// Takes what the document's runtime reported.
    fileprivate func take(_ text: String) {
        guard let report = try? JSONDecoder().decode(Report.self, from: Data(text.utf8)) else { return }
        deliver(report, to: sessions)
    }

    private func deliver(_ report: Report, to sessions: [WebKitDevToolsPage]) {
        let milliseconds = DevToolsValue.number(report.time ?? Date().timeIntervalSince1970 * 1000)
        let context = DevToolsValue.number(Double(Self.mainContextID))
        switch report.kind {
        case .console:
            for session in sessions {
                session.report(
                    "Runtime.consoleAPICalled",
                    [
                        "type": .string(report.level == "warn" ? "warning" : report.level ?? "log"),
                        "args": .array(report.args ?? []), "executionContextId": context, "timestamp": milliseconds,
                    ], when: session.isRuntimeEnabled)
            }
        case .exception:
            guard let details = report.details else { return }
            for session in sessions {
                session.report(
                    "Runtime.exceptionThrown", ["timestamp": milliseconds, "exceptionDetails": details],
                    when: session.isRuntimeEnabled)
            }
        case .binding:
            guard let name = report.name, let payload = report.payload else { return }
            for session in sessions {
                session.report(
                    "Runtime.bindingCalled",
                    ["name": .string(name), "payload": .string(payload), "executionContextId": context])
            }
        case .document:
            syncDocument()
        case .domContent:
            reportContentLoaded()
        case .resource:
            reportResource(report)
        }
    }

    /// A resource WebKit finished, as the protocol's three events. The browser
    /// reports it only once it is done, with no headers or body.
    private func reportResource(_ report: Report) {
        guard let url = report.url else { return }
        let requestID = DevToolsValue.string("crest-\(nextRequest)")
        nextRequest += 1
        let time = Self.now
        let type = DevToolsValue.string(Self.resourceType(of: report.initiator))
        let bytes = DevToolsValue.number(report.encodedBytes ?? 0)
        for session in sessions where session.isObservingNetwork {
            session.report(
                "Network.requestWillBeSent",
                [
                    "requestId": requestID, "loaderId": .string(loaderID), "documentURL": .string(lastURL ?? ""),
                    "request": .object([
                        "url": .string(url), "method": .string("GET"), "headers": .object([:]),
                        "initialPriority": .string("Medium"), "referrerPolicy": .string("no-referrer-when-downgrade"),
                    ]),
                    "timestamp": time, "wallTime": time, "initiator": .object(["type": .string("other")]),
                    "type": type, "frameId": .string(frameID),
                ])
            session.report(
                "Network.responseReceived",
                [
                    "requestId": requestID, "loaderId": .string(loaderID), "timestamp": time, "type": type,
                    "frameId": .string(frameID),
                    "response": .object([
                        "url": .string(url), "status": .number(report.status ?? 0), "statusText": .string(""),
                        "headers": .object([:]), "mimeType": .string(report.mimeType ?? ""),
                        "connectionReused": .bool(false), "connectionId": .number(0), "encodedDataLength": bytes,
                        "securityState": .string("unknown"),
                    ]),
                ])
            session.report(
                "Network.loadingFinished", ["requestId": requestID, "timestamp": time, "encodedDataLength": bytes])
        }
    }

    private static func resourceType(of initiator: String?) -> String {
        [
            "fetch": "Fetch", "xmlhttprequest": "XHR", "script": "Script", "link": "Stylesheet", "css": "Stylesheet",
            "img": "Image", "image": "Image", "video": "Media", "audio": "Media",
        ][initiator ?? ""] ?? "Other"
    }

    private func jsonString(_ text: String) -> String {
        (try? DevToolsValue.string(text).text()) ?? "\"\""
    }
}

// MARK: - Frame addresses

/// The addresses one page's frames went to.
private final class FrameAddresses {
    var urls: Set<String> = []
}

// MARK: - Reports

/// Carries the runtime's reports to the document without the content
/// controller keeping it alive.
private final class WebKitDevToolsReports: NSObject, WKScriptMessageHandler {
    private weak var document: WebKitDevToolsDocument?

    init(_ document: WebKitDevToolsDocument) {
        self.document = document
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        document?.take(text)
    }
}
