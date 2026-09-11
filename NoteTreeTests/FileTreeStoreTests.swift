import XCTest
@testable import NoteTree

@MainActor
final class FileTreeStoreTests: XCTestCase {
    func testLazyExpansionAndRefreshPreserveSelectionWhenFinderAddsAFile() async throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.writeFile("Folder/keep.md")
        let workspaceModel = workspace.workspace()
        let fileSystem = LocalWorkspaceFileSystem(workspace: workspaceModel)
        let fileTree = FileTreeStore(workspace: workspaceModel, fileSystem: fileSystem)

        try await fileTree.loadRoot()
        let folder = try XCTUnwrap(fileTree.rootChildren.first(where: { $0.displayName == "Folder" }))
        XCTAssertNil(folder.children)

        await fileTree.setExpanded(folder.id, isExpanded: true)
        let expandedFolder = try XCTUnwrap(fileTree.rootChildren.first(where: { $0.id == folder.id }))
        let selectedFile = try XCTUnwrap(expandedFolder.children?.first(where: { $0.displayName == "keep.md" }))
        fileTree.select(selectedFile)

        _ = try workspace.writeFile("new-from-finder.md")
        await fileTree.refresh()

        XCTAssertTrue(fileTree.expandedNodeIDs.contains(folder.id))
        XCTAssertEqual(fileTree.selectedNode()?.id, selectedFile.id)
        XCTAssertTrue(fileTree.rootChildren.contains(where: { $0.displayName == "new-from-finder.md" }))
    }

    func testDraggedFileMovesToAnEligibleFolderOrTheWorkspaceRoot() async throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.writeFile("Source/note.md")
        _ = try workspace.makeDirectory("Source/Child")
        _ = try workspace.makeDirectory("Destination")
        let workspaceModel = workspace.workspace()
        let fileTree = FileTreeStore(
            workspace: workspaceModel,
            fileSystem: LocalWorkspaceFileSystem(workspace: workspaceModel)
        )

        try await fileTree.loadRoot()
        let source = try XCTUnwrap(fileTree.rootChildren.first(where: { $0.displayName == "Source" }))
        let destination = try XCTUnwrap(fileTree.rootChildren.first(where: { $0.displayName == "Destination" }))
        await fileTree.setExpanded(source.id, isExpanded: true)
        await fileTree.setExpanded(destination.id, isExpanded: true)
        let expandedSource = try XCTUnwrap(fileTree.rootChildren.first(where: { $0.id == source.id }))
        let note = try XCTUnwrap(expandedSource.children?.first(where: { $0.displayName == "note.md" }))
        let child = try XCTUnwrap(expandedSource.children?.first(where: { $0.displayName == "Child" }))

        _ = fileTree.beginDragging(source)
        XCTAssertFalse(fileTree.canAcceptDrop(on: child))
        XCTAssertTrue(fileTree.canAcceptDrop(on: destination))

        let dragToken = fileTree.beginDragging(note)
        let didMove = await fileTree.completeDrop(with: dragToken, on: destination)
        XCTAssertTrue(didMove)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.url.appendingPathComponent("Destination/note.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url.appendingPathComponent("Source/note.md").path))

        let movedNote = try XCTUnwrap(fileTree.rootChildren.first(where: { $0.id == destination.id })?.children?.first)
        XCTAssertFalse(fileTree.rootChildren.first(where: { $0.id == source.id })?.children?.contains(where: { $0.id == note.id }) == true)

        _ = try workspace.writeFile("from-finder.md")
        await fileTree.refreshAfterExternalChange()
        XCTAssertFalse(fileTree.rootChildren.contains(where: { $0.displayName == "from-finder.md" }))

        await fileTree.refresh()
        XCTAssertTrue(fileTree.rootChildren.contains(where: { $0.displayName == "from-finder.md" }))

        let rootDragToken = fileTree.beginDragging(movedNote)
        XCTAssertTrue(fileTree.canAcceptDrop(on: nil))
        let didMoveToRoot = await fileTree.completeDrop(with: rootDragToken, on: nil)

        XCTAssertTrue(didMoveToRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.url.appendingPathComponent("note.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url.appendingPathComponent("Destination/note.md").path))
    }

    func testSynchronousDropUpdatesImmediatelyAndRollsBackAfterFailure() async throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.writeFile("Source/note.md")
        _ = try workspace.makeDirectory("Destination")
        let workspaceModel = workspace.workspace()
        let fileSystem = DelayedFailingMoveFileSystem(workspace: workspaceModel)
        let fileTree = FileTreeStore(workspace: workspaceModel, fileSystem: fileSystem)

        try await fileTree.loadRoot()
        let source = try XCTUnwrap(fileTree.rootChildren.first(where: { $0.displayName == "Source" }))
        let destination = try XCTUnwrap(fileTree.rootChildren.first(where: { $0.displayName == "Destination" }))
        await fileTree.setExpanded(source.id, isExpanded: true)
        let expandedSource = try XCTUnwrap(fileTree.rootChildren.first(where: { $0.id == source.id }))
        let note = try XCTUnwrap(expandedSource.children?.first)
        fileTree.select(note)

        let dragToken = fileTree.beginDragging(expandedSource)
        let startedToken = try XCTUnwrap(fileTree.beginDrop(on: destination))
        XCTAssertEqual(startedToken, dragToken)

        XCTAssertNil(fileTree.rootChildren.first(where: { $0.id == source.id }))
        let optimisticFolder = try XCTUnwrap(
            fileTree.rootChildren.first(where: { $0.id == destination.id })?.children?.first
        )
        XCTAssertEqual(optimisticFolder.displayName, "Source")
        XCTAssertEqual(optimisticFolder.children?.first?.relativePath, "Destination/Source/note.md")

        let finishTask = Task { @MainActor in
            await fileTree.finishDrop(with: startedToken)
        }
        await fileSystem.waitUntilMoveStarts()

        await fileSystem.failMove()
        let didMove = await finishTask.value
        XCTAssertFalse(didMove)

        XCTAssertEqual(fileTree.selectedNodeID, note.id)
        XCTAssertEqual(fileTree.rootChildren.first(where: { $0.id == source.id })?.children?.first?.id, note.id)
        XCTAssertNil(fileTree.rootChildren.first(where: { $0.id == destination.id })?.children)
        XCTAssertEqual(fileTree.lastError, .permissionDenied)
    }

    func testCopyAndInspectionUseInjectedClipboardAndMetadata() async throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.writeFile("note.md", contents: "body")
        let workspaceModel = workspace.workspace()
        let clipboard = RecordingFileURLClipboard()
        let fileTree = FileTreeStore(
            workspace: workspaceModel,
            fileSystem: LocalWorkspaceFileSystem(workspace: workspaceModel),
            clipboard: clipboard
        )

        try await fileTree.loadRoot()
        let note = try XCTUnwrap(fileTree.rootChildren.first)
        fileTree.select(note)
        fileTree.setHovered(note, isHovering: true)
        await fileTree.copy(note)
        await fileTree.inspect(note)

        XCTAssertEqual(clipboard.copiedURLs, [note.url])
        XCTAssertEqual(fileTree.selectedNodeID, note.id)
        XCTAssertEqual(fileTree.hoveredNodeID, note.id)
        XCTAssertEqual(fileTree.inspectedItem?.displayName, "note.md")
        XCTAssertEqual(fileTree.inspectedItem?.byteCount, 4)
        XCTAssertNil(fileTree.inspectionError)
    }
}

