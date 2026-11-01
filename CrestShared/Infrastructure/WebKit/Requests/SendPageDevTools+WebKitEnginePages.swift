import Foundation

extension SendPageDevTools {
    /// WebKit has no protocol of its own to pass through; its DevTools
    /// sessions are `WebKitDevToolsPage`.
    @MainActor func answer(on _: WebKitEnginePages) -> Answer {
        false
    }
}
