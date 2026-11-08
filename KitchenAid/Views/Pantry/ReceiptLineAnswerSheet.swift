import SwiftUI
import SwiftData

/// One receipt line, and the question it could not answer by itself.
///
/// This is the screen the whole receipt feature turns on, so it is built around one tap. The
/// candidates the matcher offered are buttons; his own pantry is a second list of buttons; the
/// whole catalogue is one tap further; and **skip is as prominent as any of them.**
///
/// That last one is deliberate and the reason is in `ReceiptTokenMatcher.minimumScore`'s own
/// comment: the floor on a candidate is low on purpose, because a weak tail is what keeps the
/// confidence gap honest, and the visible cost is that `DOG FOOD` offers `doubanjiang` at 74.
/// A screen that makes picking easy and skipping hard turns that cosmetic cost into the wrong
/// tin of food in his pantry.
///
/// Nothing here writes. It hands a changed `ReceiptLineDraft` back to the review list, which
/// is the only thing that writes, and only when he confirms the whole receipt. Minting a
/// `FoodItem` on a tap here would leave a bare row behind every line he changed his mind
/// about -- the same reason `AddStockSheet` mints on **Add** and not on pick.
struct ReceiptLineAnswerSheet: View {

    let draft: ReceiptLineDraft
    let onDone: (ReceiptLineDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(IngredientCatalog.self) private var catalog
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    /// Bare and filtered in Swift, the way `PantryView` and `AddStockSheet` do it.
    @Query private var items: [FoodItem]

    /// Seeded from the draft in `onAppear` rather than bound to it, which is this codebase's
    /// pattern for an editor sheet (`AddStockSheet.seedDefaultsOnce`): a field bound straight
    /// through would make a half-made decision a made one.
    @State private var answer: ScanAnswer = .unanswered
    @State private var amount: Rational = .zero
    @State private var unit: KitchenUnit = UnitCatalog.each
    @State private var didSeed = false
    @State private var isPicking = false
    @State private var search = ""

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        List {
            lineSection
            answerSection
            if !candidates.isEmpty { candidateSection }
            kitchenSection
            catalogueSection
            if !answer.isSkipped && !answer.isStaple && answer.name != nil { amountSection }
            skipSection
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search your pantry")
        .navigationTitle("What is this?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use this") { save(answer, amount, unit) }
                    .disabled(answer.name == nil && !answer.isSkipped)
            }
        }
        .sheet(isPresented: $isPicking) {
            NavigationStack {
                CatalogPickerView(title: "What is it?") { entry in
                    choose(.entry(entry))
                }
            }
        }
        .onAppear(perform: seedOnce)
    }

    // MARK: - What the line said

    /// The line taken apart, because the first question is not "what is it" but "is that what
    /// the receipt says". `Reading` carries every piece for exactly this.
    private var lineSection: some View {
        Section {
            Text(draft.printedLine)
                .font(.callout)
                .monospaced()
                .textSelection(.enabled)
            if !readingDetail.isEmpty {
                Text(readingDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("The line")
        } footer: {
            if !draft.reading.droppedWords.isEmpty {
                Text("Ignored: \(draft.reading.droppedWords.joined(separator: ", ")) "
                     + "\u{2014} store codes, tax flags and stray numbers.")
            }
        }
    }

    private var readingDetail: String {
        var parts: [String] = []
        if !draft.reading.brand.isEmpty { parts.append("brand \(draft.reading.brand)") }
        parts.append("read as \u{201C}\(draft.reading.nameDisplay)\u{201D}")
        if let size = draft.reading.size(preferring: answer.dimension) {
            parts.append("size \(size.exactDescription)")
        } else if draft.reading.sizeAmount == nil {
            parts.append("no size printed")
        }
        if let multiplier = draft.reading.multiplier { parts.append("\u{00D7}\(multiplier)") }
        if let cents = draft.reading.priceCents { parts.append(PantryEditor.priceText(cents)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - The answer as it stands

    @ViewBuilder
    private var answerSection: some View {
        Section {
            if answer.isSkipped {
                Text("Skipped. Nothing will be added for this line.")
                    .font(.subheadline)
            } else if let name = answer.name {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.medium))
                    Text(answerDetail).font(.caption).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            } else {
                Text("Nothing picked yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("This line is")
        } footer: {
            if answer.name != nil {
                // Said out loud because it is the promise the feature is built on, and a
                // promise he cannot see is one he cannot trust.
                Text("Confirming the receipt remembers \u{201C}\(draft.reading.nameDisplay)\u{201D} "
                     + "as a name for this, so the next receipt will not ask.")
            }
        }
    }

    private var answerDetail: String {
        switch answer {
        case .item(let item):
            if item.isStaple { return "Already in your kitchen \u{00B7} staple" }
            return "Already in your kitchen"
        case .entry(let entry):
            if entry.staple { return "\(entry.aisle) \u{00B7} tracked present or absent" }
            return "\(entry.aisle) \u{00B7} new row in your pantry"
        case .unanswered, .skipped:
            return ""
        }
    }

    // MARK: - What the matcher offered

    private var candidates: [ReceiptTokenMatcher.Candidate] {
        draft.resolution.match.candidates
    }

    private var candidateSection: some View {
        Section {
            ForEach(candidates, id: \.self) { candidate in
                Button {
                    choose(.entry(candidate.entry))
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name).foregroundStyle(.primary)
                            Text(candidateDetail(candidate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if isChosen(candidate.entry) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.name)
                .accessibilityValue(candidateDetail(candidate))
                .accessibilityAddTraits(isChosen(candidate.entry) ? [.isSelected] : [])
            }
        } header: {
            Text(candidates.count == 1 ? "The one match" : "\(candidates.count) possible matches")
        } footer: {
            Text("Ranked, best first. \u{201C}Via\u{201D} is the name or alias that actually "
                 + "matched, so a surprising answer explains itself rather than looking "
                 + "arbitrary.")
        }
    }

    /// Why this candidate is here, in the matcher's own terms: the string that matched and how
    /// strongly. `matchedVia` is the whole reason `HVY WHIP CRM` reaching `heavy cream` does
    /// not look like a guess -- it matched via the shipped alias `heavy whipping cream`.
    private func candidateDetail(_ candidate: ReceiptTokenMatcher.Candidate) -> String {
        var parts: [String] = []
        if candidate.isExact {
            parts.append("the catalogue names this outright")
        } else {
            parts.append("score \(candidate.score)")
        }
        if candidate.matchedVia != candidate.name && !candidate.matchedVia.isEmpty {
            parts.append("via \u{201C}\(candidate.matchedVia)\u{201D}")
        }
        parts.append(candidate.entry.aisle)
        if let size = candidate.size { parts.append(size.exactDescription) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - His own kitchen

    /// His own rows, which the catalogue cannot offer: a `FoodItem` he renamed, or one he made
    /// from an entry that no longer resembles its template. Picking one here is also what
    /// `ReceiptIntake.learn(_:as:in:)` was written for -- the alias lands on HIS row.
    @ViewBuilder
    private var kitchenSection: some View {
        let rows = kitchenMatches
        Section {
            if rows.isEmpty {
                Text(items.isEmpty
                     ? "Your pantry is empty, so there is nothing of your own to match yet."
                     : "No pantry item matches that search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { item in
                    Button {
                        choose(.item(item))
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
                    .accessibilityAddTraits(isChosen(item) ? [.isSelected] : [])
                }
            }
        } header: {
            Text("In your kitchen")
        } footer: {
            if search.isEmpty && items.count > kitchenLimit {
                Text("Showing \(kitchenLimit) of \(items.count). Search to narrow it.")
            }
        }
    }

    private var kitchenLimit: Int { 8 }

    private var kitchenMatches: [FoodItem] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = items.sorted(by: PantryLevels.byName)
        guard !needle.isEmpty else { return Array(sorted.prefix(kitchenLimit)) }
        return sorted.filter { item in
            if item.displayName.lowercased().contains(needle) { return true }
            // His own aliases too: "the good anchovies" is a name he gave something, and a
            // search that ignores them is a search that cannot find what he called it.
            return item.orderedAliases.contains { $0.text.lowercased().contains(needle) }
        }
    }

    // MARK: - The whole catalogue

    private var catalogueSection: some View {
        Section {
            Button {
                isPicking = true
            } label: {
                Label("Search all ingredients", systemImage: "magnifyingglass")
                    .frame(minHeight: 44)
            }
        } footer: {
            Text("\(catalog.all.count) ingredients ship with the app, each with its aisle and "
                 + "the unit it is bought in. Picking one here adds it to your pantry when you "
                 + "confirm the receipt.")
        }
    }

    // MARK: - How much

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
            if amount <= .zero {
                // The honest state, and the brief's rule: never an invented quantity. A
                // package whose weight the receipt did not print is not a package of one pound.
                Text("The receipt printed no amount for this, and the app will not invent one. "
                     + "Set it and the line goes in the pantry; leave it and the name is still "
                     + "remembered.")
            } else if draft.reading.sizeAmount != nil {
                Text("Read off the receipt as \u{201C}\(printedSizeText)\u{201D}. Weight and "
                     + "volume are not interchangeable without a weight per cup, so the unit "
                     + "follows what this food is sold by.")
            } else {
                Text("Nothing on the line said how much, so this is one of them. Change it if "
                     + "you bought more.")
            }
        }
    }

    private var printedSizeText: String {
        let amountText = draft.reading.sizeAmount?.humanDescription ?? ""
        return "\(amountText)\(draft.reading.sizeUnitCode)"
    }

    // MARK: - Skipping

    private var skipSection: some View {
        Section {
            Button(role: .destructive) {
                // The values are passed rather than written to `@State` and read back: a
                // property wrapper written and read in one event is not something this
                // container can ask a compiler about, and silently saving the previous answer
                // is the one failure this sheet must not have.
                save(.skipped, amount, unit)
            } label: {
                Text("Skip this line")
                    .frame(minHeight: 44)
            }
        } footer: {
            Text("Nothing is added and nothing is remembered. The right answer for a line that "
                 + "is not food, or one the app read badly \u{2014} a wrong guess is harder to "
                 + "find later than a missing line.")
        }
    }

    // MARK: - Seeding and choosing

    private func seedOnce() {
        guard !didSeed else { return }
        didSeed = true
        answer = draft.answer
        amount = draft.amount
        unit = draft.unit
    }

    /// Picking an answer RE-READS the printed size, because what the size means depends on the
    /// answer: `8Z` is eight weight ounces of cream cheese and eight fluid ounces of milk. One
    /// rule, in `ReceiptLineDraft.startingQuantity`, so this screen and the first pass cannot
    /// disagree.
    private func choose(_ newAnswer: ScanAnswer) {
        answer = newAnswer
        let (newAmount, newUnit) = ReceiptLineDraft.startingQuantity(
            for: newAnswer, reading: draft.reading, catalog: catalog
        )
        amount = newAmount
        unit = newUnit
    }

    private func isChosen(_ entry: CatalogEntry) -> Bool {
        if case .entry(let chosen) = answer { return chosen.name == entry.name }
        return false
    }

    private func isChosen(_ item: FoodItem) -> Bool {
        if case .item(let chosen) = answer { return chosen.id == item.id }
        return false
    }

    private func save(_ chosen: ScanAnswer, _ chosenAmount: Rational, _ chosenUnit: KitchenUnit) {
        var updated = draft
        updated.answer = chosen
        updated.amount = chosenAmount
        updated.unit = chosenUnit
        onDone(updated)
        dismiss()
    }
}
