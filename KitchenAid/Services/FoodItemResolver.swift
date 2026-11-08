import Foundation
import Observation
import SwiftData

/// Why a delete was refused, and what to offer instead.
///
/// Declared here rather than in `Models/Support/` because the model layer is frozen and does
/// not carry it; ARCHITECTURE.md §3.12 gives it its own file, and it can move there with no
/// call-site change. Nothing about the schema depends on where a value type lives.
///
/// The SCHEMA is what guarantees nothing is destroyed — `FoodItem -> lots` and
/// `FoodItem -> transactions` are `.nullify`, so a stray `.onDelete` cannot torch the ledger.
/// This is the courteous layer on top: it turns "that would orphan a year of your history"
/// into a sentence and a button. The reasons beyond the two `canDelete(_:)` raises are here
/// because the other guards (the roster, the default store, the last storage location) refuse
/// for the same reason and should refuse in the same words.
struct DeleteRefusal: Error, Identifiable, Sendable {

    enum Reason: String, Codable, CaseIterable, Sendable {
        case hasLedgerHistory
        case isOnOpenShoppingList
        /// The roster must not reach zero: attendance is what scales a recipe, and with
        /// nobody in the household there is nothing to divide by.
        case isLastEater
        case isDefaultStore
        case isOnlyStorageLocation
    }

    var id = UUID()
    var reason: Reason
    var subjectName: String
    var affectedCount: Int = 0

    var message: String {
        switch reason {
        case .hasLedgerHistory:
            return "\(subjectName) has \(affectedCount) inventory records. Deleting it would leave them unattributed."
        case .isOnOpenShoppingList:
            return "\(subjectName) is on a shopping list you have not finished."
        case .isLastEater:
            return "Keep at least one person in the household — attendance is what scales a recipe."
        case .isDefaultStore:
            return "\(subjectName) is the default store. Make another one default first."
        case .isOnlyStorageLocation:
            return "\(subjectName) is the only place you can put groceries."
        }
    }

    /// What the sheet offers INSTEAD of deleting. A refusal with no second button is a dead
    /// end, and the second button is the whole point of refusing politely.
    var suggestion: String {
        switch reason {
        case .hasLedgerHistory: return "Merge into another item"
        case .isOnOpenShoppingList: return "Remove it from the list first"
        case .isLastEater: return "Mark them inactive instead"
        case .isDefaultStore: return "Choose a new default"
        case .isOnlyStorageLocation: return "Add another location first"
        }
    }
}

/// Why a merge was refused, and what to offer instead.
///
/// The same shape as `DeleteRefusal` above, deliberately: `reason` / `message` / `suggestion`,
/// rendered by its readers as "\(message) \(suggestion)." — so the roster, the places screen
/// and the merge screen all refuse in one voice rather than three screens inventing three
/// sentences. A second shape for "cannot do this, here is why" would be the third.
///
/// It is a separate type rather than four more cases on `DeleteRefusal` because every one of
/// that type's `suggestion`s is an alternative to DELETING, and offering "merge into another
/// item" as the way out of a refused merge is a loop.
struct MergeRefusal: Error, Identifiable, Sendable {

    enum Reason: String, Codable, CaseIterable, Sendable {
        /// The container fell back to an in-memory store, so a merge would delete rows and
        /// lose the `MergeRecord` that says it did. The duplicates come back on the next
        /// launch with nothing to explain the gap.
        case storeUnavailable
        /// The rows moved between the preview and the tap. Merging now would not be the
        /// sentence he agreed to, which is the one thing this screen exists to guarantee.
        case changedSinceCheck
        /// The survivor carries no quantity — a staple is present or absent by decision
        /// (CLAUDE.md), an `.untracked` row is one he asked not to count — and a loser has
        /// real ledger rows. `PantryLevels.level` answers "Have it" / "Not tracked" for such
        /// a row, so the merge would file lots and transactions under something that shows
        /// no amount: nothing is destroyed, and nothing is visible either.
        case wouldHideALevel
        case couldNotSave
    }

    var id = UUID()
    var reason: Reason
    var subjectName: String = ""
    var affectedCount: Int = 0

    var message: String {
        switch reason {
        case .storeUnavailable:
            return "The database could not be opened, so a merge would be undone when the app closes."
        case .changedSinceCheck:
            return "The pantry changed while this was on screen, so these are no longer the rows you read."
        case .wouldHideALevel:
            return "\(subjectName) is tracked present or absent with no amount, and the duplicate has \(affectedCount) inventory records. Merging would file them under a row that shows no amount."
        case .couldNotSave:
            return "The merge could not be written to the database."
        }
    }

