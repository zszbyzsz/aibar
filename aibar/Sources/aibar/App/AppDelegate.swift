import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var activityStatusBarController: ActivityStatusBarController?
    private var statusItem: NSStatusItem?
    private var screenshotCoordinator: ScreenshotCoordinator?
    private var screenshotHotKey: GlobalScreenshotHotKey?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notchController = NotchWindowController()
        activityStatusBarController = ActivityStatusBarController()
        screenshotCoordinator = ScreenshotCoordinator(
            language: { [weak self] in self?.notchController?.currentLanguage ?? .zh },
            setChromeSuppressed: { [weak self] suppressed in
                self?.notchController?.setScreenshotSuppressed(suppressed)
                self?.activityStatusBarController?.setScreenshotSuppressed(suppressed)
            }
        )
        screenshotHotKey = GlobalScreenshotHotKey { [weak self] in
            self?.screenshotCoordinator?.captureRegion()
        }
        setUpStatusItem()
        // Useful for deterministic local UI checks and screenshots without
        // changing the normal hover-to-reveal behavior for everyday launches.
        if CommandLine.arguments.contains("--open") {
            notchController?.showDashboardForPreview()
        }
    }

    /// A menu-bar icon is the only affordance for opening the dashboard (or
    /// quitting) that doesn't depend on the mouse already being at the notch —
    /// left-click toggles the panel directly, right-click gets a small menu for
    /// the same toggle plus Quit.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "aibar")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @MainActor
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            notchController?.toggleExpandedByClick()
        }
    }

    /// Assigning `.menu` and immediately performing a synthetic click is the
    /// standard way to show an on-demand menu from an NSStatusItem without
    /// permanently attaching one — a permanent menu would swallow left-clicks
    /// and break the direct toggle above.
    @MainActor
    private func showStatusMenu() {
        guard let controller = notchController, let item = statusItem else { return }
        let lang = controller.currentLanguage
        let menu = NSMenu()
        let toggleTitle = controller.isExpanded ? L.hidePanel(lang) : L.showPanel(lang)
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let capsuleItem = NSMenuItem(title: L.activityCapsuleMenuTitle(lang), action: #selector(toggleCapsuleFromMenu), keyEquivalent: "")
        capsuleItem.target = self
        capsuleItem.state = (activityStatusBarController?.isEnabled ?? true) ? .on : .off
        menu.addItem(capsuleItem)

        let screenshotItem = NSMenuItem(
            title: L.screenshotMenuTitle(lang),
            action: #selector(captureScreenshot),
            keyEquivalent: ""
        )
        screenshotItem.target = self
        menu.addItem(screenshotItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L.quitApp(lang), action: #selector(quitFromMenu), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @MainActor
    @objc private func toggleFromMenu() {
        notchController?.toggleExpandedByClick()
    }

    @MainActor
    @objc private func toggleCapsuleFromMenu() {
        guard let controller = activityStatusBarController else { return }
        controller.setEnabled(!controller.isEnabled)
    }

    @MainActor
    @objc private func captureScreenshot() {
        screenshotCoordinator?.captureRegion()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
}
