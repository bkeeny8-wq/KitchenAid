import Foundation

/// The algorithm. A pure namespace: **no fetches, no mutation, no SwiftUI.**
///
/// It reads values and closures the caller already holds and returns a `Draft`; persistence is
/// `ShoppingListStore`. That split is the whole testability story — every rule below can be
/// exercised with no `ModelContainer`.
///
/// Three rounds of spec review found more defects here than anywhere else in the design, and
/// each one is answered by a named thing in this file rather than by prose:
///
/// 1. **One line per `FoodItem`, N subtotals inside it.** Lines are grouped by `ItemIdentity`
///    ALONE. Grouping by item AND dimension split flour-by-the-cup from flour-by-the-gram into
///    two lines, and two lines cannot be added to one another — only two subtotals on one line
///    can — so the volume↔mass collapse became unreachable on the requested side.
/// 2. **A recipe aggregates against itself.** One planned meal of the fixture already merges
///    butter's `1 tbsp + 1 tbsp` across two components and kosher salt's `1 tsp + 1/4 tsp`,
///    because the grouping key is the item and never the recipe or the component.
/// 3. The author's own `altAmount` beats a density conversion — see `contribution(for:item:)`.
/// 4. The HAVE side is bridged too, by `QuantityMath.subtract` calling `bridgeHave` first.
/// 5. `status(...)` is the **one** writer of `LineStatus`, and its ladder is commented.
/// 6. The staple diversion is a RUNG OF THAT LADDER rather than a later pass, so it can no
///    longer swallow a bridge warning.
enum ShoppingListBuilder {

    // MARK: - Identity

    /// What makes two contributions the same shopping line.
    ///
    /// Declared here rather than in a `Models/Support/MergeKey.swift` as ARCHITECTURE.md §1
    /// still says, for two reasons: nothing outside the builder and its store needs it, and the
    /// `MergeKey` that file was also to own has no reader at all — `QuantitySubtotal` carries
    /// `dimensionKey`, and that IS the bucket key inside a line. A second type naming the same
    /// bucket is a second thing that can disagree. The Swift wins (`CLAUDE.md`).
    enum ItemIdentity: Hashable, Sendable {
        case cataloged(UUID)
        /// `NameNormalizer.matchKey` of the display name, for a line that matched no item.
        case freeText(String)
    }

    /// The ONE derivation of a line's identity, called by the builder when it groups and by
    /// `ShoppingListStore` when it matches a stored line back to a regenerated one.
    ///
    /// Two implementations of this rule is how a checked-off line comes back: the regenerate
    /// carry-over matches on it, so the store deriving `.freeText("kosher salt")` where the
    /// builder derived `.freeText("kosher-salt")` loses the match in silence.
    static func identity(for item: FoodItem?, displayName: String) -> ItemIdentity {
        if let item = item { return .cataloged(item.id) }
        let key = NameNormalizer.matchKey(displayName)
        return .freeText(key.isEmpty ? displayName : key)
    }

    // MARK: - Options

    /// Everything that changes what a build produces, and the whole of what `ShoppingList`
    /// freezes (minus the range, the slots and the expanded ids, which it stores as four
    /// date/key fields and two blobs, and minus `now`, which is `generatedAt`).
    ///
    /// No explicit `init`, so the memberwise one survives: `range` has no sensible default and
    /// everything else does, which is exactly the initializer this wants.
    struct Options: Hashable, Sendable {
        var range: DateInterval
        var slots: Set<MealSlot> = MealSlot.shoppableDefaults
        var subtractInventory: Bool = true
        var countExpiredAsAvailable: Bool = false
        /// Excludes stock expiring before the END of the plan range from the on-hand total, so
        /// a yogurt that dies Tuesday does not cover Friday's recipe.
        var expiringGraceDays: Int = 0
        var includeStaples: Bool = false
        var includeOptionalLines: Bool = false
        /// Buy-or-make overrides for THIS run, by content `lineID`.
        var expandedLineIDs: Set<String> = []
        var maxExpansionDepth: Int = 4
        var unitSystem: UnitSystem = .us
        var defaultDinerCount: Int = 2
        var now: Date = .now

