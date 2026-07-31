import Foundation

/// Reads the current user's local Codex session and archived-session transcripts, then
/// aggregates real token usage, rate-limit windows, and API-equivalent cost. Token
/// usage is retained at its individual event timestamp, rather than being assigned to
/// the final timestamp of a long-running session.
final class UsageScanner {
    private let sessionRoots: [URL]
    private let cachePath: URL
    private let usageKeys = [
        "input_tokens", "cached_input_tokens", "cache_write_input_tokens",
        "output_tokens", "reasoning_output_tokens", "total_tokens",
    ]
    // Bumped to rebuild every cached summary with the two accuracy fixes in
    // `process`/`parseSession`: skipping re-emitted `token_count` events, and
    // back-filling the model for events logged before the first `turn_context`.
    private static let cacheVersion = 5

    init() {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        sessionRoots = [
            home.appendingPathComponent("sessions"),
            home.appendingPathComponent("archived_sessions"),
        ]
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/aibarUsage")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cachePath = cacheDir.appendingPathComponent("usage-cache.json")
    }

    func classifyWindow(_ minutes: Int) -> String? {
        if minutes <= 0 { return nil }
        if minutes <= 600 { return "session" }
        if minutes <= 20_000 { return "weekly" }
        return "monthly"
    }

    func normalizedModel(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        return value == "gpt-5.6" ? "gpt-5.6-sol" : value
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

    func parseSession(url: URL) -> FileSummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let fallbackAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        var totals: [String: Int] = [:]
        var usageByModel: [String: [String: Int]] = [:]
        var dailyUsageByModel: [String: [String: [String: Int]]] = [:]
        var limitsByKind: [String: LimitSlot] = [:]
        var planType: String?
        var planAt: String?
        var project: String?
        var toolCallCount = 0
        var filesChangedCount = 0
        var activeModel = "unknown"
        var firstKnownModel: String?
        var previousTotalUsage: [String: Int]?
        var latestAt = Formatting.isoTimestamp(from: fallbackAt)

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var lineStart = 0
            for index in 0..<bytes.count {
                guard bytes[index] == 0x0A else { continue }
                if index > lineStart {
                    let lineData = Data(bytes: bytes.baseAddress! + lineStart, count: index - lineStart)
                    process(lineData: lineData, activeModel: &activeModel, firstKnownModel: &firstKnownModel,
                            previousTotalUsage: &previousTotalUsage, latestAt: &latestAt,
                            totals: &totals, usageByModel: &usageByModel,
                            dailyUsageByModel: &dailyUsageByModel,
                            limitsByKind: &limitsByKind, planType: &planType, planAt: &planAt,
                            project: &project, toolCallCount: &toolCallCount, filesChangedCount: &filesChangedCount)
                }
                lineStart = index + 1
            }
            if lineStart < bytes.count {
                let lineData = Data(bytes: bytes.baseAddress! + lineStart, count: bytes.count - lineStart)
                process(lineData: lineData, activeModel: &activeModel, firstKnownModel: &firstKnownModel,
                        previousTotalUsage: &previousTotalUsage, latestAt: &latestAt,
                        totals: &totals, usageByModel: &usageByModel,
                        dailyUsageByModel: &dailyUsageByModel,
                        limitsByKind: &limitsByKind, planType: &planType, planAt: &planAt,
                        project: &project, toolCallCount: &toolCallCount, filesChangedCount: &filesChangedCount)
            }
        }

        // Sessions written before Codex started logging `turn_context` up front
        // record their first `token_count` events with no model in scope yet, so
        // those tokens land in an "unknown" bucket that no price table can match
        // and are silently costed at $0. The model is still recoverable — it just
        // appears later in the same file — so fold that bucket into the first one
        // the session actually named.
        if let model = firstKnownModel, model != "unknown" {
            adoptUnknownUsage(into: model, usageByModel: &usageByModel, dailyUsageByModel: &dailyUsageByModel)
        }

