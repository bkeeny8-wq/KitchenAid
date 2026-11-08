import XCTest
@testable import KitchenAid

/// `ShoppingListBuilder.build` — the algorithm, exercised with no `ModelContext`.
///
/// It takes three closures and two fetched values and returns a `Draft`. That split is the
/// whole reason this file can exist on a machine with no simulator: every rule below is
/// reachable without a store, a loader or a tweak overlay.
///
/// Three rounds of spec review found more defects here than anywhere else in the design, and
/// what is asserted below is those findings turned into something that fails: the grouping
/// key being the item ALONE, a recipe aggregating against ITSELF, the status ladder's rung
/// order, and the par-level pass folding into the line that already exists rather than adding
/// a second one.
///
/// **No `ModelContainer`.** `PlannedMeal`, `MealAttendance`, `MealRecipe`, `FoodItem` and
/// `StoreSection` are built in memory and only their properties are read, which is the
/// ordinary SwiftData pattern. Nothing here FETCHES — a fetch is the one thing that would
/// need a context, and it is the likeliest reason this file would fail to RUN rather than
/// fail an assertion.
final class ShoppingListBuilderTests: XCTestCase {

    // MARK: - Shipped values these stand-ins mirror
    //
    // A test whose stand-in disagrees with the shipped data goes green while the shipping
    // behaviour is the reverse of what it claims to protect (code review 01 item 9). So every
    // number below is quoted from `KitchenAid/Resources/ingredients.json` or from
    // `KitchenAid/Resources/Recipes/ny-strip-crostini-with-creamed-horseradish-spinach.json`,
    // and anything that is NOT in a shipped file says so at its use site.

    /// `ingredients.json`'s `aisleOrder`, verbatim and in order. Passed in rather than copied
    /// into the builder for exactly this reason: one list, and the test uses the same one the
    /// app does.
    private static let aisleOrder = [
        "Produce", "Bakery", "Butcher", "Seafood", "Dairy", "Dry goods", "Canned",
        "Condiments", "Spices", "Baking", "Nuts", "Beverages", "Frozen"
    ]

    // MARK: - Stand-in items

    /// Minted the way `FoodItemResolver.insert` mints one from a template: the catalogue's
    /// `name`, `staple`, `gramsPerCup` and the `StoreSection` for its `aisle`.
    ///
    /// `preferred` is NOT the entry's `dimension`, and copying that is the mistake this
    /// parameter name exists to stop. `FoodItemResolver.preferredDimension(for:)` takes the
    /// BAKING unit's dimension where the entry ships one, then the entry's own if it is mass
    /// or volume, and `.mass` otherwise — so butter, which ships `"dimension": "volume"` and
    /// `"bakingUnit": "g"`, is minted as MASS, and garlic, which ships `count`, is minted as
    /// mass too because a count is not a side a collapse can land on.
    ///
    /// No assertion in this file turns on it — the collapse only runs on an item that has a
    /// density AND both a volume and a mass requirement, which none of these builds produces
    /// — but a stand-in that quietly disagreed with the mint is how a test goes green while
    /// the shipping behaviour is the reverse of what it claims to protect.
    private func item(
        catalogName: String,
        aisle: String,
        preferred: MeasureDimension,
        staple: Bool,
        gramsPerCup: Rational? = nil
    ) -> FoodItem {
        let food = FoodItem(
            catalogName: catalogName,
            trackingModeRaw: staple
                ? StockTrackingMode.staple.rawValue
                : StockTrackingMode.tracked.rawValue,
            preferredDimensionRaw: preferred.rawValue
        )
        // `setName` writes `name` AND `matchKey`, which is what the resolver stand-in below
        // looks rows up by. Assigning `name` alone leaves the key empty and nothing resolves.
        food.setName(catalogName)
        // Both density fields through the one writer that cannot leave the pair half-written.
        food.setDensity(gramsPerCup)
        food.defaultSection = StoreSection.seeded(
            aisle: aisle, sortIndex: Self.aisleOrder.firstIndex(of: aisle) ?? 0
        )
        return food
    }

    /// `{"name": "butter", "aisle": "Dairy", "dimension": "volume", "bakingUnit": "g",
    /// "gramsPerCup": 227, "staple": false}` — so `.mass`, off the baking unit.
    private func butter() -> FoodItem {
        item(catalogName: "butter", aisle: "Dairy", preferred: .mass,
             staple: false, gramsPerCup: Rational(227))
    }

