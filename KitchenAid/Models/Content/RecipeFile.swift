import Foundation

/// One recipe file. The envelope exists so a future content migration has a version to
/// branch on without re-reading every file to guess its shape.
///
/// It decodes BOTH shapes: `{"schemaVersion": 1, "recipe": {…}}`, and the flat
/// `{"schemaVersion": 1, "id": …, "title": …}` that `scripts/import_recipe.py` emits
/// directly. The flat form is what is actually committed, because it is the importer's own
/// output and a wrapping step that exists only to satisfy a Swift type is a step that will
/// eventually be forgotten. `schemaVersion` is read from the same object either way.
struct RecipeFile: Codable, Sendable {
    var schemaVersion: Int = 1
    var recipe: Recipe = Recipe()

    enum CodingKeys: String, CodingKey { case schemaVersion, recipe }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if let nested = try c.decodeIfPresent(Recipe.self, forKey: .recipe) {
            self.recipe = nested
        } else {
            // No `recipe` key: the whole object IS the recipe. `Recipe.init(from:)` reads
            // the same decoder, so the flat form costs nothing and needs no second type.
            self.recipe = try Recipe(from: decoder)
        }
    }

    init(schemaVersion: Int = 1, recipe: Recipe) {
        self.schemaVersion = schemaVersion
        self.recipe = recipe
    }
}
