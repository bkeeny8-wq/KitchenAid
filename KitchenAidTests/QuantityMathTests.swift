import XCTest
@testable import KitchenAid

/// The shopping list's arithmetic, tested against the real recipes.
///
/// Three rounds of review found more defects in this area than everywhere else
/// combined, and every assertion below is one of those findings turned into
/// something that fails rather than something written down. The shopping
/// builder is being written against these same functions, so if it gets a
/// precedence wrong the test catches it on Brandon's Mac rather than in a
/// supermarket.
final class QuantityMathTests: XCTestCase {

    // MARK: - Stand-ins for a FoodItem

    /// `QuantityMath` takes `(any DensityCarrying)?` rather than a `FoodItem`
    /// precisely so these tests need no `ModelContainer`. That decision is what
    /// makes this file possible.
    private struct Item: DensityCarrying {
        var gramsPerCup: Rational?
        var preferredDimension: MeasureDimension
    }

    /// The shipped catalogue's butter: 227 g per cup, measured in volume.
    private let butter = Item(gramsPerCup: Rational(227), preferredDimension: .volume)
    /// The shipped catalogue's all-purpose flour: 120 g per cup, volume.
    private let flour = Item(gramsPerCup: Rational(120), preferredDimension: .volume)
    /// Kosher salt is deliberately absent from the density table, because
    /// Diamond Crystal is ~142 g/cup and Morton ~288 — a factor of two from the
    /// same words on the box.
    private let salt = Item(gramsPerCup: nil, preferredDimension: .volume)

    private func q(_ amount: Rational, _ unit: KitchenUnit) -> QuantityMath.Contribution {
        QuantityMath.Contribution(quantity: Quantity(amount: amount, unit: unit))
    }

    private func subtotal(_ base: Rational, _ unit: KitchenUnit) -> QuantitySubtotal {
        QuantitySubtotal(dimensionKey: unit.dimensionKey, base: base, preferredUnit: unit)
    }

    // MARK: - A recipe aggregates against itself

    /// The fixture's headline case. Butter appears as 1 tbsp in "Crostini and
    /// steak" and 1 tbsp in "Creamed horseradish spinach", so ONE planned meal
    /// of ONE recipe must already merge them. An implementation that only
    /// de-duplicates across recipes fails here.
    func testButterMergesWithinOneRecipe() {
        let out = QuantityMath.sum(
            [q(.one, UnitCatalog.tablespoon), q(.one, UnitCatalog.tablespoon)],
            using: butter
        )
        XCTAssertEqual(out.count, 1, "two tablespoons of butter became \(out.count) lines")
        XCTAssertEqual(out[0].base, Rational(2) * UnitCatalog.tablespoon.baseFactor)
        XCTAssertEqual(out[0].quantity?.displayString(), "2 tbsp")
    }

    /// The other self-aggregation in the same recipe: 1 tsp in the steak group
    /// and 1/4 tsp in the spinach. Exactly 1 1/4 tsp, not 1.25.
    func testKosherSaltMergesToAnExactFraction() {
        let out = QuantityMath.sum(
            [q(.one, UnitCatalog.teaspoon), q(Rational(1, 4), UnitCatalog.teaspoon)],
            using: salt
        )
        XCTAssertEqual(out.count, 1)
        let amount = out[0].base / UnitCatalog.teaspoon.baseFactor
        XCTAssertEqual(amount, Rational(5, 4))
        XCTAssertEqual(amount.exactDescription, "1 1/4")
    }

    /// Different dimensions stay apart when nothing can bridge them. Salt has
    /// no density on purpose, so a teaspoon and a gram are two buckets.
    func testUnbridgeableDimensionsStaySeparate() {
        let out = QuantityMath.sum(
            [q(.one, UnitCatalog.teaspoon), q(Rational(10), UnitCatalog.gram)],
            using: salt
        )
        XCTAssertEqual(out.count, 2, "salt has no density, so these must not merge")
    }

    /// A count never converts to anything, density or not.
    func testCountNeverMerges() {
        let clove = UnitCatalog.countUnit(noun: "clove")
        let out = QuantityMath.sum(
            [q(Rational(2), clove), q(Rational(1), UnitCatalog.tablespoon)],
            using: butter
        )
        XCTAssertEqual(out.count, 2)
    }

