import Foundation
import Observation
import SwiftData

/// One row of the reconcile report: **what the cache says, what the ledger says, and the
/// difference.**
///
/// Declared here rather than in `Models/Support/` because the model layer is frozen and does
/// not carry it; ARCHITECTURE.md §3.11 puts it in its own file, and it can move there with no
/// call-site change. It is a value type with no stored-property footprint, so nothing about
/// the schema depends on where it lives.
///
/// Three things it has to carry, each because a screen asks for it:
///
/// 1. **The per-lot / per-item split.** A lot's `remaining` can drift from the sum of that
///    lot's own transactions, AND an item's total can drift from the sum of all of its
///    transactions. Those are different bugs with different fixes, so `scope` separates them.
/// 2. **The unassigned bucket.** `level(of:in:includeExpired:asOf:graceEnd:)` sums the item's
///    transactions, not its lots, so a row whose lot was deleted still counts — and it has to
///    be attributable to something. `.unassignedLot` is that something, and it is the one
///    case where the right action is "file these against a lot" rather than "rebuild the
///    cache".
/// 3. **The delta, per dimension, exactly.** Not a Bool `diverged`: the screen says "cache
///    says 2 lb, ledger says 1 lb 14 oz, short by 2 oz", because a number he can read is the
///    difference between trusting the repair and reinstalling the app.
struct LedgerDivergence: Identifiable, Sendable {

    enum Scope: Hashable, Sendable {
        /// One lot's `remaining` cache against its own transactions.
        case lot(UUID)
        /// One item's rolled-up lot caches against the sum of all its transactions.
        case item(UUID)
        /// Transactions for this item whose `lot == nil`. Not an error on its own — it
        /// becomes one only when nothing else accounts for them.
        case unassignedLot(itemID: UUID)
    }

    var id = UUID()
    var scope: Scope
    /// Readable even when the row it describes was orphaned, because it comes from
    /// `foodItemNameSnapshot` by way of `itemDisplayName`.
    var itemName: String
    var lotLabel: String = ""
    var dimensionKey: String
    /// What the caches claim, in base units.
    var cachedBase: Rational
    /// What the append-only ledger sums to, in base units. The TRUTH.
    var ledgerBase: Rational
    /// Rows that could not be counted at all (`resolutionState == .pendingBridge`). Shown
    /// beside the delta because they EXPLAIN part of it, and clearing them is the fix.
    var pendingBridgeCount: Int = 0
    var preferredUnit: KitchenUnit

    /// Negative means the cache is overstating stock, which is the direction that makes him
    /// arrive at dinner without butter.
    var delta: Rational { ledgerBase - cachedBase }
    var isDiverged: Bool { delta != .zero }

    /// Through the display ladder, never by interpolating a base value: review 03 traced the
    /// fixture's butter against a 4 oz lot and found a note rendering "23 1111/1135 tsp".
    func display(_ value: Rational, system: UnitSystem = .us) -> String {
        guard preferredUnit.baseFactor != .zero else { return value.humanDescription }
        return Quantity(amount: value / preferredUnit.baseFactor, unit: preferredUnit)
            .displayString(system: system)
    }

    /// The sentence the reconcile row renders.
    func message(system: UnitSystem = .us) -> String {
        let cached = display(cachedBase, system: system)
        let ledger = display(ledgerBase, system: system)
        return "cache says \(cached), ledger says \(ledger)"
    }
}

/// Why the ledger refused. One case, because there is exactly one thing a caller can ask for
/// that would silently corrupt stock.
enum LedgerError: Error, Sendable {
    /// Receiving a list twice doubles everything on it, and the second receive looks
    /// identical to the first from the UI. The guard is the ledger rows the first receive
    /// wrote, not `completedAt`, because he can mark a trip finished without putting it away.
    case alreadyReceived(listTitle: String)

    var message: String {
        switch self {
        case .alreadyReceived(let listTitle):
            let name = listTitle.isEmpty ? "That list" : listTitle
            return "\(name) has already been put away. Receiving it again would double the stock."
        }
    }
}

/// THE ONLY WRITER OF INVENTORY. Every add, every depletion, every cache rebuild.
///
/// `@MainActor` because it holds a `ModelContainer` and `mainContext` is main-actor isolated,
/// and because the alternative — a private context of its own — means a view driven by
/// `@Query` does not see a depletion until something else refetches, which reads as the cook
/// not having been recorded. Same reasoning as `TweakStore`.
@MainActor
@Observable
final class InventoryLedger {

