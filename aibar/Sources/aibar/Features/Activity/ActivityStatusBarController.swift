import AppKit
import SwiftUI

/// An always-on stack of pills that floats just beneath the physical notch,
/// centered under it — a compact "what is Codex doing right now" indicator,
/// not the dashboard's hover-only activity view. `NotchWindowController` only
/// shows Codex's activity while someone is actively hovering the notch; this
/// polls `CodexActivityMonitor` on its own short cycle so the top pill
/// appears the moment a task starts and a distinct chime plays the moment one
/// ends. Collapsed, only the single most relevant row shows; hovering pulls
/// the rest of the stack down — every other project currently running, up to
/// `maxRunningRows` of them. Clicking a task brings Codex to the front;
/// clicking an all-completed summary reveals the finished task list.
@MainActor
final class ActivityStatusBarController: NSObject, ObservableObject {
    private let panel: NSPanel
    private let monitor = CodexActivityMonitor()
    /// Read by `ActivityStatusBarView`. Order matters: a just-finished
    /// project's `.completed` announcement (if any) is temporarily first,
    /// followed by every currently running project in whatever order
    /// `CodexActivityMonitor.activeThreadStates` returned them — that's
    /// already `ORDER BY updated_at_ms DESC` (most recently active first),
    /// so there's deliberately no additional sort applied here; re-deriving
    /// an order (e.g. by running duration) both adds work and risks the list
    /// visibly reordering itself between polls for no reason a viewer would
    /// notice or want. Recently completed tasks come last after their
    /// announcement ends. Collapsed, only `rows.first` is drawn (see
    /// `ActivityStatusBarView`); `isExpanded` reveals the rest.
    @Published fileprivate(set) var rows: [CapsuleRow] = []
    /// Whether the full stack is pulled down. Read by `ActivityStatusBarView`
    /// to decide how many of `rows` to actually mount, and by
    /// `currentCapsuleFrame()` to size the panel to match. Driven by hover
    /// over the panel's content — see `setListHovering(_:)`.
    @Published fileprivate(set) var isExpanded = false

    /// Every thread currently believed to be running, keyed by
    /// `CodexActivityMonitor.ThreadActivity.key` — lets `apply(_:)` notice
    /// when *a specific* thread (not just "some" thread) transitions from
    /// running to finished while others keep going. This is a lookup table,
    /// not the source of display order — see `lastRunningRows`.
    private var runningByKey: [String: ProjectActivity] = [:]
    /// The running rows from the most recent poll, already in the DB's own
    /// recency order and already capped to `maxRunningRows` — `rebuildDisplay()`
    /// reuses this rather than re-deriving it from `runningByKey` (a plain
    /// dictionary, whose iteration order is not guaranteed stable) whenever
    /// it's called from somewhere other than a fresh poll, namely a
    /// completion notice's own clear timer.
    private var lastRunningRows: [CapsuleRow] = []
    /// The latest finish still within its prominent five-second announcement
    /// window. Earlier finishes are not discarded; they move to
    /// `retainedCompletions` at the end of the expanded running list.
    private var completedAnnouncement: RetainedCompletion?
    /// Completed tasks kept behind the running rows for at most two minutes.
    /// When the last running task finishes, the remaining shelf becomes the
    /// 30-second all-completed summary instead of being discarded.
    private var retainedCompletions: [RetainedCompletion] = []
    /// True while the final, all-tasks-completed state owns the capsule. With
    /// one completion it shows that project directly; with several it shows
    /// a compact summary until clicked.
    private var isAllCompletedPresentationActive = false
    /// Clicking the multi-completion summary pins its detail rows open until
    /// they are consumed individually or the user clicks outside the panel.
    private var isCompletionReviewExpanded = false
    /// Latest repository update discovered by the six-hour checker. It is
    /// appended only while task activity already makes the capsule visible.
    private var updateNotice: AppUpdateNotice?
    /// A thread whose rollout just went idle, but not trusted yet. Codex
    /// marks the end of *every* internal turn with the same `task_complete`
    /// label this reads, including turns inside a longer autonomous run that
    /// continues into another turn within milliseconds — a real rollout on
    /// this machine showed 20+ `task_complete` → `task_started` pairs a
    /// single-digit number of *milliseconds* apart. Firing the completion
    /// chime/notice on the first idle poll announced "done" for every one of
    /// those internal turn boundaries, not just the real end. Now a thread
    /// has to stay idle across `completionConfirmPolls` consecutive polls —
    /// i.e. survive at least one more full poll interval — before its
    /// completion is trusted; if it starts running again before then, this
    /// is just discarded and nothing was ever announced.
    private var pendingCompletions: [String: (project: String, outcome: ActivityOutcome?, remainingPolls: Int)] = [:]