    // MARK: - The bridge, which was wrong in both directions

    /// With a density, volume and mass collapse onto one bucket rather than
    /// showing the cook two numbers for one ingredient.
    ///
    /// `sum` runs that collapse itself, so there is already ONE bucket by the
    /// time it returns. This asserted 2, with the message "sum keeps the
    /// buckets; collapsing is a separate pass" — a description of a `sum` that
    /// does not exist, and the test would have failed on the first run on a Mac.
    /// Two callers depend on the real one: `ShoppingListBuilder` raises
    /// `.needsBridge` from `hasVolume && hasMass` on `sum`'s OUTPUT and
    /// `ShoppingListStore` re-sums the same way, and both are only correct
    /// because the density has already merged the pair.
    func testVolumeAndMassCollapseWhenADensityExists() {
        let mixed = QuantityMath.sum(
            [q(.one, UnitCatalog.cup), q(Rational(200), UnitCatalog.gram)],
            using: flour
        )
        XCTAssertEqual(mixed.count, 1, "sum collapses on the density itself")
        // 200 g at 120 g per cup is 5/3 cup, so this is 8/3 cup in all.
        XCTAssertEqual(mixed[0].base, Rational(8, 3) * UnitCatalog.cup.baseFactor)
        XCTAssertFalse(mixed[0].conversionNote.isEmpty,
                       "a bucket merged on a density must carry the density it was merged on")

        // And `collapseAcrossDimensions` called DIRECTLY, on an array that
        // genuinely holds two buckets. Summing with salt's missing density is
        // what produces one: handing it the already-collapsed array above
        // asserted nothing, because it returns early when either dimension is
        // absent — so the old line passed without the function doing any work.
        let twoBuckets = QuantityMath.sum(
            [q(.one, UnitCatalog.cup), q(Rational(200), UnitCatalog.gram)],
            using: salt
        )
        XCTAssertEqual(twoBuckets.count, 2)
        let collapsed = QuantityMath.collapseAcrossDimensions(
            twoBuckets, using: flour, system: .us
        )
        XCTAssertEqual(collapsed.count, 1, "1 cup + 200 g of flour is one amount, not two")
    }

    /// Without a density it must refuse rather than invent one. 1 cup is right
    /// for water, off by about half for flour, and wrong SILENTLY — inside the
    /// number he is about to shop by.
    func testCollapseRefusesWithoutADensity() {
        let mixed = QuantityMath.sum(
            [q(.one, UnitCatalog.teaspoon), q(Rational(10), UnitCatalog.gram)],
            using: salt
        )
        let collapsed = QuantityMath.collapseAcrossDimensions(mixed, using: salt, system: .us)
        XCTAssertEqual(collapsed.count, 2)
    }

    /// THE case review 01 found broken. 2 tbsp of butter is wanted; the pantry
    /// holds 4 oz, which is a MASS. The catalogue ships butter's density, so
    /// this must convert, cover the requirement, and raise NO bridge warning.
    /// It was doing the opposite: buying butter he already had, and warning it
    /// could not convert.
    func testButterStockInMassCoversAVolumeRequirement() {
        let requested = QuantityMath.sum([q(Rational(2), UnitCatalog.tablespoon)], using: butter)
        let have = [subtotal(Rational(4) * UnitCatalog.ounce.baseFactor, UnitCatalog.ounce)]
        let result = QuantityMath.subtract(
            requested: requested, have: have, item: butter
        )
        XCTAssertFalse(result.flags.contains(.needsBridge),
                       "butter's density is in the catalogue, so this is not a bridge failure")
        XCTAssertTrue(result.didReduce, "4 oz of butter must reduce a 2 tbsp requirement")
        // 4 oz is about 113 g and 2 tbsp of butter is about 28 g, so it is covered.
        let remaining = result.toBuy.reduce(Rational.zero) { $0 + $1.base }
        XCTAssertEqual(remaining, .zero, "4 oz of butter more than covers 2 tbsp")
    }

    /// And the flag still fires when the bridge genuinely does not exist.
    func testBridgeWarningFiresOnlyWhenNothingCanConvert() {
        let requested = QuantityMath.sum([q(.one, UnitCatalog.teaspoon)], using: salt)
        let have = [subtotal(Rational(10) * UnitCatalog.gram.baseFactor, UnitCatalog.gram)]
        let result = QuantityMath.subtract(requested: requested, have: have, item: salt)
        XCTAssertTrue(result.flags.contains(.needsBridge),
                      "salt has no density, so grams cannot answer a teaspoon")
    }

