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
    /// If the key he typed is already another item's identity, this still records it and
    /// `reconcile(in:)` then merges the two rows, because they now share a key. That is the
    /// correct outcome: he has told the app the two names mean one thing.
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

    /// Rebuilds `aliasBlob` from the rows. The ROWS are the truth; the blob is the
    /// predicate-queryable index over them, rebuilt and never appended to — append to it
    /// directly and a CloudKit merge of two devices that each added an alias silently loses
    /// one, and "scallion" and "green onion" stop collapsing into one purchase.
    func reindex(_ item: FoodItem) {
        item.aliasBlob = item.rebuiltAliasBlob()
    }

    // MARK: - Merging

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

    /// The deterministic de-dup pass, run on launch.
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
    @discardableResult
    func reconcile(in context: ModelContext) throws -> [MergeRecord] {
        let items = try context.fetch(FetchDescriptor<FoodItem>()).sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
        guard items.count > 1 else {
            if let only = items.first { reindex(only) }
            return []
        }

        var parent = Array(0..<items.count)
        var owner: [String: Int] = [:]

        for (index, item) in items.enumerated() {
            // Repair the index while we are here: a blob that a CloudKit merge mangled, or
            // that a writer appended to by hand, stops the alias predicate finding a row that
            // plainly has the alias.
            reindex(item)

            var keys: [String] = []
            if !item.matchKey.isEmpty { keys.append(item.matchKey) }
            for alias in item.orderedAliases where !alias.matchKey.isEmpty {
                keys.append(alias.matchKey)
            }

            for key in keys {
                if let existing = owner[key] {
                    Self.unite(index, existing, in: &parent)
                } else {
                    owner[key] = index
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for index in items.indices {
            let root = Self.rootIndex(index, in: &parent)
            groups[root, default: []].append(index)
        }

        var records: [MergeRecord] = []
        for root in groups.keys.sorted() {
            guard let members = groups[root]?.sorted(), members.count > 1 else { continue }
            // `items` is already in survivor order, so the lowest index IS the earliest
            // `createdAt` with the uuid tie-break applied.
            let rows = members.map { items[$0] }
            let survivor = rows[0]
            let record = try merge(Array(rows.dropFirst()), into: survivor, in: context)
            records.append(record)
        }

        if !records.isEmpty { try context.save() }
        return records
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
