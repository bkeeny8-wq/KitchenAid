import Foundation

/// `KitchenAid/Resources/ingredients.json`, decoded as `scripts/build_catalogue.py` emits it.
///
/// It exists for one reason: adding something must be picking, not typing. Nobody populates
/// several hundred ingredients by hand, and an app that asks him to is an app he stops
/// opening.
struct CatalogFile: Codable, Sendable {
    var version: Int = 1
    /// **The authoritative store walk order**, emitted by the build script's
    /// `AISLE_WALK_ORDER`. `items` is sorted alphabetically by aisle, which is not a walk
    /// order, so the order travels separately — and the app READS this rather than keeping a
    /// second copy in the seed, because two copies of a list drift and no test here can catch
    /// it.
    var aisleOrder: [String] = []
    var items: [CatalogEntry] = []

    enum CodingKeys: String, CodingKey { case version, aisleOrder, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.aisleOrder = try c.decodeIfPresent([String].self, forKey: .aisleOrder) ?? []
        self.items = try c.decodeIfPresent([CatalogEntry].self, forKey: .items) ?? []
    }

    init(version: Int = 1, aisleOrder: [String] = [], items: [CatalogEntry] = []) {
        self.version = version
        self.aisleOrder = aisleOrder
        self.items = items
    }
}

extension CatalogFile {
    /// Where an aisle falls on the walk, for sorting shopping-list sections. An aisle the
    /// catalogue does not name sorts LAST rather than first: a hand-added section he invented
    /// at the checkout belongs at the end of the walk, not ahead of Produce.
    func walkIndex(ofAisle aisle: String) -> Int {
        aisleOrder.firstIndex(of: aisle) ?? aisleOrder.count
    }
}
