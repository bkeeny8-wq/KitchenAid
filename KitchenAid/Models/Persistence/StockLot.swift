import Foundation
import SwiftData

/// One physical lot: this bag of flour, in this location, with this best-by.
///
/// Lots rather than one level per item because butter is simultaneously in the fridge and the
/// freezer with different expiries, because FIFO depletion needs per-lot dates, and because
/// "what is about to go bad" is the single most useful inventory screen. The cost is more
/// rows and more arithmetic. Accepted, knowingly.
@Model
final class StockLot {
    var id: UUID = UUID()

    // MARK: `remaining` is a CACHE, not truth
    //
    // The truth is the signed sum of the ITEM's `InventoryTransaction` rows. This cache
    // exists because "do I have enough butter" runs on every shopping-list build and every
    // recipe detail render, and summing a multi-year transaction log per item per render is
    // not viable.
    //
    // Every mutation goes through `InventoryLedger`, which writes both. `recompute(lot:)`
    // rebuilds it from the rows, and `reconcileReport` SURFACES divergence in Settings
    // rather than hiding it. A cache that silently drifts is worse than no cache; a cache
    // that reports its own drift is fine.
    var remainingHasQuantity: Bool = false
    var remainingNumerator: Int = 0
    var remainingDenominator: Int = 1
    var remainingUnitCode: String = ""
    var remainingDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    /// When the cache above was last rebuilt from the ledger. Written by the same call that
    /// writes the cache — see `setRemaining(_:rebuiltAt:)` — because a reconcile screen
    /// reporting a drift next to a stale timestamp is reporting the wrong thing.
    var cacheRebuiltAt: Date = .now

    var originalHasQuantity: Bool = false
    var originalNumerator: Int = 0
    var originalDenominator: Int = 1
    var originalUnitCode: String = ""
    var originalDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    var acquiredAt: Date = .now
    var expiresAt: Date? = nil
    var openedAt: Date? = nil

    /// Cents, and `Int?` because zero is a meaningful price and absent is not.
    var unitCostCents: Int? = nil

    var label: String = ""                  // "Costco 2-pack", "the big bag", "from Mom"
    var notes: String = ""

    /// Kept so a lot orphaned by a stray item delete is still readable in the reconcile
    /// screen. Same snapshot discipline as `MealAttendance.eaterNameSnapshot`.
    var foodItemNameSnapshot: String = ""

    /// Macro lives on `FoodItem.lots`, and it is `.nullify` — see the long comment there.
    var item: FoodItem? = nil
    /// Macro lives on `StorageLocation.lots`.
    var location: StorageLocation? = nil

    /// `.nullify`, and a level sums the ITEM's transactions rather than its lots.
    ///
    /// If this cascaded, deleting a lot would delete ledger rows — the one thing the whole
    /// append-only design exists to prevent. If it nullified while a level summed LOTS, an
    /// orphaned transaction would remain in the ledger and silently stop contributing,
    /// producing a divergence `reconcileReport` could never attribute or clear: the numbers
    /// would simply disagree, with nothing to point at. Summing at the item level means an
    /// orphan still counts, into an explicit "unassigned lot" bucket the reconcile screen
    /// names.
    ///
    /// So this edge is a cache home and an attribution aid, not a parent.
    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.lot)
    var transactions: [InventoryTransaction]? = []

    init(
        id: UUID = UUID(),
        remainingHasQuantity: Bool = false,
        remainingNumerator: Int = 0,
        remainingDenominator: Int = 1,
        remainingUnitCode: String = "",
        remainingDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        cacheRebuiltAt: Date = .now,
        originalHasQuantity: Bool = false,
        originalNumerator: Int = 0,
        originalDenominator: Int = 1,
        originalUnitCode: String = "",
        originalDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        acquiredAt: Date = .now,
        expiresAt: Date? = nil,
        openedAt: Date? = nil,
        unitCostCents: Int? = nil,
        label: String = "",
        notes: String = "",
        foodItemNameSnapshot: String = "",
        item: FoodItem? = nil,
        location: StorageLocation? = nil
    ) {
        self.id = id
        self.remainingHasQuantity = remainingHasQuantity
        self.remainingNumerator = remainingNumerator
        self.remainingDenominator = remainingDenominator
        self.remainingUnitCode = remainingUnitCode
        self.remainingDimensionRaw = remainingDimensionRaw
        self.cacheRebuiltAt = cacheRebuiltAt
        self.originalHasQuantity = originalHasQuantity
        self.originalNumerator = originalNumerator
        self.originalDenominator = originalDenominator
        self.originalUnitCode = originalUnitCode
        self.originalDimensionRaw = originalDimensionRaw
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.openedAt = openedAt
        self.unitCostCents = unitCostCents
        self.label = label
        self.notes = notes
        self.foodItemNameSnapshot = foodItemNameSnapshot
        self.item = item
        self.location = location
    }
}

