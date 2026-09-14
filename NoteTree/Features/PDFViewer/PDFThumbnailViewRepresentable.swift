import PDFKit
import SwiftUI

@MainActor
struct PDFThumbnailViewRepresentable: NSViewRepresentable {
    let controller: PDFEditorController

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = NSSize(width: 128, height: 168)
        view.pdfView = controller.pdfView
        view.setAccessibilityLabel(String(localized: "pdf.thumbnails"))
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== controller.pdfView {
            nsView.pdfView = controller.pdfView
        }
    }

    static func dismantleNSView(_ nsView: PDFThumbnailView, coordinator: ()) {
        nsView.pdfView = nil
    }
}
