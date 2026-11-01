import Foundation

/// A command the server could not carry out, as the protocol reports it.
struct DevToolsFailure: Error, Equatable, Sendable {
    // MARK: - Static Variables

    static let invalidRequest = Self(code: -32600, message: "Invalid request")
    static let noSession = Self(code: -32001, message: "Session not found")
    static let noTarget = Self(code: -32000, message: "No target with given id found")
    static let pageGone = Self(code: -32000, message: "The page went away")
    /// A target the person's Spaces or the connected client's own origin keep
    /// out of reach.
    static let refusedTarget = Self(code: -32000, message: "This target is out of reach")

    // MARK: - Variables

    let code: Int
    let message: String
    /// What a client can act on, in the protocol's `error.data`.
    let data: String?

    // MARK: - Initializers

    init(code: Int = -32000, message: String, data: String? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // MARK: - Actions - Failures

    static func unknownMethod(_ method: String) -> Self {
        Self(code: -32601, message: "'\(method)' wasn't found")
    }

    static func invalidParameters(_ method: String) -> Self {
        Self(code: -32602, message: "Invalid parameters for \(method)")
    }

    static func unsupported(_ method: String, _ reason: String, data: String? = nil) -> Self {
        Self(code: -32000, message: "\(method) isn't available on WebKit: \(reason)", data: data)
    }

    // MARK: - Actions - Encoding

    /// The `error` member of a reply.
    var value: DevToolsValue {
        var members: [String: DevToolsValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { members["data"] = .string(data) }
        return .object(members)
    }
}
