import Foundation

/// What the arithmetic needs from an ingredient, which is a density and a preference — not a
/// SwiftData class.
///
/// `QuantityMath` is the arithmetic under test and has no business importing SwiftData: a
/// `FoodItem` parameter would mean every test of the shopping-list sums needs a
/// `ModelContainer` to build one, and the math would stop being pure. `FoodItem` declares
/// conformance (`gramsPerCup` and `preferredDimension` are already its own accessors over
/// stored primitives) and every call site can keep passing a `FoodItem?`.
protocol DensityCarrying {
    /// Grams in one CUP of this ingredient. nil means the density is not settled, and the
    /// app must then refuse to convert rather than invent one: 1 cup = 240 g is right for
    /// water, off by ~2× for flour and ~1.4× for honey — and wrong SILENTLY, inside the
    /// number he is about to shop by.
    var gramsPerCup: Rational? { get }
    /// Which side a collapsed volume+mass requirement lands on.
    var preferredDimension: MeasureDimension { get }
}

/// The arithmetic under test. A pure enum: no fetches, no mutation, no SwiftUI.
enum QuantityMath {

    /// One contribution on the way in, with the unit it was WRITTEN in (which is what the
    /// hint is computed from).
    struct Contribution: Hashable, Sendable {
        var quantity: Quantity

        init(quantity: Quantity) {
            self.quantity = quantity
        }
    }

    // MARK: - Display unit selection

    /// Picks the unit a human would use, and says when the exact value cannot be shown
    /// exactly in it.
    ///
    /// (a) If the HINT unit — the unit the most source lines were written in, ties broken
    ///     toward the FINER unit — yields an amount in [1/4, 64), use it. If every recipe
    ///     says tbsp, he wants tbsp.
    /// (b) Otherwise take the COARSEST candidate where base/factor >= 1. If that amount's
    ///     reduced denominator exceeds 8, step ONE unit finer and retry.
    /// (c) If nothing yields a denominator <= 8, keep the coarsest with amount >= 1, keep the
    ///     EXACT value, and report `isApproximate` so the owner of the subtotal records that
    ///     its display is rounded.
    /// (d) If NOTHING on the ladder reaches 1 — 1/2 tsp of a volume, a base smaller than the
    ///     finest unit — use the FINEST unit. This is the hole every other "largest unit
    ///     whose value is >= 1" rule leaves open, and it is why 1/2 tsp renders as "1/2 tsp"
    ///     and not as "0 tbsp".
    ///
    /// `fl oz`, `gallon` and (in US mode) `kg`/`L` are not candidates at all, which is what
    /// guarantees 18 tsp of butter renders "6 tbsp" and never "3 fl oz".
    ///
    /// The returned flag is about the STORED value, not about the characters printed:
    /// `Rational.kitchenRounded` decides those, and rounds whether or not this flag is set.
    static func displayUnit(
        forBase base: Rational,
        dimensionKey: String,
        hint: KitchenUnit?,
        system: UnitSystem = .us
    ) -> (unit: KitchenUnit, isApproximate: Bool) {
        let candidates = UnitCatalog.displayCandidates(for: dimensionKey, system: system)
            .filter { $0.isHouseholdCommon }
        guard let finest = candidates.last else { return (UnitCatalog.each, false) }

        // (a)
        if let h = hint, h.isHouseholdCommon, candidates.contains(h), h.baseFactor != .zero {
            let amount = base / h.baseFactor
            if amount >= Rational(1, 4) && amount < Rational(64) { return (h, false) }
        }

        // (b) and (c)
        for (index, unit) in candidates.enumerated() where unit.baseFactor != .zero {
            let amount = base / unit.baseFactor
            guard amount >= .one else { continue }
            if amount.denominator <= 8 { return (unit, false) }
            if index + 1 < candidates.count {
                let finer = candidates[index + 1]
                if finer.baseFactor != .zero, (base / finer.baseFactor).denominator <= 8 {
                    return (finer, false)
                }
            }
            return (unit, true)
        }

        // (d)
        let amount = finest.baseFactor == .zero ? base : base / finest.baseFactor
        return (finest, amount.denominator > 8)
    }

