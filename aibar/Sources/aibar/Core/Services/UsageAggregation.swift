import Foundation

/// Shared aggregation over parsed per-session `FileSummary` entries — turns a
/// cache of {file path: FileSummary} into the payload the dashboard renders.
/// Both UsageScanner (Codex) and ClaudeCodeUsageScanner feed this the exact
/// same way; only how a single session file gets turned into a FileSummary
/// differs between the two CLIs' very different JSONL schemas, so this is the
/// one place daily rollup, model breakdown, and cost math live.
enum UsageAggregation {
    /// Project bucket used when Codex reports account activity for a day for
    /// which this Mac has no matching local transcript. Keeping that usage
    /// explicit is more accurate than silently assigning it to a known cwd.
    static let unattributedProject = "__account_unattributed__"

    /// Normalizes a set of local model/category samples to one authoritative
    /// daily total. Local transcripts remain the only available source for
    /// model and input/cache/output proportions, but their repeated-context
    /// totals are not allowed to change the account-owned total.
    static func normalizedUsageByModel(
        _ local: [String: [String: Int]],
        targetTokens: Int
    ) -> [String: [String: Int]] {
        normalizedBuckets(local, targetTokens: targetTokens, fallbackKey: "unknown")
    }

    private static func normalizedBuckets(
        _ local: [String: [String: Int]],
        targetTokens: Int,
        fallbackKey: String
    ) -> [String: [String: Int]] {
        let target = max(0, targetTokens)
        guard target > 0 else { return [:] }

        let positive = local.filter { ($0.value["total_tokens"] ?? 0) > 0 }
        let localTotal = positive.values.reduce(0) { $0 + ($1["total_tokens"] ?? 0) }
        guard localTotal > 0 else { return [fallbackKey: ["total_tokens": target]] }

        let factor = Double(target) / Double(localTotal)
        let allocations = proportionalAllocation(
            positive.mapValues { $0["total_tokens"] ?? 0 },
            target: target
        )
        var result: [String: [String: Int]] = [:]
        for key in positive.keys.sorted() {
            guard let usage = positive[key],
                  let allocatedTotal = allocations[key],
                  allocatedTotal > 0
            else { continue }
            var scaled: [String: Int] = [:]
            for (counter, value) in usage where counter != "total_tokens" {
                scaled[counter] = max(0, Int((Double(value) * factor).rounded()))
            }
            scaled["total_tokens"] = allocatedTotal
            clampNestedCounters(&scaled)
            result[key] = scaled
        }
        return result
    }

