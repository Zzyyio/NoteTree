import Foundation
import Observation

enum FileTreeCreationKind: Sendable {
    case markdown
    case folder

    var defaultName: String {
        switch self {
        case .markdown:
            "Untitled.md"
        case .folder:
            "New Folder"
        }
    }
}

@MainActor
@Observable
final class FileTreeStore {
    let workspace: Workspace
    private let fileSystem: any WorkspaceFileSystem

    private(set) var rootChildren: [FileNode] = []
    private(set) var matchingNodes: [FileNode] = []
    private(set) var expandedNodeIDs: Set<FileNodeID> = []
    private(set) var selectedNodeID: FileNodeID?
    private(set) var lastError: WorkspaceError?
    private(set) var isLoading = false
    var filterText = ""
    private(set) var creationKind: FileTreeCreationKind?
    private(set) var creationParentID: FileNodeID?
    var creationName = ""
    private(set) var renameNodeID: FileNodeID?
    var renameName = ""
    private(set) var inlineOperationError: WorkspaceError?

    private var filterTask: Task<Void, Never>?
    private var undoManager: UndoManager?

    init(workspace: Workspace, fileSystem: any WorkspaceFileSystem) {
        self.workspace = workspace
        self.fileSystem = fileSystem
    }

    func loadRoot() async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            rootChildren = try await fileSystem.children(of: workspace.rootURL)
            lastError = nil
        } catch let error as WorkspaceError {
            lastError = error
            throw error
        } catch {
            lastError = .readFailed
            throw WorkspaceError.readFailed
        }
    }

    func setExpanded(_ nodeID: FileNodeID, isExpanded: Bool) async {
        if !isExpanded {
            expandedNodeIDs.remove(nodeID)
            return
        }

        expandedNodeIDs.insert(nodeID)
        guard let node = node(with: nodeID), node.isFolder, node.children == nil else {
            return
        }

        do {
            let children = try await fileSystem.children(of: node.url)
            replaceChildren(of: nodeID, with: children)
            lastError = nil
        } catch let error as WorkspaceError {
            lastError = error
        } catch {
            lastError = .readFailed
        }
    }

    func select(_ node: FileNode) {
        selectedNodeID = node.id
    }

    func setUndoManager(_ undoManager: UndoManager?) {
        self.undoManager = undoManager
    }

    func beginCreation(_ kind: FileTreeCreationKind, in folder: FileNode? = nil) {
        guard folder == nil || folder?.isFolder == true else {
            return
        }

        renameNodeID = nil
        creationKind = kind
        creationParentID = folder?.id
        creationName = kind.defaultName
        inlineOperationError = nil
    }

    func cancelCreation() {
        creationKind = nil
        creationParentID = nil
        creationName = ""
        inlineOperationError = nil
    }

    func commitCreation() async {
        guard let creationKind else {
            return
        }

        let parentURL: URL
        if let creationParentID {
            guard let parent = node(with: creationParentID), parent.isFolder else {
                inlineOperationError = .fileNotFound
                return
            }
            parentURL = parent.url
        } else {
            parentURL = workspace.rootURL
        }

        do {
            let created: FileNode
            switch creationKind {
            case .markdown:
                created = try await fileSystem.createMarkdown(named: creationName, in: parentURL)
            case .folder:
                created = try await fileSystem.createDirectory(named: creationName, in: parentURL)
            }

            cancelCreation()
            registerUndo(.trashCreated(created.url))
            await refresh(selecting: created.id)
        } catch let error as WorkspaceError {
            inlineOperationError = error
        } catch {
            inlineOperationError = .writeFailed
        }
    }

    func beginRename(_ node: FileNode) {
        renameNodeID = node.id
        renameName = node.displayName
        creationKind = nil
        inlineOperationError = nil
    }

    func cancelRename() {
        renameNodeID = nil
        renameName = ""
        inlineOperationError = nil
    }

    func commitRename(for node: FileNode) async {
        guard renameNodeID == node.id else {
            return
        }

        do {
            let renamed = try await fileSystem.renameItem(at: node.url, to: renameName)
            cancelRename()
            registerUndo(.rename(currentURL: renamed.url, previousName: node.displayName))
            await refresh(selecting: renamed.id)
        } catch let error as WorkspaceError {
            inlineOperationError = error
        } catch {
            inlineOperationError = .moveFailed
        }
    }

    func move(_ node: FileNode, to destinationDirectory: URL) async {
        do {
            let moved = try await fileSystem.moveItem(at: node.url, to: destinationDirectory)
            registerUndo(.move(currentURL: moved.url, previousDirectory: node.url.deletingLastPathComponent()))
            await refresh(selecting: moved.id)
        } catch let error as WorkspaceError {
            lastError = error
        } catch {
            lastError = .moveFailed
        }
    }

    func trash(_ node: FileNode) async {
        do {
            try await fileSystem.trashItem(at: node.url)
            await refresh()
        } catch let error as WorkspaceError {
            lastError = error
        } catch {
            lastError = .trashFailed
        }
    }

    func selectedNode() -> FileNode? {
        guard let selectedNodeID else {
            return nil
        }
        return node(with: selectedNodeID) ?? matchingNodes.first(where: { $0.id == selectedNodeID })
    }

    func updateFilter() {
        filterTask?.cancel()
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matchingNodes = []
            return
        }

        let fileSystem = fileSystem
        filterTask = Task { [weak self] in
            do {
                let matches = try await fileSystem.matchingEntries(query: query)
                guard !Task.isCancelled else {
                    return
                }
                self?.matchingNodes = matches
                self?.lastError = nil
            } catch let error as WorkspaceError {
                guard !Task.isCancelled else {
                    return
                }
                self?.lastError = error
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.lastError = .readFailed
            }
        }
    }

    func refresh() async {
        let expandedPaths = expandedNodeIDs.map(\.relativePath)
        let selectedPath = selectedNodeID?.relativePath

        do {
            try await loadRoot()
            expandedNodeIDs = []
            for path in expandedPaths.sorted(by: { $0.count < $1.count }) {
                let nodeID = FileNodeID(workspaceID: workspace.id, relativePath: path)
                if let node = node(with: nodeID), node.isFolder {
                    await setExpanded(nodeID, isExpanded: true)
                }
            }
            restoreSelection(relativePath: selectedPath)
            updateFilter()
        } catch {
            // loadRoot records a user-presentable error while preserving the last visible tree.
        }
    }

    private func restoreSelection(relativePath: String?) {
        guard var candidatePath = relativePath else {
            return
        }

        while true {
            let candidateID = FileNodeID(workspaceID: workspace.id, relativePath: candidatePath)
            if node(with: candidateID) != nil {
                selectedNodeID = candidateID
                return
            }
            guard let separatorIndex = candidatePath.lastIndex(of: "/") else {
                selectedNodeID = nil
                return
            }
            candidatePath = String(candidatePath[..<separatorIndex])
        }
    }

    private func node(with id: FileNodeID) -> FileNode? {
        Self.findNode(with: id, in: rootChildren)
    }

    private static func findNode(with id: FileNodeID, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.id == id {
                return node
            }
            if let children = node.children, let descendant = findNode(with: id, in: children) {
                return descendant
            }
        }
        return nil
    }

    private func replaceChildren(of id: FileNodeID, with children: [FileNode]) {
        Self.replaceChildren(of: id, with: children, in: &rootChildren)
    }

    @discardableResult
    private static func replaceChildren(of id: FileNodeID, with children: [FileNode], in nodes: inout [FileNode]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id {
                nodes[index].children = children
                return true
            }
            if var descendants = nodes[index].children,
               replaceChildren(of: id, with: children, in: &descendants) {
                nodes[index].children = descendants
                return true
            }
        }
        return false
    }

    private func refresh(selecting nodeID: FileNodeID) async {
        await refresh()
        if node(with: nodeID) != nil {
            selectedNodeID = nodeID
        }
    }

    private func registerUndo(_ action: FileTreeUndoAction) {
        guard let undoManager else {
            return
        }

        undoManager.registerUndo(withTarget: self) { store in
            Task { @MainActor in
                await store.performUndo(action)
            }
        }
    }

    private func performUndo(_ action: FileTreeUndoAction) async {
        do {
            switch action {
            case .trashCreated(let url):
                try await fileSystem.trashItem(at: url)
                await refresh()
            case .rename(let currentURL, let previousName):
                let restored = try await fileSystem.renameItem(at: currentURL, to: previousName)
                registerUndo(.rename(currentURL: restored.url, previousName: currentURL.lastPathComponent))
                await refresh(selecting: restored.id)
            case .move(let currentURL, let previousDirectory):
                let restored = try await fileSystem.moveItem(at: currentURL, to: previousDirectory)
                registerUndo(.move(currentURL: restored.url, previousDirectory: currentURL.deletingLastPathComponent()))
                await refresh(selecting: restored.id)
            }
        } catch let error as WorkspaceError {
            lastError = error
        } catch {
            lastError = .moveFailed
        }
    }
}

private enum FileTreeUndoAction: Sendable {
    case trashCreated(URL)
    case rename(currentURL: URL, previousName: String)
    case move(currentURL: URL, previousDirectory: URL)
}
