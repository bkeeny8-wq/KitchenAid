import Foundation
import SwiftData

/// Everything the pantry screens READ, in one place.
///
/// **Nothing in this file ever adds up `StockLot.remaining`.** Every level comes from
/// `InventoryLedger.level(of:in:)`, which sums the item's TRANSACTIONS. The reason is written
/// at length on `FoodItem.levelContributions` and worth repeating where a screen could get it
/// wrong: `StockLot.transactions` is `.nullify`, so a lot deleted by hand leaves its ledger
/// rows behind with `lot == nil`. A screen that summed lots would silently stop counting
/// them, and the gap would be a divergence `reconcileReport` could never attribute to
/// anything or clear — the numbers would just disagree, with nothing to point at.
///
/// Only the three functions that take an `InventoryLedger` are `@MainActor`, and only
/// because it is: it reads through `container.mainContext`, the context `@Query` hands the
/// views. The rest sort, group and word things, so isolating them would make every caller
/// isolated for no gain — the same split `HouseholdEditor` and `PlanEditor` already use.
enum PantryLevels {

    // MARK: - One item's level

    /// What `level(of:in:)` returned, plus the one string the rows render.
    ///
    /// The flags ride along because `level` is the only thing in the system that can see a
    /// lot's `expiresAt`: `.expiredStockIgnored` means there IS stock and it is past its date,
    /// which is a different sentence from "none on hand" and has to read differently.
    struct Level {
        var subtotals: [QuantitySubtotal] = []
        var flags: Set<LineFlag> = []
        var text: String = ""
        /// Nothing countable. Not the same as zero: an item with no rows at all and an item
        /// whose rows cancel to zero both land here, and neither is worth two sentences.
        var isEmpty: Bool = true
    }

    @MainActor
    static func level(
        of item: FoodItem,
        in location: StorageLocation? = nil,
        using ledger: InventoryLedger
    ) -> Level {
        // A staple is present or absent with NO quantity (CLAUDE.md). Summing one would be
        // answering a question he deliberately did not ask.
        if item.isStaple {
            return Level(text: item.isRunningLow ? "Out" : "Have it", isEmpty: false)
        }
        if !item.tracksQuantity {
            return Level(text: "Not tracked", isEmpty: false)
        }

        let result = ledger.level(of: item, in: location)
        let parts = result.subtotals.compactMap { subtotal -> String? in
            guard subtotal.base != .zero else { return nil }
            // `displayString`, never `exactDescription`: that is how a label came to read
            // "23 1111/1135 tsp" (SPEC_REVIEW_03 finding 8).
            return subtotal.displayString(system: ledger.unitSystem)
        }
        guard !parts.isEmpty else {
            let text = result.flags.contains(.expiredStockIgnored)
                ? "None in date"
                : "None on hand"
            return Level(subtotals: result.subtotals, flags: result.flags, text: text)
        }
        // Two subtotals on one item is normal and not an error: a pound of butter in the
        // freezer and 3 tablespoons open in the fridge are different buckets until a density
        // bridges them, and the ledger refuses to guess one.
        return Level(
            subtotals: result.subtotals,
            flags: result.flags,
            text: parts.joined(separator: " + "),
            isEmpty: false
        )
    }

    // MARK: - Par levels

    /// Whether an item is below the minimum he wants kept, and by how much.
    ///
    /// The arithmetic is `QuantityMath.subtract` — the same call the shopping builder uses —
    /// rather than a comparison written here. That is deliberate: it clamps the have side
    /// before subtracting (a negative volume residue from cooking would otherwise INFLATE the
    /// shortfall), and it gives the density bridge its chance, so a par in cups against stock
    /// in grams is answered rather than flagged whenever the item carries a weight per cup.
    ///
    /// `ShoppingListBuilder.materialize` takes `parLevelShortfalls: [(FoodItem,
    /// QuantitySubtotal)]` from its caller and nothing in the tree computed it yet. This is
    /// that computation, so the Shop screen can feed the builder from here rather than
    /// growing a second one.
    struct ParStatus {
        var par: Quantity
        /// nil when the par is met. `subtract` drops a zero remainder, which is exactly the
        /// "met" case, so there is no zero row to mistake for a shortfall.
        var shortfall: QuantitySubtotal?
        var flags: Set<LineFlag> = []

