import Foundation

/// The WebSocket framing a DevTools client speaks, as RFC 6455 defines it for
/// a server: frames arrive masked and leave unmasked. Network.framework's own
/// WebSocket protocol can't share a listener with the HTTP discovery routes
/// clients read first, so the server frames its messages itself.
struct DevToolsWebSocket: Sendable {
    // MARK: - Types

    /// What a client sent, whole.
    enum Message: Equatable, Sendable {
        case text(String)
        case ping(Data)
        case close
    }

    enum Failure: Error, Equatable {
        case unmaskedFrame
        case tooLarge
        case malformed
    }

    private enum Opcode: UInt8 {
        case continuation = 0
        case text = 1
        case binary = 2
        case close = 8
        case ping = 9
        case pong = 10
    }

    // MARK: - Static Variables

    /// The largest message either side passes, as slicc's relay caps it.
    static let maximumMessageBytes = 64 * 1024 * 1024
    private static let acceptSuffix = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    // MARK: - Variables

    private var buffer = Data()
    private var assembling = Data()
    private var isAssembling = false

    // MARK: - Actions - Handshake

    /// The `Sec-WebSocket-Accept` answer to a client's `key`.
    static func acceptance(for key: String, hash: (Data) -> Data) -> String {
        hash(Data((key + acceptSuffix).utf8)).base64EncodedString()
    }

    // MARK: - Actions - Encoding

    /// `text` as one unmasked frame.
    static func frame(text: String) -> Data {
        frame(.text, Data(text.utf8))
    }

    static func pong(_ payload: Data) -> Data {
        frame(.pong, payload)
    }

    static var closeFrame: Data {
        frame(.close, Data([0x03, 0xE8]))
    }

    private static func frame(_ opcode: Opcode, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        switch payload.count {
        case ..<126:
            frame.append(UInt8(payload.count))
        case ..<65536:
            frame.append(126)
            frame.append(contentsOf: withUnsafeBytes(of: UInt16(payload.count).bigEndian, Array.init))
        default:
            frame.append(127)
            frame.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init))
        }
        frame.append(payload)
        return frame
    }

    // MARK: - Mutators

    /// Takes `data` from the socket and answers the messages it completes.
    mutating func receive(_ data: Data) throws(Failure) -> [Message] {
        buffer.append(data)
        var messages: [Message] = []
        while let message = try nextFrame() {
            if let message { messages.append(message) }
        }
        return messages
    }

    /// The next whole frame in the buffer: nil when none is whole yet, and an
    /// inner nil for one that completes no message.
    private mutating func nextFrame() throws(Failure) -> Message?? {
        let bytes = buffer
        let start = bytes.startIndex
        guard bytes.count >= 2 else { return nil }
        let head = bytes[start]
        let second = bytes[start + 1]
        guard second & 0x80 != 0 else { throw .unmaskedFrame }
        guard let opcode = Opcode(rawValue: head & 0x0F) else { throw .malformed }
        var cursor = 2
        var length = Int(second & 0x7F)
        if length == 126 {
            guard bytes.count >= cursor + 2 else { return nil }
            length = bytes[(start + 2)..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
            cursor += 2
        } else if length == 127 {
            guard bytes.count >= cursor + 8 else { return nil }
            let wide = bytes[(start + 2)..<(start + 10)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard wide <= UInt64(Self.maximumMessageBytes) else { throw .tooLarge }
            length = Int(wide)
            cursor += 8
        }
        guard length <= Self.maximumMessageBytes else { throw .tooLarge }
        guard bytes.count >= cursor + 4 + length else { return nil }
        let mask = Array(bytes[(start + cursor)..<(start + cursor + 4)])
        cursor += 4
        var payload = Data(bytes[(start + cursor)..<(start + cursor + length)])
        for index in payload.indices {
            payload[index] ^= mask[(index - payload.startIndex) % 4]
        }
        buffer = Data(bytes[(start + cursor + length)...])
        return .some(try complete(opcode, payload, isFinal: head & 0x80 != 0))
    }

    private mutating func complete(
        _ opcode: Opcode, _ payload: Data, isFinal: Bool
    ) throws(Failure) -> Message? {
        switch opcode {
        case .ping: return .ping(payload)
        case .pong: return nil
        case .close: return .close
        case .binary: throw .malformed
        case .text, .continuation:
            guard (opcode == .continuation) == isAssembling else { throw .malformed }
            guard assembling.count + payload.count <= Self.maximumMessageBytes else { throw .tooLarge }
            assembling.append(payload)
            isAssembling = !isFinal
            guard isFinal else { return nil }
            defer { assembling = Data() }
            guard let text = String(data: assembling, encoding: .utf8) else { throw .malformed }
            return .text(text)
        }
    }
}
