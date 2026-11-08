import SwiftUI
import SwiftData

/// "2 full + 1 half + 2 guests = 4½ portions, ×1⅛".
///
/// Display only. Every number here is computed by the model layer —
/// `PlannedMeal.householdPortions`, `guestPortions` and `portionTotal`, and
/// `MealRecipe.scale(recipeServings:)` — because that arithmetic is the reason
/// `Rational` exists and a view re-deriving it would be the second
/// implementation.
///
/// The scale is shown as a FRACTION. "×1.125" is precisely the rendering this
/// project refuses: it is the same number, it cannot be measured, and it is
/// what a `Double` pipeline produces. `humanDescription` prints a kitchen
/// denominator exactly and marks anything it had to round with "≈", so the
/// label is never more confident than the value.
///
/// A dish the plan selects BY WEIGHT — a whole roast bird — gets `weight`
/// instead of `scale`: see `WeightBadge`. The portion line above it still
/// reads, because who is eating is a fact about the meal even when it is not
/// what sets the quantities.
struct PortionSummary: View {

    /// What a dish SELECTED BY WEIGHT puts in the badge, in place of a scale.
    ///
    /// A whole roast bird is not scaled, it is bought: nobody roasts 1.4
    /// turkeys. So "×1⅛" is not a number he can act on here — it is the ratio
    /// between two birds and it reads like a quantity — and the useful badge is
    /// the bird itself, or the fact that one still has to be chosen.
    ///
    /// Added as a SEPARATE case rather than by reinterpreting `scale`, because
    /// `scale` means "multiply the recipe by this" at both existing call sites
    /// and a weight is not that number.
    enum WeightBadge: Hashable, Sendable {
        /// The bird he picked, in pounds: "18 lb bird".
        case chosen(Rational)
        /// Weight-driven and nothing chosen yet. The meal cannot be shopped
        /// honestly until it is, so this says so rather than going blank.
        case needed
    }

    let meal: PlannedMeal
    /// nil when there is nothing to scale: no attendance, or a recipe with no
    /// yield. Both are real states the caller surfaces its own way, so this
    /// view omits the badge rather than inventing ×1.
    var scale: Rational? = nil
    /// Set instead of `scale` for a dish the plan selects by weight. When both
    /// arrive this one wins, because a weight-driven dish's `scale` is a ratio
    /// of two bird weights and showing it beside a portion count is the exact
    /// confusion this case exists to remove.
    var weight: WeightBadge? = nil
    /// The day cell has room for one line; the meal editor does not need to be
    /// terse.
    var isCompact: Bool = false

    var body: some View {
        if isCompact {
            HStack(spacing: 8) {
                Text(totalText)
                    .font(.caption.weight(.semibold))
                badge
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(breakdownText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text("= \(totalText)")
                        .font(.subheadline.weight(.semibold))
                    badge
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// One badge at most, and the weight takes precedence. Written once here
    /// rather than twice in the two layouts above, which is where a later edit
    /// would have made the compact row and the full row disagree.
    @ViewBuilder
    private var badge: some View {
        if let weight = weight {
            weightBadge(weight)
        } else if let scale = scale {
            scaleBadge(scale)
        }
    }

    private func scaleBadge(_ scale: Rational) -> some View {
        Text("\u{00D7}\(scale.humanDescription)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.16), in: Capsule())
            .accessibilityLabel("scaled \(scale.humanDescription) times the recipe")
    }

    /// `humanDescription` here as everywhere: 14/1 has to read "14 lb" and not
    /// "14/1", and an exact interpolation is how a label came to read
    /// "23 1111/1135 tsp".
    /// `kind` and not `badge`: the computed property above is called `badge`, and a
    /// parameter shadowing it is the kind of line a later reader misreads.
    @ViewBuilder
    private func weightBadge(_ kind: WeightBadge) -> some View {
        switch kind {
        case .chosen(let pounds):
            Text("\(pounds.humanDescription) lb bird")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.16), in: Capsule())
                // No article, so there is none to get wrong: "a 18 pound bird" is what
                // the obvious phrasing reads for half the chart's own rows.
                .accessibilityLabel("bird weight \(pounds.humanDescription) pounds")
        case .needed:
            // Orange and worded as a job, not a value: until he picks one the
            // list buys the quantities as written, which is a defensible answer
            // and not the right one.
            Text("pick a bird weight")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.18), in: Capsule())
                .accessibilityLabel("no bird weight chosen yet")
        }
    }

    // MARK: - The words

    /// Grouped by portion size and not listed by name: the point of the line is
    /// that four heads is not four portions.
    private var breakdownText: String {
        var parts: [String] = []

        let consuming = meal.orderedAttendance.filter { $0.consumesPortion }
        let full = consuming.filter { $0.effectivePortion == .one }.count
        let half = consuming.filter { $0.effectivePortion == Rational(1, 2) }.count
        if full > 0 { parts.append("\(full) full") }
        if half > 0 { parts.append("\(half) half") }

        // Anything that is neither full nor half was written by a future build
        // — `HouseholdView` offers exactly two — so it is named with its own
        // fraction rather than rounded into one of the two buckets.
        let others = consuming.filter {
            $0.effectivePortion != .one && $0.effectivePortion != Rational(1, 2)
        }
        for row in others {
            parts.append("\(row.initials) \(row.effectivePortion.humanDescription)")
        }

        if meal.guestCount > 0 {
            let noun = meal.guestCount == 1 ? "guest" : "guests"
            if meal.guestPortion == .one {
                parts.append("\(meal.guestCount) \(noun)")
            } else {
                parts.append(
                    "\(meal.guestCount) \(noun) at \(meal.guestPortion.humanDescription)"
                )
            }
        }

        if parts.isEmpty { return "Nobody eating yet" }
        return parts.joined(separator: " + ")
    }

    /// `.zero` is a real answer and not an error — a meal with nobody assigned
    /// must neither silently buy nothing nor silently buy for four — so it says
    /// "no portions" instead of "0 portions", which reads like a bug.
    private var totalText: String {
        let total = meal.portionTotal
        if total.isZero { return "no portions" }
        let noun = total == .one ? "portion" : "portions"
        return "\(total.humanDescription) \(noun)"
    }
}
