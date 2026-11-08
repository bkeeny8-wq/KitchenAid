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

    /// True when the serving count is not a number the recipe commits to.
    ///
    /// The three compotes state no servings at all; Brandon supplied "approx 4"
    /// and it is recorded in `docs/recipe-overrides.json`. Scaling uses the
    /// value either way — the planner has to divide by something — but the UI
    /// should not render a guess he gave in passing with the same confidence as
    /// "12 crostini (serves 4)", which the document actually claims.
    ///
    /// The decoder also sets this when NOBODY stated a count (see
    /// `servingsStated`), because every "Serves …" label in the app reads this
    /// one flag, and the flag's job is "do not say this confidently".
    var servingsApproximate: Bool = false

    /// False when the document states no serving count at all, and the 4 in
    /// `servingsNumerator` is this decoder's substitution rather than anybody's number.
    ///
    /// Code review 01 item 4: `roast-turkey.json` and `turkey-gravy.json` both carry
    /// `"servings": null`, the decoder's `?? 4` turned that into a recipe serving four, and
    /// the meal planner divided by the invented 4 with nothing anywhere saying it was
    /// invented. `servings` still has to come back positive — it is a divisor — so the
    /// honesty lives here instead: `MealScaling` raises a note and names the substitution in
    /// the provenance sentence on every shopping line the dish produces.
    ///
    /// Default TRUE, so a `Recipe(id:title:)` built in code and every file that does state a
    /// count keep meaning what they meant: a recipe that says "serves 4" said it.
    var servingsStated: Bool = true

    // MARK: - Selected by weight, not scaled by portions

    /// The weight in POUNDS the document's quantities were written for, on a recipe that is
    /// selected by weight rather than scaled by attendance. `nil` on every other recipe,
    /// which today is all of them but the roast turkey.
    ///
    /// Nobody roasts 1.4 turkeys. You buy a bigger bird and read the longer time off the
    /// chart, so for this kind of recipe attendance does not set the scale at all — the
    /// chosen weight against this basis does (`MealRecipe.chosenWeightPounds`, derived in
    /// `MealScaling`). Every other dish in the meal, the gravy and the sides, keeps scaling
    /// by attendance exactly as before.
    ///
    /// The document states no basis any more than it states a serving count, so this arrives
    /// as an OVERRIDE from `docs/recipe-overrides.json`: Brandon, 2026-11-08, "the turkey was
    /// for a roughly 14lb turkey", then "yes use the weight chart". It is emphatically NOT a
    /// serving count and does not touch `servings` or `servingsStated` — inventing a portion
    /// count out of a weight is the guess that file exists to avoid.
    ///
    /// A bare JSON number decodes, exactly as `minutesPerPound` does: the override writes
    /// `"basisWeightPounds": 14` and `Rational`'s hand-written decoder takes a single value.
    /// Exact, like every other quantity here: 18 lb against this is 9/7, not 1.2857.
    var basisWeightPounds: Rational? = nil

    // MARK: - Timing that is a rate, not a duration

    /// Minutes per pound, where the recipe times by weight instead of by the
    /// clock. The roast turkey is "350 F, 13 minutes per pound" and has no
    /// total time at all, because a 10 lb bird and a 24 lb bird share the
    /// recipe and nothing else.
    ///
    /// When this is set, a missing `totalMinutes` is not an omission — it is
    /// the correct answer, and the importer stops warning about it.
    var minutesPerPound: Rational? = nil

    /// Oven temperature in Fahrenheit, where the recipe states one up front.
    var ovenTempF: Int? = nil

    /// Lookup tables the document prints. See `RecipeTable` for why these stay
    /// as strings.
    var tables: [RecipeTable] = []

    /// What the importer could not work out about this recipe, in its own words.
    ///
    /// Seven of these exist across the eight bundled files and every one is
    /// true: the compotes state no yield, the turkey no serving count, and four
    /// of the gravy's and turkey's ingredient names are column labels ("Fat",
    /// "Stock", "Pan base") that match nothing in the catalogue and so will
    /// never aggregate or meet the pantry.
    ///
    /// They were being dropped on decode, because this property did not exist
    /// and `check_swift.py` had `warnings` in its ignore list as build
    /// provenance. That was wrong: a warning about a recipe is the most useful
    /// thing the app can tell Brandon after he adds one, since his loop is
    /// author, import, commit, rebuild, with no console anywhere near the
    /// phone that shows the result.
    var warnings: [String] = []
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
        case servingsNumerator, servingsDenominator, servingsApproximate, servingsStated
        case basisWeightPounds
        case minutesPerPound, ovenTempF, tables, warnings
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
        //
        // The third branch is code review 01 item 4. `decodeIfPresent` returns nil for a JSON
        // null exactly as it does for an absent key, so the turkey's `"servings": null` fell
        // through the old `?? 4` and became a recipe serving four — a number no document and
        // no person ever gave, indistinguishable downstream from the fixture's stated
        // "(serves 4)". The 4 is still substituted, because the planner has to divide by
        // something; what changes is that `servingsStated` records that nobody chose it.
        var stated = true
        if let whole = try importer.decodeIfPresent(Int.self, forKey: .servings) {
            self.servingsNumerator = whole
            self.servingsDenominator = 1
        } else if let numerator = try c.decodeIfPresent(Int.self, forKey: .servingsNumerator) {
            self.servingsNumerator = numerator
            self.servingsDenominator = try c.decodeIfPresent(Int.self, forKey: .servingsDenominator) ?? 1
        } else {
            stated = false
            self.servingsNumerator = 4
            self.servingsDenominator = 1
        }
        // An explicit key beats what key presence implies, so a round trip survives: the
        // synthesized encoder writes `servingsNumerator: 4` for the turkey, which on the way
        // back in would otherwise read as a count the file states.
        self.servingsStated = try c.decodeIfPresent(Bool.self, forKey: .servingsStated) ?? stated
        // SINGLE-MEANING, and the `|| !servingsStated` that was briefly here is gone.
        //
        // "about 4" means a number HE GAVE IN PASSING -- "they serve approx 4", the three
        // compotes. Folding the unstated case into it made the turkey print "Serves about
        // 4", character for character what the compotes print, and attributing an
        // approximate serving count to a document that has none is a claim, not a hedge.
        // It also collapsed the one distinction this flag's own doc comment exists to
        // preserve, and `docs/recipe-overrides.json`'s turkey entry says the opposite in
        // as many words: the count stays UNSTATED.
        //
        // The third state is the third state. `servesLabel(scale:)` renders it.
        self.servingsApproximate =
            try c.decodeIfPresent(Bool.self, forKey: .servingsApproximate) ?? false
        // `"basisWeightPounds": 14`, written by the override pass in
        // `scripts/import_recipe.py`. Same single-value form as `minutesPerPound` below.
        self.basisWeightPounds = try c.decodeIfPresent(Rational.self, forKey: .basisWeightPounds)
        self.minutesPerPound = try c.decodeIfPresent(Rational.self, forKey: .minutesPerPound)
        self.ovenTempF = try c.decodeIfPresent(Int.self, forKey: .ovenTempF)
        self.tables = try c.decodeIfPresent([RecipeTable].self, forKey: .tables) ?? []
        self.warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []

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
    /// The ONE wording of the serving count, in all three of its states.
    ///
    /// Four places spelled this rule out independently -- the Today subtitle, the add-meal
    /// row, the recipe screen's metric and the PDF's fact line -- and all four read
    /// `servingsApproximate` alone, so all four printed a count nobody stated as one he
    /// had estimated. Four spellings of one rule is four things that can disagree, and the
    /// printed sheet disagreeing with the screen is the artefact nobody can debug.
    ///
    /// Three states, not two:
    /// - stated:        "Serves 4"        -- the document claims it
    /// - approximate:   "Serves about 4"  -- he gave it in passing
    /// - not stated:    no number at all  -- nobody gave it
    ///
    /// The third prints NO number on purpose. `servings` substitutes 4 so the planner has
    /// something to divide by, but "Serves 4 (assumed)" still leads with a figure nobody
    /// chose, and for the roast turkey it is not even the divisor any more -- a
    /// weight-driven recipe scales by the bird, so the 4 reaches nothing a cook reads.
    func servesLabel(scale: Rational = .one) -> String {
        guard let number = servingsNumberText(scale: scale) else {
            return Self.servingsNotStatedText
        }
        return "Serves \(number)"
    }

    /// Just the figure, for a label that supplies its own "Serves". nil in the third state.
    func servingsNumberText(scale: Rational = .one) -> String? {
        guard servingsStated else { return nil }
        let n = (servings * scale).humanDescription
        return servingsApproximate ? "about \(n)" : n
    }

    /// Centralised so the screen, the sheet and the printed page cannot word it three ways.
    static let servingsNotStatedText = "Serving count not stated"

    /// The scaling divisor. Guaranteed positive: a recipe whose servings were never set must
    /// not make `scale` explode or vanish.
    ///
    /// The substitution is invisible through this accessor, which is the whole reason
    /// `servingsStated` is stored: read that before printing this number or dividing by it.
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

