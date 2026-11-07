import SwiftUI
import SwiftData

/// The Shop tab. It opens on the list he is shopping, not on a library of lists.
///
/// There is at most one live list by construction: building a new one archives the one it
/// replaces (see `GenerateShoppingListSheet`), so "the current list" is a fact rather than a
/// guess. Everything older is under Past lists, where a list he shopped in November still
/// reads as it did in November — the numbers, the units and the aisle order are all
/// snapshotted onto its rows.
struct ShopView: View {
    @Query(
        filter: #Predicate<ShoppingList> { $0.isArchived == false },
        sort: \ShoppingList.generatedAt,
        order: .reverse
    )
    private var liveLists: [ShoppingList]

    @State private var isBuilding = false

    var body: some View {
        Group {
            if let list = liveLists.first {
                ShoppingListDetailView(list: list)
            } else {
                empty
            }
        }
        .sheet(isPresented: $isBuilding) {
            GenerateShoppingListSheet()
        }
    }

    @ViewBuilder
    private var empty: some View {
        EmptyStateView(
            symbol: "cart",
            headline: "No list yet",
            detail: "A list is built from the meals on the plan: every recipe's ingredients, "
                  + "merged across the week, scaled for whoever is eating, with what the "
                  + "pantry already has subtracted.",
            actionTitle: "Build one from the plan",
            action: { isBuilding = true }
        )
        .navigationTitle("Shop")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ShoppingListArchiveView()
                } label: {
                    Text("Past lists")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ExportCenterView()
                } label: {
                    Image(systemName: "printer")
                }
                .accessibilityLabel("Print or share")
            }
        }
    }
}

/// Every list he has finished, newest first. A historical document: nothing here is recomputed
/// on view, which is why a revised recipe cannot change what a list said in the aisle.
struct ShoppingListArchiveView: View {
    @Query(sort: \ShoppingList.generatedAt, order: .reverse)
    private var lists: [ShoppingList]

    var body: some View {
        List {
            if archived.isEmpty {
                Section {
                    EmptyStateView(
                        symbol: "archivebox",
                        headline: "Nothing archived yet",
                        detail: "A list moves here when you build its replacement, or when "
                              + "you archive it by hand."
                    )
                }
            }
            ForEach(archived) { list in
                NavigationLink {
                    ShoppingListDetailView(list: list)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(list.title.isEmpty ? "Shopping" : list.title)
                        Text(subtitle(list))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Past lists")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var archived: [ShoppingList] { lists.filter { $0.isArchived } }

    private func subtitle(_ list: ShoppingList) -> String {
        let lines = list.orderedLines
        let checked = lines.filter { $0.isChecked }.count
        var parts = ["\(lines.count) item\(lines.count == 1 ? "" : "s")"]
        if checked > 0 { parts.append("\(checked) checked off") }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        parts.append(formatter.string(from: list.generatedAt))
        return parts.joined(separator: " \u{00B7} ")
    }
}