    /// Same dimension needs no density at all: 3 tbsp of cream against 250 ml
    /// in the fridge leaves the list entirely.
    func testSameDimensionSubtractsWithoutADensity() {
        let noDensity = Item(gramsPerCup: nil, preferredDimension: .volume)
        let requested = QuantityMath.sum([q(Rational(3), UnitCatalog.tablespoon)], using: noDensity)
        let have = [subtotal(Rational(250) * UnitCatalog.milliliter.baseFactor,
                             UnitCatalog.milliliter)]
        let result = QuantityMath.subtract(requested: requested, have: have, item: noDensity)
        XCTAssertFalse(result.flags.contains(.needsBridge))
        XCTAssertEqual(result.toBuy.reduce(Rational.zero) { $0 + $1.base }, .zero)
    }

    /// Partial cover reduces rather than clearing: 2 cloves wanted, 1 in the
    /// pantry, so 1 to buy.
    func testPartialCoverLeavesTheShortfall() {
        let clove = UnitCatalog.countUnit(noun: "clove")
        let item = Item(gramsPerCup: nil, preferredDimension: .count)
        let requested = QuantityMath.sum([q(Rational(2), clove)], using: item)
        let result = QuantityMath.subtract(
            requested: requested, have: [subtotal(.one, clove)], item: item
        )
        XCTAssertTrue(result.didReduce)
        let left = result.toBuy.reduce(Rational.zero) { $0 + $1.base }
        XCTAssertEqual(left, .one, "2 cloves less 1 clove is 1 clove")
    }

    /// Clamped on the HAVE side, not only on `toBuy`. A lot holding a negative
    /// volume must not INFLATE the purchase: `requested - (-2 tbsp)` would buy
    /// more than the recipe asked for, and flooring only the output guards the
    /// wrong side.
    func testNegativeStockCannotInflateThePurchase() {
        let item = Item(gramsPerCup: nil, preferredDimension: .volume)
        let requested = QuantityMath.sum([q(Rational(2), UnitCatalog.tablespoon)], using: item)
        let negative = [subtotal(Rational(-2) * UnitCatalog.tablespoon.baseFactor,
                                 UnitCatalog.tablespoon)]
        let result = QuantityMath.subtract(requested: requested, have: negative, item: item)
        let toBuy = result.toBuy.reduce(Rational.zero) { $0 + $1.base }
        XCTAssertEqual(toBuy, Rational(2) * UnitCatalog.tablespoon.baseFactor,
                       "negative stock must be ignored, not added to the requirement")
    }

    // MARK: - Display, where the unit ladder has documented holes

    /// The hole every "largest unit whose value is at least 1" rule leaves
    /// open. Half a teaspoon is smaller than the finest unit above it, and must
    /// render as "1/2 tsp" rather than "0 tbsp".
    func testHalfATeaspoonDoesNotRenderAsZero() {
        let out = QuantityMath.sum([q(Rational(1, 2), UnitCatalog.teaspoon)], using: salt)
        XCTAssertEqual(out.count, 1)
        let text = out[0].quantity?.displayString() ?? ""
        XCTAssertFalse(text.hasPrefix("0"), "rendered as \(text)")
        XCTAssertTrue(text.contains("tsp"), "rendered as \(text)")
    }

    /// Fluid ounces are off the ladder entirely, which is what guarantees
    /// 18 tsp of butter reads "6 tbsp" and never "3 fl oz".
    func testFluidOuncesNeverAppear() {
        let out = QuantityMath.sum(
            Array(repeating: q(.one, UnitCatalog.teaspoon), count: 18),
            using: butter
        )
        let text = out[0].quantity?.displayString() ?? ""
        XCTAssertFalse(text.contains("fl oz"), "rendered as \(text)")
        XCTAssertEqual(text, "6 tbsp")
    }

