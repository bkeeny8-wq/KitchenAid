import SwiftUI
import SwiftData

/// One item: what is on hand, which lots it is in, and every row that ever moved it.
///
/// This is the screen that answers the question the ledger was built for — *"why does it
/// think I have three pounds of butter?"* A scalar `onHand` has no answer to that. The
/// history at the bottom is the answer, and it is append-only, so nothing has been quietly
/// pruned out of it.
struct FoodItemDetailView: View {
    let item: FoodItem

    @Environment(\.modelContext) private var context
    @Environment(IngredientCatalog.self) private var catalog
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    @State private var isAddingStock = false
    @State private var isAdjusting = false
    @State private var isSettingPar = false
    @State private var isSettingDensity = false
    @State private var showsAllHistory = false

    /// How many rows the history shows before it offers the rest. The ledger is a multi-year
    /// log by design; rendering all of it to answer "what happened lately" is work for
    /// nothing.
    private static let historyWindow = 25

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        List {
            levelSection
            if item.isStaple {
                stapleSection
            } else {
                parSection
                densitySection
                lotsSection
            }
            historySection
            aliasSection
            notesSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingStock) {
            NavigationStack {
                AddStockSheet(item: item)
            }
        }
        .sheet(isPresented: $isAdjusting) {
            NavigationStack {
                AdjustStockSheet(item: item)
            }
        }
        .sheet(isPresented: $isSettingPar) {
            NavigationStack {
                ParLevelSheet(item: item)
            }
        }
        .sheet(isPresented: $isSettingDensity) {
            NavigationStack {
                DensitySheet(item: item)
            }
        }
    }

    // MARK: - Level

    @MainActor
    @ViewBuilder
    private var levelSection: some View {
        let level = PantryLevels.level(of: item, using: ledger)
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(level.text)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                if !item.isStaple {
                    ForEach(byLocation) { row in
                        HStack {
                            Label(row.title, systemImage: row.symbol)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(row.text)
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        }
                    }
                }
                FlagBadgeRow(flags: level.flags)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        } header: {
            Text("On hand")
        } footer: {
            // Not a throwaway line: it is the one invariant of this screen, and a future
            // edit that "optimises" it by reading the lot caches would break the orphan case
            // silently.
            Text("Summed from this item's transactions, not from its lots, so a row whose "
                 + "lot was deleted still counts."
                 + (item.catalogName.isEmpty ? "" : " From the catalogue as \(item.catalogName)."))
        }
    }

    /// The per-place breakdown. Each number is its own `level(of:in:)` call, so each is
    /// summed from the transactions filed against that place's lots — never from the lots.
    ///
    /// The places come from this item's own lots rather than from every location in the
    /// store, so the breakdown lists where the food actually is instead of five zeroes.
    @MainActor
    private var byLocation: [PlaceLevel] {
        var seen = Set<UUID>()
        var out: [PlaceLevel] = []
        for lot in item.orderedLots {
            guard let place = lot.location else { continue }
            guard seen.insert(place.id).inserted else { continue }
            out.append(PlaceLevel(
                id: place.id,
                title: place.displayName,
                symbol: place.symbolName,
                text: PantryLevels.level(of: item, in: place, using: ledger).text
            ))
        }
        return out
    }

    // MARK: - Staple

    @ViewBuilder
    private var stapleSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { !item.isRunningLow },
                set: { PantryEditor.setStaplePresent(item, isPresent: $0, in: context) }
            )) {
                Text("In the house")
            }
            .frame(minHeight: 44)
            .accessibilityLabel("In the house")
        } footer: {
            Text("A staple is present or absent with no quantity, so there are no lots and "
                 + "no amounts here. Switch it off and it joins the next shopping list.")
        }
    }

    // MARK: - Par level

    @MainActor
    @ViewBuilder
    private var parSection: some View {
        let status = PantryLevels.parStatus(for: item, using: ledger)
        Section {
            Button {
                isSettingPar = true
            } label: {
                HStack {
                    Text("Keep at least")
                    Spacer(minLength: 8)
                    Text(status?.parText(system: ledger.unitSystem) ?? "Not set")
                        .foregroundStyle(status == nil ? .secondary : .primary)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Par level")
            .accessibilityValue(status?.parText(system: ledger.unitSystem) ?? "not set")

            if let status = status, status.isBelow {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    FlagBadge(flag: .parLevel)
                    Text(status.cannotCompare
                         ? "What is on hand is measured differently, so none of it was "
                           + "counted against the par."
                         : "Short by \(status.shortfallText(system: ledger.unitSystem)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Par level")
        } footer: {
            Text("A par level puts this on the shopping list by a rule when it runs low, "
                 + "rather than only when you remember to flag it.")
        }
    }

    // MARK: - Density

    /// Grams per cup, with the explanation, because this one number is the fix for three
    /// separate complaints: a depletion the app could not work out, a shopping line badged
    /// "needs weight per cup", and a par in cups it cannot compare to a pound in the freezer.
    @ViewBuilder
    private var densitySection: some View {
        Section {
            Button {
                isSettingDensity = true
            } label: {
                HStack {
                    Text("Weight per cup")
                    Spacer(minLength: 8)
                    Text(densityText)
                        .foregroundStyle(item.hasDensity ? .primary : .secondary)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Weight per cup")
            .accessibilityValue(densityText)
        } footer: {
            Text("Without it the app refuses to convert between cups and grams rather than "
                 + "guessing: a cup is 240 g of water, 120 g of flour and 340 g of honey, "
                 + "and guessing wrong is wrong inside a number you shop by.")
        }
    }

    private var densityText: String {
        guard let grams = item.gramsPerCup else { return "Not set" }
        return "\(grams.humanDescription) g"
    }

    // MARK: - Lots

    @MainActor
    @ViewBuilder
    private var lotsSection: some View {
        let lots = item.orderedLots
        Section {
            if lots.isEmpty {
                Text("No lots. Anything on hand is coming from rows filed against no lot.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lots) { lot in
                    NavigationLink {
                        StockLotView(lot: lot)
                    } label: {
                        lotRow(lot)
                    }
                }
            }
        } header: {
            Text(lots.count == 1 ? "1 lot" : "\(lots.count) lots")
        } footer: {
            if !lots.isEmpty {
                Text("The oldest in-date lot is drawn down first, and an already-open one "
                     + "before an unopened one \u{2014} you finish the open butter before "
                     + "cutting a new stick.")
            }
        }
    }

    @MainActor
    private func lotRow(_ lot: StockLot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(lotTitle(lot))
                Spacer(minLength: 8)
                // The LOT's own cached amount, which is a different number from the level
                // above and deliberately so: this is the cache, the level is the ledger, and
                // the reconcile report is where a disagreement between them shows up.
                Text(lot.remaining?.displayString(system: ledger.unitSystem) ?? "\u{2014}")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(PantryLevels.expiryText(for: lot))
                if lot.isOpen { Text("\u{00B7} open") }
                if let place = lot.location { Text("\u{00B7} \(place.displayName)") }
            }
            .font(.caption)
            .foregroundStyle(lot.isExpired() ? .orange : .secondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func lotTitle(_ lot: StockLot) -> String {
        if !lot.label.isEmpty { return lot.label }
        return "Bought \(PantryLevels.dayText(lot.acquiredAt))"
    }

    // MARK: - History

    @MainActor
    @ViewBuilder
    private var historySection: some View {
        let all = item.orderedTransactions
        let rows = showsAllHistory ? all : Array(all.prefix(FoodItemDetailView.historyWindow))
        Section {
            if all.isEmpty {
                Text("Nothing recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    historyRow(row)
                }
                if !showsAllHistory && all.count > rows.count {
                    Button("Show all \(all.count)") { showsAllHistory = true }
                        .frame(minHeight: 44)
                }
            }
        } header: {
            Text("History")
        } footer: {
            Text("Append-only. Nothing is deleted to undo it \u{2014} a correction is "
                 + "another row \u{2014} because the pruned row is exactly the one you would "
                 + "be asking about.")
        }
    }

    @MainActor
    private func historyRow(_ transaction: InventoryTransaction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: PantryLevels.symbol(for: transaction.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(PantryLevels.title(for: transaction.kind))
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Text(PantryLevels.amountText(for: transaction, system: ledger.unitSystem))
                        .font(.subheadline)
                        .monospacedDigit()
                }
                Text(historyDetail(transaction))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if transaction.needsBridge {
                    Text("Amount unknown \u{2014} the app recorded the question rather than "
                         + "guessing.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// Cook provenance without a cook log: the recipe title is a SNAPSHOT on the row, which
    /// is the whole of what a journal would have been load-bearing for. Brandon declined the
    /// journal; "where did the cream go" still has an answer.
    private func historyDetail(_ transaction: InventoryTransaction) -> String {
        var parts: [String] = [PantryLevels.dayText(transaction.occurredAt)]
        if !transaction.recipeTitleSnapshot.isEmpty {
            parts.append(transaction.recipeTitleSnapshot)
        }
        if transaction.isUnassignedLot && transaction.kind != .cookDepletion {
            parts.append("no lot")
        }
        if let cents = transaction.priceCents {
            parts.append(PantryEditor.priceText(cents))
        }
        if !transaction.note.isEmpty { parts.append(transaction.note) }
        if transaction.resolutionState == .voided { parts.append("voided") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Notes

    /// The other names this food answers to, and the only way to take one back off.
    ///
    /// It exists because of a defect rather than for completeness. `addAlias` had no
    /// counterpart: a receipt token learned against the wrong food resolves at step 2 of
    /// `FoodItemResolver.findOrCreate` — his own aliases, AHEAD of the shipped catalogue —
    /// so it answered that line the same wrong way on every future receipt, and nothing in
    /// the app could reach in and correct it. The only escape was deleting the item, which
    /// takes its lots and its whole history with it.
    ///
    /// The shipped catalogue's own synonyms are deliberately NOT here. They are not rows:
    /// `IngredientCatalog` consults them in memory and `findOrCreate` mints from the
    /// template, so "green onions" reaching scallion is content and not something he
    /// taught the app. Only his own rows can be wrong, and only his own are removable.
    @ViewBuilder
    private var aliasSection: some View {
        let aliases = item.orderedAliases
        if !aliases.isEmpty {
            Section {
                ForEach(aliases) { alias in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alias.text)
                        Text("Matched as \(alias.matchKey)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            FoodItemResolver(catalog: catalog)
                                .removeAlias(alias, in: context)
                        } label: {
                            Label("Forget", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Also known as")
            } footer: {
                Text("Names learned from your receipts. Swipe to forget one — the next "
                   + "receipt that prints it will ask again instead of guessing.")
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        Section {
            TextField(
                "Notes, e.g. the good anchovies, back of aisle 7",
                text: Binding(
                    get: { item.notes },
                    set: { PantryEditor.setNotes(item, to: $0, in: context) }
                ),
                axis: .vertical
            )
            .frame(minHeight: 44)
            .accessibilityLabel("Notes")
        } header: {
            Text("Notes")
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                isAddingStock = true
            } label: {
                Label(item.isStaple ? "Mark as bought" : "Add a lot", systemImage: "plus")
            }
            .frame(minHeight: 44)

            if !item.isStaple {
                Button {
                    isAdjusting = true
                } label: {
                    Label("Adjust, waste or count", systemImage: "slider.horizontal.3")
                }
                .frame(minHeight: 44)
            }
        }
    }
}

// MARK: - The per-place rows

/// One line of the "on hand" breakdown. A struct rather than a tuple because `ForEach` needs
/// something `Identifiable` and there are no key paths into a tuple.
private struct PlaceLevel: Identifiable {
    var id: UUID
    var title: String
    var symbol: String
    var text: String
}

// MARK: - Par level

/// Setting the minimum to keep on hand.
///
/// Through `FoodItem.setParLevel`, which writes all five primitives together. Assigning the
/// amount while leaving `parLevelUnitCode` behind leaves a row that has no par level and
/// still claims a unit — which no accessor reads, and which the reconcile screen and any
/// future migration both read as a contradiction.
private struct ParLevelSheet: View {
    let item: FoodItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(IngredientCatalog.self) private var catalog

    @State private var isOn = false
    @State private var amount: Rational = .one
    @State private var unit: KitchenUnit = UnitCatalog.each
    @State private var didSeed = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep a minimum on hand", isOn: $isOn)
                    .frame(minHeight: 44)
            } footer: {
                Text("Below the par level this goes onto the next shopping list by a rule, "
                     + "badged \u{201C}below par\u{201D} so the list says why it is there.")
            }

            if isOn {
                Section {
                    QuantityField(label: "At least", value: $amount, unitName: unit.name(for: amount))
                    UnitPicker(
                        label: "Unit",
                        dimension: unit.dimension,
                        countNoun: unit.isCount ? unit.code : "",
                        unit: $unit
                    )
                } footer: {
                    Text("Set it in the unit you think about this in. The comparison converts "
                         + "between cups and grams only when this item carries a weight per "
                         + "cup.")
                }
            }
        }
        .navigationTitle("Par level")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(isOn && amount.isZero)
            }
        }
        .onAppear(perform: seedOnce)
    }

    private func seedOnce() {
        guard !didSeed else { return }
        didSeed = true
        if let par = item.parLevel {
            isOn = true
            amount = par.amount
            unit = par.unit
            return
        }
        unit = catalog.entry(named: item.catalogName)?.defaultUnit ?? UnitCatalog.each
    }

    private func save() {
        let par = isOn && !amount.isZero ? Quantity(amount: amount, unit: unit) : nil
        PantryEditor.setPar(item, to: par, in: context)
        dismiss()
    }
}

// MARK: - Density

/// Grams per US cup, as a whole number of grams.
///
/// A whole number because that is how the shipped catalogue carries it for its 108 entries
/// and how every reference table he would read it off is written. It is stored exactly, as a
/// `Rational`, so the bridge arithmetic stays exact.
private struct DensitySheet: View {
    let item: FoodItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var text: String = ""
    @State private var didSeed = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Grams per cup")
                    Spacer(minLength: 8)
                    TextField("e.g. 227", text: $text)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .accessibilityLabel("Grams per cup")
                }
                .frame(minHeight: 44)
            } footer: {
                Text("Butter is 227, flour 120, granulated sugar 200. Leave it empty and the "
                     + "app keeps refusing to convert, which is the honest answer when it "
                     + "does not know.")
            }

            if item.hasDensity {
                Section {
                    Button("Remove it", role: .destructive) {
                        PantryEditor.setDensity(item, gramsPerCup: nil, in: context)
                        dismiss()
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("Weight per cup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    PantryEditor.setDensity(item, gramsPerCup: Int(text), in: context)
                    dismiss()
                }
                .disabled(Int(text) == nil || (Int(text) ?? 0) <= 0)
            }
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            if let grams = item.gramsPerCup {
                // `humanDescription`, never `exactDescription`, even in a field: a density
                // that arrived as 2271/10 would otherwise seed the box with a fraction.
                text = grams.humanDescription
            }
        }
    }
}