    /// What the screen offers INSTEAD. A refusal with no second button is a dead end, which
    /// is `DeleteRefusal`'s own note on the matter and the reason that type has this property.
    var suggestion: String {
        switch reason {
        case .storeUnavailable: return "Close the app and open it again first"
        case .changedSinceCheck: return "Check again and read the new list"
        // Nothing in the app changes an item's tracking mode, so the way out is to stop the
        // two rows matching: the alias that links them is removable on either item's screen,
        // under "Also known as".
        case .wouldHideALevel: return "Forget the alias that links them, on either item"
        case .couldNotSave: return "Check again \u{2014} this screen will say what landed"
        }
    }
}

/// One group of rows that mean the same purchase, as a VALUE: ids, names and counts, with
/// no `FoodItem` in it anywhere.
///
/// Carrying ids rather than objects for the same reason `LedgerDivergence` does, and here
/// it is load-bearing twice over. A screen holds a preview in `@State` across renders, and
/// the whole point of this type is that the rows it describes are about to be DELETED —
/// reading a property of a deleted SwiftData model is not a thing to find out about on a
/// device. So the preview is a snapshot, the commit re-derives from live rows, and
/// `signature` is what ties the two together.
struct DuplicateGroup: Identifiable {

    /// One row that would be deleted, and everything of his that would move off it.
    struct Absorbed: Identifiable {
        var id: UUID
        var name: String
        var lotCount: Int = 0
        var transactionCount: Int = 0
        var shoppingLineCount: Int = 0
        /// Lines on a list he has not finished — the one that is in his pocket in the
        /// shop. Counted separately because the line MOVES, so a list he is reading
        /// changes under him, and that is worth a sentence of its own.
        var openShoppingLineCount: Int = 0
    }

    var survivorID: UUID
    var survivorName: String
    var absorbed: [Absorbed] = []

    /// The keys two or more rows in this group share, which is the answer to "why does it
    /// think these are the same thing". Empty is legitimate and not a bug: grouping is
    /// transitive, so A and C can be one purchase because B shares a key with each.
    var sharedKeys: [String] = []

    var refusal: MergeRefusal?

    var id: UUID { survivorID }

    /// Survivor first, then the losers in merge order. Compared — never shown — so the
    /// commit can prove it is acting on the group that was previewed.
    var signature: String {
        ([survivorID] + absorbed.map { $0.id }).map { $0.uuidString }.joined(separator: "|")
    }

    var lotCount: Int { absorbed.reduce(0) { $0 + $1.lotCount } }
    var transactionCount: Int { absorbed.reduce(0) { $0 + $1.transactionCount } }
    var shoppingLineCount: Int { absorbed.reduce(0) { $0 + $1.shoppingLineCount } }
    var openShoppingLineCount: Int { absorbed.reduce(0) { $0 + $1.openShoppingLineCount } }

    /// What `MergeRecord.repointedCount` will read, computed the same way `merge` counts
    /// it: lots plus transactions plus shopping lines, over the losers. If these two ever
    /// disagree, the preview was a lie.
    var repointedCount: Int { lotCount + transactionCount + shoppingLineCount }

    var absorbedNames: [String] { absorbed.map { $0.name } }

    /// "3 lots, 11 transactions, 1 shopping line" — the half of the sentence he is
    /// agreeing to that has to be the thing that happens.
    ///
    /// **Empty when nothing moves**, rather than the word "nothing": two rows with no
    /// history between them is a real and common case (an item minted by a shopping list
    /// he never put away), and only the caller knows whether it is reading "Moves:" on a
    /// row or mid-sentence in a confirmation.
    var movesSentence: String {
        var parts: [String] = []
        if lotCount > 0 { parts.append(lotCount == 1 ? "1 lot" : "\(lotCount) lots") }
        if transactionCount > 0 {
            parts.append(transactionCount == 1
                ? "1 transaction" : "\(transactionCount) transactions")
        }
        if shoppingLineCount > 0 {
            parts.append(shoppingLineCount == 1
                ? "1 shopping line" : "\(shoppingLineCount) shopping lines")
        }
        return parts.joined(separator: ", ")
    }
}

