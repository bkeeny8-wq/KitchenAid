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

    var body: some View {
        List {
            Section {
                Text("These files are in the app but could not be used. Everything else "
                     + "loaded normally.")
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

            if loader.diagnostics.isEmpty {
                Section {
                    Label("Every recipe file loaded cleanly", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
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