    /// No user-facing string may carry an exact rational with an absurd
    /// denominator. A by-hand trace of the butter bridge produced
    /// "23 1111/1135 tsp", which is correct and useless.
    ///
    /// Pointed at the CONVERSION NOTE, which is where that string actually came
    /// from. This test previously drove `subtract` and looped over `toBuy`, and
    /// asserted nothing at all: 4 oz of butter is 113 2/5 g, which fully covers a
    /// 2 tbsp requirement, so `toBuy` was empty and the loop body never ran. It
    /// passed vacuously in both directions, which left the worst display bug this
    /// project has had with no regression guard whatsoever.
    ///
    /// The real path: `bridgeHave` moves 567/5 g toward volume, giving 27216/1135
    /// tsp — the denominator in the bug — and the note it writes has to render
    /// that through the display ladder rather than exactly.
    func testNoDisplayStringLeaksAnAbsurdFraction() {
        let have = [subtotal(Rational(4) * UnitCatalog.ounce.baseFactor, UnitCatalog.ounce)]
        let bridged = QuantityMath.bridgeHave(
            have,
            toward: [MeasureDimension.volume.rawValue],
            using: butter
        )
        XCTAssertEqual(bridged.bridged.count, 1, "4 oz of butter bridges to a volume")
        XCTAssertTrue(bridged.unbridgeable.isEmpty)

        // Both the note and the rendered amount, because either one printing the
        // exact rational reproduces the bug.
        let note = bridged.bridged[0].conversionNote
        let amount = bridged.bridged[0].quantity?.displayString() ?? ""
        XCTAssertFalse(note.isEmpty, "a bridged subtotal must say how it was bridged")
        for text in [note, amount] {
            XCTAssertFalse(text.contains("/1135"), text)
            // Nothing a kitchen reads has a three-digit denominator.
            var rest = Substring(text)
            while let slash = rest.firstIndex(of: "/") {
                let after = rest.index(after: slash)
                let denominator = rest[after...].prefix { $0.isNumber }
                XCTAssertLessThanOrEqual(denominator.count, 2, "denominator in \(text)")
                rest = rest[after...]
            }
        }
    }

    // MARK: - Scaling, end to end

    /// The attendance case, through the arithmetic rather than on paper:
    /// 2 full + 1 half + 2 guests against a recipe for 4 is ×1 1/8, and the
    /// fixture's 1/4 tsp of salt becomes exactly 9/32 tsp.
    func testScaledFixtureSaltIsExact() {
        let scale = (Rational(2) + Rational(1, 2) + Rational(2)) / Rational(4)
        XCTAssertEqual(scale, Rational(9, 8))
        let out = QuantityMath.sum(
            [q(Rational(1, 4) * scale, UnitCatalog.teaspoon)],
            using: salt
        )
        let amount = out[0].base / UnitCatalog.teaspoon.baseFactor
        XCTAssertEqual(amount, Rational(9, 32))
    }

    // MARK: - A bird is selected by weight, not scaled by portions
    //
    // The roast turkey document states no serving count, and until this feature the
    // Swift divided by a 4 nobody chose. Asked how many it serves Brandon answered
    // with a weight -- "the turkey was for a roughly 14lb turkey" -- and then "yes
    // use the weight chart". Nobody roasts 1.4 turkeys: you buy a bigger bird and
    // read the longer time off the chart, so the scale is the bird over the basis
    // and attendance does not enter. Every other dish in the meal is untouched,
    // which the last test here is for.

    /// The turkey's chart as `scripts/import_recipe.py` parses it out of the
    /// document, verbatim from `KitchenAid/Resources/Recipes/roast-turkey.json`.
    /// Built here rather than loaded, so these assertions need no bundle.
    private func turkeyChart() -> RecipeTable {
        RecipeTable(
            name: "Cooking Times",
            headers: ["Turkey weight", "Total time",
                      "Covered (first 2/3)", "Uncovered (last 1/3)"],
            rows: [
                ["10 lb", "2 hr 10 min", "1 hr 27 min", "43 min"],
                ["12 lb", "2 hr 36 min", "1 hr 44 min", "52 min"],
                ["14 lb", "3 hr 02 min", "2 hr 01 min", "1 hr 01 min"],
                ["16 lb", "3 hr 28 min", "2 hr 19 min", "1 hr 09 min"],
                ["18 lb", "3 hr 54 min", "2 hr 36 min", "1 hr 18 min"],
                ["20 lb", "4 hr 20 min", "2 hr 53 min", "1 hr 27 min"],
                ["22 lb", "4 hr 46 min", "3 hr 11 min", "1 hr 35 min"],
                ["24 lb", "5 hr 12 min", "3 hr 28 min", "1 hr 44 min"]
            ]
        )
    }