    /// `{"name": "kosher salt", "aisle": "Spices", "dimension": "volume",
    /// "gramsPerCup": null, "staple": true}`.
    ///
    /// Both halves matter and neither is incidental: it is a STAPLE, so it is diverted to the
    /// footer, and it ships NO density, so a volume and a mass requirement for it cannot
    /// collapse. That combination is what makes the staple/bridge rung order below reachable
    /// on real data.
    private func kosherSalt() -> FoodItem {
        item(catalogName: "kosher salt", aisle: "Spices", preferred: .volume, staple: true)
    }

    /// `{"name": "parmesan", "aisle": "Dairy", "dimension": "volume", "gramsPerCup": 100,
    /// "staple": false}`. The catalogue's name is lower-case; the fixture's line reads
    /// "Parmesan", and the row is named from the TEMPLATE.
    private func parmesan() -> FoodItem {
        item(catalogName: "parmesan", aisle: "Dairy", preferred: .volume,
             staple: false, gramsPerCup: Rational(100))
    }

    /// `{"name": "garlic", "aisle": "Produce", "dimension": "count", "unit": "clove",
    /// "bakingUnit": null, "gramsPerCup": null, "staple": false}` — minted `.mass`, because
    /// `count` is not a dimension a collapse can land on.
    private func garlic() -> FoodItem {
        item(catalogName: "garlic", aisle: "Produce", preferred: .mass, staple: false)
    }

    /// `{"name": "olive oil", "aisle": "Condiments", "dimension": "volume",
    /// "gramsPerCup": 216, "staple": true}`.
    private func oliveOil() -> FoodItem {
        item(catalogName: "olive oil", aisle: "Condiments", preferred: .volume,
             staple: true, gramsPerCup: Rational(216))
    }

    // MARK: - Stand-in content

    private func ingredient(
        _ lineID: String,
        _ displayName: String,
        _ amount: Rational,
        _ unitCode: String,
        _ dimension: MeasureDimension
    ) -> IngredientLine {
        var written = IngredientLine(lineID: lineID, displayName: displayName)
        written.amount = amount
        written.unitCode = unitCode
        written.dimension = dimension
        return written
    }

    /// The fixture's two butter lines and two kosher-salt lines, in the components and the
    /// order the bundled JSON holds them: `kosher-salt-1` (1 tsp) and `butter-1` (1 tbsp) in
    /// "Crostini and steak", `butter-2` (1 tbsp) and `kosher-salt-2` (1/4 tsp) in "Creamed
    /// horseradish spinach".
    ///
    /// The other twelve lines are left out so that `lines.count == 2` means something: two
    /// ingredients across two components reaching two lines is the claim.
    ///
    /// `servings` is 4 — "Makes: 12 crostini (serves 4)" — and `catalogName` is empty on
    /// every line, because `scripts/import_recipe.py` does not write one; resolution is by
    /// display name, which is what the builder's `resolveItem` closure receives.
    private func crostini() -> Recipe {
        var recipe = Recipe(
            id: "ny-strip-crostini-with-creamed-horseradish-spinach",
            title: "NY Strip Crostini with Creamed Horseradish Spinach"
        )
        recipe.servingsNumerator = 4
        recipe.servingsDenominator = 1
        recipe.components = [
            RecipeComponent(title: "Crostini and steak", lines: [
                ingredient("kosher-salt-1", "kosher salt", .one, "tsp", .volume),
                ingredient("butter-1", "butter", .one, "tbsp", .volume)
            ]),
            RecipeComponent(title: "Creamed horseradish spinach", lines: [
                ingredient("butter-2", "butter", .one, "tbsp", .volume),
                ingredient("kosher-salt-2", "kosher salt", Rational(1, 4), "tsp", .volume)
            ])
        ]
        return recipe
    }

    // MARK: - Driving the builder

    /// Four full portions against a recipe serving 4, so the scale is exactly 1 and every
    /// number below is the document's own. A `.planned`, `.recipe`, dinner meal — the only
    /// combination `contributesToShopping` admits.
    private func dinner(
        recipeID: String,
        title: String,
        portions: Int = 4,
        status: PlanStatus = .planned,
        kind: MealEntryKind = .recipe
    ) -> PlannedMeal {
        let planned = PlannedMeal()
        planned.setStatus(status)
        planned.setKind(kind)
        planned.setSlot(.dinner)
        var rows: [MealAttendance] = []
        for index in 0..<portions {
            // The snapshot defaults to 1/1, a full portion, and `.attending` consumes it.
            let row = MealAttendance(eaterNameSnapshot: "Eater \(index + 1)")
            row.meal = planned
            rows.append(row)
        }
        // Assigned as WHOLE arrays after the child side, not appended to: setting one end of
        // a SwiftData relationship may populate the other, and an append would then list a
        // dish twice and double every contribution it makes.
        planned.attendance = rows
        let dish = MealRecipe(recipeID: recipeID, recipeTitleSnapshot: title)
        dish.meal = planned
        planned.mealRecipes = [dish]
        return planned
    }