    /// Largest-remainder apportionment makes every displayed dimension add up
    /// to the exact server total, including awkward non-divisible ratios.
    private static func proportionalAllocation(
        _ weights: [String: Int],
        target: Int
    ) -> [String: Int] {
        let positive = weights.filter { $0.value > 0 }
        let weightTotal = positive.values.reduce(0, +)
        guard target > 0, weightTotal > 0 else { return [:] }

        var result: [String: Int] = [:]
        var remainders: [(key: String, value: Double)] = []
        var allocated = 0
        for key in positive.keys.sorted() {
            let exact = Double(positive[key]!) * Double(target) / Double(weightTotal)
            let floorValue = Int(exact.rounded(.down))
            result[key] = floorValue
            allocated += floorValue
            remainders.append((key, exact - Double(floorValue)))
        }
        remainders.sort {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        for item in remainders.prefix(max(0, target - allocated)) {
            result[item.key, default: 0] += 1
        }
        return result
    }

    private static func clampNestedCounters(_ usage: inout [String: Int]) {
        let input = max(0, usage["input_tokens"] ?? 0)
        let cacheWrite = min(input, max(0, usage["cache_write_input_tokens"] ?? 0))
        let cached = min(input - cacheWrite, max(0, usage["cached_input_tokens"] ?? 0))
        usage["input_tokens"] = input
        usage["cache_write_input_tokens"] = cacheWrite
        usage["cached_input_tokens"] = cached

        let output = max(0, usage["output_tokens"] ?? 0)
        usage["output_tokens"] = output
        usage["reasoning_output_tokens"] = min(output, max(0, usage["reasoning_output_tokens"] ?? 0))
        usage["long_context_input_tokens"] = min(input, max(0, usage["long_context_input_tokens"] ?? 0))
        usage["long_context_cache_write_input_tokens"] = min(cacheWrite, max(0, usage["long_context_cache_write_input_tokens"] ?? 0))
        usage["long_context_cached_input_tokens"] = min(cached, max(0, usage["long_context_cached_input_tokens"] ?? 0))
        usage["long_context_output_tokens"] = min(output, max(0, usage["long_context_output_tokens"] ?? 0))
    }

    static func buildPayload(
        cacheFiles: [String: CachedEntry],
        prices: [String: ModelPrice],
        priceStatus: String,
        defaultPlan: String,
        normalizeModel: (String?) -> String,
        accountUsage: CodexAccountTokenUsage? = nil,
        calendarTimeZone: TimeZone = .current
    ) -> UsagePayload {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = calendarTimeZone
        let todayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.date(byAdding: .day, value: -29, to: todayStart)!
        // The heatmap spans further back than the "30-day" totals below it —
        // otherwise, at 30 days it only ever fills about a week's worth of
        // rows and leaves the card looking half-empty next to the taller
        // session/weekly rings beside it. Kept separate from `monthStart` so
        // `monthCost`/`monthTokens`/the global model breakdown stay a true
        // 30-day rollup regardless of how far back the chart reaches.
        let heatmapDays = 112
        let heatmapStart = calendar.date(byAdding: .day, value: -(heatmapDays - 1), to: todayStart)!
        let todayKey = isoDateOnly(todayStart, timeZone: calendarTimeZone)

        var todayByModel: [String: [String: Int]] = [:]
        var monthByModel: [String: [String: Int]] = [:]
        var dailyByDate: [String: [String: [String: Int]]] = [:]
        var limitsByKind: [String: (slot: LimitSlot, at: Date)] = [:]
        var latestPlan = defaultPlan
        var latestPlanAt = Date.distantPast
        var latestSessionTokens = 0
        var latestSessionAt = Date.distantPast
        var latestSessionUsageByDate: [String: [String: [String: Int]]] = [:]
        var monthToolCalls = 0
        var monthFilesChanged = 0
        var monthToolUsage: [String: Int] = [:]
        var dailyToolUsage: [String: [String: Int]] = [:]
        // Unlike the overall model list, this keeps the model dimension nested
        // under each project. A session has one cwd but can switch models, so
        // recording only `projectTokens` here would make the breakdown
        // impossible to reconstruct later.
        var projectUsageByDate: [String: [String: [String: [String: Int]]]] = [:]
        // The project card is a 90-day view. Keep its per-day totals beside
        // the aggregate so the UI can draw a faithful trend without doing any
        // additional transcript work.
        var projectDailyTokens: [String: [String: Int]] = [:]

        func addProjectUsage(
            _ usageByModel: [String: [String: Int]],
            project: String,
            dateKey: String
        ) {
            for (model, usage) in usageByModel {
                for (counter, value) in usage {
                    projectUsageByDate[dateKey, default: [:]][project, default: [:]][model, default: [:]][counter, default: 0] += value
                }
            }
        }

        /// Tool events have their own dates, unlike the legacy session-level
        /// totals. Prefer the detailed counters so a long-running session is
        /// attributed to the days on which its tools were actually invoked;
        /// retain the old end-date behavior for caches/providers without them.
        func addToolUsage(_ summary: FileSummary, ended: Date) {
            if !summary.dailyToolUsage.isEmpty {
                for (dateKey, tools) in summary.dailyToolUsage {
                    guard let day = dateFromDayKey(dateKey, timeZone: calendarTimeZone), day >= monthStart else { continue }
                    for (tool, calls) in tools where calls > 0 {
                        monthToolCalls += calls
                        monthToolUsage[tool, default: 0] += calls
                        dailyToolUsage[dateKey, default: [:]][tool, default: 0] += calls
                    }
                }
            } else if ended >= monthStart {
                monthToolCalls += summary.toolCallCount
                for (tool, calls) in summary.toolUsage where calls > 0 {
                    monthToolUsage[tool, default: 0] += calls
                    dailyToolUsage[isoDateOnly(ended, timeZone: calendarTimeZone), default: [:]][tool, default: 0] += calls
                }
            }
        }

        for entry in cacheFiles.values {
            let summary = entry.summary
            guard let ended = Formatting.parseISODate(summary.endedAt) else { continue }
            let usage = summary.usage

            if ended >= latestSessionAt {
                latestSessionAt = ended
                latestSessionTokens = usage["total_tokens"] ?? 0
                latestSessionUsageByDate = summary.dailyUsageByModel.isEmpty
                    ? [isoDateOnly(ended, timeZone: calendarTimeZone): (summary.usageByModel.isEmpty ? ["unknown": usage] : summary.usageByModel)]
                    : summary.dailyUsageByModel
            }
            if let planType = summary.planType {
                let planAt = summary.planAt.flatMap(Formatting.parseISODate) ?? ended
                if planAt >= latestPlanAt {
                    latestPlanAt = planAt
                    latestPlan = planType
                }
            }
            addToolUsage(summary, ended: ended)
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
                let endedKey = isoDateOnly(ended, timeZone: calendarTimeZone)
                merge(byModel, into: &dailyByDate[endedKey, default: [:]])
                if ended >= monthStart {
                    merge(byModel, into: &monthByModel)
                    monthFilesChanged += summary.filesChangedCount
                }
                if ended >= heatmapStart {
                    addProjectUsage(
                        byModel,
                        project: summary.project ?? Self.unattributedProject,
                        dateKey: endedKey
                    )
                }
                if ended >= todayStart { merge(byModel, into: &todayByModel) }
                continue
            }

            for (dateKey, eventUsageByModel) in usageByDate {
                guard let eventDay = dateFromDayKey(dateKey, timeZone: calendarTimeZone) else { continue }
                if eventDay >= heatmapStart { merge(eventUsageByModel, into: &dailyByDate[dateKey, default: [:]]) }
                if eventDay >= monthStart {
                    merge(eventUsageByModel, into: &monthByModel)
                }
                if eventDay >= heatmapStart {
                    addProjectUsage(
                        eventUsageByModel,
                        project: summary.project ?? Self.unattributedProject,
                        dateKey: dateKey
                    )
                }
                if dateKey == todayKey { merge(eventUsageByModel, into: &todayByModel) }
            }

            // File changes remain session-level — their source records don't
            // contain a stable per-file event timestamp — while tool calls are
            // accounted above from their own event-day counters.
            if ended >= monthStart {
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

        func normalizedProjectDay(
            _ local: [String: [String: [String: Int]]],
            targetTokens: Int
        ) -> [String: [String: [String: Int]]] {
            var flat: [String: [String: Int]] = [:]
            var identity: [String: (project: String, model: String)] = [:]
            var pairs: [(project: String, model: String, usage: [String: Int])] = []
            for (project, byModel) in local {
                for (model, usage) in byModel {
                    pairs.append((project, model, usage))
                }
            }
            pairs.sort {
                $0.project == $1.project ? $0.model < $1.model : $0.project < $1.project
            }
            for (index, pair) in pairs.enumerated() {
                let key = String(index)
                flat[key] = pair.usage
                identity[key] = (pair.project, pair.model)
            }
            let fallbackKey = "fallback"
            identity[fallbackKey] = (Self.unattributedProject, "unknown")
            let normalized = Self.normalizedBuckets(
                flat,
                targetTokens: targetTokens,
                fallbackKey: fallbackKey
            )

            var result: [String: [String: [String: Int]]] = [:]
            for (key, usage) in normalized {
                guard let bucket = identity[key] else { continue }
                result[bucket.project, default: [:]][bucket.model] = usage
            }
            return result
        }

        var projectUsageByModel: [String: [String: [String: Int]]] = [:]
        if let accountUsage, !accountUsage.dailyTokens.isEmpty {
            let rawDailyByDate = dailyByDate
            for offset in stride(from: heatmapDays - 1, through: 0, by: -1) {
                let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
                let dateKey = isoDateOnly(date, timeZone: calendarTimeZone)
                let normalizedProjects = normalizedProjectDay(
                    projectUsageByDate[dateKey] ?? [:],
                    targetTokens: accountUsage.dailyTokens[dateKey] ?? 0
                )
                var normalizedModels: [String: [String: Int]] = [:]
                for byModel in normalizedProjects.values {
                    merge(byModel, into: &normalizedModels)
                }
                // Project/model pairs are the canonical normalized dimension,
                // so summing either card produces identical counters and cost.
                // A model-only fallback is retained for old cache summaries
                // that predate project attribution.
                dailyByDate[dateKey] = normalizedModels.isEmpty
                    ? Self.normalizedUsageByModel(
                        rawDailyByDate[dateKey] ?? [:],
                        targetTokens: accountUsage.dailyTokens[dateKey] ?? 0
                    )
                    : normalizedModels

                if offset <= 89 {
                    for (project, byModel) in normalizedProjects {
                        merge(byModel, into: &projectUsageByModel[project, default: [:]])
                        projectDailyTokens[dateKey, default: [:]][project, default: 0] += byModel.values.reduce(0) {
                            $0 + ($1["total_tokens"] ?? 0)
                        }
                    }
                }
            }

            // Rebuild every derived 30-day field from normalized daily data;
            // otherwise total tokens would be official while model mix and
            // price remained on the inflated transcript counter.
            todayByModel = dailyByDate[todayKey] ?? [:]
            monthByModel = [:]
            for offset in stride(from: 29, through: 0, by: -1) {
                let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
                let dateKey = isoDateOnly(date, timeZone: calendarTimeZone)
                merge(dailyByDate[dateKey] ?? [:], into: &monthByModel)
            }

            // The server has no per-session dimension. Attribute the latest
            // session its proportional share of each authoritative day, using
            // the same local samples as the project/model split.
            latestSessionTokens = 0
            for (dateKey, sessionByModel) in latestSessionUsageByDate {
                let sessionLocal = sessionByModel.values.reduce(0) { $0 + ($1["total_tokens"] ?? 0) }
                let dayLocal = (rawDailyByDate[dateKey] ?? [:]).values.reduce(0) {
                    $0 + ($1["total_tokens"] ?? 0)
                }
                guard sessionLocal > 0, dayLocal > 0 else { continue }
                let target = accountUsage.dailyTokens[dateKey] ?? 0
                latestSessionTokens += min(
                    target,
                    max(0, Int((Double(target) * Double(sessionLocal) / Double(dayLocal)).rounded()))
                )
            }
        } else {
            for offset in stride(from: 89, through: 0, by: -1) {
                let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
                let dateKey = isoDateOnly(date, timeZone: calendarTimeZone)
                let byProject = projectUsageByDate[dateKey] ?? [:]
                for (project, byModel) in byProject {
                    merge(byModel, into: &projectUsageByModel[project, default: [:]])
                    projectDailyTokens[dateKey, default: [:]][project, default: 0] += byModel.values.reduce(0) {
                        $0 + ($1["total_tokens"] ?? 0)
                    }
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
            let dateKey = isoDateOnly(date, timeZone: calendarTimeZone)
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

        func recentDateKeys(_ count: Int) -> [String] {
            (0..<count).map { index in
                let date = calendar.date(byAdding: .day, value: -(count - 1 - index), to: todayStart) ?? todayStart
                return isoDateOnly(date, timeZone: calendarTimeZone)
            }
        }

        let modelTrendDates = recentDateKeys(30)
        let projectTrendDates = recentDateKeys(90)

        var tools: [ToolUsage] = []
        for (name, calls) in monthToolUsage {
            let trend = modelTrendDates.map { dateKey in
                dailyToolUsage[dateKey]?[name] ?? 0
            }
            tools.append(ToolUsage(name: name, calls: calls, dailyCalls: trend))
        }
        tools.sort { lhs, rhs in
            lhs.calls == rhs.calls
                ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                : lhs.calls > rhs.calls
        }

        var projects: [ProjectUsage] = []
        for (project, usageByModel) in projectUsageByModel {
            var models: [ProjectModelUsage] = []
            for (model, usage) in usageByModel {
                let cost: Double
                if let price = prices[normalizeModel(model)] {
                    let breakdown = categoryCost(usage, price: price)
                    cost = breakdown.input + breakdown.cached + breakdown.output
                } else {
                    cost = 0
                }
                models.append(ProjectModelUsage(
                    model: model,
                    tokens: usage["total_tokens"] ?? 0,
                    apiEquivalentCost: cost
                ))
            }
            models.sort { $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens }
            projects.append(ProjectUsage(
                name: project,
                tokens: models.reduce(0) { $0 + $1.tokens },
                apiEquivalentCost: models.reduce(0) { $0 + $1.apiEquivalentCost },
                models: models,
                dailyTokens: projectTrendDates.map { projectDailyTokens[$0]?[project] ?? 0 }
            ))
        }
        projects.sort { $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens }
        let topProjects = Array(projects.prefix(12))

        var modelBreakdown: [ModelUsage] = []
        for (model, usage) in monthByModel.sorted(by: { ($0.value["total_tokens"] ?? 0) > ($1.value["total_tokens"] ?? 0) }) {
            let dailyTokens = modelTrendDates.map { dailyByDate[$0]?[model]?["total_tokens"] ?? 0 }
            if let price = prices[normalizeModel(model)] {
                let breakdown = categoryCost(usage, price: price)
                modelBreakdown.append(ModelUsage(
                    model: model, tokens: usage["total_tokens"] ?? 0,
                    apiEquivalentCost: breakdown.input + breakdown.cached + breakdown.output,
                    inputCost: breakdown.input, cachedCost: breakdown.cached, outputCost: breakdown.output,
                    dailyTokens: dailyTokens
                ))
            } else {
                modelBreakdown.append(ModelUsage(
                    model: model,
                    tokens: usage["total_tokens"] ?? 0,
                    apiEquivalentCost: 0,
                    dailyTokens: dailyTokens
                ))
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
            tools: tools,
            monthUnpricedModels: monthUnpriced,
            models: modelBreakdown,
            daily: daily,
            topProjects: Array(topProjects),
            priceStatus: priceStatus,
            sessionFileCount: cacheFiles.count
        )
    }

    static func isoDateOnly(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    private static func dateFromDayKey(_ key: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return formatter.date(from: key)
    }
}
