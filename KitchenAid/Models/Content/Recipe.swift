import Foundation

/// IMMUTABLE BUNDLED CONTENT. A value type, not a `@Model`.
///
/// Brandon writes a recipe in conversation, edits it, and the PDF is dropped into a Claude
/// Code session where `scripts/import_recipe.py` parses it and the JSON is committed to
/// `KitchenAid/Resources/Recipes/`. There is no authoring UI and there are no recipe rows
/// in the store. Everything he does to a recipe afterwards is a `RecipeTweak` overlay
/// keyed by `id` — the same split CFAL3 uses between `LOS` content and `LOSStudyStatus`.
///
/// ORDER IS FREE HERE. A JSON array is ordered, so components, lines, steps and notes need
/// no `sortIndex` — which is the one genuine simplification this split buys, since the
/// SwiftData side has to carry `sortIndex` on every ordered child precisely because a
/// to-many relationship does not preserve order.
struct Recipe: Codable, Identifiable, Hashable, Sendable {

    /// The stable id, and the file name: the fixture's
    /// `ny-strip-crostini-with-creamed-horseradish-spinach.json` holds
    /// `"ny-strip-crostini-with-creamed-horseradish-spinach"`. The importer assigns it as
    /// `slug(title)` — the FULL title, not an abbreviation, because an abbreviation is a
    /// second thing to keep in sync by hand and nothing reads the id aloud.
    ///
    /// A SLUG, not a UUID — the id is what every `MealRecipe`, `RecipeTweak` and
    /// `ShoppingListSource` stores, so it has to be readable in a diff and proofreadable by
    /// a human. **Once published, an id is never changed**: changing it dangles every row
    /// that references it.
    var id: String = ""

    var title: String = ""
    var subtitle: String = ""
    var summary: String = ""

    // MARK: Yields — TWO independent numbers, and conflating them is the bug
    //
    // The fixture says "Makes: 12 crostini (serves 4)". Twelve is a produced-unit count;
    // four is a serving count; neither is derivable from the other. A single yield field
    // makes meal-plan scale = portions / 12, so planning this recipe for four people shops
    // for one third of every ingredient — and no zero-yield warning fires, because the
    // yield is not zero.
    //
    // `servings` is the ONLY value scaling divides by. `yieldAmount` is display, and it
    // scales alongside so six eaters reads "18 crostini".
    //
    // Stored as a numerator/denominator pair because a recipe can serve 2 1/2. The importer
    // writes a whole number as `"servings": 4`, which the decoder below accepts into the
    // pair.
    var servingsNumerator: Int = 4
    var servingsDenominator: Int = 1

    /// True when the serving count is a stated approximation rather than a
    /// number the recipe commits to.
    ///
    /// The three compotes state no servings at all; Brandon supplied "approx 4"
    /// and it is recorded in `docs/recipe-overrides.json`. Scaling uses the
    /// value either way — the planner has to divide by something — but the UI
    /// should not render a guess he gave in passing with the same confidence as
    /// "12 crostini (serves 4)", which the document actually claims.
    var servingsApproximate: Bool = false
    var yieldAmount: Rational? = nil
    var yieldUnitLabel: String = ""
    /// Verbatim, e.g. "12 crostini (serves 4)". Kept so a reparse is always possible.
    var yieldText: String = ""

    // MARK: Times — optional, never 0
    var activeMinutes: Int? = nil
    var totalMinutes: Int? = nil
    /// Both fixture times are prefixed "About", so the UI must not imply precision.
    var timesAreApproximate: Bool = true

    /// Continuous / halfBatches / wholeBatches. You cannot bake 1.4 loaves, and that is a
    /// property of the recipe, not of any one line.
    var batchGranularity: BatchGranularity = .continuous

    var course: CourseKind = .main
    var difficulty: Difficulty = .medium
    var cuisine: String = ""
    var sourceName: String = ""

