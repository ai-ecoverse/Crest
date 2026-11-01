import Foundation
import Security
import XCTest

@testable import Crest

/// A vault's values must outlive Crest, stay within their Space and origin,
/// and never answer anyone but the vault.
final class BrowserVaultStoreTests: XCTestCase {
    private final class MemoryKeychain: SecurityCredentialKeychainClient, @unchecked Sendable {
        var items: [String: Data] = [:]

        func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, result: CFTypeRef?) {
            guard let data = items[query[kSecAttrAccount] as? String ?? ""] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data as CFData)
        }

        func update(_: [CFString: Any], attributes _: [CFString: Any]) -> OSStatus { errSecSuccess }

        func add(_ attributes: [CFString: Any]) -> OSStatus {
            items[attributes[kSecAttrAccount] as? String ?? ""] = attributes[kSecValueData] as? Data
            return errSecSuccess
        }

        func delete(_ query: [CFString: Any]) -> OSStatus {
            items[query[kSecAttrAccount] as? String ?? ""] = nil
            return errSecSuccess
        }
    }

    private var directory: URL!
    private let keychain = MemoryKeychain()
    private let vault = "https://vault.sliccy.ai"

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: BrowserVaultStore { BrowserVaultStore(directory: directory, keychain: keychain) }

    func testAValueOutlivesTheStoreThatWroteIt() throws {
        let profile = UUID()
        try store.set("sealed", for: "records", profileID: profile, origin: vault)
        XCTAssertEqual(try store.value(for: "records", profileID: profile, origin: vault), "sealed")
        XCTAssertEqual(try store.keys(profileID: profile, origin: vault), ["records"])
        try store.remove("records", profileID: profile, origin: vault)
        XCTAssertNil(try store.value(for: "records", profileID: profile, origin: vault))
    }

    func testValuesStayWithinTheirSpaceAndOrigin() throws {
        let profile = UUID()
        try store.set("sealed", for: "records", profileID: profile, origin: vault)
        XCTAssertNil(try store.value(for: "records", profileID: UUID(), origin: vault))
        XCTAssertNil(try store.value(for: "records", profileID: profile, origin: "https://other.example"))
    }

    func testValuesOnDiskAreSealed() throws {
        let profile = UUID()
        try store.set("recognisable-value", for: "records", profileID: profile, origin: vault)
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        let contents = try files.compactMap { name -> Data? in
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? nil : try Data(contentsOf: url)
        }
        XCTAssertFalse(contents.isEmpty)
        XCTAssertFalse(contents.contains { $0.range(of: Data("recognisable-value".utf8)) != nil })
    }

    func testAFileCantStandInForAnotherOrigin() throws {
        let profile = UUID()
        try store.set("sealed", for: "records", profileID: profile, origin: vault)
        let folder = directory.appendingPathComponent(profile.uuidString)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: folder.path).first)
        try store.set("other", for: "records", profileID: profile, origin: "https://other.example")
        let others = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != file }
        let other = try XCTUnwrap(others.first)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(other))
        try FileManager.default.copyItem(
            at: folder.appendingPathComponent(file), to: folder.appendingPathComponent(other))
        XCTAssertThrowsError(try store.value(for: "records", profileID: profile, origin: "https://other.example"))
    }

    func testDeletingASpaceForgetsItsValues() throws {
        let profile = UUID()
        try store.set("sealed", for: "records", profileID: profile, origin: vault)
        store.removeAll(profileID: profile)
        XCTAssertNil(try store.value(for: "records", profileID: profile, origin: vault))
        XCTAssertTrue(keychain.items.isEmpty)
    }

    func testAnOriginCantKeepUnlimitedData() {
        let big = String(repeating: "x", count: BrowserVaultStore.maximumBytes + 1)
        XCTAssertThrowsError(try store.set(big, for: "records", profileID: UUID(), origin: vault)) { error in
            XCTAssertEqual(error as? BrowserVaultStore.Failure, .tooLarge)
        }
    }

    func testOnlyAVaultFrameInAnAllowedPageGetsThrough() {
        let access = BrowserVaultAccess(embedders: ["https://seven.sliccy.ai"], vaults: [vault])
        XCTAssertTrue(access.allows(frame: vault, inPage: "https://seven.sliccy.ai"))
        XCTAssertFalse(access.allows(frame: "https://seven.sliccy.ai", inPage: "https://seven.sliccy.ai"))
        XCTAssertFalse(access.allows(frame: vault, inPage: "https://evil.example"))
        XCTAssertFalse(access.allows(frame: vault, inPage: nil))
        XCTAssertFalse(access.offers(toPage: "https://evil.example"))
    }
}
