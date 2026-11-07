import SwiftUI
import SwiftData

/// What the app opens on, because Brandon chose it: today's plan with a way
/// into cooking, falling back to recent recipes when the plan is empty.
///
/// The plan half is deliberately not faked. `PlannedMeal` exists and is in the
/// schema, but nothing writes one yet, so this reads the store honestly and
/// says there is nothing planned rather than showing a pretend meal. The
/// fallback is the part that works today, and it is the part he needs: a way to
/// get from opening the app to a recipe.
struct TodayView: View {
    @Environment(RecipeLoader.self) private var loader

    /// Read from the real store. It returns nothing until the Plan screen can
    /// write a meal, which is correct rather than a placeholder.
    @Query private var allMeals: [PlannedMeal]

    private var todayKey: Int { CalendarKey.dayKey(for: Date()) }

    private var todaysMeals: [PlannedMeal] {
        allMeals.filter { $0.dayKey == todayKey }
    }

    var body: some View {
        List {
            Section {
                if todaysMeals.isEmpty {
                    nothingPlanned
                } else {
                    ForEach(todaysMeals) { meal in
                        Text(meal.slot.title)
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
                            if !recipe.yieldText.isEmpty {
                                Text(recipe.yieldText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
    }

    /// The library is small and has no cooking history yet — Brandon declined a
    /// journal, so only a last-made date is kept, and nothing writes one until
    /// Cook mode exists. So this is simply the first few by title, which is
    /// honest; calling it "recent" when nothing is tracked would not be.
    private var recentRecipes: [Recipe] {
        Array(loader.all.prefix(6))
    }

    private var nothingPlanned: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing planned for today").font(.subheadline.weight(.medium))
            Text("Planning a meal needs the Plan screen, which is not built yet. "
                 + "Pick a recipe below instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
