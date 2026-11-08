import XCTest
@testable import KitchenAid

/// Receipt reading, catalogue matching, and barcode normalization.
///
/// `ReceiptTokenMatcher` is pure — strings in, candidates out, no `ModelContainer` and no
/// camera — which makes it the one part of the scanning feature that can carry real
/// assertions. So it carries a lot of them. Everything below was traced against a port of the
/// algorithm before it was written down, because there is no Apple toolchain in this
/// container: **these have never been run.** Treat every number as unverified until the test
/// target runs on Brandon's Mac, and read the two assertions in `CODE_REVIEW_01.md` that
/// passed for the wrong reason before trusting the shape of one here.
///
/// What is NOT covered, and cannot be from here: everything in `BarcodeRegistry` and
/// `ReceiptIntake` that fetches, because a fetch needs a context. `normalize(_:)` and the
/// key agreement that makes "once, then remembers" work are testable, and they are the two
/// places a silent failure would cost him a question on every single receipt.
final class ReceiptScanningTests: XCTestCase {

    // MARK: - A stand-in catalogue

    /// Thirteen real entries, copied from `ingredients.json` with their real aisles,
    /// dimensions and aliases.
    ///
    /// Hand-built rather than loaded, for the same reason `QuantityMathTests` uses a
    /// `DensityCarrying` stand-in instead of a `FoodItem`: `IngredientCatalog` reads its JSON
    /// out of a `Bundle`, and a unit test's bundle is the test runner's. The matcher takes
    /// `[CatalogEntry]` precisely so this file can exist.
    private func entry(
        _ name: String,
        _ aisle: String,
        _ dimension: MeasureDimension,
        _ unit: String,
        _ aliases: [String] = []
    ) -> CatalogEntry {
        var made = CatalogEntry(name: name, aisle: aisle, dimension: dimension, unit: unit)
        made.aliases = aliases
        return made
    }

    private var catalogue: [CatalogEntry] {
        [
            entry("cream cheese", "Dairy", .mass, "oz", ["cream cheeses"]),
            entry("cottage cheese", "Dairy", .mass, "oz", ["cottage cheeses"]),
            entry("goat cheese", "Dairy", .mass, "oz", ["chevre", "goat cheeses"]),
            entry("blue cheese", "Dairy", .mass, "oz", ["blue cheeses"]),
            entry("swiss cheese", "Dairy", .mass, "oz", ["swiss cheeses"]),
            entry("heavy cream", "Dairy", .volume, "cup", ["heavy whipping cream", "heavy creams"]),
            entry("milk", "Dairy", .volume, "cup", ["whole milk", "milks"]),
            entry("milk chocolate", "Baking", .mass, "oz", ["milk chocolates"]),
            entry("eggs", "Dairy", .count, "each", ["egg"]),
            entry("banana", "Produce", .count, "each", ["bananas"]),
            entry("chicken breast", "Butcher", .count, "each",
                  ["boneless skinless chicken breast", "chicken breasts"]),
            entry("chicken thigh", "Butcher", .count, "each", ["chicken thighs"]),
            entry("butter", "Dairy", .volume, "tbsp", ["unsalted butter", "salted butter", "butters"])
        ]
    }

    /// Mirrors `IngredientCatalog.entry(matching:)`: canonical name first, then `matchKey`,
    /// then a shipped alias's `matchKey`. The order is the part that matters — an alias
    /// winning over a name lets one row's synonym capture another row's identity — and the
    /// shipping implementation is the one in `IngredientCatalog`, not this.
    /// Static, so the closure handed to the matcher captures an array and not a test case.
    private static func exactLookup(_ raw: String, in entries: [CatalogEntry]) -> CatalogEntry? {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let named = entries.first(where: { $0.name.lowercased() == lowered }) { return named }
        let key = NameNormalizer.matchKey(raw)
        guard !key.isEmpty else { return nil }
        if let byKey = entries.first(where: { $0.matchKey == key }) { return byKey }
        return entries.first(where: { $0.aliasMatchKeys.contains(key) })
    }

    private func matcher() -> ReceiptTokenMatcher {
        let entries = catalogue
        return ReceiptTokenMatcher(
            entries: entries,
            exactLookup: { name in ReceiptScanningTests.exactLookup(name, in: entries) }
        )
    }

