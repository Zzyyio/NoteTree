import XCTest
@testable import NoteTree

final class NonPDFCompletionTests: XCTestCase {
    func testPreviewSeparatesTableImageAndCodeWithoutParsingCodeAsImage() {
        let blocks = MarkdownBlock.parse("# Heading\n| A | B |\n|---|---|\n| 1 | 2 |\n![alt](local.png)\n```\n![literal](x)\n```")
        XCTAssertEqual(blocks, [.heading("Heading", 1), .table([["A", "B"], ["1", "2"]]),
                                .image("alt", "local.png"), .code("![literal](x)")])
    }

    func testHiddenAndGlobExclusionsKeepGitProtected() {
        let policy = FileTreeExclusionPolicy(showHidden: true, patterns: ["*.tmp", "cache?"])
        XCTAssertTrue(policy.shouldExclude(URL(fileURLWithPath: "/tmp/.git")))
        XCTAssertTrue(policy.shouldExclude(URL(fileURLWithPath: "/tmp/a.tmp")))
        XCTAssertTrue(policy.shouldExclude(URL(fileURLWithPath: "/tmp/cache1")))
        XCTAssertFalse(policy.shouldExclude(URL(fileURLWithPath: "/tmp/.notes")))
    }

    @MainActor
    func testRestoringNestedSelectionLoadsParentsAndRejectsEscape() async throws {
        let temporary = try TemporaryWorkspace()
        _ = try temporary.writeFile("a/b/note.md")
        let workspace = temporary.workspace()
        let tree = FileTreeStore(workspace: workspace, fileSystem: LocalWorkspaceFileSystem(workspace: workspace))
        try await tree.loadRoot()
        await tree.restorePath("a/b/note.md")
        XCTAssertEqual(tree.selectedNode()?.relativePath, "a/b/note.md")
        XCTAssertEqual(tree.expandedNodeIDs.count, 2)
        await tree.restorePath("../outside")
        XCTAssertEqual(tree.selectedNode()?.relativePath, "a/b/note.md")
    }

    @MainActor
    func testDirtyMutationGuardPreventsMoveRenameAndTrash() async throws {
        let temporary = try TemporaryWorkspace()
        _ = try temporary.writeFile("note.md", contents: "keep")
        let destination = try temporary.makeDirectory("folder")
        let workspace = temporary.workspace()
        let tree = FileTreeStore(workspace: workspace, fileSystem: LocalWorkspaceFileSystem(workspace: workspace))
        try await tree.loadRoot()
        let note = try XCTUnwrap(tree.rootChildren.first { $0.displayName == "note.md" })
        tree.canMutate = { _ in false }
        let moved = await tree.move(note, to: destination)
        XCTAssertFalse(moved)
        tree.beginRename(note)
        tree.renameName = "changed.md"
        await tree.commitRename(for: note)
        XCTAssertEqual(tree.inlineOperationError, .unsavedChanges)
        await tree.trash(note)
        XCTAssertEqual(tree.lastError, .unsavedChanges)
        XCTAssertEqual(try String(contentsOf: note.url, encoding: .utf8), "keep")
    }

    @MainActor
    func testMarkdownImagesRejectRemoteAndOutsideWorkspace() async throws {
        let temporary = try TemporaryWorkspace()
        let url = try temporary.writeFile("note.md")
        let workspace = temporary.workspace()
        let session = MarkdownDocumentSession(workspace: workspace, url: url,
                                               fileSystem: LocalWorkspaceFileSystem(workspace: workspace))
        let remote = await session.localImagePreview("https://example.com/image.png")
        let outside = await session.localImagePreview("../../image.png")
        XCTAssertNil(remote)
        XCTAssertNil(outside)
    }
}