    private var pollTimer: Timer?
    /// A first activity pass can need to inspect a large current rollout.
    /// Skipping timer ticks while that pass is still in flight prevents a
    /// backlog of duplicate SQLite/JSONL reads from delaying the very capsule
    /// those reads are trying to display.
    private var isPolling = false
    private var hideWorkItem: DispatchWorkItem?
    /// Clears `completedAnnouncement` once it's had its
    /// `completionAnnouncementDuration` on screen. Cancelled if a new
    /// completion supersedes it, or if its own thread starts running again,
    /// before that timer fires.
    private var announcementClearWorkItem: DispatchWorkItem?
    /// Removes the earliest two-minute completion shelf entry at its exact
    /// expiry time. Polling would eventually do this too, but an exact timer
    /// prevents the row lingering for another expanded 10-second poll cycle.
    private var retentionClearWorkItem: DispatchWorkItem?
    /// Passive all-completed state expires after 30 seconds. Entering the
    /// explicit review state cancels this timer.
    private var allCompletedClearWorkItem: DispatchWorkItem?
    private var localOutsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?
    /// A short grace period before actually collapsing after the pointer
    /// leaves — mirrors `NotchWindowController.scheduleAutoClose`'s reasoning:
    /// enough slack to not flicker shut on a momentary gap, short enough to
    /// still feel responsive.
    private var collapseWorkItem: DispatchWorkItem?
    /// The single fresh reading taken after a hover-expand has settled — see
    /// `schedulePostExpandPoll()`.
    private var hoverPollWorkItem: DispatchWorkItem?
    /// The frame the panel is resting at or currently animating toward. Every
    /// poll runs through `resizeForCurrentContent()`, but the frame only
    /// genuinely changes when a row is added/removed or the stack
    /// expands/collapses; without this, an identical `setFrame` restarted the
    /// spring from wherever the in-flight one had reached, which is exactly
    /// what a poll landing during the hover expand looked like.
    private var targetFrame: CGRect = .zero
    /// Identifies the most recently started resize so a superseded animation's
    /// completion handler can't restore `panel.hasShadow` in the middle of the
    /// one that replaced it — which would put the per-frame shadow recompute
    /// `resizeForCurrentContent()` exists to avoid back into the animation
    /// still playing.
    private var resizeGeneration = 0
    /// Tracks the panel's *intended* visibility (not `panel.isVisible`,
    /// which still reads true mid-fade-out) so `updateVisibility()` can tell
    /// whether it actually needs to do anything, and so a stale, already-
    /// superseded `hideWorkItem` knows not to order the panel out from under
    /// a show that happened right after it was scheduled.
    private var isPanelVisible = false
    private var isScreenshotSuppressed = false
    private var isDashboardPresented = false
    /// User-facing on/off switch from the status-item menu. Polling continues
    /// while hidden so re-enabling immediately reflects current activity.
    private(set) var isEnabled = ActivityStatusBarController.loadEnabledPreference()

