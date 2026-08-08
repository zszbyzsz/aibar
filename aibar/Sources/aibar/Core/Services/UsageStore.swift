import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    /// Keep the account quota current while the menu-bar app is running, even
    /// when no Codex session is active and the dashboard remains hidden.
    /// Opening the panel still triggers an immediate refresh independently of
    /// this hourly background cadence.
    static let refreshInterval: TimeInterval = 60 * 60
    /// While the dashboard is visible, poll the lightweight SQLite/WAL file
    /// signature rather than repeatedly parsing every historical transcript.
    /// Codex updates this state as soon as it records a `token_count` event,
    /// so this keeps the displayed local usage within one short interval of a
    /// completed response without any network polling.
    static let visibleCodexRefreshInterval: TimeInterval = 1.5

    @Published var payload = UsagePayload()
    @Published var refreshing = false
    /// Switching this re-scans immediately (see didSet) and every card in the
    /// dashboard re-renders from the freshly-fetched payload for that CLI —
    /// there's no per-field merging, the whole payload is provider-specific.
    @Published var provider: UsageProvider = .codex {
        didSet {
            guard oldValue != provider else { return }
            Task { await refresh() }
        }
    }
    /// Persisted across launches; only re-scans for providers whose payload
    /// itself carries language-dependent text (currently just Trae CN's
    /// explanatory error string) — everything else is relabeled live by the
    /// views themselves via `Environment.appLanguage`.
    @Published var language: AppLanguage = .loadSaved() {
        didSet {
            guard oldValue != language else { return }
            language.persist()
            if provider == .traeCN { Task { await refresh() } }
        }
    }

    private let demoMode: Bool

    private let codexScanner = UsageScanner()
    private let codexActivityMonitor = CodexActivityMonitor()
    private let codexPricing = PricingService()
    private let claudeScanner = ClaudeCodeUsageScanner()
    private let claudePricing = ClaudePricingService()
    private var timer: Timer?
    private var hasStarted = false
    private var visibleCodexTimer: Timer?
    private var lastCodexStateFingerprint: CodexStateFingerprint?

    private struct FileFingerprint: Equatable {
        let modifiedAt: TimeInterval
        let size: Int
    }

    private struct CodexStateFingerprint: Equatable {
        let database: FileFingerprint?
        let writeAheadLog: FileFingerprint?
    }

    /// Last successful `/api/oauth/usage` result, re-applied on top of every
    /// local rescan (see the .claudeCode case in refresh()) since that local
    /// scan itself has no source for session/weekly limits — only this
    /// network call does. Kept separate from `payload` so a local rescan on
    /// either timer doesn't clobber it back to nil between visits.
    private var claudeRemoteQuota: ClaudeOAuthUsage.Result?
    private var lastClaudeOAuthFetch: Date?
    /// The oauth/usage endpoint is undocumented and rate-limits hard, so this
    /// is a floor under how often refreshRemoteQuota() will actually
    /// hit the network, independent of how often the caller asks.
    private static let claudeOAuthMinInterval: TimeInterval = 60
    /// Snapshot of Codex's server-owned token activity and Full reset credits.
    /// Kept outside `payload` so a fast local transcript refresh cannot
    /// briefly replace official daily values with raw JSONL counters.
    private var codexAccountTokenUsage: CodexAccountTokenUsage?
    private var codexResetCredits: RateLimitResetCredits?
    private var lastCodexAccountMetadataFetch: Date?
    private static let codexAccountMetadataMinInterval: TimeInterval = 60

    init() {
        demoMode = CommandLine.arguments.contains("--demo")
        if demoMode {
            language = .en
            payload = Self.demoPayload()
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard !demoMode else { return }
        // A fresh install has no warm in-memory price cache yet. Start the
        // official-price request right away, but do not make local session
        // data wait for it: `refresh(eagerly:)` publishes a fallback-priced
        // scan first and replaces it as soon as the live rates arrive.
        Task { await refresh(eagerly: true) }
        refreshCodexAccountMetadataIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The local scan alone cannot see account-owned quota details.
                // Refresh those first so an idle app still receives the latest
                // Codex/Claude limits once per hour.
                self.refreshRemoteQuota()
                await self.refresh()
            }
        }
    }

    /// Starts an on-screen, local-only refresh loop.  The loop first checks
    /// Codex's live state DB and its WAL sidecar; it performs the comparatively
    /// heavier JSONL aggregation only after those files have changed.
    func startVisibleCodexRefresh() {
        guard visibleCodexTimer == nil else { return }
        lastCodexStateFingerprint = codexStateFingerprint()
        visibleCodexTimer = Timer.scheduledTimer(
            withTimeInterval: Self.visibleCodexRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVisibleCodexUsageIfNeeded()
            }
        }
    }

    func stopVisibleCodexRefresh() {
        visibleCodexTimer?.invalidate()
        visibleCodexTimer = nil
        lastCodexStateFingerprint = nil
    }

    private func refreshVisibleCodexUsageIfNeeded() {
        guard provider == .codex, !refreshing else { return }
        let fingerprint = codexStateFingerprint()
        guard fingerprint != lastCodexStateFingerprint else { return }
        lastCodexStateFingerprint = fingerprint
        // A completed response changes both the local attribution sample and
        // the server-owned daily total. Refresh both sides of that equation;
        // the account fetch has its own one-minute throttle below.
        refreshCodexAccountMetadataIfNeeded()
        Task { await refresh() }
    }

    /// `state_5.sqlite` is Codex Desktop's live local thread index; the WAL is
    /// normally the file whose metadata changes for each committed turn.  Read
    /// metadata only here — the scanner remains the single source of detailed
    /// per-model/day aggregation from the corresponding session JSONLs.
    private func codexStateFingerprint() -> CodexStateFingerprint {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

        func fingerprint(for url: URL) -> FileFingerprint? {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modifiedAt = values.contentModificationDate?.timeIntervalSince1970,
                  let size = values.fileSize
            else { return nil }
            return FileFingerprint(modifiedAt: modifiedAt, size: size)
        }

        // Both paths can coexist after a Codex migration.  Use the same
        // activity-aware resolver as the live capsule so the visible dashboard
        // refresh follows the database Codex is actually writing.
        let database = CodexActivityMonitor.stateDatabaseURL(in: codexHome)

        return CodexStateFingerprint(
            database: fingerprint(for: database),
            writeAheadLog: fingerprint(for: database.appendingPathExtension("wal"))
        )
    }

    func refresh() async {
        await refresh(eagerly: false)
    }

    /// The startup path must show all locally available usage without waiting
    /// for remote model-price pages. It therefore starts that fetch in parallel
    /// and performs one cheap cached/fallback-priced scan immediately. Once the
    /// fetch completes, it re-aggregates from the scanner's on-disk summaries,
    /// so no session transcript has to be parsed a second time in the usual
    /// case.
    private func refresh(eagerly: Bool) async {
        if demoMode {
            payload = Self.demoPayload()
            return
        }
        // Startup and preview-open can request a refresh in the same run loop.
        // Coalescing them prevents two concurrent parsers from rereading the
        // same large local transcript archive and delaying the first payload.
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let currentProvider = provider
        switch currentProvider {
        case .codex:
            if eagerly {
                async let refreshedPrices = codexPricing.prices()
                let immediatePrices = await codexPricing.cachedOrFallbackPrices()
                await publishCachedCodexPayload(
                    prices: immediatePrices.models,
                    status: immediatePrices.status,
                    provider: currentProvider
                )
                var immediateResult = await codexPayload(
                    prices: immediatePrices.models,
                    status: immediatePrices.status
                )
                immediateResult.activeProject = codexActivityMonitor.currentActivity()
                guard provider == currentProvider else { return }
                payload = immediateResult

                let latestPrices = await refreshedPrices
                guard provider == currentProvider else { return }
                // If the fallback was all the network could provide, its
                // already-published payload is complete. Otherwise publish
                // the same local records with the newly verified rates.
                guard latestPrices.status != "fallback" else { return }
                var refreshedResult = await codexPayload(
                    prices: latestPrices.models,
                    status: latestPrices.status
                )
                refreshedResult.activeProject = codexActivityMonitor.currentActivity()
                guard provider == currentProvider else { return }
                payload = refreshedResult
                return
            }

            let (prices, status) = await codexPricing.prices()
            await publishCachedCodexPayload(
                prices: prices,
                status: status,
                provider: currentProvider
            )
            var result = await codexPayload(prices: prices, status: status)
            result.activeProject = codexActivityMonitor.currentActivity()
            guard provider == currentProvider else { return }
            payload = result
        case .claudeCode:
            let (prices, status) = await claudePricing.prices()
            let scanner = claudeScanner
            var result = await Task.detached(priority: .userInitiated) {
                scanner.scan(prices: prices, priceStatus: status)
            }.value
            result.pricingRates = prices
            // The local scan itself never has session/weekly limits (see
            // ClaudeCodeUsageScanner's header comment) — graft on whatever
            // refreshRemoteQuota() last fetched from the live API.
            result.session = claudeRemoteQuota?.session
            result.weekly = claudeRemoteQuota?.weekly
            result.weeklyKind = claudeRemoteQuota?.weekly != nil ? "weekly" : nil
            // Claude Code has no local equivalent of Codex's ChatGPT-subscription
            // auth.json claims, so the badge stays hidden for this provider.
            guard provider == currentProvider else { return }
            payload = result
        case .traeCN:
            // No async work — see TraeCNUsageScanner for why there's nothing
            // local to actually scan.
            guard provider == currentProvider else { return }
            payload = TraeCNUsageScanner.scan(lang: language)
        }
    }

    /// Keeps the cold-start and ordinary paths on precisely the same local
    /// aggregation logic. `UsageScanner` persists per-file summaries, so the
    /// second call after a live pricing response normally only reads metadata
    /// and recalculates totals from that cache.
    private func codexPayload(prices: [String: ModelPrice], status: String) async -> UsagePayload {
        let scanner = codexScanner
        let accountUsage = codexAccountTokenUsage
        var result = await Task.detached(priority: .userInitiated) {
            (
                scanner.scan(
                    prices: prices,
                    priceStatus: status,
                    accountUsage: accountUsage
                ),
                SubscriptionInfo.read()
            )
        }.value
        result.0.pricingRates = prices
        result.0.subscriptionPlan = result.1?.planType
        result.0.subscriptionActiveUntil = result.1?.activeUntil
        result.0.rateLimitResetCredits = codexResetCredits
        return result.0
    }

    /// Publish a complete cached snapshot before any changing session file is
    /// reparsed.  It uses the same account metadata, subscription, pricing,
    /// and activity decoration as the fresh scan below, so this is a real
    /// dashboard state rather than a temporary placeholder.
    private func publishCachedCodexPayload(
        prices: [String: ModelPrice],
        status: String,
        provider currentProvider: UsageProvider
    ) async {
        let scanner = codexScanner
        let accountUsage = codexAccountTokenUsage
        let cached = await Task.detached(priority: .userInitiated) {
            (
                scanner.cachedPayload(
                    prices: prices,
                    priceStatus: status,
                    accountUsage: accountUsage
                ),
                SubscriptionInfo.read()
            )
        }.value
        guard var result = cached.0 else { return }
        result.pricingRates = prices
        result.subscriptionPlan = cached.1?.planType
        result.subscriptionActiveUntil = cached.1?.activeUntil
        result.rateLimitResetCredits = codexResetCredits
        result.activeProject = codexActivityMonitor.currentActivity()
        guard provider == currentProvider else { return }
        payload = result
    }

    /// Refreshes the selected provider's live quota. Called when the dashboard
    /// opens and by the hourly background timer, never by the rapid local-file
    /// polling loop. The client-side throttle keeps rapid hover changes from
    /// hammering Claude's rate-limited endpoint.
    func refreshRemoteQuota() {
        guard !demoMode else { return }
        if provider == .codex {
            refreshCodexAccountMetadataIfNeeded()
            return
        }
        guard provider == .claudeCode else { return }
        if let last = lastClaudeOAuthFetch, Date().timeIntervalSince(last) < Self.claudeOAuthMinInterval { return }
        lastClaudeOAuthFetch = Date()
        Task {
            guard let result = await ClaudeOAuthUsage.fetch() else { return }
            claudeRemoteQuota = result
            guard provider == .claudeCode else { return }
            payload.session = result.session
            payload.weekly = result.weekly
            payload.weeklyKind = result.weekly != nil ? "weekly" : nil
        }
    }

    /// Uses Codex's own authenticated app-server process. No credential data
    /// crosses into aibar; only aggregate token buckets/reset metadata do.
    private func refreshCodexAccountMetadataIfNeeded() {
        guard provider == .codex else { return }
        if let last = lastCodexAccountMetadataFetch,
           Date().timeIntervalSince(last) < Self.codexAccountMetadataMinInterval {
            return
        }
        lastCodexAccountMetadataFetch = Date()
        Task {
            guard let metadata = await CodexAppServerUsage.fetchAccountMetadata() else { return }
            let tokenUsageChanged = metadata.tokenUsage != nil && metadata.tokenUsage != codexAccountTokenUsage
            if let tokenUsage = metadata.tokenUsage { codexAccountTokenUsage = tokenUsage }
            if let resetCredits = metadata.resetCredits { codexResetCredits = resetCredits }
            guard provider == .codex else { return }
            if let resetCredits = metadata.resetCredits {
                payload.rateLimitResetCredits = resetCredits
            }
            // Token totals, model/project attribution, and all derived prices
            // are one calculation. Rebuild them atomically instead of briefly
            // publishing a payload whose cards disagree with each other.
            if tokenUsageChanged { await refresh() }
        }
    }

    /// A deterministic, non-sensitive dataset for UI checks and README assets.
    /// It drives the app only with `--demo` — ordinary launches always inspect
    /// the user's local records instead — and is reachable directly so the
    /// documentation images can be rendered from the same numbers.
    static func demoPayload() -> UsagePayload {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let tokenBands = [
            0,
            50_000_000,
            120_000_000,
            280_000_000,
            520_000_000,
            850_000_000,
            1_400_000_000,
            3_200_000_000,
            5_600_000_000,
            10_400_000_000,
        ]
        let daily = (0..<112).map { offset -> DailyPoint in
            let date = calendar.date(byAdding: .day, value: offset - 111, to: now) ?? now
            let activity = (offset * 37 + 19) % 10
            let tokens = tokenBands[activity]
            return DailyPoint(
                date: UsageAggregation.isoDateOnly(date),
                tokens: tokens,
                cost: Double(tokens) / 1_000_000 * 0.78
            )
        }
        let recentMonthTokens = Array(daily.suffix(30)).map(\.tokens)
        let recentProjectTokens = Array(daily.suffix(90)).map(\.tokens)
        let modelTrendShares = [
            42_000_000_000.0 / 67_260_000_000.0,
            17_000_000_000.0 / 67_260_000_000.0,
            8_260_000_000.0 / 67_260_000_000.0,
        ]
        let modelTrends = modelTrendShares.map { share in
            recentMonthTokens.map { Int((Double($0) * share).rounded()) }
        }
        let projectTrendTotal = 61_800_000_000.0
        let projectTrendShares = [
            31_600_000_000.0 / projectTrendTotal,
            20_400_000_000.0 / projectTrendTotal,
            9_800_000_000.0 / projectTrendTotal,
        ]
        let projectTrends = projectTrendShares.map { share in
            recentProjectTokens.map { Int((Double($0) * share).rounded()) }
        }
        let toolCallBands = recentMonthTokens.enumerated().map { index, tokens in
            max(0, Int(Double(tokens) / 180_000_000) + (index % 4))
        }
        let demoMCPServers = [
            MCPUsage(name: "codex_apps", calls: 186, dailyCalls: toolCallBands.map { $0 + 2 }),
            MCPUsage(name: "node_repl", calls: 121, dailyCalls: toolCallBands.map { max(0, $0 - 1) }),
            MCPUsage(name: "computer-use", calls: 103, dailyCalls: toolCallBands.map { max(0, $0 / 2) }),
            MCPUsage(name: "gitnexus", calls: 72, dailyCalls: toolCallBands.map { $0 % 5 }),
        ]
        let resetBase = now.timeIntervalSince1970
        return UsagePayload(
            generatedAt: now,
            plan: "Pro",
            session: LimitView(usedPercent: 26, windowMinutes: 300, resetsAt: resetBase + 90 * 60, resetCount: 0),
            weekly: LimitView(usedPercent: 41, windowMinutes: 10_080, resetsAt: resetBase + 4 * 86_400, resetCount: 0),
            weeklyKind: "weekly",
            latestSessionTokens: 1_850_000_000,
            todayCost: 1_092.00,
            todayInputTokens: 900_000_000,
            todayCachedTokens: 500_000_000,
            monthCost: 52_462.80,
            monthTokens: 67_260_000_000,
            monthInputTokens: 43_000_000_000,
            monthCachedTokens: 18_000_000_000,
            monthMCPCalls: 482,
            monthFilesChanged: 97,
            mcpServers: demoMCPServers,
            monthUnpricedModels: [],
            models: [
                ModelUsage(model: "gpt-5.6-sol", tokens: 42_000_000_000, apiEquivalentCost: 32_100.00, inputCost: 12_840.0, cachedCost: 3_210.0, outputCost: 16_050.0, dailyTokens: modelTrends[0]),
                ModelUsage(model: "gpt-5.6-terra", tokens: 17_000_000_000, apiEquivalentCost: 14_250.00, inputCost: 5_700.0, cachedCost: 1_425.0, outputCost: 7_125.0, dailyTokens: modelTrends[1]),
                ModelUsage(model: "gpt-5.5", tokens: 8_260_000_000, apiEquivalentCost: 6_112.80, inputCost: 2_445.12, cachedCost: 611.28, outputCost: 3_056.40, dailyTokens: modelTrends[2]),
            ],
            daily: daily,
            topProjects: [
                ProjectUsage(name: "studio-app", tokens: 31_600_000_000, apiEquivalentCost: 25_600.00, models: [
                    ProjectModelUsage(model: "gpt-5.6-sol", tokens: 24_000_000_000, apiEquivalentCost: 19_200.00),
                    ProjectModelUsage(model: "gpt-5.6-terra", tokens: 7_600_000_000, apiEquivalentCost: 6_400.00),
                ], dailyTokens: projectTrends[0]),
                ProjectUsage(name: "design-system", tokens: 20_400_000_000, apiEquivalentCost: 16_100.00, models: [
                    ProjectModelUsage(model: "gpt-5.6-terra", tokens: 13_000_000_000, apiEquivalentCost: 10_400.00),
                    ProjectModelUsage(model: "gpt-5.6-sol", tokens: 7_400_000_000, apiEquivalentCost: 5_700.00),
                ], dailyTokens: projectTrends[1]),
                ProjectUsage(name: "swift-lab", tokens: 9_800_000_000, apiEquivalentCost: 7_800.00, models: [
                    ProjectModelUsage(model: "gpt-5.5", tokens: 7_800_000_000, apiEquivalentCost: 6_200.00),
                    ProjectModelUsage(model: "gpt-5.6-terra", tokens: 2_000_000_000, apiEquivalentCost: 1_600.00),
                ], dailyTokens: projectTrends[2]),
            ],
            activeProject: ProjectActivity(
                project: "studio-app",
                conversationTitle: "Refine studio workspace",
                goalObjective: "Polish the workspace activity experience",
                model: "gpt-5.6-sol", phase: .usingScreen,
                lastActivityAt: now, startedAt: now.addingTimeInterval(-643),
                timingScope: .continuousGoal,
                currentContextTokens: 184_000,
                conversationTokens: 789_000_000,
                sandboxPolicy: "workspace-write", approvalMode: "on-request",
                threadID: "preview-thread"
            ),
            priceStatus: "live",
            sessionFileCount: 24,
            pricingRates: [
                "gpt-5.6-sol": ModelPrice(input: 5, cachedInput: 0.5, output: 30, source: "demo", status: "live"),
                "gpt-5.6-terra": ModelPrice(input: 2.5, cachedInput: 0.25, output: 15, source: "demo", status: "live"),
                "gpt-5.5": ModelPrice(input: 5, cachedInput: 0.5, output: 30, source: "demo", status: "live"),
            ],
            subscriptionPlan: "Pro",
            subscriptionActiveUntil: calendar.date(byAdding: .day, value: 19, to: now),
            // One credit on each side of the ten-day line, so the heatmap shows
            // both expiry markers: the quiet alarm and the red days-left cell.
            rateLimitResetCredits: RateLimitResetCredits(
                availableCount: 2,
                expiresAt: [resetBase + 3 * 86_400, resetBase + 13 * 86_400]
            )
        )
    }
}