        // There is deliberately NO `roundToPurchaseUnits` and no `includeCoveredLines`.
        // Purchase-unit rounding is cut (`CLAUDE.md`) and a covered line is kept and collapsed
        // rather than removed, so both would be options nothing honours — and `ShoppingList`
        // freezes this struct, which means a flag with no reader ships inside the schema and
        // deleting it after the first build is a migration rather than an edit.

        /// The instant inventory is judged against: stock dying inside the grace days does not
        /// count toward a meal at the end of the range. The caller hands this to
        /// `InventoryLedger.level(of:in:includeExpired:asOf:graceEnd:)`, which is the only
        /// thing that can see a lot's date.
        var graceEnd: Date {
            guard expiringGraceDays != 0 else { return range.end }
            return range.end.addingTimeInterval(TimeInterval(expiringGraceDays) * 86_400)
        }
    }

    // MARK: - The draft

    /// Why a line exists, one row per contributing dish. He will ask.
    struct DraftSource: Sendable {
        var kind: LineSourceKind = .plannedMeal
        var mealID: UUID? = nil
        var mealDayKey: Int = 0
        var mealSlotRaw: String = ""
        var mealTitle: String = ""
        var recipeID: String = ""
        var recipeTitle: String = ""
        var lineID: String = ""
        var componentPath: String = ""
        var originalText: String = ""
        var scaledText: String = ""
        var scaleDescription: String = ""
        /// THIS source's own contribution. Per source and not only per line, because "why is
        /// this 2 tbsp" is answered by which of the components asked for what — and the fixture
        /// needs it on one recipe alone, where butter appears in two of them.
        var contribution: QuantitySubtotal? = nil
    }

    struct DraftLine: Sendable {
        var identity: ItemIdentity
        var foodItemID: UUID? = nil
        var displayName: String = ""
        var sectionName: String = ""
        var sectionSortIndex: Int = 0
        /// Position within the section. **Written, not left at 0.** Review 03 found
        /// "alphabetical within a section" specified with no writer anywhere, so every line tied
        /// at 0 and fell through to raw `String <` — Unicode-scalar order, which puts "Parmesan"
        /// before "butter". `ShoppingListLine.displayNamePrecedes` is the comparison, and this
        /// is where its result is recorded.
        var sortIndex: Int = 0
        var status: LineStatus = .needed
        var flags: Set<LineFlag> = []
        var unmeasuredNote: String = ""
        var requested: [QuantitySubtotal] = []
        var have: [QuantitySubtotal] = []
        var toBuy: [QuantitySubtotal] = []
        var purchase: [QuantitySubtotal] = []
        var sources: [DraftSource] = []
        var isCovered: Bool = false
    }

    struct Draft: Sendable {
        var lines: [DraftLine] = []        // already sectioned and sorted
        var diagnostics: [RecipeGraph.Diagnostic] = []
        var mealCount: Int = 0
        var adHocMealCount: Int = 0
        var sectionOrder: [String] = []
        /// The options this draft was built FROM, carried so `ShoppingListStore.materialize`
        /// cannot freeze a different set onto the list than the one that produced its numbers.
        /// A draft that cannot say what produced it makes the frozen options a guess, and the
        /// whole point of freezing them is that a list regenerated later under different
        /// preferences visibly differs from the one he shopped.
        var options: Options
    }

    // MARK: - Sections

    /// A line whose item has no `StoreSection` still has to land somewhere he will see it.
    static let unsortedSectionName = "Unsorted"
    /// After every aisle, by a margin wide enough that a section he invented himself sorts
    /// between the shipped walk order and this.
    static let unsortedSectionSortIndex = 1_000_000

