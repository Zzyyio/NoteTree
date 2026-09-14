import PDFKit
import SwiftUI

@MainActor
struct PDFOutlineView: View {
    let controller: PDFEditorController

    var body: some View {
        Group {
            if let root = controller.outlineRoot, root.numberOfChildren > 0 {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<root.numberOfChildren, id: \.self) { index in
                            if let child = root.child(at: index) {
                                PDFOutlineRow(outline: child, controller: controller)
                            }
                        }
                    }
                    .padding(10)
                }
            } else {
                ContentUnavailableView {
                    Label("pdf.outline.empty.title", systemImage: "list.bullet.indent")
                } description: {
                    Text("pdf.outline.empty.description")
                }
            }
        }
        .accessibilityIdentifier("pdf.outline")
    }
}

@MainActor
private struct PDFOutlineRow: View {
    let outline: PDFOutline
    let controller: PDFEditorController
    @State private var isExpanded = false

    var body: some View {
        if outline.numberOfChildren > 0 {
            DisclosureGroup(isExpanded: $isExpanded) {
                // Child views are created only when expanded; a large outline is
                // not recursively materialized while the first PDF page loads.
                if isExpanded {
                    ForEach(0..<outline.numberOfChildren, id: \.self) { index in
                        if let child = outline.child(at: index) {
                            PDFOutlineRow(outline: child, controller: controller)
                        }
                    }
                }
            } label: {
                destinationButton
            }
        } else {
            destinationButton
                .padding(.leading, 16)
        }
    }

    private var destinationButton: some View {
        Button {
            controller.goToOutline(outline)
        } label: {
            Text(outline.label ?? String(localized: "pdf.outline.untitled"))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