// MARK: - The weight chart
//
// A whole roast bird is bought, not scaled: the document prints eight rows of weight
// against total, covered and uncovered time, and the cook's input is which row he is
// holding. These accessors are what a picker shows and what `MealScaling` divides by; they
// read the table the importer already parsed and parse nothing a second time.

extension Recipe {

    /// The pounds a weight cell names: "14 lb" → 14.
    ///
    /// The parse rule is `RecipeTable.row(matchingFirstColumn:)`'s, on purpose and not by
    /// coincidence: that method finds a row by the LEADING NUMBER of its first cell, so a
    /// second parser with its own idea of what "14 lb" means is a parser that can disagree
    /// with the lookup the Cook screen already uses. It therefore stops at the first
    /// non-digit exactly as that one does, which also means "14 1/2 lb" reads as 14 — the
    /// shipped chart is whole pounds, and one rule both places share beats two that differ.
    static func pounds(fromWeightCell cell: String) -> Rational? {
        let digits = cell.trimmingCharacters(in: .whitespaces).lowercased()
            .prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty else { return nil }
        let text = String(digits)
        // "14": exact, and the only path the shipped chart takes.
        if let exact = Rational(string: text), exact > .zero { return exact }
        // "14.5": `Rational(string:)` reads no decimals, and `init(approximating:)` is
        // explicitly the boundary parser for them. 14.5 comes back as exactly 29/2, so the
        // scale it feeds is still an exact rational — nothing downstream rounds.
        guard let value = Double(text), value > 0 else { return nil }
        return Rational(approximating: value, maxDenominator: 16)
    }

