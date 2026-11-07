import SwiftUI

/// One meal, as a row. Used by the week, by a single day, and by Today, so the three
/// screens cannot drift into describing the same meal three ways.
///
/// Everything numeric on it is computed by the model layer: `PlannedMeal.portionTotal` and
/// `MealRecipe.scale(recipeServings:)`, rendered by `PortionSummary`. Nothing here sums a
/// portion or divides by a serving count.
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
                PortionSummary(meal: meal, scale: singleDishScale, isCompact: true)
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

    /// The scale badge is only shown when the meal has exactly ONE dish.
    ///
    /// Each dish scales separately — he cooks extra of the ragù and not of the salad beside
    /// it — so a single number across three dishes would be wrong for at least two of them.
    /// Several dishes means the badge belongs on the dish rows in the editor, and this row
    /// shows portions alone. `nil` also covers no attendance and a missing yield, which
    /// `PortionSummary` renders by omitting the badge rather than inventing ×1.
    private var singleDishScale: Rational? {
        let dishes = meal.orderedMealRecipes
        guard dishes.count == 1, let dish = dishes.first else { return nil }
        guard let recipe = dish.recipe(loader) else { return nil }
        return dish.scale(recipeServings: recipe.servings)
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
