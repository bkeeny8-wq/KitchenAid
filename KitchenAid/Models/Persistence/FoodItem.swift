import Foundation
import SwiftData

/// The thing actually in the house. The only row that means "a thing in my kitchen".
///
/// It is NOT the catalogue. `KitchenAid/Resources/ingredients.json` ships 668 TEMPLATES
/// (`CatalogEntry`, §0.3); a `FoodItem` is minted from one by `FoodItemResolver.findOrCreate`
/// the first time something is actually needed, copying the template's dimension, density and
/// staple flag and resolving its aisle to a seeded `StoreSection`, so he can then override
/// any of them. After that the row is his and `catalogName` is only provenance.
///
/// The catalogue is deliberately NOT seeded into the store: 668 mostly-empty rows make every
/// pantry screen a filter over nothing, and make a catalogue rebuild a migration.
///
/// Two things the mint cannot skip, both of which have already been written wrong once:
///
/// - The density is TWO fields. `gramsPerCup` below returns nil without `hasDensity`, so
///   writing only the numerator/denominator pair leaves the volume-to-mass bridge unable to
///   fire on an item whose density ships in the catalogue. `setDensity(_:)` is the writer
///   that cannot get this half-right.
/// - The template's `unit` is NOT copied, because there is no unit field here to copy it
///   into. The one unit-bearing property on this row, `parLevelUnitCode`, is the par level's
///   unit, and giving it a second meaning is worse than reading the template live: a default
///   unit for an add-stock sheet is `catalog.entry(named: item.catalogName)?.defaultUnit`.
///   (ARCHITECTURE.md §0.3 still claims this row has "two unit fields"; the second was
///   `purchasePackUnitCode`, which went with purchase-unit rounding. The Swift is right.)
@Model
final class FoodItem {
    var id: UUID = UUID()
    var name: String = ""

    /// Normalized `name` (`NameNormalizer.matchKey`), used for identity matching, and stored
    /// rather than computed so step 1 of the resolver's lookup can be a `#Predicate` — a
    /// computed property cannot appear in one.
    ///
    /// Deliberately NOT unique: CloudKit-backed stores reject `@Attribute(.unique)`, so two
    /// devices offline can and will both create "Shallot". The constraint does not exist;
    /// `FoodItemResolver` plus its deterministic merge pass is what keeps this single-rowed.
    var matchKey: String = ""

    /// The `CatalogEntry.name` this row was minted from, or "" for a row he invented. A
    /// STRING by design: the catalogue is built by a Python script, has no UUIDs, and must
    /// stay diffable in git.
    var catalogName: String = ""

    /// A DERIVED INDEX over the `aliases` rows — "|scallion|spring onion|" — rebuilt by
    /// `FoodItemResolver.reindex(_:)` whenever a row is added or merged.
    ///
    /// It exists only so alias lookup can be a `#Predicate` instead of fetching and scanning
    /// the whole store on every line resolution, forever. The ROWS are the truth. Never
    /// append to this directly: add a `FoodItemAlias` and reindex, or a CloudKit merge of two
    /// devices that each added an alias silently loses one, and "scallion" and "green onion"
    /// stop collapsing into one purchase. **Shipped aliases are not in here** — they stay in
    /// the catalogue and are consulted after this.
    var aliasBlob: String = ""

    /// `StockTrackingMode`: tracked / staple / untracked. Seeded from `CatalogEntry.staple`.
    ///
    /// 87 of the 668 shipped entries are `.staple`: salt, pepper, every oil, every vinegar,
    /// every spice. A staple is present or absent with **no quantity** — assumed present,
    /// never depleted, and never shopped unless `isRunningLow` or a par level trips. Counting
    /// teaspoons of salt is work nobody does, and without this the app demands he inventory
    /// his salt and he abandons it in week two.
    ///
    /// Staples still AGGREGATE fully and are shown with their summed quantity in a collapsed
    /// footer, which is why the fixture's 1 tsp + 1/4 tsp kosher salt is a live test case and
    /// not a skipped path.
    var trackingModeRaw: String = StockTrackingMode.tracked.rawValue

    /// The present/absent bit for a staple, and a manual nudge for anything else.
    var isRunningLow: Bool = false

