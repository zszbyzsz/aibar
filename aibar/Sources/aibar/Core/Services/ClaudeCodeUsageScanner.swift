import Foundation

/// Reads the current user's local Claude Code session transcripts
/// (~/.claude/projects/**/*.jsonl) and aggregates real token usage and
/// API-equivalent cost, the same way UsageScanner does for Codex CLI — one
/// JSONL file per session, fed through the same UsageAggregation pipeline.
/// Claude Code's local transcripts don't carry the 5h/7d rate-limit snapshot
/// Codex writes into its own session files (that accounting only lives
/// server-side for Claude Code), so `session`/`weekly` in the resulting
/// payload always come back nil here — QuotaMeterView already renders a nil
/// limit as "暂无数据" rather than a fake bar.
final class ClaudeCodeUsageScanner {
    private let sessionsRoot: URL
    private let cachePath: URL
    // Bumped when `input_tokens` changed meaning here (see `process`) — cached
    // summaries written under the old shape would price cache reads wrong.
    private static let cacheVersion = 3
    private static let fileToolNames: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    init() {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        sessionsRoot = home.appendingPathComponent("projects")
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/aibarUsage")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cachePath = cacheDir.appendingPathComponent("claude-usage-cache.json")
    }

    /// Strips a trailing dated snapshot suffix ("-20251001") so a specific
    /// pinned model version still matches its family's price-table entry,
    /// mirroring UsageScanner.normalizedModel for the Codex side.
    func normalizedModel(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        if let range = value.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(value[value.startIndex..<range.lowerBound])
        }
        return value
    }

    private func readCache() -> CacheFile {
        guard let data = try? Data(contentsOf: cachePath),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.version == Self.cacheVersion
        else { return CacheFile(version: Self.cacheVersion, files: [:]) }
        return cache
    }

    private func writeCache(_ cache: CacheFile) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cachePath, options: .atomic)
    }

    /// One JSONL file = one Claude Code session. Every `type: "assistant"`
    /// line carries a `message.usage` block for that turn — this sums them
    /// into the same {input_tokens, cached_input_tokens, cache_write_input_tokens,
    /// output_tokens, total_tokens} shape UsageScanner produces for Codex, so
    /// UsageAggregation doesn't need to know which CLI a session came from.
    func parseSession(url: URL) -> FileSummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let fallbackAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        var totals: [String: Int] = [:]
        var usageByModel: [String: [String: Int]] = [:]
        var project: String?
        var toolCallCount = 0
        var filesChangedCount = 0
        var latestAt = Formatting.isoTimestamp(from: fallbackAt)
        var sawUsage = false

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var lineStart = 0
            for index in 0..<bytes.count {
                guard bytes[index] == 0x0A else { continue }
                if index > lineStart {
                    let lineData = Data(bytes: bytes.baseAddress! + lineStart, count: index - lineStart)
                    process(lineData: lineData, latestAt: &latestAt, totals: &totals,
                            usageByModel: &usageByModel, project: &project,
                            toolCallCount: &toolCallCount, filesChangedCount: &filesChangedCount, sawUsage: &sawUsage)
                }
                lineStart = index + 1
            }
            if lineStart < bytes.count {
                let lineData = Data(bytes: bytes.baseAddress! + lineStart, count: bytes.count - lineStart)
                process(lineData: lineData, latestAt: &latestAt, totals: &totals,
                        usageByModel: &usageByModel, project: &project,
                        toolCallCount: &toolCallCount, filesChangedCount: &filesChangedCount, sawUsage: &sawUsage)
            }
        }

        guard sawUsage else { return nil }
        return FileSummary(endedAt: latestAt, usage: totals, usageByModel: usageByModel,
                            limitsByKind: [:], planType: nil, planAt: nil,
                            project: project, toolCallCount: toolCallCount, filesChangedCount: filesChangedCount)
    }

    private func process(
        lineData: Data, latestAt: inout String, totals: inout [String: Int],
        usageByModel: inout [String: [String: Int]], project: inout String?,
        toolCallCount: inout Int, filesChangedCount: inout Int, sawUsage: inout Bool
    ) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }
        if let timestamp = obj["timestamp"] as? String { latestAt = timestamp }
        if project == nil, let cwd = obj["cwd"] as? String {
            project = (cwd as NSString).lastPathComponent
        }
        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any]
        else { return }

        if let content = message["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "tool_use" {
                toolCallCount += 1
                if let name = block["name"] as? String, Self.fileToolNames.contains(name) {
                    filesChangedCount += 1
                }
            }
        }

        guard let usage = message["usage"] as? [String: Any] else { return }
        let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
        let cachedRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
        let cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        let output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
        guard input + cachedRead + cacheWrite + output > 0 else { return }
        sawUsage = true

        let model = normalizedModel(message["model"] as? String)
        // Anthropic reports `input_tokens` as *only* the uncached remainder, with
        // cache reads and writes as disjoint siblings; Codex reports the whole
        // prompt in `input_tokens` and names the cached slice inside it. Convert
        // to the Codex shape here so UsageAggregation's cost split has one
        // meaning to work with — otherwise `cached_input_tokens` gets clamped to
        // the handful of uncached tokens, and both the cache-read discount and
        // the cache-write premium silently vanish from the bill.
        let values: [String: Int] = [
            "input_tokens": input + cachedRead + cacheWrite,
            "cached_input_tokens": cachedRead,
            "cache_write_input_tokens": cacheWrite,
            "output_tokens": output,
            "total_tokens": input + cachedRead + cacheWrite + output,
        ]
        for (key, value) in values {
            totals[key, default: 0] += value
            usageByModel[model, default: [:]][key, default: 0] += value
        }
    }

    /// Full scan: same cache-then-reaggregate shape as UsageScanner.scan(),
    /// just pointed at ~/.claude/projects and this file's Claude-specific parser.
    func scan(prices: [String: ModelPrice], priceStatus: String) -> UsagePayload {
        var cache = readCache()
        let fileManager = FileManager.default
        let paths = fileManager.fileExists(atPath: sessionsRoot.path) ? allJSONLFiles() : []

        var liveKeys = Set<String>()
        for url in paths {
            let key = url.path
            liveKeys.insert(key)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate?.timeIntervalSince1970,
                  let size = values.fileSize
            else { continue }

            if let existing = cache.files[key], existing.mtime == mtime, existing.size == size {
                continue
            }
            if let summary = parseSession(url: url) {
                cache.files[key] = CachedEntry(mtime: mtime, size: size, summary: summary)
            } else {
                cache.files.removeValue(forKey: key)
            }
        }

        let cutoff = Date().addingTimeInterval(-35 * 86400)
        for key in Array(cache.files.keys) {
            let entry = cache.files[key]!
            let ended = Formatting.parseISODate(entry.summary.endedAt) ?? .distantPast
            if !liveKeys.contains(key) || ended < cutoff {
                cache.files.removeValue(forKey: key)
            }
        }
        writeCache(cache)

        return UsageAggregation.buildPayload(
            cacheFiles: cache.files, prices: prices, priceStatus: priceStatus,
            defaultPlan: "Claude Code", normalizeModel: normalizedModel
        )
    }

    private func allJSONLFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            results.append(url)
        }
        return results
    }
}
