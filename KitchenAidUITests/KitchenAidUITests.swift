import XCTest

/// UI tests run against a clean store.
///
/// `UITestMode` in the app keeps its SwiftData store in memory and reads
/// preferences from a throwaway suite under the `-uitesting` launch argument,
/// so a test never inherits a previous run's data and never touches the real
/// device's. That pattern is lifted from Brandon's CFAL3 project, where a
/// `@AppStorage` that was missed caused one test to open on the tab a previous
/// test had left selected.
///
/// There is only a smoke test here for now: the views are not written yet, and
/// a UI test asserting on a screen that does not exist would be a test of
/// nothing. It exists so the target compiles and so the next session has
/// somewhere obvious to put the real ones.
final class KitchenAidUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchClean() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
        return app
    }

    /// The app launches and stays up. Worth having on its own: a SwiftData
    /// schema with a bad relationship fails when the container opens, which is
    /// at launch, so this catches the whole class of "every model is wrong"
    /// before any screen is involved.
    func testLaunchesAndStaysRunning() {
        let app = launchClean()
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Relaunching must not crash, which is the cheapest check that the store
    /// opened and closed cleanly rather than leaving a half-migrated file.
    func testRelaunchIsClean() {
        let app = launchClean()
        XCTAssertEqual(app.state, .runningForeground)
        app.terminate()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }
}
