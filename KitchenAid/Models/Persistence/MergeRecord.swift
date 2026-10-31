import Foundation
import SwiftData

/// An audit row per de-dup merge, so Settings can say "merged 3 duplicates" rather than
/// mutating his data mutely. A merge that happens silently is indistinguishable from data
/// loss — and because `@Attribute(.unique)` is forbidden under CloudKit, merges are a routine
/// part of this schema rather than an emergency.
@Model
final class MergeRecord {
    var id: UUID = UUID()
    var mergedAt: Date = .now

    /// "FoodItem", "RecipeTweak". A string and not an enum: this table outlives any one list
    /// of mergeable types, and a row written by a newer build has to stay readable.
    var entityName: String = ""

    var survivorID: UUID = UUID()
    var survivorName: String = ""

    /// `|`-delimited, both outer pipes present. Admissible as a blob where a stored array is
    /// not, because this is a frozen audit row written once by one writer in one breath:
    /// nothing ever appends to it, so there is no last-writer-wins append to lose.
    var absorbedIDBlob: String = ""
    var absorbedNameBlob: String = ""

    /// How many referrers were repointed — lots, transactions, shopping lines. The number
    /// that tells him the merge moved his history rather than dropping it.
    var repointedCount: Int = 0

    var note: String = ""

    init(
        id: UUID = UUID(),
        mergedAt: Date = .now,
        entityName: String = "",
        survivorID: UUID = UUID(),
        survivorName: String = "",
        absorbedIDBlob: String = "",
        absorbedNameBlob: String = "",
        repointedCount: Int = 0,
        note: String = ""
    ) {
        self.id = id
        self.mergedAt = mergedAt
        self.entityName = entityName
        self.survivorID = survivorID
        self.survivorName = survivorName
        self.absorbedIDBlob = absorbedIDBlob
        self.absorbedNameBlob = absorbedNameBlob
        self.repointedCount = repointedCount
        self.note = note
    }
}

extension MergeRecord {
    /// `|a|b|`, the same shape as `FoodItem.aliasBlob` and `ShoppingListLine.flagsBlob`, so
    /// there is one blob format in this schema rather than three.
    static func encodeBlob(_ values: [String]) -> String {
        let kept = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("|") }
        guard !kept.isEmpty else { return "" }
        return "|" + kept.joined(separator: "|") + "|"
    }

    static func decodeBlob(_ blob: String) -> [String] {
        blob.split(separator: "|").map(String.init)
    }

    var absorbedIDs: [UUID] {
        MergeRecord.decodeBlob(absorbedIDBlob).compactMap { UUID(uuidString: $0) }
    }

    var absorbedNames: [String] { MergeRecord.decodeBlob(absorbedNameBlob) }

    var absorbedCount: Int { MergeRecord.decodeBlob(absorbedIDBlob).count }

    /// What the Settings row reads. Names and not counts where it can, because "merged
    /// Shallot into shallot" is a sentence he can check and "merged 1 duplicate" is not.
    var summary: String {
        let names = absorbedNames.filter { !$0.isEmpty }
        let survivor = survivorName.isEmpty ? "an item" : survivorName
        guard !names.isEmpty else {
            return "Merged \(absorbedCount) duplicate(s) into \(survivor)"
        }
        return "Merged \(names.joined(separator: ", ")) into \(survivor)"
    }

    /// Writes both blobs from the losers in one call, so an id can never be recorded without
    /// its name — the pair is the whole value of the row.
    static func make(
        entityName: String,
        survivorID: UUID,
        survivorName: String,
        absorbed: [(id: UUID, name: String)],
        repointedCount: Int,
        note: String = "",
        mergedAt: Date = .now
    ) -> MergeRecord {
        MergeRecord(
            mergedAt: mergedAt,
            entityName: entityName,
            survivorID: survivorID,
            survivorName: survivorName,
            absorbedIDBlob: encodeBlob(absorbed.map { $0.id.uuidString }),
            absorbedNameBlob: encodeBlob(absorbed.map { $0.name }),
            repointedCount: repointedCount,
            note: note
        )
    }
}
