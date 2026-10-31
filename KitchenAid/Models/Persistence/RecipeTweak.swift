import Foundation
import SwiftData

/// THE OVERLAY. One row per recipe id he has actually touched.
///
/// This is `LOSStudyStatus` for recipes: bundled content is immutable, so everything the
/// user does to a recipe lives here, keyed by the content's stable string id. **A tweak
/// never mutates bundled content** — the resolver applies the overlay to a COPY of the
/// decoded value and hands that to the views, so the next launch re-reads the file exactly
/// as it was authored.
///
/// Rows are created lazily. A recipe he has never favourited, never made and never adjusted
/// has no row at all, so the store stays proportional to what he has done rather than to
/// what is bundled.
///
/// `recipeID` is deliberately not unique — CloudKit-backed stores reject
/// `@Attribute(.unique)`, so two offline devices can both create a tweak for the same
/// recipe. The accessor fetches with `fetchLimit` 1 ordered by `createdAt` then
/// `id.uuidString` so both devices pick the same survivor, and maintenance folds the
/// duplicates: notes concatenated once with a separator, `lastMadeAt` taking the later
/// date, override rows re-parented.
@Model
final class RecipeTweak {
    var id: UUID = UUID()

    /// The content id, i.e. the `id` field of a `Resources/Recipes/*.json` file.
    ///
    /// **This is allowed to dangle, and no schema can stop it.** A delete rule only reaches
    /// rows, and the thing on the other end of this string is a bundled file, not a row —
    /// so removing a recipe from the bundle leaves every tweak, meal and transaction
    /// holding its id pointing at nothing, with nothing for SwiftData to cascade to. That
    /// is why `recipeTitleSnapshot` exists and why the cheap alternative is always
    /// `"archived": true` in the JSON: an archived recipe is hidden from the library and
    /// its id still resolves. Archive, do not delete.
    var recipeID: String = ""

    /// Written when the row is created, so a recipe whose file is gone can still be NAMED
    /// — "NY Strip Crostini (recipe no longer bundled)" rather than a blank row he cannot
    /// identify well enough to decide whether to forget it.
    var recipeTitleSnapshot: String = ""

    /// **The whole of cooking history.** No log rows, no ratings, no durations, no
    /// per-cook notes — he was offered a journal and declined it. `nil` means never made,
    /// which both the library and the Today screen surface.
    var lastMadeAt: Date? = nil

    /// His notes on this recipe: "too much horseradish, 1 tbsp next time".
    ///
    /// One free-text field he rewrites, deliberately not a list of dated entries: a
    /// per-note row carrying a date IS a cooking journal, which is the thing he said no to.
    /// The cost is that it is last-writer-wins across devices, and that is accepted.
    var notes: String = ""

    /// Belongs on the overlay rather than in the JSON, because it is a fact about him and
    /// not about the recipe.
    var isFavorite: Bool = false

    var createdAt: Date = .now
    var updatedAt: Date = .now

    @Relationship(deleteRule: .cascade, inverse: \IngredientOverride.tweak)
    var ingredientOverrides: [IngredientOverride]? = []

    @Relationship(deleteRule: .cascade, inverse: \StepOverride.tweak)
    var stepOverrides: [StepOverride]? = []