    // MARK: Volume <-> mass bridge
    //
    // Stored as an integer pair, not a Double. The whole reason `Rational` exists is to keep
    // Doubles out of the arithmetic, and a density that arrives as a Double and is then
    // `Rational(approximating:)`-ed reintroduces the imprecision at the one point it
    // matters. The catalogue says 120 for flour; that is 120/1 exactly.
    var hasDensity: Bool = false
    var gramsPerCupNumerator: Int = 0
    var gramsPerCupDenominator: Int = 1

    // MARK: Par level — a staple reaches the list by a RULE, not by a hand-flipped Bool
    var hasParLevel: Bool = false
    var parLevelNumerator: Int = 0
    var parLevelDenominator: Int = 1
    var parLevelUnitCode: String = ""
    var parLevelDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    /// Which dimension this item's subtotals collapse toward when a density lets them meet.
    /// The mint overwrites it from the template; the default matters only for a row he
    /// created from scratch.
    var preferredDimensionRaw: String = MeasureDimension.mass.rawValue

    var notes: String = ""              // "the good anchovies, back of aisle 7"
    var createdAt: Date = .now

    /// The recipe this item is a batch OF — chimichurri, stock, pizza dough. A content id and
    /// not a relationship, because SwiftData cannot hold a relationship to a `Codable` value
    /// type, so a make-ahead batch can be stocked as a lot and drawn down like anything else.
    /// "" = not produced by a recipe.
    var producedByRecipeID: String = ""

    /// Macro lives on `StoreSection.foodItems`.
    var defaultSection: StoreSection? = nil
    /// Macro lives on `StorageLocation.foodItems`.
    var defaultLocation: StorageLocation? = nil

    @Relationship(deleteRule: .cascade, inverse: \FoodItemAlias.item)
    var aliases: [FoodItemAlias]? = []

    // MARK: The ledger edges are .nullify, and this is load-bearing
    //
    // A `.cascade` here means one `context.delete(foodItem)` from a stray SwiftUI `.onDelete`
    // destroys the entire append-only ledger the architecture is built around. `.deny` is
    // forbidden by CloudKit. Putting the guard only in a service is not a guard: any other
    // call site bypasses it, and the schema cannot enforce what a service promises.
    //
    // So: `.nullify`, plus `foodItemNameSnapshot` on both children so an orphan is still
    // readable and attributable in the reconcile screen. `FoodItemResolver.canDelete` ALSO
    // refuses an item with history and offers "merge into…", but that is a courtesy on top
    // rather than the only thing standing between him and a lost year.
    @Relationship(deleteRule: .nullify, inverse: \StockLot.item)
    var lots: [StockLot]? = []

    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.item)
    var transactions: [InventoryTransaction]? = []

    /// Deleting an item must never eat a printed list.
    @Relationship(deleteRule: .nullify, inverse: \ShoppingListLine.foodItem)
    var shoppingLines: [ShoppingListLine]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        matchKey: String = "",
        catalogName: String = "",
        aliasBlob: String = "",
        trackingModeRaw: String = StockTrackingMode.tracked.rawValue,
        isRunningLow: Bool = false,
        hasDensity: Bool = false,
        gramsPerCupNumerator: Int = 0,
        gramsPerCupDenominator: Int = 1,
        hasParLevel: Bool = false,
        parLevelNumerator: Int = 0,
        parLevelDenominator: Int = 1,
        parLevelUnitCode: String = "",
        parLevelDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        preferredDimensionRaw: String = MeasureDimension.mass.rawValue,
        notes: String = "",
        createdAt: Date = .now,
        producedByRecipeID: String = "",
        defaultSection: StoreSection? = nil,
        defaultLocation: StorageLocation? = nil
    ) {
        self.id = id
        self.name = name
        self.matchKey = matchKey
        self.catalogName = catalogName
        self.aliasBlob = aliasBlob
        self.trackingModeRaw = trackingModeRaw
        self.isRunningLow = isRunningLow
        self.hasDensity = hasDensity
        self.gramsPerCupNumerator = gramsPerCupNumerator
        self.gramsPerCupDenominator = gramsPerCupDenominator
        self.hasParLevel = hasParLevel
        self.parLevelNumerator = parLevelNumerator
        self.parLevelDenominator = parLevelDenominator
        self.parLevelUnitCode = parLevelUnitCode
        self.parLevelDimensionRaw = parLevelDimensionRaw
        self.preferredDimensionRaw = preferredDimensionRaw
        self.notes = notes
        self.createdAt = createdAt
        self.producedByRecipeID = producedByRecipeID
        self.defaultSection = defaultSection
        self.defaultLocation = defaultLocation
    }
}

