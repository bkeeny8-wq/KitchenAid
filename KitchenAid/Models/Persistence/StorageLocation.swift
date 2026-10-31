import Foundation
import SwiftData

/// Pantry, fridge, freezer, spice rack, bar, garage fridge. A model for the same reasons as
/// `StoreSection` — "Garage fridge" arrives without a build — and the reason butter can be in
/// two places at once with two different expiries.
@Model
final class StorageLocation {
    var id: UUID = UUID()
    var name: String = ""
    var matchKey: String = ""

    /// `StorageKind`: a coarse classification for icons and default shelf lives. The NAME is
    /// what he reads; this is only what the app guesses from.
    var kindRaw: String = StorageKind.pantry.rawValue

    var sortIndex: Int = 0
    var symbolName: String = "cabinet"

    /// Used to pre-fill `StockLot.expiresAt` on receive. nil, not 0 — zero days is a
    /// meaningful (if silly) value and absent is not.
    var defaultShelfLifeDays: Int? = nil

    var createdAt: Date = .now

    @Relationship(deleteRule: .nullify, inverse: \StockLot.location)
    var lots: [StockLot]? = []

    @Relationship(deleteRule: .nullify, inverse: \FoodItem.defaultLocation)
    var foodItems: [FoodItem]? = []

    @Relationship(deleteRule: .nullify, inverse: \ShoppingListLine.destinationLocation)
    var shoppingLines: [ShoppingListLine]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        matchKey: String = "",
        kindRaw: String = StorageKind.pantry.rawValue,
        sortIndex: Int = 0,
        symbolName: String = "cabinet",
        defaultShelfLifeDays: Int? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.matchKey = matchKey
        self.kindRaw = kindRaw
        self.sortIndex = sortIndex
        self.symbolName = symbolName
        self.defaultShelfLifeDays = defaultShelfLifeDays
        self.createdAt = createdAt
    }
}

extension StorageLocation {
    var kind: StorageKind { StorageKind(rawValue: kindRaw) ?? .pantry }

    var displayName: String { name.isEmpty ? "Storage" : name }

    var orderedLots: [StockLot] {
        (lots ?? []).sorted { $0.acquiredAt < $1.acquiredAt }
    }

    var orderedFoodItems: [FoodItem] {
        (foodItems ?? []).sorted { $0.name < $1.name }
    }

    var allShoppingLines: [ShoppingListLine] { shoppingLines ?? [] }

    func setName(_ newName: String) {
        name = newName
        matchKey = NameNormalizer.matchKey(newName)
    }

    /// The best-by to pre-fill on a lot received into this location, or nil when the location
    /// has no default. Day-granular: a shelf life measured to the second is false precision
    /// on a date he reads as "around the 14th".
    func suggestedExpiry(from date: Date = .now, calendar: Calendar = .current) -> Date? {
        guard let days = defaultShelfLifeDays else { return nil }
        return calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date))
    }

    static func seeded(
        name: String,
        kind: StorageKind,
        sortIndex: Int,
        symbolName: String = "cabinet",
        defaultShelfLifeDays: Int? = nil
    ) -> StorageLocation {
        StorageLocation(
            name: name,
            matchKey: NameNormalizer.matchKey(name),
            kindRaw: kind.rawValue,
            sortIndex: sortIndex,
            symbolName: symbolName,
            defaultShelfLifeDays: defaultShelfLifeDays
        )
    }
}
