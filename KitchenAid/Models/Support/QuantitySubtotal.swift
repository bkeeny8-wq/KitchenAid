import Foundation

/// ONE (dimension, count-noun) subtotal, in base units. **The only declaration.**
///
/// The design panel listed a `QuantitySubtotal.swift` in its manifest with no spec, while
/// declaring the same thing as a nested `QuantityMath.Subtotal` — so half its signatures said
/// one and half said the other, and neither had an owner. Resolved here: this is a top-level
/// type in its own file, `QuantityMath.Subtotal` does not exist, and every signature in the
/// math, the shopping-list builder and the services names `QuantitySubtotal`.
/// `ShoppingListLineSubtotal` is its persisted mirror and converts both ways.
struct QuantitySubtotal: Hashable, Sendable {
    /// "volume" | "mass" | "count:clove". The aggregation bucket, and the reason clove and
    /// head are separate subtotals ON ONE LINE.
    var dimensionKey: String
    /// EXACT, in tsp / g / count-of-noun. Never rounded — `base` is what the next build's
    /// arithmetic starts from.
    var base: Rational
    /// The unit chosen for display. Frozen onto the persisted row so a printed list reads
    /// the same in March.
    var preferredUnit: KitchenUnit
    /// Rides with the SPECIFIC number that was converted, which a line-level string cannot
    /// express. A non-empty note is also the mark that a volume↔mass density bridge fired on
    /// this bucket, which is why the builder raises `.converted` from it: the number is
    /// correct to the density it was given and no further.
    var conversionNote: String = ""
    /// Set when the exact value does not render to a denominator <= 8, so the display is an
    /// approximation prefixed "≈". The exact value is still what is stored.
    var isApproximateDisplay: Bool = false

    var quantity: Quantity? {
        guard preferredUnit.baseFactor != .zero else { return nil }
        return Quantity(amount: base / preferredUnit.baseFactor, unit: preferredUnit)
    }

    /// The HUMAN rendering, in the frozen `preferredUnit`. A function and not a property so
    /// the display system can be passed down; `QuantityMath` builds every conversion note
    /// through this rather than interpolating `base`.
    func displayString(system: UnitSystem = .us) -> String {
        guard let q = quantity else { return base.humanDescription }
        return q.displayString(system: system)
    }

    /// EXACT, for diagnostics and tests.
    var exactDescription: String {
        guard let q = quantity else { return base.exactDescription }
        return q.exactDescription
    }
}

/// Which of the four numbers on a shopping line this subtotal is.
///
/// All four are kept per line and per dimension. `toBuy` is what he shops by; `purchase` is
/// what `InventoryLedger.receive(_:in:)` posts. In v1 `purchase` equals `toBuy`, because
/// purchase-unit rounding is deferred (`CLAUDE.md`) — it is a separate role so that rounding
/// could one day arrive as a writer rather than as a migration.
enum SubtotalRole: String, Codable, CaseIterable, Sendable {
    case requested, have, toBuy, purchase

    var title: String {
        switch self {
        case .requested: return "Need"
        case .have: return "Have"
        case .toBuy: return "Buy"
        case .purchase: return "Purchase"
        }
    }
}
