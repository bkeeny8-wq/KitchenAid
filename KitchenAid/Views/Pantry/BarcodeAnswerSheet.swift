import SwiftUI
import SwiftData

/// "What is this?" for one number, which is the whole barcode feature.
///
/// There are no candidates to offer and there never will be: a barcode is only a number, and
/// turning one into "heavy cream" needs a commercial product database -- a subscription and a
/// network call this app does not have (`CLAUDE.md`). So this screen does not pretend to have
/// guessed. It shows the number, says plainly that nothing can look it up, and puts his own
/// pantry one tap away with the whole shipped catalogue one tap behind that.
///
/// Built for ONE QUESTION AND ONE TAP, because it is asked once per product in his kitchen and
/// then never again. His own items come first and unfiltered, since the thing he just scanned
/// is usually something he already buys.
///
/// It writes nothing. The answer goes back to `BarcodeScanView`, which remembers the number
/// immediately -- `FoodItemResolver` stays the only thing in the app that creates a `FoodItem`,
/// reached through `BarcodeRegistry.remember`.
struct BarcodeAnswerSheet: View {

    let row: BarcodeScanRow
    let onDone: (BarcodeScanRow) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(IngredientCatalog.self) private var catalog
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    @Query private var items: [FoodItem]

    /// Seeded in `onAppear` rather than bound through, the pattern every editor sheet here
    /// uses (`AddStockSheet.seedDefaultsOnce`).
    @State private var answer: ScanAnswer = .unanswered
    @State private var amount: Rational = .zero
    @State private var unit: KitchenUnit = UnitCatalog.each
    @State private var packages = 1
    @State private var didSeed = false
    @State private var isPicking = false
    @State private var search = ""

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        List {
            numberSection
            answerSection
            kitchenSection
            catalogueSection
            if answer.name != nil && !answer.isStaple { amountSection }
            laterSection
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search your pantry")
        .navigationTitle(row.isUnreadable ? "Unreadable number" : "What is this?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use this") { finish(answer, amount, unit, packages) }
                    .disabled(answer.name == nil)
            }
        }
        .sheet(isPresented: $isPicking) {
            NavigationStack {
                CatalogPickerView(title: "What is it?") { entry in
                    // `finishing: false` on purpose. `CatalogPickerView` dismisses ITSELF in
                    // this closure, and closing this sheet in the same event means two nested
                    // dismissals in one tick -- which is how one of them gets lost and he is
                    // left looking at a sheet he thought he had finished with. He taps "Use
                    // this" here instead, having just been through a picker anyway.
                    pick(.entry(entry), finishing: false)
                }
            }
        }
        .onAppear(perform: seedOnce)
    }

    // MARK: - The number

    private var numberSection: some View {
        Section {
            Text(row.digits)
                .font(.title3)
                .monospaced()
                .textSelection(.enabled)
            if !row.symbology.isEmpty {
                Text(row.symbology)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("The number")
        } footer: {
            Text(numberFooter)
        }
    }

    private var numberFooter: String {
        if row.isUnreadable {
            // Said rather than hidden: a 5-digit produce sticker and a half-read label both
            // land here, and "nothing was stored" is the part that matters -- a number filed
            // wrongly would auto-fill the wrong food for ever.
            return "A product code is 8, 12, 13 or 14 digits. This is not one, so it was not "
                 + "stored and cannot be remembered. A produce sticker or a shelf label often "
                 + "reads like this."
        }
        if row.isForgotten {
            return "This number was remembered before, but the food it named is no longer in "
                 + "the pantry \u{2014} deleted, or merged into something else. Saying what it "
                 + "is again overwrites the same row, so it will not ask a third time."
        }
        return "Nothing looks this up. There is no product database in this app and no network "
             + "call, so a number means whatever you say it means \u{2014} once, and it fills "
             + "itself in from then on."
    }

    // MARK: - The answer as it stands

    @ViewBuilder
    private var answerSection: some View {
        Section {
            if let name = answer.name {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.medium))
                    Text(answerDetail).font(.caption).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            } else if row.isForgotten && !row.rememberedName.isEmpty {
                Text("Was \u{201C}\(row.rememberedName)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing picked yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("This is")
        }
    }

    private var answerDetail: String {
        switch answer {
        case .item(let item):
            return item.isStaple ? "In your kitchen \u{00B7} staple" : "In your kitchen"
        case .entry(let entry):
            return entry.staple ? "\(entry.aisle) \u{00B7} tracked present or absent"
                                : "\(entry.aisle) \u{00B7} new row in your pantry"
        case .unanswered, .skipped:
            return ""
        }
    }

    // MARK: - His own kitchen, first

    /// Unfiltered and alphabetical, because the thing he just scanned is usually something he
    /// already buys, and the one-tap case is the whole point of this screen. Searching narrows
    /// it by name and by HIS aliases -- what he calls a thing is a name too.
    @ViewBuilder
    private var kitchenSection: some View {
        let matches = kitchenMatches
        Section {
            if matches.isEmpty {
                Text(items.isEmpty
                     ? "Your pantry is empty, so pick from the catalogue below."
                     : "No pantry item matches that search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matches) { item in
                    Button {
                        pick(.item(item))
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.displayName).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if isChosen(item) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(row.isUnreadable)
                    .accessibilityAddTraits(isChosen(item) ? [.isSelected] : [])
                }
            }
        } header: {
            Text("In your kitchen")
        } footer: {
            if search.isEmpty && items.count > kitchenLimit {
                Text("Showing \(kitchenLimit) of \(items.count). Search to narrow it.")
            } else if row.isUnreadable {
                Text("Nothing can be filed against this number, so there is nothing to pick.")
            }
        }
    }

    private var kitchenLimit: Int { 10 }

    private var kitchenMatches: [FoodItem] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = items.sorted(by: PantryLevels.byName)
        guard !needle.isEmpty else { return Array(sorted.prefix(kitchenLimit)) }
        return sorted.filter { item in
            if item.displayName.lowercased().contains(needle) { return true }
            return item.orderedAliases.contains { $0.text.lowercased().contains(needle) }
        }
    }

    // MARK: - The catalogue

    @ViewBuilder
    private var catalogueSection: some View {
        Section {
            Button {
                isPicking = true
            } label: {
                Label("Search all ingredients", systemImage: "magnifyingglass")
                    .frame(minHeight: 44)
            }
            .disabled(row.isUnreadable)
        } footer: {
            Text("\(catalog.all.count) ingredients ship with the app, with the aisle and the "
                 + "unit each is bought in. Picking one adds it to your pantry.")
        }
    }

    // MARK: - How much

    @MainActor
    @ViewBuilder
    private var amountSection: some View {
        Section {
            QuantityField(label: "In one package", value: $amount, unitName: unit.name(for: amount))
            UnitPicker(
                label: "Unit",
                dimension: unit.dimension,
                countNoun: unit.isCount ? unit.code : "",
                system: ledger.unitSystem,
                unit: $unit
            )
            Stepper(value: $packages, in: 1...99) {
                Text(packages == 1 ? "1 package" : "\(packages) packages")
                    .monospacedDigit()
            }
            .frame(minHeight: 44)
        } header: {
            Text("How much")
        } footer: {
            Text(amountFooter)
        }
    }

    private var amountFooter: String {
        guard amount <= .zero else {
            return "Each package becomes its own lot, so two of them can go bad on different "
                 + "days."
        }
        // The honest limit, and the reason it is honest: there is nowhere to remember a package
        // size. `FoodItemBarcode` holds digits and nothing else, deliberately -- a size field
        // on it would be a quantity the app claims a barcode told it.
        return "A barcode carries no size, and there is nowhere to remember one, so this is "
             + "the one thing a scan cannot fill in. Set it and the package goes in the "
             + "pantry; leave it and the number is still remembered."
    }

    // MARK: - Not now

    private var laterSection: some View {
        Section {
            Button(role: .destructive) {
                // Passed, not written and read back: a property wrapper written and read in one
                // event is not something this container can ask a compiler about.
                finish(.skipped, amount, unit, packages)
            } label: {
                Text("Not now").frame(minHeight: 44)
            }
        } footer: {
            Text("Leaves the number unknown. The next scan of it asks again, which is the right "
                 + "answer for something you are not sure about \u{2014} a wrong name is harder "
                 + "to find later than a missing one.")
        }
    }

    // MARK: - Seeding, choosing, saving

    private func seedOnce() {
        guard !didSeed else { return }
        didSeed = true
        answer = row.answer
        amount = row.amount
        unit = row.unit
        packages = max(1, row.packages)
    }

    /// Picking re-seeds the amount from the food's own purchase unit, because the two honest
    /// starting points depend entirely on what it turned out to be: one of a thing that is
    /// counted, nothing at all for a thing that is weighed. One rule, in
    /// `BarcodeScanRow.startingQuantity`.
    ///
    /// And then it LEAVES, when there is nothing left to ask. That is the one-tap case this
    /// screen exists for: a staple keeps no amount anywhere in the app, and a counted food is
    /// one per package, so both are answered completely by the tap he just made. A food
    /// measured by weight or volume is not -- only he knows whether the tub is 8 oz or 16 --
    /// so the sheet stays open on the amount rather than closing and making him come back to
    /// a row that says "no amount yet".
    private func pick(_ newAnswer: ScanAnswer, finishing: Bool = true) {
        let (newAmount, newUnit) = BarcodeScanRow.startingQuantity(
            for: newAnswer, catalog: catalog
        )
        answer = newAnswer
        amount = newAmount
        unit = newUnit
        if finishing, newAnswer.isStaple || newAmount > .zero {
            finish(newAnswer, newAmount, newUnit, packages)
        }
    }

    private func isChosen(_ item: FoodItem) -> Bool {
        if case .item(let chosen) = answer { return chosen.id == item.id }
        return false
    }

    private func finish(
        _ chosen: ScanAnswer, _ chosenAmount: Rational, _ chosenUnit: KitchenUnit, _ count: Int
    ) {
        var updated = row
        updated.answer = chosen
        updated.amount = chosenAmount
        updated.unit = chosenUnit
        updated.packages = max(1, count)
        onDone(updated)
        dismiss()
    }
}
