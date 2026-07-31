import Foundation

/// Shared aggregation over parsed per-session `FileSummary` entries — turns a
/// cache of {file path: FileSummary} into the payload the dashboard renders.
/// Both UsageScanner (Codex) and ClaudeCodeUsageScanner feed this the exact
/// same way; only how a single session file gets turned into a FileSummary
/// differs between the two CLIs' very different JSONL schemas, so this is the
/// one place daily rollup, model breakdown, and cost math live.
enum UsageAggregation {
    static func buildPayload(
        cacheFiles: [String: CachedEntry],
        prices: [String: ModelPrice],
        priceStatus: String,
        defaultPlan: String,
        normalizeModel: (String?) -> String
    ) -> UsagePayload {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let todayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.date(byAdding: .day, value: -29, to: todayStart)!
        // The heatmap spans further back than the "30-day" totals below it —
        // otherwise, at 30 days it only ever fills about a week's worth of
        // rows and leaves the card looking half-empty next to the taller
        // session/weekly rings beside it. Kept separate from `monthStart` so
        // `monthCost`/`monthTokens`/the model & project breakdowns stay a
        // true 30-day rollup regardless of how far back the chart reaches.
        let heatmapDays = 112
        let heatmapStart = calendar.date(byAdding: .day, value: -(heatmapDays - 1), to: todayStart)!
        let todayKey = isoDateOnly(todayStart)

        var todayByModel: [String: [String: Int]] = [:]
        var monthByModel: [String: [String: Int]] = [:]
        var dailyByDate: [String: [String: [String: Int]]] = [:]
        var limitsByKind: [String: (slot: LimitSlot, at: Date)] = [:]
        var latestPlan = defaultPlan
        var latestPlanAt = Date.distantPast
        var latestSessionTokens = 0
        var latestSessionAt = Date.distantPast
        var monthToolCalls = 0
        var monthFilesChanged = 0
        var projectTokens: [String: Int] = [:]

        for entry in cacheFiles.values {
            let summary = entry.summary
            guard let ended = Formatting.parseISODate(summary.endedAt) else { continue }
            let usage = summary.usage

            if ended >= latestSessionAt {
                latestSessionAt = ended
                latestSessionTokens = usage["total_tokens"] ?? 0
            }
            if let planType = summary.planType {
                let planAt = summary.planAt.flatMap(Formatting.parseISODate) ?? ended
                if planAt >= latestPlanAt {
                    latestPlanAt = planAt
                    latestPlan = planType
                }
            }
            for (kind, slot) in summary.limitsByKind {
                let slotAt = Formatting.parseISODate(slot.at) ?? ended
                if let existing = limitsByKind[kind] {
                    // A named sub-quota (e.g. a specific preview model's own
                    // limit) must never shadow the account's real overall
                    // usage just because it happens to be reported more
                    // recently — only let a fresher slot win when neither
                    // side, or both sides, are the unnamed overall quota.
                    let existingIsOverall = existing.slot.limitName == nil
                    let candidateIsOverall = slot.limitName == nil
                    if existingIsOverall, !candidateIsOverall {
                        continue
                    }
                    if !existingIsOverall, candidateIsOverall {
                        limitsByKind[kind] = (slot, slotAt)
                        continue
                    }
                    if slotAt >= existing.at {
                        limitsByKind[kind] = (slot, slotAt)
                    }
                } else {
                    limitsByKind[kind] = (slot, slotAt)
                }
            }

            let byModel = summary.usageByModel.isEmpty ? ["unknown": usage] : summary.usageByModel
            let usageByDate = summary.dailyUsageByModel

            if usageByDate.isEmpty {
                // Claude Code summaries and cache files from an older version
                // do not carry per-event timestamps. Preserve their previous
                // end-of-session behavior rather than dropping their data.
                merge(byModel, into: &dailyByDate[isoDateOnly(ended), default: [:]])
                if ended >= monthStart {
                    merge(byModel, into: &monthByModel)
                    monthToolCalls += summary.toolCallCount
                    monthFilesChanged += summary.filesChangedCount
                    if let project = summary.project {
                        projectTokens[project, default: 0] += usage["total_tokens"] ?? 0
                    }
                }
                if ended >= todayStart { merge(byModel, into: &todayByModel) }
                continue
            }

            for (dateKey, eventUsageByModel) in usageByDate {
                guard let eventDay = dateFromDayKey(dateKey) else { continue }
                if eventDay >= heatmapStart { merge(eventUsageByModel, into: &dailyByDate[dateKey, default: [:]]) }
                if eventDay >= monthStart {
                    merge(eventUsageByModel, into: &monthByModel)
                    if let project = summary.project {
                        projectTokens[project, default: 0] += eventUsageByModel.values.reduce(0) { $0 + ($1["total_tokens"] ?? 0) }
                    }
                }
                if dateKey == todayKey { merge(eventUsageByModel, into: &todayByModel) }
            }

            // Tool calls and file changes do not yet carry token-equivalent
            // event records, so keep their former session-level accounting.
            if ended >= monthStart {
                monthToolCalls += summary.toolCallCount
                monthFilesChanged += summary.filesChangedCount
            }
        }

        func merge(_ source: [String: [String: Int]], into target: inout [String: [String: Int]]) {
            for (model, modelUsage) in source {
                for (key, value) in modelUsage {
                    target[model, default: [:]][key, default: 0] += value
                }
            }
        }

        /// Splits one model's token usage into the billed categories at its current
        /// rate — full-price input, cache-hit input, cache writes, and output — so
        /// callers can show not just a total but where that total came from.
        ///
        /// Both scanners report `input_tokens` as the whole prompt, with
        /// `cached_input_tokens` and `cache_write_input_tokens` as the discounted
        /// and premium-rate slices *inside* it; whatever is left over is what gets
        /// billed at the plain input rate. Cache writes are folded into the
        /// `input` component of the returned breakdown because the UI shows three
        /// bars, and a write is conceptually still uncached prompt — just at a
        /// different rate.
        func categoryCost(_ usage: [String: Int], price: ModelPrice) -> (input: Double, cached: Double, output: Double) {
            let rawInput = usage["input_tokens"] ?? 0
            let cacheWrite = min(rawInput, usage["cache_write_input_tokens"] ?? 0)
            let cached = min(rawInput - cacheWrite, usage["cached_input_tokens"] ?? 0)
            let uncached = max(0, rawInput - cached - cacheWrite)
            let output = usage["output_tokens"] ?? 0

            let longRawInput = min(rawInput, usage["long_context_input_tokens"] ?? 0)
            let longCacheWrite = min(cacheWrite, usage["long_context_cache_write_input_tokens"] ?? 0)
            let longCached = min(cached, usage["long_context_cached_input_tokens"] ?? 0)
            let longUncached = max(0, longRawInput - longCached - longCacheWrite)
            let longOutput = min(output, usage["long_context_output_tokens"] ?? 0)

            let shortUncached = max(0, uncached - longUncached)
            let shortCacheWrite = max(0, cacheWrite - longCacheWrite)
            let shortCached = max(0, cached - longCached)
            let shortOutput = max(0, output - longOutput)

            let inputMultiplier = price.longInputMultiplier ?? 1
            let cachedMultiplier = price.longCachedInputMultiplier ?? 1
            let cacheWriteMultiplier = price.longCacheWriteMultiplier ?? 1
            let outputMultiplier = price.longOutputMultiplier ?? 1
            return (
                (Double(shortUncached) * price.input
                    + Double(longUncached) * price.input * inputMultiplier
                    + Double(shortCacheWrite) * price.cacheWrite
                    + Double(longCacheWrite) * price.cacheWrite * cacheWriteMultiplier) / 1_000_000,
                (Double(shortCached) * price.cachedInput
                    + Double(longCached) * price.cachedInput * cachedMultiplier) / 1_000_000,
                (Double(shortOutput) * price.output
                    + Double(longOutput) * price.output * outputMultiplier) / 1_000_000
            )
        }

        func pricedCost(_ usageByModel: [String: [String: Int]]) -> (Double, [String]) {
            var cost = 0.0
            var unpriced: [String] = []
            for (model, usage) in usageByModel {
                guard let price = prices[normalizeModel(model)] else {
                    unpriced.append(model)
                    continue
                }
                let breakdown = categoryCost(usage, price: price)
                cost += breakdown.input + breakdown.cached + breakdown.output
            }
            return (cost, Array(Set(unpriced)).sorted())
        }

        var daily: [DailyPoint] = []
        for offset in stride(from: heatmapDays - 1, through: 0, by: -1) {
            let date = calendar.date(byAdding: .day, value: -offset, to: now)!
            let dateKey = isoDateOnly(date)
            let usageModels = dailyByDate[dateKey] ?? [:]
            let (cost, _) = pricedCost(usageModels)
            let tokens = usageModels.values.reduce(0) { $0 + ($1["total_tokens"] ?? 0) }
            daily.append(DailyPoint(date: dateKey, tokens: tokens, cost: cost))
        }

        let (todayCost, _) = pricedCost(todayByModel)
        let (monthCost, monthUnpriced) = pricedCost(monthByModel)
        let monthTokens = monthByModel.values.reduce(0) { $0 + ($1["total_tokens"] ?? 0) }
        let monthInputTokens = monthByModel.values.reduce(0) { $0 + ($1["input_tokens"] ?? 0) }
        let monthCachedTokens = monthByModel.values.reduce(0) { $0 + ($1["cached_input_tokens"] ?? 0) }
        let todayInputTokens = todayByModel.values.reduce(0) { $0 + ($1["input_tokens"] ?? 0) }
        let todayCachedTokens = todayByModel.values.reduce(0) { $0 + ($1["cached_input_tokens"] ?? 0) }
        let topProjects = projectTokens
            .sorted { $0.value > $1.value }
            .prefix(12)
            .map { ProjectUsage(name: $0.key, tokens: $0.value) }

        var modelBreakdown: [ModelUsage] = []
        for (model, usage) in monthByModel.sorted(by: { ($0.value["total_tokens"] ?? 0) > ($1.value["total_tokens"] ?? 0) }) {
            if let price = prices[normalizeModel(model)] {
                let breakdown = categoryCost(usage, price: price)
                modelBreakdown.append(ModelUsage(
                    model: model, tokens: usage["total_tokens"] ?? 0,
                    apiEquivalentCost: breakdown.input + breakdown.cached + breakdown.output,
                    inputCost: breakdown.input, cachedCost: breakdown.cached, outputCost: breakdown.output
                ))
            } else {
                modelBreakdown.append(ModelUsage(model: model, tokens: usage["total_tokens"] ?? 0, apiEquivalentCost: 0))
            }
        }

        func limitView(_ kind: String) -> LimitView? {
            guard let entry = limitsByKind[kind] else { return nil }
            let resetCount = ResetTracker.observe(provider: defaultPlan, kind: kind, resetsAt: entry.slot.resetsAt)
            return LimitView(
                usedPercent: entry.slot.usedPercent, windowMinutes: entry.slot.windowMinutes,
                resetsAt: entry.slot.resetsAt, resetCount: resetCount
            )
        }
        let weekly = limitView("weekly") ?? limitView("monthly")
        let weeklyKind = limitsByKind["weekly"] != nil ? "weekly" : (limitsByKind["monthly"] != nil ? "monthly" : nil)

        return UsagePayload(
            generatedAt: now,
            plan: latestPlan,
            session: limitView("session"),
            weekly: weekly,
            weeklyKind: weeklyKind,
            latestSessionTokens: latestSessionTokens,
            todayCost: todayCost,
            todayInputTokens: todayInputTokens,
            todayCachedTokens: todayCachedTokens,
            monthCost: monthCost,
            monthTokens: monthTokens,
            monthInputTokens: monthInputTokens,
            monthCachedTokens: monthCachedTokens,
            monthToolCalls: monthToolCalls,
            monthFilesChanged: monthFilesChanged,
            monthUnpricedModels: monthUnpriced,
            models: modelBreakdown,
            daily: daily,
            topProjects: Array(topProjects),
            priceStatus: priceStatus,
            sessionFileCount: cacheFiles.count
        )
    }

    static func isoDateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func dateFromDayKey(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: key)
    }
}
