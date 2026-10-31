import Foundation
import SwiftData

/// One aisle, under a `Store`.
///
/// A MODEL and not an enum, for three reasons that each cost a shipped build otherwise: he
/// cannot add "Fish counter" without one; a second store cannot have its own geography; and
/// reordering an enum's cases is a migration while reordering `sortIndex` is a drag. Keeping
/// the walk order in `UserDefaults` is worse again — that suite is deliberately not synced,
/// so his iPad would shop a different aisle order than his phone.
///
/// The seeded `name`s are exactly the catalogue's 13 `aisle` values, matched on `matchKey`,
/// so a `FoodItem` minted from a template lands in the right aisle with no mapping table.
/// **The walk order is READ from the JSON's `aisleOrder`**, not kept here:
/// `ingredients.json`'s `items` array is sorted alphabetically by aisle, which is not a walk
/// order, so the file carries the order separately and the seed writes it into `sortIndex`
/// once. From then on `sortIndex` is a row he drags, and a catalogue rebuild never silently
/// reorders aisles he has already arranged.
@Model
final class StoreSection {
    var id: UUID = UUID()
    var name: String = ""

    /// `NameNormalizer.matchKey(name)`. Stored, not computed, so the aisle lookup a mint
    /// performs can be a `#Predicate`.
    var matchKey: String = ""

    /// The order he physically walks the store. Seeded from `aisleOrder` — perimeter first,
    /// centre aisles next, frozen last so it is not going soft in the cart while he picks out
    /// spices — and reordered by hand the first time he shops with the app.
    var sortIndex: Int = 0

    var symbolName: String = "basket"
    var colorIndex: Int = 0
    var createdAt: Date = .now

    /// Owner. Macro lives on `Store.sections` (`.cascade`).
    var store: Store? = nil

    @Relationship(deleteRule: .nullify, inverse: \FoodItem.defaultSection)
    var foodItems: [FoodItem]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        matchKey: String = "",
        sortIndex: Int = 0,
        symbolName: String = "basket",
        colorIndex: Int = 0,
        createdAt: Date = .now,
        store: Store? = nil
    ) {
        self.id = id
        self.name = name
        self.matchKey = matchKey
        self.sortIndex = sortIndex
        self.symbolName = symbolName
        self.colorIndex = colorIndex
        self.createdAt = createdAt
        self.store = store
    }
}

extension StoreSection {
    var orderedFoodItems: [FoodItem] {
        (foodItems ?? []).sorted { $0.name < $1.name }
    }

    var displayName: String { name.isEmpty ? "Aisle" : name }

    /// Keeps `name` and `matchKey` from describing different aisles, which would strand every
    /// item minted into the old key.
    func setName(_ newName: String) {
        name = newName
        matchKey = NameNormalizer.matchKey(newName)
    }

    /// The seed's spelling: one aisle name from `IngredientCatalog.aisleOrder`, at its index
    /// in that array. Written here rather than in the seed so the `matchKey` the mint looks
    /// items up by cannot be computed one way in one file and another way in another.
    static func seeded(aisle: String, sortIndex: Int, store: Store? = nil) -> StoreSection {
        StoreSection(
            name: aisle,
            matchKey: NameNormalizer.matchKey(aisle),
            sortIndex: sortIndex,
            store: store
        )
    }
}
