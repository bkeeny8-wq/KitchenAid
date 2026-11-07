import SwiftUI
import SwiftData

/// Everything that moves an amount and is neither a purchase nor a cook: a correction, a
/// spill, something thrown out, something given away, or a count off the shelf.
///
/// **Nothing here overwrites a number.** Every outcome is one appended row, written through
/// `InventoryLedger.apply` — the only place an `InventoryTransaction` is created, and the
/// only thing that moves a lot's cache and the ledger together. "I counted 3 lb" becomes the
/// delta that makes the ledger agree, so the size of the disagreement stays in the history
/// instead of being papered over.
///
/// `.purchase` is not offered: that is `AddStockSheet`, which also creates the lot.
/// `.cookDepletion` is not offered either — those rows carry a recipe id and title as
/// snapshots, which is cook provenance this screen has no way to supply and would therefore
/// record as an anonymous adjustment.
struct AdjustStockSheet: View {
    let item: FoodItem
    let lot: StockLot?
    let initialKind: TransactionKind
    let prefill: Quantity?

    init(
        item: FoodItem,
        lot: StockLot? = nil,
        kind: TransactionKind = .manualAdjustment,
        prefill: Quantity? = nil
    ) {
        self.item = item
        self.lot = lot
        self.initialKind = kind
        self.prefill = prefill
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(IngredientCatalog.self) private var catalog
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    @State private var kind: TransactionKind = .manualAdjustment
    @State private var isIncrease = false
    @State private var amount: Rational = .zero
    @State private var unit: KitchenUnit = UnitCatalog.each
    @State private var selectedLotID: UUID?
    @State private var note: String = ""
    @State private var occurredAt: Date = .now
    @State private var didSeed = false

    /// What this sheet can write. Ordered by how often a home kitchen needs them.
    private static let kinds: [TransactionKind] = [
        .manualAdjustment, .waste, .inventoryCount, .giftOut, .correction
    ]

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        Form {
            kindSection
            amountSection
            lotSection
            detailSection
        }
        .navigationTitle("Adjust")
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
        .onAppear(perform: seedOnce)
    }

    // MARK: - What happened

