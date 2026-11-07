import SwiftUI

/// ONE STEP, large.
///
/// The body text is `.title3` and not `.body`, which looks oversized in a
/// screenshot and is the whole point in a kitchen: this is read at arm's length,
/// at an angle, past a pan. Dynamic Type still applies on top, so the person who
/// has already turned text up gets it bigger again.
///
/// The step carries its own component tag (`componentIndex`) and nothing else
/// connects it to an ingredient group -- steps are FLAT across the whole dish and
/// a component groups ingredients only. So where a step is tagged, the group is
/// shown as a pill for orientation ("you are in the spinach now"); where it is
/// not, nothing is invented. `scripts/import_recipe.py` does not write
/// `componentIndex` today, so in practice the pill is absent on all eight
/// bundled recipes and appears the moment the importer learns to tag.
struct CookStepCard: View {

    let step: RecipeStep
    let number: Int
    let total: Int
    /// "" when the step is not tagged into a component.
    let componentTitle: String
    let isDone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            badges
            if !componentTitle.isEmpty {
                Text(componentTitle.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
            }
            if !step.title.isEmpty {
                Text(step.title)
                    .font(.title.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !step.body.isEmpty {
                Text(step.body)
                    .font(.title3)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !step.cookTemperatureText.isEmpty {
                temperatures
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Badges

    /// Four states, and they must not look alike: a plain duration, a RANGE, no
    /// duration at all, and a passive rest.
    ///
    /// The fixture forces all four in one recipe -- step 1 is a 30-minute rest,
    /// step 3 is "7 to 8 min", steps 7 and 8 have no duration -- and the
    /// turkey's ten steps have none at all, because the recipe times by weight.
    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 8) {
            if step.readsAsPassiveRest {
                badge(
                    text: restText,
                    symbol: "hourglass",
                    tint: .secondary,
                    // Waiting, not work. Grey and the word "hands off", because
                    // an orange clock on a rest reads as something to attend to
                    // and the entire value of a rest is that he can walk away.
                    accessibility: "Hands off. \(restText)"
                )
            } else if let duration = step.durationText {
                badge(
                    text: duration,
                    symbol: "timer",
                    tint: .orange,
                    accessibility: step.hasDurationRange
                        ? "Takes \(duration), a range"
                        : "Takes \(duration)"
                )
            }
            if isDone {
                badge(
                    text: "Done",
                    symbol: "checkmark.circle.fill",
                    tint: .green,
                    accessibility: "This step is marked done"
                )
            }
            Spacer(minLength: 0)
            Text("\(number) / \(total)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var restText: String {
        if let duration = step.durationText { return "Hands off \u{00B7} \(duration)" }
        return "Hands off"
    }

    private func badge(
        text: String,
        symbol: String,
        tint: Color,
        accessibility: String
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    /// The oven and the internal target, side by side and big. Two fields
    /// because one cannot hold both: the fixture's step 2 heats the oven to 400F
    /// and its step 3 wants 125F in the middle of the steak.
    @ViewBuilder
    private var temperatures: some View {
        HStack(spacing: 10) {
            Image(systemName: "thermometer.medium")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(step.cookTemperatureText)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
