import AppKit
import PDFKit

@MainActor
private final class PDFInlineTextDelegate: NSObject, NSTextViewDelegate {
    var commit: ((String) -> Void)?
    var cancel: (() -> Void)?

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), NSEvent.modifierFlags.contains(.command) {
            commit?(textView.string)
            return true
        }
        return false
    }
}

/// An event and overlay bridge over PDFKit. It only handles editing gestures;
/// untouched pointer events still reach PDFView for native scrolling and text selection.
@MainActor
final class PDFEditingView: PDFView {
    weak var editingController: PDFEditorController?

    private let inkPreviewLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private var textView: NSTextView?
    private var textDelegate: PDFInlineTextDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureOverlayLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureOverlayLayers()
    }

    override func layout() {
        super.layout()
        inkPreviewLayer.frame = bounds
        selectionLayer.frame = bounds
        handleLayer.frame = bounds
        editingController?.viewLayoutDidChange()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard editingController?.beginEditing(with: event, at: point) == true else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard editingController?.continueEditing(with: event, at: point) == true else {
            super.mouseDragged(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard editingController?.finishEditing(with: event, at: point) == true else {
            super.mouseUp(with: event)
            return
        }
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" else {
            if event.keyCode == 51, editingController?.handleDelete() == true { return }
            super.keyDown(with: event)
            return
        }
        if event.modifierFlags.contains(.shift) { editingController?.redo() } else { editingController?.undo() }
    }

    func showInkPreview(points: [CGPoint]) {
        let path = CGMutablePath()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            if points.count == 1 { path.addArc(center: first, radius: 1.5, startAngle: 0, endAngle: .pi * 2, clockwise: false) }
        }
        inkPreviewLayer.path = path
    }

    func clearInkPreview() { inkPreviewLayer.path = nil }

    func showSelection(rect: CGRect) {
        let path = CGMutablePath()
        path.addRect(rect)
        selectionLayer.path = path
        let handles = CGMutablePath()
        for point in [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)
        ] {
            handles.addRect(CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        }
        handleLayer.path = handles
    }

    override func clearSelection() {
        super.clearSelection()
        selectionLayer.path = nil
        handleLayer.path = nil
    }

    func clearInteractionOverlays() {
        clearInkPreview()
        clearSelection()
        _ = endTextEditing(commit: false)
    }

    func beginTextEditing(
        frame: CGRect,
        text: String,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _ = endTextEditing(commit: true)
        let delegate = PDFInlineTextDelegate()
        let editor = NSTextView(frame: frame.insetBy(dx: 2, dy: 2))
        editor.string = text
        editor.font = .systemFont(ofSize: 16)
        editor.textColor = .labelColor
        editor.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.94)
        editor.drawsBackground = true
        editor.isRichText = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.autoresizingMask = []
        editor.delegate = delegate
        delegate.commit = { [weak self] value in
            self?.removeTextEditor()
            onCommit(value)
        }
        delegate.cancel = { [weak self] in
            self?.removeTextEditor()
            onCancel()
        }
        textView = editor
        textDelegate = delegate
        addSubview(editor)
        window?.makeFirstResponder(editor)
    }

    /// Returns the text when committing a pending editor and always removes it.
    func endTextEditing(commit: Bool) -> String? {
        guard let textView else { return nil }
        let text = textView.string
        removeTextEditor()
        return commit ? text : nil
    }

    private func configureOverlayLayers() {
        wantsLayer = true
        guard let layer else { return }
        inkPreviewLayer.strokeColor = NSColor.systemBlue.cgColor
        inkPreviewLayer.fillColor = nil
        inkPreviewLayer.lineWidth = 3
        inkPreviewLayer.lineCap = .round
        inkPreviewLayer.lineJoin = .round
        inkPreviewLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        selectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        selectionLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        selectionLayer.lineWidth = 1.5
        handleLayer.strokeColor = NSColor.controlAccentColor.cgColor
        handleLayer.fillColor = NSColor.windowBackgroundColor.cgColor
        handleLayer.lineWidth = 1.5
        layer.addSublayer(inkPreviewLayer)
        layer.addSublayer(selectionLayer)
        layer.addSublayer(handleLayer)
    }

    private func removeTextEditor() {
        textView?.removeFromSuperview()
        textView = nil
        textDelegate = nil
    }
}
