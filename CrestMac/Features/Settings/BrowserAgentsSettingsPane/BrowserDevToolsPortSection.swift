import AppKit
import SwiftUI

/// Turns on the DevTools port, says how to reach it, and which websites may.
struct BrowserDevToolsPortSection: View {
    @Environment(BrowserMacDevTools.self) private var devTools
    @State private var newOrigin = ""

    var body: some View {
        Section {
            Toggle("DevTools Port", isOn: Binding(get: { devTools.isOn }, set: devTools.setOn))
            if let endpoint = devTools.endpoint {
                HStack {
                    Text(verbatim: endpoint.discoveryURL).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(endpoint.discoveryURL, forType: .string)
                    }
                }
            }
            if let failure = devTools.failure {
                Text(failure).foregroundStyle(.secondary)
            }
        } footer: {
            CrestFormFootnote(
                "Anything with this address, and allowed websites, can control your tabs, with your logins, until you turn this off."
            )
        }
        Section("Allowed Websites") {
            ForEach(devTools.allowedOrigins, id: \.self) { origin in
                HStack {
                    Text(verbatim: origin)
                    Spacer()
                    Button("Remove") { devTools.disallow(origin) }
                }
            }
            TextField("https://example.com", text: $newOrigin)
                .onSubmit {
                    devTools.allow(newOrigin)
                    newOrigin = ""
                }
        }
    }
}
