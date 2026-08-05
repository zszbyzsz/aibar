import AppKit
import SwiftUI
import Combine

/// A borderless, non-activating panel pinned under the physical notch. Idle, it's
/// a fully invisible hotzone; hovering it reveals a wide real-time usage dashboard
/// (Codex or Claude Code, switchable in the header), which auto-hides again once
/// the pointer leaves — no click needed.
@MainActor
final class NotchWindowController: NSObject, ObservableObject {
    private let panel: NSPanel
    private var hostingView: NSHostingView<RootView>?
    let usageStore: UsageStore
    private var store: UsageStore { usageStore }
    // @Published (not a plain var) is what actually makes SwiftUI re-render RootView
    // when a hover event flips this — mutating a bare var here was a no-op as far as
    // SwiftUI's view graph was concerned, so the panel resized but kept showing the
    // invisible idle content.
    @Published private(set) var isExpanded = false
    /// Keeps the independently managed notch-side readouts and activity
    /// capsule informed when the dashboard owns the notch presentation.
    var onPresentationChange: ((Bool) -> Void)?
    private var idleFrame = CGRect.zero
    private var expandedFrame = CGRect.zero
    // Anchors for `expandedFrameRect(forHeight:)` — kept separately from
    // `expandedFrame` since they only change on `recomputeGeometry()`
    // (screen changes), not on every content-height update.
    private var screenMidX: CGFloat = 0
    private var screenMaxY: CGFloat = 0

    // Width stays fixed; height follows the dashboard's complete natural
    // content. There is deliberately no whole-dashboard height cap or outer
    // scroll view: the panel itself expands to contain the dashboard.
    /// Kept file-visible so `RootView` can lay the dashboard out at its final
    /// width even while the native window is still growing from the notch.
    /// Otherwise every animation frame proposes a different text width,
    /// continuously changing the measured height and retargeting the window.
    fileprivate static let expandedWidth: CGFloat = 720
    private static let initialExpandedHeight: CGFloat = 320

    private var closeWorkItem: DispatchWorkItem?
    /// A status-item click begins outside this panel's tracking view. Keep
    /// its close decision separate from `closeWorkItem`: AppKit may emit a
    /// synthetic enter while the panel is resizing, and `setExpanded(true)`
    /// correctly cancels the hover timer in that case but must not turn a
    /// status-bar-open dashboard into a permanently pinned one.
    private var statusItemAutoCloseWorkItem: DispatchWorkItem?
    private var keepsDashboardOpen = false
    private var isScreenshotSuppressed = false
    /// True while the share popover (or any other child popover the dashboard
    /// opens) is up. A `.popover` in SwiftUI opens its own separate window, so
    /// moving the pointer into it leaves `HoverTrackingView`'s bounds and
    /// would otherwise fire the normal `scheduleAutoClose()` — collapsing the
    /// panel (and with it, the popover anchored to a view inside it) the
    /// moment someone tries to reach the share options. This flag makes that
    /// hand-off inert until the popover itself reports it has closed.
    private var isPopoverOpen = false

    init(store: UsageStore) {
        usageStore = store
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Forces the vibrancy material to render dark regardless of the system's
        // appearance setting, matching the black "tech" card design regardless of
        // whether the user runs macOS in Light or Dark mode.
        panel.appearance = NSAppearance(named: .darkAqua)
        super.init()

        recomputeGeometry()
        panel.setFrame(idleFrame, display: false)
        let hostView = HoverTrackingView()
        hostView.onMouseEntered = { [weak self] in self?.setExpanded(true) }
        hostView.onMouseExited = { [weak self] in self?.scheduleAutoClose() }
        let hosting = NSHostingView(rootView: rootView())
        hostingView = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: hostView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
        panel.contentView = hostView
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        store.start()
    }

    private func rootView() -> RootView {
        RootView(store: store, controller: self)
    }

    /// Called from `DashboardHeader` whenever its share popover opens or
    /// closes. Opening cancels/suppresses the hover auto-close outright;
    /// closing re-arms it, since the pointer may by then already be outside
    /// both the popover and the hover hotzone.
    func setPopoverOpen(_ open: Bool) {
        isPopoverOpen = open
        if open {
            closeWorkItem?.cancel()
            closeWorkItem = nil
        } else {
            scheduleAutoClose()
        }
    }

