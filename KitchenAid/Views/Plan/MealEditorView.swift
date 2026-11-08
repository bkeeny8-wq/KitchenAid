import SwiftUI
import SwiftData

/// One meal, editable: what it is, which dishes, who is eating, and what came of it.
///
/// This is where the scale he will shop by becomes visible. Each dish scales SEPARATELY —
/// he cooks extra of the ragù and not of the salad beside it — so the badge lives on the
/// dish row and not on the meal. Every number is `MealRecipe.scale(recipeServings:)` and
/// `MealScaling`; this screen formats them and nothing more.
///
/// And it is where a BIRD is chosen. A dish whose recipe is `isWeightDriven` is not scaled
/// by attendance at all — nobody roasts 1.4 turkeys — so its control is a weight off the
/// document's own chart, written onto the `MealRecipe` so the shopping list can read it.
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
            // The general rule, and the exception named where the exception is visible. A
            // screen that states "each dish scales against who is eating" above a dish that
            // demonstrably does not is how the next reader concludes the turkey is broken.
            if hasWeightDrivenDish {
                Text("Each dish scales on its own against who is eating \u{2014} except a "
                     + "whole bird, which is chosen by weight. The gravy and the sides "
                     + "beside it still follow the attendance.")
            } else {
                Text("Each dish scales on its own against who is eating.")
            }
        }
    }

    /// True when any dish in the meal is selected by weight rather than scaled.
    private var hasWeightDrivenDish: Bool {
        meal.orderedMealRecipes.contains { $0.recipe(loader)?.isWeightDriven == true }
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

            // The one thing he can act on, in words, when a bird is what the quantities
            // depend on and no bird has been picked. The badge above it says "yield
            // unknown", which is `ScalingNote`'s existing name for "the divisor is not a
            // number anybody gave us" and is true but not actionable.
            if let prompt = weightPrompt(dish, recipe: recipe) {
                Label(prompt, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let recipe = recipe, recipe.isWeightDriven {
                weightMenu(dish, recipe: recipe)
            } else {
                // "I know, make a double batch anyway" beats the attendance arithmetic
                // outright, which is what `setScaleOverride` is for. Offered as fixed batch
                // sizes rather than a free number: the override is a cook's decision, and a
                // text field inviting 1.125 is the one input this project will not take.
                //
                // Not offered on a weight-driven dish, where it is the wrong question: you
                // do not make a double batch of turkey, you buy a bigger bird. The menu
                // beside this one is that choice, and it is the only control such a dish
                // needs.
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
            }

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

    // MARK: - The bird
    //
    // Brandon, 2026-11-08: the roast turkey document states no serving count. Asked how many
    // it serves, he answered that it "was for a roughly 14lb turkey" — a weight, not a count.
    // Asked whether to drive its portions off the document's own weight chart instead: "yes
    // use the weight chart".
    //
    // So for this kind of recipe the control here is not a scale and not a portion count. It
    // is WHICH BIRD, off the eight rows the document prints, and it is written onto the
    // `MealRecipe` rather than held on screen because the shopping list is built from the
    // plan: a weight chosen only at the stove could never reach the list, and he would shop
    // for a 14 lb bird and roast an 18 lb one.

    /// The chart's own weights, as a menu. Its rows and not a stepper, because a weight off
    /// the chart has no time to read against it — `weightRow(forPounds:)` returns nil and the
    /// cook screen loses the fact line that is the whole point of the table.
    @ViewBuilder
    private func weightMenu(_ dish: MealRecipe, recipe: Recipe) -> some View {
        Menu {
            ForEach(recipe.selectableWeightsPounds, id: \.self) { pounds in
                Button {
                    dish.setChosenWeightPounds(pounds)
                } label: {
                    // A tick on the current row, the same way `CookView`'s batch menu marks
                    // its own: a menu that shows no current value makes him open it twice.
                    if pounds == dish.chosenWeightPounds {
                        Label("\(pounds.humanDescription) lb bird", systemImage: "checkmark")
                    } else {
                        Text("\(pounds.humanDescription) lb bird")
                    }
                }
            }
            Button("No bird chosen yet") { dish.setChosenWeightPounds(nil) }
            // Reachable only for a dish that was given a fixed scale before its recipe
            // became weight-driven, or by `AddDishSheet` on a recipe that later gained a
            // chart. `MealScaling` honours an override ahead of the weight, so without this
            // the plan would shop by a number with nothing on screen to clear it.
            if let override = dish.scaleOverride {
                Button("Stop fixing the scale at \u{00D7}\(override.humanDescription)") {
                    dish.setScaleOverride(nil)
                }
            }
        } label: {
            Label(weightLabel(dish), systemImage: "scalemass")
                .font(.caption)
        }
        .frame(minHeight: 44)
    }

    /// "Bird: 18 lb", or that none is chosen. `humanDescription` and never
    /// `exactDescription`: 18/1 has to read "18" and not "18/1".
    private func weightLabel(_ dish: MealRecipe) -> String {
        guard let chosen = dish.chosenWeightPounds else { return "Bird: not chosen yet" }
        return "Bird: \(chosen.humanDescription) lb"
    }

    /// The sentence under a weight-driven dish with no bird picked, in a cook's words.
    ///
    /// It names the consequence rather than the state, because the consequence is the part
    /// that costs him something: the list is not wrong, it is buying the quantities as the
    /// document wrote them, which is right for the basis weight and for no other bird.
    private func weightPrompt(_ dish: MealRecipe, recipe: Recipe?) -> String? {
        guard let recipe = recipe, recipe.isWeightDriven,
              dish.chosenWeightPounds == nil, dish.scaleOverride == nil,
              let basis = recipe.basisWeightPounds
        else { return nil }
        return "Pick a bird weight \u{2014} until then this is shopped as written, "
            + "for a \(basis.humanDescription) lb bird."
    }

    /// The sentence `MealScaling` builds, which names the arithmetic behind the number.
    ///
    /// `defaultDinerCount` is deliberately NOT consulted here: its fallback-to-two belongs
    /// to a shopping list that must buy something, whereas this screen can simply say
    /// nobody is down for the meal yet. Inventing two eaters on the plan screen would make
    /// the empty attendance grid and the scale beside it disagree. The weight branch below
    /// passes the argument because the signature demands one, and `weightDrivenScaling` says
    /// why that number cannot reach anything on screen.
    private func scaleText(_ dish: MealRecipe, recipe: Recipe?) -> String {
        guard let recipe = recipe else {
            return "This recipe is no longer in the app, so it cannot be scaled."
        }
        // A bird is not divided by a head count, so the sentence has to come from the one
        // place that knows that. `scale(recipeServings:)` below takes a serving count and
        // cannot see `basisWeightPounds`, which is why routing this through `MealScaling` is
        // not a style choice: without it this row read ×1/2 while the shopping list read
        // ×≈1.3 for the same dish.
        if recipe.isWeightDriven {
            return weightDrivenScaling(dish, recipe: recipe).description
        }
        guard let scale = dish.scale(recipeServings: recipe.servings) else {
            if meal.portionTotal.isZero {
                return "Nobody is eating yet, so there is nothing to scale by."
            }
            return "This recipe does not say how many it serves, so it cannot be scaled."
        }
        let portions = dish.requestedPortions
        let word = portions == .one ? "portion" : "portions"
        // "recipe serves 4" is a CLAIM about the document, so it may only be made when the
        // document makes it. The gravy states no serving count either, and it is not
        // weight-driven, so this row quoted the 4 the decoder substituted straight back as
        // the recipe's own figure -- the exact damage `servingsStated` was added to stop,
        // in the one screen where he sets attendance and reads the scale.
        //
        // The number IS disclosed here rather than hidden, which is the opposite of what
        // `Recipe.servesLabel()` does, and deliberately: there the number is a claim about
        // the recipe, here it is what the app is dividing his shopping by right now. He
        // should be able to see it in order to argue with it.
        //
        // The sentence below the guard was written for this case and was UNREACHABLE:
        // `scale(recipeServings:)` returns nil only on zero portions, which the branch
        // above already answers.
        guard recipe.servingsStated else {
            return "\u{00D7}\(scale.humanDescription) \u{2014} \(portions.humanDescription) "
                + "\(word). This recipe states no serving count, so 4 is assumed."
        }
        return "\u{00D7}\(scale.humanDescription) \u{2014} \(portions.humanDescription) "
            + "\(word), recipe serves \(recipe.servings.humanDescription)"
    }

    /// `MealScaling`'s own result for a weight-driven dish: the scale, the notes and the
    /// sentence, all from the one place a dish's scale is derived.
    ///
    /// `defaultDinerCount` cannot reach anything this screen shows. On the weight branch it
    /// lands only in `Result.portions`, which is reported for display and never divided by,
    /// and neither that branch's sentence nor an override's mentions a head count — so the 1
    /// passed here is not the fallback-to-two this screen deliberately refuses elsewhere (see
    /// `scaleText`), it is a required argument with no path to the output.
    private func weightDrivenScaling(_ dish: MealRecipe, recipe: Recipe) -> MealScaling.Result {
        MealScaling.scaling(for: dish, recipe: recipe, defaultDinerCount: 1)
    }

    /// Badges, never swallowed: a snapped batch has to say it snapped, and an override has
    /// to say the arithmetic was beaten.
    private func notes(for dish: MealRecipe, recipe: Recipe?) -> [ScalingNote] {
        // Same reason as `scaleText`: every check below is portion arithmetic against a
        // serving count, and `.snappedToBatch` in particular would be decided by a scale
        // this dish does not use. `MealScaling` suppresses `.noAttendance` and
        // `.leftoversIncluded` here too, because neither input moved the quantity and a
        // badge that explains a number it had no part in is noise.
        if let recipe = recipe, recipe.isWeightDriven {
            return weightDrivenScaling(dish, recipe: recipe).notes
        }
        var out: [ScalingNote] = []
        if dish.scaleOverride != nil { out.append(.overridden) }
        if let extra = dish.plannedLeftoverServings, extra > 0 {
            out.append(.leftoversIncluded)
        }
        // `servings` can never BE zero -- the accessor substitutes -- so the old test here
        // could only ever fire on a missing recipe. A document that states no count is the
        // case that actually occurs (the gravy, the turkey) and it needs the same badge, so
        // the line this dish puts on a shopping list carries the same warning the list
        // itself shows.
        if recipe == nil || recipe?.servingsStated == false { out.append(.unknownYield) }
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