@MainActor
private final class RecordingFileURLClipboard: FileURLCopying {
    private(set) var copiedURLs: [URL] = []

    func copyFileURL(_ url: URL) {
        copiedURLs.append(url)
    }
}

private actor DelayedFailingMoveFileSystem: WorkspaceFileSystem {
    private let backing: LocalWorkspaceFileSystem
    private var hasStartedMove = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var failureContinuation: CheckedContinuation<Void, Never>?

    init(workspace: Workspace) {
        backing = LocalWorkspaceFileSystem(workspace: workspace)
    }

    func children(of directory: URL) async throws -> [FileNode] {
        try await backing.children(of: directory)
    }

    func matchingEntries(query: String) async throws -> [FileNode] {
        try await backing.matchingEntries(query: query)
    }

    func createMarkdown(named name: String, in directory: URL) async throws -> FileNode {
        try await backing.createMarkdown(named: name, in: directory)
    }

    func createDirectory(named name: String, in directory: URL) async throws -> FileNode {
        try await backing.createDirectory(named: name, in: directory)
    }

    func renameItem(at url: URL, to name: String) async throws -> FileNode {
        try await backing.renameItem(at: url, to: name)
    }

    func moveItem(at url: URL, to destinationDirectory: URL) async throws -> FileNode {
        hasStartedMove = true
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            failureContinuation = continuation
        }
        throw WorkspaceError.permissionDenied
    }

    func trashItem(at url: URL) async throws {
        try await backing.trashItem(at: url)
    }

    func itemInfo(at url: URL) async throws -> FileItemInfo {
        try await backing.itemInfo(at: url)
    }

    func readData(at url: URL) async throws -> VersionedFileData {
        try await backing.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL, expectedVersion: FileVersion) async throws -> FileVersion {
        try await backing.writeData(data, to: url, expectedVersion: expectedVersion)
    }

    func writeCopy(of data: Data, for url: URL, named name: String) async throws -> URL {
        try await backing.writeCopy(of: data, for: url, named: name)
    }

    func waitUntilMoveStarts() async {
        guard !hasStartedMove else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func failMove() {
        failureContinuation?.resume()
        failureContinuation = nil
    }
}
