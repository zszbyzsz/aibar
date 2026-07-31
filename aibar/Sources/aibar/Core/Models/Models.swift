import Foundation

/// Which CLI's local session logs the dashboard is currently reading from.
/// Both scanners feed the same UsagePayload shape, so switching this is the
/// only thing that needs to change to make every card on screen reflect the
/// other tool's usage.
enum UsageProvider: String, CaseIterable, Identifiable {
    case codex
    case claudeCode
    case traeCN

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .traeCN: return "Trae CN"
        }
    }

    /// Providers surfaced in the UI. Claude Code and Trae CN support are
    /// implemented (scanners, tests) but not yet polished enough to show
    /// by default, so only Codex is offered for now — revert this to
    /// `allCases` once they're ready.
    static let enabledCases: [UsageProvider] = [.codex]
}

struct LimitSlot: Codable {
    var at: String
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Double?
    /// nil for the account's overall plan quota; non-nil for a named
    /// sub-quota (e.g. a specific preview model's own limit, reported
    /// alongside the real one under the same `window_minutes`). A named
    /// slot must never shadow the unnamed one when merging across session
    /// files purely by recency — see `UsageAggregation.buildPayload`.
    var limitName: String? = nil
}

struct FileSummary: Codable {
    var endedAt: String
    var usage: [String: Int]
    var usageByModel: [String: [String: Int]]
    /// Token usage grouped by the timestamp of each individual token event.
    /// This avoids assigning an entire long-running task to the day on which
    /// its transcript happened to end.
    var dailyUsageByModel: [String: [String: [String: Int]]] = [:]
    var limitsByKind: [String: LimitSlot]
    var planType: String?
    var planAt: String?
    var project: String?
    var toolCallCount: Int = 0
    var filesChangedCount: Int = 0
}

struct CachedEntry: Codable {
    var mtime: Double
    var size: Int
    var summary: FileSummary
}

struct CacheFile: Codable {
    var version: Int
    var files: [String: CachedEntry]
}

struct ModelPrice: Codable {
    var input: Double
    var cachedInput: Double
    var output: Double
    /// $/1M tokens for writing a prompt into the cache. Most models charge the
    /// normal input rate; GPT-5.6 charges 1.25× input. Anthropic has its own
    /// premium cache-write rate, so this cannot be folded into `input`.
    var cacheWrite: Double
    /// Some OpenAI models charge higher rates when a single request crosses
    /// the long-context threshold. Optional so providers without such a tier,
    /// and older on-disk payloads, retain their ordinary rates.
    var longContextThreshold: Int?
    var longInputMultiplier: Double?
    var longCachedInputMultiplier: Double?
    var longCacheWriteMultiplier: Double?
    var longOutputMultiplier: Double?
    var source: String
    var status: String

    init(input: Double, cachedInput: Double, output: Double,
         cacheWrite: Double? = nil,
         longContextThreshold: Int? = nil,
         longInputMultiplier: Double? = nil,
         longCachedInputMultiplier: Double? = nil,
         longCacheWriteMultiplier: Double? = nil,
         longOutputMultiplier: Double? = nil,
         source: String, status: String) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.cacheWrite = cacheWrite ?? input
        self.longContextThreshold = longContextThreshold
        self.longInputMultiplier = longInputMultiplier
        self.longCachedInputMultiplier = longCachedInputMultiplier
        self.longCacheWriteMultiplier = longCacheWriteMultiplier
        self.longOutputMultiplier = longOutputMultiplier
        self.source = source
        self.status = status
    }
}

struct ModelUsage: Identifiable {
    var id: String { model }
    var model: String
    var tokens: Int
    var apiEquivalentCost: Double
    var inputCost: Double = 0
    var cachedCost: Double = 0
    var outputCost: Double = 0
}

struct DailyPoint: Identifiable {
    var id: String { date }
    var date: String
    var tokens: Int
    var cost: Double
}

struct ProjectUsage: Identifiable {
    var id: String { name }
    var name: String
    var tokens: Int
    /// Models that contributed to this project's 90-day token total, ordered
    /// from most to least used. Keeping this alongside the project total lets
    /// the dashboard explain a project's spend without needing another scan.
    var models: [ProjectModelUsage] = []
}

struct ProjectModelUsage: Identifiable {
    var id: String { model }
    var model: String
    var tokens: Int
}

/// A deliberately narrow, privacy-preserving view of a recently active Codex
/// thread. It contains only thread metadata and the final event kind — never a
/// prompt, response, command, file path, or tool input/output.
struct ProjectActivity: Equatable {
    enum Phase {
        case working
        case thinking
        case usingTool
        case editing
    }

