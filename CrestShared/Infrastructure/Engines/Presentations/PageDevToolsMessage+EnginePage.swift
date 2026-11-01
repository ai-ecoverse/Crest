import Foundation

extension PageDevToolsMessage {
    @MainActor func deliver(to page: EnginePage) {
        page.devToolsSessions[sessionID]?.take(message)
    }
}

extension PageDevToolsClosed {
    @MainActor func deliver(to page: EnginePage) {
        page.devToolsSessions[sessionID]?.engineClosed()
    }
}
