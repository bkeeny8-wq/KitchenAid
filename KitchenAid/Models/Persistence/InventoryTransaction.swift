import Foundation
import SwiftData

/// Append-only. This is the TRUTH of what is in the kitchen.
///
/// Two reasons a scalar `onHand` was rejected, and the second is decisive:
///
/// 1. Answerability. He will open the app and ask "why does it think I have 3 lb of butter?"
///    A scalar has no answer. A ledger shows: bought 2 lb Oct 4, bought 2 lb Oct 19, cooked
///    -1 lb Oct 22.
/// 2. CloudKit merge semantics. With a scalar, his phone decrements butter by 1/2 cup and his
///    iPad by 2 tbsp while both are offline; CloudKit resolves field-level last-writer-wins
///    and ONE DECREMENT VANISHES, with no conflict handler possible. With append-only rows
///    both are distinct records, both sync, and the derived level is correct with no conflict
///    handling at all.
///
/// This is also the one part of the architecture that is genuinely not additive later: adding
/// a ledger in year two cannot backfill history that was never recorded. Which is why it is
/// built on day one, before the screens that read it.
///
/// **A level is summed from these rows, never from `StockLot.remaining`.** The lot caches are
/// a render-speed convenience that reports its own drift; this table is what the drift is
/// measured against. A row whose `lot` was deleted still counts, into the unassigned bucket.
@Model
final class InventoryTransaction {
    var id: UUID = UUID()

    /// Signed. Negative depletes.
    ///
    /// `hasDelta == false` means the delta is UNKNOWN, not zero. That is the `.pendingBridge`
    /// case: a cook depletion needing a density the `FoodItem` does not carry is WRITTEN,
    /// with no number, and lands in the "Unresolved depletions" inbox. A skipped depletion is
    /// an invisible overstatement of stock; a guessed one is a silent lie. Neither is
    /// acceptable, so the app records the question instead of answering it.
    var hasDelta: Bool = false
    var deltaNumerator: Int = 0
    var deltaDenominator: Int = 1
    var deltaUnitCode: String = ""
    var deltaDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    /// `TransactionKind`: purchase / cookDepletion / waste / manualAdjustment / correction /
    /// inventoryCount / giftOut.
    var kindRaw: String = TransactionKind.manualAdjustment.rawValue

    /// `ResolutionState`: applied / pendingBridge / voided.
    ///
    /// Nothing is ever deleted to undo it — a `.correction` row is appended, or this is set
    /// `.voided`. An append-only ledger that is sometimes pruned is not append-only, and the
    /// pruned case is exactly the one he would be asking about.
    var resolutionStateRaw: String = ResolutionState.applied.rawValue

    var occurredAt: Date = .now
    var note: String = ""
    var priceCents: Int? = nil

    /// So an orphan — from a stray item delete — is still readable and attributable in the
    /// reconcile screen.
    var foodItemNameSnapshot: String = ""

    /// Cook provenance WITHOUT a cook log. "Where did the cream go" stays answerable, which
    /// was the only thing a `CookLogEntry.depletions` edge was load-bearing for; the rest of
    /// that model was the journal he declined. These are two snapshot strings on a row that
    /// already exists, not a history table, and nothing reads them as one. "" when the
    /// depletion came from somewhere else.
    var recipeIDSnapshot: String = ""
    var recipeTitleSnapshot: String = ""

    /// Macro lives on `FoodItem.transactions` (`.nullify`).
    var item: FoodItem? = nil

    /// Macro lives on `StockLot.transactions` (`.nullify`). nil is LEGAL and means
    /// "unassigned lot": the row still contributes to the item's level.
    var lot: StockLot? = nil

    /// Macro lives on `ShoppingList.receivedTransactions`. Archiving a list must not un-buy
    /// the groceries, so that edge is `.nullify` too.
    var shoppingList: ShoppingList? = nil

    /// Macro lives on `PlannedMeal.inventoryTransactions`.
    var plannedMeal: PlannedMeal? = nil

