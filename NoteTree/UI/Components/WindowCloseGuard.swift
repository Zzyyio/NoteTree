import SwiftUI

@MainActor
struct WindowCloseGuard: NSViewRepresentable {
    let store: WorkspaceStore
    func makeNSView(context: Context) -> CloseGuardView {
        let view = CloseGuardView()
        view.store = store
        return view
    }
    func updateNSView(_ nsView: CloseGuardView, context: Context) { nsView.store = store }
}

@MainActor
final class CloseGuardView: NSView, NSWindowDelegate {
    var store: WorkspaceStore?
    private weak var originalDelegate: (any NSWindowDelegate)?
    private var isClosing = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.delegate !== self else { return }
        originalDelegate = window.delegate
        window.delegate = self
    }
    func windowWillClose(_ notification: Notification) { originalDelegate?.windowWillClose?(notification) }
    func windowDidResize(_ notification: Notification) { originalDelegate?.windowDidResize?(notification) }
    func windowDidMove(_ notification: Notification) { originalDelegate?.windowDidMove?(notification) }
    func windowDidBecomeKey(_ notification: Notification) { originalDelegate?.windowDidBecomeKey?(notification) }
    func windowDidResignKey(_ notification: Notification) { originalDelegate?.windowDidResignKey?(notification) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosing { return originalDelegate?.windowShouldClose?(sender) ?? true }
        Task {
            guard await store?.prepareForNavigation() ?? true else { return }
            isClosing = true
            sender.performClose(nil)
            isClosing = false
        }
        return false
    }
}
