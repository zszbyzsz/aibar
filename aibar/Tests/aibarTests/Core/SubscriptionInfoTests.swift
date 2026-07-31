import XCTest
@testable import aibar

final class SubscriptionInfoTests: XCTestCase {
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeIDToken(claims: [String: Any]) throws -> String {
        let header = try base64URL(JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"]))
        let payload = try base64URL(JSONSerialization.data(withJSONObject: claims))
        return "\(header).\(payload).unsigned"
    }

    /// Points CODEX_HOME at a fresh temp dir containing a hand-built
    /// auth.json for the duration of the test, then restores the previous
    /// value so this doesn't leak into other tests or a real local install.
    private func withCodexHome(authJSON: Data?, _ body: () -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubscriptionInfoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let authJSON {
            try authJSON.write(to: dir.appendingPathComponent("auth.json"))
        }
        let previous = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", dir.path, 1)
        addTeardownBlock {
            if let previous {
                setenv("CODEX_HOME", previous, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
            try? FileManager.default.removeItem(at: dir)
        }
        body()
    }

    func testReadDecodesPlanTypeAndActiveUntilFromLocalAuthJSON() throws {
        let idToken = try makeIDToken(claims: [
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "Pro",
                "chatgpt_subscription_active_until": "2026-08-01T00:00:00Z",
            ],
        ])
        let authJSON = try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": idToken]])

        try withCodexHome(authJSON: authJSON) {
            let info = SubscriptionInfo.read()
            XCTAssertEqual(info?.planType, "Pro")
            XCTAssertNotNil(info?.activeUntil)
        }
    }

    func testReadReturnsNilWhenAuthFileIsMissing() throws {
        try withCodexHome(authJSON: nil) {
            XCTAssertNil(SubscriptionInfo.read())
        }
    }

    func testReadReturnsNilWhenAuthJSONIsMalformed() throws {
        try withCodexHome(authJSON: Data("not json".utf8)) {
            XCTAssertNil(SubscriptionInfo.read())
        }
    }

    func testReadReturnsNilWhenAuthClaimIsMissing() throws {
        let idToken = try makeIDToken(claims: ["some_other_claim": "value"])
        let authJSON = try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": idToken]])

        try withCodexHome(authJSON: authJSON) {
            XCTAssertNil(SubscriptionInfo.read())
        }
    }
}