    // MARK: - Build

    /// Steps 1–9, nothing persisted. The generation sheet calls this live as he toggles
    /// options: "32 items across 6 sections, 4 flagged".
    static func preview(
        meals: [PlannedMeal],
        resolveRecipe: (String) -> ResolvedRecipe?,
        resolveItem: (_ catalogName: String, _ displayName: String) -> FoodItem?,
        inventoryLevel: (FoodItem, Options) -> (subtotals: [QuantitySubtotal], flags: Set<LineFlag>),
        parLevelShortfalls: [(FoodItem, QuantitySubtotal)],
        aisleOrder: [String],
        options: Options
    ) -> Draft {
        build(
            meals: meals,
            resolveRecipe: resolveRecipe,
            resolveItem: resolveItem,
            inventoryLevel: inventoryLevel,
            parLevelShortfalls: parLevelShortfalls,
            aisleOrder: aisleOrder,
            options: options
        )
    }

    /// Identical to `preview`, named separately so the call sites read correctly.
    ///
    /// **Three closures and two fetched values**, and that is deliberate: the builder never
    /// reaches for a `ModelContext`, a `RecipeLoader` or a `TweakStore`.
    ///
    /// `inventoryLevel` returns FLAGS as well as subtotals because the ledger is the only thing
    /// that can see a lot's `expiresAt`: `.expiredStockIgnored` and `.expiringBeforeNeed` have
    /// no other possible writer, and a closure of `(FoodItem) -> [QuantitySubtotal]` receives no
    /// dates and could apply neither filter.
    ///
    /// `aisleOrder` is `IngredientCatalog.aisleOrder` — the walk order shipped inside
    /// `ingredients.json` — PASSED IN rather than copied into this file. A second copy of that
    /// list is a copy that silently stops matching the JSON the first time
    /// `build_catalogue.py` adds an aisle, and nothing in the Swift could catch it.
    static func build(
        meals: [PlannedMeal],
        resolveRecipe: (String) -> ResolvedRecipe?,
        resolveItem: (_ catalogName: String, _ displayName: String) -> FoodItem?,
        inventoryLevel: (FoodItem, Options) -> (subtotals: [QuantitySubtotal], flags: Set<LineFlag>),
        parLevelShortfalls: [(FoodItem, QuantitySubtotal)],
        aisleOrder: [String],
        options: Options
    ) -> Draft {
        var diagnostics: [RecipeGraph.Diagnostic] = []
        var flats: [RecipeGraph.FlatLine] = []
        var mealCount = 0
        var adHocMealCount = 0

        // MARK: Steps 1-3 - the meals, their scales, and the flattened lines

        for meal in meals {
            // ONE accessor, which drops by KIND rather than by a skipped flag: leftovers
            // (Tuesday reheating Sunday's ragu - the single largest source of over-buying in a
            // weekly plan), takeout, eating out, a bare note, a meal he skipped, and a meal
            // already `.cooked`, which depleted inventory when it was cooked and would
            // otherwise be shopped for a second time.
            guard meal.contributesToShopping, options.slots.contains(meal.slot) else { continue }
            mealCount += 1

            let dishes = meal.orderedMealRecipes
            if dishes.isEmpty {
                // Counted rather than dropped in silence, so the header can say "3 meals with
                // no recipe".
                adHocMealCount += 1
                continue
            }

            for dish in dishes {
                let found = resolveRecipe(dish.recipeID)
                // `MealScaling` takes the BUNDLED value: the scale depends on `servings` and
                // `batchGranularity`, neither of which an override can touch, so the overlay is
                // irrelevant here and the call says so.
                let scaling = MealScaling.scaling(
                    for: dish,
                    recipe: found?.recipe,
                    defaultDinerCount: options.defaultDinerCount
                )

                guard let resolved = found else {
                    // A content id is allowed to dangle - the thing on the other end is a file,
                    // not a row, and no delete rule can stop it - so the list reports it rather
                    // than quietly shopping for less.
                    diagnostics.append(.missingRecipe(
                        id: dish.recipeID, inRecipeTitle: meal.displayTitle
                    ))
                    continue
                }

                // `Recipe.servings` substitutes 1 for a non-positive stored value so the scale
                // neither explodes nor vanishes. This is the one place that can say it did,
                // because the substitution is invisible through the accessor.
                if resolved.recipe.servingsNumerator <= 0 {
                    diagnostics.append(.zeroServings(recipeTitle: resolved.title))
                }

                let provenance = RecipeGraph.Provenance(
                    mealID: meal.id,
                    mealDayKey: meal.dayKey,
                    mealSlotRaw: meal.slotRaw,
                    mealTitle: meal.displayTitle,
                    recipeTitle: resolved.title,
                    recipeID: resolved.id,
                    scaleDescription: scaling.description
                )

                var produced = RecipeGraph.flatten(
                    recipe: resolved,
                    scale: scaling.scale,
                    options: options,
                    provenance: provenance,
                    componentPath: [],
                    resolve: resolveRecipe,
                    visited: [],
                    depth: 0,
                    diagnostics: &diagnostics
                )

                // Every scaling note is surfaced as a badge on every affected shopping line and
                // never swallowed, and the note is a property of the DISH - so it lands on each
                // line the dish produced rather than on the meal, which the list does not draw.
                if !scaling.notes.isEmpty {
                    for index in produced.indices {
                        produced[index].notes.append(contentsOf: scaling.notes)
                    }
                }
                flats.append(contentsOf: produced)
            }
        }

        // MARK: Step 4 - resolve and bucket, by identity ALONE

        /// One line under construction. The dimension appears nowhere in this key.
        struct Bucket {
            var item: FoodItem?
            var displayName: String
            var contributions: [QuantityMath.Contribution] = []
            var sources: [DraftSource] = []
            var flags: Set<LineFlag> = []
            var unmeasuredNotes: [String] = []
        }

        var order: [ItemIdentity] = []
        var buckets: [ItemIdentity: Bucket] = [:]

        for flat in flats {
            let item = resolveItem(flat.catalogName, flat.displayName)
            let lineIdentity = identity(for: item, displayName: flat.displayName)

            if buckets[lineIdentity] == nil {
                order.append(lineIdentity)
                buckets[lineIdentity] = Bucket(
                    item: item,
                    displayName: item?.displayName ?? flat.displayName
                )
            }
            guard var bucket = buckets[lineIdentity] else { continue }

            var sourceContribution: QuantitySubtotal? = nil
            if let quantity = contribution(for: flat, item: item) {
                bucket.contributions.append(QuantityMath.Contribution(quantity: quantity))
                sourceContribution = QuantitySubtotal(
                    dimensionKey: quantity.dimensionKey,
                    base: quantity.base,
                    preferredUnit: quantity.unit
                )
            } else if !flat.unmeasuredNote.isEmpty,
                      !bucket.unmeasuredNotes.contains(flat.unmeasuredNote) {
                // "Pinch flaky salt" reaches the list as a presence item: never 0, never
                // dropped, and never aggregated into "2 pinches".
                bucket.unmeasuredNotes.append(flat.unmeasuredNote)
            }

            if flat.wasTweaked { bucket.flags.insert(.tweaked) }
            bucket.flags.formUnion(LineFlag.from(flat.notes))

            if item == nil && !bucket.flags.contains(.unresolvedItem) {
                // Once per line and not once per contribution: butter in two components would
                // otherwise report the same unmatched ingredient twice on the diagnostics screen.
                diagnostics.append(.unresolvedItem(
                    text: flat.displayName.isEmpty ? flat.originalText : flat.displayName,
                    recipeTitle: flat.provenance.recipeTitle
                ))
                bucket.flags.insert(.unresolvedItem)
            }

            bucket.sources.append(DraftSource(
                kind: .plannedMeal,
                mealID: flat.provenance.mealID,
                mealDayKey: flat.provenance.mealDayKey,
                mealSlotRaw: flat.provenance.mealSlotRaw,
                mealTitle: flat.provenance.mealTitle,
                recipeID: flat.provenance.recipeID,
                recipeTitle: flat.provenance.recipeTitle,
                lineID: flat.lineID,
                componentPath: flat.componentPath.joined(separator: " \u{003E} "),
                originalText: flat.originalText,
                scaledText: flat.scaledText,
                scaleDescription: flat.provenance.scaleDescription,
                contribution: sourceContribution
            ))

            buckets[lineIdentity] = bucket
        }

        // MARK: Step 8 - par levels, folded into the lines that already exist
        //
        // Appending to an existing line rather than adding a second one is not tidiness. The
        // staple rung below deliberately leaves a staple with a par-level shortfall on the list
        // as an ordinary line, and kosher salt - the fixture's own staple - is the likeliest
        // thing in this kitchen to carry a par level, so an unconditional pass gives one
        // `FoodItem` two lines on one list. It would also break the regenerate carry-over, which
        // matches on identity: two lines sharing one make it ambiguous, and a line he checked
        // off comes back.

        var parIdentities: Set<ItemIdentity> = []
        for (item, shortfall) in parLevelShortfalls {
            let lineIdentity = identity(for: item, displayName: item.displayName)
            parIdentities.insert(lineIdentity)

            if buckets[lineIdentity] == nil {
                order.append(lineIdentity)
                buckets[lineIdentity] = Bucket(item: item, displayName: item.displayName)
            }
            guard var bucket = buckets[lineIdentity] else { continue }

            bucket.flags.insert(.parLevel)
            if let quantity = shortfall.quantity {
                bucket.contributions.append(QuantityMath.Contribution(quantity: quantity))
            }
            bucket.sources.append(DraftSource(
                kind: .parLevel,
                mealTitle: "Below par",
                scaledText: shortfall.displayString(system: options.unitSystem),
                scaleDescription: "you keep \(item.displayName) stocked",
                contribution: shortfall
            ))
            buckets[lineIdentity] = bucket
        }

        // MARK: Steps 5-7 and 9 - sum, subtract, status, section

        var lines: [DraftLine] = []

        for identity in order {
            guard let bucket = buckets[identity] else { continue }
            let item = bucket.item
            var flags = bucket.flags

            // Step 5. ONE call per line, with every contribution in it, so `sum` partitions by
            // `dimensionKey` internally and then runs the single volume-mass collapse. This is
            // also where a recipe aggregates against ITSELF: butter's two components and kosher
            // salt's `1 tsp + 1/4 tsp` are already in this array.
            let requested = QuantityMath.sum(
                bucket.contributions, using: item, system: options.unitSystem
            )

            // `.converted` is derived HERE, at the one call site that can see the result:
            // `collapseAcrossDimensions` returns subtotals with no flag channel by design,
            // because the note rides with the specific number that moved.
            if requested.contains(where: { !$0.conversionNote.isEmpty }) {
                flags.insert(.converted)
            }

            // Writer 1 of `.needsBridge`: a volume AND a mass requirement both survived the
            // collapse, which happens only when the item carries no `gramsPerCup`. Both numbers
            // are kept on one line, and the pinned block offers "these are the same -
            // 1 cup = ___ g", which writes the density back onto the `FoodItem`. One tap, once,
            // forever. Count buckets are never a bridge case: nothing converts a clove into a
            // head, and pretending otherwise is purchase-unit rounding (`CLAUDE.md`).
            let volumeKey = MeasureDimension.volume.rawValue
            let massKey = MeasureDimension.mass.rawValue
            let hasVolume = requested.contains { $0.dimensionKey == volumeKey }
            let hasMass = requested.contains { $0.dimensionKey == massKey }
            if hasVolume && hasMass { flags.insert(.needsBridge) }

            // Step 6.
            var have: [QuantitySubtotal] = []
            var toBuy = requested
            var didReduce = false

            if options.subtractInventory, let item = item {
                let level = inventoryLevel(item, options)
                flags.formUnion(level.flags)

                if item.isRunningLow {
                    // He has told us this is nearly gone, so the ledger's number is wrong in the
                    // only direction that matters and the line counts zero on hand. `.parLevel`
                    // is this schema's flag for "a stock rule, not a recipe, put this on the
                    // list", which is what running low is; `LineFlag` has no separate case and
                    // adding one is an edit to a frozen file.
                    flags.insert(.parLevel)
                } else {
                    have = level.subtotals
                }

                // `subtract` clamps BOTH sides, runs `bridgeHave` FIRST - so a 4 oz butter lot
                // really does cover a 2 tbsp requirement at `gramsPerCup: 227` - and raises
                // `.needsBridge` (writer 2) only for stock that survives that attempt. A known
                // density must never produce a bridge warning: a warning on an item the
                // catalogue ships a density for teaches him to ignore warnings.
                let result = QuantityMath.subtract(
                    requested: requested, have: have, item: item, system: options.unitSystem
                )
                toBuy = result.toBuy
                flags.formUnion(result.flags)
                didReduce = result.didReduce
            }

            // An unmeasured-only line has nothing to subtract, so an empty `toBuy` is vacuously
            // true of it - without the first clause "Pinch flaky salt" files itself under
            // "Already have" and the salt is never bought.
            let nothingLeftToBuy = !requested.isEmpty && toBuy.isEmpty

            // A bridge that changed nothing he has to buy is noise, and the flag and the status
            // must agree: `ShoppingListLine.block` pins on EITHER of them, so leaving the flag
            // on a covered line pins a line with nothing to do into "Needs attention".
            if nothingLeftToBuy { flags.remove(.needsBridge) }

            let stapleDiverted = isStapleDiverted(
                item: item,
                hasParShortfall: parIdentities.contains(identity),
                options: options
            )

            let lineStatus = status(
                isUnresolved: flags.contains(.unresolvedItem),
                needsBridge: flags.contains(.needsBridge),
                isStapleDiverted: stapleDiverted,
                nothingLeftToBuy: nothingLeftToBuy,
                didReduce: didReduce
            )

            // Step 7's second half. The aggregation above already ran IN FULL - kosher salt's
            // `1 tsp + 1/4 tsp = 1 1/4 tsp` is a live calculation and the footer prints it - and
            // only the buy numbers are dropped. A quantity to buy printed beside "assumed on
            // hand" is the footer contradicting itself, and `purchase` is what
            // `InventoryLedger.receive` posts, so a non-empty one would restock something that
            // was never bought.
            //
            // Both of these hang off the LADDER'S RESULT rather than off a pass of their own.
            // That is the fix for the defect where an unconditional staple diversion ran after
            // the status was assigned and overrode it: all-purpose flour ships `staple: true` in
            // the shipped catalogue, so a flour line that should show a bridge warning went into
            // the collapsed staples footer instead, taking its one-tap fix with it - on real
            // data, not in theory.
            if lineStatus == .staple {
                flags.insert(.assumedOnHand)
                toBuy = []
            }

            // Step 9. In v1 `purchase` is a copy of `toBuy`: with purchase-unit rounding cut
            // there is no pack to round toward, so the list shops by the exact need and says so
            // ("12 slices baguette", as written). It keeps its own rows because `receive` posts
            // what came home rather than what the recipe asked for - which makes rounding a new
            // writer one day rather than a migration.
            let purchase = toBuy

            let placement = sectionPlacement(for: item, aisleOrder: aisleOrder)

            lines.append(DraftLine(
                identity: identity,
                foodItemID: item?.id,
                displayName: bucket.displayName,
                sectionName: placement.name,
                sectionSortIndex: placement.sortIndex,
                sortIndex: 0,
                status: lineStatus,
                flags: flags,
                unmeasuredNote: bucket.unmeasuredNotes.joined(separator: ", "),
                requested: requested,
                have: have,
                toBuy: toBuy,
                purchase: purchase,
                sources: bucket.sources,
                // Only the genuine arithmetic answer. A diverted staple has an empty `toBuy` BY
                // CONSTRUCTION, so calling it covered would be a second fact that disagrees with
                // the first - and `ShoppingListLine.block` already files it under Staples.
                isCovered: lineStatus == .haveEnough
            ))
        }

        // The walk order first, then the one comparison `ShoppingListLine` defines:
        // `localizedStandardCompare`, which is case- and diacritic-insensitive and numerically
        // aware, so "Parmesan" sorts beside "butter" and "2% milk" before "10% cream".
        lines.sort { a, b in
            if a.sectionSortIndex != b.sectionSortIndex {
                return a.sectionSortIndex < b.sectionSortIndex
            }
            return ShoppingListLine.displayNamePrecedes(a.displayName, b.displayName)
        }

        // And now WRITE the within-section position, so a stored list re-sorts exactly as the
        // preview sheet showed it rather than falling back to a tiebreak.
        var positions: [String: Int] = [:]
        for index in lines.indices {
            let section = lines[index].sectionName
            let next = positions[section] ?? 0
            lines[index].sortIndex = next
            positions[section] = next + 1
        }

        // The only writer of `sectionOrder`: the distinct section names in the order the lines
        // already carry, which puts "Unsorted" last because its index is the largest there is.
        var sectionOrder: [String] = []
        for line in lines where !sectionOrder.contains(line.sectionName) {
            sectionOrder.append(line.sectionName)
        }

        return Draft(
            lines: lines,
            diagnostics: diagnostics,
            mealCount: mealCount,
            adHocMealCount: adHocMealCount,
            sectionOrder: sectionOrder,
            options: options
        )
    }