    init(
        id: UUID = UUID(),
        recipeID: String = "",
        recipeTitleSnapshot: String = "",
        lastMadeAt: Date? = nil,
        notes: String = "",
        isFavorite: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.recipeID = recipeID
        self.recipeTitleSnapshot = recipeTitleSnapshot
        self.lastMadeAt = lastMadeAt
        self.notes = notes
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Reading the overlay

extension RecipeTweak {
    /// Sorted by key, not by recipe position: the overlay has no idea where a line sits in
    /// the document, and inventing an order here would compete with the one the recipe
    /// already defines. Views walk the recipe and ask for the override by id; this exists
    /// for the diagnostic and lapse screens, where a stable order is all that is needed.
    var orderedIngredientOverrides: [IngredientOverride] {
        (ingredientOverrides ?? []).sorted { $0.lineID < $1.lineID }
    }

    var orderedStepOverrides: [StepOverride] {
        (stepOverrides ?? []).sorted { $0.stepID < $1.stepID }
    }

    func ingredientOverride(lineID: String) -> IngredientOverride? {
        (ingredientOverrides ?? []).first { $0.lineID == lineID }
    }

    func stepOverride(stepID: String) -> StepOverride? {
        (stepOverrides ?? []).first { $0.stepID == stepID }
    }

    /// True when this row is carrying nothing and can be dropped, so "undo my tweak"
    /// leaves no residue.
    var isEmpty: Bool {
        lastMadeAt == nil && notes.isEmpty && !isFavorite
            && (ingredientOverrides ?? []).isEmpty && (stepOverrides ?? []).isEmpty
    }

    /// Every mutation goes through this rather than assigning `updatedAt` at each call
    /// site, because the one that forgets is invisible until duplicate-folding picks the
    /// wrong survivor.
    func touch(at date: Date = .now) {
        updatedAt = date
    }
}

// MARK: - The content this overlay points at

/// Whether the bundled recipe behind a `recipeID` can still be found, and in what state.
///
/// Three cases and not two, because the middle one is the whole point of the archive
/// mechanism: an archived recipe is NOT missing — its id resolves, its lines resolve, every
/// override still applies — it is merely hidden from the library. Collapsing `.archived`
/// into `.missing` would make "tidy up my library" look identical to "your tweaks now
/// point at nothing".
enum RecipeContentStatus: String, Codable, CaseIterable, Sendable {
    /// The file is bundled and visible.
    case present
    /// Bundled with `"archived": true` — resolvable, hidden from the library.
    case archived
    /// No bundled recipe carries this id any more. Nothing can be cascaded; the row keeps
    /// its snapshot and waits for him to decide.
    case missing
}

extension RecipeTweak {
    /// What to put on screen for this row. The caller passes the title of the resolved
    /// recipe when it has one, and `nil` when the id no longer resolves; the snapshot is
    /// the fallback, never the preferred answer, because the bundled file can be revised
    /// and the snapshot cannot.
    func displayTitle(resolvedTitle: String?, status: RecipeContentStatus = .present) -> String {
        let base: String
        if let resolvedTitle = resolvedTitle, !resolvedTitle.isEmpty {
            base = resolvedTitle
        } else if !recipeTitleSnapshot.isEmpty {
            base = recipeTitleSnapshot
        } else {
            base = recipeID.isEmpty ? "Untitled recipe" : recipeID
        }
        return status == .missing ? "\(base) (recipe no longer bundled)" : base
    }
}

// MARK: - Lapse

extension RecipeTweak {
    /// Overrides whose `lineID` is not in the recipe as it now reads.
    ///
    /// Join keys are name-plus-occurrence (`butter-1`, `butter-2`) and deliberately NOT
    /// positional, so a revised recipe file makes a stale override LAPSE instead of
    /// silently re-pointing at whatever ingredient now occupies that slot — a tweak that
    /// quietly moves from butter to flour is worse than one that stops applying. These are
    /// reported, never dropped: the tweak sheet lists them as "this no longer applies —
    /// remove it?" so a lost tweak is visible rather than silent.
    ///
    /// The empty-set guard is not defensive noise. `liveLineIDs` is empty exactly when the
    /// recipe could not be resolved at all — removed file, failed decode — and in that case
    /// EVERY override would be reported as lapsed, offering him a screenful of "remove it?"
    /// for a recipe that may well come back on the next build. A missing recipe is
    /// `RecipeContentStatus.missing` and is handled whole, not one override at a time.
    func lapsedIngredientOverrides(liveLineIDs: Set<String>) -> [IngredientOverride] {
        guard !liveLineIDs.isEmpty else { return [] }
        return orderedIngredientOverrides.filter { !liveLineIDs.contains($0.lineID) }
    }

    /// The step half of the same rule, with the same guard and for the same reason.
    func lapsedStepOverrides(liveStepIDs: Set<String>) -> [StepOverride] {
        guard !liveStepIDs.isEmpty else { return [] }
        return orderedStepOverrides.filter { !liveStepIDs.contains($0.stepID) }
    }

    func hasLapses(liveLineIDs: Set<String>, liveStepIDs: Set<String>) -> Bool {
        !lapsedIngredientOverrides(liveLineIDs: liveLineIDs).isEmpty
            || !lapsedStepOverrides(liveStepIDs: liveStepIDs).isEmpty
    }
}

// MARK: - IngredientOverride

/// "That line says 2 tbsp; it should say 1." One row per overridden ingredient line.
///
/// It carries the five flat quantity primitives behind `QuantityCarrying` — the same shape
/// as everything else in this schema that holds a quantity, and for the same reason: a
/// `Codable` composite would persist as an opaque blob that no `#Predicate` can read and
/// that any later change to `Rational` or to the unit table would have to migrate.
///
/// An existing row with `hasQuantity == false` means "this line has no measured quantity
/// any more" — the pinch representation, applied to an override. It is NOT "no override":
/// no override is the ABSENCE of the row.
@Model
final class IngredientOverride: QuantityCarrying {
    var id: UUID = UUID()

    /// `IngredientLine.lineID`, e.g. `butter-1`. Name-based with an occurrence number, so
    /// an override lapses visibly when the ingredient changes rather than re-pointing when
    /// lines are reordered. See the lapse comments on `RecipeTweak`.
    var lineID: String = ""

    /// The line as it read when he overrode it, so a lapsed override can be shown and
    /// explained — "you had set 1 tbsp butter; that line is gone" — instead of vanishing.
    var lineTextSnapshot: String = ""

    // MARK: The five flat primitives
    var hasQuantity: Bool = false
    var amountNumerator: Int = 0
    var amountDenominator: Int = 1
    var unitCode: String = ""
    var dimensionRaw: String = MeasureDimension.unmeasured.rawValue

    /// "" = leave the bundled preparation alone. There is deliberately no NAME override:
    /// changing what an ingredient IS is authoring, and recipes are authored before they
    /// arrive.
    var preparationOverride: String = ""

    var note: String = ""
    var createdAt: Date = .now

    /// Owner. The relationship macro lives on `RecipeTweak.ingredientOverrides`, so the
    /// `inverse:` is declared on exactly one side.
    var tweak: RecipeTweak? = nil

    init(
        id: UUID = UUID(),
        lineID: String = "",
        lineTextSnapshot: String = "",
        hasQuantity: Bool = false,
        amountNumerator: Int = 0,
        amountDenominator: Int = 1,
        unitCode: String = "",
        dimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        preparationOverride: String = "",
        note: String = "",
        createdAt: Date = .now,
        tweak: RecipeTweak? = nil
    ) {
        self.id = id
        self.lineID = lineID
        self.lineTextSnapshot = lineTextSnapshot
        self.hasQuantity = hasQuantity
        self.amountNumerator = amountNumerator
        self.amountDenominator = amountDenominator
        self.unitCode = unitCode
        self.dimensionRaw = dimensionRaw
        self.preparationOverride = preparationOverride
        self.note = note
        self.createdAt = createdAt
        self.tweak = tweak
    }
}

extension IngredientOverride {
    /// True when the recipe no longer has the line this row was written against.
    func hasLapsed(liveLineIDs: Set<String>) -> Bool {
        !liveLineIDs.isEmpty && !liveLineIDs.contains(lineID)
    }

    /// What the resolved line's preparation should read. `""` is the leave-alone sentinel
    /// and is why this is a function rather than the stored property being read directly.
    func effectivePreparation(bundled: String?) -> String? {
        preparationOverride.isEmpty ? bundled : preparationOverride
    }

    /// Something to show for a row whose line is gone, in preference order: the snapshot he
    /// recognises, then the key, then the quantity he typed.
    var lapseDescription: String {
        if !lineTextSnapshot.isEmpty { return lineTextSnapshot }
        if !lineID.isEmpty { return lineID }
        return quantity?.exactDescription ?? "Edited ingredient"
    }
}

// MARK: - StepOverride

/// "Step 6 should say 3 minutes, and the body is wrong." One row per corrected step.
///
/// `hasMinutesOverride` exists because `Int?` alone cannot distinguish "no override" from
/// "overridden to no duration", and zero is never an absent sentinel in this schema. A step
/// he has decided is untimed has to be expressible, and it is: the flag true with both
/// bounds nil.
@Model
final class StepOverride {
    var id: UUID = UUID()

    /// `RecipeStep.stepID`, e.g. `sear-the-steak-1`. Slug-of-title plus an occurrence
    /// number — name-based for the same reason as `IngredientOverride.lineID`, so
    /// renumbering a method does not silently move his correction onto another step.
    var stepID: String = ""

    /// The step title as it read when he corrected it, so a lapsed correction can be named.
    var stepTitleSnapshot: String = ""

    /// "" = leave the bundled text alone.
    var titleOverride: String = ""
    var bodyOverride: String = ""

    var hasMinutesOverride: Bool = false
    var minMinutes: Int? = nil
    var maxMinutes: Int? = nil

    var note: String = ""
    var createdAt: Date = .now

    /// Owner. The relationship macro lives on `RecipeTweak.stepOverrides`.
    var tweak: RecipeTweak? = nil

    init(
        id: UUID = UUID(),
        stepID: String = "",
        stepTitleSnapshot: String = "",
        titleOverride: String = "",
        bodyOverride: String = "",
        hasMinutesOverride: Bool = false,
        minMinutes: Int? = nil,
        maxMinutes: Int? = nil,
        note: String = "",
        createdAt: Date = .now,
        tweak: RecipeTweak? = nil
    ) {
        self.id = id
        self.stepID = stepID
        self.stepTitleSnapshot = stepTitleSnapshot
        self.titleOverride = titleOverride
        self.bodyOverride = bodyOverride
        self.hasMinutesOverride = hasMinutesOverride
        self.minMinutes = minMinutes
        self.maxMinutes = maxMinutes
        self.note = note
        self.createdAt = createdAt
        self.tweak = tweak
    }
}

extension StepOverride {
    func hasLapsed(liveStepIDs: Set<String>) -> Bool {
        !liveStepIDs.isEmpty && !liveStepIDs.contains(stepID)
    }

    func effectiveTitle(bundled: String) -> String {
        titleOverride.isEmpty ? bundled : titleOverride
    }

    func effectiveBody(bundled: String) -> String {
        bodyOverride.isEmpty ? bundled : bodyOverride
    }

    /// The timing the resolved step should carry. Returns the BUNDLED pair untouched when
    /// there is no override, and `(nil, nil)` when he has overridden the step to untimed —
    /// which is why the flag cannot be inferred from the two `Int?`s.
    func effectiveMinutes(bundledMin: Int?, bundledMax: Int?) -> (min: Int?, max: Int?) {
        guard hasMinutesOverride else { return (bundledMin, bundledMax) }
        return (minMinutes, maxMinutes)
    }

    /// True when he has deliberately declared this step untimed, as opposed to never having
    /// touched its timing.
    var isUntimedOverride: Bool {
        hasMinutesOverride && minMinutes == nil && maxMinutes == nil
    }

    var lapseDescription: String {
        if !stepTitleSnapshot.isEmpty { return stepTitleSnapshot }
        if !stepID.isEmpty { return stepID }
        return titleOverride.isEmpty ? "Edited step" : titleOverride
    }
}