    private let container: ModelContainer

    /// Which units the numbers this service returns are rendered in. A stored preference
    /// rather than a parameter on every call, because `level(of:in:includeExpired:asOf:graceEnd:)`
    /// has a spelling that three rounds of spec review kept half-changing, and adding a
    /// `system:` to it is exactly that defect again. A printed `ShoppingList` freezes its own
    /// `unitSystem` onto each subtotal row, so this only decides what an un-frozen,
    /// in-flight number reads as.
    var unitSystem: UnitSystem = .us

    init(container: ModelContainer) {
        self.container = container
    }

    /// The context callers use when they have none of their own — the hot path for the
    /// badges and the pantry screens. Every method that WRITES takes a context explicitly, so
    /// a caller inside a background task cannot accidentally write through this one.
    var context: ModelContext { container.mainContext }

    // MARK: - Levels

    /// What is on hand, summed from the item's **transactions, not its lots**.
    ///
    /// This reads like a detour — the lots are right there with quantities on them — so:
    /// `StockLot.transactions` is `.nullify`, which means deleting a lot leaves its ledger
    /// rows behind with `lot == nil`. If a level summed LOTS, those rows would still be in
    /// the ledger and would silently stop contributing, producing a divergence between the
    /// ledger and the caches that `reconcileReport(in:)` could never attribute to anything or
    /// clear — the numbers would simply disagree, with nothing to point at. Summing at the
    /// item level means an orphan still counts, into an explicit bucket the reconcile screen
    /// names.
    ///
    /// It returns **the flags it raised** as well as the numbers, because it is the only
    /// thing in the system that can see a lot's `expiresAt`. `ShoppingListBuilder` cannot
    /// derive either exclusion, which is why `.expiredStockIgnored` and `.expiringBeforeNeed`
    /// previously had no writer anywhere.
    ///
    /// The subtotals are `QuantityMath.sum(_:using: item)` output — **the same item and the
    /// same collapse pass the requested side runs.** Without that the two sides can be summed
    /// into `dimensionKey`s that never meet even where a density bridges them, and
    /// `QuantityMath.subtract` has nothing to match on: a 2 tbsp butter requirement never
    /// cancels against the 4 oz lot sitting in the fridge.
    func level(
        of item: FoodItem,
        in location: StorageLocation? = nil,
        includeExpired: Bool = false,
        asOf: Date = .now,
        graceEnd: Date? = nil
    ) -> (subtotals: [QuantitySubtotal], flags: Set<LineFlag>) {
        var flags: Set<LineFlag> = []
        var contributions: [QuantityMath.Contribution] = []

        for row in item.levelContributions {
            guard let delta = row.delta else { continue }

            if let lot = row.lot {
                // A location filter is a property of the LOT, so a row filed against a lot in
                // another location is not stock here.
                if let location = location, lot.location?.id != location.id { continue }

                // `includeExpired` turns BOTH date filters off. Counting stock that is already
                // past its date while excluding stock that merely dies soon is a contradiction,
                // and a caller asking for the first is asking to ignore dates.
                if !includeExpired {
                    if lot.isExpired(asOf: asOf) {
                        flags.insert(.expiredStockIgnored)
                        continue
                    }
                    if let graceEnd = graceEnd, lot.expires(before: graceEnd) {
                        flags.insert(.expiringBeforeNeed)
                        continue
                    }
                }
            } else if location != nil {
                // An orphan has no lot, so it has no location to claim. It is still counted
                // by every unfiltered call — see below.
                continue
            }

            // NOTE WHAT DID NOT HAPPEN HERE: a row whose `lot` is nil was never expiry-
            // filtered. It has no `expiresAt` to judge, and both alternatives are wrong
            // inside a number he shops by — dropping it understates stock permanently with
            // nothing on screen to explain the gap, and inventing a date for it is a guess.
            contributions.append(QuantityMath.Contribution(quantity: delta))
        }

        let subtotals = QuantityMath.sum(contributions, using: item, system: unitSystem)
        return (subtotals, flags)
    }

    // MARK: - FIFO selection

