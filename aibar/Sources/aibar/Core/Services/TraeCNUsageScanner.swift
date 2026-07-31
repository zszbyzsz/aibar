import Foundation

/// Trae CN is listed as a provider option, but — unlike Codex and Claude Code
/// — it doesn't have a stable, documented local usage log to read.
///
/// Investigated before writing this: `~/.trae-cn` and
/// `~/Library/Application Support/TRAE SOLO CN` are a VS Code–fork profile
/// (Electron/LevelDB/SQLite storage, not plain JSONL). Every workspace's
/// `state.vscdb` → `chat.ChatSessionStore.index` comes back `{"entries":{}}`
/// — task/chat history isn't persisted locally at all, consistent with Trae
/// Solo's tasks running server-side (the task list in the app shows a cloud
/// icon per task). The only place token-shaped strings ("input_tokens" etc.)
/// turn up on disk is inside Chromium's raw HTTP disk cache, which is a
/// transient, undocumented binary container that rotates/evicts on its own —
/// not something to build a "your usage" number on top of.
///
/// So this returns an explicit no-data payload (empty 30-day heatmap, no
/// model/project breakdown, an explanatory `error` string) rather than
/// guessing at numbers from a source that isn't actually there.
enum TraeCNUsageScanner {
    static func scan(lang: AppLanguage) -> UsagePayload {
        var payload = UsagePayload()
        payload.plan = "Trae CN"
        payload.priceStatus = "fallback"
        payload.daily = (0...29).map { daysAgo -> DailyPoint in
            let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -(29 - daysAgo), to: Date())!
            return DailyPoint(date: UsageAggregation.isoDateOnly(date), tokens: 0, cost: 0)
        }
        payload.error = L.traeCNNoData(lang)
        return payload
    }
}
