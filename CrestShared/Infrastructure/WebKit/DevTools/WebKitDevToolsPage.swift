import Foundation
import WebKit

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// One client's attachment to a page in `WKWebView`. WebKit exposes no protocol
/// of its own to an app, so this answers CDP over what `WKWebView` offers and
/// `WebKitDevToolsRuntime`, which lives in the document. Commands WebKit has no
/// way to honor fail with a reason rather than pretend to succeed, so a client
/// never mistakes "unsupported" for "nothing there". Input is DOM events, which
/// a page can tell from the person's own.
@MainActor
final class WebKitDevToolsPage: NSObject, DevToolsPageSession {
    // MARK: - Types

    private typealias Command = @MainActor (WebKitDevToolsPage, DevToolsValue) async throws -> DevToolsValue

    private struct Evaluation: Decodable {
        let expression: String
        let awaitPromise: Bool?
        let contextId: Int?
        let uniqueContextId: String?
    }

    private struct FunctionCall: Decodable {
        let functionDeclaration: String
        let objectId: String?
        let executionContextId: Int?
        let uniqueContextId: String?
        let awaitPromise: Bool?
    }

    private struct NodeResolution: Decodable {
        let executionContextId: Int?
    }

    private struct Navigation: Decodable {
        let url: String
    }

    private struct IsolatedWorld: Decodable {
        let worldName: String?
        let frameId: String?
    }

    private struct Screenshot: Decodable {
        struct Clip: Decodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }

        let format: String?
        let quality: Int?
        let clip: Clip?
    }

    private struct HistoryEntry: Decodable {
        let entryId: Int
    }

    private struct UserAgent: Decodable {
        let userAgent: String
    }

    private struct NewDocumentScript: Decodable {
        let source: String
    }

    private struct ScriptReference: Decodable {
        let identifier: String
    }

    private struct FetchInterception: Decodable {
        struct Pattern: Decodable {
            let resourceType: String?
        }

        let patterns: [Pattern]?
    }

    private struct DialogAnswer: Decodable {
        let accept: Bool
        let promptText: String?
    }

    private struct PausedRequest: Decodable {
        let requestId: String
    }

    private struct CookieQuery: Decodable {
        let urls: [String]?
    }

    private struct CookieDeletion: Decodable {
        let name: String
        let url: String?
        let domain: String?
        let path: String?
    }

    private struct CookieWrite: Decodable {
        let name: String
        let value: String
        let url: String?
        let domain: String?
        let path: String?
        let secure: Bool?
        let httpOnly: Bool?
        let expires: Double?
        let sameSite: String?

        /// This write as a cookie, or nil when it names no host.
        var cookie: HTTPCookie? {
            let origin = url.flatMap(URL.init(string:))
            guard let host = domain ?? origin?.host else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: host, .path: path ?? "/",
            ]
            if secure == true || origin?.scheme == "https" { properties[.secure] = "TRUE" }
            if let expires, expires > 0 { properties[.expires] = Date(timeIntervalSince1970: expires) }
            if let sameSite { properties[.sameSitePolicy] = sameSite.lowercased() }
            if httpOnly == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }

    private struct CookiesWrite: Decodable {
        let cookies: [CookieWrite]
    }

    // MARK: - Static Variables

    private static let noOperations: Set<String> = [
        "Log.enable", "Log.disable", "Security.enable", "Security.disable", "Performance.enable", "Performance.disable",
        "Inspector.enable", "Inspector.disable", "Page.setLifecycleEventsEnabled", "Runtime.runIfWaitingForDebugger",
        "Accessibility.enable", "Accessibility.disable", "DOM.enable", "DOM.disable",
        "Network.setBypassServiceWorker", "Network.setCacheDisabled",
    ]
    private static let refusals: [String: String] = [
        "DOM.setFileInputFiles": "a page in WKWebView can't be handed a file",
        "Emulation.setDeviceMetricsOverride": "the page takes its size from Crest's window",
        "Network.getResponseBody": "WKWebView doesn't expose response bodies",
        "Network.setRequestInterception": "WKWebView can't pause requests",
    ]
    private static let commands: [String: Command] = [
        "Page.enable": { page, _ in page.setEnabled(\.isPageEnabled) },
        "Page.disable": { page, _ in page.setDisabled(\.isPageEnabled) },
        "Page.navigate": { page, parameters in try await page.navigate(parameters) },
        "Page.reload": { page, _ in await page.reload() },
        "Page.stopLoading": { page, _ in page.stopLoading() },
        "Page.getFrameTree": { page, _ in try await page.frameTree() },
        "Page.getNavigationHistory": { page, _ in page.navigationHistory() },
        "Page.navigateToHistoryEntry": { page, parameters in try await page.navigateToHistoryEntry(parameters) },
        "Page.createIsolatedWorld": { page, parameters in try page.createIsolatedWorld(parameters) },
        "Page.captureScreenshot": { page, parameters in try await page.captureScreenshot(parameters) },
        "Page.printToPDF": { page, _ in try await page.printToPDF() },
        "Page.handleJavaScriptDialog": { page, parameters in try page.answerDialog(parameters) },
        "Page.getLayoutMetrics": { page, _ in try await page.run("layoutMetrics") },
        "Page.addScriptToEvaluateOnNewDocument": { page, parameters in try page.addNewDocumentScript(parameters) },
        "Page.removeScriptToEvaluateOnNewDocument": { page, parameters in try page.removeNewDocumentScript(parameters)
        },
        "Runtime.enable": { page, _ in try await page.enableRuntime() },
        "Runtime.disable": { page, _ in page.setDisabled(\.isRuntimeEnabled) },
        "Runtime.evaluate": { page, parameters in try await page.evaluate(parameters) },
        "Runtime.callFunctionOn": { page, parameters in try await page.callFunction(parameters) },
        "Runtime.getProperties": { page, parameters in try await page.runForObject("properties", parameters) },
        "Runtime.releaseObject": { page, parameters in try await page.runForObject("release", parameters) },
        "Runtime.releaseObjectGroup": { page, parameters in try await page.run("releaseGroup", parameters) },
        "Runtime.addBinding": { page, parameters in try await page.run("binding", parameters) },
        "DOM.getDocument": { page, parameters in try await page.run("document", parameters) },
        "DOM.querySelector": { page, parameters in try await page.runForNode("querySelector", parameters) },
        "DOM.querySelectorAll": { page, parameters in try await page.runForNode("querySelectorAll", parameters) },
        "DOM.describeNode": { page, parameters in try await page.runForNode("describeNode", parameters) },
        "DOM.resolveNode": { page, parameters in try await page.resolveNode(parameters) },
        "DOM.requestNode": { page, parameters in try await page.runForNode("requestNode", parameters) },
        "DOM.getBoxModel": { page, parameters in try await page.runForNode("boxModel", parameters) },
        "DOM.getContentQuads": { page, parameters in try await page.runForNode("contentQuads", parameters) },
        "DOM.focus": { page, parameters in try await page.runForNode("focus", parameters) },
        "DOM.getFrameOwner": { _, _ in throw DevToolsFailure(message: "Crest reaches a page's main frame only") },
        "Accessibility.getFullAXTree": { page, _ in try await page.run("accessibilityTree") },
        "Input.dispatchMouseEvent": { page, parameters in try await page.run("mouse", parameters) },
        "Input.dispatchKeyEvent": { page, parameters in try await page.run("key", parameters) },
        "Input.insertText": { page, parameters in try await page.run("insertText", parameters) },
        "Fetch.enable": { page, parameters in try page.enableDocumentFetch(parameters) },
        "Fetch.disable": { page, _ in
            page.pausesDocuments = false
            return .object([:])
        },
        "Fetch.continueRequest": { page, parameters in try page.answerPaused(parameters, allowed: true) },
        "Fetch.failRequest": { page, parameters in try page.answerPaused(parameters, allowed: false) },
        "Network.enable": { page, _ in await page.observeNetwork(true) },
        "Network.disable": { page, _ in await page.observeNetwork(false) },
        "Network.getCookies": { page, parameters in try await page.cookies(parameters) },
        "Network.getAllCookies": { page, _ in try await page.allCookies() },
        "Network.setCookie": { page, parameters in try await page.setCookie(parameters) },
        "Network.setCookies": { page, parameters in try await page.setCookies(parameters) },
        "Network.deleteCookies": { page, parameters in try await page.deleteCookies(parameters) },
        "Browser.getWindowForTarget": { _, _ in DevToolsClient.windowValue },
        "Emulation.setUserAgentOverride": { page, parameters in try page.overrideUserAgent(parameters) },
    ]

    // MARK: - Variables

    private let document: WebKitDevToolsDocument
    private let events: @MainActor (DevToolsPageEvent) -> Void
    private var originalUserAgent: String??
    private var isDetached = false
    private var didReplayConsole = false
    private(set) var isPageEnabled = false
    private(set) var isRuntimeEnabled = false
    private(set) var isObservingNetwork = false
    private(set) var pausesDocuments = false

    /// WebKit makes no trusted input for an app.
    let deliversTrustedInput = false

    private var webView: WKWebView? { document.webView }
    private var host: WebKitDevToolsDocument.Host { document.host }
    private var worlds: [WebKitDevToolsDocument.World] { document.worlds }
    private var frameID: String { document.frameID }

    // MARK: - Initializers

    /// Attaches to the page `document` tracks.
    init(document: WebKitDevToolsDocument, events: @escaping @MainActor (DevToolsPageEvent) -> Void) {
        self.document = document
        self.events = events
        super.init()
        document.add(self)
    }

    // MARK: - Actions - Commands

    func send(method: String, parameters: DevToolsValue?, childSession _: String?) async throws -> DevToolsValue {
        guard webView != nil else { throw DevToolsFailure.pageGone }
        if Self.noOperations.contains(method) { return .object([:]) }
        if let reason = Self.refusals[method] { throw DevToolsFailure.unsupported(method, reason) }
        guard let command = Self.commands[method] else { throw DevToolsFailure.unknownMethod(method) }
        do {
            return try await command(self, parameters ?? .object([:]))
        } catch is DecodingError {
            throw DevToolsFailure.invalidParameters(method)
        } catch let failure as DevToolsFailure {
            throw failure
        } catch {
            throw DevToolsFailure(message: Self.message(of: error))
        }
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        if let originalUserAgent { webView?.customUserAgent = originalUserAgent }
        document.remove(self)
    }

    // MARK: - Actions - Runtime

    private func run(
        _ name: String, _ parameters: DevToolsValue = .object([:]), in world: WebKitDevToolsDocument.World? = nil
    ) async throws -> DevToolsValue {
        try await document.run(name, parameters, in: world)
    }

    /// Runs operation `name` in the world `objectId` was made in.
    private func runForObject(_ name: String, _ parameters: DevToolsValue) async throws -> DevToolsValue {
        try await run(name, parameters, in: document.world(ofObject: parameters["objectId"]?.string))
    }

    private func runForNode(_ name: String, _ parameters: DevToolsValue) async throws -> DevToolsValue {
        try await run(name, parameters, in: document.world(ofNodeIn: parameters))
    }

    /// Answers a node as an object in the world the client asks for. A world
    /// can't hand another its objects, but they share the DOM: the node's own
    /// world raises an event on it, and the other one catches it.
    private func resolveNode(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        let source = document.world(ofNodeIn: parameters)
        let request = try parameters.decoded(as: NodeResolution.self)
        let target = try document.world(context: request.executionContextId ?? source.contextID, unique: nil)
        guard target.contextID != source.contextID else { return try await run("resolveNode", parameters, in: source) }
        try await document.installRuntime(in: target)
        _ = try await run("expose", parameters, in: source)
        return try await run("adopt", parameters, in: target)
    }

    // MARK: - Actions - Evaluation

    private func enableRuntime() async throws -> DevToolsValue {
        isRuntimeEnabled = true
        for world in worlds { document.reportContext(world, to: self) }
        if !didReplayConsole {
            didReplayConsole = true
            try await document.replayConsole(to: self)
        }
        return .object([:])
    }

    private func evaluate(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        let evaluation = try parameters.decoded(as: Evaluation.self)
        let world = try document.world(context: evaluation.contextId, unique: evaluation.uniqueContextId)
        try await document.installRuntime(in: world)
        let arrow = evaluation.awaitPromise == true ? "async () =>" : "() =>"
        let body = """
            const runtime = globalThis[__key];
            return JSON.stringify(await runtime.settled(JSON.parse(__request), \(arrow) (
            \(evaluation.expression)
            )));
            """
        do {
            return try await document.answer(body, parameters, in: world)
        } catch let failure as DevToolsFailure {
            throw failure
        } catch  where Self.isSyntaxError(error) {
            return try await evaluateProgram(evaluation.expression, parameters, in: world)
        } catch {
            // Caught between two documents: the next one can answer.
            try await Task.sleep(for: .milliseconds(150))
            try await document.installRuntime(in: world)
            return try await document.answer(body, parameters, in: world)
        }
    }

    /// What WebKit said about `error`, which its localized description hides.
    private static func message(of error: any Error) -> String {
        let info = (error as NSError).userInfo
        return info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    /// Whether WebKit refused to compile a script, rather than failing to run
    /// one. A client's expression fails this way when it is really a program.
    private static func isSyntaxError(_ error: any Error) -> Bool {
        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        return message?.contains("SyntaxError") == true
    }

    /// Evaluates what failed to compile as an expression, which is a program:
    /// only `eval` and a script evaluation report its last statement's value.
    /// `eval` also keeps objects as handles, so it goes first; where the page's
    /// content security policy refuses it, WebKit's script evaluation still
    /// runs, and answers by value.
    private func evaluateProgram(
        _ program: String, _ parameters: DevToolsValue, in world: WebKitDevToolsDocument.World
    ) async throws -> DevToolsValue {
        let body = """
            const runtime = globalThis[__key];
            return JSON.stringify(await runtime.settled(JSON.parse(__request), () => (0, eval)(__program)));
            """
        let evaluated = try await document.answer(body, parameters, in: world, program: program)
        guard evaluated["exceptionDetails"]?["exception"]?["className"]?.string == "EvalError" else { return evaluated }
        guard let webView else { throw DevToolsFailure.pageGone }
        do {
            let value = try await webView.evaluateJavaScript(program, in: nil, contentWorld: world.world)
            return .object(["result": Self.remoteObject(from: value)])
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            let text = message ?? error.localizedDescription
            return .object([
                "result": .object([
                    "type": .string("object"), "subtype": .string("error"), "description": .string(text),
                ]),
                "exceptionDetails": .object([
                    "exceptionId": .number(1), "text": .string(text), "lineNumber": .number(0),
                    "columnNumber": .number(0),
                ]),
            ])
        }
    }

    private func callFunction(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        let call = try parameters.decoded(as: FunctionCall.self)
        let world: WebKitDevToolsDocument.World
        if let objectID = call.objectId {
            world = document.world(ofObject: objectID)
        } else {
            world = try document.world(context: call.executionContextId, unique: call.uniqueContextId)
        }
        try await document.installRuntime(in: world)
        let body = """
            const runtime = globalThis[__key];
            return JSON.stringify(await runtime.call(JSON.parse(__request), (
            \(call.functionDeclaration)
            )));
            """
        return try await document.answer(body, parameters, in: world)
    }

    private static func remoteObject(from value: Any?) -> DevToolsValue {
        switch value {
        case let text as String: .object(["type": .string("string"), "value": .string(text)])
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            .object(["type": .string("boolean"), "value": .bool(number.boolValue)])
        case let number as NSNumber: .object(["type": .string("number"), "value": .number(number.doubleValue)])
        case let list as [Any]:
            .object([
                "type": .string("object"), "subtype": .string("array"), "className": .string("Array"),
                "value": json(from: list),
            ])
        case let members as [String: Any]:
            .object(["type": .string("object"), "className": .string("Object"), "value": json(from: members)])
        default: .object(["type": .string("undefined")])
        }
    }

    /// What WebKit answered, as JSON.
    private static func json(from value: Any?) -> DevToolsValue {
        switch value {
        case let text as String: .string(text)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): .bool(number.boolValue)
        case let number as NSNumber: .number(number.doubleValue)
        case let list as [Any]: .array(list.map(json(from:)))
        case let members as [String: Any]: .object(members.mapValues(json(from:)))
        default: .null
        }
    }

    // MARK: - Actions - Page

    private func setEnabled(_ flag: ReferenceWritableKeyPath<WebKitDevToolsPage, Bool>) -> DevToolsValue {
        self[keyPath: flag] = true
        return .object([:])
    }

    private func setDisabled(_ flag: ReferenceWritableKeyPath<WebKitDevToolsPage, Bool>) -> DevToolsValue {
        self[keyPath: flag] = false
        return .object([:])
    }

    private func answerDialog(_ parameters: DevToolsValue) throws -> DevToolsValue {
        let answer = try parameters.decoded(as: DialogAnswer.self)
        guard document.answerDialog(accepted: answer.accept, text: answer.promptText) else {
            throw DevToolsFailure(message: "No dialog is showing")
        }
        return .object([:])
    }

    private func frameTree() async throws -> DevToolsValue {
        .object(["frameTree": try await document.frameTree()])
    }

    private func navigate(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        guard let url = URL(string: try parameters.decoded(as: Navigation.self).url), url.scheme != nil else {
            return .object(["frameId": .string(frameID), "errorText": .string("net::ERR_INVALID_URL")])
        }
        guard !host.isProtected(url) else { throw DevToolsFailure.refusedTarget }
        document.willLoad()
        let loaderID = document.loaderID
        host.navigate(url)
        await document.awaitCommit()
        return .object(["frameId": .string(frameID), "loaderId": .string(loaderID)])
    }

    private func reload() async -> DevToolsValue {
        document.willLoad()
        host.reload()
        await document.awaitCommit()
        return .object([:])
    }

    private func stopLoading() -> DevToolsValue {
        webView?.stopLoading()
        return .object([:])
    }

    private func navigationHistory() -> DevToolsValue {
        guard let list = webView?.backForwardList else {
            return .object(["currentIndex": .number(0), "entries": .array([])])
        }
        let items = list.backList + (list.currentItem.map { [$0] } ?? []) + list.forwardList
        let entries = items.enumerated().map { index, item in
            DevToolsValue.object([
                "id": .number(Double(index)), "url": .string(item.url.absoluteString),
                "userTypedURL": .string(item.initialURL.absoluteString), "title": .string(item.title ?? ""),
                "transitionType": .string("link"),
            ])
        }
        return .object(["currentIndex": .number(Double(list.backList.count)), "entries": .array(entries)])
    }

    private func navigateToHistoryEntry(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        guard let webView else { throw DevToolsFailure.pageGone }
        let list = webView.backForwardList
        let offset = try parameters.decoded(as: HistoryEntry.self).entryId - list.backList.count
        guard let item = list.item(at: offset) else { throw DevToolsFailure(message: "No entry with passed id") }
        guard !host.isProtected(item.url) else { throw DevToolsFailure.refusedTarget }
        document.willLoad()
        host.stepHistory(offset)
        await document.awaitCommit()
        return .object([:])
    }

    private func createIsolatedWorld(_ parameters: DevToolsValue) throws -> DevToolsValue {
        let request = try parameters.decoded(as: IsolatedWorld.self)
        // Running in the main frame instead would answer for the wrong document.
        guard request.frameId == nil || request.frameId == frameID else {
            throw DevToolsFailure.unsupported("Page.createIsolatedWorld", "Crest reaches a page's main frame only")
        }
        let world = document.addWorld(named: request.worldName ?? "")
        return .object(["executionContextId": .number(Double(world.contextID))])
    }

    private func captureScreenshot(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        guard let webView else { throw DevToolsFailure.pageGone }
        let screenshot = try parameters.decoded(as: Screenshot.self)
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        if let clip = screenshot.clip {
            configuration.rect = CGRect(x: clip.x, y: clip.y, width: clip.width, height: clip.height)
        }
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let data = Self.encoded(image, format: screenshot.format, quality: screenshot.quality) else {
            throw DevToolsFailure(message: "The snapshot couldn't be encoded")
        }
        return .object(["data": .string(data.base64EncodedString())])
    }

    #if canImport(UIKit)
        private static func encoded(_ image: UIImage, format: String?, quality: Int?) -> Data? {
            guard format == "jpeg" else { return image.pngData() }
            return image.jpegData(compressionQuality: CGFloat(quality ?? 80) / 100)
        }
    #else
        private static func encoded(_ image: NSImage, format: String?, quality: Int?) -> Data? {
            guard let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return nil }
            guard format == "jpeg" else { return bitmap.representation(using: .png, properties: [:]) }
            let factor = NSNumber(value: Double(quality ?? 80) / 100)
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: factor])
        }
    #endif

    private func printToPDF() async throws -> DevToolsValue {
        guard let webView else { throw DevToolsFailure.pageGone }
        let data = try await webView.pdf(configuration: WKPDFConfiguration())
        return .object(["data": .string(data.base64EncodedString())])
    }

    /// Scripts run once the new document commits, since a user script can't be
    /// removed from a content controller on its own: a page's first inline
    /// scripts may run before one of these does.
    private func addNewDocumentScript(_ parameters: DevToolsValue) throws -> DevToolsValue {
        .object(["identifier": .string(document.addScript(try parameters.decoded(as: NewDocumentScript.self).source))])
    }

    private func removeNewDocumentScript(_ parameters: DevToolsValue) throws -> DevToolsValue {
        document.removeScript(try parameters.decoded(as: ScriptReference.self).identifier)
        return .object([:])
    }

    private func overrideUserAgent(_ parameters: DevToolsValue) throws -> DevToolsValue {
        guard let webView else { throw DevToolsFailure.pageGone }
        if originalUserAgent == nil { originalUserAgent = .some(webView.customUserAgent) }
        webView.customUserAgent = try parameters.decoded(as: UserAgent.self).userAgent
        return .object([:])
    }

    /// The document may be on its way out; the next one starts observing by
    /// itself, so a failure here loses nothing.
    private func observeNetwork(_ observing: Bool) async -> DevToolsValue {
        isObservingNetwork = observing
        _ = try? await run("observeNetwork", .object(["observing": .bool(document.isObservingNetwork)]))
        return .object([:])
    }

    /// Pauses documents through the page's navigation delegate, which can hold
    /// one until the client answers. `WKWebView` can't pause any other kind of
    /// request, so nothing wider is offered. Both answers say so, which is how
    /// a client learns it may rely on a hold that covers documents alone.
    private func enableDocumentFetch(_ parameters: DevToolsValue) throws -> DevToolsValue {
        let patterns = try parameters.decoded(as: FetchInterception.self).patterns ?? []
        guard !patterns.isEmpty, patterns.allSatisfy({ $0.resourceType == "Document" }) else {
            throw DevToolsFailure.unsupported(
                "Fetch.enable", "WKWebView can pause documents only", data: "documents-only")
        }
        pausesDocuments = true
        return .object(["holdsDocuments": .bool(true)])
    }

    private func answerPaused(_ parameters: DevToolsValue, allowed: Bool) throws -> DevToolsValue {
        let requestID = try parameters.decoded(as: PausedRequest.self).requestId
        guard document.settle(requestID, allowed: allowed) else {
            throw DevToolsFailure(message: "Invalid InterceptionId.")
        }
        return .object([:])
    }

    // MARK: - Actions - Cookies

    private var cookieStore: WKHTTPCookieStore? {
        webView?.configuration.websiteDataStore.httpCookieStore
    }

    /// The page's Space's cookies, without those of an origin no client may
    /// reach.
    private func reachableCookies() async throws -> [HTTPCookie] {
        guard let cookieStore else { throw DevToolsFailure.pageGone }
        return await cookieStore.allCookies().filter { !isProtected(domain: $0.domain) }
    }

    private func isProtected(domain: String) -> Bool {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return URL(string: "https://\(host)").map(self.host.isProtected) ?? true
    }

    private func cookies(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        let cookies = try await reachableCookies()
        var urls = try parameters.decoded(as: CookieQuery.self).urls?.compactMap(URL.init(string:)) ?? []
        if urls.isEmpty, let url = webView?.url { urls = [url] }
        let scoped = cookies.filter { cookie in urls.contains { Self.applies(cookie, to: $0) } }
        return .object(["cookies": .array(scoped.map(Self.value(of:)))])
    }

    private func allCookies() async throws -> DevToolsValue {
        .object(["cookies": .array(try await reachableCookies().map(Self.value(of:)))])
    }

    private func setCookie(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        .object(["success": .bool(await write([try parameters.decoded(as: CookieWrite.self)]))])
    }

    private func setCookies(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        _ = await write(try parameters.decoded(as: CookiesWrite.self).cookies)
        return .object([:])
    }

    private func write(_ writes: [CookieWrite]) async -> Bool {
        guard let cookieStore else { return false }
        let cookies = writes.compactMap(\.cookie).filter { !isProtected(domain: $0.domain) }
        for cookie in cookies { await cookieStore.setCookie(cookie) }
        return cookies.count == writes.count
    }

    private func deleteCookies(_ parameters: DevToolsValue) async throws -> DevToolsValue {
        guard let cookieStore else { throw DevToolsFailure.pageGone }
        let deletion = try parameters.decoded(as: CookieDeletion.self)
        let scope = deletion.url.flatMap(URL.init(string:))
        let domain = deletion.domain ?? scope?.host
        for cookie in try await reachableCookies() where cookie.name == deletion.name {
            guard domain.map({ Self.matches(cookie.domain, host: $0) }) ?? true else { continue }
            guard deletion.path.map({ $0 == cookie.path }) ?? true else { continue }
            await cookieStore.deleteCookie(cookie)
        }
        return .object([:])
    }

    private static func matches(_ cookieDomain: String, host: String) -> Bool {
        let bare = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return host == bare || host.hasSuffix("." + bare)
    }

    private static func applies(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host, matches(cookie.domain, host: host) else { return false }
        return url.path.isEmpty ? cookie.path == "/" : url.path.hasPrefix(cookie.path)
    }

    private static func value(of cookie: HTTPCookie) -> DevToolsValue {
        .object([
            "name": .string(cookie.name), "value": .string(cookie.value), "domain": .string(cookie.domain),
            "path": .string(cookie.path), "expires": .number(cookie.expiresDate?.timeIntervalSince1970 ?? -1),
            "size": .number(Double(cookie.name.utf8.count + cookie.value.utf8.count)),
            "httpOnly": .bool(cookie.isHTTPOnly), "secure": .bool(cookie.isSecure),
            "session": .bool(cookie.isSessionOnly),
        ])
    }

    // MARK: - Actions - Events

    /// Says `method` to the client, when `isWanted`.
    func report(_ method: String, _ parameters: [String: DevToolsValue] = [:], when isWanted: Bool = true) {
        guard !isDetached, isWanted else { return }
        events(DevToolsPageEvent(method, .object(parameters)))
    }
}
