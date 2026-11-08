import XCTest
@testable import KitchenAid

/// `MealScaling.scaling(for:recipe:defaultDinerCount:)` — the one place a dish's scale is
/// derived, and now the one place TWO derivations live.
///
/// This is the arithmetic where being wrong is SILENT. A scale off by a factor does not
/// crash: it produces a plausible shopping list, he buys half the butter, and the first
/// sign of it is dinner. So every assertion below is on an exact `Rational` and names the
/// value that would make it fail.
///
/// **What is deliberately NOT here.** `QuantityMathTests` already owns the weight path's
/// headline cases — 18 lb against a 14 lb basis is exactly 9/7, 14 lb is exactly 1, no
/// weight chosen is 1 with `.unknownYield`, a manual override beats the chart, the
/// `isWeightDriven` truth table, and the chart's own accessors. Repeating them here would be
/// a third copy of an assertion that already exists, so where this file touches those
/// numbers it does so under a configuration that would CHANGE them if the code were wrong
/// (batch granularity on the weight path, attendance present on a weight-driven dish).
///
/// **No `ModelContainer`.** `PlannedMeal`, `MealAttendance` and `MealRecipe` are built in
/// memory and only their properties are read, which is the ordinary SwiftData pattern and
/// the reason this file can exist at all on a machine with no simulator. Nothing here
/// FETCHES, and a fetch is the one thing that would need a context — so if either of these
/// two new files fails to RUN rather than failing an assertion, that is where to look.
final class MealScalingTests: XCTestCase {

    // MARK: - Stand-ins
    //
    // Mirrors of shipped content, named where they mirror it. A stand-in that disagrees with
    // the shipped data is how `testVolumeAndMassCollapseWhenADensityExists` went green while
    // asserting the opposite of what `sum` does (code review 01 item 9).

    /// The fixture's own yield: "Makes: 12 crostini (serves 4)", so `servings` is 4 and the
    /// document claims it. `batchGranularity` is absent from every shipped file, which
    /// decodes as `.continuous`.
    private func crostini(granularity: BatchGranularity = .continuous) -> Recipe {
        var recipe = Recipe(id: "ny-strip-crostini", title: "NY Strip Crostini")
        recipe.servingsNumerator = 4
        recipe.servingsDenominator = 1
        recipe.batchGranularity = granularity
        return recipe
    }

    /// The first three rows of `roast-turkey.json`'s "Cooking Times", verbatim. The full
    /// eight are transcribed in `QuantityMathTests`; three is enough for `weightTable` to
    /// match (a "weight" first header plus at least one row whose first cell parses) and
    /// keeps what this file asserts about the 10, 14 and 18 lb birds readable.
    private func turkeyChart() -> RecipeTable {
        RecipeTable(
            name: "Cooking Times",
            headers: ["Turkey weight", "Total time",
                      "Covered (first 2/3)", "Uncovered (last 1/3)"],
            rows: [
                ["10 lb", "2 hr 10 min", "1 hr 27 min", "43 min"],
                ["14 lb", "3 hr 02 min", "2 hr 01 min", "1 hr 01 min"],
                ["18 lb", "3 hr 54 min", "2 hr 36 min", "1 hr 18 min"]
            ]
        )
    }

    /// The bundled turkey: `"servings": null` so `servingsStated` is false and the decoder's
    /// substituted 4 sits in `servings`, plus the 14 lb basis from
    /// `docs/recipe-overrides.json`. The 4 is precisely the number nothing on this path may
    /// divide by.
    ///
    /// `granularity` defaults to `.continuous`, which is what the shipped file decodes as.
    /// Where a test below sets `.wholeBatches` it is DEVIATING from shipped data on purpose,
    /// and says so: asserting "snapping did not run" against a recipe that has no
    /// granularity asserts nothing at all.
    private func turkey(granularity: BatchGranularity = .continuous) -> Recipe {
        var recipe = Recipe(id: "roast-turkey", title: "Roast Turkey")
        recipe.basisWeightPounds = Rational(14)
        recipe.tables = [turkeyChart()]
        recipe.servingsNumerator = 4
        recipe.servingsDenominator = 1
        recipe.servingsStated = false
        recipe.batchGranularity = granularity
        return recipe
    }

