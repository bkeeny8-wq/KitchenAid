import Foundation

/// Volume, mass and count are different physical dimensions and are NOT convertible without
/// per-item data. The app never guesses a density.
///
/// Requirement 6 from the fixture: units carry an explicit dimension, because bare "oz" means
/// weight ounces three times in that document and fluid ounces elsewhere. There is
/// deliberately NO `length` dimension: "1/2 inch thick" is descriptive and not purchasable,
/// so it lives in `IngredientLine.preparation`.
///
/// The raw values are `"volume"`, `"mass"`, `"count"` — which is exactly what
/// `scripts/build_catalogue.py` writes into `ingredients.json`, so `CatalogEntry.dimension`
/// decodes straight into this with no mapping table.
enum MeasureDimension: String, Codable, CaseIterable, Sendable {
    case volume      // base unit: teaspoon
    case mass        // base unit: gram
    case count       // base unit: the noun itself ("clove", "slice", "each")
    /// Reached by the parser, never persisted on a line with an amount. A pinch is a nil
    /// quantity plus an `unmeasuredNote`, not a unit.
    case unmeasured

    var baseUnitCode: String {
        switch self {
        case .volume: return "tsp"
        case .mass: return "g"
        case .count: return "each"
        case .unmeasured: return ""
        }
    }

    var title: String {
        switch self {
        case .volume: return "Volume"
        case .mass: return "Weight"
        case .count: return "Count"
        case .unmeasured: return "Unmeasured"
        }
    }
}
