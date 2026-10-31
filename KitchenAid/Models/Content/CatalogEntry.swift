import Foundation

/// One catalogue entry: the TEMPLATE a `FoodItem` is created from. Not a row, not seeded into
/// the store, and never written to.
///
/// **These names are `scripts/build_catalogue.py`'s names.** If the script changes a key,
/// this file changes with it in the same commit, and `IngredientCatalogTests` is what catches
/// the mismatch. `ingredients.json` is generated, never hand-edited (`CLAUDE.md`), so there
/// are no importer-alternate spellings here — one writer, one spelling.
struct CatalogEntry: Codable, Hashable, Sendable, Identifiable {

    /// The canonical name, collision-free by construction — the build script fails on a
    /// duplicate, and on an alias colliding with a name or another alias. This is the value
    /// `FoodItem.catalogName` stores.
    var name: String = ""
    var id: String { name }
    /// The store section, which is also a seeded `StoreSection.name`.
    var aisle: String = ""
    /// mass | volume | count. Decides what can be ADDED to what, and is the reason
    /// "16 oz steak" never becomes a volume.
    var dimension: MeasureDimension = .count
    /// The unit to default to when he adds this by hand.
    var unit: String = "each"
    /// The unit to prefer when the recipe is a bake — 300 g of bread flour, not 2 1/2 cups,
    /// because volume measurement of flour varies by up to 20% and that is the difference
    /// between bread and a brick. nil = use `unit`.
    var bakingUnit: String? = nil
    /// Grams per US cup, or nil when the density is not settled. **nil means the app
    /// REFUSES to convert**, which is the whole point: kosher salt is deliberately absent
    /// from the script's table because Diamond Crystal is ~142 g/cup and Morton ~288.
    var gramsPerCup: Int? = nil
    /// Tracked present/absent with no quantity. Counting teaspoons of salt is work nobody
    /// does, and a list that keeps asking for salt is a list you stop reading.
    var staple: Bool = false
    var aliases: [String] = []

    enum CodingKeys: String, CodingKey {
        case name, aisle, dimension, unit, bakingUnit, gramsPerCup, staple, aliases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.aisle = try c.decodeIfPresent(String.self, forKey: .aisle) ?? ""
        self.dimension = c.decodeRawValue(MeasureDimension.self, forKey: .dimension, fallback: .count)
        self.unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? "each"
        self.bakingUnit = try c.decodeIfPresent(String.self, forKey: .bakingUnit)
        self.gramsPerCup = try c.decodeIfPresent(Int.self, forKey: .gramsPerCup)
        self.staple = try c.decodeIfPresent(Bool.self, forKey: .staple) ?? false
        self.aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    init(name: String, aisle: String = "", dimension: MeasureDimension = .count, unit: String = "each") {
        self.name = name
        self.aisle = aisle
        self.dimension = dimension
        self.unit = unit
    }
}

extension CatalogEntry {
    var defaultUnit: KitchenUnit? { UnitCatalog.unit(code: unit, fallbackDimension: dimension) }
    var preferredBakingUnit: KitchenUnit? {
        guard let bakingUnit else { return nil }
        return UnitCatalog.unit(code: bakingUnit, fallbackDimension: dimension)
    }
    var trackingMode: StockTrackingMode { staple ? .staple : .tracked }
    var matchKey: String { NameNormalizer.matchKey(name) }
    var aliasMatchKeys: [String] { aliases.map(NameNormalizer.matchKey) }
    /// Every key a lookup may arrive on, name first. The build script guarantees no two
    /// entries share one, so "whichever comes first" never decides a pantry match.
    var allMatchKeys: [String] { [matchKey] + aliasMatchKeys }
}
