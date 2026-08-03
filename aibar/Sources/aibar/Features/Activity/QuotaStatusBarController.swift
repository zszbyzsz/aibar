import AppKit
import SwiftUI
import Combine

/// Two unobtrusive quota readouts that sit beside the physical notch. They are
/// deliberately separate windows so the center remains available to the
/// dashboard's existing hover hotzone. They are hidden only while that
/// dashboard is presented; activity-capsule state never affects them.
@MainActor
final class QuotaStatusBarController: NSObject {
    private let store: UsageStore
    /// Pure background fill for software screenshots of the camera gap.
    /// It is ordered before every interactive surface and ignores the mouse.
    private let cameraBridgePanel: NSPanel
    private let leftPanel: NSPanel
    private let rightPanel: NSPanel
    private var quotaSubscription: AnyCancellable?
    private var readoutsVisible = true
    private var isDashboardPresented = false
    private var isScreenshotSuppressed = false

    /// Just enough room for a two-digit readout. Keeping these wings narrow
    /// lets the hardware notch remain the visual anchor instead of turning
    /// the whole menu bar into a second, wider notch.
    private static let readoutWidth: CGFloat = 38
    /// The display's rounded camera-housing corners can otherwise reveal a
    /// sliver of wallpaper at the join. A deliberate overlap hides that
    /// seam without making the readouts feel detached from the notch.
    private static let notchInset: CGFloat = 10
    private static let fallbackSize = CGSize(width: 170, height: 34)
    /// Side readouts live inside the menu-bar safe area. One step above the
    /// normal status-window level keeps them from being painted underneath the
    /// system menu-bar surface, while remaining far below alerts and menus.
    private static let readoutLevel = NSWindow.Level(
        rawValue: NSWindow.Level.statusBar.rawValue + 1
    )

    init(store: UsageStore) {
        self.store = store
        cameraBridgePanel = Self.makePanel(ignoresMouseEvents: true)
        leftPanel = Self.makePanel()
        rightPanel = Self.makePanel()
        super.init()

        cameraBridgePanel.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue - 1
        )
        leftPanel.level = Self.readoutLevel
        rightPanel.level = Self.readoutLevel
        let bridgeView = NSView()
        bridgeView.wantsLayer = true
        bridgeView.layer?.backgroundColor = NSColor.black.cgColor
        cameraBridgePanel.contentView = bridgeView
        leftPanel.contentView = NSHostingView(
            rootView: QuotaSideReadoutView(store: store, side: .left)
        )
        rightPanel.contentView = NSHostingView(
            rootView: QuotaSideReadoutView(store: store, side: .right)
        )
        reposition()
        quotaSubscription = store.$payload.sink { [weak self] _ in
            self?.updatePanelVisibility()
        }
        updatePanelVisibility()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Restores the readouts according to their own state. Dashboard and
    /// screenshot suppression still win over this request.
    func showReadouts() {
        readoutsVisible = true
        reposition()
        updatePanelVisibility()
    }

    func setDashboardPresented(_ presented: Bool) {
        guard presented != isDashboardPresented else { return }
        isDashboardPresented = presented
        updatePanelVisibility()
    }

    func setScreenshotSuppressed(_ suppressed: Bool) {
        guard suppressed != isScreenshotSuppressed else { return }
        isScreenshotSuppressed = suppressed
        if suppressed {
            hideReadouts()
        } else {
            showReadouts()
        }
    }

    private func hideReadouts() {
        readoutsVisible = false
        cameraBridgePanel.orderOut(nil)
        leftPanel.orderOut(nil)
        rightPanel.orderOut(nil)
    }