// MARK: - Accessors

/// The `DensityCarrying` conformance is declared HERE, on the extension that already
/// provides both of its requirements, rather than on the class.
///
/// `QuantityMath` takes `(any DensityCarrying)?` instead of a `FoodItem?` so the
/// arithmetic imports no SwiftData and its tests need no `ModelContainer`. That only
/// works if this conformance exists: without it every `QuantityMath` call that passes a
/// `FoodItem` fails to type-check, and the bridge that converts 4 oz of butter into
/// tablespoons has no density to work from.
extension FoodItem: DensityCarrying {
    var trackingMode: StockTrackingMode {
        StockTrackingMode(rawValue: trackingModeRaw) ?? .tracked
    }

    var preferredDimension: MeasureDimension {
        MeasureDimension(rawValue: preferredDimensionRaw) ?? .mass
    }

    var isStaple: Bool { trackingMode == .staple }

    /// Whether a quantity means anything for this row at all. A staple carries none by
    /// decision, and an `.untracked` row is one he does not want counted.
    var tracksQuantity: Bool { trackingMode == .tracked }

    var displayName: String { name.isEmpty ? "Unnamed item" : name }

    /// Grams per US cup, exact. nil means unknown, and unknown means the app REFUSES to
    /// convert rather than guessing: 1 cup = 240 g is right for water, off by 2x for flour
    /// and 1.4x for honey — and wrong SILENTLY, inside a number he is about to shop by.
    var gramsPerCup: Rational? {
        guard hasDensity else { return nil }
        let r = Rational(gramsPerCupNumerator, max(1, gramsPerCupDenominator))
        // A zero or negative density would divide the bridge by zero or flip its sign. A row
        // written that way is a bug or a future build, and refusing to convert is the same
        // answer as not knowing.
        return r > .zero ? r : nil
    }

    var parLevel: Quantity? {
        guard hasParLevel,
              let unit = UnitCatalog.unit(
                  code: parLevelUnitCode,
                  fallbackDimension: MeasureDimension(rawValue: parLevelDimensionRaw)
              )
        else { return nil }
        return Quantity(
            amount: Rational(parLevelNumerator, max(1, parLevelDenominator)),
            unit: unit
        )
    }