    // MARK: - The headline case

    /// His own example: `GV CRM CHS 8Z` is Great Value cream cheese, 8 oz.
    ///
    /// Four separate things have to go right in one line, which is why they are asserted
    /// separately: the brand prefix comes off, the price comes off, the size is read as a real
    /// `Rational`, and two vowel-dropped abbreviations reach a two-word catalogue name.
    func testGreatValueCreamCheeseReachesCreamCheese() throws {
        let match = matcher().match("GV CRM CHS 8Z            4.99 F")

        XCTAssertTrue(match.reading.isItemLine)
        XCTAssertEqual(match.reading.brand, "GV")
        XCTAssertEqual(match.reading.nameDisplay, "CRM CHS")
        XCTAssertEqual(match.reading.nameKey, "crm chs")
        XCTAssertEqual(match.reading.priceCents, 499)
        XCTAssertEqual(match.reading.sizeAmount, Rational(8))
        XCTAssertEqual(match.reading.sizeUnitCode, "oz")

        let top = try XCTUnwrap(match.best)
        XCTAssertEqual(top.entry.name, "cream cheese", "ranked: \(match.candidates.map { $0.name })")
        XCTAssertEqual(top.tokenCoverage, 100, "both words of the token were consumed")
        XCTAssertEqual(top.nameCoverage, 100, "both words of the name were accounted for")
        XCTAssertGreaterThanOrEqual(top.score, ReceiptTokenMatcher.confidentScore)
        XCTAssertTrue(match.isConfident, "cream cheese is clear of the runner-up")
        XCTAssertFalse(match.needsAnswer)

        // `8Z` is eight WEIGHT ounces here, because cream cheese is sold by mass. The same two
        // characters on a milk line are fluid ounces — see
        // `testTheSameSizeResolvesToWeightOrFluidByTheFood`.
        let size = try XCTUnwrap(top.size)
        XCTAssertEqual(size.amount, Rational(8))
        XCTAssertEqual(size.unit.code, "oz")
        XCTAssertEqual(size.unit.dimension, MeasureDimension.mass)
    }

    /// Rule 3, which is the whole reason the size's unit is resolved per candidate rather than
    /// in `read(_:)`: `UnitCatalog` already knows `oz` is ambiguous and already resolves it
    /// from a dimension. Half a pound of chicken stock was the bug that put that there.
    func testTheSameSizeResolvesToWeightOrFluidByTheFood() throws {
        let milk = try XCTUnwrap(matcher().match("GV MLK 8Z 2.78").best)
        XCTAssertEqual(milk.entry.name, "milk")
        let fluid = try XCTUnwrap(milk.size)
        XCTAssertEqual(fluid.unit.code, "floz")
        XCTAssertEqual(fluid.unit.dimension, MeasureDimension.volume)
        XCTAssertEqual(fluid.amount, Rational(8))
    }

    // MARK: - Lines that are not items

    /// A price-only line and a totals line produce nothing. Both are rejected with a named
    /// reason, so a screen can say "skipped 9 totals lines" instead of quietly dropping a
    /// third of the receipt.
    func testAPriceOnlyLineAndASubtotalLineProduceNothing() {
        let m = matcher()

        let price = m.match("4.99")
        XCTAssertFalse(price.reading.isItemLine)
        XCTAssertEqual(price.reading.rejection, ReceiptTokenMatcher.Rejection.noLetters)
        XCTAssertTrue(price.candidates.isEmpty)

        // A tax flag gives the line a letter, so it survives the no-letters test and is
        // rejected one step later, with nothing left after the price came off.
        let flagged = m.match("$4.99 F")
        XCTAssertFalse(flagged.reading.isItemLine)
        XCTAssertEqual(flagged.reading.rejection, ReceiptTokenMatcher.Rejection.noName)
        XCTAssertEqual(flagged.reading.priceCents, 499)
        XCTAssertTrue(flagged.candidates.isEmpty)

        let subtotal = m.match("SUBTOTAL                42.17")
        XCTAssertEqual(subtotal.reading.rejection, ReceiptTokenMatcher.Rejection.totals)
        XCTAssertTrue(subtotal.candidates.isEmpty)

        XCTAssertEqual(m.match("TOTAL     44.64").reading.rejection,
                       ReceiptTokenMatcher.Rejection.totals)
        XCTAssertEqual(m.match("TAX  1    2.47").reading.rejection,
                       ReceiptTokenMatcher.Rejection.totals)
        XCTAssertEqual(m.match("CHANGE    0.00").reading.rejection,
                       ReceiptTokenMatcher.Rejection.totals)
        XCTAssertEqual(m.match("VISA DEBIT **** 1234").reading.rejection,
                       ReceiptTokenMatcher.Rejection.payment)
        XCTAssertEqual(m.match("1234 MAIN ST").reading.rejection,
                       ReceiptTokenMatcher.Rejection.address)
        XCTAssertEqual(m.match("GROCERY").reading.rejection,
                       ReceiptTokenMatcher.Rejection.department)
        XCTAssertEqual(m.match("").reading.rejection, ReceiptTokenMatcher.Rejection.blank)
    }

