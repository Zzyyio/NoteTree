import XCTest
@testable import NoteTree

final class EditorRouterTests: XCTestCase {
    func testRoutesEachSupportedAndUnsupportedFileKind() {
        XCTAssertEqual(EditorRouter.route(for: .folder), .folder)
        XCTAssertEqual(EditorRouter.route(for: .markdown), .markdown)
        XCTAssertEqual(EditorRouter.route(for: .pdf), .pdf)
        XCTAssertEqual(EditorRouter.route(for: .image(.png)), .image)
        XCTAssertEqual(EditorRouter.route(for: .unsupported), .unsupported)
    }
}
