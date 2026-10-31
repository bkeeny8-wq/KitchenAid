import Foundation

/// An ingredient GROUP — "Crostini and steak", "Creamed horseradish spinach", "To finish".
/// It owns ordered ingredient lines and NOTHING ELSE.
///
/// It deliberately does not own steps. See the long comment on `Recipe.steps`.
struct RecipeComponent: Codable, Hashable, Sendable {
    /// "" for a single-group recipe, which the UI then renders with no header.
    var title: String = ""
    var note: String = ""
    var kind: ComponentKind = .other
    var isOptional: Bool = false

    /// Set when this group IS another bundled recipe — "half a batch of the chimichurri".
    /// Its lines are read through `RecipeLoader` rather than duplicated here.
    ///
    /// An id that no longer resolves makes this an orphaned reference: the flattener emits
    /// a diagnostic and contributes nothing, and the UI renders "Chimichurri — recipe not
    /// bundled" rather than silently dropping a third of a dish.
    var sourceRecipeID: String? = nil
    var sourceScale: Rational = .one

    var makeAheadNote: String = ""
    var lines: [IngredientLine] = []

    /// One-to-one with the stored properties; the importer's `name` is in `ImporterKeys`.
    /// Review 03 finding 1 — see the note on `Recipe.CodingKeys`.
    enum CodingKeys: String, CodingKey {
        case title, note, kind, isOptional, sourceRecipeID, sourceScale, makeAheadNote, lines
    }

    private enum ImporterKeys: String, CodingKey {
        /// The importer's spelling for `title`.
        case name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let importer = try decoder.container(keyedBy: ImporterKeys.self)

        self.title = try c.decodeIfPresent(String.self, forKey: .title)
            ?? importer.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.kind = c.decodeRawValue(ComponentKind.self, forKey: .kind, fallback: .other)
        self.isOptional = try c.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
        self.sourceRecipeID = try c.decodeIfPresent(String.self, forKey: .sourceRecipeID)
        self.sourceScale = try c.decodeIfPresent(Rational.self, forKey: .sourceScale) ?? .one
        self.makeAheadNote = try c.decodeIfPresent(String.self, forKey: .makeAheadNote) ?? ""
        self.lines = try c.decodeIfPresent([IngredientLine].self, forKey: .lines) ?? []
    }

    init(title: String = "", kind: ComponentKind = .other, lines: [IngredientLine] = []) {
        self.title = title
        self.kind = kind
        self.lines = lines
    }

    /// A reference-only group: it names another recipe and carries no lines of its own.
    var isReference: Bool { sourceRecipeID != nil && lines.isEmpty }
}
