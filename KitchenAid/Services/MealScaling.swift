import Foundation

/// Attendance into an exact scale, and the sentence that explains it.
///
/// The whole of this file exists because a scale derived from a head count is wrong for the
/// household it was written for: "4 eaters" meaning two adults and two half portions is 3
/// servings, and cooking 4 wastes food every time. So portions are summed on the attendance
/// EDGE (`MealAttendance.effectivePortion`), guests are counted and multiplied, and the
/// divisor is `Recipe.servings`.
///
/// **Never `yieldAmount`.** The fixture says "Makes: 12 crostini (serves 4)"; dividing by 12
/// gives 4/12 = 1/3 and the first shopping list he generates buys one third of every
/// ingredient — with no zero-yield warning, because the yield is not zero.
///
/// **And not attendance at all, for a dish selected by weight.** A whole roast bird is bought
/// in one piece: nobody roasts 1.4 turkeys, you buy a bigger bird and read the longer time
/// off the chart. So where `Recipe.isWeightDriven` holds, the scale is the chosen weight over
/// the weight the document was written for and nothing else — see the branch below. The
/// gravy and the sides in the same meal keep scaling by attendance, because this is a
/// property of the recipe rather than of the meal.
///
/// A pure namespace: no fetches, no SwiftData, no SwiftUI. `recipe` is passed in rather than
/// reached for, because `MealRecipe` holds a content id and there is no row to fetch. It takes
/// the BUNDLED `Recipe` and not a `ResolvedRecipe`, because the scale depends only on
/// `servings`, `batchGranularity` and `basisWeightPounds`, none of which a tweak can touch —
/// so the overlay is irrelevant here and the signature says so.
enum MealScaling {

    struct Result: Sendable {
        /// Exact. Two full portions, one half and two full-portion guests is 9/2.
        ///
        /// REPORTED, NOT ALWAYS DIVIDED BY. For a weight-driven dish — a whole roast bird,
        /// selected by weight off the document's chart — this is still who is eating, and
        /// `scale` ignores it entirely: the chosen bird weight against the weight the recipe
        /// was written for is the whole derivation. The next reader will assume attendance
        /// still matters, so it is said here as well as at the branch below.
        var portions: Rational = .zero
        /// Exact. 9/2 against a recipe serving 4 is 9/8, never 1.125.
        var scale: Rational = .one
        /// Surfaced as a BADGE on every shopping line this dish touches, never swallowed.
        var notes: [ScalingNote] = []
        /// "×1 1/8 — 4 1/2 eaters, recipe serves 4". Lands on EVERY source row, so the
        /// arithmetic behind a number he is about to shop by is never a mystery.
        var description: String = ""
    }

