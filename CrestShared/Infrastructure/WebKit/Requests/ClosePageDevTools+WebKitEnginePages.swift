import Foundation

extension ClosePageDevTools {
    /// WebKit has no protocol of its own to pass through; its DevTools
    /// sessions are `WebKitDevToolsPage`.
    @MainActor func answer(on _: WebKitEnginePages) -> Answer {
        false
    }
}
