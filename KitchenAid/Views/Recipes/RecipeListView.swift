import SwiftUI

/// The library. Eight recipes today and more every time Brandon cooks, so this
/// is built around search and sort rather than around browsing a short list.
struct RecipeListView: View {
    @Environment(RecipeLoader.self) private var loader

    enum Sort: String, CaseIterable, Identifiable {
        case title = "A–Z"
        case time = "Time"
        case course = "Course"
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var sort: Sort = .title

    var body: some View {
        List {
            if !shown.isEmpty {
                Section {
                    ForEach(shown) { recipe in
                        NavigationLink(value: recipe.id) {
                            RecipeRow(recipe: recipe)
                        }
                    }
                } header: {
                    Text(countLabel)
                }
            } else {
                emptyState
            }
        }
        .navigationTitle("Recipes")
        .navigationDestination(for: String.self) { recipeID in
            RecipeDetailView(recipeID: recipeID)
        }
        .searchable(text: $query, prompt: "Name, ingredient or tag")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var countLabel: String {
        let n = shown.count
        if query.isEmpty {
            return n == 1 ? "1 recipe" : "\(n) recipes"
        }
        return n == 1 ? "1 match" : "\(n) matches"
    }

    /// Search covers ingredients and tags, not just the title. "What can I do
    /// with Gruyère" is the question a recipe library is actually asked.
    private var shown: [Recipe] {
        let base = loader.all
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? base : base.filter { recipe in
            if recipe.title.lowercased().contains(needle) { return true }
            if recipe.summary.lowercased().contains(needle) { return true }
            if recipe.tags.contains(where: { $0.name.lowercased().contains(needle) }) { return true }
            return recipe.allLines.contains { $0.displayName.lowercased().contains(needle) }
        }
        switch sort {
        case .title:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .time:
            // Unknown times sort last rather than first, because a recipe with
            // no stated time is not a fast recipe.
            return filtered.sorted {
                ($0.activeMinutes ?? Int.max, $0.title) < ($1.activeMinutes ?? Int.max, $1.title)
            }
        case .course:
            return filtered.sorted {
                ($0.course.rawValue, $0.title) < ($1.course.rawValue, $1.title)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if loader.all.isEmpty {
            // Distinguished deliberately: an empty library and a library whose
            // files failed to load look identical on screen, and the second is
            // the one worth acting on.
            VStack(spacing: 10) {
                Text(loader.hasDiagnostics ? "No recipes loaded" : "No recipes yet")
                    .font(.headline)
                Text(loader.hasDiagnostics
                     ? "Recipe files were found but could not be read. The banner above says which."
                     : "Recipes are bundled with the app. Add one and rebuild.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            Text("Nothing matches \u{201C}\(query)\u{201D}")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        }
    }
}

private struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.title).font(.body.weight(.medium))
            if !recipe.summary.isEmpty {
                Text(recipe.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                if let active = recipe.activeMinutes {
                    Label("\(active) min active", systemImage: "clock")
                } else if let perPound = recipe.minutesPerPound {
                    Label("\(perPound.humanDescription) min/lb", systemImage: "scalemass")
                }
                if !recipe.yieldText.isEmpty {
                    Text(recipe.yieldText)
                }
                if recipe.components.count > 1 {
                    Text("\(recipe.components.count) components")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
