import Foundation
import SwiftData

/// A shop he actually walks. One seeded "Default" row is enough for v1, and the model exists
/// so a second store can carry its own aisle geography without a migration — a list printed
/// for the warehouse store should not be ordered for the grocery down the street.
@Model
final class Store {
    var id: UUID = UUID()
    var name: String = "Default"

    /// Which store a new list is built for. Not a uniqueness constraint and not enforced by
    /// the schema: CloudKit forbids `@Attribute(.unique)`, so two devices can both set it and
    /// `defaultStore(in:)` below settles the tie deterministically instead of trusting that
    /// exactly one row says true.
    var isDefault: Bool = true

    var sortIndex: Int = 0
    var notes: String = ""
    var createdAt: Date = .now

    /// A section belongs to its store's geography and means nothing without it.
    @Relationship(deleteRule: .cascade, inverse: \StoreSection.store)
    var sections: [StoreSection]? = []

    /// Deleting a store must not delete last month's trips.
    @Relationship(deleteRule: .nullify, inverse: \ShoppingList.store)
    var shoppingLists: [ShoppingList]? = []

    init(
        id: UUID = UUID(),
        name: String = "Default",
        isDefault: Bool = true,
        sortIndex: Int = 0,
        notes: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.sortIndex = sortIndex
        self.notes = notes
        self.createdAt = createdAt
    }
}

extension Store {
    var orderedSections: [StoreSection] {
        (sections ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var allShoppingLists: [ShoppingList] { shoppingLists ?? [] }

    var displayName: String { name.isEmpty ? "Store" : name }

    /// Deterministic, so two devices that both seeded a store agree on which one a new list
    /// is built for before the reconcile pass merges them: earliest `createdAt`, tie-broken
    /// by lowest `id.uuidString`. The same rule the `FoodItem` merge survivor uses, and for
    /// the same reason — a "best row" heuristic lets the two devices ping-pong forever.
    static func preferred(from stores: [Store]) -> Store? {
        let candidates = stores.contains(where: { $0.isDefault })
            ? stores.filter { $0.isDefault }
            : stores
        return candidates.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }.first
    }

    /// Resolve a catalogue aisle name to one of this store's sections. Matched on `matchKey`,
    /// so a seeded "Dry goods" and a hand-typed "dry goods" are one aisle.
    func section(matchingAisle aisle: String) -> StoreSection? {
        let key = NameNormalizer.matchKey(aisle)
        guard !key.isEmpty else { return nil }
        return orderedSections.first { $0.matchKey == key }
    }
}
