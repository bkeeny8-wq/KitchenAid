import Foundation
import SwiftData

/// A persisted, frozen trip. Not recomputed on view.
///
/// He checks things off while standing in the produce aisle, and he adds paper towels, which
/// came from no recipe. A list is also a historical document: if a recipe is revised in
/// March, the November list must still say what it said in November — which, with recipes
/// bundled and immutable, now also means "the list survives a `git revert` of a recipe file".
@Model
final class ShoppingList {
    var id: UUID = UUID()
    var title: String = ""                 // "Nov 3-9"
    var generatedAt: Date = .now
    var rangeStart: Date = .now
    var rangeEnd: Date = .now
    var rangeStartDayKey: Int = 0
    var rangeEndDayKey: Int = 0
    var isArchived: Bool = false
    var completedAt: Date? = nil
    var notes: String = ""

    // MARK: The build options, FROZEN as real fields rather than a JSON blob
    //
    // "Which options produced this list" is a question the regenerate path and the diff sheet
    // both ask, and an `optionsJSON: String` makes it a decode rather than a read. Real
    // fields are also what let a future option be added without touching stored rows.
    //
    // This is the WHOLE of `ShoppingListBuilder.Options` minus `range`/`slots`/
    // `expandedLineIDs` (which are the four range fields and the two blobs below) and minus
    // `now`. `now` is deliberately NOT frozen: `generatedAt` already records it, and a
    // second copy of the same instant is a second thing that can disagree.
    //
    // Nothing that no code reads is frozen here. `roundToPurchaseUnits` and
    // `includeCoveredLines` are both absent on purpose (review 03, findings 2 and 4): a
    // stored flag with no reader ships inside the schema, so deleting it after the first
    // build is a migration rather than an edit, and a list that records "rounded to
    // purchase units: yes" about a list shopped by the exact need is worse than silence.
    // Purchase-unit rounding is cut (`CLAUDE.md`); covered lines are always kept.
    //
    // `unitSystemRaw` and `defaultDinerCount` are here because a regenerate without them is
    // not reproducible: the unit system changes every `preferredUnitCode` frozen onto the
    // subtotal rows, and the diner count changes the `.noAttendance` fallback scale, so a
    // list regenerated under a different preference silently differs from the one he
    // shopped.
    var subtractInventory: Bool = true
    var countExpiredAsAvailable: Bool = false
    var expiringGraceDays: Int = 0
    var includeStaples: Bool = false
    var includeOptionalLines: Bool = false
    var maxExpansionDepth: Int = 4
    /// `UnitSystem` raw value. Stored, never an enum (§0.4).
    var unitSystemRaw: String = UnitSystem.us.rawValue
    var defaultDinerCount: Int = 2
    /// `|`-delimited `MealSlot` raw values. Frozen at generation; single writer.
    var slotsBlob: String = ""
    /// `|`-delimited `IngredientLine.lineID` values: the buy-or-make decisions he made for
    /// THIS run, so a regenerate is reproducible. **Strings, not UUIDs**, because the lines
    /// are content now.
    ///
    /// A delimited blob under the §2.8 exception: written once at generation by one writer,
    /// never appended to afterwards. There is deliberately NO `includedMealIDs` blob — the
    /// live `ShoppingListSource.plannedMeal` edges ARE the included set, and they are
    /// queryable.
    var expandedLineIDBlob: String = ""

    /// Macro lives on `Store.shoppingLists`.
    var store: Store? = nil

    @Relationship(deleteRule: .cascade, inverse: \ShoppingListLine.list)
    var lines: [ShoppingListLine]? = []

    /// `.nullify`: archiving a list must not un-buy the groceries.
    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.shoppingList)
    var receivedTransactions: [InventoryTransaction]? = []

    init(
        id: UUID = UUID(),
        title: String = "",
        generatedAt: Date = .now,
        rangeStart: Date = .now,
        rangeEnd: Date = .now,
        rangeStartDayKey: Int = 0,
        rangeEndDayKey: Int = 0,
        isArchived: Bool = false,
        completedAt: Date? = nil,
        notes: String = "",
        subtractInventory: Bool = true,
        countExpiredAsAvailable: Bool = false,
        expiringGraceDays: Int = 0,
        includeStaples: Bool = false,
        includeOptionalLines: Bool = false,
        maxExpansionDepth: Int = 4,
        unitSystemRaw: String = UnitSystem.us.rawValue,
        defaultDinerCount: Int = 2,
        slotsBlob: String = "",
        expandedLineIDBlob: String = "",
        store: Store? = nil
    ) {
        self.id = id
        self.title = title
        self.generatedAt = generatedAt
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.rangeStartDayKey = rangeStartDayKey
        self.rangeEndDayKey = rangeEndDayKey
        self.isArchived = isArchived
        self.completedAt = completedAt
        self.notes = notes
        self.subtractInventory = subtractInventory
        self.countExpiredAsAvailable = countExpiredAsAvailable
        self.expiringGraceDays = expiringGraceDays
        self.includeStaples = includeStaples
        self.includeOptionalLines = includeOptionalLines
        self.maxExpansionDepth = maxExpansionDepth
        self.unitSystemRaw = unitSystemRaw
        self.defaultDinerCount = defaultDinerCount
        self.slotsBlob = slotsBlob
        self.expandedLineIDBlob = expandedLineIDBlob
        self.store = store
    }
}

