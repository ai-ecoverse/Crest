import Foundation
import XCTest

@testable import Crest

/// Clients decide what a cookie reaches from what the port says, so these
/// follow the rules a server's own request does.
final class WebKitDevToolsCookieScopeTests: XCTestCase {
    private func cookie(domain: String, path: String = "/", secure: Bool = false) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: "a", .value: "b", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    private func applies(_ cookie: HTTPCookie, _ address: String) throws -> Bool {
        WebKitDevToolsCookieScope.applies(cookie, to: try XCTUnwrap(URL(string: address)))
    }

    func testAHostOnlyCookieStaysOnItsHost() throws {
        let cookie = try cookie(domain: "example.com")
        XCTAssertTrue(try applies(cookie, "https://example.com/"))
        XCTAssertFalse(try applies(cookie, "https://sub.example.com/"))
    }

    func testADomainCookieCoversSubdomainsButNotLookalikes() throws {
        let cookie = try cookie(domain: ".example.com")
        XCTAssertTrue(try applies(cookie, "https://example.com/"))
        XCTAssertTrue(try applies(cookie, "https://sub.example.com/"))
        XCTAssertFalse(try applies(cookie, "https://notexample.com/"))
    }

    func testPathsMatchOnTheirSeparators() throws {
        let cookie = try cookie(domain: "example.com", path: "/foo")
        XCTAssertTrue(try applies(cookie, "https://example.com/foo"))
        XCTAssertTrue(try applies(cookie, "https://example.com/foo/bar"))
        XCTAssertFalse(try applies(cookie, "https://example.com/foobar"))
        XCTAssertFalse(try applies(cookie, "https://example.com/"))
    }

    func testASecureCookieNeedsASecureAddress() throws {
        let cookie = try cookie(domain: "example.com", secure: true)
        XCTAssertTrue(try applies(cookie, "https://example.com/"))
        XCTAssertFalse(try applies(cookie, "http://example.com/"))
    }

    func testAWriteWithoutAPathTakesTheAddressesDirectory() {
        XCTAssertEqual(WebKitDevToolsCookieScope.defaultPath(for: URL(string: "https://a.test/x/y")), "/x")
        XCTAssertEqual(WebKitDevToolsCookieScope.defaultPath(for: URL(string: "https://a.test/x")), "/")
        XCTAssertEqual(WebKitDevToolsCookieScope.defaultPath(for: nil), "/")
    }

    func testAWriteCantNameTwoDestinationsThatDisagree() {
        let address = URL(string: "https://sub.example.com/")
        XCTAssertTrue(WebKitDevToolsCookieScope.agrees(domain: "example.com", with: address))
        XCTAssertFalse(WebKitDevToolsCookieScope.agrees(domain: "other.test", with: address))
        XCTAssertTrue(WebKitDevToolsCookieScope.agrees(domain: "other.test", with: nil))
    }
}