    /// One candidate lot, already converted into the dimension the requirement is written in.
    private struct Candidate {
        var lot: StockLot
        /// In the REQUESTED dimension's base unit, so the walk below is one subtraction.
        var available: Rational
        var isBridged: Bool
        var isOpen: Bool
        var expiry: Date
        var acquired: Date
    }

    /// Which lots to draw down, and how much from each.
    ///
    /// FIFO by `expiresAt` then `acquiredAt`, preferring an **already-opened** lot — you
    /// finish the open butter before cutting a new stick — and preferring lots that need **no
    /// bridge**, so a conversion only happens when there is nothing else to take from. The
    /// amounts come back in the unit the requirement was written in, so the caller writes one
    /// unit into the ledger instead of one per lot.
    func lotsForDepletion(_ item: FoodItem, needed: Quantity) -> [(StockLot, Quantity)] {
        guard needed.unit.baseFactor != .zero else { return [] }
        var outstanding = needed.base.clampedAtZero
        guard outstanding != .zero else { return [] }

        let wantedKey = needed.dimensionKey
        var gramsPerTsp: Rational? = nil
        if let grams = item.gramsPerCup, grams != .zero { gramsPerTsp = grams / Rational(48) }

        let massKey = MeasureDimension.mass.rawValue
        let volumeKey = MeasureDimension.volume.rawValue

        var candidates: [Candidate] = []
        for lot in item.orderedLots {
            guard let remaining = lot.remaining else { continue }
            let available = remaining.base.clampedAtZero
            guard available != .zero else { continue }

            var converted: Rational? = nil
            var bridged = false
            if remaining.dimensionKey == wantedKey {
                converted = available
            } else if let grams = gramsPerTsp {
                // Volume <-> mass and ONLY on a per-item density. Two count nouns are never
                // folded into one another in v1 — that is purchase-unit rounding, and it is
                // cut (CLAUDE.md).
                if remaining.dimensionKey == massKey, wantedKey == volumeKey {
                    converted = available / grams
                    bridged = true
                } else if remaining.dimensionKey == volumeKey, wantedKey == massKey {
                    converted = available * grams
                    bridged = true
                }
            }
            guard let usable = converted, usable != .zero else { continue }

            candidates.append(Candidate(
                lot: lot,
                available: usable,
                isBridged: bridged,
                isOpen: lot.isOpen,
                // A lot with no best-by sorts last rather than first: it never expires, so it
                // is the one to keep rather than the one to use up.
                expiry: lot.expiresAt ?? Date.distantFuture,
                acquired: lot.acquiredAt
            ))
        }

        candidates.sort {
            ($0.isBridged ? 1 : 0, $0.isOpen ? 0 : 1, $0.expiry, $0.acquired)
                < ($1.isBridged ? 1 : 0, $1.isOpen ? 0 : 1, $1.expiry, $1.acquired)
        }

        var out: [(StockLot, Quantity)] = []
        for candidate in candidates {
            guard outstanding != .zero else { break }
            let take = candidate.available < outstanding ? candidate.available : outstanding
            guard take != .zero else { continue }
            out.append((
                candidate.lot,
                Quantity(amount: take / needed.unit.baseFactor, unit: needed.unit)
            ))
            outstanding = outstanding - take
        }
        return out
    }

    /// Whether stock measured in `stockKey` can reach a requirement written in `wantedKey`.
    /// The question `.pendingBridge` exists to record the answer to.
    private func isReachable(_ wantedKey: String, from stockKey: String, item: FoodItem) -> Bool {
        if stockKey == wantedKey { return true }
        guard let grams = item.gramsPerCup, grams != .zero else { return false }
        let massKey = MeasureDimension.mass.rawValue
        let volumeKey = MeasureDimension.volume.rawValue
        return (stockKey == massKey && wantedKey == volumeKey)
            || (stockKey == volumeKey && wantedKey == massKey)
    }

    // MARK: - Writing a row

