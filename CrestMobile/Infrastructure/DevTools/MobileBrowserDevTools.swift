import Observation
import UIKit
import WebKit

/// The DevTools port on iPhone and iPad: what it exposes, and its life. A page
/// of an allowed origin drives other tabs through it, so it serves that page
/// over TLS. It is off at every launch: it hands whoever holds the token the
/// logged-in sessions of the Spaces on screen, so it lasts only as long as the
/// person keeps it on. What it never shows: a private window, a locked Space, a
/// Space no window shows, and pages of an allowed origin, which are the
/// clients' own.
@Observable
@MainActor
final class MobileBrowserDevTools: DevToolsBrowsing {
    // MARK: - Static Variables

    private static let allowedOriginsKey = "devTools.allowedOrigins"
    private static let defaultOrigins = ["https://seven.sliccy.ai"]
    /// How often pages a client depends on are put back in a window.
    private static let parkingInterval: Duration = .seconds(1)

    // MARK: - Variables

    /// Where the port answers, while it is on.
    private(set) var endpoint: DevToolsEndpoint?
    /// Why the port couldn't open.
    private(set) var failure: LocalizedStringResource?
    /// The origins whose pages may connect, each `scheme://host[:port]`, which
    /// stay on this device.
    private(set) var allowedOrigins: [String] {
        didSet { UserDefaults.standard.set(allowedOrigins, forKey: Self.allowedOriginsKey) }
    }

    @ObservationIgnored private let stores: MobileBrowserPageStoreRegistry
    @ObservationIgnored private let spaceAccess: BrowserSpaceAccessController
    @ObservationIgnored private var server: DevToolsServer?
    @ObservationIgnored private var parking: Task<Void, Never>?
    @ObservationIgnored private let parkingLot = MobileDevToolsParkingLot()
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    #if DEBUG
        @ObservationIgnored private var exposesClients = false
    #endif

    var isOn: Bool { endpoint != nil }

    let product = "Crest (WebKit)"
    var userAgent: String { BrowserPlatformUserAgent.applicationName ?? "" }

    // MARK: - Initializers

    init(stores: MobileBrowserPageStoreRegistry, spaceAccess: BrowserSpaceAccessController) {
        self.stores = stores
        self.spaceAccess = spaceAccess
        allowedOrigins = UserDefaults.standard.stringArray(forKey: Self.allowedOriginsKey) ?? Self.defaultOrigins
        #if DEBUG
            startForValidation()
        #endif
    }