    /// The one place a dish's scale is derived, and it stays the one place.
    ///
    /// Two derivations now live here, picked by the recipe and not by the caller: portions
    /// over `servings` for everything you can make more of, and chosen weight over
    /// `basisWeightPounds` for a whole bird you can only buy bigger. A manual
    /// `scaleOverride` beats both — "actually ×2" is an answer, not an argument.
    ///
    /// Every number here is built from stored integer pairs and nothing is laundered through
    /// a `Double`: `Rational` exists so that 1/3 cup × 3 is exactly 1 cup, and a scale that
    /// arrives as 1.125 gives that back as 0.9999999 no matter how careful the multiplication
    /// afterwards is.
    static func scaling(
        for mealRecipe: MealRecipe,
        recipe: Recipe?,
        defaultDinerCount: Int
    ) -> Result {
        var notes: [ScalingNote] = []

        // Worked out before the attendance notes, because on a weight-driven dish they would
        // be badges explaining a number they had no part in. A whole roast bird is SELECTED
        // BY WEIGHT: nobody roasts 1.4 turkeys, so neither the head count nor the extra he
        // wants for Thursday can move the quantity — he buys a bigger bird instead. The
        // gravy and the sides beside it still scale by attendance, which is why this is a
        // property of the recipe and not of the meal.
        let weightDriven = recipe?.isWeightDriven == true

        // The extra he is deliberately cooking for a later leftovers meal is already inside
        // `requestedPortions`; the note is what stops the larger number reading as a bug.
        if let extra = mealRecipe.plannedLeftoverServings, extra > 0, !weightDriven {
            notes.append(.leftoversIncluded)
        }

        var portions = mealRecipe.requestedPortions
        if portions <= .zero {
            // A meal with nobody assigned must neither silently buy nothing nor silently buy
            // for four. It buys for the per-device default AND says so.
            portions = Rational(max(1, defaultDinerCount))
            // Except on a weight-driven dish, where "no eaters set" would be a badge on a
            // quantity that no attendance figure touched. The weight is the only input, and
            // the branch below badges a MISSING weight instead, which is the thing he can
            // actually do something about.
            if !weightDriven { notes.append(.noAttendance) }
        }

        // "I know, make a double batch anyway" beats the arithmetic outright, so the
        // attendance fallback above is reported but not applied to the scale.
        if let override = mealRecipe.scaleOverride {
            notes.append(.overridden)
            let snapped = snap(override, to: recipe?.batchGranularity, notes: &notes)
            return Result(
                portions: portions,
                scale: snapped,
                notes: notes,
                description: "\u{00D7}\(snapped.humanDescription) \u{2014} your override"
            )
        }

        // A `recipeID` that no longer resolves: scale 1 and say so, rather than quietly
        // shopping for less. The meal's own title snapshot still reads, so the list header can
        // report it.
        guard let recipe = recipe else {
            notes.append(.unknownYield)
            return Result(
                portions: portions,
                scale: .one,
                notes: notes,
                description: "\u{00D7}1 \u{2014} this recipe is no longer in the app"
            )
        }

        // MARK: Weight-driven: the bird, not the head count
        //
        // Brandon, 2026-11-08, asked how many the turkey serves: "the turkey was for a
        // roughly 14lb turkey", then "yes use the weight chart". So for this kind of recipe
        // the scale is the bird he bought over the bird the document was written for, and
        // attendance and `servings` do not enter at all. That is what stops the turkey being
        // divided by the 4 `Recipe`'s decoder substituted for a count no document gives.
        //
        // Exact, and deliberately NOT snapped to `batchGranularity`: a weight ratio is not a
        // batch count, and snapping 9/7 to whole batches would double every quantity on an
        // 18 lb bird. Granularity answers "you cannot bake 1.4 loaves"; this answers "you
        // bought a bigger bird", and they are not the same question.
        if weightDriven, let basis = recipe.basisWeightPounds, basis > .zero {
            guard let chosen = mealRecipe.chosenWeightPounds, chosen > .zero else {
                // No weight picked yet. Scale 1 — the quantities as the document wrote them,
                // which are already right for the basis weight — and NOT the serving-count
                // path, which would divide by the substituted 4 this whole branch exists to
                // stop using.
                //
                // `.unknownYield` rather than a new case, and not because the badge wording
                // is ideal. `LineFlag.from(_:)` switches over `ScalingNote` exhaustively and
                // `PDFExportService.flagText` matches the same set, so a new case needs arms
                // in files this change does not own, and a case without them is a build
                // error in two places nobody here can fix. It is also the precedent set an
                // hour earlier for the same recipe (code review 01 item 4): this enum
                // already means "the divisor is not a number anybody gave us", which is
                // exactly true here. The sentence below carries what the badge cannot.
                notes.append(.unknownYield)
                return Result(
                    portions: portions,
                    scale: .one,
                    notes: notes,
                    description: "\u{00D7}1 \u{2014} no weight chosen yet, so this is the "
                        + "recipe as written for \(basis.humanDescription) lb"
                )
            }
            // `humanDescription`, never `exactDescription`: 9/7 reads "≈ 1.3" and not
            // "1 2/7", and an exact interpolation is how a label came to read
            // "23 1111/1135 tsp" (review 03 finding 8).
            let scale = chosen / basis
            return Result(
                portions: portions,
                scale: scale,
                notes: notes,
                description: "\u{00D7}\(scale.humanDescription) \u{2014} "
                    + "\(chosen.humanDescription) lb, recipe written for "
                    + "\(basis.humanDescription) lb"
            )
        }

        let servings = recipe.servings

        // Code review 01 item 4: the turkey and the gravy state no serving count, so
        // `recipe.servings` is 4 because `Recipe`'s decoder substituted 4 — not because
        // either document says so. Dividing by that in silence is the defect; the note is
        // the fix, and it rides the same path every other scaling note does, onto a badge on
        // each shopping line the dish produces.
        //
        // `.unknownYield` rather than a new case, for two reasons. It is already what this
        // enum means when the divisor is not a number the recipe gave us — `MealEditorView`
        // raises the same case for a zero serving count, and `RecipeGraph` for a sub-recipe
        // whose yield is missing. And a new case would need matching arms in `LineFlag`,
        // `LineFlag.from`, `ScalingNote.badge` and `PDFExportService.flagText` to earn a
        // badge that would read the same as this one's.
        if !recipe.servingsStated {
            notes.append(.unknownYield)
        }

        let snapped = snap(portions / servings, to: recipe.batchGranularity, notes: &notes)

        // `humanDescription` and never `exactDescription`: this string is read by a human on
        // every provenance row, and review 03 finding 8 traced an exact interpolation
        // rendering "23 1111/1135 tsp" — correct, and unusable.
        let eaterWord = portions == .one ? "eater" : "eaters"
        // Whose number the divisor is. "recipe serves 4" is a claim the document makes; for
        // the turkey the 4 was substituted here, and this sentence is where that has to be
        // readable, because it is what he reads in the aisle when a quantity looks wrong.
        let servesClause = recipe.servingsStated
            ? "recipe serves \(servings.humanDescription)"
            : "recipe gives no serving count, so \(servings.humanDescription) is assumed"
        let description = "\u{00D7}\(snapped.humanDescription) \u{2014} "
            + "\(portions.humanDescription) \(eaterWord), "
            + servesClause

        return Result(portions: portions, scale: snapped, notes: notes, description: description)
    }

    /// You cannot bake 1.4 loaves, and that is a property of the recipe rather than of any one
    /// line. Snapping UP is deliberate: half a batch too much is dinner, half a batch too
    /// little is a second trip.
    private static func snap(
        _ scale: Rational,
        to granularity: BatchGranularity?,
        notes: inout [ScalingNote]
    ) -> Rational {
        guard let granularity = granularity, let step = granularity.step, step > .zero else {
            return scale
        }
        let snapped = scale.ceiling(toMultipleOf: step)
        if snapped != scale { notes.append(.snappedToBatch) }
        return snapped
    }
}
