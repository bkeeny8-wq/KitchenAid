import Foundation

/// One step of the method. FLAT and recipe-ordered; `componentIndex` is an optional tag into
/// `Recipe.components`, used by the cook-mode sticky header and the per-step group pill.
/// Nothing reaches a step through a component, so there is no "which parent wins" question
/// for a renderer, an exporter or a cook screen to get wrong.
struct RecipeStep: Codable, Identifiable, Hashable, Sendable {

    /// Stable, authored, and the `StepOverride` join key. **Slug-of-title plus an occurrence
    /// number**, exactly as `scripts/import_recipe.py` assigns it: `"sear-the-steak-1"`,
    /// `"rest-the-steak-1"`.
    ///
    /// Name-based for the same reason `lineID` is, and emphatically NOT `"step-3"`: a
    /// positional id re-points "step 6 should say 3 minutes" onto whatever step 6 became when
    /// a step was inserted above it. A title-based id lapses instead, visibly, which is when
    /// it should. `number` still carries the printed 1–8 ordering; the occurrence suffix
    /// exists for the rare method that titles two steps the same.
    var stepID: String = ""
    var id: String { stepID }
    var number: Int = 0

    /// Every step in the fixture is "Title (duration). Body" — "Season the steak (30 min).
    /// Pat the steak dry and season all over with…". Split so cook mode can show the title
    /// big and the body small, and so the duration is a timer rather than prose.
    var title: String = ""
    /// Verbatim, including any temperatures. Never rewritten, so a later extraction pass
    /// needs no re-import.
    var body: String = ""

    /// Equal when the document gives a single value, both nil when it gives none. NOT
    /// `Int = 0`: the fixture's step 7 ("Slice the steak") and step 8 ("Assemble") have no
    /// duration at all, and step 3's is the RANGE "7 to 8 min".
    var minMinutes: Int? = nil
    var maxMinutes: Int? = nil

    /// Step 2 has an oven temperature (400F) and step 3 an internal target (125F). One field
    /// cannot hold both, and `0` is a real temperature.
    var ovenTemperatureF: Int? = nil
    var targetInternalTemperatureF: Int? = nil

    /// "Let it sit at room temperature" — nothing to do but wait. Drives the prep-ahead PDF
    /// page and the planner's `.prep` suggestion.
    var isPassiveRest: Bool = false
    var timerLabel: String = ""
    var componentIndex: Int? = nil

    /// One-to-one with the stored properties; the importer's `order` is in `ImporterKeys`.
    /// Review 03 finding 1 — see the note on `Recipe.CodingKeys`.
    enum CodingKeys: String, CodingKey {
        case stepID, number, title, body, minMinutes, maxMinutes
        case ovenTemperatureF, targetInternalTemperatureF, isPassiveRest, timerLabel
        case componentIndex
    }

    private enum ImporterKeys: String, CodingKey {
        /// The importer's spelling for `number`.
        case order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let importer = try decoder.container(keyedBy: ImporterKeys.self)

        self.stepID = try c.decode(String.self, forKey: .stepID)
        self.number = try c.decodeIfPresent(Int.self, forKey: .number)
            ?? importer.decodeIfPresent(Int.self, forKey: .order)
            ?? 0
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        self.minMinutes = try c.decodeIfPresent(Int.self, forKey: .minMinutes)
        self.maxMinutes = try c.decodeIfPresent(Int.self, forKey: .maxMinutes)
        self.ovenTemperatureF = try c.decodeIfPresent(Int.self, forKey: .ovenTemperatureF)
        self.targetInternalTemperatureF = try c.decodeIfPresent(
            Int.self, forKey: .targetInternalTemperatureF
        )
        self.isPassiveRest = try c.decodeIfPresent(Bool.self, forKey: .isPassiveRest) ?? false
        self.timerLabel = try c.decodeIfPresent(String.self, forKey: .timerLabel) ?? ""
        self.componentIndex = try c.decodeIfPresent(Int.self, forKey: .componentIndex)
    }

    init(stepID: String, number: Int, title: String = "", body: String = "") {
        self.stepID = stepID
        self.number = number
        self.title = title
        self.body = body
    }
}

extension RecipeStep {
    /// "30 min", "7-8 min", or nil.
    var durationText: String? {
        switch (minMinutes, maxMinutes) {
        case let (lo?, hi?) where lo != hi: return "\(lo)-\(hi) min"
        case let (lo?, _): return "\(lo) min"
        case let (_, hi?): return "\(hi) min"
        default: return nil
        }
    }

    /// Cook mode times the longer end, so a timer never fires early on a range.
    var timerSeconds: Int? {
        guard let m = maxMinutes ?? minMinutes else { return nil }
        return m * 60
    }
}