    /// `2 @ 3.50` is a quantity line, not an item — and its numbers are kept anyway, so a
    /// screen that wants to apply them to the line above has them. Nothing here guesses that
    /// it should.
    func testAQuantityLineIsNotAnItemButIsStillRead() {
        let match = matcher().match("2 @ 3.50")
        XCTAssertEqual(match.reading.rejection, ReceiptTokenMatcher.Rejection.quantityOnly)
        XCTAssertEqual(match.reading.multiplier, 2)
        XCTAssertEqual(match.reading.priceCents, 350)
        XCTAssertTrue(match.candidates.isEmpty)
    }

    /// The address rule requires the street suffix to be the LAST word, and this is why.
    /// `ST LOUIS RIBS` is a real cut of pork; an address rule that fired on any `ST` would
    /// drop it off every receipt with nothing saying so.
    func testAStreetSuffixInTheMiddleIsNotAnAddress() {
        let match = matcher().match("2 LB ST LOUIS RIBS 14.99")
        XCTAssertTrue(match.reading.isItemLine)
        XCTAssertEqual(match.reading.nameKey, "st louis ribs")
        XCTAssertEqual(match.reading.sizeAmount, Rational(2))
        XCTAssertEqual(match.reading.sizeUnitCode, "lb")
        // Nothing in this stand-in catalogue is ribs, so it asks. That is the right answer:
        // it is an item line with no match, not a line to throw away.
        XCTAssertTrue(match.candidates.isEmpty)
        XCTAssertTrue(match.needsAnswer)
    }

    // MARK: - Ambiguity

    /// `CHS` is five cheeses and the honest answer is five cheeses. The screen is going to ask
    /// him, and a confident wrong answer is worse than a question.
    func testAnAmbiguousTokenReturnsMoreThanOneCandidate() {
        let match = matcher().match("CHS 3.99 F")
        XCTAssertTrue(match.reading.isItemLine)
        XCTAssertGreaterThan(match.candidates.count, 1,
                             "one cheese out of five is a guess, not a match")
        XCTAssertFalse(match.isConfident, "nothing here is clear of anything else")
        XCTAssertTrue(match.needsAnswer)
        for candidate in match.candidates {
            XCTAssertTrue(candidate.name.contains("cheese"), candidate.name)
        }
        // Tied scores, so the order has to come from the tie-breaks and not from dictionary
        // iteration: two runs that disagree about "the first one" are a screen that offers a
        // different cheese each time it opens.
        XCTAssertEqual(match.candidates.map { $0.name },
                       match.candidates.map { $0.name }.sorted(),
                       "tied candidates sort by name")
    }

    // MARK: - Aliases

    /// A token that matches a shipped ALIAS rather than a name. `chevre` is goat cheese, and
    /// the lookup that finds it is `IngredientCatalog.entry(matching:)`'s alias rung.
    func testATokenMatchesACatalogueAliasRatherThanAName() throws {
        let match = matcher().match("CHEVRE 7.49")
        let top = try XCTUnwrap(match.best)
        XCTAssertEqual(top.entry.name, "goat cheese")
        XCTAssertTrue(top.isExact, "an exact alias is as good as an exact name")
        XCTAssertEqual(top.score, 100)
        XCTAssertTrue(match.isConfident)
        XCTAssertEqual(match.candidates.count, 1,
                       "the build script guarantees no two entries share an alias")
    }

