import CryptoKit
import XCTest
@testable import aibar

final class AppUpdateServiceTests: XCTestCase {
    func testChecksEverySixHours() {
        XCTAssertEqual(AppUpdateService.checkInterval, 21_600)
    }

    func testVersionComparisonIsNumericAndStableBeatsPrerelease() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9.9")), try XCTUnwrap(AppVersion("0.10.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("v1.0.0-beta")), try XCTUnwrap(AppVersion("1.0.0")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.2")), try XCTUnwrap(AppVersion("1.2.0")))
    }

    func testGitHubAssetAcceptsOnlyValidSHA256Digest() throws {
        let valid = String(repeating: "a", count: 64)
        let data = Data("""
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/zszbyzsz/aibar/releases/tag/v0.2.0",
          "draft": false,
          "prerelease": false,
          "assets": [{
            "name": "aibar-0.2.0.zip",
            "browser_download_url": "https://github.com/zszbyzsz/aibar/releases/download/v0.2.0/aibar-0.2.0.zip",
            "digest": "sha256:\(valid)"
          }]
        }
        """.utf8)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        XCTAssertEqual(release.assets.first?.sha256Digest, valid)
    }

    func testSHA256MatchesKnownValue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-update-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("aibar".utf8).write(to: url)

        let expected = SHA256.hash(data: Data("aibar".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(try AppUpdateService.sha256(of: url), expected)
    }

    func testUpdateReminderOnlyJoinsAnAlreadyVisibleCapsule() {
        let notice = AppUpdateNotice(
            version: "0.2.0",
            releaseURL: URL(string: "https://example.com/release")!,
            packageURL: nil
        )

        XCTAssertTrue(ActivityCapsulePolicy.rows(
            running: [], announcement: nil, retained: [], updateNotice: notice
        ).isEmpty)

        let completion = RetainedCompletion(
            key: "done",
            project: "project",
            outcome: .completed,
            completedAt: Date()
        )
        XCTAssertEqual(
            ActivityCapsulePolicy.rows(
                running: [], announcement: completion, retained: [], updateNotice: notice
            ).map(\.id),
            ["completed-done", "update-0.2.0"]
        )
    }
}