    /// The bundled turkey: a 14 lb basis from `docs/recipe-overrides.json`, the
    /// chart, and `servingsStated` false with the decoder's substituted 4 sitting
    /// in `servings` — which is precisely the number none of this may divide by.
    private func turkey() -> Recipe {
        var recipe = Recipe(id: "roast-turkey", title: "Roast Turkey")
        recipe.basisWeightPounds = Rational(14)
        recipe.tables = [turkeyChart()]
        recipe.servingsNumerator = 4
        recipe.servingsDenominator = 1
        recipe.servingsStated = false
        return recipe
    }

    /// One dish of a meal with nobody assigned: `meal` is nil, so
    /// `requestedPortions` is zero and the `defaultDinerCount` fallback fires.
    /// That is the state the weight path has to survive, because it is the state a
    /// shopping list is generated in.
    private func turkeyDish(weight: Rational? = nil, override: Rational? = nil) -> MealRecipe {
        let made = MealRecipe(recipeID: "roast-turkey", recipeTitleSnapshot: "Roast Turkey")
        made.setChosenWeightPounds(weight)
        made.setScaleOverride(override)
        return made
    }

    /// The headline case, exact: an 18 lb bird against the document's 14 lb is
    /// 9/7. Not 1.2857, and not 1 2/7 rounded anywhere on the way.
    func testEighteenPoundBirdIsExactlyNineSevenths() {
        let result = MealScaling.scaling(
            for: turkeyDish(weight: Rational(18)), recipe: turkey(), defaultDinerCount: 2
        )
        XCTAssertEqual(result.scale, Rational(9, 7))
        XCTAssertEqual(result.scale.numerator, 9)
        XCTAssertEqual(result.scale.denominator, 7)
        // And it carries through a quantity exactly: the turkey's 1/2 cup of butter
        // at 9/7 is 9/14 cup, which no `Double` round trip gives back.
        XCTAssertEqual(Rational(1, 2) * result.scale, Rational(9, 14))
        XCTAssertTrue(result.notes.isEmpty, "a chosen weight needs no badge: \(result.notes)")
    }

    /// The bird the recipe was written for scales to exactly 1 — no drift, and no
    /// `.snappedToBatch` surprise from a granularity that does not apply.
    func testTheBasisWeightScalesToOne() {
        let result = MealScaling.scaling(
            for: turkeyDish(weight: Rational(14)), recipe: turkey(), defaultDinerCount: 2
        )
        XCTAssertEqual(result.scale, .one)
    }

    /// The defect this feature exists to end. With no weight chosen the dish must
    /// cook as written and SAY a weight is needed — not fall through to the
    /// serving-count path, where two default diners over the substituted 4 is 1/2
    /// and every quantity on the list is halved for no stated reason.
    func testNoWeightChosenDoesNotDivideByTheSubstitutedServings() {
        let result = MealScaling.scaling(
            for: turkeyDish(), recipe: turkey(), defaultDinerCount: 2
        )
        XCTAssertEqual(result.scale, .one)
        XCTAssertNotEqual(result.scale, Rational(1, 2), "this is the old serving-count path")
        XCTAssertTrue(result.notes.contains(.unknownYield),
                      "a missing bird weight has to reach a badge")
        XCTAssertFalse(result.notes.contains(.noAttendance),
                       "attendance did not produce this number, so it must not explain it")
        // Portions are still REPORTED — the screens show who is eating — they just
        // do not divide.
        XCTAssertEqual(result.portions, Rational(2))
        XCTAssertTrue(result.description.contains("14 lb"),
                      "the sentence must name the basis: \(result.description)")
    }

    /// "Actually ×2" beats everything, chart included. He is allowed to say it and
    /// the app should not argue.
    func testAManualOverrideStillBeatsTheChart() {
        let result = MealScaling.scaling(
            for: turkeyDish(weight: Rational(18), override: Rational(2)),
            recipe: turkey(),
            defaultDinerCount: 2
        )
        XCTAssertEqual(result.scale, Rational(2))
        XCTAssertTrue(result.notes.contains(.overridden))
    }

