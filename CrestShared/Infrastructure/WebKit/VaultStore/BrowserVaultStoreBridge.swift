import Foundation
import WebKit

/// Who may reach a page's vault store: a frame of a vault origin, in a page of
/// an origin the person allowed. The page itself is no way in, since an agent
/// runs there and the vault exists to keep values from it.
struct BrowserVaultAccess: Equatable, Sendable {
    // MARK: - Static Variables

    private static let embeddersKey = "devTools.allowedOrigins"
    private static let vaultsKey = "devTools.vaultOrigins"
    private static let defaultEmbedders = ["https://seven.sliccy.ai"]
    private static let defaultVaults = ["https://vault.sliccy.ai"]

    /// What the person allowed, which stays on this device.
    static var current: Self {
        let defaults = UserDefaults.standard
        return Self(
            embedders: Set(defaults.stringArray(forKey: embeddersKey) ?? defaultEmbedders),
            vaults: Set(defaults.stringArray(forKey: vaultsKey) ?? defaultVaults))
    }

    // MARK: - Variables

    let embedders: Set<String>
    let vaults: Set<String>

    // MARK: - Actions - Access

    /// Whether a page at `pageOrigin` may see the store at all.
    func offers(toPage pageOrigin: String?) -> Bool {
        pageOrigin.map(embedders.contains) ?? false
    }

    /// Whether a frame at `frameOrigin`, in a page at `pageOrigin`, may use it.
    func allows(frame frameOrigin: String, inPage pageOrigin: String?) -> Bool {
        offers(toPage: pageOrigin) && vaults.contains(frameOrigin)
    }
}

/// `webkit.messageHandlers.crestVaultStore`, in the pages of an allowed origin.
/// What a message claims says nothing about who sent it, so every call is
/// judged by the origin WebKit reports for the sending frame.
@MainActor
final class BrowserVaultStoreBridge: NSObject, WKScriptMessageHandlerWithReply {
    // MARK: - Types

    private struct Call: Decodable {
        let op: String
        let key: String?
        let value: String?
    }

    // MARK: - Static Variables

    static let name = "crestVaultStore"
    private static let denied = "EACCES"
    private static let invalid = "EINVAL"
    private static let unavailable = "EIO"

    // MARK: - Variables

    private let store: BrowserVaultStore
    private let profileID: UUID

    // MARK: - Initializers

    init(profileID: UUID, store: BrowserVaultStore = BrowserVaultStore()) {
        self.profileID = profileID
        self.store = store
    }

    // MARK: - Actions - Messages

    func userContentController(
        _: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let sender = message.frameInfo.securityOrigin
        let scheme = sender.protocol
        let origin = sender.port == 0 ? "\(scheme)://\(sender.host)" : "\(scheme)://\(sender.host):\(sender.port)"
        guard message.world === WKContentWorld.page,
            BrowserVaultAccess.current.allows(frame: origin, inPage: message.webView?.url?.devToolsOrigin)
        else { return (nil, Self.denied) }
        guard let body = message.body as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: body),
            let call = try? JSONDecoder().decode(Call.self, from: data)
        else { return (nil, Self.invalid) }
        return answer(call, origin: origin)
    }

    private func answer(_ call: Call, origin: String) -> (Any?, String?) {
        do {
            switch (call.op, call.key, call.value) {
            case ("get", let key?, nil):
                return (try store.value(for: key, profileID: profileID, origin: origin) ?? NSNull(), nil)
            case ("put", let key?, let value?):
                try store.set(value, for: key, profileID: profileID, origin: origin)
                return (true, nil)
            case ("delete", let key?, nil):
                try store.remove(key, profileID: profileID, origin: origin)
                return (true, nil)
            case ("list", nil, nil):
                return (try store.keys(profileID: profileID, origin: origin), nil)
            default:
                return (nil, Self.invalid)
            }
        } catch {
            return (nil, Self.unavailable)
        }
    }
}
