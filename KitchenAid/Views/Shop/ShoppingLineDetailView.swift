import SwiftUI
import SwiftData

/// One line, and why it says what it says.
///
/// This screen exists because of a question he will ask in an aisle — "why does it want 2
/// tablespoons of butter?" — and the fixture answers it on a single recipe: butter appears as
/// 1 tbsp in two of its three components, and kosher salt as 1 tsp plus 1/4 tsp. So the
/// provenance is per SOURCE and not per line, and each row prints what the recipe said, what
/// it became, and the scale that did it.
///
/// It is also where the two states with a fix live. A `.needsBridge` line cannot be finished
/// by the app — 4 oz of butter by weight cannot answer a 2 tbsp requirement by volume without
/// a density — and one tap here fixes it forever. An `.unresolvedItem` line matched nothing in
/// the catalogue, and picking what it is does the same.
struct ShoppingLineDetailView: View {
    let line: ShoppingListLine

    @Environment(IngredientCatalog.self) private var catalog
    @Environment(\.modelContext) private var context

    @State private var note: String = ""
    /// Zero, not a plausible-looking default. A seeded 120 g is flour's weight and nothing
    /// else's, and the one thing worse than a line the app could not finish is a density he
    /// saved by tapping Save without reading it. The button stays disabled until he types
    /// one, and an item that already has a density has it read in on appear.
    @State private var gramsPerCup: Rational = .zero
    @State private var isPicking = false
    @State private var didSaveDensity = false
    @State private var didMatchItem = false

    private var system: UnitSystem { line.list?.unitSystem ?? .us }

