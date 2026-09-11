import XCTest
@testable import NoteTree

@MainActor
final class MarkdownDocumentSessionTests: XCTestCase {
    func testExplicitSaveWritesLatestRapidEditAndClearsDraft() async throws {
        let workspace = try TemporaryWorkspace()
        let noteURL = try workspace.writeFile("note.md", contents: "original")
        let suiteName = "MarkdownDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = MarkdownDocumentSession(
            workspace: workspace.workspace(),
            url: noteURL,
            fileSystem: LocalWorkspaceFileSystem(workspace: workspace.workspace()),
            draftStore: MarkdownDraftStore(defaults: defaults)
        )

        await session.load()
        session.updateText("first")
        session.updateText("latest")

        let didSave = await session.saveNow()
        XCTAssertTrue(didSave)
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "latest")
        XCTAssertEqual(session.state, .clean)
        XCTAssertFalse(session.isDirty)
    }

    func testExternalEditDuringDirtySessionEntersConflictWithoutOverwriting() async throws {
        let workspace = try TemporaryWorkspace()
        let noteURL = try workspace.writeFile("note.md", contents: "disk")
        let session = MarkdownDocumentSession(
            workspace: workspace.workspace(),
            url: noteURL,
            fileSystem: LocalWorkspaceFileSystem(workspace: workspace.workspace())
        )

        await session.load()
        session.updateText("local")
        try "external".write(to: noteURL, atomically: true, encoding: .utf8)

        let didSave = await session.saveNow()
        XCTAssertFalse(didSave)
        XCTAssertEqual(session.state, .conflict)
        XCTAssertEqual(session.difference(), MarkdownTextDifference(localText: "local", externalText: "external"))
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "external")
    }

    func testWriteFailureKeepsDraftAndTextForRetry() async throws {
        let workspace = try TemporaryWorkspace()
        let noteURL = try workspace.writeFile("note.md", contents: "disk")
        let suiteName = "MarkdownDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let draftStore = MarkdownDraftStore(defaults: defaults)
        let workspaceModel = workspace.workspace()
        let session = MarkdownDocumentSession(
            workspace: workspaceModel,
            url: noteURL,
            fileSystem: FailingMarkdownFileSystem(workspace: workspaceModel),
            draftStore: draftStore
        )

        await session.load()
        session.updateText("unsaved")

        let didSave = await session.saveNow()
        XCTAssertFalse(didSave)
        XCTAssertEqual(session.state, .failed(.permissionDenied))
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(draftStore.draft(for: workspaceModel.id, fileURL: noteURL), "unsaved")
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "disk")
    }
}

private actor FailingMarkdownFileSystem: WorkspaceFileSystem {
    private let backing: LocalWorkspaceFileSystem

    init(workspace: Workspace) {
        backing = LocalWorkspaceFileSystem(workspace: workspace)
    }

    func children(of directory: URL) async throws -> [FileNode] { try await backing.children(of: directory) }
    func matchingEntries(query: String) async throws -> [FileNode] { try await backing.matchingEntries(query: query) }
    func createMarkdown(named name: String, in directory: URL) async throws -> FileNode { try await backing.createMarkdown(named: name, in: directory) }
    func createDirectory(named name: String, in directory: URL) async throws -> FileNode { try await backing.createDirectory(named: name, in: directory) }
    func renameItem(at url: URL, to name: String) async throws -> FileNode { try await backing.renameItem(at: url, to: name) }
    func moveItem(at url: URL, to destinationDirectory: URL) async throws -> FileNode { try await backing.moveItem(at: url, to: destinationDirectory) }
    func trashItem(at url: URL) async throws { try await backing.trashItem(at: url) }
    func itemInfo(at url: URL) async throws -> FileItemInfo { try await backing.itemInfo(at: url) }
    func readData(at url: URL) async throws -> VersionedFileData { try await backing.readData(at: url) }
    func writeData(_ data: Data, to url: URL, expectedVersion: FileVersion) async throws -> FileVersion { throw WorkspaceError.permissionDenied }
    func writeCopy(of data: Data, for url: URL, named name: String) async throws -> URL { try await backing.writeCopy(of: data, for: url, named: name) }
}
