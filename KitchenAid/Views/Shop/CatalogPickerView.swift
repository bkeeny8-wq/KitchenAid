import SwiftUI

/// Picking an ingredient out of the shipped catalogue, which is the whole reason the
/// catalogue exists: **adding something must be picking, not typing.** He is not going to
/// populate a few hundred ingredients by hand, and an app that asks him to is an app he stops
/// opening — so the aisle, the dimension and the unit all arrive with the entry and he types
/// none of them.
///
/// Ordered by the walk order shipped inside `ingredients.json`, not alphabetically, because
/// that is the order the list itself is in and two orders for one set of aisles is two things
/// to learn. `IngredientCatalog.aisleNames` already puts an aisle the walk order does not name
/// at the end, so nothing is unreachable.
struct CatalogPickerView: View {
    let title: String
    let onPick: (CatalogEntry) -> Void

    @Environment(IngredientCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""

    var body: some View {
        List {
            if catalog.isEmpty {
                Section {
                    EmptyStateView(
                        kind: .somethingWrong,
                        symbol: "questionmark.folder",
                        headline: "The catalogue did not load",
                        detail: "ingredients.json ships with the app and is read at launch. "
                              + "Without it there is nothing to pick from, so an item added "
                              + "now would carry no aisle and no unit."
                    )
                }
            } else if !trimmedSearch.isEmpty {
                Section {
                    ForEach(matches) { entry in
                        row(entry)
                    }
                } header: {
                    Text(matches.isEmpty ? "No match" : "\(matches.count) matching")
                }
            } else {
                ForEach(catalog.aisleNames, id: \.self) { aisle in
                    Section(aisle) {
                        ForEach(catalog.entries(inAisle: aisle)) { entry in
                            row(entry)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search ingredients")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func row(_ entry: CatalogEntry) -> some View {
        Button {
            onPick(entry)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .foregroundStyle(.primary)
                    // The unit is shown because it is what the line will be counted in, and
                    // "cloves" vs "heads" is a distinction the arithmetic takes seriously:
                    // they are separate aggregation buckets and nothing converts between them.
                    Text(subtitle(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if entry.staple {
                    Text("staple")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.name)
        .accessibilityValue(subtitle(entry))
    }

    private func subtitle(_ entry: CatalogEntry) -> String {
        let unitName = entry.defaultUnit?.plural ?? entry.unit
        if entry.staple {
            // Staples carry no quantity anywhere in the app, so offering one a unit here
            // would be the one screen that disagrees.
            return "\(entry.aisle) \u{00B7} tracked present or absent"
        }
        return unitName.isEmpty ? entry.aisle : "\(entry.aisle) \u{00B7} \(unitName)"
    }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Name first, then aliases, which is how the catalogue itself resolves a name — so
    /// searching "green onions" finds scallions rather than nothing.
    private var matches: [CatalogEntry] {
        let needle = trimmedSearch.lowercased()
        return catalog.all.filter { entry in
            if entry.name.lowercased().contains(needle) { return true }
            return entry.aliases.contains { $0.lowercased().contains(needle) }
        }
    }
}
