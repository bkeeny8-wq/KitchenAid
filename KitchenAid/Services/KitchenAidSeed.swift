import Foundation
import SwiftData

/// THE ONE-TIME ROWS: storage locations, one store with its aisles, and the household.
///
/// A static namespace and not an `@Observable` service, because it holds no state and is
/// called exactly once from the launch task. There is nothing for a view to observe and
/// nothing for `.environment(...)` to inject.
///
/// Everything here is gated by a `SeedRecord` fetched BEFORE it is applied. That is how
/// idempotence is bought without `@Attribute(.unique)`, which a CloudKit-backed store
/// rejects (`CLAUDE.md`). The key carries its own version — `sections.v1` — so a later build
/// that wants to add an aisle writes `sections.v2` and the first seed is left alone, rather
/// than needing a migration or a hand-edit of a shipped device.
///
/// IT SEEDS NO `FoodItem` AND NO RECIPE. The 669 catalogue entries are content, minted into
/// rows on demand (`IngredientCatalog`), and recipes are bundled files (`RecipeLoader`).
enum KitchenAidSeed {

    static let sectionsKey = "sections.v1"
    static let locationsKey = "locations.v1"
    static let householdKey = "household.v1"

    /// Called once from the App's launch task, AFTER `IngredientCatalog.load()`, because the
    /// aisle walk order is read from the catalogue and is deliberately not copied here.
    ///
    /// Throwing rather than swallowing: the caller decides, and the launch task calls this
    /// with `try?` so a failed seed cannot stop the app from opening on a device whose store
    /// is already in an in-memory fallback.
    static func applyIfNeeded(in context: ModelContext, catalog: IngredientCatalog) throws {
        try seedLocations(in: context)
        try seedSections(in: context, catalog: catalog)
        try seedHousehold(in: context)
        try context.save()
    }

    // MARK: - Storage locations

    /// The places food sits, with the shelf lives that pre-fill a lot's best-by.
    ///
    /// One row per `StorageKind` case rather than a longer list of names, because the kind is
    /// what the app guesses a default shelf life and an icon from, and a location whose kind
    /// is `.other` can be added by hand in a second. He renames and adds freely afterwards;
    /// a garage fridge arrives without a build.
    private static func seedLocations(in context: ModelContext) throws {
        guard try !isApplied(locationsKey, in: context) else { return }

        // A sync can deliver another device's locations before this device's SeedRecord
        // arrives. Writing a second Pantry then looks to him like the app duplicated his
        // kitchen, so the record is written and nothing is inserted.
        guard try context.fetch(FetchDescriptor<StorageLocation>()).isEmpty else {
            try record(locationsKey, in: context)
            return
        }

        let rows: [(name: String, kind: StorageKind, symbol: String, shelfLife: Int?)] = [
            ("Pantry", .pantry, "cabinet", nil),
            ("Fridge", .fridge, "refrigerator", 7),
            ("Freezer", .freezer, "snowflake", 90),
            ("Spice rack", .spice, "leaf", nil),
            ("Bar", .bar, "wineglass", nil)
        ]
        for (index, row) in rows.enumerated() {
            context.insert(StorageLocation.seeded(
                name: row.name,
                kind: row.kind,
                sortIndex: index,
                symbolName: row.symbol,
                defaultShelfLifeDays: row.shelfLife
            ))
        }
        try record(locationsKey, in: context)
    }

    // MARK: - The store and its aisles

