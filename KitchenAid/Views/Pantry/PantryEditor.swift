import Foundation
import SwiftData

/// The pantry's writes, in one place, mirroring `HouseholdEditor` and `PlanEditor`.
///
/// Almost everything here is a thin call into `InventoryLedger`, and that is the point: the
/// ledger is **the only place an `InventoryTransaction` is created** and the only thing that
/// moves a lot's cache and the ledger together. A view that inserted a transaction itself
/// would be a call site that forgets the cache, and the drift would not surface until the
/// reconcile screen reported it months later with nothing to blame.
///
/// Only the three functions that write through the ledger are `@MainActor`, because it is.
/// The rest set a property and save, so isolating them would isolate every caller for
/// nothing.
enum PantryEditor {

    // MARK: - Putting stock away

    /// A new lot, and the `.purchase` row that gives it its level.
    ///
    /// The order is copied from `InventoryLedger.receive(_:in:)` and matters: insert the lot,
    /// then point it at its item and location, THEN `apply`, because `apply` recomputes the
    /// lot cache from the rows filed against it and a row written before the lot is in the
    /// context has nothing to be filed against.
    ///
    /// `setOriginal` records what the package held when it arrived. `remaining` is never
    /// written here — it is a cache, and `apply` rebuilds it from the ledger.
    @MainActor
    @discardableResult
    static func addLot(
        for item: FoodItem,
        quantity: Quantity,
        location: StorageLocation?,
        acquiredAt: Date = .now,
        expiresAt: Date? = nil,
        label: String = "",
        notes: String = "",
        priceCents: Int? = nil,
        using ledger: InventoryLedger,
        in context: ModelContext
    ) -> StockLot? {
        guard item.tracksQuantity, quantity.amount > .zero else { return nil }

        let lot = StockLot(
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            foodItemNameSnapshot: item.displayName
        )
        lot.setOriginal(quantity)
        // BOTH money fields, and this is their only writer anywhere.
        //
        // `InventoryTransaction.priceCents` is the ledger's money column — what
        // `receive(_:in:)` posts for a finished shop, and what any future spend report would
        // sum. `StockLot.unitCostCents` is what THIS package cost, which is what the lot
        // screen shows. Before this they had no writer at all, and a field nothing writes is
        // how purchase-unit rounding came to ship a mechanism with no data source (CLAUDE.md).
        lot.unitCostCents = priceCents
        context.insert(lot)
        lot.item = item
        lot.location = location

        ledger.apply(
            kind: .purchase,
            delta: quantity,
            to: item,
            lot: lot,
            priceCents: priceCents,
            at: acquiredAt,
            in: context
        )
        // Remembered so the next lot of this item defaults to the same shelf, which is what
        // "the butter lives in the fridge" means in practice.
        if item.defaultLocation == nil { item.defaultLocation = location }
        save(context)
        return lot
    }

    /// A staple is present or absent with **no quantity** (CLAUDE.md), so this writes one
    /// Bool and no ledger row. Counting teaspoons of salt is work nobody does, and there is
    /// deliberately nothing here to count.
    ///
    /// The same assignment `InventoryLedger.receive` makes when a staple is on a finished
    /// list, which is why neither path mints a lot.
    static func setStaplePresent(_ item: FoodItem, isPresent: Bool, in context: ModelContext) {
        item.isRunningLow = !isPresent
        save(context)
    }

    // MARK: - Adjusting what is there