    /// Fed by `DashboardView`'s own height measurement each time its content
    /// changes size (language switch, more/fewer models, a longer footnote…),
    /// so the panel always fits exactly what it's showing instead of sitting
    /// at some fixed guess. Reuses the hover-expand animation when already
    /// open so a resize mid-visit still glides instead of jumping.
    func setContentHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        // GeometryReader can report the same layout with tiny floating-point
        // differences while AppKit is animating the panel. Pixel-align and
        // ignore equivalent frames so one content change produces one resize.
        let scale = panel.screen?.backingScaleFactor
            ?? NotchGeometry.targetScreen()?.backingScaleFactor
            ?? 1
        let alignedHeight = ceil(height * scale) / scale
        let newFrame = expandedFrameRect(forHeight: alignedHeight)
        guard abs(newFrame.height - expandedFrame.height) >= 1 / scale else { return }
        expandedFrame = newFrame
        guard isExpanded else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = .notchSpring
            panel.animator().setFrame(expandedFrame, display: true)
        }
    }

    private func expandedFrameRect(forHeight height: CGFloat) -> CGRect {
        let clamped = max(height, 1)
        return CGRect(
            x: screenMidX - Self.expandedWidth / 2, y: screenMaxY - clamped,
            width: Self.expandedWidth, height: clamped
        )
    }

    /// Read by the menu-bar status item, which has no hover concept of its own
    /// and needs to label itself "Show" vs "Hide" for whatever state we're in.
    var currentLanguage: AppLanguage { store.language }

    /// Entry point for the status-bar icon's click-to-toggle. A click begins
    /// outside this panel's tracking area, so merely expanding would leave no
    /// later `mouseExited` event to initiate the normal close. The dedicated
    /// timer checks the actual cursor location after the opening animation;
    /// it is intentionally not cancelled by an incidental tracking event
    /// emitted while AppKit resizes the panel.
    func toggleExpandedByClick() {
        // `--open` is useful for getting a freshly launched development
        // build on screen, but it must not permanently change the behaviour
        // of the normal status-bar control. The first deliberate click hands
        // control back to the standard hover/click lifecycle.
        keepsDashboardOpen = false
        statusItemAutoCloseWorkItem?.cancel()
        statusItemAutoCloseWorkItem = nil
        if isExpanded {
            setExpanded(false)
        } else {
            setExpanded(true)
            scheduleStatusItemAutoClose()
        }
    }

    /// Keeps the dashboard open when launched with `--open`. This is useful
    /// for local UI checks and screenshots; normal launches retain the
    /// hover-to-reveal interaction and its automatic close behavior.
    func showDashboardForPreview() {
        keepsDashboardOpen = true
        setExpanded(true)
    }

    /// Temporarily removes aibar's own floating chrome while the system
    /// selection overlay is active, so the app does not accidentally appear
    /// inside the screenshot. Restoring brings back the normal idle hotzone.
    func setScreenshotSuppressed(_ suppressed: Bool) {
        guard suppressed != isScreenshotSuppressed else { return }
        isScreenshotSuppressed = suppressed
        if suppressed {
            setExpanded(false)
            panel.orderOut(nil)
        } else {
            panel.setFrame(idleFrame, display: false)
            panel.orderFrontRegardless()
        }
    }

    @objc private func screenParametersChanged() {
        recomputeGeometry()
        panel.setFrame(isExpanded ? expandedFrame : idleFrame, display: true)
    }

    /// Delegates to `NotchGeometry` (shared with `ActivityStatusBarController`)
    /// so the idle hotzone and the always-on activity capsule stay pixel-aligned.
    private func recomputeGeometry() {
        guard let screen = NotchGeometry.targetScreen() else { return }
        let frame = screen.frame
        idleFrame = NotchGeometry.rect(
            on: screen,
            fallbackSize: NotchGeometry.softwareCapsuleSize(on: screen)
        )

        screenMidX = frame.midX
        screenMaxY = frame.maxY
        // No content-height measurement has come in yet on the very first
        // call (the dashboard isn't even mounted until the first hover), so
        // this starts with a compact provisional height — `setContentHeight`
        // replaces it with the measured content height immediately after the
        // dashboard mounts.
        let priorHeight = expandedFrame == .zero ? Self.initialExpandedHeight : expandedFrame.height
        expandedFrame = expandedFrameRect(forHeight: priorHeight)
    }

    private func setExpanded(_ expanded: Bool) {
        closeWorkItem?.cancel()
        closeWorkItem = nil
        if !expanded {
            statusItemAutoCloseWorkItem?.cancel()
            statusItemAutoCloseWorkItem = nil
        }
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        if expanded {
            // Companions disappear before the dashboard begins growing.
            onPresentationChange?(true)
        }
        panel.hasShadow = expanded
        if expanded {
            // Reassert front ordering when the panel grows from the invisible
            // hover hotzone. This is especially important after a display or
            // Space change, where a status-level panel can otherwise remain
            // ordered behind the menu-bar surface despite receiving its new
            // expanded frame.
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = .notchSpring
            panel.animator().setFrame(expanded ? expandedFrame : idleFrame, display: true)
        } completionHandler: { [weak self] in
            guard !expanded else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isExpanded else { return }
                // Restore each companion from its own state only after the
                // dashboard has completely returned to the idle hotzone.
                self.onPresentationChange?(false)
            }
        }
        // The background scan stays deliberately sparse while the panel is
        // hidden.  Once shown, take an immediate reading and then let
        // UsageStore watch Codex's local SQLite/WAL metadata for fresh turns.
        // It re-aggregates only when that state has changed.
        if expanded {
            Task { await store.refresh() }
            store.startVisibleCodexRefresh()
            // Claude Code's session/weekly rings come from a real network call
            // against Anthropic's undocumented usage endpoint (see
            // ClaudeOAuthUsage) rather than a local file, so it only fires once
            // per visit here — never on the local-file timer above, which
            // would hammer an endpoint that already rate-limits hard.
            store.refreshRemoteQuotaOnVisit()
        } else {
            store.stopVisibleCodexRefresh()
        }

        if expanded {
            // Give the new SwiftUI tree one layout turn, then use its AppKit
            // intrinsic height as a fallback if the geometry callback has not
            // arrived yet. This avoids pinning the panel to its temporary
            // opening frame without imposing a height cap or page scrolling.
            DispatchQueue.main.async { [weak self] in
                self?.hostingView?.layoutSubtreeIfNeeded()
                self?.setContentHeight(self?.hostingView?.fittingSize.height ?? 0)
            }
        }
    }

    /// A short grace period after the pointer leaves — long enough to cross a gap
    /// between the hotzone and the dashboard edge without flicker, short enough to
    /// feel responsive.
    private func scheduleAutoClose() {
        guard !keepsDashboardOpen, !isPopoverOpen else { return }
        closeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isExpanded,
                  !self.keepsDashboardOpen,
                  !self.isPopoverOpen,
                  !self.isPointerInsidePanel
            else { return }
            self.setExpanded(false)
        }
        closeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Tracking areas may emit a transient exit while their window is being
    /// resized. The global cursor position is authoritative at close time; a
    /// one-point tolerance also prevents edge pixels from oscillating between
    /// inside and outside on Retina displays.
    private var isPointerInsidePanel: Bool {
        panel.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
    }

    /// Status-item opening has no reliable corresponding exit event because
    /// the cursor was never in `HoverTrackingView` to begin with. Once the
    /// user has had enough time to move into the dashboard, close only when
    /// the pointer is demonstrably outside its current frame. If it is inside,
    /// the ordinary hover exit path takes over when it later leaves.
    private func scheduleStatusItemAutoClose() {
        guard !keepsDashboardOpen, !isPopoverOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isExpanded,
                  !self.keepsDashboardOpen,
                  !self.isPopoverOpen,
                  !self.isPointerInsidePanel
            else { return }
            self.setExpanded(false)
        }
        statusItemAutoCloseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
}