    var orderedAliases: [FoodItemAlias] {
        (aliases ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var orderedLots: [StockLot] {
        (lots ?? []).sorted { $0.acquiredAt < $1.acquiredAt }
    }

    /// Newest first: the ledger is read as history, and the thing he wants to see when he
    /// asks "why does it think I have 3 lb of butter" is the most recent row.
    var orderedTransactions: [InventoryTransaction] {
        (transactions ?? []).sorted { $0.occurredAt > $1.occurredAt }
    }

    var allShoppingLines: [ShoppingListLine] { shoppingLines ?? [] }

    /// THE ROWS A LEVEL IS SUMMED FROM — the item's transactions, not its lots.
    ///
    /// `StockLot.transactions` is `.nullify`, so deleting a lot leaves its transactions in
    /// the ledger with `lot == nil`. If a level summed LOTS, those rows would still be
    /// present and would silently stop contributing, producing a divergence between the
    /// ledger and the caches that `reconcileReport` could never attribute to anything or
    /// clear. Summing at the item level means an orphan still counts, into an explicit
    /// "unassigned lot" bucket the reconcile screen names.
    ///
    /// This reads like a detour — the lots are right there, with the quantities on them —
    /// which is exactly why it is written down here next to both relationships.
    var levelContributions: [InventoryTransaction] {
        (transactions ?? []).filter { $0.countsTowardLevel }
    }

    var hasLedgerHistory: Bool {
        !(lots ?? []).isEmpty || !(transactions ?? []).isEmpty
    }
}

// MARK: - Writers that cannot leave a pair half-written

extension FoodItem {
    /// Both density fields through one call. A view or a mint that assigns the numbers
    /// without the Bool produces a row whose `gramsPerCup` is nil, and the bridge then never
    /// fires on an item whose density shipped in the catalogue — silently, because nothing
    /// about the row looks wrong.
    func setDensity(_ newDensity: Rational?) {
        guard let d = newDensity, d > .zero else {
            hasDensity = false
            gramsPerCupNumerator = 0
            gramsPerCupDenominator = 1
            return
        }
        hasDensity = true
        gramsPerCupNumerator = d.numerator
        gramsPerCupDenominator = d.denominator
    }

    /// All five par-level primitives together. Clearing the amount while leaving
    /// `parLevelUnitCode` at "tbsp" leaves a row that has no par level and still claims a
    /// unit — which no accessor reads, and which the reconcile screen, the CloudKit dashboard
    /// and any future migration all read as a contradiction.
    func setParLevel(_ newParLevel: Quantity?) {
        guard let q = newParLevel else {
            hasParLevel = false
            parLevelNumerator = 0
            parLevelDenominator = 1
            parLevelUnitCode = ""
            parLevelDimensionRaw = MeasureDimension.unmeasured.rawValue
            return
        }
        hasParLevel = true
        parLevelNumerator = q.amount.numerator
        parLevelDenominator = q.amount.denominator
        parLevelUnitCode = q.unit.code
        parLevelDimensionRaw = q.unit.dimension.rawValue
    }

    func setName(_ newName: String) {
        name = newName
        matchKey = NameNormalizer.matchKey(newName)
    }
}

// MARK: - The alias blob, and the two lookups it exists for

extension FoodItem {
    /// `|a|b|` with BOTH outer pipes, so a `contains("|scallion|")` cannot match a longer key
    /// that merely starts with it. Keys only — the display text lives on the rows.
    static func encodeAliasBlob(_ keys: [String]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for key in keys {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, !k.contains("|"), seen.insert(k).inserted else { continue }
            kept.append(k)
        }
        guard !kept.isEmpty else { return "" }
        return "|" + kept.joined(separator: "|") + "|"
    }

    /// The needle a predicate matches. Built here so the blob's format has exactly one
    /// writer and one reader.
    static func aliasNeedle(forMatchKey key: String) -> String { "|" + key + "|" }

    var aliasMatchKeys: [String] {
        aliasBlob.split(separator: "|").map(String.init)
    }

    /// What `FoodItemResolver.reindex(_:)` assigns to `aliasBlob`. The rows are the truth and
    /// this is rebuilt from them, never appended to.
    func rebuiltAliasBlob() -> String {
        FoodItem.encodeAliasBlob(orderedAliases.map { $0.matchKey })
    }

    /// Step 1 of the resolver's lookup order.
    static func descriptor(forMatchKey key: String) -> FetchDescriptor<FoodItem> {
        // Hoisted, and this is not style. `#Predicate` has to translate the closure body
        // into a `PredicateExpression` tree, and `DefaultStringInterpolation` has no
        // representation there, so `#Predicate { $0.matchKey == "\(key)" }` fails to expand
        // with "the expression could not be converted to a Predicate". A captured `let` is
        // an expression the macro CAN represent. General rule for this codebase: build every
        // predicate operand outside the macro and capture it.
        let needle = key
        var descriptor = FetchDescriptor<FoodItem>(
            predicate: #Predicate<FoodItem> { $0.matchKey == needle }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Step 2. The whole reason `aliasBlob` is stored at all: a stored `[String]` is a blob
    /// predicates cannot see into, so without this field every line resolution becomes a
    /// fetch-and-scan of the entire store, forever.
    static func descriptor(forAliasKey key: String) -> FetchDescriptor<FoodItem> {
        let needle = aliasNeedle(forMatchKey: key)
        var descriptor = FetchDescriptor<FoodItem>(
            predicate: #Predicate<FoodItem> { $0.aliasBlob.contains(needle) }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }
}
