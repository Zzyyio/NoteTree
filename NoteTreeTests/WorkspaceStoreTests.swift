import XCTest
@testable import NoteTree

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testSelectedWorkspaceIsPersistedAndScanned() async throws {
        let workspace = try TemporaryWorkspace()
        _ = try workspace.writeFile("first.md")
        let suiteName = "NoteTreeTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        let bookmarkStore = WorkspaceBookmarkStore(
            defaultsSuiteName: suiteName,
            defaultsKey: "recents",
            provider: TestStoreBookmarkProvider(rootURL: workspace.url)
        )
        let store = WorkspaceStore(
            bookmarkStore: bookmarkStore,
            picker: FixedWorkspacePicker(url: workspace.url),
            resourceAccess: AlwaysGrantedResourceAccess(),
            fileSystemFactory: { workspace in
                LocalWorkspaceFileSystem(workspace: workspace)
            }
        )

        await store.chooseWorkspace()

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.fileTree?.rootChildren.map(\.displayName), ["first.md"])
        XCTAssertEqual(store.recents.map(\.workspace.id), [store.currentWorkspace?.id].compactMap { $0 })
    }
}

@MainActor
private final class FixedWorkspacePicker: WorkspacePicking {
    let url: URL?

    init(url: URL?) {
        self.url = url
    }

    func pickWorkspace() -> URL? {
        url
    }
}

private struct AlwaysGrantedResourceAccess: SecurityScopedResourceAccessing {
    func startAccessing(_ url: URL) -> Bool {
        true
    }

    func stopAccessing(_ url: URL) {}
}

private struct TestStoreBookmarkProvider: SecurityScopedBookmarkProviding {
    let rootURL: URL

    func makeBookmark(for url: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: rootURL, isStale: false)
    }
}
