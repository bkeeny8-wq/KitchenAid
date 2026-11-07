import SwiftUI
import SwiftData

/// The unresolved-depletions inbox, badged on the Pantry tab rather than buried in settings,
/// because a standing queue nobody sees goes stale and quietly makes the next shopping list
/// wrong.
///
/// Every row here is a cook depletion the app **recorded without answering**: the recipe
/// asked for a volume, the stock is a weight, and the item carries no grams-per-cup to get
/// between them. A skipped depletion would be an invisible overstatement of stock and a
/// guessed one a silent lie, so the app writes the question down — `hasDelta == false`,
/// `.pendingBridge` — and asks here.
struct PendingDepletionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    /// Reactivity only; the rows come from the service's own predicate fetch.
    @Query private var allItems: [FoodItem]

    @State private var resolving: InventoryTransaction?

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Section { nothing }
            } else {
                Section {
                    ForEach(rows) { row in
                        Button {
                            resolving = row
                        } label: {
                            rowView(row)
                        }
                        .buttonStyle(.plain)
                        .disabled(row.item == nil)
                    }
                } footer: {
                    Text("Until one is answered it counts as nothing, so what you have is "
                         + "overstated by whatever was actually used. Answering it writes "
                         + "the amount and nothing else changes.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Unresolved")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $resolving) { row in
            NavigationStack {
                if let item = row.item {
                    ResolveDepletionSheet(transaction: row, item: item)
                } else {
                    EmptyStateView(
                        kind: .somethingWrong,
                        symbol: "questionmark.folder",
                        headline: "This row has no item",
                        detail: "It outlived the item it was filed against, which is why it "
                              + "is still readable. There is nothing left to take an amount "
                              + "off."
                    )
                }
            }
        }
    }

    @MainActor
    private var rows: [InventoryTransaction] {
        (try? ledger.pendingBridgeTransactions(in: context)) ?? []
    }

    private func rowView(_ transaction: InventoryTransaction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(transaction.itemDisplayName).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                FlagBadge(flag: .needsBridge)
            }
            // The note the ledger wrote carries the amount the recipe asked for — "used
            // 2 tbsp; needs a weight per cup before it can be taken off a lot" — which is
            // the single most useful thing on the row.
            if !transaction.note.isEmpty {
                Text(transaction.note).font(.caption).foregroundStyle(.secondary)
            }
            Text(provenance(transaction)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// Cook provenance from the snapshots on the row. No cook log exists and none is wanted
    /// — Brandon declined the journal — and two snapshot strings answer "where did the cream
    /// go" without one.
    private func provenance(_ transaction: InventoryTransaction) -> String {
        var parts = [PantryLevels.dayText(transaction.occurredAt)]
        if !transaction.recipeTitleSnapshot.isEmpty {
            parts.append(transaction.recipeTitleSnapshot)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var nothing: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "checkmark.circle",
            headline: "Nothing unresolved",
            detail: "Every depletion the app has recorded has an amount on it."
        )
    }
}

/// Answering one inbox row.
///
/// Two routes out, and the second is the better one: enter what came off the shelf, or give
/// the item a weight per cup so this and every future depletion of it resolve themselves.
/// `InventoryLedger.resolve` moves the delta and the state together and rebuilds the lot
/// cache, because a row that starts counting without its cache being rebuilt is a divergence
/// the app created itself.
private struct ResolveDepletionSheet: View {
    let transaction: InventoryTransaction
    let item: FoodItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(IngredientCatalog.self) private var catalog
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    @State private var amount: Rational = .zero
    @State private var unit: KitchenUnit = UnitCatalog.each
    @State private var didSeed = false

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        Form {
            Section {
                Text(transaction.note.isEmpty
                     ? "The app could not work out how much of this was used."
                     : transaction.note)
                    .font(.subheadline)
            } header: {
                Text(item.displayName)
            }

            Section {
                QuantityField(
                    label: "Came off the shelf",
                    value: $amount,
                    unitName: unit.name(for: amount)
                )
                UnitPicker(
                    label: "Unit",
                    dimension: unit.dimension,
                    countNoun: unit.isCount ? unit.code : "",
                    system: ledger.unitSystem,
                    unit: $unit
                )
            } footer: {
                Text("Enter it in the unit your stock is measured in \u{2014} that is the "
                     + "side the amount has to come off.")
            }

            Section {
                NavigationLink {
                    FoodItemDetailView(item: item)
                } label: {
                    Label("Set a weight per cup instead", systemImage: "scalemass")
                }
                .frame(minHeight: 44)
            } footer: {
                Text("One number on the item fixes this row and every future one, because "
                     + "the app can then convert between cups and grams by itself rather "
                     + "than asking.")
            }
        }
        .navigationTitle("How much?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Record") { record() }
                    .disabled(amount.isZero || unit.baseFactor == .zero)
            }
        }
        .onAppear { seedOnce() }
    }

    @MainActor
    private func seedOnce() {
        guard !didSeed else { return }
        didSeed = true
        // The unit the stock is actually in, because the whole problem is that the
        // requirement was written in a different one.
        if let stockUnit = item.orderedLots.compactMap({ $0.remaining?.unit }).first {
            unit = stockUnit
        } else {
            unit = catalog.entry(named: item.catalogName)?.defaultUnit ?? UnitCatalog.each
        }
    }

    /// Negated here. He types "4 oz" — the amount that left the kitchen — and a depletion is
    /// a negative row. `PantryLevels.isDepletion` decides from the kind rather than this
    /// screen assuming, because a `.pendingBridge` row is written by `depleteForCook` today
    /// and could be written by a receive tomorrow.
    @MainActor
    private func record() {
        let entered = Quantity(amount: amount, unit: unit)
        let delta = PantryLevels.isDepletion(transaction.kind)
            ? Quantity(amount: entered.amount.negated, unit: entered.unit)
            : entered
        ledger.resolve(transaction, withDelta: delta, in: context)
        dismiss()
    }
}
