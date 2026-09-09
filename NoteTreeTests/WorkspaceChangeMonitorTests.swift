import XCTest
@testable import NoteTree

@MainActor
final class WorkspaceChangeMonitorTests: XCTestCase {
    func testPresenterChangeSchedulesARefreshWithoutPolling() async throws {
        let workspace = try TemporaryWorkspace()
        let refreshScheduled = expectation(description: "refresh scheduled")
        let monitor = WorkspaceChangeMonitor(
            rootURL: workspace.url,
            debounceInterval: 0
        ) {
            refreshScheduled.fulfill()
        }
        defer { monitor.stop() }

        monitor.presentedItemDidChange()

        await fulfillment(of: [refreshScheduled], timeout: 1)
    }
}
