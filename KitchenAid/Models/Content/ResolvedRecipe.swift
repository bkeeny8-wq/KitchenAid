import Foundation

/// Bundled content with the overlay applied — what every view actually renders.
///
/// `TweakStore.effectiveRecipe(id:)` builds one by copying the loaded `Recipe` VALUE and
/// writing the overrides into the copy. **The loaded content is never mutated**, so two
/// screens showing the same recipe cannot disagree, and the next launch re-reads the file as
/// written.
///
/// It carries the override sets as well as the result, because the UI has to show which
/// numbers are his: an ingredient row with an override gets an "edited" dot and a "back to as
/// written" action, and the PDF prints the effective value with a footnote.
struct ResolvedRecipe: Identifiable, Sendable {

    /// Overrides already applied.
    var recipe: Recipe
    /// As bundled, for the "as written" comparison.
    var original: Recipe
    var overriddenLineIDs: Set<String> = []
    var overriddenStepIDs: Set<String> = []
    var lastMadeAt: Date? = nil
    var userNotes: String = ""
    var isFavorite: Bool = false

    /// Overrides whose `lineID` or `stepID` no longer exists in the bundled recipe, because
    /// the file was revised. They are REPORTED, not discarded: `TweakSheet` lists them as
    /// "this no longer applies — remove it?" so a lost tweak is visible rather than silent.
    var lapsedOverrides: [LapsedOverride] = []

    struct LapsedOverride: Identifiable, Hashable, Sendable {
        enum Kind: String, Hashable, Sendable { case ingredient, step }

        var id = UUID()
        var kind: Kind
        /// The `lineID` or `stepID` the override was written against.
        var key: String
        /// What it said, so the sheet can show him what he is about to lose.
        var snapshot: String

        init(id: UUID = UUID(), kind: Kind, key: String, snapshot: String = "") {
            self.id = id
            self.kind = kind
            self.key = key
            self.snapshot = snapshot
        }
    }

    /// `original` defaults to `recipe` so the no-tweaks case — which is most recipes, most of
    /// the time — cannot accidentally be built with the two halves swapped.
    init(
        recipe: Recipe,
        original: Recipe? = nil,
        overriddenLineIDs: Set<String> = [],
        overriddenStepIDs: Set<String> = [],
        lastMadeAt: Date? = nil,
        userNotes: String = "",
        isFavorite: Bool = false,
        lapsedOverrides: [LapsedOverride] = []
    ) {
        self.recipe = recipe
        self.original = original ?? recipe
        self.overriddenLineIDs = overriddenLineIDs
        self.overriddenStepIDs = overriddenStepIDs
        self.lastMadeAt = lastMadeAt
        self.userNotes = userNotes
        self.isFavorite = isFavorite
        self.lapsedOverrides = lapsedOverrides
    }

    var hasTweaks: Bool {
        !overriddenLineIDs.isEmpty || !overriddenStepIDs.isEmpty || !userNotes.isEmpty
    }

    func isOverridden(lineID: String) -> Bool { overriddenLineIDs.contains(lineID) }
    func isOverridden(stepID: String) -> Bool { overriddenStepIDs.contains(stepID) }

    /// The line AS BUNDLED, for the "as written: 2 tbsp" caption beside his 1 tbsp.
    func originalLine(id lineID: String) -> IngredientLine? { original.line(id: lineID) }
    func originalStep(id stepID: String) -> RecipeStep? { original.step(id: stepID) }

    // MARK: - Forwarding accessors onto the EFFECTIVE recipe
    //
    // `RecipeGraph.flatten` takes a `ResolvedRecipe` and walks its components, its id and —
    // for sub-recipe expansion — its yield. Without these, those call sites do not compile:
    // `ResolvedRecipe` holds `recipe` and `original` and has none of these members. The
    // document's version omitted `yieldAmount` and `yieldUnitLabel` specifically, and that
    // broke the flattener twice, because sub-recipe expansion divides by the yield and never
    // by a serving count.
    //
    // Forwarding rather than spelling `recipe.recipe.components` at every call site, because
    // `.recipe.recipe` is the kind of line a later reader "simplifies" wrongly.

    var id: String { recipe.id }
    var title: String { recipe.title }
    var subtitle: String { recipe.subtitle }
    var summary: String { recipe.summary }

    var components: [RecipeComponent] { recipe.components }
    var steps: [RecipeStep] { recipe.steps }
    var notes: [RecipeNote] { recipe.notes }
    var tags: [RecipeTag] { recipe.tags }
    var allLines: [IngredientLine] { recipe.allLines }

    var servings: Rational { recipe.servings }
    var yieldAmount: Rational? { recipe.yieldAmount }
    var yieldUnitLabel: String { recipe.yieldUnitLabel }
    var yieldText: String { recipe.yieldText }
    var batchGranularity: BatchGranularity { recipe.batchGranularity }

    var activeMinutes: Int? { recipe.activeMinutes }
    var totalMinutes: Int? { recipe.totalMinutes }
    var timesAreApproximate: Bool { recipe.timesAreApproximate }

    var course: CourseKind { recipe.course }
    var difficulty: Difficulty { recipe.difficulty }
    var cuisine: String { recipe.cuisine }
    var sourceName: String { recipe.sourceName }
    var isArchived: Bool { recipe.isArchived }
    var isReusableComponent: Bool { recipe.isReusableComponent }
    var makeAheadNote: String { recipe.makeAheadNote }
    var makeAheadNotes: [RecipeNote] { recipe.makeAheadNotes }
    var rawText: String { recipe.rawText }

    var hasSingleUnnamedComponent: Bool { recipe.hasSingleUnnamedComponent }
    var referencedRecipeIDs: [String] { recipe.referencedRecipeIDs }

    func component(at index: Int?) -> RecipeComponent? { recipe.component(at: index) }
    func line(id lineID: String) -> IngredientLine? { recipe.line(id: lineID) }
    func step(id stepID: String) -> RecipeStep? { recipe.step(id: stepID) }
    func scaledYieldLabel(at scale: Rational) -> String? { recipe.scaledYieldLabel(at: scale) }
}