// MARK: - Accessors

extension StockLot {
    /// Two quantities on one row, so this type cannot conform to `QuantityCarrying` — a type
    /// may conform once. It uses the same five-primitive SHAPE twice with distinct prefixes,
    /// which is the whole reason that protocol is a convenience rather than the contract.
    var remaining: Quantity? {
        guard remainingHasQuantity,
              let unit = UnitCatalog.unit(
                  code: remainingUnitCode,
                  fallbackDimension: MeasureDimension(rawValue: remainingDimensionRaw)
              )
        else { return nil }
        return Quantity(
            amount: Rational(remainingNumerator, max(1, remainingDenominator)),
            unit: unit
        )
    }

    var original: Quantity? {
        guard originalHasQuantity,
              let unit = UnitCatalog.unit(
                  code: originalUnitCode,
                  fallbackDimension: MeasureDimension(rawValue: originalDimensionRaw)
              )
        else { return nil }
        return Quantity(
            amount: Rational(originalNumerator, max(1, originalDenominator)),
            unit: unit
        )
    }

    var isOpen: Bool { openedAt != nil }

    var itemDisplayName: String {
        if let item, !item.name.isEmpty { return item.name }
        return foodItemNameSnapshot.isEmpty ? "Unassigned item" : foodItemNameSnapshot
    }

    /// An orphan — `item == nil` after a stray delete — still has to be nameable and
    /// re-pointable in the reconcile screen, which is the only reason the snapshot exists.
    var isOrphaned: Bool { item == nil }

    func expires(before date: Date) -> Bool {
        guard let e = expiresAt else { return false }
        return e < date
    }

    /// A lot with no best-by never expires. Inventing a date for it would put a number he
    /// shops by on a guess.
    func isExpired(asOf date: Date = .now) -> Bool { expires(before: date) }

    func daysUntilExpiry(asOf date: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let e = expiresAt else { return nil }
        let start = calendar.startOfDay(for: date)
        let end = calendar.startOfDay(for: e)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    /// The transaction rows filed against this lot. Present for attribution in the reconcile
    /// screen; a LEVEL is never summed from here (see `transactions` above).
    var orderedTransactions: [InventoryTransaction] {
        (transactions ?? []).sorted { $0.occurredAt > $1.occurredAt }
    }
}

// MARK: - Writers that cannot leave a five-primitive group half-written

extension StockLot {
    /// All five remaining-primitives plus the rebuild date, through one call.
    ///
    /// Clearing the amount while leaving `remainingUnitCode` at "tbsp" leaves a lot that has
    /// no remaining quantity and still claims `tbsp`/`volume` — which no accessor reads, and
    /// which the reconcile screen, the CloudKit dashboard and any future migration all read
    /// as a contradiction. "A quantity that does not exist is nil" is only true if the whole
    /// group goes.
    func setRemaining(_ newRemaining: Quantity?, rebuiltAt: Date = .now) {
        cacheRebuiltAt = rebuiltAt
        guard let q = newRemaining else {
            remainingHasQuantity = false
            remainingNumerator = 0
            remainingDenominator = 1
            remainingUnitCode = ""
            remainingDimensionRaw = MeasureDimension.unmeasured.rawValue
            return
        }
        remainingHasQuantity = true
        remainingNumerator = q.amount.numerator
        remainingDenominator = q.amount.denominator
        remainingUnitCode = q.unit.code
        remainingDimensionRaw = q.unit.dimension.rawValue
    }

    func setOriginal(_ newOriginal: Quantity?) {
        guard let q = newOriginal else {
            originalHasQuantity = false
            originalNumerator = 0
            originalDenominator = 1
            originalUnitCode = ""
            originalDimensionRaw = MeasureDimension.unmeasured.rawValue
            return
        }
        originalHasQuantity = true
        originalNumerator = q.amount.numerator
        originalDenominator = q.amount.denominator
        originalUnitCode = q.unit.code
        originalDimensionRaw = q.unit.dimension.rawValue
    }
}
