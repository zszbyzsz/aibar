import Foundation
import Security

/// Fetches live session/weekly quota utilization from Anthropic's undocumented
/// `/api/oauth/usage` endpoint — the same one Claude Code's own `/status` and
/// `/usage` slash commands call. Unlike SubscriptionInfo (which just decodes a
/// JWT Codex CLI already wrote to disk, zero network I/O), this is a real
/// request against a live account, using the OAuth access token Claude Code
/// itself stores in the macOS Keychain under the "Claude Code-credentials"
/// service. Read-only: never writes back to the Keychain and never attempts a
/// token refresh, so an expired token just means "no data" rather than this
/// app minting new credentials on the user's behalf.
///
/// This endpoint isn't documented and rate-limits hard, so callers must NOT
/// poll it on the usual 8s/30s local-file cadence — UsageStore only calls
/// this once per dashboard visit, with its own minimum-interval guard on top.
enum ClaudeOAuthUsage {
    struct Result {
        var session: LimitView?
        var weekly: LimitView?
    }

    private struct Credentials {
        var accessToken: String
        var expiresAt: Date?
    }

    private struct WindowUsage: Decodable {
        var utilization: Double?
        var resets_at: String?
    }

    private struct UsageResponse: Decodable {
        var five_hour: WindowUsage?
        var seven_day: WindowUsage?
    }

    static func fetch() async -> Result? {
        guard let credentials = readKeychainCredentials() else { return nil }
        if let expiresAt = credentials.expiresAt, expiresAt <= Date() { return nil }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Without a claude-code-shaped UA this lands in a far more aggressively
        // rate-limited bucket than the CLI's own traffic gets.
        request.setValue("claude-cli/2.0.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data)
        else { return nil }

        func limitView(_ window: WindowUsage?, windowMinutes: Int, kind: String) -> LimitView? {
            guard let window, let utilization = window.utilization else { return nil }
            let resetsAt = window.resets_at.flatMap(Formatting.parseISODate)?.timeIntervalSince1970
            let resetCount = ResetTracker.observe(provider: "claudeCode", kind: kind, resetsAt: resetsAt)
            return LimitView(usedPercent: utilization, windowMinutes: windowMinutes, resetsAt: resetsAt, resetCount: resetCount)
        }

        return Result(
            session: limitView(decoded.five_hour, windowMinutes: 300, kind: "session"),
            weekly: limitView(decoded.seven_day, windowMinutes: 10080, kind: "weekly")
        )
    }

    /// Reads the same Keychain item ("Claude Code-credentials", macOS username
    /// as the account) that the Claude Code CLI itself writes on login.
    private static func readKeychainCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: NSUserName(),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String
        else { return nil }

        var expiresAt: Date?
        if let millis = oauth["expiresAt"] as? NSNumber {
            expiresAt = Date(timeIntervalSince1970: millis.doubleValue / 1000)
        }
        return Credentials(accessToken: accessToken, expiresAt: expiresAt)
    }
}
