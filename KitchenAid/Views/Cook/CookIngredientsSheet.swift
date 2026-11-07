import SwiftUI

/// THE INGREDIENT LIST, at the scale he is actually cooking.
///
/// Reached from the toolbar of cook mode and deliberately a sheet rather than a
/// panel: the step is the screen, and the ingredients are something he comes
/// back to between steps -- "how much butter was it?" -- and then dismisses.
///
/// Three things it has to get right, each of them a defect the project has
/// already had somewhere:
///
/// - **Groups, not sub-recipes.** Ingredients are grouped into components and
///   the method is FLAT across the whole dish, so a component is a heading over
///   a list of lines and nothing else. There are no steps on this screen.
/// - **Every amount through `CookQuantity`**, which applies the three rules the
///   PDF exporter applies: a `.fixed` line does not scale, a range stays a
///   range, and the number is rendered with `displayString()`/`humanDescription`
///   and never `exactDescription` -- which is what produced the "23 1111/1135
///   tsp" label review 03 found.
/// - **A pick-one group writes back.** The pancake's "Spice Mix-Ins" offers
///   cinnamon, nutmeg or both, and `CookView.choices` is what both its fact line
///   and `depleteFromPantry` read. Without a control that sets it, cooking one
///   variation would take all three out of the pantry.
///
/// It carries its own `NavigationStack`. Everywhere else in the app the
/// presenter wraps the sheet -- `PantryView` wraps `AddStockSheet`, and so on --
/// but `CookView` presents this bare, so a stack here is the difference between
/// a titled sheet with a way out and a list with neither.
struct CookIngredientsSheet: View {

    let resolved: ResolvedRecipe
    let scale: Rational

    /// Component INDEX to chosen `lineID`, keyed the same way `CookView` keys it
    /// so `resolved.component(at:)` resolves on the other side. Session-only;
    /// writing it to the store would be authoring a variant.
    @Binding var choices: [Int: String]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if resolved.components.isEmpty {
                    EmptyStateView(
                        kind: .nothingYet,
                        symbol: "list.bullet",
                        headline: "No ingredients listed",
                        detail: "This recipe is method only, so there is nothing to measure "
                              + "out. The steps still work."
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Ingredients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            if scale != .one {
                scaleBanner
            }
            ForEach(Array(resolved.components.enumerated()), id: \.offset) { index, component in
                section(index: index, component: component)
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Said once, at the top, rather than tagged onto every row. The per-line
    /// "not scaled" qualifier is what explains the rows this does not apply to.
    @ViewBuilder
    private var scaleBanner: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "multiply.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Every amount below is \(scale.humanDescription) times the recipe.")
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - One group

    @ViewBuilder
    private func section(index: Int, component: RecipeComponent) -> some View {
        let offersChoice = component.lines.contains { $0.isChoice }
        Section {
            if !component.summary.isEmpty {
                Text(component.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // A group that names another recipe and carries no lines of its own.
            // Said plainly rather than rendered as an empty group, because a
            // blank heading reads as a bug and this is the content being honest.
            if component.isReference {
                Text("Made as its own recipe \u{2014} open it from the library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(component.lines) { line in
                if line.isChoice {
                    choiceRow(line, componentIndex: index)
                } else {
                    row(line)
                }
            }
        } header: {
            // A single unnamed group IS the ingredient list, so labelling it
            // reads better than a blank header. Same call as RecipeDetailView.
            Text(component.title.isEmpty
                 ? (resolved.hasSingleUnnamedComponent ? "Ingredients" : "")
                 : component.title)
        } footer: {
            if offersChoice {
                Text("Pick one. Only what you pick comes out of the pantry when you "
                   + "finish, so tap it again to un-pick it.")
            }
        }
    }

    // MARK: - One line

    private func row(_ line: IngredientLine) -> some View {
        let amount = CookQuantity.text(for: line, scale: scale)
        let alt = CookQuantity.altText(for: line, scale: scale)
        let qualifiers = CookQuantity.qualifiers(for: line, scale: scale)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(amount)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 96, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.displayName)
                        .font(.title3)
                    if resolved.isOverridden(lineID: line.lineID) {
                        // His number, not the document's. Marked because the
                        // overlay is silent otherwise and "did I change that?"
                        // is a question only the app can answer.
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("you edited this")
                    }
                }
                if !line.preparation.isEmpty {
                    Text(line.preparation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // The recipe's OWN second measurement, scaled: "(190g)". Exact,
                // written by whoever wrote the recipe, and for a baking recipe
                // the one to weigh by.
                if let alt {
                    Text("or \(alt)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !qualifiers.isEmpty {
                    Text(qualifiers)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// One of several ways to make the recipe, not a thing to buy.
    ///
    /// These rows arrive from the importer with `hasQuantity: false` and their
    /// amount in `choiceText` -- "1/2 tsp, good with the apple compote" -- so
    /// running one through `CookQuantity.text` prints an empty string. The text
    /// is shown as written instead, unscaled, because a sentence is not a
    /// number and multiplying it is not possible.
    private func choiceRow(_ line: IngredientLine, componentIndex: Int) -> some View {
        let isPicked = choices[componentIndex] == line.lineID
        return Button {
            choices[componentIndex] = isPicked ? nil : line.lineID
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: isPicked ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.displayName)
                        .font(.title3.weight(isPicked ? .semibold : .regular))
                    if !line.choiceText.isEmpty {
                        Text(line.choiceText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