    /// "Mostly just me plus 1 adult" plus a half portion — `CLAUDE.md`'s household, as rows
    /// on the attendance EDGE, which is what makes a half portion arithmetic rather than a
    /// special case.
    ///
    /// `portions` are the snapshot portions, one row each. `guestCount` and `guestPortion`
    /// are the party stepper: counted, never named.
    ///
    /// There is no `status` or `kind` here, because `MealScaling` reads neither — a meal that
    /// contributes nothing to shopping is `ShoppingListBuilder`'s filter and is asserted in
    /// `ShoppingListBuilderTests`. A parameter this file could not make fail is a hook with
    /// no caller.
    private func meal(
        portions: [Rational],
        away: Int = 0,
        guestCount: Int = 0,
        guestPortion: Rational = .one
    ) -> PlannedMeal {
        let planned = PlannedMeal()
        var rows: [MealAttendance] = []
        for (index, portion) in portions.enumerated() {
            let row = MealAttendance(
                portionSnapshotNumerator: portion.numerator,
                portionSnapshotDenominator: portion.denominator,
                eaterNameSnapshot: "Eater \(index + 1)"
            )
            row.meal = planned
            rows.append(row)
        }
        // `.away` rows exist and consume nothing. A roster of nobody-is-coming is a
        // different state from an empty roster and has to reach the same fallback.
        for index in 0..<away {
            let row = MealAttendance(
                statusRaw: AttendanceStatus.away.rawValue,
                eaterNameSnapshot: "Away \(index + 1)"
            )
            row.meal = planned
            rows.append(row)
        }
        planned.attendance = rows
        if guestCount > 0 { planned.setGuests(count: guestCount, portion: guestPortion) }
        return planned
    }

    /// One dish of that meal.
    ///
    /// Only the CHILD side is wired: `requestedPortions` reads `meal?.portionTotal`, and
    /// nothing in this file reads `PlannedMeal.mealRecipes`. Appending to the parent's array
    /// here as well would risk listing the dish twice, since setting one side of a SwiftData
    /// relationship may populate the other — which is why `meal(portions:)` above assigns
    /// `attendance` as a whole array rather than appending to it.
    private func dish(
        in planned: PlannedMeal?,
        recipeID: String = "ny-strip-crostini",
        title: String = "NY Strip Crostini",
        weight: Rational? = nil,
        override: Rational? = nil,
        leftovers: Int? = nil
    ) -> MealRecipe {
        let made = MealRecipe(recipeID: recipeID, recipeTitleSnapshot: title)
        made.setChosenWeightPounds(weight)
        made.setScaleOverride(override)
        made.plannedLeftoverServings = leftovers
        made.meal = planned
        return made
    }

    // MARK: - Portions over servings