        guard !totals.isEmpty else { return nil }
        return FileSummary(endedAt: latestAt, usage: totals, usageByModel: usageByModel,
                            dailyUsageByModel: dailyUsageByModel,
                            limitsByKind: limitsByKind, planType: planType, planAt: planAt,
                            project: project, toolCallCount: toolCallCount, filesChangedCount: filesChangedCount)
    }

    /// Byte-level triage ahead of the JSON parser, which is what a cold rebuild
    /// actually spends its time in. Around four fifths of a transcript's bytes
    /// are tool output and MCP results carrying nothing this scanner reads, and
    /// recognizing them by substring costs a fraction of decoding them. Each
    /// marker includes its closing quote so `custom_tool_call_output` — the
    /// single largest kind of line by volume — isn't dragged back in by
    /// `custom_tool_call`.
    private static let usefulMarkers: [Data] = [
        #""type":"token_count""#,
        #""type":"turn_context""#,
        #""type":"session_meta""#,
        #""type":"custom_tool_call""#,
        #""type":"function_call""#,
        #""type":"patch_apply_end""#,
        #""rate_limits""#,
    ].map { Data($0.utf8) }

    /// How far into a line the triage above has to look. Every marker lives in
    /// the line's envelope — timestamp, top-level type, payload type — which
    /// across local transcripts never reaches past ~74 bytes; the rest of the
    /// line is content. Capping the search keeps triage the same cost for a
    /// 200-byte event as for a 200 KB blob of tool output, instead of scanning
    /// gigabytes of message bodies looking for a key that is always up front.
    private static let envelopeBytes = 512

    private static let timestampPrefix = Data(#"{"timestamp":""#.utf8)

    /// Lifts the leading timestamp out of a line without decoding it. Skipped
    /// lines still have to advance `latestAt`, because a session's `endedAt` is
    /// the timestamp of its last line whatever kind that line happens to be.
    private static func timestamp(in line: Data) -> String? {
        guard line.starts(with: timestampPrefix) else { return nil }
        let valueStart = line.index(line.startIndex, offsetBy: timestampPrefix.count)
        guard let closingQuote = line[valueStart...].firstIndex(of: 0x22) else { return nil }
        return String(data: line[valueStart..<closingQuote], encoding: .utf8)
    }

    /// Reassigns everything parsed before the session named a model, so those
    /// tokens get priced instead of being written off as unattributable.
    private func adoptUnknownUsage(
        into model: String,
        usageByModel: inout [String: [String: Int]],
        dailyUsageByModel: inout [String: [String: [String: Int]]]
    ) {
        if let orphaned = usageByModel.removeValue(forKey: "unknown") {
            for (key, value) in orphaned { usageByModel[model, default: [:]][key, default: 0] += value }
        }
        for (dateKey, byModel) in dailyUsageByModel {
            guard let orphaned = byModel["unknown"] else { continue }
            dailyUsageByModel[dateKey]?.removeValue(forKey: "unknown")
            for (key, value) in orphaned {
                dailyUsageByModel[dateKey]?[model, default: [:]][key, default: 0] += value
            }
        }
    }

    private func process(
        lineData: Data, activeModel: inout String, firstKnownModel: inout String?,
        previousTotalUsage: inout [String: Int]?, latestAt: inout String,
        totals: inout [String: Int], usageByModel: inout [String: [String: Int]],
        dailyUsageByModel: inout [String: [String: [String: Int]]],
        limitsByKind: inout [String: LimitSlot], planType: inout String?, planAt: inout String?,
        project: inout String?, toolCallCount: inout Int, filesChangedCount: inout Int
    ) {
        let envelope = lineData.count > Self.envelopeBytes ? lineData.prefix(Self.envelopeBytes) : lineData
        guard Self.usefulMarkers.contains(where: { envelope.range(of: $0) != nil }) else {
            if let timestamp = Self.timestamp(in: lineData) { latestAt = timestamp }
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }
        if let timestamp = obj["timestamp"] as? String { latestAt = timestamp }
        let topLevelType = obj["type"] as? String
        guard let payload = obj["payload"] as? [String: Any] else { return }

        if topLevelType == "session_meta", project == nil, let cwd = payload["cwd"] as? String {
            project = (cwd as NSString).lastPathComponent
        }

        if let model = payload["model"] as? String {
            activeModel = normalizedModel(model)
            if firstKnownModel == nil, activeModel != "unknown" { firstKnownModel = activeModel }
        }
        let payloadType = payload["type"] as? String

        if payloadType == "custom_tool_call" || payloadType == "function_call" {
            toolCallCount += 1
        }
        if payloadType == "patch_apply_end", let changes = payload["changes"] as? [String: Any] {
            filesChangedCount += changes.count
        }

        if let rateLimits = payload["rate_limits"] as? [String: Any] {
            if let plan = rateLimits["plan_type"] as? String {
                planType = plan
                planAt = latestAt
            }
            let limitName = rateLimits["limit_name"] as? String
            for key in ["primary", "secondary"] {
                guard let slot = rateLimits[key] as? [String: Any] else { continue }
                let windowMinutes = (slot["window_minutes"] as? NSNumber)?.intValue ?? 0
                guard let kind = classifyWindow(windowMinutes) else { continue }
                limitsByKind[kind] = LimitSlot(
                    at: latestAt,
                    usedPercent: (slot["used_percent"] as? NSNumber)?.doubleValue,
                    windowMinutes: windowMinutes,
                    resetsAt: (slot["resets_at"] as? NSNumber)?.doubleValue,
                    limitName: limitName
                )
            }
        }

        guard payloadType == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any]
        else { return }

        // Codex re-emits the previous turn's `token_count` when it refreshes its
        // own usage display (e.g. as a new turn opens), so the same
        // `last_token_usage` can appear several times without a matching API
        // call. Its running `total_token_usage` is the authority on whether real
        // tokens were actually spent: when that hasn't moved, nothing was
        // billed, and adding `last_token_usage` again would double-count it.
        // Measured across ~284k events in local transcripts, these repeats
        // inflate totals by roughly 1.4%.
        if let running = info["total_token_usage"] as? [String: Any] {
            let snapshot = running.compactMapValues { ($0 as? NSNumber)?.intValue }
            let alreadyCounted = previousTotalUsage == snapshot
            previousTotalUsage = snapshot
            if alreadyCounted { return }
        }

        let eventDate = Formatting.parseISODate(latestAt) ?? Date()
        let dateKey = UsageAggregation.isoDateOnly(eventDate)
        for key in usageKeys {
            let value = (usage[key] as? NSNumber)?.intValue ?? 0
            totals[key, default: 0] += value
            usageByModel[activeModel, default: [:]][key, default: 0] += value
            dailyUsageByModel[dateKey, default: [:]][activeModel, default: [:]][key, default: 0] += value
        }
    }

    /// Full scan: reuses cached per-file summaries for transcripts whose mtime/size are
    /// unchanged and retains every locally available transcript, including archives.
    /// The cache-version bump deliberately rebuilds older end-of-session summaries.
    func scan(prices: [String: ModelPrice], priceStatus: String) -> UsagePayload {
        var cache = readCache()
        let paths = allJSONLFiles()

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

        for key in Array(cache.files.keys) {
            if !liveKeys.contains(key) {
                cache.files.removeValue(forKey: key)
            }
        }
        writeCache(cache)

        return UsageAggregation.buildPayload(
            cacheFiles: cache.files, prices: prices, priceStatus: priceStatus,
            defaultPlan: "Codex", normalizeModel: normalizedModel
        )
    }

    private func allJSONLFiles() -> [URL] {
        let fileManager = FileManager.default
        // If a transcript is moved from sessions to archived_sessions, preserve a
        // single copy. The active path wins in the unlikely event both exist.
        var resultsByName: [String: URL] = [:]
        for root in sessionRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if resultsByName[url.lastPathComponent] == nil {
                    resultsByName[url.lastPathComponent] = url
                }
            }
        }
        return Array(resultsByName.values)
    }
}
