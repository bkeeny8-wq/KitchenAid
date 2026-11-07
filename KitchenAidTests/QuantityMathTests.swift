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
    func testVolumeAndMassCollapseWhenADensityExists() {
        let mixed = QuantityMath.sum(
            [q(.one, UnitCatalog.cup), q(Rational(200), UnitCatalog.gram)],
            using: flour
        )
        XCTAssertEqual(mixed.count, 2, "sum keeps the buckets; collapsing is a separate pass")
        let collapsed = QuantityMath.collapseAcrossDimensions(mixed, using: flour, system: .us)
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
    func testNoDisplayStringLeaksAnAbsurdFraction() {
        let requested = QuantityMath.sum([q(Rational(2), UnitCatalog.tablespoon)], using: butter)
        let have = [subtotal(Rational(4) * UnitCatalog.ounce.baseFactor, UnitCatalog.ounce)]
        let result = QuantityMath.subtract(requested: requested, have: have, item: butter)
        for bucket in result.toBuy {
            let text = bucket.quantity?.displayString() ?? ""
            XCTAssertFalse(text.contains("/1135"), text)
            // Nothing a kitchen reads has a three-digit denominator.
            if let slash = text.firstIndex(of: "/") {
                let denominator = text[text.index(after: slash)...].prefix { $0.isNumber }
                XCTAssertLessThanOrEqual(denominator.count, 2, "denominator in \(text)")
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
}