    /// Portions are summed on the EDGE and the result is an exact fraction.
    ///
    /// Two full portions and one half is 5/2 portions; against a recipe serving 4 that is
    /// exactly 5/8. The project's prose quotes 9/8 for this household, and that figure
    /// includes two guests — see the next test. 5/2 over 4 is 5/8 and nothing else, and the
    /// value that would make this fail is 0.625 arriving as a `Double` and coming back as
    /// 5/8 only by luck, or a head count of 3 producing 3/4.
    func testTwoFullPortionsAndOneHalfScaleToAnExactFraction() {
        let result = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one, Rational(1, 2)])),
            recipe: crostini(),
            defaultDinerCount: 2
        )
        XCTAssertEqual(result.portions, Rational(5, 2))
        XCTAssertEqual(result.scale, Rational(5, 8))
        XCTAssertEqual(result.scale.numerator, 5)
        XCTAssertEqual(result.scale.denominator, 8)
        // And it carries through a quantity exactly: the fixture's 1/4 tsp of kosher salt at
        // 5/8 is 5/32 tsp, which no `Double` round trip gives back.
        XCTAssertEqual(Rational(1, 4) * result.scale, Rational(5, 32))
        XCTAssertTrue(result.notes.isEmpty, "a fully assigned meal needs no badge: \(result.notes)")
        XCTAssertTrue(result.description.contains("recipe serves 4"), result.description)
    }

    /// Guests MULTIPLY: one stepper, not eight rows.
    ///
    /// The same household plus two full-portion guests is 9/2 portions and ×9/8 — the figure
    /// `PlannedMeal`'s own comment quotes. Then four half-portion guests reach the identical
    /// scale from a different stepper, which is the whole claim behind "a table of eight
    /// adults and a table of eight including four children differ by one stepper": if
    /// `guestPortions` summed rows or ignored `guestPortion`, the second number would be 13/8.
    func testAGuestCountMultipliesRatherThanAddingRows() {
        let household: [Rational] = [.one, .one, Rational(1, 2)]

        let full = MealScaling.scaling(
            for: dish(in: meal(portions: household, guestCount: 2)),
            recipe: crostini(),
            defaultDinerCount: 2
        )
        XCTAssertEqual(full.portions, Rational(9, 2))
        XCTAssertEqual(full.scale, Rational(9, 8))

        let halves = MealScaling.scaling(
            for: dish(in: meal(portions: household, guestCount: 4, guestPortion: Rational(1, 2))),
            recipe: crostini(),
            defaultDinerCount: 2
        )
        XCTAssertEqual(halves.portions, Rational(9, 2), "four half portions are two portions")
        XCTAssertEqual(halves.scale, Rational(9, 8))
        XCTAssertNotEqual(halves.scale, Rational(13, 8),
                          "this is four guests counted at a full portion each")
    }

    /// Nobody assigned must neither silently buy nothing nor silently buy for four.
    ///
    /// Three facts, and the first is the one that matters most: the scale is NOT zero. A
    /// zero scale is the silent failure this whole file exists for — every quantity on the
    /// list becomes nothing and the shopping trip looks like it succeeded.
    ///
    /// The `.away`-only roster is the case `QuantityMathTests` does not reach: it builds the
    /// dish with no meal at all, so `requestedPortions` is zero because there is nothing to
    /// ask. Here the rows exist and consume nothing, which is `consumesPortion` doing its
    /// job rather than an absent relationship.
    func testZeroPortionsFallsBackToTheDefaultAndRaisesTheNote() {
        let result = MealScaling.scaling(
            for: dish(in: meal(portions: [], away: 2)),
            recipe: crostini(),
            defaultDinerCount: 3
        )
        XCTAssertNotEqual(result.scale, .zero, "a meal with nobody assigned must not buy nothing")
        XCTAssertEqual(result.portions, Rational(3), "the per-device default, reported")
        XCTAssertEqual(result.scale, Rational(3, 4))
        XCTAssertTrue(result.notes.contains(.noAttendance),
                      "the fallback has to be visible, not assumed")

        // And the clamp. A `defaultDinerCount` of 0 — which a preference stepper can reach —
        // is substituted with 1, not used: `Rational(max(1, defaultDinerCount))`. Without it
        // the scale is zero and the list is empty with nothing saying why.
        let clamped = MealScaling.scaling(
            for: dish(in: meal(portions: [], away: 1)),
            recipe: crostini(),
            defaultDinerCount: 0
        )
        XCTAssertEqual(clamped.portions, .one)
        XCTAssertEqual(clamped.scale, Rational(1, 4))
    }

    // MARK: - Batch snapping

    /// You cannot bake 1.4 loaves, and snapping is UP: half a batch too much is dinner, half
    /// a batch too little is a second trip.
    ///
    /// 9/2 portions over 4 servings is 9/8. Whole batches takes that to 2, half batches to
    /// 3/2, and `.continuous` leaves it alone with no note. All three are asserted because
    /// the interesting failure is not "snapping is broken" but "snapping fires where it
    /// should not" — which `.continuous` is the control for.
    func testBatchSnappingSnapsUpAndRaisesItsNote() {
        let household: [Rational] = [.one, .one, Rational(1, 2)]

        let whole = MealScaling.scaling(
            for: dish(in: meal(portions: household, guestCount: 2)),
            recipe: crostini(granularity: .wholeBatches),
            defaultDinerCount: 2
        )
        XCTAssertEqual(whole.scale, Rational(2), "9/8 of a whole-batch recipe is two batches")
        XCTAssertTrue(whole.notes.contains(.snappedToBatch))

        let half = MealScaling.scaling(
            for: dish(in: meal(portions: household, guestCount: 2)),
            recipe: crostini(granularity: .halfBatches),
            defaultDinerCount: 2
        )
        XCTAssertEqual(half.scale, Rational(3, 2))
        XCTAssertTrue(half.notes.contains(.snappedToBatch))

        let continuous = MealScaling.scaling(
            for: dish(in: meal(portions: household, guestCount: 2)),
            recipe: crostini(),
            defaultDinerCount: 2
        )
        XCTAssertEqual(continuous.scale, Rational(9, 8))
        XCTAssertFalse(continuous.notes.contains(.snappedToBatch),
                       "nothing snapped, so nothing may claim it did")
    }

    /// A scale that lands exactly on a batch boundary must not be badged.
    ///
    /// Four full portions over a recipe serving 4 is exactly 1, and `ceiling(toMultipleOf:)`
    /// returns it unchanged — so `snap` appends nothing. A `.snappedToBatch` badge on a
    /// quantity nothing moved teaches him to ignore badges, which is the same failure as a
    /// bridge warning on an item whose density ships in the catalogue.
    func testAnExactBatchIsNotBadged() {
        let result = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one, .one, .one])),
            recipe: crostini(granularity: .wholeBatches),
            defaultDinerCount: 2
        )
        XCTAssertEqual(result.scale, .one)
        XCTAssertTrue(result.notes.isEmpty, "nothing happened here: \(result.notes)")
    }

    // MARK: - `.fixed` lines opt out of the scale entirely

    /// The scale `MealScaling` derives is applied PER LINE by `RecipeGraph.flatten`, and a
    /// `.fixed` line opts out. Asserted end to end, because the two halves are what produce
    /// the number on the list: a 3× batch of this recipe wants 3 tbsp of butter and still
    /// one bay leaf, not three bay leaves and a fistful of salt.
    ///
    /// The ×3 arrives as an override, which is also how the doc comment on `ScalingRule`
    /// words the case.
    func testFixedLinesDoNotScaleWithTheRestOfTheDish() {
        var butter = IngredientLine(lineID: "butter-1", displayName: "butter")
        butter.amount = .one
        butter.unitCode = "tbsp"
        butter.dimension = .volume

        var bay = IngredientLine(lineID: "bay-leaf-1", displayName: "bay leaf")
        bay.amount = .one
        bay.unitCode = "leaf"
        bay.dimension = .count
        bay.scalingRule = .fixed

        var recipe = crostini()
        recipe.components = [RecipeComponent(title: "Braise", lines: [butter, bay])]

        let scaling = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one]), override: Rational(3)),
            recipe: recipe,
            defaultDinerCount: 2
        )
        XCTAssertEqual(scaling.scale, Rational(3), "the override, unsnapped on a continuous recipe")

        var diagnostics: [RecipeGraph.Diagnostic] = []
        let flats = RecipeGraph.flatten(
            recipe: ResolvedRecipe(recipe: recipe),
            scale: scaling.scale,
            options: options(),
            provenance: RecipeGraph.Provenance(),
            componentPath: [],
            resolve: { _ in nil },
            visited: [],
            depth: 0,
            diagnostics: &diagnostics
        )
        XCTAssertEqual(flats.count, 2)
        let scaled = flats.first { $0.lineID == "butter-1" }
        let unscaled = flats.first { $0.lineID == "bay-leaf-1" }
        XCTAssertEqual(scaled?.quantity?.amount, Rational(3), "1 tbsp at 3x is 3 tbsp")
        XCTAssertEqual(unscaled?.quantity?.amount, Rational.one)
        XCTAssertNotEqual(unscaled?.quantity?.amount, Rational(3), "three bay leaves")
        XCTAssertTrue(diagnostics.isEmpty)
    }

    // MARK: - The weight path, under conditions that would move it if it were wrong

    /// Attendance does not enter a weight-driven dish EVEN WHEN IT IS SET.
    ///
    /// `QuantityMathTests` covers the 18 lb bird with no meal attached, where
    /// `requestedPortions` is zero and the fallback fires. This is the state a real
    /// Thanksgiving is in: nine portions assigned, a bird chosen, and the scale still the
    /// bird over the basis. If attendance leaked in, this would be 9/8 — plausible, close to
    /// 9/7, and wrong.
    func testAWeightDrivenDishIgnoresAttendanceEvenWhenItIsSet() {
        let thanksgiving = meal(portions: [.one, .one, Rational(1, 2)], guestCount: 2)
        let result = MealScaling.scaling(
            for: dish(in: thanksgiving, recipeID: "roast-turkey",
                      title: "Roast Turkey", weight: Rational(18)),
            recipe: turkey(),
            defaultDinerCount: 2
        )
        XCTAssertEqual(result.scale, Rational(9, 7))
        XCTAssertNotEqual(result.scale, Rational(9, 8), "this is the attendance derivation")
        // Portions are still REPORTED — the screens show who is eating — they just do not
        // divide.
        XCTAssertEqual(result.portions, Rational(9, 2))
        XCTAssertTrue(result.notes.isEmpty, "nothing was assumed here: \(result.notes)")
        XCTAssertTrue(result.description.contains("18 lb"), result.description)
        XCTAssertFalse(result.description.contains("eater"), result.description)
    }

    /// **Batch snapping does not run on the weight path.** Asserted, not assumed.
    ///
    /// This is the difference between an 18 lb bird and a doubled recipe. Granularity
    /// answers "you cannot bake 1.4 loaves"; a weight ratio answers "you bought a bigger
    /// bird", and they are not the same question — so snapping 9/7 to whole batches would
    /// double every quantity on the list.
    ///
    /// The shipped `roast-turkey.json` states no `batchGranularity`, so it decodes as
    /// `.continuous` and the snap could not fire on it either way. Setting it here is a
    /// deliberate deviation from shipped data, and it is the only way this assertion is not
    /// vacuous: under `.wholeBatches` a snap turns 9/7 into 2 and 5/7 into 1, and under
    /// `.halfBatches` into 3/2 and 1 — every one of them a value this test would catch.
    func testBatchSnappingDoesNotRunOnTheWeightPath() {
        for granularity in [BatchGranularity.wholeBatches, .halfBatches] {
            let bigger = MealScaling.scaling(
                for: dish(in: nil, recipeID: "roast-turkey",
                          title: "Roast Turkey", weight: Rational(18)),
                recipe: turkey(granularity: granularity),
                defaultDinerCount: 2
            )
            XCTAssertEqual(bigger.scale, Rational(9, 7), "snapped under \(granularity.rawValue)")
            XCTAssertFalse(bigger.notes.contains(.snappedToBatch), granularity.rawValue)

            // And DOWNWARD, which is where snapping up would cost the most: a 10 lb bird is
            // 5/7 of the document, and snapping it to a whole batch buys 40% too much of
            // everything in the roasting pan.
            let smaller = MealScaling.scaling(
                for: dish(in: nil, recipeID: "roast-turkey",
                          title: "Roast Turkey", weight: Rational(10)),
                recipe: turkey(granularity: granularity),
                defaultDinerCount: 2
            )
            XCTAssertEqual(smaller.scale, Rational(5, 7), "snapped under \(granularity.rawValue)")
            XCTAssertNotEqual(smaller.scale, .one)
            XCTAssertFalse(smaller.notes.contains(.snappedToBatch), granularity.rawValue)
        }
    }

    /// Half-enabling the weight feature falls back to portions rather than to a derivation
    /// that cannot work.
    ///
    /// `QuantityMathTests` asserts the `isWeightDriven` truth table itself. What is asserted
    /// here is the consequence inside `scaling`: with a basis and no chart — or a chart and
    /// no basis — the dish takes the SERVING-COUNT branch, and a weight stored on it is kept
    /// and ignored. The guard is `weightDriven, let basis = …`, so a basis present with no
    /// chart is exactly the configuration where a missed `weightDriven` test would still
    /// divide 18 by 14.
    func testAHalfEnabledWeightRecipeTakesThePortionPath() {
        // `servingsStated` is forced true on both halves below, which the shipped turkey is
        // not. It isolates what is under test: with the real `false` every assertion here
        // would also carry `.unknownYield`, and that case has its own test at the end of this
        // file, against the recipe that genuinely has it.
        var basisOnly = turkey()
        basisOnly.tables = []
        basisOnly.servingsStated = true
        XCTAssertFalse(basisOnly.isWeightDriven)

        let fromBasis = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one, Rational(1, 2)], guestCount: 2),
                      recipeID: "roast-turkey", title: "Roast Turkey", weight: Rational(18)),
            recipe: basisOnly,
            defaultDinerCount: 2
        )
        XCTAssertEqual(fromBasis.scale, Rational(9, 8), "9/2 portions over the 4 it states")
        XCTAssertNotEqual(fromBasis.scale, Rational(9, 7), "this is the weight derivation")

        var chartOnly = turkey()
        chartOnly.basisWeightPounds = nil
        chartOnly.servingsStated = true
        XCTAssertFalse(chartOnly.isWeightDriven)

        let fromChart = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one, Rational(1, 2)], guestCount: 2),
                      recipeID: "roast-turkey", title: "Roast Turkey", weight: Rational(18)),
            recipe: chartOnly,
            defaultDinerCount: 2
        )
        XCTAssertEqual(fromChart.scale, Rational(9, 8))
    }

    // MARK: - An override beats both derivations

    /// "Actually ×2" beats the portion arithmetic, and is STILL snapped.
    ///
    /// `QuantityMathTests` covers an override beating the weight chart. The two things new
    /// here are that it beats the attendance derivation — 9/2 portions over 4 would be 9/8,
    /// and the override's 5/4 wins — and that `snap` runs ON the override, so a whole-batch
    /// recipe takes 5/4 to 2 and earns BOTH badges. That second half is easy to get wrong in
    /// the obvious direction: returning the override untouched looks like respecting him and
    /// produces 1 1/4 batches of something that cannot be made in quarters.
    func testAnOverrideBeatsThePortionDerivationAndIsStillSnapped() {
        let household = meal(portions: [.one, .one, Rational(1, 2)], guestCount: 2)

        let snapped = MealScaling.scaling(
            for: dish(in: household, override: Rational(5, 4)),
            recipe: crostini(granularity: .wholeBatches),
            defaultDinerCount: 2
        )
        XCTAssertEqual(snapped.scale, Rational(2))
        XCTAssertNotEqual(snapped.scale, Rational(9, 8), "the attendance derivation won")
        XCTAssertTrue(snapped.notes.contains(.overridden))
        XCTAssertTrue(snapped.notes.contains(.snappedToBatch))
        XCTAssertEqual(snapped.portions, Rational(9, 2), "portions are still reported")

        let exact = MealScaling.scaling(
            for: dish(in: household, override: Rational(5, 4)),
            recipe: crostini(),
            defaultDinerCount: 2
        )
        XCTAssertEqual(exact.scale, Rational(5, 4))
        XCTAssertFalse(exact.notes.contains(.snappedToBatch))
    }

    /// A dangling `recipeID` — the one reference no delete rule can protect, because the
    /// thing on the other end is a file and not a row.
    ///
    /// Scale 1 and a badge, rather than quietly shopping for less. And with an override in
    /// place the override wins and `.unknownYield` is NOT raised: the override path returns
    /// before the nil-recipe guard, which is correct — he gave a number, so nothing about
    /// the yield is unknown any more — and asserting it pins a return order that reads as
    /// incidental.
    func testAMissingRecipeScalesToOneAndSaysSo() {
        let orphan = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one]), recipeID: "deleted-recipe"),
            recipe: nil,
            defaultDinerCount: 2
        )
        XCTAssertEqual(orphan.scale, .one)
        XCTAssertTrue(orphan.notes.contains(.unknownYield))
        XCTAssertFalse(orphan.notes.contains(.noAttendance), "two portions were assigned")

        let overridden = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one]),
                      recipeID: "deleted-recipe", override: Rational(2)),
            recipe: nil,
            defaultDinerCount: 2
        )
        XCTAssertEqual(overridden.scale, Rational(2))
        XCTAssertTrue(overridden.notes.contains(.overridden))
        XCTAssertFalse(overridden.notes.contains(.unknownYield))
    }

    // MARK: - Leftovers, and the serving count nobody stated

    /// The extra he is deliberately cooking for Thursday is inside `requestedPortions`, and
    /// the badge is what stops the larger number reading as a bug.
    ///
    /// `MealRecipe`'s own worked example: 4 portions plus 2 for Thursday, against a recipe
    /// serving 4, is ×3/2 with `.leftoversIncluded`.
    ///
    /// The second half is the `!weightDriven` guard. Cooking extra of a whole roast bird is
    /// not a thing — you buy a bigger bird — so a leftovers figure stored on a weight-driven
    /// dish must not produce a badge explaining a number it had no part in.
    func testLeftoverServingsAreCountedAndBadgedExceptOnTheWeightPath() {
        let result = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one, .one, .one]), leftovers: 2),
            recipe: crostini(),
            defaultDinerCount: 2
        )
        XCTAssertEqual(result.portions, Rational(6))
        XCTAssertEqual(result.scale, Rational(3, 2))
        XCTAssertTrue(result.notes.contains(.leftoversIncluded))

        let bird = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one, .one, .one]),
                      recipeID: "roast-turkey", title: "Roast Turkey",
                      weight: Rational(18), leftovers: 2),
            recipe: turkey(),
            defaultDinerCount: 2
        )
        XCTAssertEqual(bird.scale, Rational(9, 7))
        XCTAssertFalse(bird.notes.contains(.leftoversIncluded),
                       "a bigger bird is the leftovers plan")
    }

    /// An ordinary recipe that states NO serving count still divides by the substituted 4 —
    /// it has to, the planner needs a divisor — and says that it did.
    ///
    /// This is `turkey-gravy.json`, not the turkey: `"servings": null`, no
    /// `basisWeightPounds`, no tables, so it is not weight-driven and there is no weight
    /// branch to rescue it. Code review 01 item 4 is exactly this line going out silently.
    /// The badge and the sentence are the fix, and the sentence is what he reads in the aisle
    /// when a quantity looks wrong.
    func testAnUnstatedServingCountIsBadgedOnAnOrdinaryRecipe() {
        var gravy = Recipe(id: "turkey-gravy", title: "Turkey Gravy")
        gravy.servingsNumerator = 4
        gravy.servingsDenominator = 1
        gravy.servingsStated = false
        XCTAssertFalse(gravy.isWeightDriven)

        let result = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one]),
                      recipeID: "turkey-gravy", title: "Turkey Gravy"),
            recipe: gravy,
            defaultDinerCount: 2
        )
        XCTAssertEqual(result.scale, Rational(1, 2), "2 portions over the substituted 4")
        XCTAssertTrue(result.notes.contains(.unknownYield))
        XCTAssertTrue(result.description.contains("gives no serving count"), result.description)
        XCTAssertFalse(result.description.contains("recipe serves"), result.description)

        // And a recipe that DOES state its count says the opposite, so the two sentences
        // cannot both be printed by a condition that is always true.
        let stated = MealScaling.scaling(
            for: dish(in: meal(portions: [.one, .one])),
            recipe: crostini(),
            defaultDinerCount: 2
        )
        XCTAssertFalse(stated.notes.contains(.unknownYield))
        XCTAssertTrue(stated.description.contains("recipe serves 4"), stated.description)
    }

    // MARK: - Options

    /// `RecipeGraph.flatten` takes the builder's `Options`, whose `range` has no default.
    /// Nothing in this file reads a date; the range is here because the type requires one.
    private func options() -> ShoppingListBuilder.Options {
        ShoppingListBuilder.Options(
            range: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86_400)
        )
    }
}