    /// The exact-`matchKey` step of `FoodItemResolver.findOrCreate`, which is all these lines
    /// need: no aliases, no catalogue fallback, no mint. It applies the same precedence the
    /// content type does — `IngredientLine.matchKey` is the catalogue name when there is one
    /// and the display name otherwise — because a resolver that keyed on something else would
    /// make every line below resolve for a reason the app does not share.
    private func resolver(_ items: [FoodItem]) -> (String, String) -> FoodItem? {
        var table: [String: FoodItem] = [:]
        for food in items { table[food.matchKey] = food }
        return { catalogName, displayName in
            let key = NameNormalizer.matchKey(catalogName.isEmpty ? displayName : catalogName)
            return table[key]
        }
    }

    /// Inventory is returned EMPTY throughout. Subtraction, the density bridge on the have
    /// side and the negative-stock clamp are `QuantityMathTests`' subject and are asserted
    /// there against `QuantityMath.subtract` directly; what this file is for is the rules
    /// `build` itself owns.
    private func draft(
        meals: [PlannedMeal],
        recipes: [Recipe],
        items: [FoodItem],
        parLevelShortfalls: [(FoodItem, QuantitySubtotal)] = [],
        includeStaples: Bool = false
    ) -> ShoppingListBuilder.Draft {
        var byID: [String: ResolvedRecipe] = [:]
        for recipe in recipes { byID[recipe.id] = ResolvedRecipe(recipe: recipe) }
        return ShoppingListBuilder.build(
            meals: meals,
            resolveRecipe: { byID[$0] },
            resolveItem: resolver(items),
            inventoryLevel: { _, _ in (subtotals: [], flags: []) },
            parLevelShortfalls: parLevelShortfalls,
            aisleOrder: Self.aisleOrder,
            options: ShoppingListBuilder.Options(
                range: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 604_800),
                includeStaples: includeStaples
            )
        )
    }

    private func draftLine(
        _ built: ShoppingListBuilder.Draft, for item: FoodItem
    ) -> ShoppingListBuilder.DraftLine? {
        built.lines.first { $0.foodItemID == item.id }
    }

    // MARK: - A recipe aggregates against itself

    /// `CLAUDE.md`'s named counterintuitive case. Butter is 1 tbsp in "Crostini and steak"
    /// and 1 tbsp in "Creamed horseradish spinach", so ONE planned meal of ONE recipe must
    /// already reach one line of 2 tbsp.
    ///
    /// The grouping key is the `FoodItem` and never the recipe or the component, so an
    /// implementation that de-duplicates only ACROSS recipes gives two lines of 1 tbsp here —
    /// which is what the assertion on `lines.count` is for. The provenance is kept per
    /// contribution, which is how "why is this 2 tbsp" gets answered, so both sources survive
    /// on the one line with their own component paths.
    func testButterAggregatesAgainstItselfWithinOneRecipe() {
        let butterItem = butter()
        let saltItem = kosherSalt()
        let built = draft(
            meals: [dinner(recipeID: crostini().id, title: crostini().title)],
            recipes: [crostini()],
            items: [butterItem, saltItem]
        )

        XCTAssertEqual(built.mealCount, 1)
        XCTAssertEqual(built.adHocMealCount, 0)
        XCTAssertTrue(built.diagnostics.isEmpty, "\(built.diagnostics)")
        XCTAssertEqual(built.lines.count, 2, "two ingredients across two components")

        guard let butterLine = draftLine(built, for: butterItem) else {
            XCTFail("no butter line in \(built.lines.map(\.displayName))")
            return
        }
        XCTAssertEqual(butterLine.identity,
                       ShoppingListBuilder.ItemIdentity.cataloged(butterItem.id))
        XCTAssertEqual(butterLine.requested.count, 1, "one volume bucket, not one per component")
        // 2 tbsp, in the volume base unit, exactly.
        XCTAssertEqual(butterLine.requested[0].base,
                       Rational(2) * UnitCatalog.tablespoon.baseFactor)
        XCTAssertEqual(butterLine.toBuy.count, 1)
        XCTAssertEqual(butterLine.toBuy[0].base, Rational(2) * UnitCatalog.tablespoon.baseFactor)
        // `purchase` is a copy of `toBuy` in v1 — there is no pack to round toward — but it
        // is its own set of rows, and `InventoryLedger.receive` posts it.
        XCTAssertEqual(butterLine.purchase.count, 1)
        XCTAssertEqual(butterLine.purchase[0].base, butterLine.toBuy[0].base)

        XCTAssertEqual(butterLine.sources.count, 2, "both components keep their provenance")
        let paths = Set(butterLine.sources.map(\.componentPath))
        XCTAssertEqual(paths.count, 2, "both sources came from the same component: \(paths)")
        XCTAssertEqual(Set(butterLine.sources.map(\.lineID)),
                       Set(["butter-1", "butter-2"]))
        for source in butterLine.sources {
            // One tablespoon each, and the per-source contribution is what the provenance row
            // prints. A nil here is the shape review 03 found with no writer.
            XCTAssertEqual(source.contribution?.base, UnitCatalog.tablespoon.baseFactor)
        }
    }

    /// The other self-aggregation in the same recipe, and the staple path in one: kosher salt
    /// is 1 tsp in the steak group and 1/4 tsp in the spinach, so the line is exactly 5/4 tsp
    /// — not 1.25, and not two lines.
    ///
    /// Then, because `kosher salt` ships `staple: true`, that line is DIVERTED to the footer:
    /// `.staple`, `.assumedOnHand`, and no quantity to buy. The aggregation still ran in full
    /// and the footer prints it, which is why `requested` is asserted after `toBuy` is
    /// asserted empty — a quantity to buy beside "assumed on hand" is the footer
    /// contradicting itself, and a non-empty `purchase` would restock something never bought.
    func testKosherSaltMergesAndIsDivertedToTheFooterWithNoQuantity() {
        let saltItem = kosherSalt()
        let built = draft(
            meals: [dinner(recipeID: crostini().id, title: crostini().title)],
            recipes: [crostini()],
            items: [butter(), saltItem]
        )

        guard let saltLine = draftLine(built, for: saltItem) else {
            XCTFail("no kosher salt line in \(built.lines.map(\.displayName))")
            return
        }
        XCTAssertEqual(saltLine.status, .staple)
        XCTAssertTrue(saltLine.flags.contains(.assumedOnHand))
        XCTAssertTrue(saltLine.toBuy.isEmpty, "a staple carries no quantity to buy")
        XCTAssertTrue(saltLine.purchase.isEmpty)
        XCTAssertFalse(saltLine.isCovered,
                       "nothing was subtracted, so this is not `Already have`")

        // And the arithmetic behind the footer, exact.
        XCTAssertEqual(saltLine.requested.count, 1)
        XCTAssertEqual(saltLine.requested[0].base, Rational(5, 4),
                       "1 tsp + 1/4 tsp, in the tsp base unit")
        XCTAssertEqual(saltLine.sources.count, 2)

        // With staples asked for, the same build puts it on the list proper.
        let wanted = draft(
            meals: [dinner(recipeID: crostini().id, title: crostini().title)],
            recipes: [crostini()],
            items: [butter(), kosherSalt()],
            includeStaples: true
        )
        guard let onTheList = wanted.lines.first(where: { $0.displayName == "kosher salt" }) else {
            XCTFail("no kosher salt line in \(wanted.lines.map(\.displayName))")
            return
        }
        XCTAssertEqual(onTheList.status, .needed)
        XCTAssertFalse(onTheList.flags.contains(.assumedOnHand))
        XCTAssertEqual(onTheList.toBuy.count, 1)
        XCTAssertEqual(onTheList.toBuy[0].base, Rational(5, 4))
    }

    // MARK: - One line per FoodItem, N subtotals inside it

    /// Lines are grouped by item ALONE, so two count nouns for one ingredient are two
    /// SUBTOTALS on one line and never two lines.
    ///
    /// Grouping by item AND dimension is the defect: two lines cannot be added to one another
    /// — only two subtotals on one line can — so the volume/mass collapse became unreachable
    /// on the requested side. Counts are the sharpest version of it, because nothing converts
    /// a clove into a head: 2 cloves and 1 head must stay 2 and 1, and the value that would
    /// make this fail is a single bucket of 3.
    ///
    /// The fixture asks for `2 clove` garlic. The head is NOT in a bundled file — it is the
    /// second recipe in the same week that writes garlic the other way, which is the case a
    /// weekly list exists to merge.
    func testOneLinePerItemWithASubtotalPerCountNoun() {
        var byClove = Recipe(id: "crostini-garlic", title: "Crostini")
        byClove.servingsNumerator = 4
        byClove.components = [RecipeComponent(title: "Crostini and steak", lines: [
            ingredient("garlic-1", "garlic", Rational(2), "clove", .count)
        ])]

        var byHead = Recipe(id: "roast-garlic", title: "Roasted Garlic")
        byHead.servingsNumerator = 4
        byHead.components = [RecipeComponent(lines: [
            ingredient("garlic-1", "garlic", .one, "head", .count)
        ])]

        let garlicItem = garlic()
        let built = draft(
            meals: [
                dinner(recipeID: byClove.id, title: byClove.title),
                dinner(recipeID: byHead.id, title: byHead.title)
            ],
            recipes: [byClove, byHead],
            items: [garlicItem]
        )

        XCTAssertEqual(built.mealCount, 2)
        XCTAssertEqual(built.lines.count, 1, "one FoodItem is one line")
        guard let garlicLine = draftLine(built, for: garlicItem) else {
            XCTFail("no garlic line")
            return
        }
        XCTAssertEqual(garlicLine.requested.count, 2, "clove and head are separate buckets")
        let byKey = Dictionary(
            uniqueKeysWithValues: garlicLine.requested.map { ($0.dimensionKey, $0.base) }
        )
        XCTAssertEqual(byKey["count:clove"], Rational(2))
        XCTAssertEqual(byKey["count:head"], Rational.one)
        XCTAssertNil(byKey["count:each"], "a count noun was folded into another")
        // Counts are never a bridge case: nothing converts a clove into a head, and
        // pretending otherwise is purchase-unit rounding, which is cut.
        XCTAssertFalse(garlicLine.flags.contains(.needsBridge))
        XCTAssertEqual(garlicLine.status, .needed)
    }

    // MARK: - The status ladder

    /// `status(...)` is the ONE writer of `LineStatus`, and the rung order is the decision.
    ///
    /// Driven directly, because each rung is "which of two TRUE things does this line say" —
    /// and the only way to assert a precedence is to make both inputs true at once. Every
    /// call below has at least two true flags, so a ladder reordered by one rung changes an
    /// answer here.
    func testTheStatusLadderRungOrder() {
        // 1 outranks 2: an unmatched item has no density to fill in, so the bridge question
        // cannot be answered yet.
        XCTAssertEqual(
            ShoppingListBuilder.status(
                isUnresolved: true, needsBridge: true, isStapleDiverted: true,
                nothingLeftToBuy: true, didReduce: true
            ),
            .unresolvedItem
        )
        // 2 outranks 3. THE rung review 03 caught: a staple whose density is missing keeps
        // its one-tap "1 cup = ___ g" fix instead of disappearing into a collapsed footer
        // with the fix inside it.
        XCTAssertEqual(
            ShoppingListBuilder.status(
                isUnresolved: false, needsBridge: true, isStapleDiverted: true,
                nothingLeftToBuy: false, didReduce: false
            ),
            .needsBridge
        )
        // 3 outranks 4: "assumed on hand" is a stronger statement than "you have enough",
        // because a staple carries no tracked quantity for anything to have been subtracted
        // from.
        XCTAssertEqual(
            ShoppingListBuilder.status(
                isUnresolved: false, needsBridge: false, isStapleDiverted: true,
                nothingLeftToBuy: true, didReduce: true
            ),
            .staple
        )
        // 4 outranks 5: fully covered is covered, however much was reduced to get there.
        XCTAssertEqual(
            ShoppingListBuilder.status(
                isUnresolved: false, needsBridge: false, isStapleDiverted: false,
                nothingLeftToBuy: true, didReduce: true
            ),
            .haveEnough
        )
        // 5 is a different fact from 6, which is why `subtract` returns `didReduce` at all.
        XCTAssertEqual(
            ShoppingListBuilder.status(
                isUnresolved: false, needsBridge: false, isStapleDiverted: false,
                nothingLeftToBuy: false, didReduce: true
            ),
            .partiallyHave
        )
        XCTAssertEqual(
            ShoppingListBuilder.status(
                isUnresolved: false, needsBridge: false, isStapleDiverted: false,
                nothingLeftToBuy: false, didReduce: false
            ),
            .needed
        )
    }

    /// The same rung, reached through `build` on real shipped flags rather than by calling
    /// `status` directly — because the defect was not in the ladder, it was in a staple
    /// diversion running as a LATER PASS that overrode whatever the ladder had decided.
    ///
    /// `all-purpose flour` is the entry review 03 named, and on shipped data it is no longer
    /// the reachable case: it ships `staple: true` AND `gramsPerCup: 120`, so its volume and
    /// mass requirements collapse on the density and there is no bridge to swallow.
    /// `kosher salt` ships `staple: true` and `gramsPerCup: null` — Diamond Crystal is
    /// ~142 g/cup and Morton ~288, a factor of two from the same words on the box — so it is
    /// the staple where this rung order decides something. No bundled recipe asks for salt by
    /// weight today; the gram line below is the baking recipe that would.
    func testAStapleMissingItsDensityKeepsTheBridgeWarning() {
        var baking = Recipe(id: "salt-by-weight", title: "Bread")
        baking.servingsNumerator = 4
        baking.components = [RecipeComponent(lines: [
            ingredient("kosher-salt-1", "kosher salt", .one, "tsp", .volume),
            ingredient("kosher-salt-2", "kosher salt", Rational(10), "g", .mass)
        ])]

        let saltItem = kosherSalt()
        XCTAssertNil(saltItem.gramsPerCup, "the shipped catalogue ships none")
        XCTAssertEqual(saltItem.trackingMode, .staple, "and ships `staple: true`")

        let built = draft(
            meals: [dinner(recipeID: baking.id, title: baking.title)],
            recipes: [baking],
            items: [saltItem]
        )
        guard let saltLine = draftLine(built, for: saltItem) else {
            XCTFail("no kosher salt line")
            return
        }
        XCTAssertEqual(saltLine.requested.count, 2, "no density, so the two buckets survive")
        XCTAssertTrue(saltLine.flags.contains(.needsBridge))
        XCTAssertEqual(saltLine.status, .needsBridge, "the staple rung swallowed it")
        XCTAssertFalse(saltLine.flags.contains(.assumedOnHand))
        XCTAssertFalse(saltLine.toBuy.isEmpty,
                       "an emptied toBuy means the diversion ran anyway")
    }

    // MARK: - Par levels fold into the line the week already asked for

    /// A par-level shortfall for an item the week already wants MERGES into that line.
    ///
    /// Not tidiness. The staple rung deliberately leaves a staple with a par shortfall on the
    /// list as an ordinary line, and kosher salt — the fixture's own staple — is the likeliest
    /// thing in this kitchen to carry a par level. An unconditional second pass therefore
    /// gives one `FoodItem` two lines on one list, which also breaks the regenerate
    /// carry-over: that matches on identity, and two lines sharing one make it ambiguous, so a
    /// line he checked off comes back.
    func testAParLevelShortfallMergesIntoTheExistingLine() {
        let saltItem = kosherSalt()
        let shortfall = QuantitySubtotal(
            dimensionKey: MeasureDimension.volume.rawValue,
            base: .one,
            preferredUnit: UnitCatalog.teaspoon
        )
        let built = draft(
            meals: [dinner(recipeID: crostini().id, title: crostini().title)],
            recipes: [crostini()],
            items: [butter(), saltItem],
            parLevelShortfalls: [(saltItem, shortfall)]
        )

        XCTAssertEqual(built.lines.filter { $0.foodItemID == saltItem.id }.count, 1,
                       "the shortfall added a second line")
        guard let saltLine = draftLine(built, for: saltItem) else {
            XCTFail("no kosher salt line")
            return
        }
        XCTAssertTrue(saltLine.flags.contains(.parLevel))
        // A par shortfall takes a staple OFF the footer, so there is a quantity to buy.
        XCTAssertFalse(saltLine.flags.contains(.assumedOnHand))
        XCTAssertEqual(saltLine.status, .needed)
        XCTAssertEqual(saltLine.requested.count, 1)
        XCTAssertEqual(saltLine.requested[0].base, Rational(9, 4),
                       "1 tsp + 1/4 tsp of recipe plus 1 tsp of par")
        XCTAssertEqual(saltLine.sources.count, 3, "two components and the par rule")
        XCTAssertEqual(saltLine.sources.filter { $0.kind == LineSourceKind.parLevel }.count, 1)
    }

    /// And a shortfall for something no meal asked for still reaches the list, on a line of
    /// its own. A staple reaches the list by a RULE, not only when a Bool is flipped by hand.
    func testAParLevelShortfallAloneCreatesItsOwnLine() {
        let oilItem = oliveOil()
        let shortfall = QuantitySubtotal(
            dimensionKey: MeasureDimension.volume.rawValue,
            base: Rational(2) * UnitCatalog.tablespoon.baseFactor,
            preferredUnit: UnitCatalog.tablespoon
        )
        let built = draft(
            meals: [dinner(recipeID: crostini().id, title: crostini().title)],
            recipes: [crostini()],
            items: [butter(), kosherSalt(), oilItem],
            parLevelShortfalls: [(oilItem, shortfall)]
        )

        XCTAssertEqual(built.lines.count, 3, "butter, kosher salt, and the par-level oil")
        guard let oilLine = draftLine(built, for: oilItem) else {
            XCTFail("no olive oil line in \(built.lines.map(\.displayName))")
            return
        }
        XCTAssertEqual(oilLine.sources.count, 1)
        XCTAssertEqual(oilLine.sources[0].kind, LineSourceKind.parLevel)
        XCTAssertTrue(oilLine.flags.contains(.parLevel))
        XCTAssertFalse(oilLine.flags.contains(.assumedOnHand), "olive oil ships `staple: true`")
        XCTAssertEqual(oilLine.requested[0].base,
                       Rational(2) * UnitCatalog.tablespoon.baseFactor)
    }

    // MARK: - Meals that contribute nothing

    /// `contributesToShopping` drops a meal by KIND and by STATUS, and either one contributing
    /// would be a double-shop.
    ///
    /// `.cooked` is the expensive one: cooking already depleted inventory, so collecting it
    /// again shops for a meal already made — the eleventh defect code review 01 found, after
    /// the Cook link dropped the dish identity and no meal ever reached `.cooked` at all.
    /// `.leftovers` is Tuesday reheating Sunday's ragù, which is the single largest source of
    /// over-buying in a weekly plan.
    ///
    /// The last build is the control. Without it this test passes just as well against a
    /// resolver that matches nothing, which is a test that asserts the wiring is broken.
    func testAMealThatDoesNotContributeToShoppingContributesNothing() {
        let recipes = [crostini()]
        let items = [butter(), kosherSalt()]

        for (label, meal) in [
            ("cooked", dinner(recipeID: crostini().id, title: crostini().title,
                              status: .cooked)),
            ("leftovers", dinner(recipeID: crostini().id, title: crostini().title,
                                 kind: .leftovers))
        ] {
            let built = draft(meals: [meal], recipes: recipes, items: items)
            XCTAssertEqual(built.mealCount, 0, label)
            XCTAssertTrue(built.lines.isEmpty, "\(label): \(built.lines.map(\.displayName))")
            XCTAssertTrue(built.sectionOrder.isEmpty, label)
        }

        // A meal that DOES contribute, through the same wiring.
        let control = draft(
            meals: [dinner(recipeID: crostini().id, title: crostini().title)],
            recipes: recipes,
            items: items
        )
        XCTAssertEqual(control.mealCount, 1)
        XCTAssertEqual(control.lines.count, 2)
    }

    /// Also dropped by the slot filter rather than by the kind: `.prep` is excluded from the
    /// shoppable defaults because its ingredients belong to the meal it prepares for, and
    /// collecting both buys the steak twice.
    func testAPrepSlotIsNotShoppedByDefault() {
        let meal = dinner(recipeID: crostini().id, title: crostini().title)
        meal.setSlot(.prep)
        XCTAssertTrue(meal.contributesToShopping, "it is a real, planned recipe meal")
        XCTAssertFalse(MealSlot.shoppableDefaults.contains(.prep))

        let built = draft(meals: [meal], recipes: [crostini()], items: [butter(), kosherSalt()])
        XCTAssertEqual(built.mealCount, 0)
        XCTAssertTrue(built.lines.isEmpty)
    }

    // MARK: - Where a line lands

    /// Sections follow the shipped WALK order, and the position within a section is WRITTEN.
    ///
    /// Produce, Dairy, Spices is `aisleOrder`'s order; alphabetically it would be Dairy,
    /// Produce, Spices, so a build that lost the walk order fails here. And review 03 found
    /// "alphabetical within a section" specified with no writer anywhere, so every line tied
    /// at 0 — the two Dairy lines are what catch that, since both would read 0.
    func testSectionsFollowTheWalkOrderAndPositionsAreWritten() {
        var spread = Recipe(id: "crostini-spread", title: "Crostini")
        spread.servingsNumerator = 4
        spread.components = [RecipeComponent(title: "Crostini and steak", lines: [
            ingredient("garlic-1", "garlic", Rational(2), "clove", .count),
            ingredient("butter-1", "butter", .one, "tbsp", .volume),
            ingredient("parmesan-1", "Parmesan", Rational(2), "tbsp", .volume),
            ingredient("kosher-salt-1", "kosher salt", .one, "tsp", .volume)
        ])]

        let built = draft(
            meals: [dinner(recipeID: spread.id, title: spread.title)],
            recipes: [spread],
            items: [garlic(), butter(), parmesan(), kosherSalt()]
        )
        XCTAssertEqual(built.sectionOrder, ["Produce", "Dairy", "Spices"])

        let dairy = built.lines.filter { $0.sectionName == "Dairy" }
        XCTAssertEqual(dairy.count, 2, "butter and parmesan")
        XCTAssertEqual(dairy.map(\.displayName), ["butter", "parmesan"],
                       "case-insensitive, numerically aware name order")
        XCTAssertEqual(dairy.map(\.sortIndex), [0, 1], "both lines tied at 0")

        let produce = built.lines.filter { $0.sectionName == "Produce" }
        XCTAssertEqual(produce.map(\.sortIndex), [0], "positions restart per section")
        XCTAssertEqual(built.lines.first?.sectionName, "Produce")
    }

    /// A line that matched no `FoodItem` is reported once and pinned, not dropped.
    ///
    /// The turkey and the gravy ship four of these — "Fat", "Stock", "Pan base", "Vegetable
    /// bed" are column labels rather than ingredient names — and Brandon chose to KEEP them
    /// flagged rather than resolve or exclude them (`docs/recipe-overrides.json`). So this is
    /// shipped behaviour and not a hypothetical: the line reaches the list, under
    /// `.unresolvedItem`, with one diagnostic and not one per occurrence.
    func testAnUnmatchedLineIsPinnedAndReportedOnce() {
        var gravy = Recipe(id: "turkey-gravy", title: "Turkey Gravy")
        gravy.servingsNumerator = 4
        gravy.components = [RecipeComponent(title: "Gravy", lines: [
            ingredient("pan-base-1", "Pan base", .one, "cup", .volume),
            ingredient("pan-base-2", "Pan base", .one, "cup", .volume)
        ])]

        let built = draft(
            meals: [dinner(recipeID: gravy.id, title: gravy.title)],
            recipes: [gravy],
            items: [butter()]
        )
        XCTAssertEqual(built.lines.count, 1, "two occurrences of one unmatched name")
        guard let unmatched = built.lines.first else {
            XCTFail("the unmatched line was dropped")
            return
        }
        XCTAssertNil(unmatched.foodItemID)
        XCTAssertEqual(
            unmatched.identity,
            ShoppingListBuilder.ItemIdentity.freeText(NameNormalizer.matchKey("Pan base"))
        )
        XCTAssertEqual(unmatched.status, .unresolvedItem)
        XCTAssertTrue(unmatched.flags.contains(.unresolvedItem))
        XCTAssertEqual(unmatched.displayName, "Pan base", "the words the document used")
        XCTAssertEqual(unmatched.sectionName, ShoppingListBuilder.unsortedSectionName)
        XCTAssertEqual(built.diagnostics.count, 1,
                       "once per line, not once per contribution: \(built.diagnostics)")
    }

    // MARK: - The scale reaches every line the dish produced

    /// Every scaling note is a badge on every line the dish touched, never swallowed.
    ///
    /// Eight full portions against the fixture's four is ×2, so the butter is 4 tbsp and
    /// nothing is badged — a badge on a number nothing assumed teaches him to ignore badges.
    /// Then the same build with nobody assigned: the scale falls back to the default diner
    /// count and `.noAttendance` has to be on BOTH lines AND on every source inside them,
    /// because the note belongs to the dish and the list does not draw the meal.
    func testTheDishScaleAndItsNotesReachEveryLine() {
        let doubled = dinner(recipeID: crostini().id, title: crostini().title, portions: 8)
        let built = draft(meals: [doubled], recipes: [crostini()], items: [butter(), kosherSalt()])
        guard let butterLine = built.lines.first(where: { $0.displayName == "butter" }) else {
            XCTFail("no butter line")
            return
        }
        XCTAssertEqual(butterLine.requested[0].base,
                       Rational(4) * UnitCatalog.tablespoon.baseFactor,
                       "2 tbsp at a scale of 2")
        XCTAssertTrue(butterLine.flags.isEmpty, "\(butterLine.flags)")

        let nobody = dinner(recipeID: crostini().id, title: crostini().title, portions: 0)
        let fallback = draft(
            meals: [nobody], recipes: [crostini()], items: [butter(), kosherSalt()]
        )
        XCTAssertEqual(fallback.lines.count, 2)
        for produced in fallback.lines {
            XCTAssertTrue(produced.flags.contains(.noAttendance), produced.displayName)
            for source in produced.sources {
                XCTAssertTrue(source.notes.contains(.noAttendance), source.lineID)
            }
        }
        // The default diner count is 2 against a recipe serving 4, so the butter halves.
        guard let halved = fallback.lines.first(where: { $0.displayName == "butter" }) else {
            XCTFail("no butter line")
            return
        }
        XCTAssertEqual(halved.requested[0].base, UnitCatalog.tablespoon.baseFactor,
                       "2 tbsp at a scale of 1/2 is 1 tbsp")
    }
}