        var isBelow: Bool { shortfall != nil }

        /// The par and the stock are in dimensions no density can bridge, so the shortfall
        /// below is the WHOLE par — nothing was assumed on hand. Said out loud rather than
        /// shown as a number he would read as a measurement.
        var cannotCompare: Bool { flags.contains(.needsBridge) }

        func parText(system: UnitSystem) -> String { par.displayString(system: system) }

        func shortfallText(system: UnitSystem) -> String {
            guard let shortfall = shortfall else { return "" }
            return shortfall.displayString(system: system)
        }
    }

    struct ParRow: Identifiable {
        var item: FoodItem
        var status: ParStatus
        var id: UUID { item.id }
    }

    @MainActor
    static func parStatus(for item: FoodItem, using ledger: InventoryLedger) -> ParStatus? {
        guard item.tracksQuantity, let par = item.parLevel, par.amount > .zero else { return nil }
        let requested = [
            QuantitySubtotal(
                dimensionKey: par.dimensionKey, base: par.base, preferredUnit: par.unit
            )
        ]
        let have = level(of: item, using: ledger).subtotals
        let result = QuantityMath.subtract(
            requested: requested, have: have, item: item, system: ledger.unitSystem
        )
        return ParStatus(par: par, shortfall: result.toBuy.first, flags: result.flags)
    }

    @MainActor
    static func belowPar(in items: [FoodItem], using ledger: InventoryLedger) -> [ParRow] {
        var rows: [ParRow] = []
        for item in items {
            guard let status = parStatus(for: item, using: ledger), status.isBelow else {
                continue
            }
            rows.append(ParRow(item: item, status: status))
        }
        return rows.sorted { byName($0.item, $1.item) }
    }

    // MARK: - Grouping by where the food sits

    /// One storage location and the items with a lot in it.
    ///
    /// An item appears in EVERY location it has a lot in, which is the whole reason lots
    /// exist: butter is in the fridge and the freezer at once, with different dates, and a
    /// screen that filed it under one of them would be hiding half of it.
    struct LocationGroup: Identifiable {
        var location: StorageLocation?
        var items: [FoodItem] = []

        var id: String { location?.id.uuidString ?? "unassigned" }
        var title: String { location?.displayName ?? "No location" }
        var symbol: String { location?.symbolName ?? "questionmark.folder" }
    }

    static func groups(locations: [StorageLocation], items: [FoodItem]) -> [LocationGroup] {
        var out: [LocationGroup] = []
        for location in ordered(locations) {
            let rows = distinctItems(location.orderedLots)
            if !rows.isEmpty {
                out.append(LocationGroup(location: location, items: rows))
            }
        }
        // Lots filed nowhere. `StockLot.location` is optional because every relationship in
        // this schema is (CloudKit), so this bucket is reachable — by a lot added before any
        // location existed, or by one whose location he deleted, which is `.nullify` and
        // keeps the lot. It is named rather than dropped.
        let strays = distinctItems(items.flatMap { $0.orderedLots }.filter { $0.location == nil })
        if !strays.isEmpty {
            out.append(LocationGroup(location: nil, items: strays))
        }
        return out
    }

