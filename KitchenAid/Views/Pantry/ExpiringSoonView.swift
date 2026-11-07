import SwiftUI
import SwiftData

/// What is about to go bad — the single most useful inventory screen, and the reason lots
/// exist at all. A scalar "2 lb of butter" cannot answer it; two lots with two dates can.
///
/// The window is his to change, because a week is right for the fridge and useless for the
/// freezer.
struct ExpiringSoonView: View {
    @Environment(\.modelContext) private var context
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    /// Here only so the body re-runs when a lot changes: the list itself comes from
    /// `InventoryLedger.expiringSoon`, which filters in Swift because `expiresAt` is optional
    /// and an optional-binding comparison is not a shape worth asking an unbuildable macro to
    /// translate.
    @Query private var allLots: [StockLot]

    @State private var days = 7
    @State private var wasting: StockLot?

    private static let windows = [3, 7, 14, 30]

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        List {
            Section {
                Picker("Within", selection: $days) {
                    ForEach(ExpiringSoonView.windows, id: \.self) { window in
                        Text("\(window) days").tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("How far ahead to look")
            }

            if lots.isEmpty {
                Section { nothing }
            } else {
                Section {
                    ForEach(lots) { lot in
                        NavigationLink {
                            StockLotView(lot: lot)
                        } label: {
                            row(lot)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                wasting = lot
                            } label: {
                                Label("Threw it out", systemImage: "trash")
                            }
                            .disabled(lot.isOrphaned)
                        }
                    }
                } footer: {
                    Text("Lots with no best-by are not here, because a lot with no date never "
                         + "expires. Inventing one would put a guess inside a number you "
                         + "shop by.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Going off")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $wasting) { lot in
            NavigationStack {
                if let item = lot.item {
                    AdjustStockSheet(
                        item: item,
                        lot: lot,
                        kind: .waste,
                        prefill: lot.remaining
                    )
                } else {
                    EmptyStateView(
                        kind: .somethingWrong,
                        symbol: "questionmark.folder",
                        headline: "This lot has no item",
                        detail: "It outlived the item it belonged to, which is why it is "
                              + "still readable. Nothing can be posted against it until it "
                              + "is pointed at an item again."
                    )
                }
            }
        }
    }

    @MainActor
    private var lots: [StockLot] {
        (try? ledger.expiringSoon(within: days, in: context)) ?? []
    }

    @MainActor
    private func row(_ lot: StockLot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(lot.itemDisplayName).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(lot.remaining?.displayString(system: ledger.unitSystem) ?? "\u{2014}")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(PantryLevels.expiryText(for: lot))
                if let place = lot.location { Text("\u{00B7} \(place.displayName)") }
                if !lot.label.isEmpty { Text("\u{00B7} \(lot.label)") }
            }
            .font(.caption)
            .foregroundStyle(lot.isExpired() ? .orange : .secondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var nothing: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "checkmark.circle",
            headline: "Nothing is near its date",
            detail: "Nothing with a best-by inside \(days) days has anything left in it."
        )
    }
}