/// Plain NSView with mouse-enter/exit callbacks driving the hover-to-reveal
/// behavior — this IS the interaction model now, not a fallback for clicks.
private final class HoverTrackingView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // `.inVisibleRect` follows bounds changes automatically. Recreating
        // the area on every animation frame generates synthetic enter/exit
        // pairs and can make the notch repeatedly open and close.
        guard trackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

private struct RootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var controller: NotchWindowController

    var body: some View {
        Group {
            if controller.isExpanded {
                DashboardView(
                    store: store,
                    onHeightChange: { controller.setContentHeight($0) },
                    onPopoverStateChange: { controller.setPopoverOpen($0) }
                )
                    // Measure localized text at the final dashboard width from
                    // the first layout pass. During the native grow animation
                    // the window simply clips this stable layout horizontally.
                    .frame(width: NotchWindowController.expandedWidth)
                    // Fill and top-align the whole hosting panel. In particular,
                    // English copy is often shorter than Chinese; without this
                    // outer frame SwiftUI centers the shorter black surface and
                    // exposes a transparent seam directly below the notch.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(NotchCardBackground())
                    .clipShape(NotchShape.attached())
                    // Crossfades against the AppKit frame resize driven by
                    // `NotchWindowController.setExpanded` (same 0.28s as
                    // `.notchSpring`) — without this the content used to pop
                    // in/out instantly the moment `isExpanded` flipped, while
                    // the panel frame kept animating on its own a beat
                    // behind, which read as a stutter rather than one motion.
                    .transition(.opacity)
                    .contextMenu {
                        Button(L.refreshNow(store.language)) { Task { await store.refresh() } }
                        Divider()
                        Button(L.quitApp(store.language)) { NSApplication.shared.terminate(nil) }
                    }
            } else {
                IdleHotzoneView()
            }
        }
        .animation(.easeInOut(duration: 0.28), value: controller.isExpanded)
    }
}

private struct NotchCardBackground: View {
    var body: some View {
        // Flat, fully opaque black — no blur, no tint, no border. This is
        // what makes the panel read as one continuous black surface with the
        // physical notch above it rather than a separate card that merely
        // sits nearby.
        Color.black
    }
}