    /// The hint: the unit the most contributions were written in. Ties go to the FINER unit,
    /// because the finer unit yields a whole-ish number more often — which is what makes
    /// `2 tbsp + 1/4 cup` display as "6 tbsp" rather than "3/8 cup".
    static func hintUnit(
        from contributions: [Contribution], dimensionKey: String
    ) -> KitchenUnit? {
        var counts: [KitchenUnit: Int] = [:]
        for c in contributions where c.quantity.dimensionKey == dimensionKey {
            counts[c.quantity.unit, default: 0] += 1
        }
        let ranked = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.baseFactor < rhs.key.baseFactor
        }
        return ranked.first?.key
    }

    /// Renders a base amount through the display ladder, so a note reads in the units he
    /// reads on the line.
    ///
    /// Every `conversionNote` below is built from this and never by interpolating a base
    /// value: review 03 traced the fixture's butter against a 4 oz lot and found the note
    /// rendering "113 2/5 g on hand counted as 23 1111/1135 tsp at 227 g per cup".
    private static func noteString(
        base: Rational, dimensionKey: String, hint: KitchenUnit?, system: UnitSystem
    ) -> String {
        let (unit, _) = displayUnit(
            forBase: base, dimensionKey: dimensionKey, hint: hint, system: system
        )
        guard unit.baseFactor != .zero else { return base.humanDescription }
        return Quantity(amount: base / unit.baseFactor, unit: unit).displayString(system: system)
    }

    // MARK: - Summation

    /// Partition by `dimensionKey`, add EXACTLY within each partition, then attempt the one
    /// collapse there is: volume <-> mass, on a per-item density.
    ///
    /// Count nouns are partitioned FIRST and are **never folded into one another**, which is
    /// why "2 cloves + 1 head" never becomes "3 cloves" — and why it stays two subtotals on
    /// one line instead of one purchase noun. Turning a count noun into a different purchase
    /// noun is purchase-unit rounding, which is deferred; see `CLAUDE.md`.
    static func sum(
        _ contributions: [Contribution],
        using item: (any DensityCarrying)?,
        system: UnitSystem = .us
    ) -> [QuantitySubtotal] {
        var bases: [String: Rational] = [:]
        for c in contributions {
            guard c.quantity.dimension != .unmeasured else { continue }
            let key = c.quantity.dimensionKey
            bases[key] = (bases[key] ?? .zero) + c.quantity.base
        }
        var subtotals: [QuantitySubtotal] = []
        for (key, base) in bases {
            let hint = hintUnit(from: contributions, dimensionKey: key)
            let (unit, approx) = displayUnit(
                forBase: base, dimensionKey: key, hint: hint, system: system
            )
            subtotals.append(QuantitySubtotal(
                dimensionKey: key, base: base, preferredUnit: unit,
                isApproximateDisplay: approx
            ))
        }
        subtotals = collapseAcrossDimensions(subtotals, using: item, system: system)
        return subtotals.sorted { $0.dimensionKey < $1.dimensionKey }
    }

    /// Volume <-> mass, and ONLY with a per-item density.
    ///
    /// "1 cup flour + 200 g flour" is answered here. With no `gramsPerCup`, both buckets
    /// SURVIVE on one line and the caller flags `.needsBridge`. The app never invents a
    /// density — see `DensityCarrying.gramsPerCup` — which is also why the catalogue ships
    /// null for anything whose density is not settled, and why kosher salt has none at all.
    ///
    /// The collapsed bucket always carries a `conversionNote`, which is the mark that its
    /// number is only as good as the density it was given. `count` is never involved.
    static func collapseAcrossDimensions(
        _ subtotals: [QuantitySubtotal],
        using item: (any DensityCarrying)?,
        system: UnitSystem
    ) -> [QuantitySubtotal] {
        guard let item = item,
              let gramsPerCup = item.gramsPerCup,
              gramsPerCup != .zero
        else { return subtotals }

        let volumeKey = MeasureDimension.volume.rawValue
        let massKey = MeasureDimension.mass.rawValue
        guard let volume = subtotals.first(where: { $0.dimensionKey == volumeKey }),
              let mass = subtotals.first(where: { $0.dimensionKey == massKey })
        else { return subtotals }

        var kept = subtotals.filter {
            $0.dimensionKey != volumeKey && $0.dimensionKey != massKey
        }
        // Volume base is tsp; 48 tsp = 1 cup = gramsPerCup grams.
        let gramsPerTsp = gramsPerCup / Rational(48)
        let perCup = gramsPerCup.humanDescription

        if item.preferredDimension == .mass {
            let movedMass = volume.base * gramsPerTsp
            let total = mass.base + movedMass
            let (unit, approx) = displayUnit(
                forBase: total, dimensionKey: massKey, hint: mass.preferredUnit, system: system
            )
            let from = noteString(
                base: volume.base, dimensionKey: volumeKey,
                hint: volume.preferredUnit, system: system
            )
            let to = noteString(
                base: movedMass, dimensionKey: massKey,
                hint: mass.preferredUnit, system: system
            )
            kept.append(QuantitySubtotal(
                dimensionKey: massKey, base: total, preferredUnit: unit,
                conversionNote: "\(from) counted as \(to) at \(perCup) g per cup",
                isApproximateDisplay: approx
            ))
        } else {
            let movedVolume = mass.base / gramsPerTsp
            let total = volume.base + movedVolume
            let (unit, approx) = displayUnit(
                forBase: total, dimensionKey: volumeKey, hint: volume.preferredUnit, system: system
            )
            let from = noteString(
                base: mass.base, dimensionKey: massKey,
                hint: mass.preferredUnit, system: system
            )
            let to = noteString(
                base: movedVolume, dimensionKey: volumeKey,
                hint: volume.preferredUnit, system: system
            )
            kept.append(QuantitySubtotal(
                dimensionKey: volumeKey, base: total, preferredUnit: unit,
                conversionNote: "\(from) counted as \(to) at \(perCup) g per cup",
                isApproximateDisplay: approx
            ))
        }
        return kept
    }

    // MARK: - Bridging the HAVE side

    /// Converts `have` buckets into the dimensions `requested` actually uses. **Nothing else
    /// in this file does this, and without it the pantry case is broken.**
    ///
    /// The defect this exists to fix: `collapseAcrossDimensions` is only called from `sum`,
    /// and it returns early unless BOTH a volume and a mass subtotal are present in the same
    /// array. `requested` and `have` are summed independently, so each side carries only its
    /// own dimensions and that condition is never met. For a 2 tbsp butter requirement
    /// against a 4 oz lot, `requested` held only `volume`, `have` held only `mass`,
    /// `subtract` matched purely on `dimensionKey`, found nothing, bought the full 2 tbsp of
    /// butter he already had — and flagged `.needsBridge` on an item the shipped catalogue
    /// gives `gramsPerCup: 227`. The bridge existed; nothing called it.
    ///
    /// It bridges on DENSITY alone — volume ↔ mass, from the item's `gramsPerCup`. A count
    /// bucket has nowhere to go, because count nouns are not bridged in v1, and anything
    /// that still has nowhere to go is returned as-is. THAT is what `.needsBridge` is for.
    static func bridgeHave(
        _ have: [QuantitySubtotal],
        toward requestedKeys: Set<String>,
        using item: (any DensityCarrying)?,
        system: UnitSystem = .us
    ) -> (bridged: [QuantitySubtotal], unbridgeable: [QuantitySubtotal]) {
        guard let item = item else { return ([], have) }

        var gramsPerTsp: Rational? = nil
        if let g = item.gramsPerCup, g != .zero { gramsPerTsp = g / Rational(48) }

        let volumeKey = MeasureDimension.volume.rawValue
        let massKey = MeasureDimension.mass.rawValue
        var bridged: [QuantitySubtotal] = []
        var unbridgeable: [QuantitySubtotal] = []

        for bucket in have {
            if requestedKeys.contains(bucket.dimensionKey) {
                bridged.append(bucket)
                continue
            }
            var moved: QuantitySubtotal? = nil

            // Volume <-> mass, and ONLY with a per-item density. A count bucket that the
            // requirement does not already use falls through to `unbridgeable`.
            if let g = gramsPerTsp {
                let perCup = (g * Rational(48)).humanDescription
                let onHand = bucket.displayString(system: system)
                if bucket.dimensionKey == massKey, requestedKeys.contains(volumeKey) {
                    let base = bucket.base / g
                    let (unit, approx) = displayUnit(
                        forBase: base, dimensionKey: volumeKey, hint: nil, system: system
                    )
                    let to = noteString(
                        base: base, dimensionKey: volumeKey, hint: unit, system: system
                    )
                    moved = QuantitySubtotal(
                        dimensionKey: volumeKey, base: base, preferredUnit: unit,
                        conversionNote: "\(onHand) on hand counted as \(to) at \(perCup) g per cup",
                        isApproximateDisplay: approx
                    )
                } else if bucket.dimensionKey == volumeKey, requestedKeys.contains(massKey) {
                    let base = bucket.base * g
                    let (unit, approx) = displayUnit(
                        forBase: base, dimensionKey: massKey, hint: nil, system: system
                    )
                    let to = noteString(
                        base: base, dimensionKey: massKey, hint: unit, system: system
                    )
                    moved = QuantitySubtotal(
                        dimensionKey: massKey, base: base, preferredUnit: unit,
                        conversionNote: "\(onHand) on hand counted as \(to) at \(perCup) g per cup",
                        isApproximateDisplay: approx
                    )
                }
            }

            if let moved = moved {
                bridged.append(moved)
            } else {
                unbridgeable.append(bucket)
            }
        }
        return (bridged, unbridgeable)
    }

    // MARK: - Subtraction

    /// `toBuy = max(0, requested - have)`, per dimension, with BOTH sides clamped.
    ///
    /// A butter lot holding +1 lb (mass) and -2 tbsp (volume, used in cooking) yields a
    /// NEGATIVE volume have-subtotal from the signed ledger. Flooring only `toBuy` guards the
    /// wrong side: `1 cup - (-2 tbsp)` becomes `1 cup + 2 tbsp` and the negative residue
    /// silently INFLATES the purchase. So `have` is clamped first.
    ///
    /// Then, BEFORE the per-requirement loop, `bridgeHave` is given the chance to move stock
    /// into a dimension the requirement actually uses. Only stock that survives that attempt
    /// raises `.needsBridge` — a known density must never produce a bridge warning, which is
    /// the second half of the defect `bridgeHave` fixes.
    ///
    /// When a requirement and the matching stock are in DIFFERENT dimensions and the item
    /// carries no usable bridge, `needed = requested` — assume NOTHING is on hand — and the
    /// line is flagged `.needsBridge`. Never silently subtract, and never silently treat the
    /// requirement as covered: buying a duplicate pound of butter is a far cheaper error than
    /// arriving at dinner without it.
    ///
    /// `didReduce` is returned so the caller can tell `.partiallyHave` from `.needed`. A line
    /// where some bucket was genuinely reduced but not to zero is a different fact from a
    /// line nothing covered, and `ShoppingListDetailView` partitions on it.
    static func subtract(
        requested: [QuantitySubtotal],
        have: [QuantitySubtotal],
        item: (any DensityCarrying)?,
        system: UnitSystem = .us
    ) -> (toBuy: [QuantitySubtotal], flags: Set<LineFlag>, didReduce: Bool) {
        var flags: Set<LineFlag> = []
        let requestedKeys = Set(requested.map { $0.dimensionKey })
        let clamped = have.map { bucket in
            QuantitySubtotal(
                dimensionKey: bucket.dimensionKey, base: bucket.base.clampedAtZero,
                preferredUnit: bucket.preferredUnit, conversionNote: bucket.conversionNote,
                isApproximateDisplay: bucket.isApproximateDisplay
            )
        }
        let (usable, unbridgeable) = bridgeHave(
            clamped, toward: requestedKeys, using: item, system: system
        )
        // ONLY stock that could not be converted raises the flag. The old condition read
        // `item?.gramsPerCup == nil`, which fired on a dimension mismatch the density could
        // in fact bridge, and the second condition fired whenever ANY bucket was unmatched —
        // so one unbridgeable row flagged every requirement on the line.
        if !unbridgeable.isEmpty { flags.insert(.needsBridge) }
        if usable.contains(where: { !$0.conversionNote.isEmpty }) { flags.insert(.converted) }

        var haveByKey: [String: Rational] = [:]
        for bucket in usable {
            haveByKey[bucket.dimensionKey] = (haveByKey[bucket.dimensionKey] ?? .zero) + bucket.base
        }

        var out: [QuantitySubtotal] = []
        var didReduce = false
        for r in requested {
            let onHand = haveByKey[r.dimensionKey] ?? .zero
            if onHand != .zero { didReduce = true }
            let remainder = (r.base - onHand).clampedAtZero
            guard remainder != .zero else { continue }
            let (unit, approx) = displayUnit(
                forBase: remainder, dimensionKey: r.dimensionKey,
                hint: r.preferredUnit, system: system
            )
            out.append(QuantitySubtotal(
                dimensionKey: r.dimensionKey, base: remainder,
                preferredUnit: unit, conversionNote: r.conversionNote,
                isApproximateDisplay: approx
            ))
        }
        return (out, flags, didReduce)
    }
}
