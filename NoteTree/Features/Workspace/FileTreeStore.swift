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
    private struct VisibleTreeSnapshot {
        let rootChildren: [FileNode]
        let matchingNodes: [FileNode]
        let expandedNodeIDs: Set<FileNodeID>
        let selectedNodeID: FileNodeID?
        let hoveredNodeID: FileNodeID?
        let foldersPendingChildReload: Set<FileNodeID>
    }

    private struct PendingOptimisticMove {
        let token: UUID
        let source: FileNode
        let destinationDirectory: URL
        let snapshot: VisibleTreeSnapshot
    }

    private enum InternalMutationRefreshSuppression {
        case inFlight
        case until(Date)
    }

    let workspace: Workspace
    private let fileSystem: any WorkspaceFileSystem
    private let clipboard: any FileURLCopying

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
    private(set) var inspectedItem: FileItemInfo?
    private(set) var inspectionError: WorkspaceError?
    private(set) var isShowingInspection = false
    private(set) var draggedNodeID: FileNodeID?
    private(set) var dropTargetNodeID: FileNodeID?
    private(set) var isRootDropTarget = false
    private(set) var hoveredNodeID: FileNodeID?
    private var activeDragToken: UUID?
    private var pendingOptimisticMove: PendingOptimisticMove?
    private var foldersPendingChildReload: Set<FileNodeID> = []

    private var filterTask: Task<Void, Never>?
    private var undoManager: UndoManager?
    private var internalMutationRefreshSuppression: InternalMutationRefreshSuppression?

    init(
        workspace: Workspace,
        fileSystem: any WorkspaceFileSystem,
        clipboard: any FileURLCopying = SystemFileURLClipboard()
    ) {
        self.workspace = workspace
        self.fileSystem = fileSystem
        self.clipboard = clipboard
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
        guard let node = node(with: nodeID), node.isFolder,
              node.children == nil || foldersPendingChildReload.contains(nodeID) else {
            return
        }

        do {
            let children = try await fileSystem.children(of: node.url)
            replaceChildren(of: nodeID, with: children)
            foldersPendingChildReload.remove(nodeID)
            lastError = nil
        } catch let error as WorkspaceError {
            lastError = error
        } catch {
            lastError = .readFailed
        }
    }

    var beforeSelection: (() async -> Bool)?
    var canMutate: ((FileNode) -> Bool)?
    private var selectionTask: Task<Void, Never>?
    private(set) var backHistory: [FileNodeID] = []
    private(set) var forwardHistory: [FileNodeID] = []

    func select(_ node: FileNode) {
        guard selectedNodeID != node.id else { return }
        guard let beforeSelection else {
            selectedNodeID = node.id
            return
        }
        guard selectionTask == nil else { return }
        selectionTask = Task {
            defer { selectionTask = nil }
            guard await beforeSelection() else { return }
            if let selectedNodeID { backHistory.append(selectedNodeID) }
            forwardHistory = []
            selectedNodeID = node.id
        }
    }

    func navigateHistory(back: Bool) {
        guard selectionTask == nil else { return }
        selectionTask = Task {
            defer { selectionTask = nil }
            guard await beforeSelection?() ?? true else { return }
            var history = back ? backHistory : forwardHistory
            while let id = history.popLast() {
                guard node(with: id) != nil else { continue }
                if let current = selectedNodeID {
                    if back { forwardHistory.append(current) } else { backHistory.append(current) }
                }
                selectedNodeID = id
                break
            }
            if back { backHistory = history } else { forwardHistory = history }
        }
    }

    func restorePath(_ path: String) async {
        let parts = path.split(separator: "/")
        guard !parts.isEmpty, !parts.contains("..") else { return }
        var prefix: [String] = []
        for part in parts.dropLast() {
            prefix.append(String(part))
            let id = FileNodeID(workspaceID: workspace.id, relativePath: prefix.joined(separator: "/"))
            guard node(with: id)?.isFolder == true else { return }
            if !expandedNodeIDs.contains(id) { await setExpanded(id, isExpanded: true) }
        }
        let id = FileNodeID(workspaceID: workspace.id, relativePath: path)
        if node(with: id) != nil { selectedNodeID = id }
    }

    func setHovered(_ node: FileNode, isHovering: Bool) {
        if isHovering {
            hoveredNodeID = node.id
        } else if hoveredNodeID == node.id {
            hoveredNodeID = nil
        }
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
        guard await beforeSelection?() ?? true else { return }
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
        guard canMutate?(node) ?? true else { inlineOperationError = .unsavedChanges; return }
        guard renameNodeID == node.id else {
            return
        }

        do {
            let renamed = try await fileSystem.renameItem(at: node.url, to: renameName)
            cancelRename()
            registerUndo(.rename(currentURL: renamed.url, previousName: node.displayName))
            applySuccessfulMove(of: node, to: renamed)
        } catch let error as WorkspaceError {
            inlineOperationError = error
        } catch {
            inlineOperationError = .moveFailed
        }
    }

    @discardableResult
    func move(_ node: FileNode, to destinationDirectory: URL) async -> Bool {
        guard pendingOptimisticMove == nil,
              let pendingMove = prepareOptimisticMove(
                  token: UUID(),
                  source: node,
                  destinationDirectory: destinationDirectory
              ) else {
            return false
        }
        return await performMove(pendingMove)
    }

    func trash(_ node: FileNode) async {
        guard canMutate?(node) ?? true else { lastError = .unsavedChanges; return }
        do {
            try await fileSystem.trashItem(at: node.url)
            removeFromVisibleTree(node)
        } catch let error as WorkspaceError {
            lastError = error
        } catch {
            lastError = .trashFailed
        }
    }

    func copy(_ node: FileNode) async {
        do {
            _ = try await fileSystem.itemInfo(at: node.url)
            clipboard.copyFileURL(node.url)
            lastError = nil
        } catch let error as WorkspaceError {
            lastError = error
        } catch {
            lastError = .readFailed
        }
    }

    func inspect(_ node: FileNode? = nil) async {
        isShowingInspection = true
        inspectedItem = nil
        inspectionError = nil

        do {
            inspectedItem = try await fileSystem.itemInfo(at: node?.url ?? workspace.rootURL)
        } catch let error as WorkspaceError {
            inspectionError = error
        } catch {
            inspectionError = .readFailed
        }
    }

    func dismissInspection() {
        isShowingInspection = false
        inspectedItem = nil
        inspectionError = nil
    }

    func beginDragging(_ node: FileNode) -> UUID {
        let token = UUID()
        draggedNodeID = node.id
        activeDragToken = token
        dropTargetNodeID = nil
        isRootDropTarget = false
        return token
    }

    func canAcceptDrop(on destination: FileNode?) -> Bool {
        guard let source = draggedNode(), let destination else {
            return destination == nil && draggedNode() != nil && sourceCanMoveToRoot()
        }

        guard destination.isFolder else {
            return false
        }
        return canMove(source, to: destination.url)
    }

    func updateDropTarget(_ destination: FileNode?) {
        guard canAcceptDrop(on: destination) else {
            clearDropTarget()
            return
        }
        dropTargetNodeID = destination?.id
        isRootDropTarget = destination == nil
    }

    func clearDropTarget() {
        dropTargetNodeID = nil
        isRootDropTarget = false
    }

    func beginDrop(on destination: FileNode?) -> UUID? {
        guard pendingOptimisticMove == nil,
              let token = activeDragToken,
              let source = draggedNode(),
              canAcceptDrop(on: destination),
              let pendingMove = prepareOptimisticMove(
                  token: token,
                  source: source,
                  destinationDirectory: destination?.url ?? workspace.rootURL
              ) else {
            return nil
        }

        pendingOptimisticMove = pendingMove
        draggedNodeID = nil
        activeDragToken = nil
        clearDropTarget()
        return token
    }

    @discardableResult
    func finishDrop(with token: UUID) async -> Bool {
        guard let pendingMove = pendingOptimisticMove, pendingMove.token == token else {
            return false
        }
        pendingOptimisticMove = nil
        return await performMove(pendingMove)
    }

    @discardableResult
    func completeDrop(with token: UUID, on destination: FileNode?) async -> Bool {
        guard token == activeDragToken,
              let startedToken = beginDrop(on: destination) else {
            return false
        }
        return await finishDrop(with: startedToken)
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
        let expandedPaths = Set(expandedNodeIDs.map(\.relativePath))
        let selectedPath = selectedNodeID?.relativePath

        do {
            // Construct the expanded hierarchy before publishing it. Replacing the tree one
            // time prevents List from briefly collapsing every open branch after a file action.
            let refreshedRootChildren = try await refreshedChildren(
                in: workspace.rootURL,
                expandedPaths: expandedPaths
            )
            rootChildren = refreshedRootChildren
            foldersPendingChildReload = []
            expandedNodeIDs = Set(expandedPaths.compactMap { path in
                let nodeID = FileNodeID(workspaceID: workspace.id, relativePath: path)
                return node(with: nodeID)?.isFolder == true ? nodeID : nil
            })
            restoreSelection(relativePath: selectedPath)
            updateFilter()
        } catch {
            // Keep the last visible tree if a concurrent external change makes reloading fail.
        }
    }

    func refreshAfterExternalChange() async {
        switch internalMutationRefreshSuppression {
        case .inFlight:
            return
        case .until(let deadline) where Date() <= deadline:
            // A coordinated move may emit several presenter callbacks. Every callback inside
            // this bounded window describes the already-visible local mutation.
            return
        case .until, .none:
            internalMutationRefreshSuppression = nil
        }

        await refresh()
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

    private func draggedNode() -> FileNode? {
        guard let draggedNodeID else {
            return nil
        }
        return node(with: draggedNodeID) ?? matchingNodes.first(where: { $0.id == draggedNodeID })
    }

    private func sourceCanMoveToRoot() -> Bool {
        guard let source = draggedNode() else {
            return false
        }
        return canMove(source, to: workspace.rootURL)
    }

    private func canMove(_ source: FileNode, to destinationDirectory: URL) -> Bool {
        let sourceParentURL = source.url.deletingLastPathComponent()
        guard sourceParentURL != destinationDirectory else {
            return false
        }
        guard !source.isFolder
            || (destinationDirectory != source.url && !destinationDirectory.path.hasPrefix(source.url.path + "/")) else {
            return false
        }
        return true
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

    private func applySuccessfulMove(of source: FileNode, to moved: FileNode) {
        applyVisibleMove(of: source, to: moved)
        markInternalMutation()
    }

    private func prepareOptimisticMove(
        token: UUID,
        source: FileNode,
        destinationDirectory: URL
    ) -> PendingOptimisticMove? {
        guard canMutate?(source) ?? true else { lastError = .unsavedChanges; return nil }
        guard canMove(source, to: destinationDirectory),
              let optimisticNode = optimisticMoveNode(for: source, to: destinationDirectory) else {
            lastError = .invalidMoveDestination
            return nil
        }

        let snapshot = visibleTreeSnapshot()
        internalMutationRefreshSuppression = .inFlight
        applyVisibleMove(of: source, to: optimisticNode)
        return PendingOptimisticMove(
            token: token,
            source: source,
            destinationDirectory: destinationDirectory,
            snapshot: snapshot
        )
    }

    private func performMove(_ pendingMove: PendingOptimisticMove) async -> Bool {
        do {
            let moved = try await fileSystem.moveItem(
                at: pendingMove.source.url,
                to: pendingMove.destinationDirectory
            )
            registerUndo(
                .move(
                    currentURL: moved.url,
                    previousDirectory: pendingMove.source.url.deletingLastPathComponent()
                )
            )
            markInternalMutation()
            lastError = nil
            return true
        } catch let error as WorkspaceError {
            restoreVisibleTree(pendingMove.snapshot)
            internalMutationRefreshSuppression = nil
            lastError = error
        } catch {
            restoreVisibleTree(pendingMove.snapshot)
            internalMutationRefreshSuppression = nil
            lastError = .moveFailed
        }
        return false
    }

    private func applyVisibleMove(of source: FileNode, to moved: FileNode) {
        _ = removeNode(with: source.id)
        insertVisibleNode(moved, into: moved.url.deletingLastPathComponent())
        rebaseVisibleState(from: source, to: moved)
        selectedNodeID = moved.id
        refreshActiveFilter()
    }

    private func removeFromVisibleTree(_ node: FileNode) {
        _ = removeNode(with: node.id)
        removeVisibleState(for: node)
        markInternalMutation()
        refreshActiveFilter()
    }

    private func markInternalMutation() {
        internalMutationRefreshSuppression = .until(Date().addingTimeInterval(1))
    }

    private func visibleTreeSnapshot() -> VisibleTreeSnapshot {
        VisibleTreeSnapshot(
            rootChildren: rootChildren,
            matchingNodes: matchingNodes,
            expandedNodeIDs: expandedNodeIDs,
            selectedNodeID: selectedNodeID,
            hoveredNodeID: hoveredNodeID,
            foldersPendingChildReload: foldersPendingChildReload
        )
    }

    private func restoreVisibleTree(_ snapshot: VisibleTreeSnapshot) {
        rootChildren = snapshot.rootChildren
        matchingNodes = snapshot.matchingNodes
        expandedNodeIDs = snapshot.expandedNodeIDs
        selectedNodeID = snapshot.selectedNodeID
        hoveredNodeID = snapshot.hoveredNodeID
        foldersPendingChildReload = snapshot.foldersPendingChildReload
    }

    private func optimisticMoveNode(for source: FileNode, to destinationDirectory: URL) -> FileNode? {
        let destinationURL = destinationDirectory.standardizedFileURL
        let targetURL = destinationURL
            .appendingPathComponent(source.displayName, isDirectory: source.isFolder)
            .standardizedFileURL
        let rootPath = workspace.rootURL.standardizedFileURL.path
        guard targetURL.path.hasPrefix(rootPath + "/") else {
            return nil
        }

        let relativePath = String(targetURL.path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else {
            return nil
        }

        let optimisticBase = FileNode(
            id: FileNodeID(workspaceID: workspace.id, relativePath: relativePath),
            url: targetURL,
            displayName: source.displayName,
            relativePath: relativePath,
            kind: source.kind,
            metadata: source.metadata,
            children: nil
        )

        return FileNode(
            id: optimisticBase.id,
            url: optimisticBase.url,
            displayName: optimisticBase.displayName,
            relativePath: optimisticBase.relativePath,
            kind: optimisticBase.kind,
            metadata: optimisticBase.metadata,
            children: source.children?.map { child in
                rebasedNode(child, from: source, to: optimisticBase)
            }
        )
    }

    @discardableResult
    private func removeNode(with id: FileNodeID) -> FileNode? {
        Self.removeNode(with: id, from: &rootChildren)
    }

    private func insertVisibleNode(_ node: FileNode, into directoryURL: URL) {
        if directoryURL == workspace.rootURL {
            rootChildren = Self.sortedNodes(rootChildren + [node])
            return
        }

        if let destinationID = Self.insertNode(node, into: directoryURL, in: &rootChildren) {
            foldersPendingChildReload.insert(destinationID)
        }
    }

    private func rebaseVisibleState(from source: FileNode, to moved: FileNode) {
        expandedNodeIDs = Set(expandedNodeIDs.map { id in
            rebasedID(id, from: source, to: moved)
        })
        selectedNodeID = selectedNodeID.map { rebasedID($0, from: source, to: moved) }
        hoveredNodeID = hoveredNodeID.map { rebasedID($0, from: source, to: moved) }
        matchingNodes = matchingNodes.map { rebasedNode($0, from: source, to: moved) }
    }

    private func removeVisibleState(for removedNode: FileNode) {
        expandedNodeIDs = Set(expandedNodeIDs.filter { id in
            !isDescendantOrSame(id.relativePath, of: removedNode.relativePath)
        })
        if let selectedNodeID,
           isDescendantOrSame(selectedNodeID.relativePath, of: removedNode.relativePath) {
            restoreSelection(relativePath: removedNode.relativePath)
        }
        if let hoveredNodeID,
           isDescendantOrSame(hoveredNodeID.relativePath, of: removedNode.relativePath) {
            self.hoveredNodeID = nil
        }
        matchingNodes.removeAll { node in
            isDescendantOrSame(node.relativePath, of: removedNode.relativePath)
        }
    }

    private func refreshActiveFilter() {
        guard !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        updateFilter()
    }

    private func rebasedID(_ id: FileNodeID, from source: FileNode, to moved: FileNode) -> FileNodeID {
        guard isDescendantOrSame(id.relativePath, of: source.relativePath) else {
            return id
        }

        let suffix = String(id.relativePath.dropFirst(source.relativePath.count))
        return FileNodeID(workspaceID: workspace.id, relativePath: moved.relativePath + suffix)
    }

    private func rebasedNode(_ node: FileNode, from source: FileNode, to moved: FileNode) -> FileNode {
        let id = rebasedID(node.id, from: source, to: moved)
        guard id != node.id else {
            return node
        }

        return FileNode(
            id: id,
            url: workspace.rootURL.appendingPathComponent(id.relativePath, isDirectory: node.isFolder),
            displayName: node.displayName,
            relativePath: id.relativePath,
            kind: node.kind,
            metadata: node.metadata,
            children: node.children?.map { rebasedNode($0, from: source, to: moved) }
        )
    }

    private func isDescendantOrSame(_ path: String, of ancestorPath: String) -> Bool {
        path == ancestorPath || path.hasPrefix(ancestorPath + "/")
    }

    private func refreshedChildren(
        in directoryURL: URL,
        expandedPaths: Set<String>
    ) async throws -> [FileNode] {
        var children = try await fileSystem.children(of: directoryURL)

        for index in children.indices where children[index].isFolder
            && expandedPaths.contains(children[index].relativePath) {
            children[index].children = try await refreshedChildren(
                in: children[index].url,
                expandedPaths: expandedPaths
            )
        }

        return children
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

    private static func removeNode(with id: FileNodeID, from nodes: inout [FileNode]) -> FileNode? {
        for index in nodes.indices {
            if nodes[index].id == id {
                return nodes.remove(at: index)
            }
            if var children = nodes[index].children,
               let removed = removeNode(with: id, from: &children) {
                nodes[index].children = children
                return removed
            }
        }
        return nil
    }

    private static func insertNode(
        _ node: FileNode,
        into directoryURL: URL,
        in nodes: inout [FileNode]
    ) -> FileNodeID? {
        for index in nodes.indices {
            if nodes[index].url == directoryURL {
                let requiresReload = nodes[index].children == nil
                var children = nodes[index].children ?? []
                children.append(node)
                nodes[index].children = sortedNodes(children)
                return requiresReload ? nodes[index].id : nil
            }
            if var children = nodes[index].children {
                let destinationID = insertNode(node, into: directoryURL, in: &children)
                nodes[index].children = children
                if let destinationID {
                    return destinationID
                }
            }
        }
        return nil
    }

    private static func sortedNodes(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { left, right in
            if left.isFolder != right.isFolder {
                return left.isFolder
            }
            return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
        }
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
        guard await beforeSelection?() ?? true else { return }
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
