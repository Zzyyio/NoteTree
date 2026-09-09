import XCTest
@testable import NoteTree

final class WorkspaceBookmarkStoreTests: XCTestCase {
    func testRestoresMostRecentWorkspaceAndRefreshesStaleBookmark() async throws {
        let workspace = try TemporaryWorkspace()
        let suiteName = makeSuiteName()
        addPersistentDomainCleanup(for: suiteName)
        let store = WorkspaceBookmarkStore(
            defaultsSuiteName: suiteName,
            defaultsKey: "recents",
            provider: TestBookmarkProvider(resolvedURL: workspace.url, isStale: true)
        )

        let savedWorkspace = try await store.saveWorkspace(at: workspace.url)
        let resolution = await store.restoreMostRecent()

        guard case .workspace(let restoredWorkspace) = resolution else {
            return XCTFail("The stale bookmark should be refreshed and restored.")
        }
        XCTAssertEqual(restoredWorkspace.id, savedWorkspace.id)
        XCTAssertEqual(restoredWorkspace.rootURL.standardizedFileURL, workspace.url.standardizedFileURL)
    }

    func testRequestsReauthorizationWhenBookmarkCannotResolve() async throws {
        let workspace = try TemporaryWorkspace()
        let suiteName = makeSuiteName()
        addPersistentDomainCleanup(for: suiteName)
        let saveStore = WorkspaceBookmarkStore(
            defaultsSuiteName: suiteName,
            defaultsKey: "recents",
            provider: TestBookmarkProvider(resolvedURL: workspace.url, isStale: false)
        )
        let savedWorkspace = try await saveStore.saveWorkspace(at: workspace.url)
        let restoreStore = WorkspaceBookmarkStore(
            defaultsSuiteName: suiteName,
            defaultsKey: "recents",
            provider: FailingBookmarkProvider()
        )

        let resolution = await restoreStore.restoreMostRecent()

        guard case .needsReauthorization(let recentWorkspace) = resolution else {
            return XCTFail("An unreadable bookmark must require reauthorization.")
        }
        XCTAssertEqual(recentWorkspace.workspace.id, savedWorkspace.id)
    }

    private func makeSuiteName() -> String {
        "NoteTreeTests.\(UUID().uuidString)"
    }

    private func addPersistentDomainCleanup(for suiteName: String) {
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }
}

private struct TestBookmarkProvider: SecurityScopedBookmarkProviding {
    let resolvedURL: URL
    let isStale: Bool

    func makeBookmark(for url: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedBookmark {
        ResolvedBookmark(url: resolvedURL, isStale: isStale)
    }
}

private struct FailingBookmarkProvider: SecurityScopedBookmarkProviding {
    private enum Failure: Error {
        case unavailable
    }

    func makeBookmark(for url: URL) throws -> Data {
        Data("test-bookmark".utf8)
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedBookmark {
        throw Failure.unavailable
    }
}
