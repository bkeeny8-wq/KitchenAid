import SwiftUI
import SwiftData

/// What the app opens on, because Brandon chose it: today's plan with a way into
/// cooking, falling back to recent recipes when the plan is empty.
///
/// This screen is the only place the plan and the stove meet, and two things about
/// it were wrong until now. It rendered a planned meal as the bare word "Dinner" —
/// no title, no dishes, no way in — and `CookView` had no construction site
/// anywhere in the app, so the Cook button in that decision was a screen nobody
/// could reach.
///
/// The meal row is `PlanMealRow`, the same one the week and the day use, so three
/// screens cannot drift into describing one meal three ways; the portion summary
/// and the missing-recipe warning come with it. Beneath it is one row per dish, and
/// each one carries the PLAN's scale into `CookView`. That scale is the point:
/// `CookView.scale` defaults to ×1, and a dinner planned for four that reaches the
/// stove at ×1 is a dinner for two.
struct TodayView: View {
    @Environment(RecipeLoader.self) private var loader

    /// Bare and filtered in Swift, exactly as `PlanWeekView` does it. The store holds
    /// a few meals a week, and a `#Predicate` rebuilt against a new day key every
    /// time midnight passes is more machinery than the data justifies.
    @Query private var allMeals: [PlannedMeal]

    /// Read as rows rather than through `TweakStore`, because what this screen wants
    /// is one date per recipe and not the whole overlay applied to each. `lastMadeAt`
    /// is the entire cooking history the app keeps — he was offered a journal and
    /// declined it.
    @Query private var allTweaks: [RecipeTweak]

    /// Which day the add sheet is open on, carried as a value the way the Plan screens
    /// carry it, so a tap either side of midnight cannot plan onto a day other than the
    /// one in the header above it.
    @State private var planningOn: PlanSheetDay?

    private var todayKey: Int { CalendarKey.dayKey(for: Date()) }

    /// Slot order and not insertion order: `.prep` ("salt the steaks the day before")
    /// belongs ahead of the day's meals, and sorting on `slotRaw` would put brunch
    /// before dinner alphabetically and prep last. Same comparison as `PlanWeekView`.
    private var todaysMeals: [PlannedMeal] {
        allMeals
            .filter { $0.dayKey == todayKey }
            .sorted {
                ($0.slotSortIndex, $0.orderInSlot, $0.createdAt)
                    < ($1.slotSortIndex, $1.orderInSlot, $1.createdAt)
            }
    }