    /// Keep both notch wings visible whenever the readouts are enabled. Codex
    /// sometimes returns only one of the two windows; replacing the absent
    /// value with a muted em dash is clearer than making the entire side look
    /// broken or causing the wings to jump around between refreshes.
    private func updatePanelVisibility() {
        let shouldShow = FloatingSurfaceVisibilityPolicy.showsQuotaReadouts(
            requested: readoutsVisible,
            dashboardPresented: isDashboardPresented,
            screenshotSuppressed: isScreenshotSuppressed
        )
        guard shouldShow else {
            cameraBridgePanel.orderOut(nil)
            leftPanel.orderOut(nil)
            rightPanel.orderOut(nil)
            return
        }
        showCameraBridgeIfAvailable()
        show(panel: leftPanel)
        show(panel: rightPanel)
    }

    private func show(panel: NSPanel) {
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersChanged() {
        reposition()
        updatePanelVisibility()
    }

    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frames = NotchGeometry.sideFrames(
            on: screen,
            width: Self.readoutWidth,
            inset: Self.notchInset,
            fallbackSize: Self.fallbackSize
        )
        leftPanel.setFrame(frames.left, display: true)
        rightPanel.setFrame(frames.right, display: true)
        if let bridgeFrame = NotchGeometry.cameraBridgeFrame(on: screen, fallbackSize: Self.fallbackSize) {
            cameraBridgePanel.setFrame(bridgeFrame, display: true)
        } else {
            cameraBridgePanel.orderOut(nil)
        }
    }

    private func showCameraBridgeIfAvailable() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let bridgeFrame = NotchGeometry.cameraBridgeFrame(on: screen, fallbackSize: Self.fallbackSize)
        else {
            cameraBridgePanel.orderOut(nil)
            return
        }

        cameraBridgePanel.setFrame(bridgeFrame, display: true)
        cameraBridgePanel.alphaValue = 1
        // Ordered first: quota wings are ordered immediately afterward, and
        // the independently managed activity capsule remains above both.
        cameraBridgePanel.orderFrontRegardless()
    }

    private static func makePanel(ignoresMouseEvents: Bool = false) -> NSPanel {
        let panel = NSPanel(
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
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }
}

private struct QuotaSideReadoutView: View {
    enum Side: Hashable {
        case left
        case right
    }

    @ObservedObject var store: UsageStore
    let side: Side

    private var remainingPercent: Int? {
        let limit: LimitView?
        switch side {
        case .left: limit = store.payload.weekly
        case .right: limit = store.payload.session
        }
        guard let used = limit?.usedPercent else { return nil }
        return Int(min(100, max(0, 100 - used)).rounded())
    }

    private var percentText: String {
        remainingPercent.map { "\($0)%" } ?? "—"
    }

    /// Uses the same five-stage scale as the dashboard, so a color always
    /// means the same remaining-quota range wherever it appears.
    private var readoutColor: Color {
        QuotaStatusPalette.color(
            remaining: remainingPercent,
            normal: .notchAccent,
            unavailable: .notchMutedInk
        )
    }

    /// The inside edge is deliberately square so the tab visually grows out
    /// of the notch; only its free, lower outside corner is softened.
    private var tabShape: UnevenRoundedRectangle {
        switch side {
        case .left:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 7,
                bottomTrailingRadius: 0, topTrailingRadius: 0
            )
        case .right:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 7, topTrailingRadius: 0
            )
        }
    }

    private var accessibilityLabel: String {
        switch side {
        case .left: return "Weekly quota remaining \(percentText)"
        case .right: return "5-hour quota remaining \(percentText)"
        }
    }

    /// The panel intentionally extends under the camera housing to cover its
    /// rounded edge. Nudge the glyph back by half that hidden overlap so it
    /// remains centered in the portion that is actually visible.
    private var textOffset: CGFloat {
        switch side {
        case .left: return -5
        case .right: return 5
        }
    }

    var body: some View {
        ZStack {
            tabShape.fill(Color.black)
            Text(remainingPercent.map(String.init) ?? "—")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(readoutColor)
                .offset(x: textOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(tabShape)
        .accessibilityLabel(accessibilityLabel)
    }
}
