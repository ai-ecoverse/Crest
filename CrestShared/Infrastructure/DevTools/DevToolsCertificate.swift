import CryptoKit
import Foundation
import Security

/// The certificate a DevTools server for `WKWebView` pages speaks TLS with.
/// WebKit refuses `http` and `ws` to loopback from an `https` page, and accepts
/// `https` and `wss` once the page's navigation delegate trusts the server.
/// Security has no way to make a certificate, so this writes a self-signed one
/// for loopback, new each time the port opens. The key lives in the Keychain
/// only while the port is open, because a `SecIdentity` must come from there.
struct DevToolsCertificate {
    // MARK: - Types

    enum Failure: Error, Equatable {
        case keyGeneration
        case signing
        case keychain(OSStatus)
    }

    // MARK: - Static Variables

    private static let label = "ai.crest.devtools.loopback"
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Variables

    let identity: SecIdentity
    /// The SHA-256 of the certificate, which is all a page trusts.
    let fingerprint: Data

    // MARK: - Initializers

    /// Makes a new key and certificate, replacing any an earlier launch left.
    init(now: Date = .now) throws(Failure) {
        Self.remove()
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
            let publicKey = SecKeyCopyPublicKey(key),
            let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw .keyGeneration }

        let body = Self.certificateBody(point: point, now: now)
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, body as CFData, &error)
                as Data?
        else { throw .signing }
        let der = Self.sequence(body + Self.signatureAlgorithm + Self.bitString(signature))
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw .signing }

        identity = try Self.store(key: key, certificate: certificate)
        fingerprint = Data(SHA256.hash(data: der))
    }

    // MARK: - Actions - Keychain

    /// Takes the key and certificate out of the Keychain.
    static func remove() {
        for itemClass in [kSecClassKey, kSecClassCertificate] {
            var query = baseQuery
            query[kSecClass as String] = itemClass
            query[kSecAttrLabel as String] = label
            SecItemDelete(query as CFDictionary)
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecUseDataProtectionKeychain as String: true]
    }

    private static func store(key: SecKey, certificate: SecCertificate) throws(Failure) -> SecIdentity {
        var keyItem = baseQuery
        keyItem[kSecClass as String] = kSecClassKey
        keyItem[kSecValueRef as String] = key
        keyItem[kSecAttrLabel as String] = label
        keyItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(keyItem as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status) }

        var certificateItem = baseQuery
        certificateItem[kSecClass as String] = kSecClassCertificate
        certificateItem[kSecValueRef as String] = certificate
        certificateItem[kSecAttrLabel as String] = label
        status = SecItemAdd(certificateItem as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status) }

        var query = baseQuery
        query[kSecClass as String] = kSecClassIdentity
        query[kSecAttrLabel as String] = label
        query[kSecReturnRef as String] = true
        var found: CFTypeRef?
        status = SecItemCopyMatching(query as CFDictionary, &found)
        guard status == errSecSuccess, let found else { throw .keychain(status) }
        // Security answers this class with this type alone.
        // swift-format-ignore: NeverForceUnwrap
        return found as! SecIdentity
    }

    // MARK: - Actions - Encoding

    /// A TBSCertificate: X.509 v3, self-issued, for `127.0.0.1` and
    /// `localhost`, for server authentication.
    private static func certificateBody(point: Data, now: Date) -> Data {
        var serial = Data(UUID().uuidString.utf8.prefix(16))
        serial[serial.startIndex] &= 0x7F
        let name = sequence(set(sequence(oid([0x55, 0x04, 0x03]) + tagged(0x0C, Data("Crest DevTools".utf8)))))
        let validity = sequence(time(now.addingTimeInterval(-3600)) + time(now.addingTimeInterval(lifetime)))
        let publicKeyInfo = sequence(
            sequence(
                oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
                    + oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])) + bitString(point))
        let addresses = sequence(tagged(0x87, Data([127, 0, 0, 1])) + tagged(0x82, Data("localhost".utf8)))
        let extensions = tagged(
            0xA3,
            sequence(
                sequence(oid([0x55, 0x1D, 0x11]) + tagged(0x04, addresses))
                    + sequence(
                        oid([0x55, 0x1D, 0x25])
                            + tagged(
                                0x04, sequence(oid([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]))))))
        return sequence(
            tagged(0xA0, tagged(0x02, Data([2]))) + tagged(0x02, serial) + signatureAlgorithm + name + validity + name
                + publicKeyInfo + extensions)
    }

    /// ecdsa-with-SHA256.
    private static let signatureAlgorithm = sequence(oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))

    private static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(formatter.string(from: date).utf8))
    }

    private static func oid(_ bytes: [UInt8]) -> Data {
        tagged(0x06, Data(bytes))
    }

    private static func bitString(_ bytes: Data) -> Data {
        tagged(0x03, Data([0]) + bytes)
    }

    private static func set(_ bytes: Data) -> Data {
        tagged(0x31, bytes)
    }

    private static func sequence(_ bytes: Data) -> Data {
        tagged(0x30, bytes)
    }

    private static func tagged(_ tag: UInt8, _ bytes: Data) -> Data {
        var encoded = Data([tag])
        if bytes.count < 128 {
            encoded.append(UInt8(bytes.count))
        } else {
            let length = withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init).drop { $0 == 0 }
            encoded.append(0x80 | UInt8(length.count))
            encoded.append(contentsOf: length)
        }
        encoded.append(bytes)
        return encoded
    }
}