    // MARK: - The status ladder

    /// **THE ONE WRITER OF `LineStatus`**, and the precedence is explicit because review 03
    /// found `.needsBridge` declared, filtered on by the pinned "needs attention" section, and
    /// assigned by nothing that survived a later pass.
    ///
    /// First match wins, in this order, and each rung is a deliberate answer to "which of two
    /// true things does this line say":
    ///
    /// 1. **`.unresolvedItem`** — it matched no `FoodItem` and no catalogue template. It
    ///    outranks the bridge because an unmatched item has no density to fill in, so the bridge
    ///    question cannot be answered yet.
    /// 2. **`.needsBridge`** — the app could not finish the arithmetic for something he has to
    ///    buy. It outranks the staple diversion, so a flour line keeps its one-tap fix instead
    ///    of disappearing into a collapsed footer, and it outranks `.partiallyHave` and
    ///    `.needed` because it is the one state a single tap fixes forever. The caller clears
    ///    the flag when nothing is left to buy, which is how "covered" still wins over a bridge
    ///    that changed nothing.
    /// 3. **`.staple`** — assumed on hand, diverted to the footer with its summed requirement
    ///    intact. Above `.haveEnough` because "assumed on hand" is a stronger statement than
    ///    "you have enough": a staple carries no tracked quantity, so a covered staple belongs
    ///    under Staples and not under "Already have" as though a number had been subtracted.
    /// 4. **`.haveEnough`** — nothing left to buy. Not an action, so it collapses.
    /// 5. **`.partiallyHave`** — some bucket was genuinely reduced in a matching dimension and
    ///    the line is still half-covered. A different fact from a line nothing covered, which is
    ///    why `subtract` returns `didReduce` at all.
    /// 6. **`.needed`** — the ordinary case.
    ///
    /// `.manual` is never returned here: it belongs to a line no recipe caused, which
    /// `ShoppingListStore.addManualLine` creates and nothing recomputes.
    static func status(
        isUnresolved: Bool,
        needsBridge: Bool,
        isStapleDiverted: Bool,
        nothingLeftToBuy: Bool,
        didReduce: Bool
    ) -> LineStatus {
        if isUnresolved { return .unresolvedItem }
        if needsBridge { return .needsBridge }
        if isStapleDiverted { return .staple }
        if nothingLeftToBuy { return .haveEnough }
        if didReduce { return .partiallyHave }
        return .needed
    }

