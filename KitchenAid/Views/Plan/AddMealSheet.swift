import SwiftUI
import SwiftData

/// Planning a meal: which slot, what kind of night it is, and which recipes.
///
/// It writes nothing until Add is tapped. Creating the `PlannedMeal` up front and editing
/// it in place would leave a half-filled row on the calendar every time he opened the sheet
/// and changed his mind, and there is no draft state in the schema to distinguish one.
///
/// **Several recipes, or none.** Tuesday dinner is a main plus two sides; Friday is
/// takeout. Both go through this sheet, and the recipe picker simply does not apply to the
/// second — `mealRecipes` being empty is an expected state, not an incomplete one.
struct AddMealSheet: View {
    let date: Date
    /// The day screen knows which slot was tapped; the week screen does not and takes the
    /// default.
    var slot: MealSlot = .dinner

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(RecipeLoader.self) private var loader

    @Query private var allEaters: [Eater]

    @State private var chosenSlot: MealSlot = .dinner
    @State private var kind: MealEntryKind = .recipe
    @State private var title: String = ""
    /// Order of selection is kept, because it is the order he cooks: the main, then the
    /// sides. `MealRecipe.sortIndex` is written from this array's index.
    @State private var chosenRecipeIDs: [String] = []
    @State private var query: String = ""
    @State private var didPrimeSlot = false

    var body: some View {
        Form {
            Section {
                Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline.weight(.medium))
                Picker("Meal", selection: $chosenSlot) {
                    ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { s in
                        Text(s.title).tag(s)
                    }
                }
                Picker("Kind", selection: $kind) {
                    ForEach(MealEntryKind.allCases, id: \.self) { k in
                        Text(k.defaultTitle).tag(k)
                    }
                }
            } header: {
                Text("When")
            } footer: {
                if kind != .recipe {
                    Text("A \(kind.defaultTitle.lowercased()) night has no recipes and buys "
                         + "nothing. It still counts who was eating.")
                }
            }

            Section {
                TextField(titlePrompt, text: $title)
            } header: {
                Text("Title")
            } footer: {
                Text("Optional. Left empty, the meal is named after its recipes.")
            }

            if kind == .recipe {
                recipeSection
            }
        }
        .navigationTitle("Plan a meal")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find a recipe")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
            }
        }
        .onAppear {
            // `@State` cannot be initialised from a `let` property, and re-priming it on
            // every body pass would fight him every time he changed the picker.
            guard !didPrimeSlot else { return }
            didPrimeSlot = true
            chosenSlot = slot
        }
    }

    private var titlePrompt: String {
        kind == .recipe ? "Sunday roast" : kind.defaultTitle
    }

    // MARK: - Recipes

    @ViewBuilder
    private var recipeSection: some View {
        if !chosenRecipeIDs.isEmpty {
            Section {
                ForEach(chosenRecipeIDs, id: \.self) { id in
                    HStack {
                        Text(recipeTitle(id))
                        Spacer(minLength: 8)
                        Button {
                            chosenRecipeIDs.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Remove \(recipeTitle(id))")
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text(chosenRecipeIDs.count == 1 ? "1 dish" : "\(chosenRecipeIDs.count) dishes")
            } footer: {
                // Selection order is cook order, and the editor is where it can be
                // changed — a reorder control in a sheet that has not written a row yet
                // would have nothing to reorder.
                Text("In the order you picked them. Each one scales on its own.")
            }
        }

        Section {
            if candidates.isEmpty {
                Text(loader.all.isEmpty
                     ? "No recipes are bundled in this build."
                     : "Nothing matches \u{201C}\(query)\u{201D}.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { recipe in
                    Button {
                        toggle(recipe.id)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: chosenRecipeIDs.contains(recipe.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosenRecipeIDs.contains(recipe.id)
                                                 ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipe.title).foregroundStyle(.primary)
                                Text(servesText(recipe))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(
                        chosenRecipeIDs.contains(recipe.id) ? [.isSelected] : []
                    )
                }
            }
        } header: {
            Text("Add a recipe")
        }
    }

    private var candidates: [Recipe] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return loader.all }
        return loader.all.filter { recipe in
            if recipe.title.lowercased().contains(needle) { return true }
            if recipe.summary.lowercased().contains(needle) { return true }
            return recipe.tags.contains { $0.name.lowercased().contains(needle) }
        }
    }

    private func recipeTitle(_ id: String) -> String {
        loader.recipe(id: id)?.title ?? id
    }

    /// "Serves about 4" when the number came from him in passing rather than from the
    /// document — `servingsApproximate` exists so the UI does not render the two with the
    /// same confidence.
    private func servesText(_ recipe: Recipe) -> String {
        let n = recipe.servings.humanDescription
        return recipe.servingsApproximate ? "Serves about \(n)" : "Serves \(n)"
    }

    private func toggle(_ id: String) {
        if chosenRecipeIDs.contains(id) {
            chosenRecipeIDs.removeAll { $0 == id }
        } else {
            chosenRecipeIDs.append(id)
        }
    }

    // MARK: - Writing

    private func add() {
        let roster = allEaters.sorted { $0.sortIndex < $1.sortIndex }
        let meal = PlanEditor.makeMeal(
            on: date,
            slot: chosenSlot,
            kind: kind,
            title: title,
            roster: roster,
            in: context
        )
        if kind == .recipe {
            for (index, id) in chosenRecipeIDs.enumerated() {
                PlanEditor.addDish(
                    recipeID: id,
                    title: recipeTitle(id),
                    to: meal,
                    sortIndex: index,
                    in: context
                )
            }
        }
        dismiss()
    }
}
