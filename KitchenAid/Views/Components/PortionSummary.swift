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
struct PortionSummary: View {
    let meal: PlannedMeal
    /// nil when there is nothing to scale: no attendance, or a recipe with no
    /// yield. Both are real states the caller surfaces its own way, so this
    /// view omits the badge rather than inventing ×1.
    var scale: Rational? = nil
    /// The day cell has room for one line; the meal editor does not need to be
    /// terse.
    var isCompact: Bool = false

    var body: some View {
        if isCompact {
            HStack(spacing: 8) {
                Text(totalText)
                    .font(.caption.weight(.semibold))
                if let scale = scale {
                    scaleBadge(scale)
                }
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
                    if let scale = scale {
                        scaleBadge(scale)
                    }
                }
            }
            .accessibilityElement(children: .combine)
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
