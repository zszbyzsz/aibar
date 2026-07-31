import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    /// The idle-state cadence — nobody's looking at the panel most of the
    /// time, so there's no point re-scanning local session logs more than
    /// every half hour. Whenever the panel actually opens, NotchWindowController
    /// triggers its own immediate refresh on top of this, independent of
    /// wherever this timer happens to be in its cycle.
    static let refreshInterval: TimeInterval = 30 * 60
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
    /// is a floor under how often refreshRemoteQuotaOnVisit() will actually
    /// hit the network, independent of how often the caller asks.
    private static let claudeOAuthMinInterval: TimeInterval = 60

    init() {
        demoMode = CommandLine.arguments.contains("--demo")
        if demoMode {
            language = .en
            payload = Self.demoPayload()
        }
    }

    func start() {
        guard !demoMode else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
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

        return CodexStateFingerprint(
            database: fingerprint(for: codexHome.appendingPathComponent("state_5.sqlite")),
            writeAheadLog: fingerprint(for: codexHome.appendingPathComponent("state_5.sqlite-wal"))
        )
    }

    func refresh() async {
        if demoMode {
            payload = Self.demoPayload()
            return
        }
        refreshing = true
        defer { refreshing = false }

        let currentProvider = provider
        switch currentProvider {
        case .codex:
            let (prices, status) = await codexPricing.prices()
            let scanner = codexScanner
            var result = await Task.detached(priority: .userInitiated) {
                (scanner.scan(prices: prices, priceStatus: status), SubscriptionInfo.read())
            }.value
            result.0.pricingRates = prices
            result.0.subscriptionPlan = result.1?.planType
            result.0.subscriptionActiveUntil = result.1?.activeUntil
            result.0.activeProject = codexActivityMonitor.currentActivity()
            guard provider == currentProvider else { return }
            payload = result.0
        case .claudeCode:
            let (prices, status) = await claudePricing.prices()
            let scanner = claudeScanner
            var result = await Task.detached(priority: .userInitiated) {
                scanner.scan(prices: prices, priceStatus: status)
            }.value
            result.pricingRates = prices
            // The local scan itself never has session/weekly limits (see
            // ClaudeCodeUsageScanner's header comment) — graft on whatever
            // refreshRemoteQuotaOnVisit() last fetched from the live API.
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

    /// Hits the live `/api/oauth/usage` endpoint — call this once per actual
    /// dashboard visit (NotchWindowController does, on hover-reveal), never
    /// from the 8s/30s local-file timers. Rate-limited client-side on top of
    /// that so rapid hover in/out doesn't hammer an endpoint that already
    /// 429s aggressively server-side.
    func refreshRemoteQuotaOnVisit() {
        guard !demoMode else { return }
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

    /// A deterministic, non-sensitive dataset for UI checks and README assets.
    /// It is available only with `--demo`; ordinary launches always inspect the
    /// user's local records instead.
    private static func demoPayload() -> UsagePayload {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let daily = (0..<112).map { offset -> DailyPoint in
            let date = calendar.date(byAdding: .day, value: offset - 111, to: now) ?? now
            let activity = (offset * 37 + 19) % 10
            return DailyPoint(
                date: UsageAggregation.isoDateOnly(date),
                tokens: activity == 0 ? 0 : 45_000 + activity * 26_000,
                cost: activity == 0 ? 0 : Double(activity) * 0.42
            )
        }
        let resetBase = now.timeIntervalSince1970
        return UsagePayload(
            generatedAt: now,
            plan: "Pro",
            session: LimitView(usedPercent: 26, windowMinutes: 300, resetsAt: resetBase + 90 * 60, resetCount: 0),
            weekly: LimitView(usedPercent: 41, windowMinutes: 10_080, resetsAt: resetBase + 4 * 86_400, resetCount: 0),
            weeklyKind: "weekly",
            latestSessionTokens: 185_000,
            todayCost: 18.42,
            todayInputTokens: 2_800_000,
            todayCachedTokens: 1_700_000,
            monthCost: 428.16,
            monthTokens: 18_600_000,
            monthInputTokens: 12_400_000,
            monthCachedTokens: 6_200_000,
            monthToolCalls: 482,
            monthFilesChanged: 97,
            monthUnpricedModels: [],
            models: [
                ModelUsage(model: "gpt-5.6-sol", tokens: 11_800_000, apiEquivalentCost: 287.40, inputCost: 122.0, cachedCost: 25.4, outputCost: 140.0),
                ModelUsage(model: "gpt-5.6-terra", tokens: 5_400_000, apiEquivalentCost: 108.26, inputCost: 42.0, cachedCost: 9.76, outputCost: 56.5),
                ModelUsage(model: "gpt-5.5", tokens: 1_400_000, apiEquivalentCost: 32.50, inputCost: 15.0, cachedCost: 2.5, outputCost: 15.0),
            ],
            daily: daily,
            topProjects: [
                ProjectUsage(name: "studio-app", tokens: 9_800_000),
                ProjectUsage(name: "design-system", tokens: 5_600_000),
                ProjectUsage(name: "swift-lab", tokens: 1_900_000),
            ],
            activeProject: ProjectActivity(
                project: "studio-app", model: "gpt-5.6-sol", phase: .editing,
                lastActivityAt: now, startedAt: now.addingTimeInterval(-643),
                sessionTokens: 185_000,
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
            subscriptionActiveUntil: calendar.date(byAdding: .day, value: 19, to: now)
        )
    }
}