    /// Any correction that is not a purchase and not a cook: a manual adjustment, waste, a
    /// gift, or a count.
    ///
    /// `amount` is always POSITIVE — he types "2 cups", not "-2 cups" — and the sign comes
    /// from the kind through `PantryLevels.isDepletion`. A `.manualAdjustment` is the one
    /// kind that can go either way, so it takes `isIncrease` from the caller.
    @MainActor
    @discardableResult
    static func adjust(
        item: FoodItem,
        lot: StockLot?,
        kind: TransactionKind,
        amount: Quantity,
        isIncrease: Bool,
        note: String = "",
        at occurredAt: Date = .now,
        using ledger: InventoryLedger,
        in context: ModelContext
    ) -> InventoryTransaction? {
        guard item.tracksQuantity, amount.amount > .zero else { return nil }
        let signed = isIncrease
            ? amount
            : Quantity(amount: amount.amount.negated, unit: amount.unit)
        let transaction = ledger.apply(
            kind: kind,
            delta: signed,
            to: item,
            lot: lot,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            at: occurredAt,
            in: context
        )
        save(context)
        return transaction
    }

    /// "I counted it, there are 3 lb." An absolute, turned into the delta that makes the
    /// ledger agree with the shelf.
    ///
    /// Written as a row like everything else rather than by overwriting a number: the ledger
    /// is append-only, so "how did it get to 3 lb" stays answerable, and a count that
    /// disagreed with the ledger leaves the size of the disagreement visible in the history.
    /// The delta is taken against the matching dimension ONLY — a count in cups says nothing
    /// about the pound in the freezer, and they are separate buckets until a density bridges
    /// them.
    @MainActor
    @discardableResult
    static func recordCount(
        item: FoodItem,
        lot: StockLot?,
        counted: Quantity,
        note: String = "",
        at occurredAt: Date = .now,
        using ledger: InventoryLedger,
        in context: ModelContext
    ) -> InventoryTransaction? {
        guard item.tracksQuantity, counted.unit.baseFactor != .zero else { return nil }
        let have = PantryLevels.level(of: item, using: ledger).subtotals
            .first { $0.dimensionKey == counted.dimensionKey }?.base ?? .zero
        let deltaBase = counted.base - have
        let delta = Quantity(amount: deltaBase / counted.unit.baseFactor, unit: counted.unit)
        let transaction = ledger.apply(
            kind: .inventoryCount,
            delta: delta,
            to: item,
            lot: lot,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            at: occurredAt,
            in: context
        )
        save(context)
        return transaction
    }

    // MARK: - The item's own settings

    /// The minimum he wants kept on hand. Through `setParLevel`, which writes all five
    /// primitives together — assigning the amount while leaving `parLevelUnitCode` behind
    /// leaves a row with no par level that still claims a unit.
    static func setPar(_ item: FoodItem, to par: Quantity?, in context: ModelContext) {
        item.setParLevel(par)
        save(context)
    }

    /// Grams per US cup, which is the one thing that lets volume and mass meet for this item.
    ///
    /// Worth a control of its own because it is the fix for a whole class of problem rather
    /// than one row: a `.pendingBridge` depletion, a `needs weight per cup` badge on a
    /// shopping line and a par in cups that cannot be compared to a pound in the freezer are
    /// all the same missing number. Through `setDensity`, which writes the Bool and the pair
    /// together — the numbers alone leave `gramsPerCup` nil and the bridge silently dead.
    static func setDensity(_ item: FoodItem, gramsPerCup: Int?, in context: ModelContext) {
        if let grams = gramsPerCup, grams > 0 {
            item.setDensity(Rational(grams))
        } else {
            item.setDensity(nil)
        }
        save(context)
    }

    static func setNotes(_ item: FoodItem, to notes: String, in context: ModelContext) {
        item.notes = notes
        save(context)
    }

    // MARK: - Lots

    /// Opening a lot is not a quantity change, so it writes no ledger row — but it changes
    /// which lot is drawn down first: `lotsForDepletion` prefers an already-opened lot,
    /// because you finish the open butter before cutting a new stick.
    static func setOpen(_ lot: StockLot, isOpen: Bool, at date: Date = .now, in context: ModelContext) {
        lot.openedAt = isOpen ? date : nil
        save(context)
    }

    static func setExpiry(_ lot: StockLot, to date: Date?, in context: ModelContext) {
        lot.expiresAt = date
        save(context)
    }

