import AppKit
import SwiftUI

@MainActor
struct WorkspaceSidebar: View {
    let workspaceStore: WorkspaceStore
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List {
            Section {
                Button("command.openWorkspace") {
                    Task {
                        await workspaceStore.chooseWorkspace()
                    }
                }
                .accessibilityIdentifier("workspace.open")
            }

            if let fileTree = workspaceStore.fileTree {
                @Bindable var fileTree = fileTree
                Section {
                    TextField("sidebar.filter", text: $fileTree.filterText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: fileTree.filterText) { _, _ in
                            fileTree.updateFilter()
                        }
                        .accessibilityIdentifier("workspace.filter")
                }

                Section("sidebar.files") {
                    if fileTree.filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if let creationKind = fileTree.creationKind {
                            InlineCreationRow(kind: creationKind, fileTree: fileTree)
                        }
                        FileTreeNodeList(nodes: fileTree.rootChildren, fileTree: fileTree)
                    } else if fileTree.matchingNodes.isEmpty {
                        Text("sidebar.noMatches")
                            .foregroundStyle(.secondary)
                    } else {
                        FileTreeNodeList(nodes: fileTree.matchingNodes, fileTree: fileTree)
                    }
                }

                if let error = fileTree.lastError {
                    Section {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("sidebar.noWorkspace", systemImage: "folder")
                }
            }

            if !workspaceStore.recents.isEmpty {
                Section("sidebar.recents") {
                    ForEach(workspaceStore.recents) { recentWorkspace in
                        Button(recentWorkspace.workspace.displayName) {
                            Task {
                                await workspaceStore.openRecent(recentWorkspace)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(workspaceStore.currentWorkspace?.displayName ?? "sidebar.noWorkspace")
        .toolbar {
            if let fileTree = workspaceStore.fileTree {
                ToolbarItem {
                    Menu {
                        Button("fileAction.newMarkdown") {
                            fileTree.beginCreation(.markdown, in: selectedFolder(in: fileTree))
                        }
                        Button("fileAction.newFolder") {
                            fileTree.beginCreation(.folder, in: selectedFolder(in: fileTree))
                        }
                        Divider()
                        Button("fileAction.revealInFinder") {
                            NSWorkspace.shared.activateFileViewerSelecting([fileTree.workspace.rootURL])
                        }
                    } label: {
                        Label("fileAction.new", systemImage: "plus")
                    }
                    .accessibilityIdentifier("fileActions.menu")
                }
            }
        }
        .onAppear {
            workspaceStore.fileTree?.setUndoManager(undoManager)
        }
        .onChange(of: undoManager) { _, newValue in
            workspaceStore.fileTree?.setUndoManager(newValue)
        }
        .safeAreaInset(edge: .bottom) {
            if let workspace = workspaceStore.currentWorkspace {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(workspace.displayName)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            }
        }
    }

    private func selectedFolder(in fileTree: FileTreeStore) -> FileNode? {
        guard let selectedNode = fileTree.selectedNode(), selectedNode.isFolder else {
            return nil
        }
        return selectedNode
    }
}

@MainActor
private struct InlineCreationRow: View {
    let kind: FileTreeCreationKind
    let fileTree: FileTreeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: kind == .markdown ? "doc.badge.plus" : "folder.badge.plus")
                TextField("fileAction.name", text: Bindable(fileTree).creationName)
                    .onSubmit {
                        Task {
                            await fileTree.commitCreation()
                        }
                    }
                    .onExitCommand {
                        fileTree.cancelCreation()
                    }
            }

            if let error = fileTree.inlineOperationError {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

@MainActor
private struct FileTreeNodeList: View {
    let nodes: [FileNode]
    let fileTree: FileTreeStore

    var body: some View {
        ForEach(nodes) { node in
            FileTreeNodeRow(node: node, fileTree: fileTree)
        }
    }
}

@MainActor
private struct FileTreeNodeRow: View {
    let node: FileNode
    let fileTree: FileTreeStore

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: expansionBinding) {
                if let children = node.children {
                    FileTreeNodeList(nodes: children, fileTree: fileTree)
                } else if fileTree.expandedNodeIDs.contains(node.id) {
                    ProgressView()
                }
            } label: {
                nodeLabel
            }
        } else {
            nodeLabel
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { fileTree.expandedNodeIDs.contains(node.id) },
            set: { isExpanded in
                Task {
                    await fileTree.setExpanded(node.id, isExpanded: isExpanded)
                }
            }
        )
    }

    private var nodeLabel: some View {
        Group {
            if fileTree.renameNodeID == node.id {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("fileAction.name", text: Bindable(fileTree).renameName)
                        .onSubmit {
                            Task {
                                await fileTree.commitRename(for: node)
                            }
                        }
                        .onExitCommand {
                            fileTree.cancelRename()
                        }

                    if let error = fileTree.inlineOperationError {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Button {
                    fileTree.select(node)
                } label: {
                    Label(node.displayName, systemImage: node.kind.systemImage)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if node.isFolder {
                        Button("fileAction.newMarkdown") {
                            fileTree.beginCreation(.markdown, in: node)
                        }
                        Button("fileAction.newFolder") {
                            fileTree.beginCreation(.folder, in: node)
                        }
                        Divider()
                    }

                    Button("fileAction.rename") {
                        fileTree.beginRename(node)
                    }
                    Button("fileAction.move") {
                        chooseMoveDestination()
                    }
                    Button("fileAction.revealInFinder") {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    }
                    Divider()
                    Button("fileAction.moveToTrash", role: .destructive) {
                        Task {
                            await fileTree.trash(node)
                        }
                    }
                }
                .accessibilityIdentifier("fileNode.\(node.id.id)")
            }
        }
    }

    private func chooseMoveDestination() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "fileAction.chooseDestination")
        panel.message = String(localized: "fileAction.chooseDestinationMessage")
        panel.directoryURL = fileTree.workspace.rootURL
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        Task {
            await fileTree.move(node, to: destinationURL)
        }
    }
}