    var body: some View {
        List {
            Section {
                if todaysMeals.isEmpty {
                    nothingPlanned
                } else {
                    ForEach(todaysMeals) { meal in
                        mealRows(meal)
                    }
                }
            } header: {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
            }

            Section("Your recipes") {
                ForEach(recentRecipes) { recipe in
                    NavigationLink(value: recipe.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recipe.title).font(.body.weight(.medium))
                            Text(subtitle(for: recipe))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // Deliberately NOT a NavigationLink. The destination on this
                // stack takes a String and resolves it as a recipe id, so a
                // link carrying "recipes" would push a "Recipe not found"
                // screen. Switching tabs from here needs the selection binding,
                // which belongs to RootTabView, and that is a wire worth
                // running once rather than faking here.
                if loader.all.count > recentRecipes.count {
                    Text("\(loader.all.count - recentRecipes.count) more in the Recipes tab")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Today")
        .navigationDestination(for: String.self) { recipeID in
            RecipeDetailView(recipeID: recipeID)
        }
        .sheet(item: $planningOn) { day in
            NavigationStack {
                AddMealSheet(date: day.date)
            }
        }
    }

    // MARK: - Today's meals

    /// The meal, then its dishes. A tuple of rows rather than one row with the dishes
    /// inside it, because each dish is its own tap target: the meal row goes to the
    /// editor (who is eating, which changes the scale) and a dish row goes to the stove.
    @ViewBuilder
    private func mealRows(_ meal: PlannedMeal) -> some View {
        NavigationLink {
            MealEditorView(meal: meal)
        } label: {
            PlanMealRow(meal: meal)
        }

        ForEach(meal.orderedMealRecipes) { dish in
            dishRow(dish)
        }
    }

    /// One dish: a Cook button when there is something to cook, and a named row
    /// saying why not when there is not.
    @ViewBuilder
    private func dishRow(_ dish: MealRecipe) -> some View {
        if let recipe = dish.recipe(loader) {
            cookRow(dish, recipe: recipe)
        } else {
            missingDishRow(dish)
        }
    }

    /// The Cook button.
    ///
    /// The WHOLE ROW is the Cook action rather than a small trailing button beside a
    /// label that navigates somewhere else: two tap targets in one list row is how a
    /// row pushes the screen you did not ask for, and this is the control he reaches
    /// for with wet hands. The dish name is the title and the scale sentence is the
    /// caption, so the row says what it will cook and how much of it before it is
    /// tapped.
    ///
    /// Not a `@ViewBuilder`: it needs two local values first, and a plain function
    /// with a `return` is one less thing to be wrong about in a file no compiler here
    /// will read.
    private func cookRow(_ dish: MealRecipe, recipe: Recipe) -> some View {
        let plan = cookPlan(for: dish, recipe: recipe)
        let title = dish.titleForDisplay(resolvedTitle: recipe.title)
        return NavigationLink {
            CookView(recipeID: dish.recipeID, scale: plan.scale, dish: dish)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "flame.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                    // "Cook" is already in the title beside it; the flame announces
                    // as "flame", which is noise in front of the words that matter.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cook \(title)")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text(plan.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }

    /// A dish whose recipe has left the bundle. No delete rule can prevent it — the
    /// thing on the other end of `recipeID` is a file, not a row — so the row names it
    /// from the snapshot and offers no Cook button, rather than pushing a screen that
    /// can only say "Recipe not found".
    private func missingDishRow(_ dish: MealRecipe) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(dish.titleForDisplay(resolvedTitle: nil))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text("Nothing to cook until that file is back in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The scale the plan worked out, and the sentence that explains it.
    ///
    /// `MealScaling` is the one place a dish's scale is derived — attendance summed on
    /// the edge, divided by `Recipe.servings`, snapped to the recipe's batch
    /// granularity — and its `description` is already written for a human to read
    /// (`humanDescription` throughout, never `exactDescription`, which is how a label
    /// once read "23 1111/1135 tsp").
    private func cookPlan(
        for dish: MealRecipe,
        recipe: Recipe
    ) -> (scale: Rational, detail: String) {
        let result = MealScaling.scaling(
            for: dish,
            recipe: recipe,
            // Unused unless the `.noAttendance` branch fires, and that branch's answer is
            // discarded just below, so this number never reaches the stove. It exists for
            // a shopping list, which must buy something for a meal nobody is down for.
            defaultDinerCount: 1
        )

        // Nobody assigned and no batch pinned: cook the recipe as written. Buying for an
        // invented two diners is a defensible shopping answer; cooking 2/4 of a
        // four-serving recipe because the attendance grid is empty is not, and he would
        // have no way to tell halved quantities from the real ones. An override is
        // different — "double batch anyway" beats the arithmetic outright, including the
        // arithmetic it never got to do — so it is passed through.
        if dish.scaleOverride == nil, result.notes.contains(.noAttendance) {
            return (.one, "Nobody is eating yet, so this cooks as written.")
        }
        return (result.scale, result.description)
    }

    /// An empty plan is the normal state of a new install and of any day he has not got
    /// to yet, so it is `.nothingYet` and not `.somethingWrong`.
    ///
    /// The action presents `AddMealSheet` here rather than switching to the Plan tab:
    /// the sheet is the same one both Plan screens open, it writes the meal through
    /// `PlanEditor` exactly as they do, and it lands him back on Today with the meal
    /// on it. A tab switch would need the selection binding that belongs to
    /// `RootTabView`, and would answer "plan a meal" with a different screen.
    private var nothingPlanned: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "fork.knife",
            headline: "Nothing planned for today",
            detail: "Plan a meal and pick its recipes, or cook something from the list "
                  + "below. Who is eating comes from the household, so the amounts "
                  + "follow on their own.",
            actionTitle: "Plan a meal",
            action: { planningOn = PlanSheetDay(date: Date()) }
        )
    }

    // MARK: - The fallback

    /// Most recently cooked first, then everything else by title.
    ///
    /// This was the first few by title and said so, because nothing wrote a last-made
    /// date until Cook mode had a caller. It has one now — this screen and the recipe
    /// detail screen — so "recent" is a fact rather than a label.
    private var recentRecipes: [Recipe] {
        let ordered = loader.all.sorted { a, b in
            let left = lastMade(a.id)
            let right = lastMade(b.id)
            if let left = left, let right = right {
                if left != right { return left > right }
            } else if (left == nil) != (right == nil) {
                return left != nil
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        return Array(ordered.prefix(6))
    }

    /// The later of any duplicate rows, which is how `TweakStore` merges them too.
    /// Two tweak rows for one recipe id is a state the UI has to survive rather than
    /// one the schema prevents: a CloudKit-ready store cannot use
    /// `@Attribute(.unique)`, so de-duplication happens in code or not at all.
    private func lastMade(_ recipeID: String) -> Date? {
        var latest: Date?
        for tweak in allTweaks where tweak.recipeID == recipeID {
            guard let made = tweak.lastMadeAt else { continue }
            if let current = latest, current >= made { continue }
            latest = made
        }
        return latest
    }

    /// Last made, or what the document says it makes. Never blank: a caption that is
    /// sometimes empty leaves the rows at two different heights for no reason the
    /// person reading them can see.
    private func subtitle(for recipe: Recipe) -> String {
        if let made = lastMade(recipe.id) {
            return "Last made \(made.formatted(date: .abbreviated, time: .omitted))"
        }
        if !recipe.yieldText.isEmpty { return recipe.yieldText }
        // `servesLabel()` and not a fourth spelling of the rule: it owns all three states,
        // including the one where the document names no count and this must print no
        // number rather than the substituted 4.
        return recipe.servesLabel()
    }
}
