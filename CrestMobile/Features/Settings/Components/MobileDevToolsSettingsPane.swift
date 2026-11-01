import SwiftUI

/// Turns on the DevTools port, and says which websites may use it.
struct MobileDevToolsSettingsPane: View {
    @Environment(MobileBrowserDevTools.self) private var devTools
    @State private var newOrigin = ""

    var body: some View {
        Section {
            Toggle("DevTools Port", isOn: Binding(get: { devTools.isOn }, set: devTools.setOn))
            if let endpoint = devTools.endpoint {
                LabeledContent("Port", value: String(endpoint.port))
            }
            if let failure = devTools.failure {
                Text(failure).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Allowed websites can control your open tabs, with your logins, until you turn this off.")
        }
        Section("Allowed Websites") {
            ForEach(devTools.allowedOrigins, id: \.self) { origin in
                Text(origin)
            }
            .onDelete { offsets in
                offsets.map { devTools.allowedOrigins[$0] }.forEach(devTools.disallow)
            }
            TextField("https://example.com", text: $newOrigin)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit {
                    devTools.allow(newOrigin)
                    newOrigin = ""
                }
        }
    }
}