    static func move(_ lot: StockLot, to location: StorageLocation?, in context: ModelContext) {
        lot.location = location
        save(context)
    }

    /// Deleting a lot keeps its ledger rows: `StockLot.transactions` is `.nullify`, which is
    /// the whole reason a level is summed from the ITEM's transactions. The rows become the
    /// unassigned bucket the reconcile screen names, so the level does not change and nothing
    /// silently stops counting. The caller says so before offering this.
    static func delete(_ lot: StockLot, in context: ModelContext) {
        context.delete(lot)
        save(context)
    }

    // MARK: - Storage locations

    /// Added at the end of the walk. `setName` keeps `matchKey` in step, which is what the
    /// seed matches against so a hand-added "Garage fridge" is not duplicated by a later one.
    @discardableResult
    static func addLocation(
        name: String,
        kind: StorageKind,
        symbolName: String,
        shelfLifeDays: Int?,
        existing: [StorageLocation],
        in context: ModelContext
    ) -> StorageLocation {
        let location = StorageLocation()
        context.insert(location)
        location.setName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        location.kindRaw = kind.rawValue
        location.symbolName = symbolName
        location.defaultShelfLifeDays = shelfLifeDays
        location.sortIndex = (existing.reduce(-1) { max($0, $1.sortIndex) }) + 1
        save(context)
        return location
    }

    static func update(
        _ location: StorageLocation,
        name: String,
        kind: StorageKind,
        symbolName: String,
        shelfLifeDays: Int?,
        in context: ModelContext
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { location.setName(trimmed) }
        location.kindRaw = kind.rawValue
        location.symbolName = symbolName
        location.defaultShelfLifeDays = shelfLifeDays
        save(context)
    }

    /// Refuses the last one, in the words `DeleteRefusal` already uses for it, so the roster,
    /// the default store and this all refuse alike. A location with lots in it CAN go — the
    /// edge is `.nullify`, so the lots survive in the "No location" group — and the caller
    /// says that in the confirmation rather than discovering it afterwards.
    static func canDelete(_ location: StorageLocation, of all: [StorageLocation]) -> Result<Void, DeleteRefusal> {
        guard all.count > 1 else {
            return .failure(DeleteRefusal(
                reason: .isOnlyStorageLocation,
                subjectName: location.displayName,
                affectedCount: location.orderedLots.count
            ))
        }
        return .success(())
    }

    static func delete(_ location: StorageLocation, in context: ModelContext) {
        context.delete(location)
        save(context)
    }

    // MARK: - Money

    /// "4.99" or "$4.99" as cents, by integer arithmetic. `Double` would be the obvious
    /// route and is wrong for the same reason `Rational` exists: 4.99 is not representable,
    /// and a grocery total that is a cent out every few lines is a total he stops trusting.
    static func cents(from text: String) -> Int? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.replacingOccurrences(of: "$", with: "")
        trimmed = trimmed.replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let wholeText = parts[0].isEmpty ? "0" : String(parts[0])
        guard let whole = Int(wholeText), whole >= 0 else { return nil }
        guard parts.count == 2 else { return whole * 100 }

        var fraction = String(parts[1].prefix(2))
        if fraction.isEmpty { fraction = "00" }
        if fraction.count == 1 { fraction += "0" }
        guard let fractional = Int(fraction), fractional >= 0 else { return nil }
        return whole * 100 + fractional
    }

    /// Cents as "$4.99", without a `NumberFormatter`: this is one number in one currency on
    /// one person's phone, and the formatter would be more machinery than the problem.
    static func priceText(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let value = abs(cents)
        let fraction = value % 100
        let padded = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        return "\(sign)$\(value / 100).\(padded)"
    }

    /// `try?`, and deliberately: a failed save inside a SwiftUI action has no recovery
    /// available on a family phone, and propagating it out of the button does not create one.
    /// The same call `TweakStore.save()` and `InventoryLedger.resolve` make.
    private static func save(_ context: ModelContext) {
        try? context.save()
    }
}
