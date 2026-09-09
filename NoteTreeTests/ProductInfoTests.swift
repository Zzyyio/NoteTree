import XCTest
@testable import NoteTree

final class ProductInfoTests: XCTestCase {
    func testDefaultProductInfoMatchesPhaseZeroConfiguration() {
        XCTAssertEqual(ProductInfo.noteTree.name, "NoteTree")
        XCTAssertEqual(ProductInfo.noteTree.minimumSystemVersion, "macOS 14")
    }
}