    /// Hidden from the library but still resolvable by id. **This is how a recipe is
    /// retired** — deleting the file dangles every row that references it, and there is no
    /// cascade that can exist to clean them up.
    var isArchived: Bool = false
    /// A sauce or a stock: offered in the sub-recipe picker, de-emphasised in the library.
    var isReusableComponent: Bool = false

    /// Pulled out of the note bullets by the importer so the planner can surface it without
    /// re-reading prose. The note itself is NOT removed from `notes`.
    var makeAheadNote: String = ""

    /// The `pdftotext -layout` text this was parsed from, committed with it. Over years the
    /// importer improves, and a re-parse of 400 stored raw documents is a feature. It is
    /// also the only honest answer when a quantity on a shopping list looks wrong.
    var rawText: String = ""

    var addedAt: Date? = nil

    var tags: [RecipeTag] = []
    /// Ingredient GROUPS. They own lines, never steps.
    var components: [RecipeComponent] = []
    /// The method, FLAT and ordered across the whole dish.
    ///
    /// This is the single most-rebroken decision in the project. The fixture groups
    /// ingredients three ways but has ONE numbered 1–8 instruction list that moves freely
    /// between the groups: season the steak (1), toast the baguette (2), sear (3), wilt the
    /// spinach (5), assemble both (8). With steps nested under components the only
    /// representable method is all-steak-then-all-crostini, and the document's actual method
    /// cannot be stored. A component is NOT a self-contained mini-recipe.
    var steps: [RecipeStep] = []
    /// An ordered list, not a paragraph. The fixture's Notes section is four distinct
    /// ideas — make-ahead, key-step warning, variation, timing tip. Flattening them at
    /// import cannot be undone.
    var notes: [RecipeNote] = []

    /// STRICTLY one-to-one with the stored properties above, and it stays that way.
    ///
    /// Review 03 finding 1: the design document put the importer's alternate spellings in
    /// here as extra cases. Swift validates the DERIVED `Codable` conformance against the
    /// stored properties, so a case matching no property fails the derivation outright with
    /// "CodingKey case 'servings' does not match any stored properties" — and `servings` is
    /// a computed property in the extension below. The alternates live in `ImporterKeys`
    /// instead, read through their own container, which keeps `encode(to:)` synthesized.
    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, summary
        case servingsNumerator, servingsDenominator, servingsApproximate
        case yieldAmount, yieldUnitLabel, yieldText
        case activeMinutes, totalMinutes, timesAreApproximate
        case batchGranularity, course, difficulty, cuisine, sourceName
        case isArchived, isReusableComponent, makeAheadNote, rawText, addedAt
        case tags, components, steps, notes
    }

    /// `scripts/import_recipe.py` is the only author of these files, so where its key names
    /// differ from a property name the DECODER gives way, not the script — it is the one
    /// with a test that runs.
    ///
    /// `warnings`, `aggregatesWithinRecipe` and `schemaVersion` are also in the importer's
    /// output and are deliberately not read here: the first two are parse-time advice to
    /// whoever committed the file, and `schemaVersion` belongs to `RecipeFile`.
    private enum ImporterKeys: String, CodingKey {
        /// A single whole number, where the canonical form is the numerator/denominator pair.
        case servings
    }

    init(from decoder: Decoder) throws {
        // Swift's synthesized `init(from:)` does NOT fall back to a property's default when
        // a key is absent — it throws. These files are hand-authored and will grow keys over
        // the years, so every optional field is `decodeIfPresent(…) ?? default`. A recipe
        // written last year must keep decoding after a field is added.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let importer = try decoder.container(keyedBy: ImporterKeys.self)

        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""

        // The importer's `"servings": 4` wins when present; the explicit pair is the
        // hand-authored form for a recipe that serves 2 1/2.
        if let whole = try importer.decodeIfPresent(Int.self, forKey: .servings) {
            self.servingsNumerator = whole
            self.servingsDenominator = 1
        } else {
            self.servingsNumerator = try c.decodeIfPresent(Int.self, forKey: .servingsNumerator) ?? 4
            self.servingsDenominator = try c.decodeIfPresent(Int.self, forKey: .servingsDenominator) ?? 1
        }
        self.servingsApproximate =
            try c.decodeIfPresent(Bool.self, forKey: .servingsApproximate) ?? false

        self.yieldAmount = try c.decodeIfPresent(Rational.self, forKey: .yieldAmount)
        self.yieldUnitLabel = try c.decodeIfPresent(String.self, forKey: .yieldUnitLabel) ?? ""
        self.yieldText = try c.decodeIfPresent(String.self, forKey: .yieldText) ?? ""

        self.activeMinutes = try c.decodeIfPresent(Int.self, forKey: .activeMinutes)
        self.totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes)
        self.timesAreApproximate = try c.decodeIfPresent(Bool.self, forKey: .timesAreApproximate) ?? true

        self.batchGranularity = c.decodeRawValue(BatchGranularity.self, forKey: .batchGranularity, fallback: .continuous)
        self.course = c.decodeRawValue(CourseKind.self, forKey: .course, fallback: .main)
        self.difficulty = c.decodeRawValue(Difficulty.self, forKey: .difficulty, fallback: .medium)
        self.cuisine = try c.decodeIfPresent(String.self, forKey: .cuisine) ?? ""
        self.sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""

        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.isReusableComponent = try c.decodeIfPresent(Bool.self, forKey: .isReusableComponent) ?? false
        self.makeAheadNote = try c.decodeIfPresent(String.self, forKey: .makeAheadNote) ?? ""
        self.rawText = try c.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        self.addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)

        self.tags = try c.decodeIfPresent([RecipeTag].self, forKey: .tags) ?? []
        self.components = try c.decodeIfPresent([RecipeComponent].self, forKey: .components) ?? []
        self.steps = try c.decodeIfPresent([RecipeStep].self, forKey: .steps) ?? []
        self.notes = try c.decodeIfPresent([RecipeNote].self, forKey: .notes) ?? []
    }

    init(id: String = "", title: String = "") {
        self.id = id
        self.title = title
    }
}