    /// The one place an `InventoryTransaction` is created.
    ///
    /// A nil `delta` is written as `.pendingBridge`, which is the one legitimate way to store
    /// a row with no number: a cook depletion needing a density the item does not carry is
    /// RECORDED rather than skipped or guessed. A skipped depletion is an invisible
    /// overstatement of stock; a guessed one is a silent lie.
    ///
    /// It recomputes the lot cache itself, because the cache and the ledger have to move
    /// together and a call site that forgets is invisible until the reconcile screen reports a
    /// drift months later.
    @discardableResult
    func apply(
        kind: TransactionKind,
        delta: Quantity?,
        to item: FoodItem,
        lot: StockLot? = nil,
        meal: PlannedMeal? = nil,
        recipeID: String = "",
        recipeTitle: String = "",
        note: String = "",
        priceCents: Int? = nil,
        at occurredAt: Date = .now,
        in context: ModelContext
    ) -> InventoryTransaction {
        let state = delta == nil ? ResolutionState.pendingBridge : ResolutionState.applied
        let transaction = InventoryTransaction(
            kindRaw: kind.rawValue,
            resolutionStateRaw: state.rawValue,
            occurredAt: occurredAt,
            note: note,
            priceCents: priceCents,
            foodItemNameSnapshot: item.displayName,
            recipeIDSnapshot: recipeID,
            recipeTitleSnapshot: recipeTitle
        )
        transaction.setDelta(delta)
        context.insert(transaction)
        // The to-one sides only. `inverse:` is declared on `FoodItem.transactions`,
        // `StockLot.transactions` and `PlannedMeal.inventoryTransactions`, so SwiftData
        // maintains the other end; writing both risks the row appearing twice.
        transaction.item = item
        transaction.lot = lot
        transaction.plannedMeal = meal
        if let lot = lot { recompute(lot: lot, at: occurredAt) }
        return transaction
    }

    // MARK: - The trip home

    /// A finished shop puts stock away. Posts the **`purchase`** role, not `requested` and not
    /// `have`: restocking what the recipe needed rather than what he bought drifts tracked
    /// stock monotonically toward zero.
    ///
    /// Only CHECKED lines. An unchecked line is something he walked past.
    func receive(_ list: ShoppingList, in context: ModelContext) throws {
        guard (list.receivedTransactions ?? []).isEmpty else {
            throw LedgerError.alreadyReceived(listTitle: list.title)
        }

        let now = Date.now
        for line in list.orderedLines where line.isChecked {
            // A line that matched no item has nothing to post against; it stays on the list
            // with `.unresolvedItem` and a one-tap "match to...".
            guard let item = line.foodItem else { continue }

            // A staple is present or absent with NO quantity (CLAUDE.md), so buying one
            // answers `isRunningLow` and creates no lot. The builder already empties `toBuy`
            // and `purchase` on a diverted staple, so this is the path for the one he added
            // anyway.
            guard item.tracksQuantity else {
                item.isRunningLow = false
                continue
            }

            var postedPrice = false
            for row in line.purchase {
                guard let quantity = row.quantity, quantity.amount > .zero else { continue }

                let location = line.destinationLocation ?? item.defaultLocation
                let lot = StockLot(
                    acquiredAt: now,
                    expiresAt: location?.suggestedExpiry(from: now),
                    label: list.title,
                    foodItemNameSnapshot: item.displayName
                )
                lot.setOriginal(quantity)
                context.insert(lot)
                lot.item = item
                lot.location = location

                // The price rides on the FIRST row only. A line with a volume and a mass
                // subtotal is one purchase at one price, and posting it per row would report
                // the week's grocery bill as double.
                let transaction = apply(
                    kind: .purchase,
                    delta: quantity,
                    to: item,
                    lot: lot,
                    priceCents: postedPrice ? nil : line.priceCents,
                    at: now,
                    in: context
                )
                transaction.shoppingList = list
                postedPrice = true
            }
        }

        // `.nullify` on the far side of `receivedTransactions`, so archiving the list later
        // does not un-buy any of this.
        if list.completedAt == nil { list.completedAt = now }
        try context.save()
    }

    // MARK: - Cooking

    /// One ingredient a dish actually used, after scaling and after the tweak overlay.
    ///
    /// The caller flattens the recipe — this service has no business resolving content — and
    /// hands over the item it resolved to. `needed` is optional because "salt to taste" and
    /// "Pinch flaky salt" are real lines with no quantity, and a nil quantity must never
    /// enter arithmetic or be read as a deliberate zero.
    struct CookRequirement {
        var item: FoodItem
        var needed: Quantity?
        var recipeID: String = ""
        var recipeTitle: String = ""
        var note: String = ""

        init(
            item: FoodItem,
            needed: Quantity? = nil,
            recipeID: String = "",
            recipeTitle: String = "",
            note: String = ""
        ) {
            self.item = item
            self.needed = needed
            self.recipeID = recipeID
            self.recipeTitle = recipeTitle
            self.note = note
        }
    }

