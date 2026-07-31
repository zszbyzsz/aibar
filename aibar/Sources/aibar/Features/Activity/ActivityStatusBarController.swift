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
/// `maxRunningRows` of them. Clicking any pill brings Codex itself to the
/// front.
@MainActor
final class ActivityStatusBarController: NSObject, ObservableObject {
    private let panel: NSPanel
    private let monitor = CodexActivityMonitor()
    /// Read by `ActivityStatusBarView`. Order matters: a just-finished
    /// project's `.completed` notice (if any) is always first, followed by
    /// every currently running project in whatever order
    /// `CodexActivityMonitor.activeThreadStates` returned them — that's
    /// already `ORDER BY updated_at_ms DESC` (most recently active first),
    /// so there's deliberately no additional sort applied here; re-deriving
    /// an order (e.g. by running duration) both adds work and risks the list
    /// visibly reordering itself between polls for no reason a viewer would
    /// notice or want. Collapsed, only `rows.first` is drawn (see
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
    /// The most recent finish still within its display window. Only one is
    /// kept — if a second project finishes while this one is still showing,
    /// it simply replaces it rather than queueing, so the top row is always
    /// the single latest outcome rather than a growing backlog of them.
    private var completedNotice: (key: String, project: String, outcome: ActivityOutcome)?
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
    private var hideWorkItem: DispatchWorkItem?
    /// Clears `completedNotice` once it's had its `completionDisplayDuration`
    /// on screen. Cancelled if a new completion supersedes it, or if its own
    /// thread starts running again, before that timer fires.
    private var completionClearWorkItem: DispatchWorkItem?
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
    /// User-facing on/off switch (menu bar icon's right-click menu),
    /// persisted across launches. Polling and sound still run while
    /// disabled — only the pill itself stays off screen — so re-enabling
    /// picks up whatever's currently active within one poll interval
    /// instead of waiting for the next state transition.
    private(set) var isEnabled = ActivityStatusBarController.loadEnabledPreference()

    /// Loose enough not to matter perf-wise or read as needlessly chatty —
    /// this only ever does a bounded SQLite read plus a bounded tail read of
    /// a handful of JSONL files. Used while collapsed; `pollIntervalExpanded`
    /// takes over once someone's actually looking at the stack.
    private static let pollIntervalCollapsed: TimeInterval = 5
    /// While the stack is expanded (someone's pointer is on it, actively
    /// reading), token counts and elapsed times updating every 2s reads as
    /// distracting flicker rather than useful liveness — slowing to once
    /// every 10s keeps the numbers moving without them visibly jittering
    /// under a closer look.
    private static let pollIntervalExpanded: TimeInterval = 10
    /// Every row — running or completed — is this same fixed size. Fixed
    /// rather than measured from content, which sidesteps sizing the window
    /// only after SwiftUI has already laid the content out once (the spring
    /// grow-in transition needs the frame correct before it plays, not after).
    private static let capsuleSize = CGSize(width: 190, height: 32)
    static let rowSpacing: CGFloat = 4
    /// However many projects are genuinely running in parallel, the
    /// expanded stack only ever shows the `maxRunningRows` most recently
    /// active ones — a hard cap so a runaway number of threads can't push
    /// the pill stack off the bottom of the screen.
    private static let maxRunningRows = 10
    /// How long a finished run's checkmark/outcome stays on screen before the
    /// capsule fades out on its own — long enough to actually read the
    /// project name and outcome (and, since the row is clickable the whole
    /// time, to click through to it), short enough to stay out of the way.
    private static let completionDisplayDuration: TimeInterval = 5
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

        poll()
        restartPollTimer(interval: Self.pollIntervalCollapsed)
    }

    deinit {
        pollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func poll() {
        let monitor = monitor
        // Fetches comfortably more than `maxRunningRows` — some of the most
        // recently updated threads in that window may already be idle, so
        // the raw row limit needs headroom above the display cap to still
        // reliably find `maxRunningRows` actually-running ones among them.
        Task.detached(priority: .utility) { [weak self] in
            let states = monitor.activeThreadStates(limit: 20)
            guard let self else { return }
            await self.apply(states)
        }
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
                if completedNotice?.key == entry.key {
                    completionClearWorkItem?.cancel()
                    completionClearWorkItem = nil
                    completedNotice = nil
                }
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
                    pendingCompletions[entry.key] = (project: previous.project, outcome: outcome, remainingPolls: remaining)
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
                    completedNotice = (key: entry.key, project: previous.project, outcome: outcome ?? .completed)
                    scheduleCompletionClear(for: entry.key)
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
        rebuildDisplay()
    }

    /// Recomputes `rows` from `lastRunningRows` and `completedNotice`. A
    /// just-finished project's notice always sorts first — occupying the
    /// single visible slot when collapsed, or the top of the stack when
    /// expanded — with every running project listed below it.
    private func rebuildDisplay() {
        var newRows: [CapsuleRow] = []
        if let completedNotice {
            newRows.append(CapsuleRow(
                id: "completed-\(completedNotice.key)",
                threadID: completedNotice.key,
                display: .completed(project: completedNotice.project, outcome: completedNotice.outcome)
            ))
        }
        newRows.append(contentsOf: lastRunningRows)

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

    private func scheduleCompletionClear(for key: String) {
        completionClearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.completedNotice?.key == key else { return }
            self.completedNotice = nil
            self.rebuildDisplay()
        }
        completionClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionDisplayDuration, execute: work)
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
        let shouldShow = isEnabled && !rows.isEmpty && !isScreenshotSuppressed
        guard shouldShow != isPanelVisible else { return }
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
        let width = Self.capsuleSize.width
        let displayedRowCount = isExpanded ? rows.count : min(rows.count, 1)
        let height = stackHeight(forRowCount: displayedRowCount)
        // `NSScreen.main` (the screen with the key window) can be nil for an
        // accessory app like this one, which never makes any window key —
        // `.screens.first` (the display with the menu bar) is the reliable
        // fallback rather than silently landing at the screen origin.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return CGRect(origin: .zero, size: CGSize(width: width, height: height))
        }
        let notch = NotchGeometry.rect(on: screen, fallbackSize: Self.capsuleSize)
        let x = notch.midX - width / 2
        // A hard backstop against the display itself, not a size the stack is
        // expected to reach in practice — `maxRunningRows` already keeps the
        // un-clamped height well under any real screen.
        let clampedHeight = min(height, NotchGeometry.availableHeightBelow(
            notch: notch, screenFrame: screen.frame,
            gap: Self.gapBelowNotch, minimum: Self.capsuleSize.height
        ))
        let y = notch.minY - Self.gapBelowNotch - clampedHeight
        return CGRect(x: x, y: y, width: width, height: clampedHeight)
    }

    private func stackHeight(forRowCount rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return Self.capsuleSize.height }
        return CGFloat(rowCount) * Self.capsuleSize.height + CGFloat(rowCount - 1) * Self.rowSpacing
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

    @objc private func screenParametersChanged() {
        targetFrame = currentCapsuleFrame()
        panel.setFrame(targetFrame, display: true)
    }
}
