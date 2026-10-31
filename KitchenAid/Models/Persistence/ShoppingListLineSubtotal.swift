import Foundation
import SwiftData

/// One (role, dimension) subtotal on one line. **The persisted mirror of `QuantitySubtotal`**
/// — same fields, same meaning, one in the store and one in flight.
///
/// `dimensionKey` is "volume" | "mass" | "count:clove" | "count:head", exactly as
/// `KitchenUnit.dimensionKey` spells it. Partitioning count by its NOUN is what stops
/// "2 cloves garlic + 1 clove + 1 head" summing to "4 cloves" and understating garlic by
/// about 50 g — and it is why the merge key and the output type agree, so the display can
/// actually show what the aggregation correctly separated.
///
/// N of these hang off ONE line. The dimension is a key inside a line, never a line of its
/// own: see `ShoppingListLine`.
@Model
final class ShoppingListLineSubtotal {
    var id: UUID = UUID()
    /// `SubtotalRole`: requested / have / toBuy / purchase.
    var roleRaw: String = SubtotalRole.requested.rawValue
    var dimensionKey: String = ""
    /// The EXACT value in the dimension's base unit (tsp / g / count-of-noun), stored as
    /// integers so it survives any future change to the display ladder.
    var baseNumerator: Int = 0
    var baseDenominator: Int = 1
    /// The unit this should be rendered in, chosen at generation by `QuantityMath.displayUnit`.
    /// Frozen, so a printed list reads the same in March.
    var preferredUnitCode: String = ""
    /// Rides with the SPECIFIC number that was converted — "200 g counted as 2 2/3 cups at
    /// 120 g per cup" — which a line-level string cannot express. Built by `QuantityMath`
    /// through the display ladder and never by interpolating a base value: review 03 traced
    /// the fixture's butter against a 4 oz lot and found a note reading "23 1111/1135 tsp".
    var conversionNote: String = ""
    /// Set when the stored exact value cannot be rendered to a kitchen fraction, so what he
    /// reads is an approximation. This is a fact about the STORED value for whoever owns it
    /// (the diff sheet, the tests); it is not what puts the "≈" in the text — see
    /// `displayString(system:)`.
    var isApproximateDisplay: Bool = false
    var sortIndex: Int = 0
    /// Owner. Macro lives on `ShoppingListLine.subtotalRows`.
    var line: ShoppingListLine? = nil

    init(
        id: UUID = UUID(),
        roleRaw: String = SubtotalRole.requested.rawValue,
        dimensionKey: String = "",
        baseNumerator: Int = 0,
        baseDenominator: Int = 1,
        preferredUnitCode: String = "",
        conversionNote: String = "",
        isApproximateDisplay: Bool = false,
        sortIndex: Int = 0,
        line: ShoppingListLine? = nil
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.dimensionKey = dimensionKey
        self.baseNumerator = baseNumerator
        self.baseDenominator = baseDenominator
        self.preferredUnitCode = preferredUnitCode
        self.conversionNote = conversionNote
        self.isApproximateDisplay = isApproximateDisplay
        self.sortIndex = sortIndex
        self.line = line
    }
}

// MARK: - Reading the row

extension ShoppingListLineSubtotal {
    var role: SubtotalRole { SubtotalRole(rawValue: roleRaw) ?? .requested }

    /// `max(1, _)` because `Rational.init` treats a zero denominator as a programmer error
    /// and traps, and this denominator comes out of the store — where a row written by a
    /// newer build, or a half-finished migration, can hand back a 0.
    var base: Rational { Rational(baseNumerator, max(1, baseDenominator)) }

    var quantity: Quantity? {
        guard let unit = UnitCatalog.unit(code: preferredUnitCode, fallbackDimension: nil),
              unit.baseFactor != .zero
        else { return nil }
        return Quantity(amount: base / unit.baseFactor, unit: unit)
    }

    /// The HUMAN rendering. A function and not a property because the unit system belongs to
    /// the list that was shopped (`ShoppingList.unitSystem`), not to the row — the same
    /// reason `QuantitySubtotal.displayString(system:)` is a function, and this is its mirror.
    ///
    /// The "≈" comes from `Quantity.displayString`, which adds it when ITS rounding lost
    /// something. This used to prefix one of its own from `isApproximateDisplay`, which
    /// prints "≈ ≈ 3 3/4 oz" on every row where both are true.
    func displayString(system: UnitSystem = .us) -> String {
        guard let q = quantity else { return base.humanDescription }
        return q.displayString(system: system)
    }

    /// EXACT, for diagnostics and tests. Never shown to him.
    var exactDescription: String {
        guard let q = quantity else { return base.exactDescription }
        return q.exactDescription
    }

    /// Round-trips to the in-flight type, so the builder and the store share one shape.
    var asSubtotal: QuantitySubtotal? {
        guard let unit = UnitCatalog.unit(code: preferredUnitCode, fallbackDimension: nil)
        else { return nil }
        return QuantitySubtotal(
            dimensionKey: dimensionKey,
            base: base,
            preferredUnit: unit,
            conversionNote: conversionNote,
            isApproximateDisplay: isApproximateDisplay
        )
    }
}

// MARK: - Writing the row

extension ShoppingListLineSubtotal {
    /// The other half of the round trip, and the only thing that should write the two base
    /// integers: splitting an exact `Rational` into a numerator and a denominator by hand at
    /// four call sites — one per role — is four chances to store 0/1 and ship a line that
    /// asks for nothing.
    static func from(
        _ subtotal: QuantitySubtotal,
        role: SubtotalRole,
        sortIndex: Int = 0
    ) -> ShoppingListLineSubtotal {
        ShoppingListLineSubtotal(
            roleRaw: role.rawValue,
            dimensionKey: subtotal.dimensionKey,
            baseNumerator: subtotal.base.numerator,
            baseDenominator: subtotal.base.denominator,
            preferredUnitCode: subtotal.preferredUnit.code,
            conversionNote: subtotal.conversionNote,
            isApproximateDisplay: subtotal.isApproximateDisplay,
            sortIndex: sortIndex
        )
    }
}