    /// The weight chart among `tables`, if the document prints one.
    ///
    /// Matched on the first column's HEADER ("Turkey weight") AND at least one row whose
    /// first cell parses as a weight. Both halves are needed: a table that merely mentions
    /// weight in a later column, or one whose rows did not survive the import, must not be
    /// mistaken for a chart you can pick a bird off.
    var weightTable: RecipeTable? {
        tables.first { table in
            guard (table.headers.first ?? "").lowercased().contains("weight") else {
                return false
            }
            return table.rows.contains { Recipe.pounds(fromWeightCell: $0.first ?? "") != nil }
        }
    }

    /// The weights the chart offers, in document order: 10, 12, 14 … 24 for the turkey.
    ///
    /// What a picker lists. `basisWeightPounds` need not be one of them and a chosen weight
    /// need not either — `MealScaling` divides whatever weight is stored by the basis — but
    /// offering the document's own rows is what keeps the timing lookup honest.
    var selectableWeightsPounds: [Rational] {
        guard let table = weightTable else { return [] }
        return table.rows.compactMap { Recipe.pounds(fromWeightCell: $0.first ?? "") }
    }

    /// True only when BOTH halves are present: a basis weight to scale against and a chart
    /// to pick a weight off.
    ///
    /// Half-enabling this is the failure mode worth naming. A basis with no chart leaves the
    /// cook no weight to choose and no times to read; a chart with no basis leaves the
    /// arithmetic nothing to divide by. Either way the dish must fall back to the ordinary
    /// serving-count path rather than to a weight-driven screen that cannot work.
    var isWeightDriven: Bool {
        guard let basis = basisWeightPounds, basis > .zero else { return false }
        return !selectableWeightsPounds.isEmpty
    }

    /// The chart row for a chosen weight, raw cells, or `nil` when the chart has no row for
    /// it. `RecipeTable.labelled(_:)` pairs it with the headers, which is how the three
    /// screens that already draw this table render a row.
    ///
    /// Compared NUMERICALLY rather than through `row(matchingFirstColumn:)`, whose
    /// string-prefix fallback would let a 2 lb weight read 20 lb's times. The cell parse is
    /// still the shared one above.
    func weightRow(forPounds pounds: Rational) -> [String]? {
        guard let table = weightTable else { return nil }
        return table.rows.first { Recipe.pounds(fromWeightCell: $0.first ?? "") == pounds }
    }
}