    @ViewBuilder
    private var kindSection: some View {
        Section {
            Picker("What happened", selection: $kind) {
                ForEach(AdjustStockSheet.kinds, id: \.self) { option in
                    Text(PantryLevels.title(for: option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)

            if allowsDirection {
                Picker("Direction", selection: $isIncrease) {
                    Text("Removed").tag(false)
                    Text("Added").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Direction")
            }
        } header: {
            Text(item.displayName)
        } footer: {
            Text(kindExplanation)
        }
    }

    /// Waste and a gift only ever go out; a count is an absolute, not a direction. Offering a
    /// direction for those would let him record a spill that increased the butter.
    private var allowsDirection: Bool {
        kind == .manualAdjustment || kind == .correction
    }

    private var kindExplanation: String {
        switch kind {
        case .inventoryCount:
            return "Enter what is actually there. The app works out the difference and "
                 + "records that, so the history shows what the ledger was out by."
        case .waste:
            return "Gone off, spilled, or binned. It leaves the kitchen and the ledger says "
                 + "so."
        case .giftOut:
            return "Given to someone. Same effect on the level as waste, and worth telling "
                 + "apart six months later."
        case .correction:
            return "A fix to an earlier row. Nothing is deleted \u{2014} an append-only "
                 + "ledger that is sometimes pruned is not append-only, and the pruned row "
                 + "is the one you would be asking about."
        default:
            return "Anything that changed the amount without a purchase and without cooking."
        }
    }

    // MARK: - Amount

    @MainActor
    @ViewBuilder
    private var amountSection: some View {
        Section {
            QuantityField(
                label: kind == .inventoryCount ? "Counted" : "Amount",
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
        } header: {
            Text(kind == .inventoryCount ? "What is actually there" : "How much")
        } footer: {
            Text(amountFooter)
        }
    }

    /// For a count, this is the whole point of the screen: it shows the delta BEFORE it is
    /// written, so a count entered in the wrong unit is visible as an absurd correction
    /// rather than as a silent swing in the level.
    @MainActor
    private var amountFooter: String {
        let system = ledger.unitSystem
        guard kind == .inventoryCount else {
            guard !amount.isZero else { return "" }
            let signed = isIncrease || (!allowsDirection && !PantryLevels.isDepletion(kind))
            let verb = signed ? "adds" : "takes away"
            return "Records one row that \(verb) "
                 + Quantity(amount: amount, unit: unit).displayString(system: system)
                 + "."
        }
        let have = PantryLevels.level(of: item, using: ledger).subtotals
            .first { $0.dimensionKey == unit.dimensionKey }?.base ?? .zero
        guard unit.baseFactor != .zero else { return "" }
        let onHand = Quantity(amount: have / unit.baseFactor, unit: unit)
        let delta = Quantity(
            amount: (amount * unit.baseFactor - have) / unit.baseFactor, unit: unit
        )
        if delta.amount.isZero {
            return "The ledger already says \(onHand.displayString(system: system)). This "
                 + "records the count and changes nothing."
        }
        let direction = delta.amount.isNegative ? "down" : "up"
        return "The ledger says \(onHand.displayString(system: system)), so this writes it "
             + "\(direction) by "
             + Quantity(amount: delta.amount.magnitude, unit: unit).displayString(system: system)
             + "."
    }

    // MARK: - Which lot

    @MainActor
    @ViewBuilder
    private var lotSection: some View {
        let lots = item.orderedLots
        if !lots.isEmpty {
            Section {
                Picker("Lot", selection: $selectedLotID) {
                    Text("No particular lot").tag(nil as UUID?)
                    ForEach(lots) { row in
                        Text(lotTitle(row)).tag(row.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
            } header: {
                Text("Which lot")
            } footer: {
                // A nil lot is legal and counted, which is why this is a choice rather than a
                // requirement: the row contributes to the level either way, and filing it
                // against a lot is what also keeps that lot's cache honest.
                Text("Filing it against a lot keeps that lot's own amount right as well as "
                     + "the total. Left unfiled it still counts, and shows up in the "
                     + "reconcile report as unassigned.")
            }
        }
    }

    @MainActor
    private func lotTitle(_ lot: StockLot) -> String {
        let remaining = lot.remaining?.displayString(system: ledger.unitSystem) ?? "\u{2014}"
        let name = lot.label.isEmpty
            ? "Bought \(PantryLevels.dayText(lot.acquiredAt))"
            : lot.label
        return "\(name) \u{00B7} \(remaining)"
    }

    // MARK: - Details

    @ViewBuilder
    private var detailSection: some View {
        Section {
            DatePicker("When", selection: $occurredAt, displayedComponents: .date)
                .frame(minHeight: 44)
            TextField("Note", text: $note, axis: .vertical)
                .frame(minHeight: 44)
                .accessibilityLabel("Note")
        } header: {
            Text("Details")
        }
    }

    // MARK: - Writing it

    private func seedOnce() {
        guard !didSeed else { return }
        didSeed = true
        kind = initialKind
        isIncrease = !PantryLevels.isDepletion(initialKind) && initialKind != .manualAdjustment
        selectedLotID = lot?.id

        if let prefill = prefill {
            amount = prefill.amount
            unit = prefill.unit
            return
        }
        // The lot's own unit first: an adjustment to a specific package is nearly always in
        // the unit that package is measured in.
        if let lotUnit = lot?.remaining?.unit ?? lot?.original?.unit {
            unit = lotUnit
        } else {
            unit = catalog.entry(named: item.catalogName)?.defaultUnit ?? UnitCatalog.each
        }
    }

    @MainActor
    private func record() {
        let quantity = Quantity(amount: amount, unit: unit)
        let target = selectedLot

        if kind == .inventoryCount {
            PantryEditor.recordCount(
                item: item,
                lot: target,
                counted: quantity,
                note: note,
                at: occurredAt,
                using: ledger,
                in: context
            )
            dismiss()
            return
        }

        PantryEditor.adjust(
            item: item,
            lot: target,
            kind: kind,
            amount: quantity,
            isIncrease: allowsDirection ? isIncrease : !PantryLevels.isDepletion(kind),
            note: note,
            at: occurredAt,
            using: ledger,
            in: context
        )
        dismiss()
    }

    private var selectedLot: StockLot? {
        guard let id = selectedLotID else { return nil }
        return item.orderedLots.first { $0.id == id }
    }
}
