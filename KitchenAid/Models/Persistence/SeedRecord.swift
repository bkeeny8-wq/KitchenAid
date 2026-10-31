import Foundation
import SwiftData

/// Idempotent seeding without `@Attribute(.unique)`, which CloudKit forbids: fetch by
/// `seedKey` before applying, and apply nothing if a row is already there.
///
/// Covered by the same reconcile pass as `FoodItem`, for the case where two devices seed in
/// the same minute and sync afterwards — then there are two rows for one key, which is
/// harmless for the guard (either one blocks a re-seed) and is tidied later.
@Model
final class SeedRecord {
    var id: UUID = UUID()

    /// "sections.v1", "locations.v1", "household.v1". Versioned in the key itself, so adding
    /// an aisle in a later build is a new seed rather than a migration or a hand-edit.
    var seedKey: String = ""

    var appliedAt: Date = .now
    var appVersion: String = ""

    init(
        id: UUID = UUID(),
        seedKey: String = "",
        appliedAt: Date = .now,
        appVersion: String = ""
    ) {
        self.id = id
        self.seedKey = seedKey
        self.appliedAt = appliedAt
        self.appVersion = appVersion
    }
}

extension SeedRecord {
    /// The guard every seed runs first. The needle is hoisted out of the macro deliberately:
    /// `#Predicate` translates its closure into a `PredicateExpression` tree and
    /// `DefaultStringInterpolation` has no representation there, so an interpolated operand
    /// fails to expand. A captured `let` is an expression the macro can represent.
    static func descriptor(forSeedKey key: String) -> FetchDescriptor<SeedRecord> {
        let needle = key
        var descriptor = FetchDescriptor<SeedRecord>(
            predicate: #Predicate<SeedRecord> { $0.seedKey == needle }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }
}
