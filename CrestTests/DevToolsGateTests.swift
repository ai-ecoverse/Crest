import XCTest

@testable import Crest

/// The DevTools port hands whoever gets through a person's logged-in sessions,
/// so these hold the line that a web page, a rebinding host or a client without
/// the token stays out.
final class DevToolsGateTests: XCTestCase {
    private let gate = DevToolsGate(token: "secret", port: 9222, allowedOrigins: ["https://seven.sliccy.ai"])

    private func request(
        _ line: String = "GET /secret/json/version HTTP/1.1", host: String = "127.0.0.1:9222", headers: String...
    ) -> DevToolsGate.Request {
        DevToolsGate.Request(head: ([line, "Host: \(host)"] + headers).joined(separator: "\r\n"))!
    }

    func testAClientWithTheTokenDiscoversTheBrowser() {
        XCTAssertEqual(gate.admit(request()), .admitted(.version, origin: nil))
        XCTAssertEqual(gate.admit(request("GET /secret/json/list HTTP/1.1")), .admitted(.list, origin: nil))
    }

    func testNothingAnswersWithoutTheToken() {
        for path in ["/json/version", "/wrong/json/version", "/secret2/json/version", "/devtools/browser/wrong", "/"] {
            XCTAssertEqual(gate.admit(request("GET \(path) HTTP/1.1")), .refused, path)
        }
    }

    func testAnotherHostIsRefusedAgainstDNSRebinding() {
        XCTAssertEqual(gate.admit(request(host: "evil.example")), .refused)
        XCTAssertEqual(gate.admit(request(host: "127.0.0.1:9223")), .refused)
    }

    func testOnlyAnAllowedOriginsPageGetsThrough() {
        XCTAssertEqual(
            gate.admit(request(headers: "Origin: https://seven.sliccy.ai")),
            .admitted(.version, origin: "https://seven.sliccy.ai"))
        XCTAssertEqual(gate.admit(request(headers: "Origin: https://evil.example")), .refused)
        XCTAssertEqual(gate.admit(request(headers: "Origin: null")), .refused)
    }

    func testASocketIsHeldToTheSameRules() {
        let upgrade = [
            "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: a", "Sec-WebSocket-Version: 13",
        ]
        func socket(path: String, origin: String) -> DevToolsGate.Request {
            DevToolsGate.Request(
                head: (["GET \(path) HTTP/1.1", "Host: 127.0.0.1:9222", "Origin: \(origin)"] + upgrade)
                    .joined(separator: "\r\n"))!
        }
        XCTAssertEqual(
            gate.admit(socket(path: "/devtools/browser/secret", origin: "https://seven.sliccy.ai")),
            .admitted(.socket(key: "a"), origin: "https://seven.sliccy.ai"))
        XCTAssertEqual(gate.admit(socket(path: "/devtools/browser/secret", origin: "https://evil.example")), .refused)
        XCTAssertEqual(gate.admit(socket(path: "/devtools/browser/wrong", origin: "https://seven.sliccy.ai")), .refused)
    }

    func testAPreflightNeverAnswersAnyOrigin() {
        let preflight = "OPTIONS /secret/json/list HTTP/1.1"
        let method = "Access-Control-Request-Method: GET"
        XCTAssertEqual(
            gate.admit(request(preflight, headers: "Origin: https://seven.sliccy.ai", method)),
            .admitted(.preflight, origin: "https://seven.sliccy.ai"))
        XCTAssertEqual(gate.admit(request(preflight, headers: "Origin: https://evil.example", method)), .refused)
        XCTAssertFalse(gate.crossOriginHeaders(for: "https://seven.sliccy.ai").contains { $0.contains("*") })
    }
}