    /// Salt, pepper, every oil, every vinegar, every spice — tracked present or absent with no
    /// quantity, because counting teaspoons of salt is work nobody does and a list that keeps
    /// asking for salt is a list you stop reading.
    ///
    /// Three things take a staple off the footer and onto the list proper: he asked for staples
    /// this time, he said this one was running low, or a par level says it is short.
    static func isStapleDiverted(
        item: FoodItem?,
        hasParShortfall: Bool,
        options: Options
    ) -> Bool {
        guard let item = item, item.trackingMode == .staple else { return false }
        if options.includeStaples || item.isRunningLow || hasParShortfall { return false }
        return true
    }

    // MARK: - Choosing which of the recipe's two numbers to count

    /// The quantity this line contributes, which is **not always the one the line leads with.**
    ///
    /// When the author wrote their own equivalent — "1 1/2 cups all-purpose flour (190g)" — and
    /// it is already in the dimension the item prefers, that number is used. It is EXACT, where
    /// converting the cups through `gramsPerCup` approximates a density that varies with how the
    /// flour was scooped. The density bridge is the fallback for a line that gave only one
    /// number, and when it fires it marks itself: `QuantityMath` writes a `conversionNote` onto
    /// the bucket it moved and the builder raises `.converted` from it, so an approximated
    /// number is never silently presented as a measured one.
    ///
    /// `RecipeGraph` has already dropped `altQuantity` for a ranged line, because the author's
    /// gram equivalent was written for the amount stated and not for the top of a range.
    static func contribution(for flat: RecipeGraph.FlatLine, item: FoodItem?) -> Quantity? {
        guard let primary = flat.quantity else { return nil }
        guard let item = item, let alt = flat.altQuantity else { return primary }
        if primary.dimension != item.preferredDimension,
           alt.dimension == item.preferredDimension {
            return alt
        }
        return primary
    }

