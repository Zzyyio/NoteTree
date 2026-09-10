import SwiftUI

@MainActor
struct FileInfoSheet: View {
    let fileTree: FileTreeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: fileTree.inspectedItem?.kind.systemImage ?? "doc.text.magnifyingglass")
                    .font(.title2)
                Text(fileTree.inspectedItem?.displayName ?? String(localized: "fileInfo.loading"))
                    .font(.headline)
                    .lineLimit(1)
            }

            if let info = fileTree.inspectedItem {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    FileInfoRow(label: "fileInfo.type", value: kindName(for: info.kind))
                    FileInfoRow(label: "fileInfo.location", value: info.relativePath.isEmpty ? "." : info.relativePath)
                    FileInfoRow(label: "fileInfo.size", value: byteCountText(info.byteCount))
                    FileInfoRow(label: "fileInfo.modified", value: modificationDateText(info.modificationDate))
                    if let directChildCount = info.directChildCount {
                        FileInfoRow(
                            label: "fileInfo.children",
                            value: String(localized: "fileInfo.children.count \(directChildCount)")
                        )
                    }
                }
            } else if let error = fileTree.inspectionError {
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
            } else {
                ProgressView("fileInfo.loading")
            }

            HStack {
                Spacer()
                Button("fileInfo.done") {
                    fileTree.dismissInspection()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private func kindName(for kind: FileKind) -> String {
        switch kind {
        case .folder:
            String(localized: "fileInfo.type.folder")
        case .markdown:
            String(localized: "fileInfo.type.markdown")
        case .pdf:
            String(localized: "fileInfo.type.pdf")
        case .image:
            String(localized: "fileInfo.type.image")
        case .unsupported:
            String(localized: "fileInfo.type.file")
        }
    }

    private func byteCountText(_ byteCount: Int?) -> String {
        guard let byteCount else {
            return String(localized: "fileInfo.unavailable")
        }
        return byteCount.formatted(.byteCount(style: .file))
    }

    private func modificationDateText(_ modificationDate: Date?) -> String {
        guard let modificationDate else {
            return String(localized: "fileInfo.unavailable")
        }
        return modificationDate.formatted(date: .abbreviated, time: .shortened)
    }
}

@MainActor
private struct FileInfoRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