/// THE ONLY PLACE A `FoodItem` IS CREATED.
///
/// Nothing else may call `context.insert(FoodItem(...))` — not the shopping builder, not the
/// pantry editor, not a manual shopping line. That discipline is what substitutes for the
/// `@Attribute(.unique)` CloudKit forbids: with no constraint available, two offline devices
/// can and will both create "Shallot", and one creation site plus one deterministic merge pass
/// is what keeps the store single-rowed instead.
///
/// Not `@MainActor`: it owns no context and no mutable observable state, so it is usable from
/// whatever actor the caller's `ModelContext` belongs to. The catalogue it reads is immutable
/// bundled content.
@Observable
final class FoodItemResolver {

    private let catalog: IngredientCatalog

    init(catalog: IngredientCatalog) {
        self.catalog = catalog
    }

    // MARK: - Lookup

    /// Four steps, in this order, and the order is load-bearing: an alias must never win over
    /// a canonical name, or one row's synonym captures another row's actual identity and the
    /// pantry matches the wrong purchase with nothing on screen saying it did.
    ///
    /// 1. His own `FoodItem.matchKey` — a `#Predicate`, `fetchLimit = 1`.
    /// 2. His own aliases, through `FoodItem.aliasBlob` — also a `#Predicate`.
    /// 3. The shipped catalogue, in memory, and mint from the template.
    /// 4. A bare row, or nil when `createIfMissing` is false, in which case the caller shows
    ///    the line with `.unresolvedItem` and a one-tap "match to...".
    ///
    /// Steps 1 and 2 are the entire reason `matchKey` and `aliasBlob` are STORED rather than
    /// computed: a computed property cannot appear in a `#Predicate`, and a stored `[String]`
    /// is a blob a predicate cannot see into, so without them every line resolution becomes a
    /// fetch-and-scan of the whole store, forever.
    func findOrCreate(
        name raw: String,
        createIfMissing: Bool = true,
        in context: ModelContext
    ) throws -> FoodItem? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = NameNormalizer.matchKey(trimmed)
        guard !key.isEmpty else { return nil }

        if let hit = try context.fetch(FoodItem.descriptor(forMatchKey: key)).first {
            return hit
        }
        if let hit = try context.fetch(FoodItem.descriptor(forAliasKey: key)).first {
            return hit
        }

        // The catalogue's own aliases are consulted here, AFTER his: "Green Onions" resolves
        // to the `scallion` template, whose `matchKey` is then what the mint looks up. So the
        // shipped synonym is not copied into a `FoodItemAlias` row — the next lookup for
        // "green onions" takes this same path and lands on the same row, and his alias table
        // stays his vocabulary rather than a cache of the catalogue's.
        if let entry = catalog.entry(matching: trimmed) {
            return try findOrCreate(fromCatalog: entry, in: context)
        }

