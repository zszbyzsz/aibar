import AppKit
import SwiftUI

/// Two unobtrusive quota readouts that sit beside a physical notch, or merge
/// into one complete hanging capsule when the display has no camera housing.
/// They are hidden only while the dashboard is presented; activity-capsule
/// state never affects them.
@MainActor
final class QuotaStatusBarController: NSObject {
    private let store: UsageStore
    /// The camera fill and both quota readouts are intentionally hosted in a
    /// single window. Splitting them into a bridge plus two side panels left
    /// visible seams when macOS composited or captured them independently.
    private let quotaPanel: NSPanel
    private var readoutsVisible = true
    private var isDashboardPresented = false
    private var isScreenshotSuppressed = false

    /// Side readouts live inside the menu-bar safe area. One step above the
    /// normal status-window level keeps them from being painted underneath the
    /// system menu-bar surface, while remaining far below alerts and menus.
    private static let readoutLevel = NSWindow.Level(
        rawValue: NSWindow.Level.statusBar.rawValue + 1
    )

    init(store: UsageStore) {
        self.store = store
        quotaPanel = Self.makePanel(ignoresMouseEvents: true)
        super.init()

        quotaPanel.level = Self.readoutLevel
        reposition()
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
        quotaPanel.orderOut(nil)
    }

    /// Keep the complete unified bar visible whenever readouts are enabled.
    /// Missing quota values render as muted em dashes inside the same stable
    /// geometry, so the bar never splits or changes width during refreshes.
    private func updatePanelVisibility() {
        let shouldShow = FloatingSurfaceVisibilityPolicy.showsQuotaReadouts(
            requested: readoutsVisible,
            dashboardPresented: isDashboardPresented,
            screenshotSuppressed: isScreenshotSuppressed
        )
        guard shouldShow else {
            quotaPanel.orderOut(nil)
            return
        }
        show(panel: quotaPanel)
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
        guard let screen = NotchGeometry.targetScreen() else { return }
        let layout = NotchGeometry.quotaBarLayout(on: screen)
        quotaPanel.setFrame(layout.frame, display: true)
        quotaPanel.contentView = NSHostingView(
            rootView: QuotaBarView(
                store: store,
                sideContentWidth: layout.sideContentWidth,
                centerWidth: layout.centerWidth
            )
        )
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

/// One complete black surface: left value, fully filled camera/fallback
/// center, right value. It is rendered in a single native window so a screen
/// capture sees the same continuous shape that is visible around the hardware
/// housing in person.
private struct QuotaBarView: View {
    @ObservedObject var store: UsageStore
    let sideContentWidth: CGFloat
    let centerWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            QuotaValueView(store: store, side: .left)
                .frame(width: sideContentWidth)
            Color.clear.frame(width: centerWidth)
            QuotaValueView(store: store, side: .right)
                .frame(width: sideContentWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hangingShape.fill(Color.black))
        .clipShape(hangingShape)
        .accessibilityElement(children: .contain)
    }

    /// The top remains flush with the screen edge like a hardware notch;
    /// rounding only the lower corners avoids the detached oval/sliver that a
    /// full `Capsule` creates when its top half is clipped by the menu bar.
    private var hangingShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 9,
            bottomTrailingRadius: 9,
            topTrailingRadius: 0
        )
    }
}

private enum QuotaReadoutSide {
    case left
    case right
}

private struct QuotaValueView: View {
    @ObservedObject var store: UsageStore
    let side: QuotaReadoutSide

    private var remainingPercent: Int? {
        let limit = side == .left ? store.payload.weekly : store.payload.session
        guard let used = limit?.usedPercent else { return nil }
        return Int(min(100, max(0, 100 - used)).rounded())
    }

    private var percentText: String {
        remainingPercent.map { "\($0)%" } ?? "—"
    }

    private var readoutColor: Color {
        QuotaStatusPalette.color(
            remaining: remainingPercent,
            normal: .notchAccent,
            unavailable: .notchMutedInk
        )
    }

    var body: some View {
        Text(remainingPercent.map(String.init) ?? "—")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(readoutColor)
            .frame(minWidth: 24)
            .accessibilityLabel(
                side == .left
                    ? "Weekly quota remaining \(percentText)"
                    : "5-hour quota remaining \(percentText)"
            )
    }
}