    init(
        id: UUID = UUID(),
        hasDelta: Bool = false,
        deltaNumerator: Int = 0,
        deltaDenominator: Int = 1,
        deltaUnitCode: String = "",
        deltaDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        kindRaw: String = TransactionKind.manualAdjustment.rawValue,
        resolutionStateRaw: String = ResolutionState.applied.rawValue,
        occurredAt: Date = .now,
        note: String = "",
        priceCents: Int? = nil,
        foodItemNameSnapshot: String = "",
        recipeIDSnapshot: String = "",
        recipeTitleSnapshot: String = "",
        item: FoodItem? = nil,
        lot: StockLot? = nil,
        shoppingList: ShoppingList? = nil,
        plannedMeal: PlannedMeal? = nil
    ) {
        self.id = id
        self.hasDelta = hasDelta
        self.deltaNumerator = deltaNumerator
        self.deltaDenominator = deltaDenominator
        self.deltaUnitCode = deltaUnitCode
        self.deltaDimensionRaw = deltaDimensionRaw
        self.kindRaw = kindRaw
        self.resolutionStateRaw = resolutionStateRaw
        self.occurredAt = occurredAt
        self.note = note
        self.priceCents = priceCents
        self.foodItemNameSnapshot = foodItemNameSnapshot
        self.recipeIDSnapshot = recipeIDSnapshot
        self.recipeTitleSnapshot = recipeTitleSnapshot
        self.item = item
        self.lot = lot
        self.shoppingList = shoppingList
        self.plannedMeal = plannedMeal
    }
}

// MARK: - Accessors

extension InventoryTransaction {
    var delta: Quantity? {
        guard hasDelta,
              let unit = UnitCatalog.unit(
                  code: deltaUnitCode,
                  fallbackDimension: MeasureDimension(rawValue: deltaDimensionRaw)
              )
        else { return nil }
        return Quantity(
            amount: Rational(deltaNumerator, max(1, deltaDenominator)),
            unit: unit
        )
    }

    var kind: TransactionKind { TransactionKind(rawValue: kindRaw) ?? .manualAdjustment }

    var resolutionState: ResolutionState {
        ResolutionState(rawValue: resolutionStateRaw) ?? .applied
    }

    /// Only `.applied` rows with a delta contribute to a level. A `.pendingBridge` row is a
    /// recorded question with no number in it, and a `.voided` row is history that has been
    /// reversed; counting either would be inventing stock.
    var countsTowardLevel: Bool { resolutionState == .applied && hasDelta }

    /// The row is in the ledger and its lot is gone. It still counts — it has no lot, so it
    /// has no `expiresAt` to judge, and both alternatives (drop it, or invent a date for it)
    /// put a guess inside a number he shops by.
    var isUnassignedLot: Bool { lot == nil }

    /// The "Unresolved depletions" inbox, badged on the Pantry tab rather than buried in
    /// Settings, because a standing queue nobody sees is a queue that goes stale and quietly
    /// makes the next shopping list wrong.
    var needsBridge: Bool { resolutionState == .pendingBridge }

    var itemDisplayName: String {
        if let item, !item.name.isEmpty { return item.name }
        return foodItemNameSnapshot.isEmpty ? "Unassigned item" : foodItemNameSnapshot
    }

    /// What the ledger row reads as in the history list.
    func summary(system: UnitSystem = .us) -> String {
        let amount = delta?.displayString(system: system) ?? "—"
        return "\(amount) \(itemDisplayName)"
    }
}

// MARK: - Writers

extension InventoryTransaction {
    /// All five delta primitives together, for the same reason as every other group of five
    /// in this schema: a cleared amount beside a surviving `deltaUnitCode` is a row that
    /// claims a unit no accessor reads.
    ///
    /// Passing nil is how a `.pendingBridge` row is written, so this is the one setter whose
    /// nil case is a feature rather than a reset.
    func setDelta(_ newDelta: Quantity?) {
        guard let q = newDelta else {
            hasDelta = false
            deltaNumerator = 0
            deltaDenominator = 1
            deltaUnitCode = ""
            deltaDimensionRaw = MeasureDimension.unmeasured.rawValue
            return
        }
        hasDelta = true
        deltaNumerator = q.amount.numerator
        deltaDenominator = q.amount.denominator
        deltaUnitCode = q.unit.code
        deltaDimensionRaw = q.unit.dimension.rawValue
    }

    /// Answering a `.pendingBridge` row: the delta and the state move together, because a
    /// row left `.pendingBridge` with a number in it sits in the inbox forever while already
    /// being counted, and one flipped to `.applied` without a number counts as nothing.
    func resolve(withDelta newDelta: Quantity) {
        setDelta(newDelta)
        resolutionStateRaw = ResolutionState.applied.rawValue
    }
}
