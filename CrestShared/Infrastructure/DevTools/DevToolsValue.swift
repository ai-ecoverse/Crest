import Foundation

/// A JSON value as the DevTools protocol carries it. Commands pass through the
/// server as these until the page that answers them decodes what it needs.
enum DevToolsValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    // MARK: - Static Variables

    private static let largestExactInteger = 9_007_199_254_740_992.0

    // MARK: - Initializers

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }

    /// `value` as JSON, for a typed result.
    init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    // MARK: - Actions - Reading

    /// The member `key` of an object.
    subscript(key: String) -> Self? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// This value as `Value`, for a command's typed parameters.
    func decoded<Value: Decodable>(as _: Value.Type) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(self))
    }

    // MARK: - Actions - Encoding

    /// Writes numbers without a fraction as integers, which clients read as
    /// ids; a JSON encoder would write `1.0`.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < Self.largestExactInteger {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// This value as UTF-8 JSON text.
    func text() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
