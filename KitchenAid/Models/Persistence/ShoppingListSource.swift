import Foundation
import SwiftData

/// "Recipe asked for X" — the traceability he will want the moment a number looks wrong, and
/// the rows "drop Thursday's dinner from this list" iterates.
///
/// It carries BOTH denormalized snapshot strings AND a live `.nullify` edge to the meal. The
/// snapshots preserve history across a recipe revision — a list printed in November must
/// still read correctly in March, and with recipes bundled and immutable that includes
/// surviving a `git revert` of the recipe file — and the live edge is what makes "which lines
/// did Thursday cause" and "jump to the meal that caused this line" into queries instead of a
/// decode-every-blob scan. An opaque `sourcesJSON` string gives up the second, and a bare
/// relationship gives up the first.
@Model
final class ShoppingListSource {
    var id: UUID = UUID()
    var sortIndex: Int = 0
    /// `LineSourceKind`: plannedMeal / parLevel / manual.
    var kindRaw: String = LineSourceKind.plannedMeal.rawValue

    // MARK: Snapshots
    var mealDayKey: Int = 0
    var mealSlotRaw: String = ""
    var mealTitle: String = ""
    var recipeTitle: String = ""
    /// "Creamed horseradish spinach". For a nested sub-recipe this is the full path joined
    /// with " > ", so the provenance reads the way the dish is built.
    var componentPath: String = ""
    /// "3 tbsp prepared horseradish, drained" — exactly what the recipe said.
    var originalText: String = ""
    /// "4 1/2 tbsp (×1.5)" — what it became.
    var scaledText: String = ""
    /// "×1.5 — 6 eaters, recipe serves 4". On EVERY source row, so the arithmetic is never a
    /// mystery.
    var scaleDescription: String = ""

    // MARK: This source's own contribution, in base units
    //
    // Per source and not only per line, because "why is this 1/4 cup" is answered by which
    // of the three components asked for what. The fixture needs it on one recipe alone:
    // butter appears as 1 tbsp in two components, and a line that reports 2 tbsp with no
    // per-source split is a line he cannot check.
    var hasContribution: Bool = false
    var contributionDimensionKey: String = ""
    var contributionBaseNumerator: Int = 0
    var contributionBaseDenominator: Int = 1

    /// For "jump to the recipe". A **content id string**, not a UUID: recipes are bundled
    /// content, and SwiftData cannot hold a relationship to a value type. Allowed to dangle
    /// — `recipeTitle` carries the text when the file is gone.
    var recipeID: String = ""
    /// The content line this came from, for the buy-or-make replay on a regenerate.
    var lineID: String = ""

    /// The live edge. Macro lives on `PlannedMeal.shoppingSources` (`.nullify`): deleting a
    /// meal must leave the already-bought line alone, because that happened.
    var plannedMeal: PlannedMeal? = nil
    /// Owner. Macro lives on `ShoppingListLine.sources`.
    var line: ShoppingListLine? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        kindRaw: String = LineSourceKind.plannedMeal.rawValue,
        mealDayKey: Int = 0,
        mealSlotRaw: String = "",
        mealTitle: String = "",
        recipeTitle: String = "",
        componentPath: String = "",
        originalText: String = "",
        scaledText: String = "",
        scaleDescription: String = "",
        hasContribution: Bool = false,
        contributionDimensionKey: String = "",
        contributionBaseNumerator: Int = 0,
        contributionBaseDenominator: Int = 1,
        recipeID: String = "",
        lineID: String = "",
        plannedMeal: PlannedMeal? = nil,
        line: ShoppingListLine? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.kindRaw = kindRaw
        self.mealDayKey = mealDayKey
        self.mealSlotRaw = mealSlotRaw
        self.mealTitle = mealTitle
        self.recipeTitle = recipeTitle
        self.componentPath = componentPath
        self.originalText = originalText
        self.scaledText = scaledText
        self.scaleDescription = scaleDescription
        self.hasContribution = hasContribution
        self.contributionDimensionKey = contributionDimensionKey
        self.contributionBaseNumerator = contributionBaseNumerator
        self.contributionBaseDenominator = contributionBaseDenominator
        self.recipeID = recipeID
        self.lineID = lineID
        self.plannedMeal = plannedMeal
        self.line = line
    }
}

// MARK: - Reading a source

extension ShoppingListSource {
    var kind: LineSourceKind { LineSourceKind(rawValue: kindRaw) ?? .plannedMeal }

    /// Nil when the slot was never snapshotted — a `.parLevel` or `.manual` source has no
    /// meal, and that is a legitimate state rather than a missing field.
    var mealSlot: MealSlot? { MealSlot(rawValue: mealSlotRaw) }

    /// `max(1, _)` guards `Rational`'s zero-denominator precondition against a value read
    /// back out of the store.
    var contributionBase: Rational? {
        guard hasContribution else { return nil }
        return Rational(contributionBaseNumerator, max(1, contributionBaseDenominator))
    }

    /// "Tuesday dinner · Creamed horseradish spinach" — the provenance row's heading. The
    /// snapshots are read in preference to the live edge on purpose: a meal retitled in March
    /// must not retitle November's list.
    var provenanceHeading: String {
        let parts = [mealTitle, recipeTitle, componentPath].filter { !$0.isEmpty }
        return parts.isEmpty ? kind.rawValue : parts.joined(separator: " \u{00B7} ")
    }
}
