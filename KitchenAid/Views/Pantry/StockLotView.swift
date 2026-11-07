import SwiftUI
import SwiftData

/// One physical lot: this bag of flour, in this place, with this best-by.
///
/// The amount shown here is the lot's **cache**, `StockLot.remaining`, and that is said out
/// loud on the screen. It exists because "do I have enough butter" runs on every list build
/// and every recipe render, and summing a multi-year log per item per render is not viable.
/// A cache that drifts silently is worse than none; this one reports its own drift, and the
/// reconcile report is where the drift is attributable. Rebuilding one lot from its rows is a
/// button here rather than something that happens behind his back.
struct StockLotView: View {
    let lot: StockLot

    @Environment(\.modelContext) private var context
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    @Query private var locations: [StorageLocation]

    @State private var isWasting = false
    @State private var confirmDelete = false

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        List {
            amountSection
            placeSection
            dateSection
            rowsSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isWasting) {
            NavigationStack {
                if let item = lot.item {
                    // Prefilled with everything the lot has left, because "it went off" is
                    // almost always the whole thing — and a wrong prefill is one tap to
                    // change, where an empty field is five.
                    AdjustStockSheet(
                        item: item,
                        lot: lot,
                        kind: .waste,
                        prefill: lot.remaining
                    )
                } else {
                    // `item` is `.nullify`, so a stray item delete leaves the lot behind
                    // rather than destroying it. It stays readable through
                    // `foodItemNameSnapshot`, but there is no item to post a row against.
                    EmptyStateView(
                        kind: .somethingWrong,
                        symbol: "questionmark.folder",
                        headline: "This lot has no item",
                        detail: "It was kept when its item was deleted, which is why it is "
                              + "still here and still readable. Nothing can be posted "
                              + "against it until it is pointed at an item again."
                    )
                }
            }
        }
        .confirmationDialog(
            "Delete this lot?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete the lot", role: .destructive) {
                PantryEditor.delete(lot, in: context)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its \(rowCount) ledger \(rowCount == 1 ? "row" : "rows") stay, so the "
                 + "amount on hand does not change \u{2014} they move to the unassigned "
                 + "bucket in the reconcile report, where you can file them against another "
                 + "lot.")
        }
    }

    private var title: String {
        lot.label.isEmpty ? lot.itemDisplayName : lot.label
    }

    private var rowCount: Int { (lot.transactions ?? []).count }

    // MARK: - Amount

    @MainActor
    @ViewBuilder
    private var amountSection: some View {
        Section {
            HStack {
                Text("On hand")
                Spacer(minLength: 8)
                Text(lot.remaining?.displayString(system: ledger.unitSystem) ?? "Unknown")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(minHeight: 44)
            if let original = lot.original {
                HStack {
                    Text("Bought as")
                    Spacer(minLength: 8)
                    Text(original.displayString(system: ledger.unitSystem))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(minHeight: 44)
            }
            if let cents = lot.unitCostCents {
                HStack {
                    Text("Cost")
                    Spacer(minLength: 8)
                    Text(PantryEditor.priceText(cents)).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text(lot.itemDisplayName)
        } footer: {
            // "Unknown" is a real state and not an error: no countable rows means nothing is
            // known about this lot, which is different from zero on hand.
            Text("A cached figure, rebuilt from this lot's own rows "
                 + "\(PantryLevels.dayText(lot.cacheRebuiltAt)). The amount the pantry "
                 + "reports is summed from the item's transactions, which is why the two can "
                 + "disagree and why the reconcile report exists.")
        }
    }

    // MARK: - Where

    @ViewBuilder
    private var placeSection: some View {
        Section {
            Picker("Place", selection: placeSelection) {
                Text("No place").tag(nil as UUID?)
                ForEach(PantryLevels.ordered(locations)) { place in
                    Text(place.displayName).tag(place.id as UUID?)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
        } header: {
            Text("Where it is")
        }
    }

    private var placeSelection: Binding<UUID?> {
        Binding(
            get: { lot.location?.id },
            set: { newID in
                PantryEditor.move(lot, to: locations.first { $0.id == newID }, in: context)
            }
        )
    }

    // MARK: - Dates

    @ViewBuilder
    private var dateSection: some View {
        Section {
            HStack {
                Text("Bought")
                Spacer(minLength: 8)
                Text(PantryLevels.dayText(lot.acquiredAt)).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)

            Toggle("Has a best-by", isOn: expiryToggle)
                .frame(minHeight: 44)
            if lot.expiresAt != nil {
                DatePicker("Best by", selection: expiryDate, displayedComponents: .date)
                    .frame(minHeight: 44)
                Text(PantryLevels.expiryText(for: lot))
                    .font(.caption)
                    .foregroundStyle(lot.isExpired() ? .orange : .secondary)
            }

            Toggle("Opened", isOn: openToggle)
                .frame(minHeight: 44)
        } header: {
            Text("Dates")
        } footer: {
            Text("An open lot is drawn down before an unopened one, and the oldest in-date "
                 + "lot goes first \u{2014} you finish the open butter before cutting a new "
                 + "stick.")
        }
    }

    private var expiryToggle: Binding<Bool> {
        Binding(
            get: { lot.expiresAt != nil },
            set: { wantsDate in
                let suggested = lot.location?.suggestedExpiry(from: lot.acquiredAt)
                PantryEditor.setExpiry(
                    lot,
                    to: wantsDate ? (suggested ?? lot.acquiredAt) : nil,
                    in: context
                )
            }
        )
    }

    private var expiryDate: Binding<Date> {
        Binding(
            get: { lot.expiresAt ?? lot.acquiredAt },
            set: { PantryEditor.setExpiry(lot, to: $0, in: context) }
        )
    }

    private var openToggle: Binding<Bool> {
        Binding(
            get: { lot.isOpen },
            set: { PantryEditor.setOpen(lot, isOpen: $0, in: context) }
        )
    }

    // MARK: - The rows behind the number

    @MainActor
    @ViewBuilder
    private var rowsSection: some View {
        let rows = lot.orderedTransactions
        Section {
            if rows.isEmpty {
                Text("No rows filed against this lot.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PantryLevels.title(for: row.kind))
                                .font(.subheadline.weight(.medium))
                            Text(PantryLevels.dayText(row.occurredAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(PantryLevels.amountText(for: row, system: ledger.unitSystem))
                            .monospacedDigit()
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("What this lot is made of")
        }
    }

    // MARK: - Actions

    @MainActor
    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                isWasting = true
            } label: {
                Label("Throw it out", systemImage: "trash")
            }
            .frame(minHeight: 44)
            // An orphaned lot has no item to post a waste row against.
            .disabled(lot.isOrphaned)

            Button {
                // One lot, rebuilt from its own rows. The same call `rebuildAllCaches` makes
                // per lot, offered here so a single disagreement can be fixed where it is
                // visible instead of by rebuilding the whole store.
                ledger.recompute(lot: lot)
                try? context.save()
            } label: {
                Label("Rebuild this amount from the rows", systemImage: "arrow.clockwise")
            }
            .frame(minHeight: 44)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete the lot", systemImage: "xmark.bin")
            }
            .frame(minHeight: 44)
        }
    }
}
