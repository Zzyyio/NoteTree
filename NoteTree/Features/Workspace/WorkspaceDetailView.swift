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
            placeholder(title: "detail.pdf.title", image: node.kind.systemImage)
        case .image:
            placeholder(title: "detail.image.title", image: node.kind.systemImage)
        case .unsupported:
            placeholder(title: "detail.unsupported.title", image: node.kind.systemImage)
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
