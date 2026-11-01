import CryptoKit
import Foundation
import Security

/// Durable storage for a web vault that WebKit won't keep. WebKit holds a
/// cross-origin frame's storage in memory, so a vault embedded by another
/// origin loses everything when Crest quits. Each Space's entries for an origin
/// stay in a file sealed with a key in the device-only Keychain: a Keychain item
/// suits a key, not the data a vault keeps, and the file means nothing without
/// it. One Space never reads another's, as with everything else it stores.
struct BrowserVaultStore: Sendable {
    // MARK: - Types

    enum Failure: Error, Equatable {
        case keychain(OSStatus)
        case tooLarge
        case unreadable
    }

    // MARK: - Static Variables

    /// The most an origin keeps in a Space, across all its entries.
    static let maximumBytes = 16 * 1024 * 1024
    private static let service = "com.pauldavis.crest.vault-store"

    // MARK: - Variables

    private let directory: URL
    private let keychain: any SecurityCredentialKeychainClient

    // MARK: - Initializers

    init(
        directory: URL = URL.applicationSupportDirectory.appendingPathComponent("VaultStore", isDirectory: true),
        keychain: any SecurityCredentialKeychainClient = SystemSecurityCredentialKeychainClient()
    ) {
        self.directory = directory
        self.keychain = keychain
    }

    // MARK: - Actions - Entries

    func value(for key: String, profileID: UUID, origin: String) throws(Failure) -> String? {
        try entries(profileID: profileID, origin: origin)[key]
    }

    func keys(profileID: UUID, origin: String) throws(Failure) -> [String] {
        try entries(profileID: profileID, origin: origin).keys.sorted()
    }

    func set(_ value: String, for key: String, profileID: UUID, origin: String) throws(Failure) {
        var entries = try entries(profileID: profileID, origin: origin)
        entries[key] = value
        try write(entries, profileID: profileID, origin: origin)
    }

    func remove(_ key: String, profileID: UUID, origin: String) throws(Failure) {
        var entries = try entries(profileID: profileID, origin: origin)
        guard entries.removeValue(forKey: key) != nil else { return }
        try write(entries, profileID: profileID, origin: origin)
    }

    /// Forgets everything a Space kept, with the key that sealed it.
    func removeAll(profileID: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(profileID.uuidString))
        _ = keychain.delete(keyQuery(profileID: profileID))
    }

    // MARK: - Actions - Files

    private func file(profileID: UUID, origin: String) -> URL {
        let name = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(profileID.uuidString).appendingPathComponent(name)
    }

    /// Binds a sealed file to its Space and origin, so one can't stand in for
    /// another.
    private static func context(profileID: UUID, origin: String) -> Data {
        Data("crest-vault-store/1\0\(profileID.uuidString)\0\(origin)".utf8)
    }

    private func entries(profileID: UUID, origin: String) throws(Failure) -> [String: String] {
        guard let sealed = try? Data(contentsOf: file(profileID: profileID, origin: origin)) else { return [:] }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plain = try AES.GCM.open(
                box, using: try key(profileID: profileID),
                authenticating: Self.context(profileID: profileID, origin: origin))
            return try JSONDecoder().decode([String: String].self, from: plain)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .unreadable
        }
    }

    private func write(_ entries: [String: String], profileID: UUID, origin: String) throws(Failure) {
        let destination = file(profileID: profileID, origin: origin)
        do {
            let plain = try JSONEncoder().encode(entries)
            guard plain.count <= Self.maximumBytes else { throw Failure.tooLarge }
            let sealed = try AES.GCM.seal(
                plain, using: try key(profileID: profileID),
                authenticating: Self.context(profileID: profileID, origin: origin))
            guard let combined = sealed.combined else { throw Failure.unreadable }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try combined.write(
                to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = destination
            try excluded.setResourceValues(values)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .unreadable
        }
    }

    // MARK: - Actions - Key

    private func keyQuery(profileID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: profileID.uuidString,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    private func key(profileID: UUID) throws(Failure) -> SymmetricKey {
        var query = keyQuery(profileID: profileID)
        query[kSecReturnData] = true
        let found = keychain.copyMatching(query)
        if found.status == errSecSuccess, let data = found.result as? Data { return SymmetricKey(data: data) }
        guard found.status == errSecItemNotFound else { throw .keychain(found.status) }

        let key = SymmetricKey(size: .bits256)
        var item = keyQuery(profileID: profileID)
        item[kSecValueData] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable] = false
        let added = keychain.add(item)
        guard added == errSecSuccess else { throw .keychain(added) }
        return key
    }
}
