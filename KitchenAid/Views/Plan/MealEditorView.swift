import SwiftUI
import SwiftData

/// One meal, editable: what it is, which dishes, who is eating, and what came of it.
///
/// This is where the scale he will shop by becomes visible. Each dish scales SEPARATELY —
/// he cooks extra of the ragù and not of the salad beside it — so the badge lives on the
/// dish row and not on the meal. Every number is `MealRecipe.scale(recipeServings:)` and
/// `MealScaling`; this screen formats them and nothing more.
///
/// It edits the row in place, with no Save button. SwiftData autosaves, a cancel would have
/// to unwind relationship changes by hand, and a meal plan is the kind of thing he adjusts
/// four times before Tuesday.
struct MealEditorView: View {
    let meal: PlannedMeal

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(RecipeLoader.self) private var loader

    @Query private var allEaters: [Eater]

    @State private var isAddingDish = false
    @State private var isConfirmingDelete = false

    var body: some View {
        Form {
            whenSection
            dishesSection
            AttendanceGridView(meal: meal, roster: roster)
            outcomeSection
            deleteSection
        }
        .navigationTitle(meal.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingDish) {
            NavigationStack {
                AddDishSheet(meal: meal)
            }
        }
        .confirmationDialog(
            "Remove this meal from the plan?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove meal", role: .destructive) {
                PlanEditor.delete(meal, in: context)
                dismiss()
            }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("Its dishes and its attendance go with it. The recipes themselves are "
                 + "untouched \u{2014} they are part of the app, not part of the plan.")
        }
    }

    private var roster: [Eater] {
        allEaters.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    // MARK: - What and when

    @ViewBuilder
    private var whenSection: some View {
        Section {
            DatePicker(
                "Day",
                selection: dayBinding,
                displayedComponents: [.date]
            )
            Picker("Meal", selection: slotBinding) {
                ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                    Text(slot.title).tag(slot)
                }
            }
            Picker("Kind", selection: kindBinding) {
                ForEach(MealEntryKind.allCases, id: \.self) { kind in
                    Text(kind.defaultTitle).tag(kind)
                }
            }
            TextField("Title", text: titleBinding)
            TextField("Notes", text: notesBinding, axis: .vertical)
        } header: {
            Text("The meal")
        } footer: {
            if meal.slot == .prep {
                Text("Prep sorts above the day's meals. Its ingredients are bought with "
                     + "the meal it is for rather than twice.")
            }
        }
    }

    // MARK: - Dishes

    @ViewBuilder
    private var dishesSection: some View {
        Section {
            if meal.orderedMealRecipes.isEmpty {
                Text(noDishesText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(meal.orderedMealRecipes) { dish in
                    dishRow(dish)
                }
                .onDelete { offsets in
                    let dishes = meal.orderedMealRecipes
                    for index in offsets where dishes.indices.contains(index) {
                        PlanEditor.removeDish(dishes[index], in: context)
                    }
                }
            }
            Button {
                isAddingDish = true
            } label: {
                Label("Add a dish", systemImage: "plus")
            }
            .frame(minHeight: 44)
        } header: {
            Text("Dishes")
        } footer: {
            Text("Each dish scales on its own against who is eating.")
        }
    }

    /// A meal with no recipe is takeout, a night out, or a note to himself. Saying so is
    /// the difference between a legitimate state and a row that looks half filled in.
    private var noDishesText: String {
        switch meal.kind {
        case .recipe:
            return "No dishes yet. Add the main, then the sides."
        case .leftovers:
            return "Leftovers buy nothing and cook nothing. They still count who ate."
        case .takeout, .eatingOut:
            return "Nothing to cook, so nothing is bought for it."
        case .note:
            return "A note on the calendar. No dishes, no shopping."
        }
    }

    @ViewBuilder
    private func dishRow(_ dish: MealRecipe) -> some View {
        let recipe = dish.recipe(loader)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dish.titleForDisplay(resolvedTitle: recipe?.title))
                        .font(.body.weight(.medium))
                    Text(scaleText(dish, recipe: recipe))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let recipe = recipe {
                    NavigationLink {
                        RecipeDetailView(recipeID: recipe.id)
                    } label: {
                        Image(systemName: "book")
                    }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Open \(recipe.title)")
                }
            }

            ForEach(notes(for: dish, recipe: recipe), id: \.self) { note in
                Text(note.badge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
            }

            // "I know, make a double batch anyway" beats the attendance arithmetic
            // outright, which is what `setScaleOverride` is for. Offered as fixed batch
            // sizes rather than a free number: the override is a cook's decision, and a
            // text field inviting 1.125 is the one input this project will not take.
            Menu {
                Button("Follow who is eating") { dish.setScaleOverride(nil) }
                Button("Half batch") { dish.setScaleOverride(Rational(1, 2)) }
                Button("Single batch") { dish.setScaleOverride(.one) }
                Button("Double batch") { dish.setScaleOverride(Rational(2)) }
                Button("Triple batch") { dish.setScaleOverride(Rational(3)) }
            } label: {
                Label(overrideLabel(dish), systemImage: "slider.horizontal.3")
                    .font(.caption)
            }
            .frame(minHeight: 44)

            Toggle("Make this one ahead", isOn: prepAheadBinding(dish))
                .font(.caption)
        }
        .padding(.vertical, 2)
    }

    /// "Scale: automatic", or the fixed batch he pinned it to.
    private func overrideLabel(_ dish: MealRecipe) -> String {
        guard let override = dish.scaleOverride else { return "Scale: automatic" }
        return "Scale: fixed at \u{00D7}\(override.humanDescription)"
    }

    /// The sentence `MealScaling` builds, which names the arithmetic behind the number.
    ///
    /// `defaultDinerCount` is deliberately NOT consulted here: its fallback-to-two belongs
    /// to a shopping list that must buy something, whereas this screen can simply say
    /// nobody is down for the meal yet. Inventing two eaters on the plan screen would make
    /// the empty attendance grid and the scale beside it disagree.
    private func scaleText(_ dish: MealRecipe, recipe: Recipe?) -> String {
        guard let recipe = recipe else {
            return "This recipe is no longer in the app, so it cannot be scaled."
        }
        guard let scale = dish.scale(recipeServings: recipe.servings) else {
            if meal.portionTotal.isZero {
                return "Nobody is eating yet, so there is nothing to scale by."
            }
            return "This recipe does not say how many it serves, so it cannot be scaled."
        }
        let portions = dish.requestedPortions
        let word = portions == .one ? "portion" : "portions"
        return "\u{00D7}\(scale.humanDescription) \u{2014} \(portions.humanDescription) "
            + "\(word), recipe serves \(recipe.servings.humanDescription)"
    }

    /// Badges, never swallowed: a snapped batch has to say it snapped, and an override has
    /// to say the arithmetic was beaten.
    private func notes(for dish: MealRecipe, recipe: Recipe?) -> [ScalingNote] {
        var out: [ScalingNote] = []
        if dish.scaleOverride != nil { out.append(.overridden) }
        if let extra = dish.plannedLeftoverServings, extra > 0 {
            out.append(.leftoversIncluded)
        }
        if recipe == nil || recipe?.servings.isZero == true { out.append(.unknownYield) }
        if let recipe = recipe,
           let step = recipe.batchGranularity.step,
           let scale = dish.scale(recipeServings: recipe.servings),
           scale.ceiling(toMultipleOf: step) != scale {
            out.append(.snappedToBatch)
        }
        return out
    }

    // MARK: - Outcome

    @ViewBuilder
    private var outcomeSection: some View {
        Section {
            Picker("Status", selection: statusBinding) {
                Text("Planned").tag(PlanStatus.planned)
                Text("Cooked").tag(PlanStatus.cooked)
                Text("Skipped").tag(PlanStatus.skipped)
                Text("Moved").tag(PlanStatus.moved)
            }
            Toggle("Leave out of the shopping list", isOn: excludeBinding)
        } header: {
            Text("Status")
        } footer: {
            // Brandon declined a cooking journal: no ratings, no notes-per-cook, no "how
            // did it go". Marking a meal cooked is a plan state, not a diary entry.
            Text("Cooked and skipped meals both stop being shopped for.")
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Text("Remove from the plan")
            }
            .frame(minHeight: 44)
        }
    }

    // MARK: - Bindings
    //
    // `setDate`, `setSlot`, `setKind` and `setStatus` are the only writers of the pairs
    // behind them. A view assigning `slotRaw` directly leaves `slotSortIndex` stale and the
    // calendar mis-ordered with nothing on screen to say so.

    private var dayBinding: Binding<Date> {
        Binding(get: { meal.date }, set: { meal.setDate($0) })
    }

    private var slotBinding: Binding<MealSlot> {
        Binding(get: { meal.slot }, set: { meal.setSlot($0) })
    }

    private var kindBinding: Binding<MealEntryKind> {
        Binding(get: { meal.kind }, set: { meal.setKind($0) })
    }

    private var statusBinding: Binding<PlanStatus> {
        Binding(get: { meal.status }, set: { meal.setStatus($0) })
    }

    private var titleBinding: Binding<String> {
        Binding(get: { meal.title }, set: { meal.title = $0 })
    }

    private var notesBinding: Binding<String> {
        Binding(get: { meal.notes }, set: { meal.notes = $0 })
    }

    private var excludeBinding: Binding<Bool> {
        Binding(get: { meal.excludeFromShopping }, set: { meal.excludeFromShopping = $0 })
    }

    private func prepAheadBinding(_ dish: MealRecipe) -> Binding<Bool> {
        Binding(get: { dish.isPrepAhead }, set: { dish.isPrepAhead = $0 })
    }
}

/// Adding a dish to a meal that already exists.
///
/// Separate from `AddMealSheet`'s picker because the two write at different moments: that
/// one collects ids and writes them when the meal is created, this one writes straight onto
/// a row that is already on the calendar.
struct AddDishSheet: View {
    let meal: PlannedMeal

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(RecipeLoader.self) private var loader

    @State private var query = ""

    var body: some View {
        List {
            if candidates.isEmpty {
                Text(loader.all.isEmpty
                     ? "No recipes are bundled in this build."
                     : "Nothing matches \u{201C}\(query)\u{201D}.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { recipe in
                    Button {
                        PlanEditor.addDish(
                            recipeID: recipe.id,
                            title: recipe.title,
                            to: meal,
                            in: context
                        )
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recipe.title).foregroundStyle(.primary)
                            if !recipe.yieldText.isEmpty {
                                Text(recipe.yieldText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .navigationTitle("Add a dish")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find a recipe")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private var candidates: [Recipe] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return loader.all }
        return loader.all.filter { recipe in
            if recipe.title.lowercased().contains(needle) { return true }
            return recipe.tags.contains { $0.name.lowercased().contains(needle) }
        }
    }
}
