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
/// **These have never run.** There is no Apple toolchain in the container most
/// of this app was written in, so they are written against the code and not
/// against a running app. Expect to fix them on the first real pass; what they
/// are for is to fail usefully rather than to pass.
///
/// They were smoke tests only for a long time, with a comment saying the views
/// were not written yet and that asserting on a screen that does not exist
/// would be a test of nothing. All five tabs are real now, so the real ones go
/// here — and deliberately only the ones that would catch something big:
///
/// - every tab opening, which renders all five root screens and is the cheapest
///   possible check on 26,000 lines of view code that has never been compiled;
/// - the bundled recipes reaching the library, which is the only automated proof
///   that `Resources/Recipes` survived into the app bundle at all;
/// - one recipe opening, which exercises the tweak overlay's resolution path.
///
/// Nothing here asserts on wording, a count, or a warning banner. All three move
/// as he adds recipes, and a UI test that fails spuriously is worse than no UI
/// test: it teaches you to ignore the suite.
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

    // MARK: - The store opens

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

    // MARK: - Every screen renders

    /// Taps all five tabs, which is the highest-value test in this file.
    ///
    /// A SwiftUI view that cannot build its body traps at RENDER time, not at
    /// launch, so the app can start perfectly and then die the moment a tab is
    /// selected. Tapping each one renders `TodayView`, `RecipeListView`,
    /// `PlanWeekView`, `ShopView` and `PantryView` and everything their bodies
    /// construct, against a store holding only what `KitchenAidSeed` wrote.
    ///
    /// The identifiers come from `AppTab.identifier`, so this stays correct if a
    /// tab is re-titled and fails loudly if one is renamed or removed.
    func testEveryTabOpens() {
        let app = launchClean()
        for identifier in ["tab.today", "tab.recipes", "tab.plan", "tab.shop", "tab.pantry"] {
            let tab = app.tabBars.buttons.matching(identifier: identifier).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "no tab \(identifier)")
            tab.tap()
            XCTAssertEqual(app.state, .runningForeground, "the app died on \(identifier)")
        }
    }

    /// Each tab's own title, so a tab that renders SOMETHING is not mistaken for
    /// a tab that rendered the right thing.
    ///
    /// `.plan` is checked and `.today` is not: Today's navigation title is also
    /// "Today", but it is the tab the app opens on, so a passing assertion there
    /// would prove nothing about tapping.
    func testEachTabShowsItsOwnScreen() {
        let app = launchClean()
        let expected = [
            "tab.recipes": "Recipes",
            "tab.plan": "Plan",
            "tab.shop": "Shop",
            "tab.pantry": "Pantry",
        ]
        for (identifier, title) in expected {
            let tab = app.tabBars.buttons.matching(identifier: identifier).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "no tab \(identifier)")
            tab.tap()
            XCTAssertTrue(
                app.navigationBars[title].waitForExistence(timeout: 5),
                "\(identifier) did not show the \(title) screen"
            )
        }
    }

    /// Queried across ANY element type rather than as `app.buttons[...]`.
    ///
    /// A `NavigationLink` inside a `List` surfaces as a button, a cell, or a
    /// button nested in a cell depending on the iOS version and the list style,
    /// and picking one of those is how a UI test starts failing on an OS update
    /// for no reason that involves the app.
    private func recipeRow(_ recipeID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "recipe.row.\(recipeID)")
            .firstMatch
    }

    // MARK: - The bundled content shipped

    /// The one automated proof that the recipe files reached the app bundle.
    ///
    /// `Resources/Recipes` is a FOLDER REFERENCE in a generated project file, so
    /// `Bundle.main.urls(..., subdirectory: "Recipes")` resolving at all depends
    /// on the directory surviving the build — and `make_xcodeproj.py` cannot
    /// verify that from Linux. If the folder is copied wrongly the app launches
    /// fine, every screen renders, and the library is simply empty.
    ///
    /// Keyed on the recipe's content id and not its title, so re-wording the
    /// document does not break the test.
    func testBundledRecipesReachTheLibrary() {
        let app = launchClean()
        app.tabBars.buttons.matching(identifier: "tab.recipes").firstMatch.tap()
        let row = recipeRow("roast-turkey", in: app)
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "the bundled recipes did not reach the library — check that "
                + "Resources/Recipes is still a folder reference in the project"
        )
    }

    /// Opening one exercises `TweakStore.effectiveRecipe(id:)`, which is how
    /// every screen but the library reads a recipe, and the navigation title is
    /// the resolved recipe's own.
    func testOpeningARecipeShowsIt() {
        let app = launchClean()
        app.tabBars.buttons.matching(identifier: "tab.recipes").firstMatch.tap()
        let row = recipeRow("roast-turkey", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(
            app.navigationBars["Roast Turkey"].waitForExistence(timeout: 5),
            "the recipe detail screen did not appear"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }
}