// MARK: - Reading the frozen options

extension ShoppingList {
    var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .us }

    var expandedLineIDs: Set<String> {
        Set(expandedLineIDBlob.split(separator: "|").map(String.init).filter { !$0.isEmpty })
    }

    var slots: Set<MealSlot> {
        Set(slotsBlob.split(separator: "|").compactMap { MealSlot(rawValue: String($0)) })
    }
}

// MARK: - Order

extension ShoppingList {
    /// Section order comes from the walk order snapshotted onto each line at generation, and
    /// within a section from the `sortIndex` the generator wrote.
    ///
    /// The third key is `localizedStandardCompare`, not `<`. Review 03 found the within-
    /// section order specified as "alphabetical" with no writer anywhere, so every line in a
    /// section tied on `sortIndex == 0` and fell through to raw `String <` — Unicode-scalar
    /// order, which renders Dairy as "Parmesan, butter, cream cheese" because 'P' (U+0050)
    /// precedes 'b' (U+0062). `ShoppingListLine.displayNamePrecedes` is the one definition of
    /// that comparison and the generator sorts by it before writing `sortIndex`, so a stored
    /// list re-sorts here exactly as it was built.
    var orderedLines: [ShoppingListLine] {
        (lines ?? []).sorted { a, b in
            if a.sectionSortIndex != b.sectionSortIndex {
                return a.sectionSortIndex < b.sectionSortIndex
            }
            if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
            return ShoppingListLine.displayNamePrecedes(a.displayName, b.displayName)
        }
    }

    /// The aisle's position in the catalogue's exported walk order, for the generator to
    /// snapshot into `ShoppingListLine.sectionSortIndex`.
    ///
    /// A function over the array the caller passes rather than a table in this file: the
    /// authoritative order is `aisleOrder` in `Resources/ingredients.json`, read at launch
    /// by `IngredientCatalog` and seeded into `StoreSection.sortIndex`, and a second copy
    /// here would be a copy that silently stops matching the shipped JSON the first time
    /// `build_catalogue.py` adds an aisle. An aisle the order does not name sorts after
    /// every aisle it does, so a line is never lost to a missing section — it lands at the
    /// end of the walk where he will still see it.
    static func sectionSortIndex(forAisle aisle: String, in aisleOrder: [String]) -> Int {
        aisleOrder.firstIndex(of: aisle) ?? aisleOrder.count
    }
}

// MARK: - Display blocks
//
// Four blocks, and `ShoppingListLine.block` decides which one a line is in — once. The
// accessors below only filter on that decision, so the blocks are exclusive and they cover
// every line. Review 03 found the previous spelling asking three independent questions of
// two fields: a staple that inventory had covered rendered in BOTH the "Already have" and
// the "Staples" footer, and a staple missing a density never reached the pinned "Needs
// attention" block at all, so its one-tap "1 cup = ___ g" fix was unreachable.

extension ShoppingList {
    /// Pinned at the top: the lines where the app is telling him it could not finish the
    /// arithmetic, and the only lines with a fix he can apply from the list.
    var needsAttention: [ShoppingListLine] {
        orderedLines.filter { $0.block == .needsAttention }
    }

    /// Grouped for display, preserving the walk order snapshotted on each line.
    var linesBySection: [(sectionName: String, lines: [ShoppingListLine])] {
        var order: [String] = []
        var buckets: [String: [ShoppingListLine]] = [:]
        for line in orderedLines where line.block == .aisle {
            if buckets[line.sectionNameSnapshot] == nil { order.append(line.sectionNameSnapshot) }
            buckets[line.sectionNameSnapshot, default: []].append(line)
        }
        return order.map { (sectionName: $0, lines: buckets[$0] ?? []) }
    }

    /// "Already have (6)", collapsed. Kept, never removed: a silently absent line is
    /// indistinguishable from a bug, and he needs to see the app's belief about his fridge
    /// before he will trust it.
    var coveredFooter: [ShoppingListLine] { orderedLines.filter { $0.block == .covered } }

    /// "Staples (not checked)", collapsed. Salt and pepper are tracked present or absent, so
    /// they are shown as assumed rather than asked for.
    var staplesFooter: [ShoppingListLine] { orderedLines.filter { $0.block == .staples } }
}

// MARK: - Provenance

extension ShoppingList {
    /// The meals this list covers, from the live edges. This is what "drop Thursday's dinner"
    /// iterates.
    var coveredMeals: [PlannedMeal] {
        var seen: Set<UUID> = []
        var out: [PlannedMeal] = []
        for line in orderedLines {
            for source in line.orderedSources {
                guard let meal = source.plannedMeal, !seen.contains(meal.id) else { continue }
                seen.insert(meal.id)
                out.append(meal)
            }
        }
        return out.sorted { ($0.dayKey, $0.slotSortIndex) < ($1.dayKey, $1.slotSortIndex) }
    }
}
