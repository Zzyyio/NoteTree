import AppKit
import SwiftUI

@MainActor
struct WorkspaceSidebar: View {
    let workspaceStore: WorkspaceStore
    @Environment(\.undoManager) private var undoManager
    @FocusState private var filterFocused: Bool

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
                        .focused($filterFocused)
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
                        WorkspaceRootDropTarget(fileTree: fileTree)
                        FileTreeNodeList(nodes: fileTree.rootChildren, fileTree: fileTree)
                    } else if fileTree.matchingNodes.isEmpty {
                        Text("sidebar.noMatches")
                            .foregroundStyle(.secondary)
                    } else {
                        FileTreeNodeList(nodes: fileTree.matchingNodes, fileTree: fileTree)
                    }
                }
                .transaction { transaction in
                    // File mutations replace a fully rebuilt snapshot; List must not animate
                    // that replacement as a collapse followed by an insertion.
                    transaction.animation = nil
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
        }
        .navigationTitle(workspaceStore.currentWorkspace?.displayName ?? "sidebar.noWorkspace")
        .onChange(of: workspaceStore.filterFocusRequest) { _, _ in filterFocused = true }
        .sheet(isPresented: inspectionBinding) {
            if let fileTree = workspaceStore.fileTree {
                FileInfoSheet(fileTree: fileTree)
            }
        }
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
                        Button("fileAction.showInfo") {
                            Task {
                                await fileTree.inspect()
                            }
                        }
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

    private var inspectionBinding: Binding<Bool> {
        Binding(
            get: { workspaceStore.fileTree?.isShowingInspection == true },
            set: { isPresented in
                if !isPresented {
                    workspaceStore.fileTree?.dismissInspection()
                }
            }
        )
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
private struct WorkspaceRootDropTarget: View {
    let fileTree: FileTreeStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text("sidebar.workspaceRoot")
        }
        .font(.caption)
        .foregroundStyle(fileTree.isRootDropTarget ? .white : .secondary)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(fileTree.isRootDropTarget ? Color.black.opacity(0.82) : .clear)
        )
        .contentShape(Rectangle())
        .onDrop(
            of: [FileTreeDragDrop.contentType],
            delegate: FileTreeDropDelegate(fileTree: fileTree, destination: nil)
        )
        .accessibilityIdentifier("workspace.rootDropTarget")
    }
}

@MainActor
private struct FileTreeNodeRow: View {
    let node: FileNode
    let fileTree: FileTreeStore
    @FocusState private var isRenameFocused: Bool

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
            .onDrop(
                of: [FileTreeDragDrop.contentType],
                delegate: FileTreeDropDelegate(fileTree: fileTree, destination: node)
            )
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
                    HStack(spacing: 6) {
                        Image(systemName: node.kind.systemImage)
                            .foregroundStyle(.white)
                        TextField("fileAction.name", text: Bindable(fileTree).renameName)
                            .textFieldStyle(.plain)
                            .focused($isRenameFocused)
                            .tint(.white)
                            .foregroundStyle(.white)
                            .onSubmit {
                                Task {
                                    await fileTree.commitRename(for: node)
                                }
                            }
                            .onExitCommand {
                                fileTree.cancelRename()
                            }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.86)))
                    .onAppear {
                        isRenameFocused = true
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
                        .foregroundStyle(labelForegroundStyle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(labelBackgroundColor))
                }
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .onKeyPress(.return) {
                    fileTree.beginRename(node)
                    return .handled
                }
                .onKeyPress(keys: [.delete], phases: .down) { key in
                    guard key.modifiers.contains(.command) else { return .ignored }
                    Task { await fileTree.trash(node) }
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard node.isFolder else { return .ignored }
                    Task { await fileTree.setExpanded(node.id, isExpanded: true) }
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    guard node.isFolder else { return .ignored }
                    Task { await fileTree.setExpanded(node.id, isExpanded: false) }
                    return .handled
                }
                .onHover { isHovering in
                    fileTree.setHovered(node, isHovering: isHovering)
                }
                .onDrag {
                    FileTreeDragDrop.provider(for: node, fileTree: fileTree)
                }
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
                    Button("fileAction.copy") {
                        Task {
                            await fileTree.copy(node)
                        }
                    }
                    Button("fileAction.showInfo") {
                        Task {
                            await fileTree.inspect(node)
                        }
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

    private var isDropTarget: Bool {
        fileTree.dropTargetNodeID == node.id
    }

    private var isSelected: Bool {
        fileTree.selectedNodeID == node.id
    }

    private var isHovered: Bool {
        fileTree.hoveredNodeID == node.id
    }

    private var labelBackgroundColor: Color {
        if isDropTarget {
            return .black.opacity(0.9)
        }
        if isSelected {
            return .black.opacity(0.78)
        }
        if isHovered {
            return .black.opacity(0.62)
        }
        return .clear
    }

    private var labelForegroundStyle: Color {
        isDropTarget || isSelected || isHovered ? .white : .primary
    }

}
