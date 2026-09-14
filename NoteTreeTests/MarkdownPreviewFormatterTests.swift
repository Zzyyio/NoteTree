import XCTest
@testable import NoteTree

final class MarkdownPreviewFormatterTests: XCTestCase {
    func testSingleProseNewlineBecomesHardBreakWithoutChangingParagraphs() {
        XCTAssertEqual(
            MarkdownPreviewFormatter.renderingSource(for: "first line\nsecond line\n\nthird paragraph"),
            "first line  \nsecond line\n\nthird paragraph"
        )
    }

    func testFencedCodeBlockKeepsItsOriginalNewlines() {
        XCTAssertEqual(
            MarkdownPreviewFormatter.renderingSource(for: "before\n```swift\nlet value = 1\nprint(value)\n```\nafter"),
            "before  \n```swift\nlet value = 1\nprint(value)\n```\nafter"
        )
    }

    func testNormalizesLegacyLineEndingsOnlyForPreviewInput() {
        XCTAssertEqual(
            MarkdownPreviewFormatter.renderingSource(for: "one\r\ntwo\rthree"),
            "one  \ntwo  \nthree"
        )
    }
}
