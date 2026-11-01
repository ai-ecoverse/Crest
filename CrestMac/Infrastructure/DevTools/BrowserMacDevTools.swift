import AppKit
import Observation
import WebKit

/// The DevTools port on the Mac: Chromium tabs pass through to the engine's
/// own agent, and WebKit tabs answer as `WebKitDevToolsPage` does on iPhone. A
/// Chromium page reaches plain `ws` on loopback, but WebKit refuses it from an
/// `https` page, so a second port speaks TLS for WebKit's pages. Both are off
/// at every launch, and neither shows a private window, a locked Space, or a
/// page of an allowed origin.
@Observable
@MainActor
final class BrowserMacDevTools: DevToolsBrowsing {
    // MARK: - Static Variables

    private static let allowedOriginsKey = "devTools.allowedOrigins"
    private static let defaultOrigins = ["https://seven.sliccy.ai"]

    // MARK: - Variables

    /// Where the port answers, while it is on.
    private(set) var endpoint: DevToolsEndpoint?
    /// Why the port couldn't open.
    private(set) var failure: LocalizedStringResource?
    private(set) var allowedOrigins: [String] {
        didSet { UserDefaults.standard.set(allowedOrigins, forKey: Self.allowedOriginsKey) }
    }

    @ObservationIgnored private unowned let application: BrowserMacApplication
    @ObservationIgnored private var servers: [DevToolsServer] = []

    var isOn: Bool { endpoint != nil }

    let product = "Crest"
    var userAgent: String { "Crest" }

    // MARK: - Initializers

    init(application: BrowserMacApplication) {
        self.application = application
        allowedOrigins = UserDefaults.standard.stringArray(forKey: Self.allowedOriginsKey) ?? Self.defaultOrigins
    }

    // MARK: - Actions - Lifecycle

    func setOn(_ isOn: Bool) {
        if isOn {
            Task { await start() }
        } else {
            stop()
        }
    }

    private func start() async {
        guard servers.isEmpty else { return }
        failure = nil
        let origins = Set(allowedOrigins)
        do {
            let plain = DevToolsServer(browser: self, allowedOrigins: origins, identity: nil)
            endpoint = try await plain.start()
            servers = [plain]
        } catch {
            failure = "The port couldn’t open."
            return
        }
        guard let certificate = try? DevToolsCertificate() else { return }
        let secure = DevToolsServer(browser: self, allowedOrigins: origins, identity: certificate.identity)
        guard let securePoint = try? await secure.start() else { return }
        servers.append(secure)
        DevToolsPin.shared.pin(fingerprint: certificate.fingerprint, endpoint: securePoint, allowedOrigins: origins)
    }

    private func stop() {
        for server in servers { server.stop() }
        servers = []
        endpoint = nil
        DevToolsPin.shared.clear()
        DevToolsCertificate.remove()
    }

    // MARK: - Actions - Origins

    func allow(_ text: String) {
        guard let origin = URL(string: text.trimmingCharacters(in: .whitespaces))?.devToolsOrigin,
            !allowedOrigins.contains(origin)
        else { return }
        allowedOrigins.append(origin)
        restart()
    }

    func disallow(_ origin: String) {
        allowedOrigins.removeAll { $0 == origin }
        restart()
    }

    private func restart() {
        guard isOn else { return }
        stop()
        Task { await start() }
    }

    // MARK: - Actions - Browsing

    private func isProtected(_ url: URL) -> Bool {
        url.devToolsOrigin.map(allowedOrigins.contains) ?? false
    }

    /// The tabs a client may reach: those of unlocked Spaces in the person's
    /// own workspaces, which leave out private windows.
    private func reachableTabs() -> [(tab: TabStateModel, space: SpaceModel)] {
        let core = application.browser.core
        return core.state.workspaces.values.filter(\.kind.keepsAppPreferences).flatMap { workspace in
            workspace.spaces.models.filter { !application.spaceAccess.isLocked($0) }.flatMap { space in
                space.tabs.models.filter { $0.nativeContent == nil }.map { (tab: $0, space: space) }
            }
        }
    }

    private func reachable(_ id: String) -> (tab: TabStateModel, space: SpaceModel)? {
        guard let tabID = UUID(uuidString: id) else { return nil }
        return reachableTabs().first { $0.tab.id == tabID }
    }

    func targets() -> [DevToolsTarget] {
        reachableTabs().compactMap { tab, _ in
            guard let address = tab.url, let url = URL(string: address), !isProtected(url) else { return nil }
            return DevToolsTarget(id: tab.id.uuidString, title: tab.title, url: address)
        }
    }

    func attach(
        _ id: String, events: @escaping @MainActor (DevToolsPageEvent) -> Void
    ) async -> (any DevToolsPageSession)? {
        guard let reached = reachable(id),
            let page = application.pages.agentPage(for: reached.tab, in: reached.space)
        else { return nil }
        guard let webView = page.webKitView else {
            let isProtected: @MainActor (URL) -> Bool = { [weak self] url in self?.isProtected(url) ?? true }
            return EngineDevToolsPage(page: page.enginePage, isProtected: isProtected, events: events)
        }
        let document = WebKitDevToolsDocument.shared(
            for: webView, targetID: id, observesPage: true,
            host: WebKitDevToolsDocument.Host(
                navigate: { [weak page] url in page?.corePage.load(url) }, reload: { [weak page] in page?.reload() },
                stepHistory: { [weak page] offset in page?.corePage.stepHistory(by: offset) },
                isProtected: { [weak self] url in self?.isProtected(url) ?? true }))
        return WebKitDevToolsPage(document: document, events: events)
    }

    func openTarget(url: URL, inBackground: Bool) async -> String? {
        guard !isProtected(url), let space = application.browser.shownSpace, !application.spaceAccess.isLocked(space),
            let tabID = application.browser.openNewTab(url: url, in: space.id, selecting: !inBackground)
        else { return nil }
        return tabID.uuidString
    }

    func closeTarget(_ id: String) -> Bool {
        guard let reached = reachable(id) else { return false }
        return application.browser.closeTab(reached.tab.id, in: reached.space.id)
    }

    func activateTarget(_ id: String) -> Bool {
        guard let reached = reachable(id) else { return false }
        return application.browser.activateSessionTab(reached.tab.id, in: reached.space.id)
    }

    func releaseSessions() {
        WebKitDevToolsDocument.releaseAll()
    }
}