extension Recipe {
    /// The scaling divisor. Guaranteed positive: a recipe whose servings were never set must
    /// not make `scale` explode or vanish.
    var servings: Rational {
        let r = Rational(servingsNumerator, max(1, servingsDenominator))
        return r > .zero ? r : .one
    }

    /// True when the recipe has exactly one unnamed ingredient group, which the UI renders
    /// with no header at all so a three-ingredient vinaigrette never shows the word "group".
    var hasSingleUnnamedComponent: Bool {
        components.count == 1 && components[0].title.isEmpty
    }

    var allLines: [IngredientLine] { components.flatMap(\.lines) }

    func component(at index: Int?) -> RecipeComponent? {
        guard let index, components.indices.contains(index) else { return nil }
        return components[index]
    }

    func line(id lineID: String) -> IngredientLine? {
        allLines.first { $0.lineID == lineID }
    }

    func step(id stepID: String) -> RecipeStep? {
        steps.first { $0.stepID == stepID }
    }

    /// Every other recipe this one reaches directly, for `RecipeLoader`'s reference check.
    var referencedRecipeIDs: [String] {
        components.compactMap(\.sourceRecipeID) + allLines.compactMap(\.subRecipeID)
    }

    /// The display yield at a given scale: 12 crostini × 3/2 reads "18 crostini".
    ///
    /// `humanDescription` and not the exact fraction: this is a label, and `Rational`'s
    /// exact rendering is what produced the "23 1111/1135 tsp" note review 03 found.
    func scaledYieldLabel(at scale: Rational) -> String? {
        guard let q = yieldAmount, !yieldUnitLabel.isEmpty else { return nil }
        return "\((q * scale).humanDescription) \(yieldUnitLabel)"
    }

    var makeAheadNotes: [RecipeNote] { notes.filter { $0.kind == .makeAhead } }

    /// `ContentDiagnostic.emptyRecipe`: a file that parsed but holds no dish.
    var isEmpty: Bool { components.isEmpty && steps.isEmpty }
}
