import SwiftUI

@MainActor
struct WorkspaceDetailView: View {
    let workspaceStore: WorkspaceStore

    var body: some View {
        switch workspaceStore.state {
        case .welcome:
            WelcomeView {
                Task {
                    await workspaceStore.chooseWorkspace()
                }
            }
        case .loading:
            ProgressView("workspace.loading")
        case .needsReauthorization(let recentWorkspace):
            ContentUnavailableView {
                Label("workspace.reauthorize.title", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text("workspace.reauthorize.description")
            } actions: {
                Button("workspace.reauthorize.action") {
                    Task {
                        await workspaceStore.reauthorize(recentWorkspace)
                    }
                }
            }
        case .failure(let error):
            ContentUnavailableView {
                Label("workspace.error.title", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("command.openWorkspace") {
                    Task {
                        await workspaceStore.chooseWorkspace()
                    }
                }
            }
        case .ready:
            if let node = workspaceStore.fileTree?.selectedNode() {
                FileRouteView(node: node, workspaceStore: workspaceStore)
            } else {
                ContentUnavailableView {
                    Label("workspace.selectFile.title", systemImage: "sidebar.left")
                } description: {
                    Text("workspace.selectFile.description")
                }
            }
        }
    }
}

@MainActor
private struct FileRouteView: View {
    let node: FileNode
    let workspaceStore: WorkspaceStore

    var body: some View {
        switch EditorRouter.route(for: node.kind) {
        case .folder:
            ContentUnavailableView {
                Label("detail.folder.title", systemImage: node.kind.systemImage)
            } description: {
                VStack(spacing: 8) {
                    Text(node.relativePath)
                    Text("detail.folder.count \(node.children?.count ?? 0)")
                }
            }
        case .markdown:
            MarkdownEditorHost(node: node, workspaceStore: workspaceStore)
        case .pdf:
            PDFReaderHost(node: node, workspaceStore: workspaceStore)
        case .image:
            ImageEditorHost(node: node, workspaceStore: workspaceStore)
        case .unsupported:
            VStack(spacing: 12) {
                Label(node.displayName, systemImage: node.kind.systemImage).font(.title2)
                Text(node.relativePath).textSelection(.enabled)
                if let size = node.metadata.byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                if let date = node.metadata.modificationDate { Text(date, format: .dateTime) }
                Button("detail.openDefault") { NSWorkspace.shared.open(node.url) }
                Button("fileAction.revealInFinder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            }.padding()
        }
    }

    private func placeholder(title: LocalizedStringKey, image: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: image)
        } description: {
            Text("detail.readOnly.description")
        }
    }
}

@MainActor
private struct PDFReaderHost: View {
    let node: FileNode
    let workspaceStore: WorkspaceStore

    var body: some View {
        Group {
            if let controller = workspaceStore.pdfController, controller.url == node.url {
                PDFReaderView(controller: controller)
            } else {
                ProgressView("pdf.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: node.id) {
            await workspaceStore.openPDF(node)
        }
    }
}
