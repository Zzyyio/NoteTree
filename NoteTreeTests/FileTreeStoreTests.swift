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
}
