import Foundation
import SwiftData

/// Join: one dish in a meal. A dinner is a main and two sides, and each dish scales and is
/// cooked separately. He chose several recipes per meal over one recipe per slot, and this
/// join is what it costs.
///
/// **`recipeID` is a content id, not a relationship.** Recipes are immutable bundled
/// content — `Codable` value types, never `@Model` — and SwiftData cannot hold a
/// relationship to a value type. So there is no `recipe: Recipe?` edge here and there
/// cannot be one.
///
/// The id is therefore allowed to DANGLE, and no delete rule can stop it: a delete rule
/// reaches rows, and the thing on the other end of this string is a bundled file. Removing
/// a recipe from the bundle leaves every `MealRecipe` holding its id pointing at nothing,
/// with nothing for SwiftData to cascade to. That is what `recipeTitleSnapshot` is for —
/// last March's plan stays readable instead of going blank — and why the cheap alternative
/// is always `"archived": true` in the JSON. Archive, do not delete.
@Model
final class MealRecipe {
    var id: UUID = UUID()

    /// Position within the meal: the main, then the sides, in the order he cooks them.
    var sortIndex: Int = 0

    /// `Recipe.id`. Resolve through `RecipeLoader.recipe(id:)`, never by fetching — there is
    /// no row to fetch.
    var recipeID: String = ""

    /// Written when the dish is added, by `MealPlanService.plan(recipeID:title:on:slot:)`,
    /// which is the one place it is set and whose `title` argument is deliberately not
    /// optional. Survives the recipe file being removed.
    var recipeTitleSnapshot: String = ""

    /// Beats the attendance calculation outright: "I know, make a double batch anyway."
    ///
    /// Both `nil` or both set, and the accessor is what guards it. Two separate `Int?`s are
    /// how you get a numerator with no denominator; `setScaleOverride(_:)` is the only
    /// writer that cannot produce that state.
    var scaleOverrideNumerator: Int? = nil
    var scaleOverrideDenominator: Int? = nil

    /// Cooking extra on purpose, to feed a `.leftovers` meal later. Counted into the scale —
    /// see `requestedPortions`.
    var plannedLeftoverServings: Int? = nil

    /// What was actually made. The number a leftovers child draws down. `nil` means not yet
    /// cooked, which is why it is not a defaulted `Int`: zero servings cooked and "I have
    /// not cooked it" are different facts, and only one of them means the leftovers meal on
    /// Thursday has nothing behind it.
    var servingsCooked: Int? = nil

    /// Cook today, eat Thursday. The fixture's spinach can be made a day ahead, so this is
    /// a real flag and not a nicety.
    var isPrepAhead: Bool = false

    var notes: String = ""

    /// Owner. The macro lives on `PlannedMeal.mealRecipes`, so the `inverse:` is declared on
    /// exactly one side.
    var meal: PlannedMeal? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        recipeID: String = "",
        recipeTitleSnapshot: String = "",
        scaleOverrideNumerator: Int? = nil,
        scaleOverrideDenominator: Int? = nil,
        plannedLeftoverServings: Int? = nil,
        servingsCooked: Int? = nil,
        isPrepAhead: Bool = false,
        notes: String = "",
        meal: PlannedMeal? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.recipeID = recipeID
        self.recipeTitleSnapshot = recipeTitleSnapshot
        self.scaleOverrideNumerator = scaleOverrideNumerator
        self.scaleOverrideDenominator = scaleOverrideDenominator
        self.plannedLeftoverServings = plannedLeftoverServings
        self.servingsCooked = servingsCooked
        self.isPrepAhead = isPrepAhead
        self.notes = notes
        self.meal = meal
    }
}

// MARK: - Resolving the content

extension MealRecipe {
    /// Resolution goes through the loader. The snapshot is the fallback, never the source,
    /// because the bundled file can be revised and the snapshot cannot.
    func recipe(_ loader: RecipeLoader) -> Recipe? { loader.recipe(id: recipeID) }

    var displayTitle: String { recipeTitleSnapshot }

    /// Something to put on screen for a dish whose recipe is no longer bundled. Named, not
    /// blank, so he can decide whether to forget it.
    ///
    /// Not an overload of `displayTitle`: a computed property and a method sharing a base
    /// name is exactly the construct this project cannot risk, having no compiler to ask.
    func titleForDisplay(resolvedTitle: String?) -> String {
        if let resolvedTitle = resolvedTitle, !resolvedTitle.isEmpty { return resolvedTitle }
        if !recipeTitleSnapshot.isEmpty { return "\(recipeTitleSnapshot) (recipe no longer bundled)" }
        return recipeID.isEmpty ? "Untitled dish" : recipeID
    }
}

// MARK: - Scale
//
// Exact rationals throughout. `Rational` exists because 1/3 cup × 3 has to be exactly
// 1 cup, and a scale laundered through `Double` on the way in gives that back as
// 0.9999999 no matter how carefully the multiplication afterwards is done.
//
// Batch granularity, the `ScalingNote`s and the per-device default diner count are
// `MealScaling`'s job, not this row's. What lives here is the arithmetic that depends only
// on this dish and its meal.

extension MealRecipe {
    /// `nil` = derive from attendance. Both integers must be present and the denominator
    /// non-zero, or there is no override.
    var scaleOverride: Rational? {
        guard let n = scaleOverrideNumerator, let d = scaleOverrideDenominator, d != 0
        else { return nil }
        let r = Rational(n, d)
        return r > .zero ? r : nil
    }

    /// Passing `nil` clears both halves, which is the point of having one writer.
    func setScaleOverride(_ newScale: Rational?) {
        guard let newScale = newScale, newScale > .zero else {
            scaleOverrideNumerator = nil
            scaleOverrideDenominator = nil
            return
        }
        scaleOverrideNumerator = newScale.numerator
        scaleOverrideDenominator = newScale.denominator
    }

    /// Portions this dish is being cooked for: the meal's eaters and guests, plus the extra
    /// he is deliberately making for a later leftovers meal.
    ///
    /// The leftover servings belong HERE and not on the meal, because he cooks extra of the
    /// ragù and not extra of the salad beside it. That is also what makes the worked example
    /// come out right: 4 portions plus 2 for Thursday, against a recipe serving 4, is a
    /// scale of 3/2 with a `.leftoversIncluded` note.
    var requestedPortions: Rational {
        let base = meal?.portionTotal ?? .zero
        let extra = plannedLeftoverServings ?? 0
        return extra > 0 ? base + Rational(extra) : base
    }

    /// The exact scale for this dish, or `nil` when there is nothing to divide.
    ///
    /// `nil` has two causes and the caller must distinguish them, which is why this does not
    /// quietly return `.one`: no attendance and no guests is `.noAttendance`, and a recipe
    /// whose yield is missing or zero is `.unknownYield`. Both are surfaced as badges on
    /// every affected shopping line — a meal with nobody assigned must neither silently buy
    /// nothing nor silently buy for four.
    func scale(recipeServings: Rational) -> Rational? {
        if let override = scaleOverride { return override }
        guard recipeServings > .zero else { return nil }
        let portions = requestedPortions
        guard portions > .zero else { return nil }
        return portions / recipeServings
    }

    /// Convenience for the common case of a whole-number yield off a decoded recipe.
    func scale(recipeServings: Int) -> Rational? {
        scale(recipeServings: Rational(recipeServings))
    }
}