    /// Match the visible dashboard's near-live cadence closely enough to catch
    /// short screen-control calls. The monitor only performs bounded metadata
    /// and rollout-tail reads, and `isPolling` still prevents overlap.
    private static let pollIntervalCollapsed: TimeInterval = 1.5
    /// Keep the phase equally trustworthy while someone is inspecting the
    /// expanded stack. The fixed two-line token readout no longer shifts the
    /// surrounding row as values change, so the faster refresh stays calm.
    private static let pollIntervalExpanded: TimeInterval = 2
    /// Every row — running or completed — keeps a fixed height so the spring
    /// grow-in transition has its vertical frame before SwiftUI lays content
    /// out. Width is intentionally absent here: on a notched Mac it comes from
    /// the physical cutout, and this size is used only when macOS reports no
    /// notch (for example on an external monitor).
    private static let fallbackCapsuleSize = CGSize(width: 190, height: 32)
    static let rowSpacing: CGFloat = 4
    /// However many projects are genuinely running in parallel, the
    /// expanded stack only ever shows the `maxRunningRows` most recently
    /// active ones — a hard cap so a runaway number of threads can't push
    /// the pill stack off the bottom of the screen.
    private static let maxRunningRows = 10
    /// How long a finished run temporarily occupies the first row as an
    /// announcement before moving behind the running projects.
    private static let completionAnnouncementDuration: TimeInterval = 5
    /// How many *consecutive* idle polls a thread must show before its
    /// completion is trusted — see `pendingCompletions`. 2 means: seen idle
    /// now, and still idle next poll too, so at least one full poll interval
    /// (`pollIntervalCollapsed`/`pollIntervalExpanded`, whichever is
    /// currently active) has to pass with no renewed activity.
    private static let completionConfirmPolls = 2
    /// A small gap under the notch — this pill reads as its own floating
    /// object now, not a flush continuation of the notch's own shape.
    private static let gapBelowNotch: CGFloat = 6
    private static let codexBundleID = "com.openai.codex"
    private static let enabledDefaultsKey = "activityCapsuleEnabled"

    private static func loadEnabledPreference() -> Bool {
        guard UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }
    override init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Clickable (opens Codex) and hoverable (pulls the stack down) — the
        // SwiftUI content already fills the panel's bounds exactly with the
        // visible pill shape(s), so there's no invisible dead zone this
        // would newly intercept clicks in.
        panel.ignoresMouseEvents = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.alphaValue = 0
        super.init()

