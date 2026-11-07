import SwiftUI
import SwiftData

/// What has fallen below the minimum he wants kept on hand.
///
/// A par level is the one thing in the pantry that puts something on a shopping list **by a
/// rule** rather than by him remembering to flag it: `LineSourceKind.parLevel` exists for
/// exactly this, and `ShoppingListBuilder` takes the shortfalls as an argument rather than
/// working them out itself. `PantryLevels.parStatus` is that computation, and this screen is
/// the place it is visible before a list is built.
struct BelowParView: View {
    @Environment(\.modelContext) private var context
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    @Query private var items: [FoodItem]

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        List {
            if rows.isEmpty && staplesOut.isEmpty {
                Section { nothing }
            }

            if !rows.isEmpty {
                Section {
                    ForEach(rows) { row in
                        NavigationLink {
                            FoodItemDetailView(item: row.item)
                        } label: {
                            rowView(row)
                        }
                    }
                } header: {
                    Text("Below par")
                } footer: {
                    Text("What is on hand is summed from the ledger and taken off the par "
                         + "with the same arithmetic the shopping list uses, so the number "
                         + "here is the number that would be bought.")
                }
            }

            if !staplesOut.isEmpty {
                Section {
                    ForEach(staplesOut) { item in
                        NavigationLink {
                            FoodItemDetailView(item: item)
                        } label: {
                            HStack {
                                Text(item.displayName)
                                Spacer(minLength: 8)
                                Text("Out").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                } header: {
                    Text("Staples to restock")
                } footer: {
                    Text("Staples have no par level because they have no amount \u{2014} "
                         + "they are present or absent, and these are the ones switched off.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Running low")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private var rows: [PantryLevels.ParRow] {
        PantryLevels.belowPar(in: items, using: ledger)
    }

    private var staplesOut: [FoodItem] {
        PantryLevels.staplesOut(in: items)
    }

    @MainActor
    private func rowView(_ row: PantryLevels.ParRow) -> some View {
        let system = ledger.unitSystem
        let level = PantryLevels.level(of: row.item, using: ledger)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.item.displayName).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(level.text)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(level.isEmpty ? .secondary : .primary)
            }
            if row.status.cannotCompare {
                // Honest rather than numeric: the par and the stock are in dimensions no
                // density can bridge, so nothing was counted against the par and a
                // "short by" figure here would be the whole par masquerading as a
                // measurement.
                Text("Par is \(row.status.parText(system: system)), and what is on hand is "
                     + "measured differently. Set a weight per cup to compare them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Short by \(row.status.shortfallText(system: system)) of a par of "
                     + "\(row.status.parText(system: system))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FlagBadgeRow(flags: row.status.flags.union([.parLevel]))
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var nothing: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "checkmark.circle",
            headline: "Nothing is running low",
            detail: "Everything with a par level is at or above it, and no staple is "
                  + "switched off."
        )
    }
}