    /// Cooking depletes. Every row written here is a `.cookDepletion` carrying the recipe id
    /// and title as SNAPSHOTS — which is cook provenance without a cook log: "where did the
    /// cream go" stays answerable, and the journal he declined stays undeclared.
    ///
    /// Three outcomes per requirement, and the third is the one that matters:
    ///
    /// 1. Lots covered it: one negative row per lot, each against the lot it came out of.
    /// 2. Nothing covered it and nothing could have: one negative row with `lot == nil`. The
    ///    food was used, so the ledger says so and the level goes negative — which the
    ///    reconcile screen then attributes to the unassigned bucket instead of leaving a gap
    ///    nothing explains.
    /// 3. He HAS stock, in a dimension no density can reach: a `.pendingBridge` row with no
    ///    number, which lands in the "Unresolved depletions" inbox badged on the Pantry tab.
    ///    The app records the question rather than answering it.
    @discardableResult
    func depleteForCook(
        _ requirements: [CookRequirement],
        meal: PlannedMeal? = nil,
        at occurredAt: Date = .now,
        in context: ModelContext
    ) -> [InventoryTransaction] {
        var written: [InventoryTransaction] = []

        for requirement in requirements {
            let item = requirement.item

            // A staple is never depleted — it is assumed present until he says otherwise —
            // and an `.untracked` row is one he asked not to be counted.
            guard item.tracksQuantity else { continue }
            guard let needed = requirement.needed, needed.amount > .zero else { continue }

            var covered = Rational.zero
            for (lot, portion) in lotsForDepletion(item, needed: needed) {
                let signed = Quantity(amount: portion.amount.negated, unit: portion.unit)
                written.append(apply(
                    kind: .cookDepletion,
                    delta: signed,
                    to: item,
                    lot: lot,
                    meal: meal,
                    recipeID: requirement.recipeID,
                    recipeTitle: requirement.recipeTitle,
                    note: requirement.note,
                    at: occurredAt,
                    in: context
                ))
                covered = covered + portion.base
            }

            let shortfall = (needed.base - covered).clampedAtZero
            guard shortfall != .zero else { continue }

            let unreachable = item.orderedLots.contains { lot in
                guard let remaining = lot.remaining,
                      remaining.base.clampedAtZero != .zero else { return false }
                return !isReachable(needed.dimensionKey, from: remaining.dimensionKey, item: item)
            }

            if unreachable {
                let asked = Quantity(
                    amount: shortfall / needed.unit.baseFactor, unit: needed.unit
                ).displayString(system: unitSystem)
                written.append(apply(
                    kind: .cookDepletion,
                    delta: nil,
                    to: item,
                    meal: meal,
                    recipeID: requirement.recipeID,
                    recipeTitle: requirement.recipeTitle,
                    note: "used \(asked); needs a weight per cup before it can be taken off a lot",
                    at: occurredAt,
                    in: context
                ))
            } else {
                let signed = Quantity(
                    amount: (shortfall / needed.unit.baseFactor).negated, unit: needed.unit
                )
                written.append(apply(
                    kind: .cookDepletion,
                    delta: signed,
                    to: item,
                    meal: meal,
                    recipeID: requirement.recipeID,
                    recipeTitle: requirement.recipeTitle,
                    note: requirement.note,
                    at: occurredAt,
                    in: context
                ))
            }
        }

        try? context.save()
        return written
    }

    // MARK: - Caches