    // MARK: - Where a line lands

    /// The section name snapshotted onto the line, and its position in the walk.
    ///
    /// Three tiers, and the middle one exists so two sections he invented do not interleave with
    /// each other: lines are grouped for display by walking them in sort order, so two sections
    /// sharing a `sectionSortIndex` would hand him "flour, batteries, sugar, lightbulbs".
    static func sectionPlacement(
        for item: FoodItem?, aisleOrder: [String]
    ) -> (name: String, sortIndex: Int) {
        guard let section = item?.defaultSection else {
            return (unsortedSectionName, unsortedSectionSortIndex)
        }
        let name = section.displayName
        // Tier 1: an aisle the shipped walk order names. `ShoppingList.sectionSortIndex` is the
        // one definition of that lookup and returns `aisleOrder.count` for anything it does not
        // know, which is how tier 2 is detected rather than guessed at.
        let walk = ShoppingList.sectionSortIndex(forAisle: section.name, in: aisleOrder)
        if walk < aisleOrder.count { return (name, walk) }
        // Tier 2: a section of his own, after every aisle he walks, in the order he dragged them
        // into. Clamped so it can never reach tier 3.
        let own = aisleOrder.count + max(0, section.sortIndex)
        return (name, min(own, unsortedSectionSortIndex - 1))
    }
}