    /// `description` lands on every shopping provenance row, so for a weight-driven
    /// dish it has to name the weight rather than a head count — and render through
    /// the display ladder, never `exactDescription`, which is how a label came to
    /// read "23 1111/1135 tsp".
    func testTheDescriptionNamesTheWeightAndNotAHeadCount() {
        let result = MealScaling.scaling(
            for: turkeyDish(weight: Rational(18)), recipe: turkey(), defaultDinerCount: 2
        )
        XCTAssertTrue(result.description.contains("18 lb"), result.description)
        XCTAssertTrue(result.description.contains("14 lb"), result.description)
        XCTAssertFalse(result.description.contains("eater"), result.description)
        XCTAssertFalse(result.description.contains("serves"), result.description)
        // 9/7 exactly would interpolate as "1 2/7". The ladder gives "≈ 1.3".
        XCTAssertFalse(result.description.contains("2/7"), result.description)
    }

    /// Both halves or neither. A basis with no chart leaves nothing to pick from
    /// and a chart with no basis leaves nothing to divide by, and either one
    /// half-enabling the feature means a dish on a weight-driven screen that
    /// cannot work.
    func testIsWeightDrivenNeedsBothTheBasisAndTheChart() {
        XCTAssertTrue(turkey().isWeightDriven)

        var chartOnly = turkey()
        chartOnly.basisWeightPounds = nil
        XCTAssertFalse(chartOnly.isWeightDriven, "a chart with no basis")

        var basisOnly = turkey()
        basisOnly.tables = []
        XCTAssertFalse(basisOnly.isWeightDriven, "a basis with no chart")

        // And a basis with a table that is not a weight chart.
        var wrongTable = turkey()
        wrongTable.tables = [RecipeTable(
            name: "Doneness", headers: ["Cut", "Internal temp"], rows: [["Breast", "165 F"]]
        )]
        XCTAssertFalse(wrongTable.isWeightDriven, "a table whose first column is not a weight")
    }

    /// The weights a picker offers, parsed off the chart's own first column, and
    /// the row lookup the Cook screen reads times from.
    func testTheChartYieldsItsWeightsAndFindsARowByWeight() {
        let recipe = turkey()
        XCTAssertEqual(recipe.selectableWeightsPounds,
                       [10, 12, 14, 16, 18, 20, 22, 24].map { Rational($0) })
        XCTAssertEqual(Recipe.pounds(fromWeightCell: "18 lb"), Rational(18))
        XCTAssertNil(Recipe.pounds(fromWeightCell: "Turkey weight"))

        XCTAssertEqual(recipe.weightRow(forPounds: Rational(18))?.first, "18 lb")
        XCTAssertEqual(recipe.weightRow(forPounds: Rational(18))?[1], "3 hr 54 min")
        // Numerically, not by string prefix: a 2 lb weight must not read 20 lb's
        // times, which `RecipeTable.row(matchingFirstColumn:)`'s fallback would do.
        XCTAssertNil(recipe.weightRow(forPounds: Rational(2)))
    }

    /// And nothing moved for a recipe that is not weight-driven. The fixture serves
    /// 4, two default diners against it is exactly 1/2, and the `.noAttendance`
    /// badge still fires — the weight branch must be invisible here.
    func testPortionScalingIsUnchangedForAnOrdinaryRecipe() {
        var crostini = Recipe(id: "ny-strip-crostini", title: "NY Strip Crostini")
        crostini.servingsNumerator = 4
        crostini.servingsDenominator = 1
        XCTAssertFalse(crostini.isWeightDriven)

        let plain = MealRecipe(recipeID: crostini.id, recipeTitleSnapshot: crostini.title)
        let result = MealScaling.scaling(for: plain, recipe: crostini, defaultDinerCount: 2)
        XCTAssertEqual(result.scale, Rational(1, 2))
        XCTAssertEqual(result.portions, Rational(2))
        XCTAssertTrue(result.notes.contains(.noAttendance))
        XCTAssertTrue(result.description.contains("recipe serves 4"), result.description)

        // A weight stored on a dish whose recipe is not weight-driven changes
        // nothing: there is no basis to divide by, so it is kept and ignored.
        plain.setChosenWeightPounds(Rational(18))
        let again = MealScaling.scaling(for: plain, recipe: crostini, defaultDinerCount: 2)
        XCTAssertEqual(again.scale, Rational(1, 2))
    }
}