    var body: some View {
        List {
            headerSection
            if needsBridge { bridgeSection }
            if line.foodItem == nil { matchSection }
            numbersSection
            sourcesSection
            noteSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(line.displayName)
        .sheet(isPresented: $isPicking) {
            NavigationStack {
                CatalogPickerView(title: "What is it?") { entry in
                    let resolver = FoodItemResolver(catalog: catalog)
                    if let item = try? resolver.findOrCreate(fromCatalog: entry, in: context) {
                        line.foodItem = item
                        // The alias is added so the NEXT import of the same recipe resolves
                        // without asking: "once, then remembers" is the rule the receipt
                        // scanner will follow too, and the vocabulary it builds is his.
                        resolver.addAlias(line.displayName, to: item, in: context)
                        didMatchItem = true
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // `onAppear` and not `task`: the closure `task` takes is `@Sendable` and so is not
        // main-actor isolated, while this reads two SwiftData properties. A non-Sendable
        // closure inherits the isolation of the context it is formed in, and `View.body` is
        // main-actor isolated, so this one is too.
        .onAppear {
            // Seeded once, from the store, rather than bound straight to the model: a
            // `TextField` bound to a SwiftData property writes on every keystroke, which
            // makes a half-typed note a saved note.
            note = line.noteToSelf
            if let existing = line.foodItem?.gramsPerCup { gramsPerCup = existing }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(statusSentence)
                    .font(.subheadline)
                FlagBadgeRow(flags: line.flags)
            }
            .padding(.vertical, 2)
            LabeledContent("Aisle", value: line.sectionNameSnapshot)
            if line.isChecked {
                LabeledContent("In the cart", value: checkedText)
            }
        }
    }

    /// One sentence per `LineStatus`, in his words rather than the enum's. The ladder that
    /// assigned it is `ShoppingListBuilder.status`, and nothing here recomputes it.
    private var statusSentence: String {
        switch line.status {
        case .needed:
            return "Nothing on hand, so the whole amount is on the list."
        case .partiallyHave:
            return "Part of this is in the pantry; the list asks for the rest."
        case .haveEnough:
            return "The pantry covers this. It is kept on the list so you can see that it was "
                 + "counted rather than missed."
        case .needsBridge:
            return "The app could not finish this one. See below."
        case .unresolvedItem:
            return "This did not match anything in the catalogue, so nothing could be "
                 + "subtracted for it."
        case .staple:
            return "A staple: assumed on hand and tracked present or absent, with no "
                 + "quantity kept."
        case .manual:
            return "You added this by hand. It survives every regenerate."
        }
    }

    private var checkedText: String {
        guard let at = line.checkedAt else { return "Yes" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: at)
    }

    // MARK: - The bridge

    /// Both the status and the flag are consulted, because the generator records the condition
    /// in both and either one alone has been the one that went missing (review 03).
    private var needsBridge: Bool {
        line.status == .needsBridge || line.flags.contains(.needsBridge)
    }

    @ViewBuilder
    private var bridgeSection: some View {
        Section {
            Text(bridgeExplanation)
                .font(.subheadline)
            if let item = line.foodItem {
                QuantityField(label: "1 cup weighs", value: $gramsPerCup, unitName: "g")
                Button {
                    // `setDensity` is the one writer of the pair, so the flag and the two
                    // integers cannot disagree. Written onto the ITEM and not the line: the
                    // answer is a fact about butter, not about this week's list, which is what
                    // makes it one tap forever rather than one tap a week.
                    item.setDensity(gramsPerCup > .zero ? gramsPerCup : nil)
                    didSaveDensity = true
                } label: {
                    Text("Save it for \(item.displayName)")
                        .frame(minHeight: 44)
                }
                .disabled(gramsPerCup <= .zero)
                if didSaveDensity {
                    Label(
                        "Saved. Regenerate the list to use it \u{2014} this line keeps the "
                        + "numbers it was built with until you do.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("Match it to an ingredient first, below; a weight per cup has to be "
                   + "stored against something.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Needs a weight per cup")
        }
    }

    /// Names the two real numbers rather than describing the problem in the abstract, because
    /// "could not convert units" is not something he can act on and "you asked for 2 tbsp and
    /// have 4 oz" is.
    private var bridgeExplanation: String {
        let volumeKey = MeasureDimension.volume.rawValue
        let massKey = MeasureDimension.mass.rawValue
        let volume = (line.requested + line.have).first { $0.dimensionKey == volumeKey }
        let mass = (line.requested + line.have).first { $0.dimensionKey == massKey }
        guard let volume = volume, let mass = mass else {
            return "This line mixes a volume and a weight, and \(line.displayName) has no "
                 + "weight per cup stored, so the two cannot be added or subtracted."
        }
        return "\(volume.displayString(system: system)) by volume and "
             + "\(mass.displayString(system: system)) by weight cannot be added without "
             + "knowing what a cup of \(line.displayName) weighs."
    }

    // MARK: - Matching an unresolved line

    @ViewBuilder
    private var matchSection: some View {
        Section {
            Button {
                isPicking = true
            } label: {
                Label("Match it to an ingredient", systemImage: "text.magnifyingglass")
                    .frame(minHeight: 44)
            }
            if didMatchItem {
                Label(
                    "Matched. Regenerate the list and this line will subtract what the pantry "
                    + "has.",
                    systemImage: "checkmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Not matched")
        } footer: {
            Text("Four lines in the turkey and gravy documents are column labels rather than "
               + "ingredients, so they match nothing on purpose. Matching one here teaches "
               + "the app, and the pantry, what it is.")
        }
    }

    // MARK: - The four numbers

    @ViewBuilder
    private var numbersSection: some View {
        Section {
            numbers("Need", line.requested)
            numbers("In the pantry", line.have)
            numbers("Buy", line.toBuy)
            if !line.unmeasuredNote.isEmpty {
                LabeledContent("Unmeasured", value: line.unmeasuredNote)
            }
        } header: {
            Text("The arithmetic")
        } footer: {
            Text(line.list?.subtractInventory ?? true
                 ? "What is on hand was subtracted from what the recipes asked for."
                 : "The pantry was not subtracted on this list.")
        }
    }

    /// Several rows for one role is normal and not a defect to hide: flour wanted by the cup
    /// AND by the gram in one week is two subtotals on this one line, and that is exactly the
    /// case a single text slot used to drop.
    @ViewBuilder
    private func numbers(_ title: String, _ rows: [ShoppingListLineSubtotal]) -> some View {
        if rows.isEmpty {
            LabeledContent(title, value: "\u{2014}")
        } else {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent(title, value: row.displayString(system: system))
                    if !row.conversionNote.isEmpty {
                        Text(row.conversionNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Why this line exists

    @ViewBuilder
    private var sourcesSection: some View {
        Section {
            ForEach(line.orderedSources) { source in
                VStack(alignment: .leading, spacing: 3) {
                    Text(sourceTitle(source))
                        .font(.subheadline.weight(.medium))
                    if !source.originalText.isEmpty {
                        Text(source.originalText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !source.scaledText.isEmpty {
                        Text(source.scaledText)
                            .font(.caption)
                    }
                    if !source.scaleDescription.isEmpty {
                        Text(source.scaleDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Why it is on the list")
        }
    }

    private func sourceTitle(_ source: ShoppingListSource) -> String {
        var parts: [String] = []
        if !source.mealTitle.isEmpty { parts.append(source.mealTitle) }
        if !source.recipeTitle.isEmpty, source.recipeTitle != source.mealTitle {
            parts.append(source.recipeTitle)
        }
        if !source.componentPath.isEmpty { parts.append(source.componentPath) }
        return parts.isEmpty ? "Added by hand" : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - His own note

    @ViewBuilder
    private var noteSection: some View {
        Section {
            TextField("The good anchovies, back of aisle 7", text: $note, axis: .vertical)
                .frame(minHeight: 44)
                .accessibilityLabel("Note to yourself")
            if note != line.noteToSelf {
                Button("Save note") {
                    line.noteToSelf = note
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text("Note")
        } footer: {
            Text("Carried across every regenerate, because you wrote it and the app did not.")
        }
    }
}
