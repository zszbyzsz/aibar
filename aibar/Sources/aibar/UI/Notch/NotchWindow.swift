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
    private let store = UsageStore()
    // @Published (not a plain var) is what actually makes SwiftUI re-render RootView
    // when a hover event flips this — mutating a bare var here was a no-op as far as
    // SwiftUI's view graph was concerned, so the panel resized but kept showing the
    // invisible idle content.
    @Published private(set) var isExpanded = false
    private var idleFrame = CGRect.zero
    private var expandedFrame = CGRect.zero
    // Anchors for `expandedFrameRect(forHeight:)` — kept separately from
    // `expandedFrame` since they only change on `recomputeGeometry()`
    // (screen changes), not on every content-height update.
    private var screenMidX: CGFloat = 0
    private var screenMaxY: CGFloat = 0

    // Width stays fixed — only height follows the dashboard's actual content
    // (see `setContentHeight`, fed by `DashboardView`'s own measurement), so
    // the panel never shows dead space below a shorter layout, or clips a
    // taller one. Model-breakdown and top-projects each cap their own inner
    // list height, so real content is already bounded well under the screen;
    // the screen-height clamp in `expandedFrameRect(forHeight:)` is just a
    // hard backstop against the display itself, not a size anything is
    // expected to reach.
    private static let expandedWidth: CGFloat = 720
    private static let minExpandedHeight: CGFloat = 320
    private static let idleFallbackSize = CGSize(width: 170, height: 34)

    private var closeWorkItem: DispatchWorkItem?
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

    override init() {
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

    private func rootView() -> some View {
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
        expandedFrame = expandedFrameRect(forHeight: height)
        guard isExpanded else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = .notchSpring
            panel.animator().setFrame(expandedFrame, display: true)
        }
    }

    private func expandedFrameRect(forHeight height: CGFloat) -> CGRect {
        let screenLimit = (NSScreen.main?.frame.height ?? height) - 40
        let clamped = min(max(height, Self.minExpandedHeight), screenLimit)
        return CGRect(
            x: screenMidX - Self.expandedWidth / 2, y: screenMaxY - clamped,
            width: Self.expandedWidth, height: clamped
        )
    }

    /// Read by the menu-bar status item, which has no hover concept of its own
    /// and needs to label itself "Show" vs "Hide" for whatever state we're in.
    var currentLanguage: AppLanguage { store.language }

    /// Entry point for the status-bar icon's click-to-toggle — deliberately a
    /// plain toggle rather than routed through the hover enter/exit path, since
    /// there's no mouse-tracking view backing this trigger.
    func toggleExpandedByClick() {
        setExpanded(!isExpanded)
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
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        idleFrame = NotchGeometry.rect(on: screen, fallbackSize: Self.idleFallbackSize)

        screenMidX = frame.midX
        screenMaxY = frame.maxY
        // No content-height measurement has come in yet on the very first
        // call (the dashboard isn't even mounted until the first hover), so
        // this starts at the min height — `setContentHeight` corrects it to
        // the real size moments after the first expand.
        let priorHeight = expandedFrame == .zero ? Self.minExpandedHeight : expandedFrame.height
        expandedFrame = expandedFrameRect(forHeight: priorHeight)
    }

    private func setExpanded(_ expanded: Bool) {
        closeWorkItem?.cancel()
        closeWorkItem = nil
        guard expanded != isExpanded else { return }
        isExpanded = expanded
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
    }

    /// A short grace period after the pointer leaves — long enough to cross a gap
    /// between the hotzone and the dashboard edge without flicker, short enough to
    /// feel responsive.
    private func scheduleAutoClose() {
        guard !keepsDashboardOpen, !isPopoverOpen else { return }
        closeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
        closeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
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
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
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
