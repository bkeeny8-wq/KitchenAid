import SwiftUI

/// What is wrong with the recipe files.
///
/// This is the screen that makes the add-a-recipe loop usable. Brandon's
/// pipeline is that a recipe is authored, imported, committed and the app
/// rebuilt — so when a file is malformed, the failure surfaces on his phone,
/// away from any console. A loader that silently skips a bad file and an app
/// with one fewer recipe look exactly the same, and the difference is a
/// afternoon of wondering where the gravy went.
///
/// Every diagnostic names the FILE, because that is the thing he can go and fix.
struct DiagnosticsView: View {
    @Environment(RecipeLoader.self) private var loader

    /// Recipes the importer had reservations about. Distinct from a diagnostic:
    /// these files loaded fine and the app works, but something in them could
    /// not be worked out, so a quantity or an ingredient will behave oddly
    /// later. Seven exist across the eight bundled files and all seven are true.
    private var warned: [Recipe] {
        loader.allIncludingArchived
            .filter { !$0.warnings.isEmpty }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        List {
            if loader.diagnostics.isEmpty && warned.isEmpty {
                Section {
                    Label("Every recipe loaded cleanly", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if !loader.diagnostics.isEmpty {
                Section {
                    Text("These files are in the app but could not be used. Everything "
                         + "else loaded normally.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(grouped, id: \.0) { fileName, items in
                    Section(fileName) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.kind.title).font(.subheadline.weight(.semibold))
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            if !warned.isEmpty {
                Section {
                    Text("These loaded and work. The importer could not work something "
                         + "out about them, which usually shows up later as a quantity "
                         + "that will not scale or an ingredient that never reaches a "
                         + "shopping list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(warned) { recipe in
                    Section(recipe.title) {
                        ForEach(Array(recipe.warnings.enumerated()), id: \.offset) { _, warning in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text(warning).font(.caption)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
        .navigationTitle("Recipe files")
    }

    /// Grouped by file, since one bad file usually produces several complaints
    /// and a flat list of them reads as several broken files.
    private var grouped: [(String, [ContentDiagnostic])] {
        Dictionary(grouping: loader.diagnostics, by: \.fileName)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}