        guard createIfMissing else { return nil }
        return insert(name: trimmed, matchKey: key, from: nil, in: context)
    }

    /// Minted FROM A TEMPLATE: dimension preference, staple flag, density and the aisle's
    /// `StoreSection` are copied and `catalogName` is stamped. Everything afterwards is his to
    /// override — the row is his, and `catalogName` is only provenance.
    ///
    /// The catalogue is deliberately not seeded into the store, so this is also the only thing
    /// that ever turns one of the 669 templates into a row he owns.
    func findOrCreate(fromCatalog entry: CatalogEntry, in context: ModelContext) throws -> FoodItem {
        let key = entry.matchKey
        if !key.isEmpty {
            if let hit = try context.fetch(FoodItem.descriptor(forMatchKey: key)).first {
                return hit
            }
            if let hit = try context.fetch(FoodItem.descriptor(forAliasKey: key)).first {
                return hit
            }
        }
        return insert(name: entry.name, matchKey: key, from: entry, in: context)
    }

    private func insert(
        name: String,
        matchKey key: String,
        from entry: CatalogEntry?,
        in context: ModelContext
    ) -> FoodItem {
        let resolvedKey = key.isEmpty ? NameNormalizer.matchKey(name) : key
        let item = FoodItem(name: name, matchKey: resolvedKey)

        if let entry = entry {
            item.catalogName = entry.name
            item.trackingModeRaw = entry.trackingMode.rawValue
            item.preferredDimensionRaw = Self.preferredDimension(for: entry).rawValue
            // BOTH density fields, through the one writer that cannot leave the pair
            // half-written. `FoodItem.gramsPerCup` returns nil without `hasDensity`, so
            // assigning only the numbers leaves the volume-to-mass bridge unable to fire on an
            // item whose density ships in the catalogue — silently, because nothing about the
            // row looks wrong. The catalogue ships a density for 108 of its entries, so this
            // is the common path, not the edge.
            item.setDensity(entry.gramsPerCup.map { Rational($0) })
            item.defaultSection = section(forAisle: entry.aisle, in: context)
            // The template's `unit` is NOT copied: there is no unit field here to copy it
            // into. The one unit-bearing property on the row, `parLevelUnitCode`, is the par
            // level's unit, and giving it a second meaning is worse than reading the template
            // live — an add-stock sheet reads
            // `catalog.entry(named: item.catalogName)?.defaultUnit`.
        }

        context.insert(item)
        return item
    }

    /// Which dimension this item's subtotals collapse toward.
    ///
    /// `bakingUnit` is read FIRST, and that is review 03's finding 7 settled in the Swift:
    /// `all-purpose flour` ships `"dimension": "volume"` with `"bakingUnit": "g"`, and copying
    /// `dimension` alone gives flour a volume preference — so "1 cup + 200 g flour" collapses
    /// to "2 2/3 cups" where the worked example, the thing written as the test oracle, says
    /// `320 g`. Volume measurement of flour varies by up to 20%, which is the difference
    /// between bread and a brick, so mass is also the right answer on the merits. This is
    /// `bakingUnit`'s first reader anywhere.
    ///
    /// A count template keeps the row's `.mass` default: the collapse only ever runs between
    /// volume and mass, and a `.count` preference would silently select the volume branch.
    private static func preferredDimension(for entry: CatalogEntry) -> MeasureDimension {
        if let baking = entry.preferredBakingUnit {
            if baking.dimension == .mass || baking.dimension == .volume { return baking.dimension }
        }
        if entry.dimension == .mass || entry.dimension == .volume { return entry.dimension }
        return .mass
    }

    /// The aisle a minted row lands in, matched on `matchKey` so the catalogue's "Dry goods"
    /// and a hand-typed "dry goods" are one aisle. nil is a legitimate answer — the sections
    /// may not be seeded yet — and a row with no section sorts to the end of the walk where he
    /// will still see it.
    private func section(forAisle aisle: String, in context: ModelContext) -> StoreSection? {
        guard !aisle.isEmpty else { return nil }
        let stores = (try? context.fetch(FetchDescriptor<Store>())) ?? []
        guard let store = Store.preferred(from: stores) else { return nil }
        return store.section(matchingAisle: aisle)
    }

    // MARK: - Aliases

    /// The one-tap "same as..." on an unresolved line. A ROW, never an element of a stored
    /// array: under CloudKit two devices each appending to a stored `[String]` resolve
    /// last-writer-wins on the WHOLE array, so one alias is silently lost — and a lost alias
    /// means two shopping lines for one purchase.
    ///
    /// If the key he typed is already another item's identity, this still records it, and the
    /// two rows then show up as one group in Pantry → Duplicate items, because they now share
    /// a key. That is the correct outcome: he has told the app the two names mean one thing.
    /// The merge itself waits for him to read it — `MergeDuplicatesView` on why.
    func addAlias(_ text: String, to item: FoodItem, in context: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = NameNormalizer.matchKey(trimmed)
        guard !key.isEmpty, key != item.matchKey else { return }
        guard !item.orderedAliases.contains(where: { $0.matchKey == key }) else { return }

        let row = FoodItemAlias.make(text: trimmed)
        context.insert(row)
        // The to-one side only: `inverse:` is declared on `FoodItem.aliases`, so SwiftData
        // maintains the array.
        row.item = item
        reindex(item)
    }

    /// Takes an alias back off, which until now nothing could do.
    ///
    /// `addAlias` has existed since the resolver did; removal did not, and that asymmetry
    /// was a real trap once receipt scanning started writing aliases. A token learned
    /// against the wrong food resolves at step 2 of `findOrCreate` — his own aliases, ahead
    /// of the shipped catalogue — so it answers that receipt line the same wrong way for
    /// ever, and nothing in the app could reach in and correct it. The only escape was
    /// deleting the `FoodItem`, which takes its lots and its history with it.
    ///
    /// Deletes the ROW and reindexes, in that order, because `aliasBlob` is an index over
    /// the rows and never a second source of truth — see `reindex`.
    func removeAlias(_ alias: FoodItemAlias, in context: ModelContext) {
        let owner = alias.item
        context.delete(alias)
        // The relationship array is maintained by SwiftData from the `inverse:` on
        // `FoodItem.aliases`, so the row is already gone from it by the time this runs.
        if let owner = owner { reindex(owner) }
    }

    /// Rebuilds `aliasBlob` from the rows. The ROWS are the truth; the blob is the
    /// predicate-queryable index over them, rebuilt and never appended to — append to it
    /// directly and a CloudKit merge of two devices that each added an alias silently loses
    /// one, and "scallion" and "green onion" stop collapsing into one purchase.
    func reindex(_ item: FoodItem) {
        item.aliasBlob = item.rebuiltAliasBlob()
    }

    // MARK: - What WOULD merge

    /// **The dry run.** Which rows WOULD merge, writing nothing.
    ///
    /// The old `reconcile(in:)` could not answer this: it fetched, repaired every alias
    /// index, merged
    /// and saves in one breath, so the only way to learn what it would do was to let it do it.
    /// A merge repoints lots, transactions and shopping lines and then DELETES rows, which is
    /// not something to perform on his behalf from a tap he did not understand, and faking a
    /// preview by merging and undoing would be worse than no preview at all — the undo is the
    /// part with no test.
    ///
    /// So the grouping moved here, and `reconcile` now calls this. One grouping, two callers:
    /// a preview computed by different code from the commit is not a preview.
    ///
    /// `static`, taking rows rather than a context, and writing nothing — including no
    /// `reindex`, which `reconcile` still does and which is a WRITE. That is what makes this
    /// safe to call from a `body` (`PantryView` does, for the row count) and from a screen
    /// that has not been granted the right to change anything yet.
    static func duplicateGroups(among items: [FoodItem]) -> [DuplicateGroup] {
        groupedRows(among: items).map { describe($0) }
    }

    /// The grouping itself. Each element is survivor-first.
    ///
    /// **The survivor rule is a convergence requirement, not a preference**: earliest
    /// `createdAt`, tie-broken by lowest `id.uuidString`. Never a "best row" heuristic such as
    /// most-lots or longest-notes — two devices have to pick the SAME survivor with no
    /// coordination, or each merges into its own choice and the merge ping-pongs forever.
    ///
    /// Grouping is by every key a lookup can arrive on, his alias ROWS included, and it is
    /// transitive: if A shares a name key with B and B shares an alias key with C, all three
    /// are one purchase. A union-find keeps that from depending on the order the rows come
    /// back in.
    private static func groupedRows(among items: [FoodItem]) -> [[FoodItem]] {
        let ordered = items.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
        guard ordered.count > 1 else { return [] }

        var parent = Array(0..<ordered.count)
        var owner: [String: Int] = [:]

        for (index, item) in ordered.enumerated() {
            for key in identityKeys(of: item) {
                if let existing = owner[key] {
                    unite(index, existing, in: &parent)
                } else {
                    owner[key] = index
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for index in ordered.indices {
            let root = rootIndex(index, in: &parent)
            groups[root, default: []].append(index)
        }

        var out: [[FoodItem]] = []
        for root in groups.keys.sorted() {
            guard let members = groups[root]?.sorted(), members.count > 1 else { continue }
            // `ordered` is already in survivor order, so the lowest index IS the earliest
            // `createdAt` with the uuid tie-break applied.
            out.append(members.map { ordered[$0] })
        }
        return out
    }

    /// Every key a lookup can arrive on this row by. The alias ROWS, never `aliasBlob`: the
    /// blob is a derived index that a CloudKit merge can mangle, and grouping off it would
    /// make two rows stop looking like duplicates because their index was stale.
    private static func identityKeys(of item: FoodItem) -> [String] {
        var keys: [String] = []
        if !item.matchKey.isEmpty { keys.append(item.matchKey) }
        for alias in item.orderedAliases where !alias.matchKey.isEmpty {
            keys.append(alias.matchKey)
        }
        return keys
    }

    private static func signature(of rows: [FoodItem]) -> String {
        rows.map { $0.id.uuidString }.joined(separator: "|")
    }

    private static func describe(_ rows: [FoodItem]) -> DuplicateGroup {
        let survivor = rows[0]
        let losers = Array(rows.dropFirst())

        let absorbed = losers.map { loser in
            DuplicateGroup.Absorbed(
                id: loser.id,
                name: loser.displayName,
                lotCount: loser.orderedLots.count,
                transactionCount: loser.orderedTransactions.count,
                shoppingLineCount: loser.allShoppingLines.count,
                openShoppingLineCount: openShoppingLineCount(of: loser)
            )
        }

        // A key held by two or more rows in the group. Counted over every row rather than
        // intersected against the survivor's, because of the transitive case: the key that
        // joined two LOSERS is still the reason the group has three rows in it.
        var tally: [String: Int] = [:]
        for row in rows {
            for key in Set(identityKeys(of: row)) { tally[key, default: 0] += 1 }
        }

        return DuplicateGroup(
            survivorID: survivor.id,
            survivorName: survivor.displayName,
            absorbed: absorbed,
            sharedKeys: tally.filter { $0.value > 1 }.keys.sorted(),
            refusal: refusal(survivor: survivor, losers: losers)
        )
    }

    /// The same test `canDelete` applies to an open list, asked of one row.
    private static func openShoppingLineCount(of item: FoodItem) -> Int {
        item.allShoppingLines.filter { line in
            guard let list = line.list else { return false }
            return !list.isArchived && list.completedAt == nil
        }.count
    }

    /// The one group this app will not merge, and it is reachable rather than theoretical.
    ///
    /// `kosher salt` mints from the catalogue as a `.staple` — present or absent, no amount.
    /// NOTE ON REACHABILITY, because the story this rested on was wrong. It said "a receipt
    /// line the matcher could not place mints a BARE row, which defaults to `.tracked`" --
    /// and nothing in the tree mints a bare row. Both callers of `findOrCreate(name:...)`
    /// pass `createIfMissing: false`, every other mint goes through
    /// `findOrCreate(fromCatalog:)` and inherits the template's tracking mode, and
    /// `AddShoppingItemSheet` adds a typed name with no item at all.
    ///
    /// So this refusal is UNREACHABLE on today's call sites. It is kept rather than deleted
    /// because the condition it guards is real and the cost of being wrong is silent: a
    /// staple carries no quantity, so folding a tracked row into one discards its level with
    /// nothing on screen to say a number disappeared. The day anything mints a bare row --
    /// a runtime importer, a barcode answered freehand -- this is the guard that was already
    /// there. What it must not do is claim a reachability it does not have.
    ///
    /// Historically: a receipt line the matcher could not place would mint a BARE row, which
    /// defaults to `.tracked`, and he then puts a lot on it. Teach the app that the two names mean one
    /// thing (one tap on an unresolved line) and they are a group, with the staple surviving
    /// if it was created first. `merge` keeps the survivor's tracking mode — correctly; it has
    /// a value, so there is nothing absent to fill — so the lots and the purchase rows would
    /// land on a row `PantryLevels.level` renders as "Have it".
    ///
    /// The ledger would still hold every row. It would just have nowhere on screen to appear,
    /// which is the one outcome worse than two rows he can see.
    private static func refusal(survivor: FoodItem, losers: [FoodItem]) -> MergeRefusal? {
        guard !survivor.tracksQuantity else { return nil }
        let history = losers
            .filter { $0.tracksQuantity }
            .reduce(0) { $0 + $1.orderedLots.count + $1.orderedTransactions.count }
        guard history > 0 else { return nil }
        return MergeRefusal(
            reason: .wouldHideALevel,
            subjectName: survivor.displayName,
            affectedCount: history
        )
    }

    // MARK: - Merging

    /// Commit ONE previewed group, and only if it is still the group that was previewed.
    ///
    /// Takes the snapshot the screen showed, re-derives the grouping from `items`, and merges
    /// the group whose `signature` matches. That is the guard, and it belongs here rather than
    /// only in the screen: this is the thing that deletes rows, and a guard that lives only at
    /// one call site is not a guard — `canDelete`'s own comment makes the same point.
    ///
    /// `items` is every `FoodItem` in the store, which is what the caller's `@Query` already
    /// holds. Re-deriving from a subset would invent duplicates that are not there.
    @discardableResult
    func mergeDuplicate(
        _ planned: DuplicateGroup,
        among items: [FoodItem],
        in context: ModelContext
    ) throws -> MergeRecord {
        guard let rows = Self.groupedRows(among: items)
            .first(where: { Self.signature(of: $0) == planned.signature })
        else {
            throw MergeRefusal(reason: .changedSinceCheck, subjectName: planned.survivorName)
        }
        let survivor = rows[0]
        let losers = Array(rows.dropFirst())
        if let refused = Self.refusal(survivor: survivor, losers: losers) { throw refused }

        let record = try merge(losers, into: survivor, in: context)
        do {
            try context.save()
        } catch {
            // ROLLED BACK, which `MergeRefusal.couldNotSave`'s message already promised and
            // nothing delivered. By the time the save runs, `merge` has repointed every lot,
            // transaction and shopping line onto the survivor, inserted the `MergeRecord` and
            // deleted every loser -- all of it unsaved but all of it live in the context. The
            // message said "the merge could not be written"; without this the merge was
            // written to memory and left there, and this app relies on SwiftData AUTOSAVE, so
            // the next unrelated write would have committed a half-done merge nobody chose.
            //
            // Discarding the whole context is heavier than discarding the merge, and it is
            // the only thing a `ModelContext` offers. Acceptable here and only here: this
            // screen opens, previews and merges, so there is nothing else of his in flight.
            context.rollback()
            throw MergeRefusal(reason: .couldNotSave, subjectName: planned.survivorName)
        }
        return record
    }

    /// Fold `losers` into `survivor`, moving every referrer, and write the audit row Settings
    /// renders.
    ///
    /// A merge that happens silently is indistinguishable from data loss — and because
    /// `@Attribute(.unique)` is forbidden, merges are routine here rather than an emergency.
    @discardableResult
    func merge(
        _ losers: [FoodItem],
        into survivor: FoodItem,
        in context: ModelContext
    ) throws -> MergeRecord {
        var repointed = 0
        var absorbed: [(id: UUID, name: String)] = []

        for loser in losers {
            guard loser.id != survivor.id else { continue }
            absorbed.append((id: loser.id, name: loser.displayName))

            // The three referrer arrays, repointed. This is why the persistence side uses a
            // real relationship graph where the content side uses string ids: merging means
            // ENUMERATING referrers, which with inverses is three arrays and with a
            // `foodItemID: UUID?` is a full-store scan on every launch forever.
            //
            // `foodItemNameSnapshot` is deliberately NOT rewritten. It records what the row was
            // filed under at the time, which is exactly what an audit of a merge should
            // preserve; it is read only when the row has no item at all.
            for lot in loser.orderedLots {
                lot.item = survivor
                repointed += 1
            }
            for transaction in loser.orderedTransactions {
                transaction.item = survivor
                repointed += 1
            }
            for line in loser.allShoppingLines {
                line.foodItem = survivor
                repointed += 1
            }

            // His vocabulary survives the merge: the loser's own name becomes an alias of the
            // survivor, so the next line written the old way still resolves.
            if !loser.matchKey.isEmpty, loser.matchKey != survivor.matchKey,
               !survivor.orderedAliases.contains(where: { $0.matchKey == loser.matchKey }) {
                let row = FoodItemAlias.make(text: loser.displayName)
                context.insert(row)
                row.item = survivor
            }
            for alias in loser.orderedAliases {
                if alias.matchKey == survivor.matchKey
                    || survivor.orderedAliases.contains(where: { $0.matchKey == alias.matchKey }) {
                    // Already covered. Left behind it would be cascade-deleted with the loser
                    // anyway; deleting it here says so explicitly.
                    context.delete(alias)
                    continue
                }
                alias.item = survivor
            }

            // Absent scalars only, so a merge never overwrites something he set on the row he
            // kept. The tracking mode is not among them: it always has a value, so there is
            // nothing absent to fill and the survivor's answer stands.
            if survivor.catalogName.isEmpty { survivor.catalogName = loser.catalogName }
            if !survivor.hasDensity, let density = loser.gramsPerCup {
                survivor.setDensity(density)
            }
            if !survivor.hasParLevel, let par = loser.parLevel {
                survivor.setParLevel(par)
            }
            if survivor.defaultSection == nil { survivor.defaultSection = loser.defaultSection }
            if survivor.defaultLocation == nil { survivor.defaultLocation = loser.defaultLocation }
            if survivor.producedByRecipeID.isEmpty {
                survivor.producedByRecipeID = loser.producedByRecipeID
            }
            if survivor.notes.isEmpty { survivor.notes = loser.notes }
            // "Running low" is a claim about the kitchen, so either row claiming it keeps it.
            if loser.isRunningLow { survivor.isRunningLow = true }

            context.delete(loser)
        }

        reindex(survivor)

        let record = MergeRecord.make(
            entityName: "FoodItem",
            survivorID: survivor.id,
            survivorName: survivor.displayName,
            absorbed: absorbed,
            repointedCount: repointed,
            note: ""
        )
        // An audit row for a merge that moved nothing is noise in a Settings list he reads to
        // check the app did what it said. The record is still returned, so the caller's
        // signature is total.
        if !absorbed.isEmpty { context.insert(record) }
        return record
    }

    /// Repairs the alias INDEX, and no longer merges anything.
    ///
    /// This was `reconcile(in:)`, "written to run on launch and still without a caller
    /// there" — its own doc comment said so. A review pointed out that the claim it had
    /// gained one was false: `MergeDuplicatesView` calls the new `duplicateGroups(among:)`
    /// and `mergeDuplicate(_:among:in:)`, not this, so this stayed an orphan.
    ///
    /// Splitting it rather than giving it a caller, because it did two things of opposite
    /// character. The merge half **should never run unattended** — silently folding two
    /// foods he considers different is worse than leaving both, which is why the screen
    /// shows a group and waits. It is gone; the screen supersedes it.
    ///
    /// The repair half is worth running every launch and is not destructive. `aliasBlob` is
    /// the predicate-queryable index over the alias ROWS, and the rows are the truth. A
    /// CloudKit merge of two devices that each added an alias can leave the blob disagreeing
    /// with them, and then the alias predicate stops finding a row that plainly has the
    /// alias — a lookup failure with no visible cause. Rebuilding from the rows is
    /// idempotent and cheap.
    ///
    /// Returns how many rows it rewrote, so a caller can say nothing happened.
    @discardableResult
    func repairAliasIndex(in context: ModelContext) throws -> Int {
        let items = try context.fetch(FetchDescriptor<FoodItem>())
        var rewritten = 0
        for item in items {
            let rebuilt = item.rebuiltAliasBlob()
            guard rebuilt != item.aliasBlob else { continue }
            item.aliasBlob = rebuilt
            rewritten += 1
        }
        return rewritten
    }

    /// Iterative with path compression, and `inout` rather than a captured `var`, because a
    /// nested function mutating its enclosing scope is the kind of construct this project
    /// cannot risk without a compiler to ask.
    private static func rootIndex(_ index: Int, in parent: inout [Int]) -> Int {
        var node = index
        while parent[node] != node { node = parent[node] }
        var walk = index
        while parent[walk] != node {
            let next = parent[walk]
            parent[walk] = node
            walk = next
        }
        return node
    }

    private static func unite(_ a: Int, _ b: Int, in parent: inout [Int]) {
        let rootA = rootIndex(a, in: &parent)
        let rootB = rootIndex(b, in: &parent)
        guard rootA != rootB else { return }
        // The LOWER index wins, which — because the caller sorted the rows first — is the
        // earliest `createdAt`. Two devices computing this on the same rows reach the same
        // root.
        if rootA < rootB {
            parent[rootB] = rootA
        } else {
            parent[rootA] = rootB
        }
    }

    // MARK: - Deleting

    /// Refuses a delete that would orphan history, so the caller can offer "merge into..."
    /// instead.
    ///
    /// The schema already guarantees nothing is destroyed (`.nullify` on both ledger edges);
    /// this exists so he is told what would happen before it does, and `.deny` is not
    /// available under CloudKit anyway. A guard that lives ONLY here is not a guard — any
    /// other call site bypasses it — which is why it is the courtesy and the delete rules are
    /// the protection.
    func canDelete(_ item: FoodItem) -> Result<Void, DeleteRefusal> {
        let history = (item.lots ?? []).count + (item.transactions ?? []).count
        if history > 0 {
            return .failure(DeleteRefusal(
                reason: .hasLedgerHistory,
                subjectName: item.displayName,
                affectedCount: history
            ))
        }

        let openLines = item.allShoppingLines.filter { line in
            guard let list = line.list else { return false }
            return !list.isArchived && list.completedAt == nil
        }
        if !openLines.isEmpty {
            return .failure(DeleteRefusal(
                reason: .isOnOpenShoppingList,
                subjectName: item.displayName,
                affectedCount: openLines.count
            ))
        }

        return .success(())
    }
}
