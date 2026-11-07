import SwiftUI
import SwiftData

/// Putting food away.
///
/// **Picking, not typing.** The item comes out of the shipped catalogue through
/// `CatalogPickerView`, and the aisle, the dimension, the density and the unit arrive with it
/// — he types an amount and a date and nothing else. That is the entire reason
/// `ingredients.json` ships: Brandon is not going to populate a few hundred ingredients by
/// hand, and an app that asks him to is an app he stops opening.
///
/// The `FoodItem` is minted on **Add**, not on pick, and only through `FoodItemResolver` —
/// the one creation site in the app, which is what stands in for the
/// `@Attribute(.unique)` CloudKit forbids. Minting on pick would leave a bare row behind
/// every time he changed his mind and backed out.
struct AddStockSheet: View {

    /// Fixed when the sheet is opened from an item's own screen, where the question is only
    /// "how much and where". nil from the Pantry's +, where the first thing it asks is what.
    let item: FoodItem?

    init(item: FoodItem? = nil) {
        self.item = item
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(IngredientCatalog.self) private var catalog
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    @Query private var locations: [StorageLocation]
    @Query private var allItems: [FoodItem]

    @State private var pickedEntry: CatalogEntry?
    @State private var isPicking = false
    @State private var amount: Rational = .one
    @State private var unit: KitchenUnit = UnitCatalog.each
    @State private var location: StorageLocation?
    @State private var acquiredAt: Date = .now
    @State private var hasExpiry = false
    @State private var expiresAt: Date = .now
    @State private var label: String = ""
    @State private var priceText: String = ""
    @State private var didSeedDefaults = false

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        Form {
            whatSection
            if subjectName != nil {
                if isStaple {
                    stapleSection
                } else {
                    amountSection
                    placeSection
                    datesSection
                    detailSection
                }
            }
        }
        .navigationTitle("Add stock")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
                    .disabled(!canAdd)
            }
        }
        .sheet(isPresented: $isPicking) {
            NavigationStack {
                CatalogPickerView(title: "What did you buy?") { entry in
                    adopt(entry)
                }
            }
        }
        .onAppear(perform: seedDefaultsOnce)
    }

    // MARK: - What

    @ViewBuilder
    private var whatSection: some View {
        Section {
            if let name = subjectName {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.body.weight(.medium))
                        Text(subjectDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if item == nil {
                        Button("Change") { isPicking = true }
                            .frame(minHeight: 44)
                    }
                }
            } else {
                Button {
                    isPicking = true
                } label: {
                    Label("Choose an ingredient", systemImage: "magnifyingglass")
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text("What")
        } footer: {
            if item == nil && pickedEntry == nil {
                Text("669 ingredients ship with the app, each with its aisle and the unit it "
                     + "is bought in. Pick one and the rest fills itself in.")
            } else if let existing = existingMatch {
                // Said out loud because the alternative looks like a bug: he picks "Green
                // onions", the app files it under "Scallion", and nothing explained why.
                Text("This adds a lot to \u{201C}\(existing.displayName)\u{201D}, which you "
                     + "already have, rather than starting a second row for the same thing.")
            }
        }
    }

    // MARK: - Amount

    @MainActor
    @ViewBuilder
    private var amountSection: some View {
        Section {
            QuantityField(label: "Amount", value: $amount, unitName: unit.name(for: amount))
            UnitPicker(
                label: "Unit",
                dimension: unit.dimension,
                countNoun: unit.isCount ? unit.code : "",
                system: ledger.unitSystem,
                unit: $unit
            )
        } header: {
            Text("How much")
        } footer: {
            Text("The unit is the one the catalogue says this is bought in. Weight and "
                 + "volume are not interchangeable without a weight per cup, so the app "
                 + "keeps them apart rather than guessing between them.")
        }
    }

    /// A staple has no amount anywhere in the app — Brandon's decision — so this sheet has
    /// no amount for one either. `InventoryLedger.receive` makes the same single assignment
    /// when a staple is checked off a finished list, and creates no lot there either.
    @ViewBuilder
    private var stapleSection: some View {
        Section {
            Text("Marked as in the house.")
                .font(.subheadline)
        } footer: {
            Text("Staples are tracked present or absent with no quantity. Counting teaspoons "
                 + "of salt is work nobody does, and a list that keeps asking for salt is a "
                 + "list you stop reading.")
        }
    }

    // MARK: - Where

    @ViewBuilder
    private var placeSection: some View {
        Section {
            Picker("Place", selection: locationSelection) {
                Text("No place").tag(nil as UUID?)
                ForEach(PantryLevels.ordered(locations)) { place in
                    Text(place.displayName).tag(place.id as UUID?)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
        } header: {
            Text("Where it goes")
        } footer: {
            if locations.isEmpty {
                Text("No places yet. A lot with no place still counts \u{2014} you can file "
                     + "it later from Places.")
            } else {
                Text("The same food can sit in two places at once with two different dates, "
                     + "which is what lots are for.")
            }
        }
    }

    /// Tagged by `UUID` rather than by the object: a `Picker` tag has to be `Hashable`, and
    /// an id is a value the selection can hold without pinning a model object to view state.
    private var locationSelection: Binding<UUID?> {
        Binding(
            get: { location?.id },
            set: { newID in
                location = locations.first { $0.id == newID }
                applyLocationDefaults()
            }
        )
    }

    // MARK: - Dates

    @ViewBuilder
    private var datesSection: some View {
        Section {
            DatePicker("Bought", selection: $acquiredAt, displayedComponents: .date)
                .frame(minHeight: 44)
            Toggle("Has a best-by", isOn: $hasExpiry)
                .frame(minHeight: 44)
            if hasExpiry {
                DatePicker("Best by", selection: $expiresAt, displayedComponents: .date)
                    .frame(minHeight: 44)
            }
        } header: {
            Text("Dates")
        } footer: {
            // A lot with no date never expires, and that is the right answer rather than a
            // missing one: inventing a date would put a guess inside a number he shops by.
            Text(hasExpiry
                 ? "Oldest goes first when you cook, and this is what \u{201C}about to go "
                   + "bad\u{201D} reads."
                 : "Without a best-by this lot never expires, which is correct for flour "
                   + "and wrong for cream.")
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var detailSection: some View {
        Section {
            TextField("Label, e.g. Costco 2-pack", text: $label)
                .frame(minHeight: 44)
            HStack {
                Text("Price")
                Spacer(minLength: 8)
                TextField("Optional", text: $priceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .accessibilityLabel("Price")
            }
            .frame(minHeight: 44)
        } header: {
            Text("Details")
        } footer: {
            if let cents = PantryEditor.cents(from: priceText) {
                Text("Recorded as \(PantryEditor.priceText(cents)) on this lot's purchase "
                     + "row.")
            } else {
                Text("The label is what you call this particular package \u{2014} it shows "
                     + "up in the lot list and in the reconcile report.")
            }
        }
    }

    // MARK: - Reading the subject

    private var subjectName: String? {
        if let item = item { return item.displayName }
        return pickedEntry?.name
    }

    private var subjectDetail: String {
        if let item = item {
            let aisle = catalog.entry(named: item.catalogName)?.aisle ?? ""
            if item.isStaple { return "Staple \u{00B7} present or absent" }
            return aisle.isEmpty ? "In your kitchen" : "In your kitchen \u{00B7} \(aisle)"
        }
        guard let entry = pickedEntry else { return "" }
        if entry.staple { return "\(entry.aisle) \u{00B7} present or absent" }
        return "\(entry.aisle) \u{00B7} bought in \(entry.defaultUnit?.plural ?? entry.unit)"
    }

    private var isStaple: Bool {
        if let item = item { return item.isStaple }
        return pickedEntry?.staple ?? false
    }

    /// His row that this entry would resolve to, by name then alias, which is the order
    /// `FoodItemResolver` resolves in. Shown so a merge is never a surprise.
    private var existingMatch: FoodItem? {
        guard item == nil, let entry = pickedEntry, !entry.matchKey.isEmpty else { return nil }
        return allItems.first { row in
            row.matchKey == entry.matchKey || row.aliasMatchKeys.contains(entry.matchKey)
        }
    }

    // MARK: - Defaults

    private func seedDefaultsOnce() {
        guard !didSeedDefaults else { return }
        didSeedDefaults = true
        if let item = item {
            // `FoodItemResolver` deliberately does NOT copy the template's unit onto the row
            // — the only unit-bearing field there is the par level's — and says in so many
            // words that an add-stock sheet reads it live. This is that reader.
            unit = catalog.entry(named: item.catalogName)?.defaultUnit ?? UnitCatalog.each
            location = item.defaultLocation ?? PantryLevels.ordered(locations).first
        } else {
            location = PantryLevels.ordered(locations).first
        }
        applyLocationDefaults()
    }

    private func adopt(_ entry: CatalogEntry) {
        pickedEntry = entry
        unit = entry.defaultUnit ?? UnitCatalog.each
        if let existing = existingMatch, let home = existing.defaultLocation {
            location = home
        }
        applyLocationDefaults()
    }

    /// Pre-fills the best-by from the place's own shelf life, day-granular, because a shelf
    /// life measured to the second is false precision on a date he reads as "around the
    /// 14th". Only ever pre-fills: a date he has already set is never overwritten.
    private func applyLocationDefaults() {
        guard !hasExpiry else { return }
        guard let suggested = location?.suggestedExpiry(from: acquiredAt) else { return }
        expiresAt = suggested
        hasExpiry = true
    }

    // MARK: - Writing it

    private var canAdd: Bool {
        guard item != nil || pickedEntry != nil else { return false }
        if isStaple { return true }
        return amount > .zero && unit.baseFactor != .zero
    }

    @MainActor
    private func add() {
        guard let target = resolveTarget() else { return }

        if target.isStaple {
            PantryEditor.setStaplePresent(target, isPresent: true, in: context)
            dismiss()
            return
        }

        PantryEditor.addLot(
            for: target,
            quantity: Quantity(amount: amount, unit: unit),
            location: location,
            acquiredAt: acquiredAt,
            expiresAt: hasExpiry ? expiresAt : nil,
            label: label,
            priceCents: PantryEditor.cents(from: priceText),
            using: ledger,
            in: context
        )
        dismiss()
    }

    /// The mint, and the only one on this screen. `findOrCreate(fromCatalog:in:)` returns an
    /// existing row when one already resolves, so picking "Green onions" twice does not make
    /// two scallions.
    private func resolveTarget() -> FoodItem? {
        if let item = item { return item }
        guard let entry = pickedEntry else { return nil }
        let resolver = FoodItemResolver(catalog: catalog)
        return try? resolver.findOrCreate(fromCatalog: entry, in: context)
    }
}
