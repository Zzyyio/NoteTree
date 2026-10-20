import SwiftUI

@MainActor
struct MarkdownSourceEditor: NSViewRepresentable {
    let session: MarkdownDocumentSession
    let fontSize: Double
    let wraps: Bool
    @Binding var editor: NSTextView?

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("markdown.editor")
        scroll.documentView = textView
        DispatchQueue.main.async { editor = textView }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.session = session
        if textView.string != session.text {
            let selection = textView.selectedRange()
            textView.string = session.text
            textView.setSelectedRange(NSRange(location: min(selection.location, (session.text as NSString).length), length: 0))
        }
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.isEditable = !session.isReadOnly && session.state != .conflict
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        textView.textContainer?.widthTracksTextView = wraps
        scroll.hasHorizontalScroller = !wraps
        let width = wraps ? max(1, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if wraps { textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, textView.frame.height))) }
    }
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var session: MarkdownDocumentSession
        init(session: MarkdownDocumentSession) { self.session = session }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            session.updateText(editor.string)
        }
    }
}