    /// And an ABBREVIATION reaching an alias, which is two mechanisms at once: `HVY WHIP CRM`
    /// matches none of `heavy cream`'s own words as written, and all three words of its alias.
    func testAnAbbreviationReachesAnAliasAndSaysSo() throws {
        let match = matcher().match("HVY WHIP CRM 4.29")
        let top = try XCTUnwrap(match.best)
        XCTAssertEqual(top.entry.name, "heavy cream")
        XCTAssertEqual(top.matchedVia, "heavy whipping cream",
                       "the screen has to be able to say WHY it picked that")
        XCTAssertEqual(top.matchedWords, 3)
        XCTAssertTrue(match.isConfident)
    }

    /// `WHL MLK` through milk's `whole milk` alias, and the entry appears ONCE even though two
    /// of its strings match. `chicken breast` is reachable by its name and by
    /// `boneless skinless chicken breast`; without the best-per-entry fold he would be offered
    /// the same food twice at different scores.
    func testAnEntryAppearsOnceAtItsBestScore() throws {
        let match = matcher().match("WHL MLK 3.19")
        let names = match.candidates.map { $0.name }
        XCTAssertEqual(names.filter { $0 == "milk" }.count, 1, "ranked: \(names)")
        let top = try XCTUnwrap(match.best)
        XCTAssertEqual(top.entry.name, "milk")
        XCTAssertEqual(top.matchedVia, "whole milk")
    }

    // MARK: - Coverage and grade words

    /// `ORG` is a grade word. It matches nothing in the catalogue, and it must not be held
    /// against the match — otherwise two words of three gives 66% coverage and the one
    /// unambiguous reading on the line becomes a question.
    func testAGradeWordDoesNotCountAgainstTheMatch() throws {
        let match = matcher().match("KS ORG CHKN BRST 2 LB 12.99")
        XCTAssertEqual(match.reading.brand, "KS")
        XCTAssertEqual(match.reading.nameKey, "org chkn brst")
        XCTAssertEqual(match.reading.sizeAmount, Rational(2))
        XCTAssertEqual(match.reading.sizeUnitCode, "lb")

        let top = try XCTUnwrap(match.best)
        XCTAssertEqual(top.entry.name, "chicken breast")
        XCTAssertEqual(top.tokenCoverage, 100, "ORG is a grade word, not a missed word")
        XCTAssertTrue(match.isConfident)

        // And the loose tier does not get to invent a match on its own: a grade word that
        // reaches something by subsequence alone is not a candidate. `ORG` is a subsequence of
        // `orange`, which is how oranges once landed on a chicken line.
        XCTAssertFalse(match.candidates.contains(where: { $0.name == "orange" }))
    }

    // MARK: - Never invent a quantity

    /// The constraint with the sharpest teeth. A size that is not written is ABSENT, not 1: an
    /// invented quantity is a wrong number in his pantry that nothing downstream can detect,
    /// and `InventoryLedger` would post it as fact.
    func testNeverInventsAQuantityItDidNotRead() throws {
        let match = matcher().match("GV CRM CHS 4.99 F")
        XCTAssertNil(match.reading.sizeAmount)
        XCTAssertEqual(match.reading.sizeUnitCode, "")
        XCTAssertNil(match.reading.multiplier)
        XCTAssertNil(match.reading.size(preferring: .mass))
        let top = try XCTUnwrap(match.best)
        XCTAssertEqual(top.entry.name, "cream cheese", "the match still works without a size")
        XCTAssertNil(top.size)

        // An abbreviated size the parser cannot place is absent too, not guessed. `8QQ` is not
        // a unit this app knows, so it is dropped rather than read as eight of something.
        let unknown = matcher().match("GV CRM CHS 8QQ 4.99")
        XCTAssertNil(unknown.reading.sizeAmount)
    }

