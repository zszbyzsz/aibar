import AppKit

@MainActor
final class ScreenshotCoordinator {
    private let language: () -> AppLanguage
    private let setChromeSuppressed: (Bool) -> Void
    private var captureProcess: Process?
    private var editor: ScreenshotEditorWindowController?

    init(
        language: @escaping () -> AppLanguage,
        setChromeSuppressed: @escaping (Bool) -> Void
    ) {
        self.language = language
        self.setChromeSuppressed = setChromeSuppressed
    }

    func captureRegion() {
        guard captureProcess == nil, editor == nil else {
            editor?.present()
            return
        }

        // TCC consent is associated with the app's bundle/signing identity,
        // not copied by an updater. A correctly signed update keeps it; if a
        // person previously denied Screen Recording, ask macOS again at the
        // moment the feature is actually requested instead of failing later
        // with an empty capture.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            presentScreenRecordingPermissionError()
            return
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-\(UUID().uuidString)")
            .appendingPathExtension("png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // Interactive selection starts with (and stays in) the familiar
        // crosshair/drag rectangle requested for this shortcut. -x avoids a
        // capture sound before the editor appears.
        process.arguments = ["-i", "-s", "-x", "-t", "png", destination.path]
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.finishCapture(process: process, destination: destination)
            }
        }

        setChromeSuppressed(true)
        captureProcess = process
        do {
            try process.run()
        } catch {
            captureProcess = nil
            setChromeSuppressed(false)
            presentCaptureError(error)
        }
    }

    private func finishCapture(process: Process, destination: URL) {
        guard process === captureProcess else { return }
        captureProcess = nil
        setChromeSuppressed(false)
        defer { try? FileManager.default.removeItem(at: destination) }

        // Escape/cancel leaves no file; it is a normal outcome and should not
        // interrupt the user with an error dialog.
        guard process.terminationStatus == 0,
              let image = NSImage(contentsOf: destination),
              image.size.width > 0,
              image.size.height > 0 else { return }

        editor = ScreenshotEditorWindowController(
            image: image,
            language: language(),
            onClose: { [weak self] in self?.editor = nil }
        )
        editor?.present()
    }

    private func presentCaptureError(_ error: Error) {
        let lang = language()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = lang == .zh ? "无法开始截图" : "Couldn’t Start Screenshot"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: lang == .zh ? "好" : "OK")
        alert.runModal()
    }

    private func presentScreenRecordingPermissionError() {
        let lang = language()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = lang == .zh ? "需要屏幕录制权限" : "Screen Recording Permission Required"
        alert.informativeText = lang == .zh
            ? "请在系统设置中允许 aibar 进行屏幕录制，然后再试一次。"
            : "Allow aibar in System Settings > Privacy & Security > Screen Recording, then try again."
        alert.addButton(withTitle: lang == .zh ? "好" : "OK")
        alert.runModal()
    }
}
