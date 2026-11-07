import SwiftUI

/// One recipe, in full.
///
/// This screen is the reason the app can be called stable: it has to render
/// everything the eight bundled documents contain, and between them they
/// contain every shape the content model allows — grouped ingredients with a
/// flat method, a component that is prose with no lines at all, a choice group,
/// quantity ranges, the author's own gram equivalents, a weight-to-time lookup
/// table, timing as a rate rather than a duration, and all-caps instructions
/// that matter more than anything else on the page.
///
/// It is READ-ONLY for now. Tweaks and notes are a later screen; showing an
/// edit affordance that does nothing would be worse than showing none.
struct RecipeDetailView: View {
    let recipeID: String

    @Environment(RecipeLoader.self) private var loader

    var body: some View {
        if let recipe = loader.recipe(id: recipeID) {
            content(recipe)
        } else {
            missing
        }
    }

    @ViewBuilder
    private func content(_ recipe: Recipe) -> some View {
        List {
            header(recipe)
            emphasis(recipe)
            ingredients(recipe)
            method(recipe)
            tables(recipe)
            notes(recipe)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ recipe: Recipe) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(recipe.title).font(.title3.weight(.semibold))
                if !recipe.summary.isEmpty {
                    Text(recipe.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    if !recipe.yieldText.isEmpty {
                        metric("Makes", recipe.yieldText)
                    }
                    metric("Serves", servingsText(recipe))
                    if let active = recipe.activeMinutes {
                        metric("Active", "\(active) min")
                    }
                    if let total = recipe.totalMinutes {
                        metric("Total", minutesText(total))
                    }
                }
                // The turkey times by weight and has no total at all, which is
                // the correct answer rather than a missing one.
                if let perPound = recipe.minutesPerPound {
                    HStack(spacing: 18) {
                        metric("Per pound", "\(perPound.humanDescription) min")
                        if let temp = recipe.ovenTempF {
                            metric("Oven", "\(temp)\u{00B0}F")
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium))
        }
    }

    /// "4", or "about 4" when the number is one Brandon supplied in passing
    /// rather than one the document claims.
    private func servingsText(_ recipe: Recipe) -> String {
        let n = recipe.servings.humanDescription
        return recipe.servingsApproximate ? "about \(n)" : n
    }

    private func minutesText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }

    // MARK: - Shouted instructions

    /// `DO. NOT. SALT.` and `DO NOT USE SALTED BUTTER.` are the whole point of
    /// the turkey — it, its butter and its gravy are all deliberately unsalted
    /// so the cook salts once at the end. The importer was dropping both lines
    /// entirely, so they get the most prominent treatment on the screen rather
    /// than being filed with the other notes.
    @ViewBuilder
    private func emphasis(_ recipe: Recipe) -> some View {
        let shouted = recipe.notes.filter { isShouted($0.text) }
        if !shouted.isEmpty {
            Section {
                ForEach(Array(shouted.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(note.text).font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    private func isShouted(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        return letters.count > 3 && letters.allSatisfy { $0.isUppercase }
    }

    // MARK: - Ingredients

    @ViewBuilder
    private func ingredients(_ recipe: Recipe) -> some View {
        ForEach(Array(recipe.components.enumerated()), id: \.offset) { _, component in
            Section {
                if !component.summary.isEmpty {
                    Text(component.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(component.lines) { line in
                    if line.isChoice {
                        choiceRow(line)
                    } else {
                        ingredientRow(line)
                    }
                }
            } header: {
                // A single unnamed group is the whole ingredient list, so
                // labelling it "Ingredients" reads better than a blank header.
                Text(component.title.isEmpty
                     ? (recipe.hasSingleUnnamedComponent ? "Ingredients" : "")
                     : component.title)
            }
        }
    }

    private func ingredientRow(_ line: IngredientLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(line.quantityDisplay)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 76, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.displayName)
                if !line.preparation.isEmpty {
                    Text(line.preparation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // The author's own second measurement, when the document gave
                // one: "1 1/2 cups all-purpose flour (190g)".
                if let alt = line.altQuantity {
                    Text("or \(alt.displayString())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// One of several ways to make the recipe, not a thing to buy. The pancake
    /// offers Cinnamon, Nutmeg, or Both.
    private func choiceRow(_ line: IngredientLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.displayName).font(.subheadline.weight(.medium))
                if !line.choiceText.isEmpty {
                    Text(line.choiceText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Method

    /// One flat list across the whole dish. A component groups ingredients; it
    /// is not a mini-recipe with its own steps, and the first fixture proved it.
    @ViewBuilder
    private func method(_ recipe: Recipe) -> some View {
        if !recipe.steps.isEmpty {
            Section("Method") {
                ForEach(recipe.steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(step.number)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            if !step.title.isEmpty {
                                HStack(spacing: 6) {
                                    Text(step.title).font(.subheadline.weight(.semibold))
                                    if let duration = step.durationText {
                                        Text(duration)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            Text(step.body).font(.subheadline)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Printed tables

    /// The turkey's weight-to-time chart. Eight rows of weight against total,
    /// covered and uncovered time, because a 10 lb bird and a 24 lb bird share
    /// the recipe and nothing else.
    @ViewBuilder
    private func tables(_ recipe: Recipe) -> some View {
        ForEach(recipe.tables) { table in
            Section(table.name) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(table.labelled(row).enumerated()), id: \.offset) { index, pair in
                            if index == 0 {
                                Text(pair.value).font(.subheadline.weight(.semibold))
                            } else {
                                HStack {
                                    Text(pair.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 8)
                                    Text(pair.value).font(.caption.weight(.medium))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Notes

    @ViewBuilder
    private func notes(_ recipe: Recipe) -> some View {
        let ordinary = recipe.notes.filter { !isShouted($0.text) }
        if !ordinary.isEmpty {
            Section("Notes") {
                ForEach(Array(ordinary.enumerated()), id: \.offset) { _, note in
                    Text(note.text).font(.subheadline)
                }
            }
        }
    }

    // MARK: - Missing

    /// A recipe id that resolves to nothing. Across the content and persistence
    /// boundary there is no cascade that could have prevented this: the far end
    /// is a file in the app, not a row, so a plan or a tweak can outlive the
    /// recipe it points at. Saying so is better than an empty screen.
    private var missing: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Recipe not found").font(.headline)
            Text("No bundled recipe has the id \u{201C}\(recipeID)\u{201D}. It may have been "
                 + "renamed or removed in a later build.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .navigationTitle("Not found")
    }
}
