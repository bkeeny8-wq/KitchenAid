import Foundation

/// An amount and a unit.
///
/// WHY NOT `Measurement<UnitVolume>`, decided once:
///
/// - It is `Double`-backed, so 1/3 cup renders as 0.333333 on the first screen he opens, and
///   1/3 cup × 3 is not 1 cup.
/// - It is GENERIC over its dimension, so one property cannot hold both "1/4 cup" and
///   "2 cloves" — and an ingredient list is heterogeneous by nature.
/// - `UnitVolume` has no `clove`, `bunch`, `package` or `to taste`, which is most of how
///   recipes are actually written.
/// - Any `Measurement` stored in SwiftData needs a `Codable` wrapper anyway, so the "free"
///   option was never free.
///
/// A custom type was therefore mandatory regardless; given that, one well-tested type beats a
/// `Measurement` for some lines and something else for the rest.
struct Quantity: Hashable, Sendable {
    var amount: Rational
    var unit: KitchenUnit

    var dimension: MeasureDimension { unit.dimension }
    var dimensionKey: String { unit.dimensionKey }

    /// In tsp / g / count-of-this-noun.
    var base: Rational { amount * unit.baseFactor }

    func scaled(by factor: Rational) -> Quantity {
        Quantity(amount: amount * factor, unit: unit)
    }

    /// nil across dimension keys — including across two different count nouns, which is the
    /// point. Nothing in v1 crosses two count nouns: that is purchase-unit rounding, and it
    /// is deferred (`CLAUDE.md`).
    func converted(to target: KitchenUnit) -> Quantity? {
        guard target.dimensionKey == dimensionKey, target.baseFactor != .zero else { return nil }
        return Quantity(amount: base / target.baseFactor, unit: target)
    }

    /// The HUMAN rendering: the unit a cook would use, the amount rounded to a kitchen
    /// fraction or to one decimal place, and "≈" when that rounding lost anything.
    ///
    /// This is the only rendering any label, badge, note or exported line may use. The
    /// exact value is never printed to him: review 03 traced the fixture's butter against a
    /// 4 oz lot and found a conversion note reading "23 1111/1135 tsp" — exact, and useless.
    /// `displayUnit`'s own approximate flag is not consulted here; it tells the OWNER of a
    /// subtotal that the stored value cannot be shown exactly (and is what
    /// `QuantitySubtotal.isApproximateDisplay` freezes), while the rounding below decides
    /// what the characters say.
    func displayString(system: UnitSystem = .us) -> String {
        let (chosen, _) = QuantityMath.displayUnit(
            forBase: base, dimensionKey: dimensionKey, hint: unit, system: system
        )
        let value = chosen.baseFactor == .zero ? amount : base / chosen.baseFactor
        let rounded = value.kitchenRounded()
        let prefix = rounded.isApproximate ? "\u{2248} " : ""
        let name = chosen.name(for: rounded.value)
        return name.isEmpty
            ? "\(prefix)\(rounded.text)"
            : "\(prefix)\(rounded.text) \(name)"
    }

    /// EXACT, in the unit this quantity is actually written in. For diagnostics, tests and
    /// round-trips — never for a user-facing string.
    var exactDescription: String {
        let name = unit.name(for: amount)
        return name.isEmpty
            ? amount.exactDescription
            : "\(amount.exactDescription) \(name)"
    }
}

// MARK: - The persistence bridge

/// The five stored primitives a model that holds ONE quantity declares, and the computed
/// accessor they share.
///
/// Quantities persist as FLAT PRIMITIVES, never as a `Codable` composite attribute. SwiftData
/// stores a `Codable` struct as an opaque encoded blob: it is unqueryable by `#Predicate`,
/// unreadable in the CloudKit dashboard, and — decisively — any future change to `Rational`
/// or to the unit table requires a custom migration stage that decodes every stored row in
/// the OLD Codable shape before re-encoding it. That is precisely the migration this project
/// exists to avoid. Five defaulted scalars survive every additive schema change, and
/// `unitCode` is a `String` rather than an enum for the same reason: the unit table has to be
/// able to grow a count noun without a store version.
///
/// A type may conform once, so the models carrying TWO or MORE quantities — `StockLot`
/// (`remaining`, `original`), `FoodItem` (`gramsPerCup`, `parLevel`) — use the same
/// five-primitive shape with distinct prefixes and their own accessors instead. The protocol
/// is the convenience; the SHAPE is the contract. In this schema the one conformer is
/// `IngredientOverride`.
protocol QuantityCarrying: AnyObject {
    var hasQuantity: Bool { get set }
    var amountNumerator: Int { get set }
    var amountDenominator: Int { get set }
    var unitCode: String { get set }
    var dimensionRaw: String { get set }
}

extension QuantityCarrying {
    /// nil means THERE IS NO QUANTITY — "Pinch flaky salt", "salt to taste". A nil quantity
    /// never enters arithmetic, never suppresses a shopping line, and cannot be confused with
    /// a deliberate zero or with a parse failure.
    var quantity: Quantity? {
        get {
            guard hasQuantity,
                  let unit = UnitCatalog.unit(
                      code: unitCode,
                      fallbackDimension: MeasureDimension(rawValue: dimensionRaw)
                  )
            else { return nil }
            return Quantity(
                amount: Rational(amountNumerator, max(1, amountDenominator)),
                unit: unit
            )
        }
        set {
            guard let q = newValue else {
                // All FIVE primitives are cleared together. Leaving `unitCode` and
                // `dimensionRaw` at their previous values leaves a row that has no quantity
                // and still claims `tbsp`/`volume` — which no accessor reads, and which
                // `StoreHealthView`, the CloudKit dashboard and any future migration all
                // read as a contradiction. "A quantity that does not exist is nil" is only
                // true if the whole group goes.
                hasQuantity = false
                amountNumerator = 0
                amountDenominator = 1
                unitCode = ""
                dimensionRaw = MeasureDimension.unmeasured.rawValue
                return
            }
            hasQuantity = true
            amountNumerator = q.amount.numerator
            amountDenominator = q.amount.denominator
            unitCode = q.unit.code
            dimensionRaw = q.unit.dimension.rawValue
        }
    }
}