    /// Rebuilds one lot's `remaining` from its own transactions. The cache exists because
    /// "do I have enough butter" runs on every list build and every recipe render, and
    /// summing a multi-year log per item per render is not viable. It is a cache that reports
    /// its own drift, which is fine; a cache that drifts silently is worse than none.
    func recompute(lot: StockLot, at date: Date = .now) {
        let rows = (lot.transactions ?? []).filter { $0.countsTowardLevel }
        let contributions = rows.compactMap { $0.delta }.map {
            QuantityMath.Contribution(quantity: $0)
        }
        guard !contributions.isEmpty else {
            // No countable rows is not "zero on hand", it is "nothing is known about this
            // lot", and the five remaining-primitives go together.
            lot.setRemaining(nil, rebuiltAt: date)
            return
        }

        // Spelled out through a local rather than passing `lot.item` straight in: the
        // parameter is `(any DensityCarrying)?`, and erasing a concrete optional into an
        // existential optional at the call site is the kind of conversion there is no
        // compiler here to confirm. One assignment of a non-optional is unambiguous.
        var density: (any DensityCarrying)? = nil
        if let owner = lot.item { density = owner }
        let subtotals = QuantityMath.sum(contributions, using: density, system: unitSystem)
        // A lot holds ONE quantity, so one bucket has to win. Prefer the dimension the lot was
        // bought in; otherwise take the first, which after a density collapse IS the whole lot
        // expressed in the item's preferred dimension.
        let wanted = lot.original?.dimensionKey ?? lot.remaining?.dimensionKey
        var chosen = subtotals.first
        if let wanted = wanted,
           let match = subtotals.first(where: { $0.dimensionKey == wanted }) {
            chosen = match
        }
        guard let chosen = chosen, let quantity = chosen.quantity else {
            lot.setRemaining(nil, rebuiltAt: date)
            return
        }
        lot.setRemaining(quantity, rebuiltAt: date)
    }

    /// Run on launch, so a cache that drifted while another device was writing repairs itself
    /// without him opening Settings.
    func rebuildAllCaches(in context: ModelContext) throws {
        let now = Date.now
        for lot in try context.fetch(FetchDescriptor<StockLot>()) {
            recompute(lot: lot, at: now)
        }
        try context.save()
    }

    // MARK: - Reconciliation

    /// SURFACES divergence rather than hiding it: per lot, per item, and per unassigned
    /// bucket. Only rows that actually disagree are returned, except the unassigned bucket,
    /// which is reported whenever it is non-empty because it is the explanation for the item
    /// row sitting next to it.
    func reconcileReport(in context: ModelContext) throws -> [LedgerDivergence] {
        var out: [LedgerDivergence] = []

        for lot in try context.fetch(FetchDescriptor<StockLot>()) {
            let rows = lot.transactions ?? []
            var ledger: [String: Rational] = [:]
            for row in rows where row.countsTowardLevel {
                guard let delta = row.delta else { continue }
                ledger[delta.dimensionKey] = (ledger[delta.dimensionKey] ?? .zero) + delta.base
            }
            var cached: [String: Rational] = [:]
            if let remaining = lot.remaining { cached[remaining.dimensionKey] = remaining.base }
            let pending = rows.filter { $0.needsBridge }.count

            for key in Set(ledger.keys).union(cached.keys).sorted() {
                let cachedBase = cached[key] ?? .zero
                let ledgerBase = ledger[key] ?? .zero
                guard cachedBase != ledgerBase else { continue }
                out.append(divergence(
                    scope: .lot(lot.id),
                    itemName: lot.itemDisplayName,
                    lotLabel: lot.label,
                    dimensionKey: key,
                    cachedBase: cachedBase,
                    ledgerBase: ledgerBase,
                    pendingBridgeCount: pending
                ))
            }
        }

        for item in try context.fetch(FetchDescriptor<FoodItem>()) {
            let rows = item.transactions ?? []
            var ledger: [String: Rational] = [:]
            for row in item.levelContributions {
                guard let delta = row.delta else { continue }
                ledger[delta.dimensionKey] = (ledger[delta.dimensionKey] ?? .zero) + delta.base
            }
            var cached: [String: Rational] = [:]
            for lot in item.orderedLots {
                guard let remaining = lot.remaining else { continue }
                cached[remaining.dimensionKey] =
                    (cached[remaining.dimensionKey] ?? .zero) + remaining.base
            }
            let pending = rows.filter { $0.needsBridge }.count

            for key in Set(ledger.keys).union(cached.keys).sorted() {
                let cachedBase = cached[key] ?? .zero
                let ledgerBase = ledger[key] ?? .zero
                guard cachedBase != ledgerBase else { continue }
                out.append(divergence(
                    scope: .item(item.id),
                    itemName: item.displayName,
                    lotLabel: "",
                    dimensionKey: key,
                    cachedBase: cachedBase,
                    ledgerBase: ledgerBase,
                    pendingBridgeCount: pending
                ))
            }

            // The unassigned bucket. These rows are counted by `level` and held by no lot, so
            // they are the whole reason the item row above can differ from the sum of its
            // caches — and "file them against a lot" is a different fix from "rebuild the
            // cache", which is why they get their own scope rather than inflating a delta.
            var orphan: [String: Rational] = [:]
            var orphanPending = 0
            for row in rows where row.isUnassignedLot {
                if row.needsBridge { orphanPending += 1 }
                guard row.countsTowardLevel, let delta = row.delta else { continue }
                orphan[delta.dimensionKey] = (orphan[delta.dimensionKey] ?? .zero) + delta.base
            }
            for key in orphan.keys.sorted() {
                let ledgerBase = orphan[key] ?? .zero
                guard ledgerBase != .zero || orphanPending > 0 else { continue }
                out.append(divergence(
                    scope: .unassignedLot(itemID: item.id),
                    itemName: item.displayName,
                    lotLabel: "",
                    dimensionKey: key,
                    cachedBase: .zero,
                    ledgerBase: ledgerBase,
                    pendingBridgeCount: orphanPending
                ))
            }
        }

        return out
    }

