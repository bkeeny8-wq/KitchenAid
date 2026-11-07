import SwiftUI
import SwiftData

/// What the house has.
///
/// Brandon chose the **full ledger** over a simple current-amount pantry, knowing it was ~8
/// models: lots with purchase dates, a transaction for every add and depletion, par levels
/// and reconciliation. The cost of that choice is paid here or not at all — a screen that
/// merely exposes the tables is a tax, and a screen that makes them legible is the reason he
/// picked them. So the order is: what needs doing, then what is where, then the tools.
///
/// **Every number on this screen is summed from transactions**, through
/// `PantryLevels.level(of:in:using:)` into `InventoryLedger.level`. Nothing adds up
/// `StockLot.remaining`; see the comment at the top of `PantryLevels`.
struct PantryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.storeUnavailable) private var storeUnavailable

    /// Optional, because the App builds `InventoryLedger` in its launch task rather than in
    /// `init()` — it is `@MainActor` — and a non-optional `@Environment` lookup traps while
    /// the value is absent. The window is short and real. Same shape as `CookView`'s
    /// `TweakStore`.
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    /// Bare and filtered in Swift, exactly as `PlanWeekView` and `TodayView` do it. These
    /// are also what makes the screen live: the two standing queues below are answered by
    /// the ledger rather than by a `@Query`, and it is these fetches re-running that brings
    /// the body back after a write.
    @Query private var items: [FoodItem]
    @Query private var locations: [StorageLocation]
    @Query private var lots: [StockLot]

    @State private var isAddingStock = false

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        List {
            if storeUnavailable { storeWarning }
            if isEmptyKitchen {
                Section { emptyKitchen }
            } else {
                attention
                ForEach(PantryLevels.groups(locations: locations, items: items)) { group in
                    locationSection(group)
                }
                staplesSection
                unstockedSection
            }
            tools
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pantry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingStock = true
                } label: {
                    Image(systemName: "plus")
                }
                // An icon-only button says nothing to VoiceOver without this.
                .accessibilityLabel("Add stock")
            }
        }
        .sheet(isPresented: $isAddingStock) {
            NavigationStack {
                AddStockSheet()
            }
        }
    }

    // MARK: - What needs doing

    /// The three standing queues, and they are the reason the ledger is worth its weight:
    /// each one is a question a scalar `onHand` could not ask.
    ///
    /// Computed in `body` rather than cached in `@State`. A home pantry is a few hundred
    /// rows — the same judgement `InventoryLedger.expiringSoon` makes about filtering in
    /// Swift instead of in a `#Predicate` — and a cached count is a count that can disagree
    /// with the screen it is on.
    @MainActor
    @ViewBuilder
    private var attention: some View {
        let short = PantryLevels.belowPar(in: items, using: ledger)
        let expiring = (try? ledger.expiringSoon(within: 7, in: context)) ?? []
        let pending = (try? ledger.pendingBridgeTransactions(in: context)) ?? []
        let staplesOut = PantryLevels.staplesOut(in: items)

        if !short.isEmpty || !expiring.isEmpty || !pending.isEmpty || !staplesOut.isEmpty {
            Section {
                if !expiring.isEmpty {
                    NavigationLink {
                        ExpiringSoonView()
                    } label: {
                        attentionRow(
                            symbol: "clock.badge.exclamationmark",
                            tint: .orange,
                            title: expiring.count == 1
                                ? "1 lot is near its date"
                                : "\(expiring.count) lots are near their date",
                            detail: "Within a week. The oldest goes first when you cook."
                        )
                    }
                }
                if !pending.isEmpty {
                    NavigationLink {
                        PendingDepletionsView()
                    } label: {
                        attentionRow(
                            symbol: "questionmark.circle",
                            tint: .orange,
                            title: pending.count == 1
                                ? "1 unresolved depletion"
                                : "\(pending.count) unresolved depletions",
                            detail: "Food was used and the app could not work out how much. "
                                  + "It recorded the question instead of guessing."
                        )
                    }
                }
                if !short.isEmpty {
                    NavigationLink {
                        BelowParView()
                    } label: {
                        attentionRow(
                            symbol: "arrow.down.to.line",
                            tint: .purple,
                            title: short.count == 1
                                ? "1 item below par"
                                : "\(short.count) items below par",
                            detail: shortNames(short)
                        )
                    }
                }
                if !staplesOut.isEmpty {
                    attentionRow(
                        symbol: "basket",
                        tint: .purple,
                        title: staplesOut.count == 1
                            ? "1 staple to restock"
                            : "\(staplesOut.count) staples to restock",
                        detail: staplesOut.map { $0.displayName }.joined(separator: ", ")
                    )
                }
            } header: {
                Text("Worth a look")
            }
        }
    }

    private func attentionRow(
        symbol: String, tint: Color, title: String, detail: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func shortNames(_ rows: [PantryLevels.ParRow]) -> String {
        let names = rows.prefix(4).map { $0.item.displayName }
        let rest = rows.count - names.count
        let joined = names.joined(separator: ", ")
        return rest > 0 ? "\(joined) and \(rest) more" : joined
    }

    // MARK: - What is where

    @MainActor
    private func locationSection(_ group: PantryLevels.LocationGroup) -> some View {
        Section {
            ForEach(group.items) { item in
                NavigationLink {
                    FoodItemDetailView(item: item)
                } label: {
                    itemRow(item, in: group.location)
                }
            }
        } header: {
            Label(group.title, systemImage: group.symbol)
        } footer: {
            if group.location == nil {
                // Reachable, so it is explained rather than looking like a bug.
                Text("These lots are not filed under a place. Deleting a location keeps its "
                     + "lots \u{2014} the level never changed \u{2014} and they land here "
                     + "until you move them.")
            } else if let shelfLife = group.location?.defaultShelfLifeDays {
                Text("New lots here are given a best-by \(shelfLife) days out, which you can "
                     + "change on the lot.")
            }
        }
    }

    /// Name, level, and the badges that explain the level. The badge comes from
    /// `LineFlag.badge` through `FlagBadgeRow`, so the wording is the one the shopping list
    /// and the PDF use.
    @MainActor
    private func itemRow(_ item: FoodItem, in location: StorageLocation?) -> some View {
        let level = PantryLevels.level(of: item, in: location, using: ledger)
        let par = PantryLevels.parStatus(for: item, using: ledger)
        var flags = level.flags
        if let par = par, par.isBelow { flags.insert(.parLevel) }

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.displayName)
                Spacer(minLength: 8)
                Text(level.text)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(level.isEmpty ? .secondary : .primary)
            }
            if let par = par, par.isBelow {
                Text(parDetail(par))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FlagBadgeRow(flags: flags)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.displayName), \(level.text)")
    }

    @MainActor
    private func parDetail(_ par: PantryLevels.ParStatus) -> String {
        let system = ledger.unitSystem
        if par.cannotCompare {
            return "Par is \(par.parText(system: system)), and what is on hand is measured "
                 + "differently. Set a weight per cup to compare them."
        }
        return "\(par.shortfallText(system: system)) below a par of "
             + par.parText(system: system)
    }

    // MARK: - Staples

    /// Present or absent, with **no quantity** — Brandon's decision, and the reason there is
    /// a toggle here and not a number. Counting teaspoons of salt is work nobody does, and a
    /// list that keeps asking for salt is a list you stop reading.
    @MainActor
    @ViewBuilder
    private var staplesSection: some View {
        let staples = PantryLevels.staples(in: items)
        if !staples.isEmpty {
            Section {
                ForEach(staples) { item in
                    Toggle(isOn: staplePresence(item)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName)
                            if item.isRunningLow {
                                Text("On the next list")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    // The toggle already announces its own on/off state; the label only
                    // needs to be the name, without the "on the next list" line under it.
                    .accessibilityLabel(item.displayName)
                }
            } header: {
                Text(staplesHeader(staples))
            } footer: {
                Text("Salt, pepper, oils, vinegars and every spice are tracked present or "
                     + "absent, with no amount. Switch one off and it joins the next "
                     + "shopping list.")
            }
        }
    }

    private func staplesHeader(_ staples: [FoodItem]) -> String {
        let out = staples.filter { $0.isRunningLow }.count
        return out == 0 ? "Staples" : "Staples \u{00B7} \(out) to restock"
    }

    private func staplePresence(_ item: FoodItem) -> Binding<Bool> {
        Binding(
            get: { !item.isRunningLow },
            set: { PantryEditor.setStaplePresent(item, isPresent: $0, in: context) }
        )
    }

    // MARK: - Items with nothing on a shelf

    @MainActor
    @ViewBuilder
    private var unstockedSection: some View {
        let rows = PantryLevels.unstocked(in: items)
        if !rows.isEmpty {
            Section {
                ForEach(rows) { item in
                    NavigationLink {
                        FoodItemDetailView(item: item)
                    } label: {
                        itemRow(item, in: nil)
                    }
                }
            } header: {
                Text("Not stocked")
            } footer: {
                Text("Known items with no lot in the house \u{2014} usually something a "
                     + "shopping list matched and you have not put away yet. Their history "
                     + "is intact.")
            }
        }
    }

    // MARK: - Tools

    @ViewBuilder
    private var tools: some View {
        Section {
            NavigationLink {
                StorageLocationsView()
            } label: {
                toolRow(
                    symbol: "cabinet",
                    title: "Places",
                    detail: locations.isEmpty
                        ? "None yet. Add the fridge, the freezer, the pantry."
                        : PantryLevels.ordered(locations)
                            .map { $0.displayName }
                            .joined(separator: ", ")
                )
            }
            NavigationLink {
                ReconcileReportView()
            } label: {
                toolRow(
                    symbol: "checkmark.gobackward",
                    title: "Reconcile",
                    detail: "Compare every lot's cached amount against the transactions it "
                          + "was summed from."
                )
            }
            NavigationLink {
                ExpiringSoonView()
            } label: {
                toolRow(
                    symbol: "clock.badge.checkmark",
                    title: "What is about to go bad",
                    detail: "By date, oldest first."
                )
            }
        } header: {
            Text("The ledger")
        } footer: {
            Text("Every change is a row that is never deleted, so \u{201C}why does it think "
                 + "I have three pounds of butter\u{201D} always has an answer.")
        }

        scanning
    }

    /// **Asked for, not built**, and said so plainly rather than shown as a button that does
    /// nothing. Brandon asked for both after seeing the design, so they are intended work and
    /// not speculation — and the barcode note is load-bearing: a barcode is only a number, so
    /// there is no design here that assumes a lookup service exists.
    @ViewBuilder
    private var scanning: some View {
        Section {
            NavigationLink {
                UnbuiltFeatureView(
                    title: "Receipt scanning",
                    detail: "The plan is on-device text recognition with the Vision "
                          + "framework, no network. Receipt text is abbreviated \u{2014} "
                          + "GV CRM CHS 8Z \u{2014} so it would be matched against the "
                          + "ingredient catalogue and its aliases, and ask about what it "
                          + "cannot place once, then remember. None of that is written yet."
                )
            } label: {
                toolRow(
                    symbol: "doc.text.viewfinder",
                    title: "Scan a receipt",
                    detail: "Asked for, not built."
                )
            }
            NavigationLink {
                UnbuiltFeatureView(
                    title: "Barcode scanning",
                    detail: "A barcode is only a number. Turning one into "
                          + "\u{201C}heavy cream\u{201D} needs a commercial product "
                          + "database, which means a subscription and a network call this "
                          + "app does not have. So the first scan of an item would ask what "
                          + "it is and every later scan would fill itself in \u{2014} the "
                          + "kitchen becomes its own database. Not written yet."
                )
            } label: {
                toolRow(
                    symbol: "barcode.viewfinder",
                    title: "Scan a barcode",
                    detail: "Asked for, not built."
                )
            }
        }
    }

    private func toolRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Empty

    private var isEmptyKitchen: Bool { items.isEmpty && lots.isEmpty }

    private var emptyKitchen: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "archivebox",
            headline: "Nothing in the pantry yet",
            detail: "Add what is already in the house and the shopping list can start "
                  + "subtracting it. Everything is picked from the ingredient catalogue, so "
                  + "there is nothing to type.",
            actionTitle: "Add stock",
            action: { isAddingStock = true }
        )
    }

    private var storeWarning: some View {
        Section {
            Text("The database could not be opened, so anything added now will be gone when "
                 + "the app closes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
