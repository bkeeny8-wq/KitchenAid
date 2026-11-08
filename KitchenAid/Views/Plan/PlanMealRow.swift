import SwiftUI

/// One meal, as a row. Used by the week, by a single day, and by Today, so the three
/// screens cannot drift into describing the same meal three ways.
///
/// Everything numeric on it is computed by the model layer: `PlannedMeal.portionTotal` and
/// `MealRecipe.scale(recipeServings:)`, rendered by `PortionSummary`. Nothing here sums a
/// portion or divides by a serving count.
///
/// A dish whose recipe is `isWeightDriven` — a whole roast bird — shows the WEIGHT instead,
/// because its quantities come from the bird he bought and not from who is eating.
struct PlanMealRow: View {
    let meal: PlannedMeal

    @Environment(RecipeLoader.self) private var loader

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: meal.slot.symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                // The slot is already spelled out in the text below it.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(meal.displayTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    if meal.kind != .recipe {
                        Image(systemName: meal.kind.symbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PortionSummary(
                    meal: meal,
                    scale: singleDishScale,
                    weight: singleDishWeight,
                    isCompact: true
                )
                if let warning = warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            if let mark = statusMark {
                Image(systemName: mark.symbol)
                    .font(.caption)
                    .foregroundStyle(mark.tint)
                    .accessibilityLabel(mark.spoken)
            }
        }
        .padding(.vertical, 2)
    }

    /// "Dinner · 3 dishes", or the kind's own word when there is no recipe at all. A meal
    /// with no dish is takeout, a night out or a bare note, and is a legitimate state
    /// rather than a half-filled row — so it gets a sentence, not a blank.
    private var subtitle: String {
        var parts: [String] = [meal.slot.title]
        let count = meal.orderedMealRecipes.count
        if count > 0 {
            parts.append(count == 1 ? "1 dish" : "\(count) dishes")
        } else if meal.kind == .recipe {
            parts.append("no dishes yet")
        } else {
            parts.append(meal.kind.defaultTitle.lowercased())
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The one dish and its recipe, when the meal has exactly one of each.
    ///
    /// A badge is only shown for a single-dish meal. Each dish scales separately — he cooks
    /// extra of the ragù and not of the salad beside it — so a single number across three
    /// dishes would be wrong for at least two of them. Several dishes means the badge
    /// belongs on the dish rows in the editor, and this row shows portions alone.
    private var soleDish: (dish: MealRecipe, recipe: Recipe)? {
        let dishes = meal.orderedMealRecipes
        guard dishes.count == 1, let dish = dishes.first else { return nil }
        guard let recipe = dish.recipe(loader) else { return nil }
        return (dish, recipe)
    }

    /// `nil` covers no attendance and a missing yield, which `PortionSummary` renders by
    /// omitting the badge rather than inventing ×1 — and now also a bird, which gets
    /// `singleDishWeight` instead.
    private var singleDishScale: Rational? {
        guard let sole = soleDish else { return nil }
        // A weight-driven dish must NOT come through here. `scale(recipeServings:)` divides
        // portions by a serving count, and for the turkey that count is the 4 the decoder
        // substituted for a number no document gives — so this row would have read ×1/2
        // while the shopping list, which goes through `MealScaling` and divides the chosen
        // bird by the 14 lb basis, read ×≈1.3. An override is different: it beats both
        // derivations in `MealScaling` too, so when one is pinned the number it shows is the
        // number he will shop by.
        if sole.recipe.isWeightDriven, sole.dish.scaleOverride == nil { return nil }
        return sole.dish.scale(recipeServings: sole.recipe.servings)
    }

    /// The bird, for a dish selected by weight: what `PortionSummary` shows where the scale
    /// badge would otherwise be.
    private var singleDishWeight: PortionSummary.WeightBadge? {
        guard let sole = soleDish, sole.recipe.isWeightDriven,
              sole.dish.scaleOverride == nil
        else { return nil }
        if let chosen = sole.dish.chosenWeightPounds { return .chosen(chosen) }
        return .needed
    }

    /// A dish whose recipe has left the bundle. No delete rule can prevent it — the thing
    /// on the other end of `recipeID` is a file, not a row — so the plan has to say so
    /// where he will see it rather than quietly showing one dish instead of two.
    private var warning: String? {
        let missing = meal.orderedMealRecipes.filter { loader.isMissing($0.recipeID) }
        guard !missing.isEmpty else { return nil }
        return missing.count == 1
            ? "1 dish is no longer in the app"
            : "\(missing.count) dishes are no longer in the app"
    }

    private var statusMark: (symbol: String, tint: Color, spoken: String)? {
        switch meal.status {
        case .planned: return nil
        case .cooked: return ("checkmark.circle.fill", .green, "cooked")
        case .skipped: return ("xmark.circle.fill", .secondary, "skipped")
        case .moved: return ("arrow.turn.down.right", .secondary, "moved")
        }
    }
}