    static func ordered(_ locations: [StorageLocation]) -> [StorageLocation] {
        locations.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    /// Items with no lot anywhere, staples excepted — they have their own section and no
    /// quantity to have.
    ///
    /// They still belong on the screen: an item minted by a shopping list he never put away,
    /// or one whose lots he deleted, has a level made entirely of unassigned rows and would
    /// otherwise be invisible. An `.untracked` item lives here too, reading "Not tracked",
    /// because it is a row he owns and a screen that hid it would look like it lost it.
    static func unstocked(in items: [FoodItem]) -> [FoodItem] {
        items.filter { !$0.isStaple && $0.orderedLots.isEmpty }.sorted(by: byName)
    }

    static func staples(in items: [FoodItem]) -> [FoodItem] {
        items.filter { $0.isStaple }.sorted(by: byName)
    }

    static func staplesOut(in items: [FoodItem]) -> [FoodItem] {
        staples(in: items).filter { $0.isRunningLow }
    }

    private static func distinctItems(_ lots: [StockLot]) -> [FoodItem] {
        var seen = Set<UUID>()
        var out: [FoodItem] = []
        for lot in lots {
            guard let item = lot.item else { continue }
            if seen.insert(item.id).inserted { out.append(item) }
        }
        return out.sorted(by: byName)
    }

    /// `localizedStandardCompare`, so "Butter" and "butter" sort together and "Item 10" sorts
    /// after "Item 9".
    static func byName(_ a: FoodItem, _ b: FoodItem) -> Bool {
        a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }

    // MARK: - Dates

    /// "Best by 14 Nov, in 7 days" / "Expired 3 days ago" / "No date".
    ///
    /// Day-granular, because `StorageLocation.suggestedExpiry` is: a shelf life measured to
    /// the second is false precision on a date he reads as "around the 14th".
    static func expiryText(for lot: StockLot, asOf now: Date = .now) -> String {
        guard let expiry = lot.expiresAt else { return "No date" }
        let date = expiry.formatted(date: .abbreviated, time: .omitted)
        guard let days = lot.daysUntilExpiry(asOf: now) else { return "Best by \(date)" }
        if days < 0 {
            let ago = -days
            return ago == 1 ? "Expired yesterday" : "Expired \(ago) days ago"
        }
        if days == 0 { return "Best by today" }
        if days == 1 { return "Best by tomorrow" }
        return "Best by \(date), in \(days) days"
    }

    static func dayText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Ledger rows, as words

    static func title(for kind: TransactionKind) -> String {
        switch kind {
        case .purchase: return "Bought"
        case .cookDepletion: return "Cooked"
        case .waste: return "Thrown out"
        case .manualAdjustment: return "Adjusted"
        case .correction: return "Corrected"
        case .inventoryCount: return "Counted"
        case .giftOut: return "Given away"
        }
    }

    static func symbol(for kind: TransactionKind) -> String {
        switch kind {
        case .purchase: return "cart"
        case .cookDepletion: return "flame"
        case .waste: return "trash"
        case .manualAdjustment: return "slider.horizontal.3"
        case .correction: return "arrow.uturn.backward"
        case .inventoryCount: return "number"
        case .giftOut: return "gift"
        }
    }

    /// Which kinds mean food LEFT the kitchen. Used to pick the sign for a row the person
    /// enters as a plain positive amount — he types "2 cups", not "-2 cups".
    static func isDepletion(_ kind: TransactionKind) -> Bool {
        switch kind {
        case .cookDepletion, .waste, .giftOut: return true
        case .purchase, .manualAdjustment, .correction, .inventoryCount: return false
        }
    }

    /// What one ledger row reads as. `delta?.displayString` and "—" for a `.pendingBridge`
    /// row, which has no number by design: a cook depletion needing a density the item does
    /// not carry is RECORDED rather than guessed.
    static func amountText(for transaction: InventoryTransaction, system: UnitSystem) -> String {
        guard let delta = transaction.delta else { return "\u{2014}" }
        return delta.displayString(system: system)
    }

    // MARK: - Fetching one row back

    /// `LedgerDivergence` carries ids rather than objects, so the reconcile screen needs this
    /// to offer "open the item". Scoped and limited; nothing here scans the store.
    static func item(withID id: UUID, in context: ModelContext) -> FoodItem? {
        let needle = id
        var descriptor = FetchDescriptor<FoodItem>(predicate: #Predicate<FoodItem> {
            $0.id == needle
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    static func lot(withID id: UUID, in context: ModelContext) -> StockLot? {
        let needle = id
        var descriptor = FetchDescriptor<StockLot>(predicate: #Predicate<StockLot> {
            $0.id == needle
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
