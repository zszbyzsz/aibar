import AppKit
import SwiftUI
import Combine

/// Two unobtrusive quota readouts that sit beside the physical notch. They are
/// deliberately separate windows so the center remains available to the
/// dashboard's existing hover hotzone.
@MainActor
final class QuotaStatusBarController: NSObject {
    private let store: UsageStore
    private let presentActivity: () -> Bool
    private let dismissActivity: () -> Void
    private let leftPanel: NSPanel
    private let rightPanel: NSPanel
    private var quotaSubscription: AnyCancellable?
    private var readoutsVisible = true
    /// While activity is presented from a side readout, its panel remains on
    /// screen but transparent. That preserves the side's tracking area so a
    /// stationary cursor cannot repeatedly re-enter when the readout is
    /// restored.
    private var isPresentingActivity = false
    private var hoveringSides: Set<QuotaSideReadoutView.Side> = []
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

    init(
        store: UsageStore,
        presentActivity: @escaping () -> Bool,
        dismissActivity: @escaping () -> Void
    ) {
        self.store = store
        self.presentActivity = presentActivity
        self.dismissActivity = dismissActivity
        leftPanel = Self.makePanel()
        rightPanel = Self.makePanel()
        super.init()

        leftPanel.contentView = NSHostingView(
            rootView: QuotaSideReadoutView(store: store, side: .left) { [weak self] side, hovering in
                self?.setSideHovering(side, hovering: hovering)
            }
        )
        rightPanel.contentView = NSHostingView(
            rootView: QuotaSideReadoutView(store: store, side: .right) { [weak self] side, hovering in
                self?.setSideHovering(side, hovering: hovering)
            }
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

    /// Restores the collapsed state after the activity stack is no longer
    /// expanded. Screenshot suppression always wins over this request.
    func showReadouts() {
        guard !isScreenshotSuppressed else { return }
        isPresentingActivity = false
        readoutsVisible = true
        leftPanel.alphaValue = 1
        rightPanel.alphaValue = 1
        reposition()
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

    private func setSideHovering(_ side: QuotaSideReadoutView.Side, hovering: Bool) {
        guard !isScreenshotSuppressed else { return }
        if hovering {
            hoveringSides.insert(side)
            guard presentActivity() else { return }
            isPresentingActivity = true
            hideReadouts(keepingTracking: true)
        } else {
            hoveringSides.remove(side)
            guard isPresentingActivity, hoveringSides.isEmpty else { return }
            dismissActivity()
        }
    }

    private func hideReadouts(keepingTracking: Bool = false) {
        readoutsVisible = false
        if keepingTracking {
            // `orderOut` destroys the hover target. Keeping a fully
            // transparent panel ordered makes the side readout and activity
            // stack mutually exclusive without causing hover churn.
            leftPanel.alphaValue = 0
            rightPanel.alphaValue = 0
            leftPanel.orderFrontRegardless()
            rightPanel.orderFrontRegardless()
        } else {
            leftPanel.orderOut(nil)
            rightPanel.orderOut(nil)
        }
    }

    /// A quota that Codex did not provide should take up no space at all. In
    /// particular, newer Pro snapshots may contain only the weekly window and
    /// omit the five-hour one altogether.
    private func updatePanelVisibility() {
        if isPresentingActivity, !isScreenshotSuppressed {
            hideReadouts(keepingTracking: true)
            return
        }
        guard readoutsVisible, !isScreenshotSuppressed else {
            leftPanel.orderOut(nil)
            rightPanel.orderOut(nil)
            return
        }
        update(panel: leftPanel, hasQuota: store.payload.weekly?.usedPercent != nil)
        update(panel: rightPanel, hasQuota: store.payload.session?.usedPercent != nil)
    }

    private func update(panel: NSPanel, hasQuota: Bool) {
        if hasQuota {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    @objc private func screenParametersChanged() {
        reposition()
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
    }

    private static func makePanel() -> NSPanel {
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
    let onHover: (Side, Bool) -> Void

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
        remainingPercent.map { "\($0)%" } ?? ""
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
            if let remainingPercent {
                tabShape.fill(Color.black)
                Text("\(remainingPercent)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(readoutColor)
                    .offset(x: textOffset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(tabShape)
        .contentShape(Rectangle())
        .onHover { hovering in
            onHover(side, hovering)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
