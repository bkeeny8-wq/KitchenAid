import Foundation
import SwiftData

/// One alias HE added. A ROW, never an element of a stored `[String]`.
///
/// This is bucketing correctness, not hygiene. Under CloudKit two devices each appending to a
/// stored array resolve last-writer-wins on the WHOLE array, so one alias is silently lost —
/// and a lost alias means two shopping lines for one purchase. Two rows both survive the
/// merge. `FoodItem.aliasBlob` is a rebuilt index over these rows, not a second copy to
/// append to.
///
/// The SHIPPED synonyms ("scallion" / "green onion" / "spring onion") live in
/// `ingredients.json` and are consulted by `FoodItemResolver` AFTER these. This table is only
/// for the one-tap "same as…" he uses on an unresolved line, so his vocabulary stays his and
/// a catalogue rebuild never overwrites it.
@Model
final class FoodItemAlias {
    var id: UUID = UUID()

    /// What he typed, kept verbatim so the "same as…" row reads back in his words.
    var text: String = ""

    /// `NameNormalizer.matchKey(text)`. This is what goes into the owner's `aliasBlob` and
    /// what a lookup arrives on.
    var matchKey: String = ""

    var createdAt: Date = .now

    /// Owner. Macro lives on `FoodItem.aliases` (`.cascade` — an alias for a deleted item is
    /// nothing).
    var item: FoodItem? = nil

    init(
        id: UUID = UUID(),
        text: String = "",
        matchKey: String = "",
        createdAt: Date = .now,
        item: FoodItem? = nil
    ) {
        self.id = id
        self.text = text
        self.matchKey = matchKey
        self.createdAt = createdAt
        self.item = item
    }
}

extension FoodItemAlias {
    /// The only spelling that cannot leave `text` and `matchKey` describing different words,
    /// which is a divergence nothing downstream can detect: the blob is built from
    /// `matchKey`, and the row he sees is `text`. A factory rather than a convenience
    /// `init`, because nothing here can compile a `@Model` class to find out how the macro
    /// treats one.
    static func make(text: String, item: FoodItem? = nil, createdAt: Date = .now) -> FoodItemAlias {
        FoodItemAlias(
            text: text,
            matchKey: NameNormalizer.matchKey(text),
            createdAt: createdAt,
            item: item
        )
    }

    var displayText: String { text.isEmpty ? matchKey : text }
}
