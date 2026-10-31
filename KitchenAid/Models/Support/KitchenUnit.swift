import Foundation

/// A STRUCT, not an enum.
///
/// Count nouns are an open set that recipes extend — clove, head, slice, loaf, bunch, sprig,
/// stick, can, ear, fillet, rib, stalk, leaf. More importantly, each count noun must be its
/// own aggregation bucket: with a single `.count` dimension sharing a factor into "each",
/// "2 cloves garlic" + "1 clove" + "1 head garlic" sums to 4 and renders "4 cloves",
/// understating garlic by about 50 g. `dimensionKey` below is what prevents that, and it
/// costs nothing.
///
/// Nothing persists a `KitchenUnit`. A row stores `code` as a `String` and resolves it
/// through `UnitCatalog`, so the unit table can grow — a new count noun, a new metric unit —
/// without a store migration.
struct KitchenUnit: Hashable, Sendable, Identifiable {
    let code: String                 // PERSISTED, as a plain String. "tbsp", "g", "clove"
    let dimension: MeasureDimension
    /// Factor into the dimension's base unit, as an exact `Rational`.
    let baseFactor: Rational
    let singular: String
    let plural: String
    /// Excluded from DISPLAY selection when false. Without this, 18 tsp of butter legally
    /// renders as "3 fl oz", which is not a thing a cook says.
    let isHouseholdCommon: Bool
    let system: UnitSystem           // .us, .metric, .agnostic

    var id: String { code }
    var isCount: Bool { dimension == .count }

    /// The aggregation bucket. "volume" | "mass" | "count:clove" | "unmeasured".
    var dimensionKey: String {
        dimension == .count ? "count:\(code)" : dimension.rawValue
    }

    func name(for amount: Rational) -> String {
        amount == .one ? singular : plural
    }
}
