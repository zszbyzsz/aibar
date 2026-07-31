import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    private let canvas: ScreenshotCanvasView
    private let language: AppLanguage
    private let onClose: () -> Void
    private let statusLabel = NSTextField(labelWithString: "")
    private var toolButtons: [ScreenshotAnnotationTool: NSButton] = [:]
    private var selectionButton: NSButton?
    private var deleteButton: NSButton?
    private var emptyCloseGuard = EmptyEditorCloseGuard()
    private var emptyCloseResetWorkItem: DispatchWorkItem?
    private var bypassCloseConfirmation = false

    init?(image: NSImage, language: AppLanguage, onClose: @escaping () -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        let pixelImage = NSImage(cgImage: cgImage, size: pixelSize)
        self.canvas = ScreenshotCanvasView(
            image: pixelImage,
            textPlaceholder: language == .zh ? "输入注释…" : "Type a note…"
        )
        self.language = language
        self.onClose = onClose

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maximum = NSSize(width: visible.width * 0.86, height: visible.height * 0.86)
        let minimumEditorWidth = min(900, maximum.width)
        let toolbarHeight: CGFloat = 58
        let imageScale = min(maximum.width / pixelSize.width, (maximum.height - toolbarHeight) / pixelSize.height, 1)
        let initialSize = NSSize(
            width: max(minimumEditorWidth, min(maximum.width, pixelSize.width * imageScale)),
            height: max(440, min(maximum.height, pixelSize.height * imageScale + toolbarHeight))
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = language == .zh ? "截图标注" : "Screenshot Markup"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: min(860, maximum.width), height: 420)
        window.collectionBehavior = [.fullScreenAuxiliary]

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
        window.center()
        canvas.onHistoryChange = { [weak self] count in
            self?.setStatus(count == 0 ? "" : (self?.language == .zh ? "已标记 \(count) 处" : "\(count) marked"))
        }
        canvas.onSelectionChange = { [weak self] hasSelection in
            self?.deleteButton?.isEnabled = hasSelection
        }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        emptyCloseResetWorkItem?.cancel()
        onClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if bypassCloseConfirmation {
            bypassCloseConfirmation = false
            return true
        }

        canvas.commitTextEditing()
        guard canvas.annotationCount == 0 else { return true }
        if emptyCloseGuard.shouldClose(annotationCount: canvas.annotationCount) {
            emptyCloseResetWorkItem?.cancel()
            return true
        }

        guard let armedUntil = emptyCloseGuard.armedUntil else { return false }
        setStatus(language == .zh ? "再次点击则立刻退出" : "Click again to exit immediately")
        emptyCloseResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.emptyCloseGuard.armedUntil == armedUntil else { return }
            self.emptyCloseGuard.reset()
            self.setStatus("")
        }
        emptyCloseResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        return false
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        let toolbar = NSVisualEffectView()
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.alignment = .centerY
        tools.spacing = 7
        tools.translatesAutoresizingMaskIntoConstraints = false
        tools.addArrangedSubview(colorWell())
        let selection = selectionToolButton()
        selectionButton = selection
        tools.addArrangedSubview(selection)
        for tool in ScreenshotAnnotationTool.allCases {
            let button = toolButton(for: tool)
            toolButtons[tool] = button
            tools.addArrangedSubview(button)
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 7
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.addArrangedSubview(actionButton(
            symbol: "arrow.uturn.backward", tip: language == .zh ? "撤销（⌘Z）" : "Undo (⌘Z)",
            action: #selector(undo), key: "z"
        ))
        let delete = actionButton(
            symbol: "trash", tip: language == .zh ? "删除选中标注（Delete）" : "Delete Selection (Delete)",
            action: #selector(deleteSelection), key: ""
        )
        delete.isEnabled = false
        deleteButton = delete
        actions.addArrangedSubview(delete)
        actions.addArrangedSubview(actionButton(
            symbol: "doc.on.doc", tip: language == .zh ? "复制（⌘C）" : "Copy (⌘C)",
            action: #selector(copyImage), key: "c"
        ))
        actions.addArrangedSubview(actionButton(
            symbol: "square.and.arrow.down", tip: language == .zh ? "保存（⌘S）" : "Save (⌘S)",
            action: #selector(saveImage), key: "s"
        ))

        let done = NSButton(title: language == .zh ? "完成" : "Done", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.contentTintColor = .controlAccentColor
        actions.addArrangedSubview(done)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)
        root.addSubview(toolbar)
        toolbar.addSubview(tools)
        toolbar.addSubview(actions)
        toolbar.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 58),

            tools.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            tools.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            actions.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tools.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),

            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        selectTool(.rectangle)
        return root
    }

    private func colorWell() -> NSColorWell {
        let well = NSColorWell()
        well.color = .systemRed
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.toolTip = language == .zh ? "颜色（默认红色）" : "Color (red by default)"
        well.setAccessibilityLabel(language == .zh ? "标注颜色" : "Annotation color")
        well.widthAnchor.constraint(equalToConstant: 38).isActive = true
        well.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return well
    }

    private func selectionToolButton() -> NSButton {
        let name = language == .zh ? "选择标注" : "Select Annotation"
        let button = NSButton(
            image: NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: name)!,
            target: self,
            action: #selector(selectionToolSelected)
        )
        button.toolTip = language == .zh ? "选择已有标注，随后可删除" : "Select an existing annotation to delete it"
        button.setAccessibilityLabel(name)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.imageScaling = .scaleProportionallyDown
        button.widthAnchor.constraint(equalToConstant: 38).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func toolButton(for tool: ScreenshotAnnotationTool) -> NSButton {
        let symbol: String
        let name: String
        switch tool {
        case .rectangle:
            symbol = "rectangle"
            name = language == .zh ? "方框" : "Rectangle"
        case .arrow:
            symbol = "arrow.up.right"
            name = language == .zh ? "箭头" : "Arrow"
        case .oval:
            symbol = "circle"
            name = language == .zh ? "圆形" : "Oval"
        case .pen:
            symbol = "pencil.tip"
            name = language == .zh ? "钢笔" : "Pen"
        case .arrowText:
            symbol = "text.bubble"
            name = language == .zh ? "箭头文字" : "Arrow Text"
        }
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name)!, target: self, action: #selector(toolSelected(_:)))
        button.tag = tool.rawValue
        button.toolTip = tool == .arrowText
            ? (language == .zh ? "箭头文字：从文字位置拖向目标" : "Arrow Text: drag from the note toward the target")
            : name
        button.setAccessibilityLabel(name)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.imageScaling = .scaleProportionallyDown
        button.widthAnchor.constraint(equalToConstant: 38).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func actionButton(symbol: String, tip: String, action: Selector, key: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.bezelStyle = .texturedRounded
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = [.command]
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    @objc private func toolSelected(_ sender: NSButton) {
        guard let tool = ScreenshotAnnotationTool(rawValue: sender.tag) else { return }
        selectTool(tool)
    }

    @objc private func selectionToolSelected() {
        canvas.commitTextEditing()
        canvas.isSelectionMode = true
        selectionButton?.state = .on
        selectionButton?.contentTintColor = .controlAccentColor
        for button in toolButtons.values {
            button.state = .off
            button.contentTintColor = .labelColor
        }
        window?.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.color = ScreenshotAnnotationColor(sender.color)
    }

    private func selectTool(_ tool: ScreenshotAnnotationTool) {
        canvas.commitTextEditing()
        canvas.isSelectionMode = false
        canvas.tool = tool
        selectionButton?.state = .off
        selectionButton?.contentTintColor = .labelColor
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
            button.contentTintColor = candidate == tool ? .controlAccentColor : .labelColor
        }
        window?.makeFirstResponder(canvas)
    }

    @objc private func undo() {
        canvas.undo()
        window?.makeFirstResponder(canvas)
    }

    @objc private func deleteSelection() {
        canvas.deleteSelection()
        window?.makeFirstResponder(canvas)
    }

    @objc private func copyImage() {
        canvas.commitTextEditing()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([canvas.renderedImage()])
        setStatus(language == .zh ? "已复制到剪贴板" : "Copied to clipboard")
    }

    @objc private func saveImage() {
        guard let window else { return }
        canvas.commitTextEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "aibar-Screenshot-\(Self.timestamp()).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self,
                  let data = self.canvas.pngData() else { return }
            do {
                try data.write(to: url, options: .atomic)
                self.setStatus(self.language == .zh ? "图片已保存" : "Image saved")
            } catch {
                self.presentSaveError(error)
            }
        }
    }

    @objc private func done() {
        copyImage()
        bypassCloseConfirmation = true
        window?.close()
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func presentSaveError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

@MainActor
private final class ScreenshotCanvasView: NSView, NSTextFieldDelegate {
    let image: NSImage
    let textPlaceholder: String
    var tool: ScreenshotAnnotationTool = .rectangle
    var color: ScreenshotAnnotationColor = .red
    var onHistoryChange: ((Int) -> Void)?
    var onSelectionChange: ((Bool) -> Void)?
    var isSelectionMode = false {
        didSet {
            if !isSelectionMode { setSelectedAnnotation(nil) }
            needsDisplay = true
        }
    }
    private var history = ScreenshotAnnotationHistory()
    private var draft: ScreenshotAnnotation?
    private var pendingArrowText: ScreenshotAnnotation?
    private weak var textEditor: NSTextField?
    private var selectedAnnotationIndex: Int?

    var annotationCount: Int { history.annotations.count }

    init(image: NSImage, textPlaceholder: String) {
        self.image = image
        self.textPlaceholder = textPlaceholder
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot annotation canvas")
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ScreenshotAnnotationRenderer.draw(
            image: image,
            annotations: history.annotations + (draft.map { [$0] } ?? []),
            in: imageRect,
            sourceSize: image.size
        )
        drawSelectionIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        let viewPoint = convert(event.locationInWindow, from: nil)
        if isSelectionMode {
            setSelectedAnnotation(sourcePoint(for: viewPoint).flatMap(annotationIndex(at:)))
            return
        }
        guard let point = sourcePoint(for: viewPoint) else { return }
        draft = ScreenshotAnnotation(
            number: history.nextNumber,
            tool: tool,
            points: [point, point],
            color: color
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isSelectionMode else { return }
        guard var annotation = draft else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = clampedSourcePoint(for: viewPoint)
        if annotation.tool == .pen {
            annotation.points.append(point)
        } else if annotation.points.count == 1 {
            annotation.points.append(point)
        } else {
            annotation.points[annotation.points.count - 1] = point
        }
        draft = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isSelectionMode else { return }
        guard let annotation = draft else { return }
        guard annotation.isMeaningful else {
            draft = nil
            needsDisplay = true
            return
        }
        if annotation.tool == .arrowText {
            beginTextEditing(for: annotation)
            return
        }
        history.append(annotation)
        draft = nil
        onHistoryChange?(history.annotations.count)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection()
        } else if event.keyCode == 53 {
            window?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    func undo() {
        if pendingArrowText != nil {
            cancelTextEditing()
            return
        }
        _ = history.undo()
        setSelectedAnnotation(nil)
        onHistoryChange?(history.annotations.count)
        needsDisplay = true
    }

    func deleteSelection() {
        guard let index = selectedAnnotationIndex else { return }
        _ = history.remove(at: index)
        setSelectedAnnotation(nil)
        onHistoryChange?(history.annotations.count)
        needsDisplay = true
    }

    func renderedImage() -> NSImage {
        let view = ScreenshotExportView(image: image, annotations: history.annotations)
        view.frame = NSRect(origin: .zero, size: image.size)
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return image }
        view.cacheDisplay(in: view.bounds, to: representation)
        let result = NSImage(size: image.size)
        result.addRepresentation(representation)
        return result
    }

    func pngData() -> Data? {
        guard let tiff = renderedImage().tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func commitTextEditing() {
        guard var annotation = pendingArrowText else { return }
        let text = textEditor?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        annotation.text = text
        removeTextEditor()
        draft = nil
        pendingArrowText = nil
        if !text.isEmpty { history.append(annotation) }
        onHistoryChange?(history.annotations.count)
        needsDisplay = true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard var annotation = pendingArrowText,
              let editor = notification.object as? NSTextField else { return }
        annotation.text = editor.stringValue
        pendingArrowText = annotation
        draft = annotation
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if movement == NSCancelTextMovement {
            cancelTextEditing()
        } else {
            commitTextEditing()
        }
    }

    private var imageRect: CGRect {
        let inset = bounds.insetBy(dx: 18, dy: 18)
        let scale = min(inset.width / image.size.width, inset.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func sourcePoint(for point: CGPoint) -> CGPoint? {
        guard imageRect.contains(point) else { return nil }
        return clampedSourcePoint(for: point)
    }

    private func clampedSourcePoint(for point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width * image.size.width, 0), image.size.width),
            y: min(max((point.y - rect.minY) / rect.height * image.size.height, 0), image.size.height)
        )
    }

    private func beginTextEditing(for annotation: ScreenshotAnnotation) {
        pendingArrowText = annotation
        draft = annotation

        let editor = NSTextField(string: "")
        editor.placeholderString = textPlaceholder
        editor.delegate = self
        editor.target = self
        editor.action = #selector(commitTextFromAction)
        editor.font = .systemFont(ofSize: 14, weight: .medium)
        editor.textColor = annotation.color.nsColor
        editor.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94)
        editor.isBezeled = true
        editor.bezelStyle = .roundedBezel

        let tail = viewPoint(forSourcePoint: annotation.points[0])
        let width = min(240, max(140, imageRect.width * 0.32))
        let height: CGFloat = 28
        let x = min(max(tail.x + 12, imageRect.minX), imageRect.maxX - width)
        var y = tail.y - height - 10
        if y < imageRect.minY { y = min(tail.y + 10, imageRect.maxY - height) }
        editor.frame = CGRect(x: x, y: y, width: width, height: height)
        addSubview(editor)
        textEditor = editor
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    @objc private func commitTextFromAction() {
        commitTextEditing()
        window?.makeFirstResponder(self)
    }

    private func cancelTextEditing() {
        removeTextEditor()
        pendingArrowText = nil
        draft = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    private func removeTextEditor() {
        textEditor?.delegate = nil
        textEditor?.removeFromSuperview()
    }

    private func viewPoint(forSourcePoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x / image.size.width * imageRect.width,
            y: imageRect.minY + point.y / image.size.height * imageRect.height
        )
    }

    private func setSelectedAnnotation(_ index: Int?) {
        selectedAnnotationIndex = index
        onSelectionChange?(index != nil)
        needsDisplay = true
    }

    private func annotationIndex(at point: CGPoint) -> Int? {
        let tolerance = max(image.size.width / imageRect.width, image.size.height / imageRect.height) * 9
        return history.annotations.indices.reversed().first { index in
            let annotation = history.annotations[index]
            switch annotation.tool {
            case .rectangle, .oval:
                return annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            case .arrow, .arrowText:
                guard let first = annotation.points.first, let last = annotation.points.last else { return false }
                return Self.distance(from: point, toSegmentFrom: first, to: last) <= tolerance
            case .pen:
                return zip(annotation.points, annotation.points.dropFirst()).contains { first, last in
                    Self.distance(from: point, toSegmentFrom: first, to: last) <= tolerance
                }
            }
        }
    }

    private func drawSelectionIfNeeded() {
        guard isSelectionMode,
              let index = selectedAnnotationIndex,
              history.annotations.indices.contains(index) else { return }
        let annotation = history.annotations[index]
        let bounds = annotation.bounds.applying(CGAffineTransform(
            a: imageRect.width / image.size.width, b: 0, c: 0,
            d: imageRect.height / image.size.height, tx: imageRect.minX, ty: imageRect.minY
        )).insetBy(dx: -7, dy: -7)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        path.lineWidth = 2
        path.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength
        let clamped = min(max(projection, 0), 1)
        let closest = CGPoint(x: start.x + clamped * dx, y: start.y + clamped * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}

private final class ScreenshotExportView: NSView {
    let image: NSImage
    let annotations: [ScreenshotAnnotation]

    init(image: NSImage, annotations: [ScreenshotAnnotation]) {
        self.image = image
        self.annotations = annotations
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ScreenshotAnnotationRenderer.draw(image: image, annotations: annotations, in: bounds, sourceSize: image.size)
    }
}

private enum ScreenshotAnnotationRenderer {
    static func draw(image: NSImage, annotations: [ScreenshotAnnotation], in imageRect: CGRect, sourceSize: CGSize) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        for annotation in annotations {
            draw(annotation, in: imageRect, sourceSize: sourceSize)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func draw(_ annotation: ScreenshotAnnotation, in rect: CGRect, sourceSize: CGSize) {
        guard let first = annotation.points.first, let last = annotation.points.last else { return }
        let map: (CGPoint) -> CGPoint = { point in
            CGPoint(
                x: rect.minX + point.x / sourceSize.width * rect.width,
                y: rect.minY + point.y / sourceSize.height * rect.height
            )
        }
        let lineWidth = max(2.5, min(5, rect.width / sourceSize.width * 5))
        let color = annotation.color.nsColor
        color.setStroke()

        switch annotation.tool {
        case .rectangle:
            let path = NSBezierPath(rect: CGRect(from: map(first), to: map(last)))
            path.lineWidth = lineWidth
            path.stroke()
        case .oval:
            let path = NSBezierPath(ovalIn: CGRect(from: map(first), to: map(last)))
            path.lineWidth = lineWidth
            path.stroke()
        case .arrow:
            drawArrow(from: map(first), to: map(last), lineWidth: lineWidth)
        case .pen:
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = lineWidth
            path.move(to: map(first))
            for point in annotation.points.dropFirst() { path.line(to: map(point)) }
            path.stroke()
        case .arrowText:
            drawArrow(from: map(first), to: map(last), lineWidth: lineWidth)
            if let text = annotation.text, !text.isEmpty {
                drawText(text, at: map(first), color: color, clippedTo: rect, scale: rect.width / sourceSize.width)
            }
        }

        let mappedBounds = annotation.bounds.applying(CGAffineTransform(
            a: rect.width / sourceSize.width, b: 0, c: 0,
            d: rect.height / sourceSize.height, tx: rect.minX, ty: rect.minY
        ))
        drawNumber(
            annotation.number,
            at: CGPoint(x: mappedBounds.minX, y: mappedBounds.minY),
            color: color,
            clippedTo: rect
        )
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = lineWidth
        path.move(to: start)
        path.line(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12, lineWidth * 4)
        path.move(to: end)
        path.line(to: CGPoint(x: end.x - headLength * cos(angle - .pi / 6), y: end.y - headLength * sin(angle - .pi / 6)))
        path.move(to: end)
        path.line(to: CGPoint(x: end.x - headLength * cos(angle + .pi / 6), y: end.y - headLength * sin(angle + .pi / 6)))
        path.stroke()
    }

    private static func drawText(_ value: String, at tail: CGPoint, color: NSColor, clippedTo rect: CGRect, scale: CGFloat) {
        let font = NSFont.systemFont(ofSize: max(13, min(20, 18 * scale)), weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let text = value as NSString
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 5)
        let size = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        var origin = CGPoint(x: tail.x + 12, y: tail.y - size.height - 10)
        if origin.y < rect.minY { origin.y = tail.y + 10 }
        origin.x = min(max(origin.x, rect.minX), max(rect.minX, rect.maxX - size.width))
        origin.y = min(max(origin.y, rect.minY), max(rect.minY, rect.maxY - size.height))
        let background = CGRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        text.draw(
            at: CGPoint(x: background.minX + padding.width, y: background.minY + padding.height),
            withAttributes: attributes
        )
    }

    private static func drawNumber(_ number: Int, at topLeft: CGPoint, color: NSColor, clippedTo rect: CGRect) {
        let diameter: CGFloat = 22
        let center = CGPoint(
            x: min(max(topLeft.x, rect.minX + diameter / 2), rect.maxX - diameter / 2),
            y: min(max(topLeft.y, rect.minY + diameter / 2), rect.maxY - diameter / 2)
        )
        let badge = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        color.setFill()
        NSBezierPath(ovalIn: badge).fill()

        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: number >= 10 ? 11 : 12, weight: .bold),
            .foregroundColor: color.contrastingLabelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
    }
}

private extension ScreenshotAnnotationColor {
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .systemRed
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension NSColor {
    var contrastingLabelColor: NSColor {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.62 ? .black : .white
    }
}

private extension CGRect {
    init(from first: CGPoint, to last: CGPoint) {
        self.init(
            x: min(first.x, last.x), y: min(first.y, last.y),
            width: abs(last.x - first.x), height: abs(last.y - first.y)
        )
    }
}
