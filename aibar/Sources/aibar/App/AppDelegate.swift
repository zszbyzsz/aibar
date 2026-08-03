import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var activityStatusBarController: ActivityStatusBarController?
    private var quotaStatusBarController: QuotaStatusBarController?
    /// Retained for the lifetime of the app. `NSStatusBar` does not keep a
    /// menu-bar item visible once its owner releases it.
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

    /// Left-click toggles the dashboard directly. Right-click opens the
    /// application menu without permanently attaching it to the status item,
    /// which would otherwise consume the left-click action.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }

        button.image = BrandIcon.menuBarImage()
        button.imagePosition = .imageOnly
        button.toolTip = "aibar"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    /// Attach the menu only for the duration of this click. Keeping it
    /// detached at rest preserves the direct left-click dashboard toggle.
    @MainActor
    private func showStatusMenu() {
        guard let controller = notchController, let item = statusItem else { return }
        let lang = controller.currentLanguage
        let menu = NSMenu()

        let toggleTitle = controller.isExpanded ? L.hidePanel(lang) : L.showPanel(lang)
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let capsuleItem = NSMenuItem(
            title: L.activityCapsuleMenuTitle(lang),
            action: #selector(toggleCapsuleFromMenu),
            keyEquivalent: ""
        )
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

        let updateItem = NSMenuItem(
            title: L.checkForUpdates(lang),
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

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

    /// A deliberate menu command is consent to download and apply an
    /// available verified update. The helper preserves the current bundle if
    /// the downloaded build fails identity or integrity validation.
    @MainActor
    @objc private func checkForUpdatesFromMenu() {
        guard let updateService else { return }
        let lang = notchController?.currentLanguage ?? .zh
        updateService.checkNow { [weak self] result in
            switch result {
            case .upToDate:
                self?.presentUpdateAlert(
                    title: lang == .zh ? "aibar 已是最新版本" : "aibar Is Up to Date",
                    message: lang == .zh ? "当前没有可用更新。" : "No updates are available.",
                    style: .informational
                )
            case .updateAvailable(let notice):
                do {
                    try SelfUpdateInstaller.install(notice)
                } catch {
                    self?.presentUpdateAlert(
                        title: lang == .zh ? "无法自动更新" : "Couldn’t Update Automatically",
                        message: SelfUpdateInstaller.userMessage(for: error, language: lang),
                        style: .warning
                    )
                }
            case .failed:
                self?.presentUpdateAlert(
                    title: lang == .zh ? "无法检查更新" : "Couldn’t Check for Updates",
                    message: lang == .zh ? "请检查网络连接后重试。" : "Check your internet connection and try again.",
                    style: .warning
                )
            }
        }
    }

    @MainActor
    private func presentUpdateAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: notchController?.currentLanguage == .zh ? "好" : "OK")
        alert.runModal()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
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

}
