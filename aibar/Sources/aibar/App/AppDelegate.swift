import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var activityStatusBarController: ActivityStatusBarController?
    private var quotaStatusBarController: QuotaStatusBarController?
    private var statusItem: NSStatusItem?
    private var screenshotCoordinator: ScreenshotCoordinator?
    private var screenshotHotKey: GlobalScreenshotHotKey?
    private var updateService: AppUpdateService?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureApplicationIcon()
        notchController = NotchWindowController(store: UsageStore())
        activityStatusBarController = ActivityStatusBarController()
        if let usageStore = notchController?.usageStore {
            quotaStatusBarController = QuotaStatusBarController(
                store: usageStore,
                presentActivity: { [weak self] in
                    self?.activityStatusBarController?.presentFromQuotaReadout() ?? false
                },
                dismissActivity: { [weak self] in
                    self?.activityStatusBarController?.dismissQuotaReadoutPresentation()
                }
            )
            activityStatusBarController?.onQuotaPresentationCollapsed = { [weak self] in
                self?.quotaStatusBarController?.showReadouts()
            }
        }
        screenshotCoordinator = ScreenshotCoordinator(
            language: { [weak self] in self?.notchController?.currentLanguage ?? .zh },
            setChromeSuppressed: { [weak self] suppressed in
                self?.notchController?.setScreenshotSuppressed(suppressed)
                self?.activityStatusBarController?.setScreenshotSuppressed(suppressed)
                self?.quotaStatusBarController?.setScreenshotSuppressed(suppressed)
            }
        )
        screenshotHotKey = GlobalScreenshotHotKey { [weak self] in
            self?.screenshotCoordinator?.captureRegion()
        }
        setUpStatusItem()
        setUpUpdateChecks()
        // Useful for deterministic local UI checks and screenshots without
        // changing the normal hover-to-reveal behavior for everyday launches.
        if CommandLine.arguments.contains("--open") {
            notchController?.showDashboardForPreview()
        }
    }

    @MainActor
    private func setUpUpdateChecks() {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let activityStatusBarController
        else { return }

        let service = AppUpdateService(currentVersion: version) { [weak activityStatusBarController] notice in
            activityStatusBarController?.setUpdateNotice(notice)
        }
        updateService = service
        service.start()
    }

    /// A menu-bar icon is the only affordance for opening the dashboard (or
    /// quitting) that doesn't depend on the mouse already being at the notch —
    /// left-click toggles the panel directly, right-click gets a small menu for
    /// the same toggle plus Quit.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = BrandIcon.menuBarImage()
            button.imagePosition = .imageOnly
            button.toolTip = "aibar"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Keep the runtime application identity in sync with the Finder icon.
    /// This is also used by system-owned UI such as app switchers and alerts
    /// if the accessory application is surfaced there.
    private func configureApplicationIcon() {
        guard
            let iconURL = Bundle.main.url(forResource: "aibar", withExtension: "icns"),
            let image = NSImage(contentsOf: iconURL)
        else { return }

        NSApp.applicationIconImage = image
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
