import Foundation

/// Reads the ChatGPT plan/subscription-expiry claims embedded in Codex CLI's own
/// local `~/.codex/auth.json` id_token. Read-only — the file holds live OAuth
/// tokens, so this only decodes the JWT payload in memory and never persists the
/// token itself (or the file's contents) to our own cache.
enum SubscriptionInfo {
    struct Info {
        var planType: String?
        var activeUntil: Date?
    }

    static func read() -> Info? {
        let authPath = (ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
            .appendingPathComponent("auth.json")

        guard let data = try? Data(contentsOf: authPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = decodeJWTPayload(idToken),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }

        let activeUntil = (auth["chatgpt_subscription_active_until"] as? String).flatMap(Formatting.parseISODate)
        return Info(planType: auth["chatgpt_plan_type"] as? String, activeUntil: activeUntil)
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
        base64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