        let hosting = NSHostingView(rootView: ActivityStatusBarView(controller: self))
        panel.contentView = hosting
        panel.setFrame(currentCapsuleFrame(), display: false)
        targetFrame = panel.frame

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        if CommandLine.arguments.contains("--demo") {
            isEnabled = true
            if !CommandLine.arguments.contains("--open") {
                let now = Date()
                rows = [
                    CapsuleRow(
                        id: "demo-active",
                        threadID: nil,
                        display: .active(
                            ProjectActivity(
                                project: "aibar",
                                conversationTitle: "优化活动胶囊展示",
                                goalObjective: "完善活动胶囊的对话与计划显示",
                                model: "gpt-5.6-sol",
                                phase: .usingScreen,
                                lastActivityAt: now,
                                startedAt: now.addingTimeInterval(-6_643),
                                timingScope: .continuousGoal,
                                currentContextTokens: 184_000,
                                conversationTokens: 789_000_000,
                                sandboxPolicy: "workspace-write",
                                approvalMode: "on-request",
                                threadID: "preview-thread"
                            )
                        )
                    )
                ]
            }
            panel.setFrame(currentCapsuleFrame(), display: false)
            targetFrame = panel.frame
            updateVisibility()
        } else {
            poll()
            restartPollTimer(interval: Self.pollIntervalCollapsed)
        }
    }

    deinit {
        pollTimer?.invalidate()
        announcementClearWorkItem?.cancel()
        retentionClearWorkItem?.cancel()
        allCompletedClearWorkItem?.cancel()
        collapseWorkItem?.cancel()
        hoverPollWorkItem?.cancel()
        if let localOutsideClickMonitor { NSEvent.removeMonitor(localOutsideClickMonitor) }
        if let globalOutsideClickMonitor { NSEvent.removeMonitor(globalOutsideClickMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        let monitor = monitor
        // Fetches comfortably more than `maxRunningRows` — some of the most
        // recently updated threads in that window may already be idle, so
        // the raw row limit needs headroom above the display cap to still
        // reliably find `maxRunningRows` actually-running ones among them.
        Task.detached(priority: .utility) { [weak self] in
            let states = monitor.activeThreadStates(limit: 20)
            guard let self else { return }
            await self.apply(states)
            await self.finishPolling()
        }
    }

    private func finishPolling() {
        isPolling = false
    }

    private func restartPollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    private func apply(_ states: [CodexActivityMonitor.ThreadActivity]) {
        var stillRunningKeys = Set<String>()
        var runningRows: [CapsuleRow] = []
        for entry in states {
            switch entry.state {
            case .active(let activity):
                stillRunningKeys.insert(entry.key)
                runningByKey[entry.key] = activity
                // Confirmed premature: this thread looked idle on a
                // previous poll but has already started running again, so
                // that was just an internal turn boundary, not a real end —
                // discard the pending completion without ever announcing it.
                pendingCompletions[entry.key] = nil
                // That thread is back to running after an *already
                // announced* completion — e.g. a follow-up turn started
                // right after the confirmed one — so its notice no longer
                // applies.
                removeCompletion(for: entry.key)
                // `states` already arrives in `activeThreadStates`'s own
                // `ORDER BY updated_at_ms DESC` — appending in that same
                // order (and simply stopping once there are enough) is the
                // entire "which 10" policy; no separate sort needed.
                if runningRows.count < Self.maxRunningRows {
                    runningRows.append(CapsuleRow(id: "active-\(entry.key)", threadID: entry.key, display: .active(activity)))
                }
            case .idle(let outcome):
                // Only a thread this controller had actually seen running
                // gets a notice — an idle thread it never observed active
                // (e.g. one that finished before the app launched) has
                // nothing new to announce.
                guard let previous = runningByKey[entry.key] else { continue }
                let remaining = (pendingCompletions[entry.key]?.remainingPolls ?? Self.completionConfirmPolls) - 1
                if remaining > 0 {
                    // Not trusted yet — keep it, and keep showing the row as
                    // still running (using its last known state) rather than
                    // blinking it away only to possibly bring it right back.
                    pendingCompletions[entry.key] = (project: previous.displayTitle, outcome: outcome, remainingPolls: remaining)
                    stillRunningKeys.insert(entry.key)
                    if runningRows.count < Self.maxRunningRows {
                        runningRows.append(CapsuleRow(id: "active-\(entry.key)", threadID: entry.key, display: .active(previous)))
                    }
                } else {
                    // Idle across `completionConfirmPolls` polls in a row —
                    // trusted now. A distinct chime per outcome is the whole
                    // point of an always-on indicator: you don't have to be
                    // looking at the screen to know whether a run finished,
                    // was interrupted, or just went quiet.
                    pendingCompletions[entry.key] = nil
                    playSound(for: outcome)
                    announceCompletion(
                        key: entry.key,
                        project: previous.displayTitle,
                        outcome: outcome ?? .completed
                    )
                }
            }
        }
        // Threads that dropped out of the tracked row set entirely (archived,
        // or aged out of `activeThreadStates`'s row limit) without an
        // explicit idle event above still stop counting as running — just
        // silently, since there's no outcome to announce for them.
        for key in runningByKey.keys where !stillRunningKeys.contains(key) {
            runningByKey[key] = nil
            pendingCompletions[key] = nil
        }

        lastRunningRows = runningRows
        pruneRetainedCompletions()
        if lastRunningRows.isEmpty, !retainedCompletions.isEmpty {
            beginAllCompletedPresentationIfNeeded()
        } else if !lastRunningRows.isEmpty, isAllCompletedPresentationActive {
            endAllCompletedPresentation(clearCompletions: false, collapse: false)
            pruneRetainedCompletions()
        }
        rebuildDisplay()
        scheduleRetentionClear()
    }

    /// Recomputes `rows` from the current running list and completion state.
    /// The latest announcement temporarily sorts first; running projects
    /// keep their monitor order; retained completions are always last.
    private func rebuildDisplay() {
        let newRows = ActivityCapsulePolicy.rows(
            running: lastRunningRows,
            announcement: completedAnnouncement,
            retained: retainedCompletions,
            completionReviewExpanded: isCompletionReviewExpanded,
            updateNotice: updateNotice
        )

        // Only a change to *which* rows exist is worth a spring transaction —
        // that's the case where SwiftUI actually has something to animate
        // (a row sliding in or out). A poll that merely refreshed a token
        // count or an elapsed time used to open the same 0.28s animation
        // every 5 seconds, re-animating every row in the stack over a change
        // no one can see; `LiveTokenReadout` already animates its own digits.
        // Identical rows are skipped outright.
        if newRows.map(\.id) != rows.map(\.id) {
            withAnimation(.notchSpring) {
                rows = newRows
            }
        } else if newRows != rows {
            rows = newRows
        }
        resizeForCurrentContent()
        updateVisibility()
    }

    private func announceCompletion(key: String, project: String, outcome: ActivityOutcome) {
        let completion = RetainedCompletion(
            key: key,
            project: project,
            outcome: outcome,
            completedAt: Date()
        )
        retainedCompletions.removeAll { $0.key == key }
        retainedCompletions.append(completion)
        completedAnnouncement = completion

        announcementClearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.completedAnnouncement?.key == key else { return }
            self.completedAnnouncement = nil
            self.pruneRetainedCompletions()
            self.rebuildDisplay()
            self.scheduleRetentionClear()
        }
        announcementClearWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.completionAnnouncementDuration,
            execute: work
        )
    }

    private func removeCompletion(for key: String) {
        retainedCompletions.removeAll { $0.key == key }
        guard completedAnnouncement?.key == key else { return }
        announcementClearWorkItem?.cancel()
        announcementClearWorkItem = nil
        completedAnnouncement = nil
    }

    private func beginAllCompletedPresentationIfNeeded() {
        guard !isAllCompletedPresentationActive else { return }
        isAllCompletedPresentationActive = true
        isCompletionReviewExpanded = false

        // The per-task five-second announcement is replaced by the clearer
        // all-completed state as soon as the final running row disappears.
        announcementClearWorkItem?.cancel()
        announcementClearWorkItem = nil
        completedAnnouncement = nil
        retentionClearWorkItem?.cancel()
        retentionClearWorkItem = nil

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isAllCompletedPresentationActive,
                  !self.isCompletionReviewExpanded
            else { return }
            self.endAllCompletedPresentation(clearCompletions: true, collapse: true)
            self.rebuildDisplay()
        }
        allCompletedClearWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ActivityCapsulePolicy.allCompletedRetentionDuration,
            execute: work
        )
    }

    private func beginCompletionReview() {
        guard isAllCompletedPresentationActive, retainedCompletions.count > 1 else { return }
        allCompletedClearWorkItem?.cancel()
        allCompletedClearWorkItem = nil
        isCompletionReviewExpanded = true
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        installOutsideClickMonitors()

        if !isExpanded {
            withAnimation(.notchSpring) { isExpanded = true }
            restartPollTimer(interval: Self.pollIntervalExpanded)
            schedulePostExpandPoll()
        }
        rebuildDisplay()
    }

    private func endAllCompletedPresentation(clearCompletions: Bool, collapse: Bool) {
        allCompletedClearWorkItem?.cancel()
        allCompletedClearWorkItem = nil
        isAllCompletedPresentationActive = false
        isCompletionReviewExpanded = false
        removeOutsideClickMonitors()
        if clearCompletions { retainedCompletions.removeAll() }

        guard collapse, isExpanded else { return }
        withAnimation(.notchSpring) { isExpanded = false }
        restartPollTimer(interval: Self.pollIntervalCollapsed)
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        // Install after the summary's own click has finished propagating, so
        // that opening click cannot immediately dismiss the review it opened.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCompletionReviewExpanded else { return }
            self.localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self else { return event }
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.dismissCompletionReview()
                }
                return event
            }
            self.globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismissCompletionReview() }
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }
    }

    private func dismissCompletionReview() {
        guard isCompletionReviewExpanded else { return }
        endAllCompletedPresentation(clearCompletions: true, collapse: true)
        rebuildDisplay()
    }

    private func pruneRetainedCompletions(now: Date = Date()) {
        retainedCompletions = ActivityCapsulePolicy.retainedCompletions(
            from: retainedCompletions,
            now: now,
            hasRunningProjects: !lastRunningRows.isEmpty
        )
    }

    private func scheduleRetentionClear(now: Date = Date()) {
        retentionClearWorkItem?.cancel()
        retentionClearWorkItem = nil
        guard !lastRunningRows.isEmpty,
              let nextExpiry = retainedCompletions
                .map({ $0.completedAt.addingTimeInterval(ActivityCapsulePolicy.completionRetentionDuration) })
                .min()
        else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pruneRetainedCompletions()
            self.rebuildDisplay()
            self.scheduleRetentionClear()
        }
        retentionClearWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, nextExpiry.timeIntervalSince(now)),
            execute: work
        )
    }

    /// Called by `ActivityStatusBarView` as the pointer enters/leaves the
    /// panel's content. Entering pulls the full stack down immediately and
    /// schedules a single fresh reading for once that motion has settled (see
    /// `schedulePostExpandPoll()`), then drops the poll cadence to
    /// `pollIntervalExpanded` so the numbers don't visibly
    /// jitter while being read up close. Leaving waits out a short grace
    /// period (see `collapseWorkItem`) before collapsing back to just the
    /// top row and restoring the faster cadence, in case the exit was only
    /// a momentary gap during the resize animation. `isExpanded` is animated
    /// with `.notchSpring` — the same control points and duration as the
    /// `NSAnimationContext`/`CAMediaTimingFunction.notchSpring` driving
    /// `resizeForCurrentContent()`'s AppKit frame change — so the SwiftUI
    /// rows revealing/hiding and the panel growing/shrinking around them
    /// move on matching curves instead of two independent animations
    /// drifting out of step with each other.
    func setListHovering(_ hovering: Bool) {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        // An explicitly opened completion review is click-driven, not hover-
        // driven. Leaving the panel keeps it open; an outside click is the
        // deliberate dismissal gesture.
        if !hovering, isCompletionReviewExpanded { return }
        guard hovering != isExpanded else { return }
        if hovering {
            withAnimation(.notchSpring) { isExpanded = true }
            resizeForCurrentContent()
            restartPollTimer(interval: Self.pollIntervalExpanded)
            schedulePostExpandPoll()
        } else {
            hoverPollWorkItem?.cancel()
            hoverPollWorkItem = nil
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                withAnimation(.notchSpring) { self.isExpanded = false }
                self.resizeForCurrentContent()
                self.restartPollTimer(interval: Self.pollIntervalCollapsed)
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    /// A fresh reading of what the newly revealed rows are showing, held back
    /// until the expand animation has finished. Polling the instant the
    /// pointer arrived put a SQLite read plus a full row rebuild — and, before
    /// `resizeForCurrentContent()`'s target check, a whole second competing
    /// `setFrame` — directly on top of the animation still playing, which is
    /// what read as a stutter right as the stack came down. Nothing revealed
    /// is more than one poll interval stale, so a third of a second's wait for
    /// the refresh is invisible in a way the hitch very much wasn't.
    private func schedulePostExpandPoll() {
        hoverPollWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isExpanded else { return }
            self.poll()
        }
        hoverPollWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    /// The single source of truth for whether the panel is on screen: simply
    /// whether there's anything to show and the user hasn't turned the
    /// capsule off. It floats above every app — including Codex itself —
    /// deliberately: an earlier version hid it whenever Codex was frontmost
    /// on the theory that Codex's own window already made the state obvious,
    /// but in practice that meant the completion chime played with no
    /// visible capsule to match it whenever a run finished while Codex had
    /// focus, which is exactly when someone is most likely to be watching
    /// for it. Called whenever activity state changes.
    private func updateVisibility() {
        let shouldShow = FloatingSurfaceVisibilityPolicy.showsActivityCapsule(
            enabled: isEnabled,
            hasContent: !rows.isEmpty,
            dashboardPresented: isDashboardPresented,
            screenshotSuppressed: isScreenshotSuppressed
        )
        guard shouldShow != isPanelVisible else {
            // The notch dashboard is a separate status-level panel. Opening
            // it (or a Space/display transition) can reorder it above this
            // already-visible capsule; previously the equality guard meant
            // an active capsule then had no path back to the front until its
            // contents changed. Polling is already the source of truth for
            // live activity, so use each successful refresh to reassert the
            // intended always-on layer without changing its visibility state.
            if shouldShow { panel.orderFrontRegardless() }
            return
        }
        isPanelVisible = shouldShow
        if shouldShow {
            hideWorkItem?.cancel()
            targetFrame = currentCapsuleFrame()
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            // Let the fade-out transition actually play before pulling the
            // window away — pulling it immediately would just cut the
            // animation off mid-flight. `isPanelVisible` (not `shouldShow`
            // recomputed fresh) is the guard here so a show that happens
            // right after this was scheduled correctly wins.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isPanelVisible else { return }
                self.panel.orderOut(nil)
            }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func setDashboardPresented(_ presented: Bool) {
        guard presented != isDashboardPresented else { return }
        isDashboardPresented = presented
        if presented {
            // Dashboard presentation is a hard mutual-exclusion boundary, so
            // do not leave the capsule ordered on screen for the normal
            // fade-out grace period.
            hideWorkItem?.cancel()
            isPanelVisible = false
            panel.orderOut(nil)
        } else {
            updateVisibility()
        }
    }

    /// Wired to the menu bar icon's right-click menu.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        updateVisibility()
    }

    /// Keeps the always-on activity capsule out of screenshots made by this
    /// app, then restores it if there is still activity to show.
    func setScreenshotSuppressed(_ suppressed: Bool) {
        guard suppressed != isScreenshotSuppressed else { return }
        isScreenshotSuppressed = suppressed
        updateVisibility()
    }

    func setUpdateNotice(_ notice: AppUpdateNotice?) {
        guard notice != updateNotice else { return }
        updateNotice = notice
        rebuildDisplay()
    }

    private func playSound(for outcome: ActivityOutcome?) {
        let name: NSSound.Name
        switch outcome {
        case .completed: name = "Glass"
        case .aborted: name = "Basso"
        case .timedOut, .none: name = "Tink"
        }
        NSSound(named: name)?.play()
    }

    /// Centered directly under the notch, with a small gap — see
    /// `NotchGeometry`. Height fits exactly one row when collapsed, or the
    /// whole `rows` stack when `isExpanded` — grown/shrunk dynamically
    /// rather than reserving a fixed worst-case height so the extra space
    /// when fewer rows are showing doesn't sit there swallowing clicks meant
    /// for whatever's underneath.
    private func currentCapsuleFrame() -> CGRect {
        let displayedRowCount = isExpanded ? rows.count : min(rows.count, 1)
        let height = stackHeight(forRowCount: displayedRowCount)
        guard let screen = NotchGeometry.targetScreen() else {
            return CGRect(origin: .zero, size: CGSize(
                width: Self.fallbackCapsuleSize.width,
                height: height
            ))
        }
        let notch = NotchGeometry.rect(on: screen, fallbackSize: Self.fallbackCapsuleSize)
        let width = notch.width
        let x = notch.midX - width / 2
        // A hard backstop against the display itself, not a size the stack is
        // expected to reach in practice — `maxRunningRows` already keeps the
        // un-clamped height well under any real screen.
        let clampedHeight = min(height, NotchGeometry.availableHeightBelow(
            notch: notch, screenFrame: screen.frame,
            gap: Self.gapBelowNotch, minimum: Self.fallbackCapsuleSize.height
        ))
        let y = notch.minY - Self.gapBelowNotch - clampedHeight
        return CGRect(x: x, y: y, width: width, height: clampedHeight)
    }

    private func stackHeight(forRowCount rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return Self.fallbackCapsuleSize.height }
        return CGFloat(rowCount) * Self.fallbackCapsuleSize.height
            + CGFloat(rowCount - 1) * Self.rowSpacing
    }

    /// Grows/shrinks the already-visible panel when a row is added, removed,
    /// or the stack expands/collapses. Skipped while the panel isn't showing
    /// at all — `updateVisibility()` sets the (already-current) frame itself
    /// when bringing the panel on screen, so animating here too would just
    /// race it.
    private func resizeForCurrentContent() {
        guard isPanelVisible else { return }
        // Polls run through here far more often than the frame actually
        // changes. Re-issuing an identical `setFrame` isn't free: it restarts
        // the timing curve from the in-flight position, so a poll arriving
        // partway through the hover expand visibly reset the motion — the
        // single largest contributor to the stutter this guard removes.
        let target = currentCapsuleFrame()
        guard target != targetFrame else { return }
        targetFrame = target

        // For a borderless, irregularly-shaped, transparent panel like this
        // one, AppKit recomputes the native window shadow's mask against the
        // actual rendered content on every frame it's asked to redraw —
        // including every frame of an animated `setFrame`. Hovering is the
        // most frequent trigger of this resize (far more often than a poll
        // picking up a new row), so that per-frame shadow recompute is what
        // read as visible stutter right as the pointer arrived. Dropping the
        // shadow for the animation's ~0.28s and restoring it once the frame
        // settles trades an imperceptible, motion-masked gap in the shadow
        // for a smooth resize. Only the newest resize may restore it — an
        // earlier, superseded animation finishing mid-flight would otherwise
        // switch the recompute back on for the remainder of this one.
        resizeGeneration += 1
        let generation = resizeGeneration
        panel.hasShadow = false
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.28
                context.timingFunction = .notchSpring
                panel.animator().setFrame(target, display: true)
            },
            completionHandler: {
                Task { @MainActor [weak self] in
                    guard let self, self.resizeGeneration == generation else { return }
                    self.panel.hasShadow = true
                }
            }
        )
    }

    /// Brings Codex (ChatGPT.app's Codex surface — the same app whose local
    /// `state_5.sqlite` this whole feature reads) to the front, and — when
    /// `threadID` is given — navigates straight to that specific thread
    /// rather than whatever Codex last happened to have open. The deep link
    /// (`codex://threads/<id>`) isn't a documented API; it was found by
    /// inspecting strings inside ChatGPT.app's bundled JS
    /// (`grep -a -o 'codex://threads/' app.asar`), so a resolution failure or
    /// a future scheme change just falls back to foregrounding the app
    /// generically instead of a specific thread.
    func openCodex(threadID: String? = nil) {
        if let threadID,
           let encodedID = threadID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "codex://threads/\(encodedID)")
        {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexBundleID) {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "codex://") {
            NSWorkspace.shared.open(url)
        }
    }

    func activate(_ row: CapsuleRow) {
        switch row.display {
        case .completionSummary:
            beginCompletionReview()
            return
        case .completed:
            // A completion is an actionable notification: consuming it opens
            // the corresponding task and removes the row immediately instead
            // of leaving an already-read item around for its passive timeout.
            if let threadID = row.threadID {
                removeCompletion(for: threadID)
            }
            if retainedCompletions.isEmpty, isAllCompletedPresentationActive {
                endAllCompletedPresentation(clearCompletions: true, collapse: true)
            }
            rebuildDisplay()
            scheduleRetentionClear()
            openCodex(threadID: row.threadID)
            return
        case .update(let notice):
            if let packageURL = notice.packageURL {
                NSWorkspace.shared.activateFileViewerSelecting([packageURL])
            } else {
                NSWorkspace.shared.open(notice.releaseURL)
            }
            return
        case .active:
            openCodex(threadID: row.threadID)
        }
    }

    @objc private func screenParametersChanged() {
        targetFrame = currentCapsuleFrame()
        panel.setFrame(targetFrame, display: true)
    }
}
