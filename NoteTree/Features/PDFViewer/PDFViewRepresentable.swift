import PDFKit
import SwiftUI

@MainActor
struct PDFViewRepresentable: NSViewRepresentable {
    let controller: PDFEditorController

    func makeNSView(context: Context) -> PDFView {
        controller.pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // The controller owns one viewer for the document's lifetime. SwiftUI updates
        // must not reset the document, selection, scroll position, or page cache.
    }
}