    /// A leading bare integer is a multiplier; a number followed by a unit is a size. `12 CT
    /// EGGS` is a dozen eggs, not twelve purchases of a carton.
    func testALeadingCountIsASizeWhenAUnitFollowsItAndAMultiplierWhenNoneDoes() throws {
        let dozen = matcher().match("12 CT EGGS 3.49")
        XCTAssertNil(dozen.reading.multiplier, "CT made it a size, not a multiplier")
        XCTAssertEqual(dozen.reading.sizeAmount, Rational(12))
        XCTAssertEqual(dozen.reading.sizeUnitCode, "each")
        let eggs = try XCTUnwrap(dozen.best)
        XCTAssertEqual(eggs.entry.name, "eggs")
        let size = try XCTUnwrap(eggs.size)
        XCTAssertEqual(size.unit.dimensionKey, "count:each",
                       "a count keeps its own bucket, away from weight and volume")

        let two = matcher().match("2 GV CRM CHS 9.98")
        XCTAssertEqual(two.reading.multiplier, 2)
        XCTAssertEqual(two.reading.brand, "GV")
        XCTAssertNil(two.reading.sizeAmount)
    }

    /// A store code or a UPC printed on the line is neither a quantity nor a name.
    func testAStoreCodeIsDroppedAndTheLineStillMatches() throws {
        let match = matcher().match("GV CRM CHS 8Z 007874201234 F 4.99")
        XCTAssertTrue(match.reading.droppedWords.contains("007874201234"))
        XCTAssertEqual(match.reading.nameKey, "crm chs")
        XCTAssertEqual(match.reading.sizeAmount, Rational(8))
        XCTAssertEqual(try XCTUnwrap(match.best).entry.name, "cream cheese")
    }

    /// A plural reaching a singular name, for free, because the token goes through
    /// `NameNormalizer.matchKey` before any matching happens.
    func testAPluralOnTheReceiptMatchesTheSingularCatalogueName() throws {
        let match = matcher().match("BANANAS 1.27 F")
        XCTAssertEqual(match.reading.nameKey, "banana")
        let top = try XCTUnwrap(match.best)
        XCTAssertEqual(top.entry.name, "banana")
        XCTAssertTrue(top.isExact)
        XCTAssertTrue(match.isConfident)
    }

    // MARK: - The pieces, directly

    /// The receipt convention this whole feature rests on: drop the vowels, keep the first
    /// letter. `y` counts as a consonant, which is what lets `HVY` reach `heavy`.
    func testTheConsonantSkeletonIsTheReceiptConvention() {
        XCTAssertEqual(ReceiptTokenMatcher.consonantSkeleton("cream"), "crm")
        XCTAssertEqual(ReceiptTokenMatcher.consonantSkeleton("cheese"), "chs")
        XCTAssertEqual(ReceiptTokenMatcher.consonantSkeleton("milk"), "mlk")
        XCTAssertEqual(ReceiptTokenMatcher.consonantSkeleton("heavy"), "hvy")
        XCTAssertEqual(ReceiptTokenMatcher.consonantSkeleton("beef"), "bf")
        // The first letter survives even when it is a vowel: an abbreviation keeps it.
        XCTAssertEqual(ReceiptTokenMatcher.consonantSkeleton("apple"), "appl")
        XCTAssertEqual(ReceiptTokenMatcher.consonantSkeleton(""), "")
    }

    /// The tiers, and the floor under them. Every tier requires the same first letter, which
    /// is what keeps `buttermilk` away from `MLK` — and what makes the index's cheap
    /// first-letter rejection sound rather than merely fast.
    func testWordPointsRanksTheTiersAndRefusesAMismatchedFirstLetter() {
        XCTAssertEqual(ReceiptTokenMatcher.wordPoints("banana", "banana"), 100)
        XCTAssertEqual(ReceiptTokenMatcher.wordPoints("choc", "chocolate"), 90)
        XCTAssertEqual(ReceiptTokenMatcher.wordPoints("crm", "cream"), 85)
        XCTAssertEqual(ReceiptTokenMatcher.wordPoints("chkn", "chicken"), 70)
        XCTAssertEqual(ReceiptTokenMatcher.wordPoints("brst", "breast"), 70)
        XCTAssertEqual(ReceiptTokenMatcher.wordPoints("mlk", "buttermilk"), 0,
                       "a different first letter is never a match")
        XCTAssertEqual(ReceiptTokenMatcher.wordPoints("c", "cream"), 0,
                       "one letter is not evidence")
        // The loose tier IS loose, and that is why coverage and not tier order decides the
        // ranking: `CRM` is a subsequence of `cardamom` too.
        XCTAssertEqual(ReceiptTokenMatcher.wordPoints("crm", "cardamom"), 70)
    }