    /// One `Store` with one `StoreSection` per entry of `IngredientCatalog.aisleOrder`, at
    /// that entry's index.
    ///
    /// **The walk order is READ, never copied.** `build_catalogue.py` owns the list, validates
    /// that it names every aisle used and invents none, and emits it into
    /// `ingredients.json` — which is the whole reason the file carries `aisleOrder` at all. A
    /// hand-written list here would be a second copy with no test in this repo able to notice
    /// it drifting, and it had already drifted once: the spec's old table put Bakery fifth and
    /// Frozen twelfth where the script has Bakery second and Frozen last.
    ///
    /// Household and Unsorted are appended after the catalogue's aisles for the things it does
    /// not cover (paper towels; a minted item whose aisle the order does not name). They are
    /// skipped if the catalogue already names an aisle that normalizes to the same key, so a
    /// future `build_catalogue.py` adding "Household" cannot produce two sections one of which
    /// nothing ever resolves to.
    private static func seedSections(in context: ModelContext, catalog: IngredientCatalog) throws {
        guard try !isApplied(sectionsKey, in: context) else { return }

        // SKIPPED WITHOUT A SeedRecord when the catalogue did not load. `aisleOrder` is `[]`
        // only when the decode failed, and seeding anyway would create a store with two
        // sections, record the key as done, and never run again — so every minted `FoodItem`
        // would land in Unsorted forever with nothing on screen explaining why. Skipping
        // leaves the next good launch to seed it, and `StoreHealthView` has the pair it needs
        // to explain the gap: a catalogue `.decodeFailed` plus a missing `sections.v1`.
        let aisles = catalog.aisleOrder
        guard !aisles.isEmpty else { return }

        let existing = try context.fetch(FetchDescriptor<Store>())
        let store: Store
        if let preferred = Store.preferred(from: existing) {
            // Same reasoning as the locations guard, plus: a store that already has a
            // geography was seeded elsewhere, and re-seeding would double every aisle.
            guard preferred.orderedSections.isEmpty else {
                try record(sectionsKey, in: context)
                return
            }
            store = preferred
        } else {
            store = Store(name: "Default", isDefault: true)
            context.insert(store)
        }

        var names = aisles
        var seen = Set(aisles.map { NameNormalizer.matchKey($0) })
        for extra in ["Household", "Unsorted"] {
            let key = NameNormalizer.matchKey(extra)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(extra)
        }

        for (index, name) in names.enumerated() {
            let section = StoreSection.seeded(aisle: name, sortIndex: index, store: store)
            context.insert(section)
            // The to-one side only. `inverse:` is declared on `Store.sections`, so SwiftData
            // maintains the array; writing both ends risks the section appearing twice.
            section.store = store
        }
        try record(sectionsKey, in: context)
    }

    // MARK: - The household

    /// TWO ROWS, because he said "mostly just me plus 1 adult", and **the two is this array's
    /// length and nothing else**.
    ///
    /// Nothing downstream knows the household is two: every scale comes from
    /// `PlannedMeal.portionTotal`, which sums the portions on the attendance rows that exist.
    /// A household of one or of nine needs no code change, which is the requirement behind
    /// "addable and removable at will".
    ///
    /// Both at a full portion, and named for him to rename rather than left blank — an empty
    /// name renders as "Unnamed" in every picker, which reads as a bug rather than as an
    /// invitation.
    private static func seedHousehold(in context: ModelContext) throws {
        guard try !isApplied(householdKey, in: context) else { return }

        guard try context.fetch(FetchDescriptor<Eater>()).isEmpty else {
            try record(householdKey, in: context)
            return
        }

        let roster: [(name: String, shortName: String, colorIndex: Int)] = [
            ("Me", "Me", 0),
            ("Partner", "Pt", 1)
        ]
        for (index, person) in roster.enumerated() {
            context.insert(Eater(
                name: person.name,
                shortName: person.shortName,
                colorIndex: person.colorIndex,
                portionNumerator: 1,
                portionDenominator: 1,
                sortIndex: index
            ))
        }
        try record(householdKey, in: context)
    }

    // MARK: - The gate

    /// The fetch every seed runs first. `SeedRecord.descriptor(forSeedKey:)` owns the
    /// `#Predicate`, with the needle hoisted into a local there — the macro cannot translate
    /// string interpolation, and a second spelling of the same query here is a second place
    /// for that to be got wrong.
    private static func isApplied(_ key: String, in context: ModelContext) throws -> Bool {
        try !context.fetch(SeedRecord.descriptor(forSeedKey: key)).isEmpty
    }

    /// Saved immediately, so a crash between two seeds cannot leave the first one applied and
    /// unrecorded — which is the one state that doubles rows on the next launch.
    private static func record(_ key: String, in context: ModelContext) throws {
        context.insert(SeedRecord(seedKey: key, appVersion: appVersion))
        try context.save()
    }

    /// Recorded with the seed so a row's provenance is readable on a device years later.
    /// Empty rather than "unknown" when the key is absent: this is data, not a label.
    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }
}