    /// One construction site for `LedgerDivergence`, because its memberwise initializer takes
    /// four `Rational`-ish values in a row and a transposed pair at one of three call sites
    /// would report the delta backwards.
    private func divergence(
        scope: LedgerDivergence.Scope,
        itemName: String,
        lotLabel: String,
        dimensionKey: String,
        cachedBase: Rational,
        ledgerBase: Rational,
        pendingBridgeCount: Int
    ) -> LedgerDivergence {
        let unit = QuantityMath.displayUnit(
            forBase: ledgerBase, dimensionKey: dimensionKey, hint: nil, system: unitSystem
        ).unit
        return LedgerDivergence(
            scope: scope,
            itemName: itemName,
            lotLabel: lotLabel,
            dimensionKey: dimensionKey,
            cachedBase: cachedBase,
            ledgerBase: ledgerBase,
            pendingBridgeCount: pendingBridgeCount,
            preferredUnit: unit
        )
    }

    // MARK: - The two standing queues

    /// "What is about to go bad", the single most useful inventory screen and the reason lots
    /// exist at all. Filtered in Swift rather than in a `#Predicate`: `expiresAt` is optional,
    /// and an optional-binding comparison is not a shape worth asking an unbuildable macro to
    /// translate when a home pantry is a few hundred rows.
    func expiringSoon(within days: Int, in context: ModelContext) throws -> [StockLot] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date.now)
        guard let cutoff = calendar.date(byAdding: .day, value: max(0, days), to: today) else {
            return []
        }
        let lots = try context.fetch(FetchDescriptor<StockLot>())
        return lots.filter { lot in
            guard let expiry = lot.expiresAt else { return false }
            guard let remaining = lot.remaining,
                  remaining.base.clampedAtZero != .zero else { return false }
            return expiry <= cutoff
        }.sorted {
            ($0.expiresAt ?? Date.distantFuture, $0.acquiredAt)
                < ($1.expiresAt ?? Date.distantFuture, $1.acquiredAt)
        }
    }

    /// The "Unresolved depletions" inbox, badged on the Pantry tab rather than buried in
    /// Settings: a standing queue nobody sees goes stale and quietly makes the next shopping
    /// list wrong.
    func pendingBridgeTransactions(in context: ModelContext) throws -> [InventoryTransaction] {
        // Hoisted, and not for style. `#Predicate` translates its closure into a
        // `PredicateExpression` tree and `DefaultStringInterpolation` has no representation
        // there, so an interpolated operand fails to expand. A captured `let` is an
        // expression the macro CAN represent.
        let needle = ResolutionState.pendingBridge.rawValue
        let descriptor = FetchDescriptor<InventoryTransaction>(
            predicate: #Predicate<InventoryTransaction> { $0.resolutionStateRaw == needle },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Answering one inbox row. The delta and the state move together — see
    /// `InventoryTransaction.resolve(withDelta:)` — and the lot cache follows, because a row
    /// that starts counting without its cache being rebuilt is a divergence this service
    /// created itself.
    func resolve(_ transaction: InventoryTransaction, withDelta delta: Quantity, in context: ModelContext) {
        transaction.resolve(withDelta: delta)
        if let lot = transaction.lot { recompute(lot: lot) }
        // `try?` rather than `try`: a failed save inside a SwiftUI action has no recovery
        // available on a family phone, and propagating it out of the button does not create
        // one. Same call as `TweakStore.save()`.
        try? context.save()
    }
}