    /// Money is read digit by digit, into cents, because `InventoryLedger.apply` already takes
    /// `priceCents` and because no `Double` goes anywhere near a number he will see next to a
    /// dollar sign. Cents are required: a bare integer on a receipt is a count or a code far
    /// more often than a price.
    func testMoneyIsReadIntoCentsAndOnlyWithCents() {
        XCTAssertEqual(ReceiptTokenMatcher.moneyCents("4.99"), 499)
        XCTAssertEqual(ReceiptTokenMatcher.moneyCents("$4.99"), 499)
        XCTAssertEqual(ReceiptTokenMatcher.moneyCents("4.99-"), 499)
        XCTAssertEqual(ReceiptTokenMatcher.moneyCents("0.00"), 0)
        XCTAssertEqual(ReceiptTokenMatcher.moneyCents("12.07"), 1207)
        XCTAssertNil(ReceiptTokenMatcher.moneyCents("4"))
        XCTAssertNil(ReceiptTokenMatcher.moneyCents("4.9"))
        XCTAssertNil(ReceiptTokenMatcher.moneyCents("4.999"))
        XCTAssertNil(ReceiptTokenMatcher.moneyCents("CHS"))
    }

    /// Sizes are exact rationals, never `Double`. `1.5` is three halves.
    func testSizesAreExactRationals() {
        XCTAssertEqual(ReceiptTokenMatcher.rational(fromNumber: "12"), Rational(12))
        XCTAssertEqual(ReceiptTokenMatcher.rational(fromNumber: "1.5"), Rational(3, 2))
        XCTAssertEqual(ReceiptTokenMatcher.rational(fromNumber: "16.9"), Rational(169, 10))
        XCTAssertEqual(ReceiptTokenMatcher.rational(fromNumber: "1/2"), Rational(1, 2))
        XCTAssertNil(ReceiptTokenMatcher.rational(fromNumber: "8z"))
        XCTAssertNil(ReceiptTokenMatcher.rational(fromNumber: ""))

        // ...and through a whole line, so the glued form is covered too.
        let litres = matcher().match("COKE 1.5L 2.49")
        XCTAssertEqual(litres.reading.sizeAmount, Rational(3, 2))
        XCTAssertEqual(litres.reading.sizeUnitCode, "l")
    }

    // MARK: - "Once, then remembers"

    /// **The promise, at the one point it can silently break.**
    ///
    /// `ReceiptIntake.learn` stores `nameDisplay` as a `FoodItemAlias`, whose `matchKey` is
    /// derived by `NameNormalizer.matchKey`. The lookup that has to find it again asks for
    /// `reading.nameKey` through `FoodItem.descriptor(forAliasKey:)`, which matches against
    /// `aliasBlob`. If those two keys ever differ, the alias is filed under a key nothing
    /// looks up: no error, no warning, and he answers the same question on every receipt
    /// forever. This is `ShoppingListBuilder.identity`'s "two implementations of this rule"
    /// problem, in the one place it would be invisible.
    func testTheLearnedAliasKeyIsExactlyTheKeyTheLookupAsksFor() {
        for line in ["GV CRM CHS 8Z 4.99 F",
                     "KS ORG CHKN BRST 2 LB 12.99",
                     "HVY WHIP CRM 4.29",
                     "BANANAS 1.27 F"] {
            let reading = ReceiptTokenMatcher.read(line)
            XCTAssertTrue(reading.isItemLine, line)
            let stored = NameNormalizer.matchKey(reading.nameDisplay)
            XCTAssertEqual(stored, reading.nameKey, line)

            let blob = FoodItem.encodeAliasBlob([stored])
            XCTAssertTrue(
                blob.contains(FoodItem.aliasNeedle(forMatchKey: reading.nameKey)),
                "\(line): stored \(blob), looked up \(reading.nameKey)"
            )
        }
    }

