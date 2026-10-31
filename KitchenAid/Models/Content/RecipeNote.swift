import Foundation

/// One note bullet.
///
/// A list element rather than a paragraph, because the fixture's Notes section is four
/// separate ideas: "the spinach can be made a day ahead" (make-ahead), "squeezing the spinach
/// dry is the key step" (warning), "for a sharper bite, stir in extra horseradish"
/// (variation), "toast the baguette just before serving" (timing). One of them is
/// semantically the make-ahead flag the meal planner wants. Flattening them into a paragraph
/// on import cannot be undone.
struct RecipeNote: Codable, Hashable, Sendable {
    var text: String = ""
    /// Classified on import by a keyword pass. Advisory; nothing branches on it except the
    /// make-ahead call-out and the prep-ahead PDF page.
    var kind: NoteKind = .general

    enum CodingKeys: String, CodingKey { case text, kind }

    init(from decoder: Decoder) throws {
        // A note may be a bare string — which is what `scripts/import_recipe.py` emits,
        // since the bullet text is all it can know — or an object once a kind has been
        // classified. The bare form decodes to `.general`, and the classification pass is
        // what turns the fixture's first bullet into `.makeAhead`.
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            self.text = text
            self.kind = .general
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.kind = c.decodeRawValue(NoteKind.self, forKey: .kind, fallback: .general)
    }

    init(text: String, kind: NoteKind = .general) {
        self.text = text
        self.kind = kind
    }
}