    var project: String
    var model: String?
    var phase: Phase
    var lastActivityAt: Date
    /// When the currently running task started. A Codex thread can be reused
    /// for many tasks, so this comes from the rollout's latest `task_started`
    /// event rather than the thread's original database creation time.
    var startedAt: Date
    var sessionTokens: Int
    var sandboxPolicy: String
    var approvalMode: String
    /// The thread's own database id (`threads.id`) — not shown anywhere, but
    /// lets the always-on capsule deep-link a click straight to this specific
    /// thread (`codex://threads/<id>`) instead of just foregrounding whatever
    /// Codex last happened to have open.
    var threadID: String
}

/// Why a thread that used to be active no longer is — lets the always-on
/// activity capsule pick a distinct completion sound instead of playing the
/// same chime whether Codex finished cleanly, was interrupted, or just went
/// silent.
enum ActivityOutcome {
    /// The rollout's last event was `task_complete`.
    case completed
    /// The rollout's last event was `turn_aborted` — an explicit stop.
    case aborted
    /// Still mid-task per the rollout, but nothing has updated in over
    /// `CodexActivityMonitor.activeWindow` — treated as "paused".
    case timedOut
}

enum CodexActivityState {
    case active(ProjectActivity)
    /// `nil` reason means there's simply nothing to report (no thread at
    /// all, or one that was never active to begin with).
    case idle(ActivityOutcome?)
}

/// What a single row of the always-on capsule (`ActivityStatusBarController`)
/// is showing. Distinct from `CodexActivityState`: completion rows can be
/// retained, consumed, or grouped into an all-completed summary.
enum ActivityCapsuleDisplay: Equatable {
    case active(ProjectActivity)
    case completed(project: String, outcome: ActivityOutcome)
    /// Collapsed entry shown when several projects have all finished. Clicking
    /// it reveals the individual completion rows underneath.
    case completionSummary(count: Int)
    case update(AppUpdateNotice)
}

struct AppUpdateNotice: Equatable {
    let version: String
    let releaseURL: URL
    /// A digest-verified archive pulled into the user's cache, when the
    /// release supplied checksum metadata. Otherwise the reminder links to
    /// the release page without downloading an unverified executable.
    let packageURL: URL?
}

/// One row in the always-on capsule's stacked list. Collapsed, only the
/// first row shows; hovering reveals the rest — every currently running
/// project, plus short-lived completion outcomes. `id` is
/// stable across polls (the thread's key, or a key derived from it for the
/// completion row) so SwiftUI can animate rows being added, removed, and
/// reordered instead of just replacing the whole list each time. `Equatable`
/// so `ActivityStatusBarController.rebuildDisplay()` can tell a poll that
/// changed nothing from one that did, and skip the republish entirely.
struct CapsuleRow: Identifiable, Equatable {
    let id: String
    /// The thread this row deep-links to on tap (`codex://threads/<id>`) —
    /// whether the row is currently shown as `.active` or `.completed`.
    /// Update reminders have no Codex thread and use their release/package
    /// URL action instead.
    let threadID: String?
    let display: ActivityCapsuleDisplay
}

struct LimitView {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Double?
    /// How many times this window has actually rolled over, counted locally
    /// by `ResetTracker` since this app first observed it — the CLI's local
    /// session logs only ever expose the current deadline, never a reset
    /// history, so this can't be backfilled further than that.
    var resetCount: Int?
}

/// Earned, manually redeemable Codex rate-limit resets. These are distinct
/// from a quota window's automatic `resetsAt`: the account may have one or
/// more Full reset credits, each with its own expiry date.
struct RateLimitResetCredits: Equatable {
    var availableCount: Int
    /// One timestamp per available detail row returned by Codex. The backend
    /// may expose only `availableCount`, in which case this remains empty.
    var expiresAt: [Double]
}

struct UsagePayload {
    var generatedAt: Date = Date()
    var plan: String = "Codex"
    var session: LimitView?
    var weekly: LimitView?
    var weeklyKind: String?
    var latestSessionTokens: Int = 0
    var todayCost: Double = 0
    var todayInputTokens: Int = 0
    var todayCachedTokens: Int = 0
    var monthCost: Double = 0
    var monthTokens: Int = 0
    var monthInputTokens: Int = 0
    var monthCachedTokens: Int = 0
    var monthToolCalls: Int = 0
    var monthFilesChanged: Int = 0
    var monthUnpricedModels: [String] = []
    var models: [ModelUsage] = []
    var daily: [DailyPoint] = []
    var topProjects: [ProjectUsage] = []
    var activeProject: ProjectActivity?
    var priceStatus: String = "fallback"
    var sessionFileCount: Int = 0
    var pricingRates: [String: ModelPrice] = [:]
    var subscriptionPlan: String?
    var subscriptionActiveUntil: Date?
    var rateLimitResetCredits: RateLimitResetCredits?
    var error: String?
}