    /// A whole recognized receipt, in printed order, rejects included — because a `2 @ 3.50`
    /// line only means anything next to the line above it.
    func testAWholeReceiptIsReadLineByLineInPrintedOrder() {
        let intake = ReceiptIntake(
            resolver: FoodItemResolver(catalog: IngredientCatalog()),
            entries: catalogue
        )
        let readings = intake.read(receiptText: """
        GV CRM CHS 8Z 4.99 F
        2 @ 3.50
        SUBTOTAL 8.49
        """)
        XCTAssertEqual(readings.count, 3)
        XCTAssertEqual(readings[0].nameKey, "crm chs")
        XCTAssertEqual(readings[1].rejection, ReceiptTokenMatcher.Rejection.quantityOnly)
        XCTAssertEqual(readings[2].rejection, ReceiptTokenMatcher.Rejection.totals)
    }

    // MARK: - Barcodes

    /// **The 12- and 13-digit forms of one number have to agree**, or the second scan of the
    /// same tin asks him what it is all over again. EAN-13 and UPC-A are the same number with
    /// a leading zero, and different readers report the same label as either one.
    func testBarcodeNormalisationMakesTheTwelveAndThirteenDigitFormsAgree() {
        let twelve = FoodItemBarcode.normalize("012345678905")
        let thirteen = FoodItemBarcode.normalize("0012345678905")
        XCTAssertEqual(twelve, thirteen)
        XCTAssertEqual(twelve, "00012345678905", "the chosen normalization is GTIN-14")
        XCTAssertEqual(twelve.count, 14)

        // Separators a reader or a hand entry can add.
        XCTAssertEqual(FoodItemBarcode.normalize("0 12345 67890 5"), twelve)
        XCTAssertEqual(FoodItemBarcode.normalize("0-12345-67890-5"), twelve)

        // A 14-digit case code is already normal; an EAN-8 pads the same way.
        XCTAssertEqual(FoodItemBarcode.normalize("10012345678905"), "10012345678905")
        XCTAssertEqual(FoodItemBarcode.normalize("96385074"), "00000096385074")
    }

    /// Anything that is not a product-code length is refused outright, so a produce PLU or a
    /// partial read cannot be filed as a barcode and then auto-fill the wrong food for ever.
    func testAnImplausibleNumberIsNeverRemembered() {
        XCTAssertEqual(FoodItemBarcode.normalize("94011"), "", "a five-digit produce PLU")
        XCTAssertEqual(FoodItemBarcode.normalize("4011"), "")
        XCTAssertEqual(FoodItemBarcode.normalize(""), "")
        XCTAssertEqual(FoodItemBarcode.normalize("CRM CHS"), "")
        XCTAssertNil(FoodItemBarcode.make(digits: "94011"),
                     "a row that cannot be looked up must not exist")
    }

    /// `digits` and `matchKey` can never describe different numbers, which is the whole reason
    /// the factory exists — the predicate matches one and the row he reads shows the other.
    func testTheFactoryKeepsTheDigitsAndTheKeyTogether() throws {
        let row = try XCTUnwrap(FoodItemBarcode.make(
            digits: "012345678905", symbology: "org.gs1.UPC-A"
        ))
        XCTAssertEqual(row.digits, "012345678905", "read back as printed on the tin")
        XCTAssertEqual(row.matchKey, "00012345678905")
        XCTAssertEqual(row.matchKey, FoodItemBarcode.normalize(row.digits))
        XCTAssertEqual(row.symbology, "org.gs1.UPC-A")
        XCTAssertEqual(row.scanCount, 1)
        XCTAssertFalse(row.isAttached, "nothing is attached until he says what it is")
        XCTAssertNil(row.itemID)

        row.noteScan(at: row.lastScannedAt.addingTimeInterval(60))
        XCTAssertEqual(row.scanCount, 2)
    }

    /// The new model is registered, which is not a compile error to get wrong: a model missing
    /// from the schema array simply has no table, and the first fetch fails at runtime, on a
    /// device, with his real data in it.
    func testTheBarcodeModelIsInTheSchema() {
        // Compared by name rather than by metatype equality: `==` on two
        // `any PersistentModel.Type` values leans on an `Any.Type` overload, and nothing here
        // can ask a compiler whether that promotion happens.
        let registered = KitchenAidSchemaV1.models.map { String(describing: $0) }
        XCTAssertTrue(registered.contains("FoodItemBarcode"),
                      "FoodItemBarcode is not in KitchenAidSchemaV1.models: \(registered)")
    }
}
