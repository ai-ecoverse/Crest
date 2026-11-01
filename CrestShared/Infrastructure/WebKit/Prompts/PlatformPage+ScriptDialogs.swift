import Foundation
import WebKit

/// The alerts, confirmations and prompts a page's script opens, asked through
/// the core.
extension BrowserPlatformPage {
    /// Asks the core the script dialog `frame`'s document opened, which this
    /// page shows once the core asks the person. A page WebKit's binding did
    /// not build has no one to ask, and declines.
    func askScriptDialog(
        _ kind: JavaScriptDialogKind, message: String, defaultText: String?, frame: WKFrameInfo,
        answer: @escaping @MainActor (Bool, String?) -> Void
    ) {
        if let webView = webKitView, WebKitDevToolsDocument.answersDialogs(in: webView) {
            Task { @MainActor in
                let reply = await WebKitDevToolsDocument.askClient(
                    type: String(describing: kind), message: message, defaultText: defaultText, in: webView)
                answer(reply.accepted, reply.text)
            }
            return
        }
        guard let webKitPage = webKitEnginePage else { return answer(false, nil) }
        webKitPage.ask(
            ScriptDialogQuestion(
                kind: kind, message: message, defaultText: defaultText ?? "",
                sourceURL: frame.request.url?.absoluteString ?? ""),
            answer: answer)
    }
}