    #if DEBUG
        /// Opens the port at launch for a validation run, which has no way to
        /// tap the toggle: `CREST_DEVTOOLS_PORT=tls` or `plain`, with plain
        /// reachable by a native client on the Simulator's shared loopback, and
        /// `CREST_DEVTOOLS_ORIGINS` listing origins, comma separated. The
        /// endpoint lands in `tmp/crest-devtools-endpoint` in the app's container.
        /// `CREST_DEVTOOLS_OPEN` opens a tab at launch, as the person would, and
        /// `CREST_DEVTOOLS_EXPOSE_CLIENTS` lets a client inspect allowed origins'
        /// own pages, to watch a page that is itself a client boot.
        /// `CREST_DEVTOOLS_VAULT_ORIGINS` lists the origins the vault store
        /// answers, for a vault on a preview.
        private func startForValidation() {
            let environment = ProcessInfo.processInfo.environment
            guard let mode = environment["CREST_DEVTOOLS_PORT"] else { return }
            if let origins = environment["CREST_DEVTOOLS_ORIGINS"] {
                allowedOrigins = origins.split(separator: ",").map(String.init)
            }
            exposesClients = environment["CREST_DEVTOOLS_EXPOSE_CLIENTS"] != nil
            if let vaults = environment["CREST_DEVTOOLS_VAULT_ORIGINS"] {
                UserDefaults.standard.set(
                    vaults.split(separator: ",").map(String.init), forKey: "devTools.vaultOrigins")
            }
            Task {
                await start(usesTLS: mode != "plain")
                guard let endpoint else { return }
                try? endpoint.discoveryURL.write(
                    to: FileManager.default.temporaryDirectory.appendingPathComponent("crest-devtools-endpoint"),
                    atomically: true, encoding: .utf8)
                guard let address = environment["CREST_DEVTOOLS_OPEN"], let url = URL(string: address) else { return }
                for _ in 0..<40 {
                    if let store = stores.liveStores.last(where: { !$0.isPrivateBrowsing }),
                        let space = store.browser.shownSpace,
                        store.browser.openNewTab(url: url, in: space.id, selecting: true) != nil
                    {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    #endif

    // MARK: - Actions - Lifecycle

    func setOn(_ isOn: Bool) {
        if isOn {
            Task { await start() }
        } else {
            stop()
        }
    }

    private func start(usesTLS: Bool = true) async {
        guard server == nil else { return }
        failure = nil
        do {
            let certificate = usesTLS ? try DevToolsCertificate() : nil
            let server = DevToolsServer(
                browser: self, allowedOrigins: Set(allowedOrigins), identity: certificate?.identity)
            let endpoint = try await server.start()
            self.server = server
            self.endpoint = endpoint
            DevToolsPin.shared.pin(
                fingerprint: certificate?.fingerprint, endpoint: endpoint, allowedOrigins: Set(allowedOrigins))
            offerEndpoint()
            startParking()
            observeActivation()
        } catch {
            DevToolsCertificate.remove()
            failure = "The port couldn’t open."
        }
    }

    private func stop() {
        parking?.cancel()
        parking = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        server?.stop()
        server = nil
        endpoint = nil
        DevToolsPin.shared.clear()
        DevToolsCertificate.remove()
        parkingLot.empty()
    }

    /// iOS takes a listening socket away from a suspended app, so the port
    /// reopens when Crest comes back, with a new token.
    private func observeActivation() {
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.reopen() }
        }
    }

    private func reopen() async {
        guard server != nil else { return }
        stop()
        await start()
    }

    // MARK: - Actions - Origins

    func allow(_ text: String) {
        guard let origin = URL(string: text.trimmingCharacters(in: .whitespaces))?.devToolsOrigin,
            !allowedOrigins.contains(origin)
        else { return }
        allowedOrigins.append(origin)
        Task { await reopen() }
    }

    func disallow(_ origin: String) {
        allowedOrigins.removeAll { $0 == origin }
        Task { await reopen() }
    }

    /// Tells open pages of an allowed origin where the port is.
    private func offerEndpoint() {
        for page in stores.liveStores.flatMap(\.residentPages) {
            guard let script = DevToolsPin.shared.clientScript(for: page.webView.url) else { continue }
            page.webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: - Actions - Keeping pages running

    /// iOS suspends a web view no window holds. An agent lives in one tab and
    /// works in others, and on a phone only one is on screen, so while the
    /// port is on every page involved stays in a window, behind the browser.
    private func startParking() {
        parking = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.parkPages()
                try? await Task.sleep(for: Self.parkingInterval)
            }
        }
    }

    private func parkPages() {
        let involved = stores.liveStores.filter { !$0.isPrivateBrowsing }.flatMap(\.residentPages).filter { page in
            DevToolsPin.shared.clientScript(for: page.webView.url) != nil
                || WebKitDevToolsDocument.isTouched(page.webView)
        }
        parkingLot.park(involved.map(\.webView))
    }

    // MARK: - Actions - Browsing

    private func isProtected(_ url: URL) -> Bool {
        #if DEBUG
            if exposesClients { return false }
        #endif
        return url.devToolsOrigin.map(allowedOrigins.contains) ?? false
    }

    /// The tabs a client may reach, each with its window's store. A window
    /// over a Space the primary store also shows owns that Space's pages, so
    /// its store answers: a tab has one page, however many stores list it.
    private func reachableTabs() -> [(tab: TabStateModel, store: MobileBrowserPageStore, space: SpaceModel)] {
        var seen: Set<UUID> = []
        var reachable: [(tab: TabStateModel, store: MobileBrowserPageStore, space: SpaceModel)] = []
        for store in stores.liveStores.reversed() where !store.isPrivateBrowsing {
            guard let space = store.browser.shownSpace, !spaceAccess.isLocked(space) else { continue }
            for tab in space.tabs.models where tab.nativeContent == nil && seen.insert(tab.id).inserted {
                reachable.append((tab: tab, store: store, space: space))
            }
        }
        return reachable
    }

    func targets() -> [DevToolsTarget] {
        reachableTabs().compactMap { tab, _, _ in
            guard let address = tab.url, let url = URL(string: address), !isProtected(url) else { return nil }
            return DevToolsTarget(id: tab.id.uuidString, title: tab.title, url: address)
        }
    }

    private func reachable(_ id: String) -> (tab: TabStateModel, store: MobileBrowserPageStore, space: SpaceModel)? {
        guard let tabID = UUID(uuidString: id) else { return nil }
        return reachableTabs().first { $0.tab.id == tabID }
    }

    func attach(
        _ id: String, events: @escaping @MainActor (DevToolsPageEvent) -> Void
    ) async -> (any DevToolsPageSession)? {
        guard let reached = reachable(id), let page = reached.store.prepareResidentPage(for: reached.tab.id) else {
            return nil
        }
        if let url = page.webView.url, isProtected(url) { return nil }
        let document = WebKitDevToolsDocument.shared(
            for: page.webView, targetID: id, observesPage: page.webKitPage.ownsUserContentController,
            host: WebKitDevToolsDocument.Host(
                navigate: { [weak page] url in page?.corePage.load(url) }, reload: { [weak page] in page?.reload() },
                stepHistory: { [weak page] offset in page?.corePage.stepHistory(by: offset) },
                isProtected: { [weak self] url in self?.isProtected(url) ?? true }))
        parkPages()
        await WebKitDevToolsDocument.awaitFirstDocument(
            in: page.webView, expected: reached.tab.url.flatMap(URL.init(string:)))
        return WebKitDevToolsPage(document: document, events: events)
    }

    /// Opens behind what the person is looking at: on a phone, the client's
    /// own page is what's on screen, and it asks to bring a tab forward when
    /// it needs to.
    func openTarget(url: URL, inBackground _: Bool) async -> String? {
        guard !isProtected(url), let store = stores.liveStores.last(where: { !$0.isPrivateBrowsing }),
            let space = store.browser.shownSpace, !spaceAccess.isLocked(space),
            let tabID = store.browser.openNewTab(url: url, in: space.id, selecting: false)
        else { return nil }
        return tabID.uuidString
    }

    func closeTarget(_ id: String) -> Bool {
        guard let reached = reachable(id) else { return false }
        return reached.store.browser.closeTab(reached.tab.id, in: reached.space.id)
    }

    func activateTarget(_ id: String) -> Bool {
        guard let reached = reachable(id) else { return false }
        return reached.store.browser.activateSessionTab(reached.tab.id, in: reached.space.id)
    }

    func releaseSessions() {
        WebKitDevToolsDocument.releaseAll()
    }
}

// MARK: - Parking lot

/// Holds web views behind the browser, in a window, where iOS keeps them
/// running and rendering. A page's own card takes its web view back by adding
/// it to itself.
@MainActor
private final class MobileDevToolsParkingLot {
    private var view: UIView?

    func park(_ webViews: [WKWebView]) {
        guard let lot = lot() else { return }
        for webView in webViews where webView.window == nil {
            webView.frame = lot.bounds
            lot.addSubview(webView)
        }
    }

    func empty() {
        for parked in view?.subviews ?? [] { parked.removeFromSuperview() }
        view?.removeFromSuperview()
        view = nil
    }

    private func lot() -> UIView? {
        if let view, view.window != nil { return view }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first else {
            return nil
        }
        let lot = UIView(frame: window.bounds)
        lot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        lot.isUserInteractionEnabled = false
        lot.alpha = 0.01
        lot.accessibilityElementsHidden = true
        window.insertSubview(lot, at: 0)
        view = lot
        return lot
    }
}
