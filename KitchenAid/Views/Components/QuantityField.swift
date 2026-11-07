import SwiftUI

/// Entering an amount that is a fraction.
///
/// This is the most-used control in the app and the one most able to make him
/// stop using it. Recipes are written in halves, thirds, quarters and eighths,
/// and a decimal keypad turns "1 1/4 tsp" into four keystrokes and a wrong
/// number: 1.25 is not a fraction, and `Rational(approximating:)` only gets it
/// back because 1/4 happens to be representable. So the common amounts are one
/// tap each, the whole number is a stepper, and the keyboard is the fallback
/// rather than the interface.
///
/// All parsing goes through `Rational(string:)`, which already survives the
/// inputs that trapped in review 03 (`"-1 -9223372036854775808/3"` among them).
/// Nothing here re-implements it.
struct QuantityField: View {
    let label: String
    @Binding var value: Rational
    /// Shown beside the field and spoken with the value. The unit itself is
    /// `UnitPicker`'s job; this control only needs the word.
    let unitName: String

    /// The text is NOT the value. It is what he has typed so far, which is
    /// frequently not yet a number ("1 1/"), and the last good value has to
    /// survive that keystroke rather than collapsing to zero under him.
    @State private var text: String = ""
    @FocusState private var isEditing: Bool

    init(label: String, value: Binding<Rational>, unitName: String = "") {
        self.label = label
        self._value = value
        self.unitName = unitName
    }

    /// Halves, thirds, quarters, eighths — the denominators a measuring spoon
    /// actually has, and the same set `Rational.kitchenDenominators` rounds to.
    private static let quickFractions: [Rational] = [
        Rational(1, 2), Rational(1, 3), Rational(2, 3),
        Rational(1, 4), Rational(3, 4), Rational(1, 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(label)
                Spacer(minLength: 8)
                TextField("Amount", text: $text)
                    .focused($isEditing)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 76, maxWidth: 116)
                    .accessibilityLabel("\(label) amount")
                    .accessibilityValue(spokenValue)
                if !unitName.isEmpty {
                    Text(unitName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: wholeBinding, in: 0...999) {
                Text("Whole: \(wholeNumber)")
                    .font(.subheadline)
                    .monospacedDigit()
            }

            fractionRow

            Text(previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
                // The field already announces the same value; saying it twice
                // is worse than not saying it at all.
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        // `initial: true` seeds the field on first render, so there is no
        // separate onAppear that can disagree with this one.
        .onChange(of: value, initial: true) { _, _ in
            // Never while he is typing: rewriting the field under the cursor
            // is how "1 1/2" becomes "1" between two keystrokes.
            if !isEditing { text = canonicalText }
        }
        .onChange(of: text) { _, newText in adopt(newText) }
    }

    // MARK: - The one-tap fractions

    private var fractionRow: some View {
        HStack(spacing: 8) {
            ForEach(QuantityField.quickFractions, id: \.self) { fraction in
                Button {
                    // Tapping the fraction already showing clears it, so
                    // 1 1/2 -> 1 is one tap and not a trip to the keyboard.
                    let next = fractionPart == fraction ? Rational.zero : fraction
                    setValue(Rational(wholeNumber) + next)
                } label: {
                    Text(fraction.exactVulgarDescription)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    fractionPart == fraction
                        ? Color.accentColor.opacity(0.20)
                        : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityLabel(QuantityField.spokenFraction(fraction))
                .accessibilityAddTraits(fractionPart == fraction ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Reading the bound value

    /// Truncated, and floored at zero: a quantity is never negative, and a
    /// negative one arriving from elsewhere must not drive the stepper below
    /// its bounds and trap.
    private var wholeNumber: Int {
        max(0, value.numerator / value.denominator)
    }

    private var fractionPart: Rational {
        (value - Rational(wholeNumber)).clampedAtZero
    }

    private var wholeBinding: Binding<Int> {
        Binding(
            get: { max(0, value.numerator / value.denominator) },
            set: { newWhole in
                setValue(Rational(max(0, newWhole)) + fractionPart)
            }
        )
    }

    /// ASCII and parseable, so round-tripping it through `adopt` is a no-op,
    /// and ROUNDED, because `exactDescription` on a scaled quantity is how a
    /// label came to read "23 1111/1135 tsp" (SPEC_REVIEW_03 finding 8). A
    /// kitchen fraction is unchanged by the rounding, which is every value this
    /// field itself can produce.
    private var canonicalText: String {
        value.isZero ? "" : value.kitchenRounded().value.exactDescription
    }

    private var previewText: String {
        guard !value.isZero else { return "No amount" }
        return unitName.isEmpty
            ? "= \(value.humanDescription)"
            : "= \(value.humanDescription) \(unitName)"
    }

    private var spokenValue: String {
        guard !value.isZero else { return "empty" }
        return unitName.isEmpty
            ? value.humanDescription
            : "\(value.humanDescription) \(unitName)"
    }

    // MARK: - Writing it

    /// Both halves together. Setting only `value` and letting the change
    /// handler catch up works, but leaves one frame where the field and the
    /// chips disagree about what the amount is.
    private func setValue(_ newValue: Rational) {
        let clamped = newValue.clampedAtZero
        value = clamped
        text = clamped.isZero ? "" : clamped.kitchenRounded().value.exactDescription
    }

    private func adopt(_ newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            value = .zero
            return
        }
        if let parsed = Rational(string: trimmed) {
            value = parsed.clampedAtZero
            return
        }
        // A decimal is not one of the forms `Rational(string:)` takes, and
        // "1.25" is a thing a person types into a numeric field. Continued
        // fractions at the boundary only — see `Rational(approximating:)`.
        if let decimal = Double(trimmed), decimal.isFinite {
            value = Rational(approximating: decimal, maxDenominator: 64).clampedAtZero
            return
        }
        // Mid-typing. Keep the last good value rather than zeroing it.
    }

    /// VoiceOver reads "1/2" as characters often enough to be worth spelling
    /// the six quick fractions out.
    private static func spokenFraction(_ fraction: Rational) -> String {
        switch (fraction.numerator, fraction.denominator) {
        case (1, 2): return "one half"
        case (1, 3): return "one third"
        case (2, 3): return "two thirds"
        case (1, 4): return "one quarter"
        case (3, 4): return "three quarters"
        case (1, 8): return "one eighth"
        default: return fraction.exactDescription
        }
    }
}
