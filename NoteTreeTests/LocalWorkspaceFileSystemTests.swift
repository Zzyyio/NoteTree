import XCTest
@testable import NoteTree

final class LocalWorkspaceFileSystemTests: XCTestCase {
    func testCreateMarkdownCreatesAnEmptyFileInsideTheRequestedDirectory() async throws {
        let workspace = try TemporaryWorkspace()
        let folder = try workspace.makeDirectory("Notes")
        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())

        let created = try await fileSystem.createMarkdown(named: "Lecture.md", in: folder)

        XCTAssertEqual(created.relativePath, "Notes/Lecture.md")
        XCTAssertEqual(created.kind, .markdown)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Lecture.md")), Data())
    }

    func testCreateRejectsInvalidAndConflictingNamesWithoutChangingExistingFile() async throws {
        let workspace = try TemporaryWorkspace()
        let existingFile = try workspace.writeFile("Existing.md", contents: "original")
        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())

        await assertWorkspaceError(.invalidFileName) {
            _ = try await fileSystem.createMarkdown(named: "../escape.md", in: workspace.url)
        }
        await assertWorkspaceError(.nameConflict) {
            _ = try await fileSystem.createMarkdown(named: "Existing.md", in: workspace.url)
        }

        XCTAssertEqual(try String(contentsOf: existingFile, encoding: .utf8), "original")
    }

    func testRenameAndMoveUpdateTheFilesystem() async throws {
        let workspace = try TemporaryWorkspace()
        let source = try workspace.writeFile("Inbox/draft.md")
        let destination = try workspace.makeDirectory("Archive")
        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())

        let renamed = try await fileSystem.renameItem(at: source, to: "final.md")
        let moved = try await fileSystem.moveItem(at: renamed.url, to: destination)

        XCTAssertEqual(moved.relativePath, "Archive/final.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("final.md").path))
    }

    func testRenameRejectsTheRootAndAConflictingName() async throws {
        let workspace = try TemporaryWorkspace()
        let source = try workspace.writeFile("source.md", contents: "source")
        let existing = try workspace.writeFile("existing.md", contents: "existing")
        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())

        await assertWorkspaceError(.rootOperationForbidden) {
            _ = try await fileSystem.renameItem(at: workspace.url, to: "renamed")
        }
        await assertWorkspaceError(.nameConflict) {
            _ = try await fileSystem.renameItem(at: source, to: "existing.md")
        }

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
    }

    func testMoveAndTrashRejectRootAndSymbolicLinkEscape() async throws {
        let workspace = try TemporaryWorkspace()
        let outsideWorkspace = try TemporaryWorkspace()
        let source = try workspace.writeFile("move-me.md")
        let escapingLink = workspace.url.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationURL: outsideWorkspace.url)
        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())

        await assertWorkspaceError(.rootOperationForbidden) {
            try await fileSystem.trashItem(at: workspace.url)
        }
        await assertWorkspaceError(.outOfWorkspace) {
            _ = try await fileSystem.moveItem(at: source, to: escapingLink)
        }
        await assertWorkspaceError(.outOfWorkspace) {
            try await fileSystem.trashItem(at: escapingLink)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testTrashUsesInjectedTrashProvider() async throws {
        let workspace = try TemporaryWorkspace()
        let source = try workspace.writeFile("discard.md")
        let fakeTrash = try TemporaryWorkspace()
        let fileSystem = LocalWorkspaceFileSystem(
            workspace: workspace.workspace(),
            trashProvider: TestWorkspaceTrash(destinationDirectory: fakeTrash.url)
        )

        try await fileSystem.trashItem(at: source)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakeTrash.url.appendingPathComponent("discard.md").path))
    }

    func testTypeDetectionUsesContentTypeWithExtensionFallback() {
        let detector = SystemFileTypeDetector()

        XCTAssertEqual(detector.kind(for: URL(fileURLWithPath: "/tmp/Note.MARKDOWN")), .markdown)
        XCTAssertEqual(detector.kind(for: URL(fileURLWithPath: "/tmp/Reference.PDF")), .pdf)
        XCTAssertEqual(detector.kind(for: URL(fileURLWithPath: "/tmp/Photo.JPEG")), .image(.jpeg))
        XCTAssertEqual(detector.kind(for: URL(fileURLWithPath: "/tmp/Archive.bin")), .unsupported)
    }

    func testChildrenSortFoldersFirstAndExcludeHiddenPackagesAndBuildArtifacts() async throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.makeDirectory("Zeta")
        _ = try workspace.makeDirectory("Alpha")
        _ = try workspace.makeDirectory("Ignored.app")
        _ = try workspace.makeDirectory(".git")
        _ = try workspace.makeDirectory("build")
        _ = try workspace.writeFile("zeta.md")
        _ = try workspace.writeFile("Alpha.MARKDOWN")
        _ = try workspace.writeFile(".hidden.md")

        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())
        let nodes = try await fileSystem.children(of: workspace.url)

        XCTAssertEqual(nodes.map(\.displayName), ["Alpha", "Zeta", "Alpha.MARKDOWN", "zeta.md"])
        XCTAssertEqual(nodes.first?.kind, .folder)
        XCTAssertEqual(nodes.dropFirst(2).first?.kind, .markdown)
    }

    func testChildrenRejectDirectoryOutsideWorkspace() async throws {
        let workspace = try TemporaryWorkspace()
        let outsideWorkspace = try TemporaryWorkspace()
        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())

        do {
            _ = try await fileSystem.children(of: outsideWorkspace.url)
            XCTFail("An out-of-workspace path must be rejected.")
        } catch let error as WorkspaceError {
            XCTAssertEqual(error, .outOfWorkspace)
        }
    }

    func testChildrenExcludeSymbolicLinksThatEscapeWorkspace() async throws {
        let workspace = try TemporaryWorkspace()
        let outsideWorkspace = try TemporaryWorkspace()
        let outsideFile = try outsideWorkspace.writeFile("outside.md")
        let linkURL = workspace.url.appendingPathComponent("outside-link.md")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideFile)

        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())
        let nodes = try await fileSystem.children(of: workspace.url)

        XCTAssertFalse(nodes.contains(where: { $0.displayName == "outside-link.md" }))
    }

    func testMatchingEntriesSearchesNestedFilesWithoutReadingOnTheMainActor() async throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.writeFile("Nested/needle.md")
        _ = try workspace.writeFile("Nested/other.pdf")
        _ = try workspace.writeFile("visible.md")

        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())
        let matches = try await fileSystem.matchingEntries(query: "needle")

        XCTAssertEqual(matches.map(\.relativePath), ["Nested/needle.md"])
        XCTAssertEqual(matches.first?.kind, .markdown)
    }

    func testRootScanHandlesFiveThousandEntries() async throws {
        let workspace = try TemporaryWorkspace()
        for index in 0..<5_000 {
            let url = workspace.url.appendingPathComponent("Note \(index).md")
            guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil) else {
                XCTFail("Could not create a test file.")
                return
            }
        }

        let fileSystem = LocalWorkspaceFileSystem(workspace: workspace.workspace())
        let nodes = try await fileSystem.children(of: workspace.url)

        XCTAssertEqual(nodes.count, 5_000)
    }

    private func assertWorkspaceError(
        _ expectedError: WorkspaceError,
        operation: @escaping () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expectedError) to be thrown.")
        } catch let error as WorkspaceError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Expected WorkspaceError, got \(error).")
        }
    }
}

private struct TestWorkspaceTrash: WorkspaceItemTrashing {
    let destinationDirectory: URL

    func trashItem(at url: URL) throws {
        try FileManager.default.moveItem(
            at: url,
            to: destinationDirectory.appendingPathComponent(url.lastPathComponent)
        )
    }
}
