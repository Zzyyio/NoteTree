import XCTest

final class NoteTreeLaunchTests: XCTestCase {
    @MainActor
    func testWelcomeScreenAppearsAtLaunch() {
        let application = XCUIApplication()
        application.launchEnvironment["NOTE_TREE_UI_TESTING"] = "1"
        application.launch()

        let welcomeScreen = application.descendants(matching: .any)["welcome.screen"]
        XCTAssertTrue(welcomeScreen.waitForExistence(timeout: 5))
    }
}
