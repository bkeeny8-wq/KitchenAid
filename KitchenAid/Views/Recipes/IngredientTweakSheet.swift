import SwiftUI
import SwiftData

/// "Too much horseradish, 1 tbsp next time."
///
/// One ingredient line and the three things CLAUDE.md's decision table allows him to
/// change about it: the quantity, the preparation, and a note. Until this sheet and
/// `StepTweakSheet` existed, the whole writer half of `TweakStore` had no caller anywhere
/// in the tree -- code review 01's third unbuilt product decision, written up as done.
///
/// **What it deliberately cannot do.** There is no name field, no add-a-line, no
/// delete-a-line. Changing what an ingredient IS, or whether it is in the recipe at all,
/// is authoring, and recipes are authored before they arrive; `IngredientOverride` has no
/// name column for exactly this reason. The boundary is not tidiness: `matchKey` is built
/// from the name, so a renamed line would stop resolving against the catalogue and leave
/// the shopping list and the pantry without saying so.
struct IngredientTweakSheet: View {

    /// Content plus overlay, as the detail screen resolved it when the sheet was
    /// presented. A VALUE, so it cannot change under the sheet; every write below
    /// dismisses, and the screen behind re-resolves.
    let resolved: ResolvedRecipe
    let lineID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RecipeLoader.self) private var loader

    /// OPTIONAL on purpose, like every other reader of this service. The App builds it in
    /// its launch task, and an `@Environment` lookup declared non-optional traps when the
    /// value is absent -- which would make opening this sheet a crash rather than a
    /// missing overlay. `tweakStore` below is the fallback.
    @Environment(TweakStore.self) private var injectedTweakStore: TweakStore?

    @State private var isMeasured = false
    @State private var amount: Rational = .zero
    @State private var unit: KitchenUnit = UnitCatalog.each
    @State private var preparation = ""
    @State private var note = ""
    @State private var didSeed = false

    var body: some View {
        Group {
            if let line = resolved.line(id: lineID) {
                form(line)
            } else {
                // Unreachable from the detail screen, which only offers this sheet for a
                // line it has just rendered. Said rather than shown blank, because the
                // other way to arrive here is a recipe file revised between render and tap.
                EmptyStateView(
                    kind: .somethingWrong,
                    symbol: "questionmark.circle",
                    headline: "That line is gone",
                    detail: "The recipe no longer has this ingredient, so there is nothing "
                          + "to adjust."
                )
            }
        }
        .navigationTitle("Adjust")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(isSaveBlocked)
            }
        }
    }

    // MARK: - The service

    /// `TweakStore` holds no state of its own -- it is a container plus the loader, and
    /// every method fetches -- so standing one up when the environment has none is cheap
    /// and cannot disagree with the injected one. Same reasoning as `CookView`.
    @MainActor
    private var tweakStore: TweakStore {
        injectedTweakStore ?? TweakStore(container: modelContext.container, loader: loader)
    }

    // MARK: - The form

    @MainActor
    @ViewBuilder
    private func form(_ line: IngredientLine) -> some View {
        Form {
            asWrittenSection(line)
            amountSection(line)
            preparationSection
            noteSection
            revertSection
        }
        // `onAppear` rather than `task`: the closure `task` takes is `@Sendable` and so is
        // not main-actor isolated, and the seed reads a resolved value the main actor owns.
        .onAppear { seed(line) }
    }

    // MARK: - As written

    /// What the document says, beside what he is about to say instead.
    ///
    /// Shown on this sheet as well as on the row behind it for the same reason the PDF
    /// exporter prints footnotes: an artefact that silently disagrees with the recipe file
    /// is the one nobody can debug six months later.
    @ViewBuilder
    private func asWrittenSection(_ line: IngredientLine) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.displayName.isEmpty ? lineID : line.displayName)
                    .font(.body.weight(.medium))
                if let text = asWrittenText, !text.isEmpty {
                    Text("As written: \(text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        } footer: {
            Text("The name is not editable. Renaming an ingredient is authoring it, and it "
                 + "would stop matching the pantry and the shopping list.")
        }
    }

    private var originalLine: IngredientLine? { resolved.originalLine(id: lineID) }

    /// `cookDisplayText` and not the parsed fields, because it prefers the verbatim
    /// importer line -- which is the same string the PDF footnote prints, so the two
    /// cannot word the same fact differently.
    private var asWrittenText: String? { originalLine?.cookDisplayText }

    // MARK: - Amount

    /// A quantity control only for a line that HAS one, as written or as he has already
    /// set it.
    ///
    /// "Pinch flaky salt", "salt to taste" and "parsley, for garnish" are a nil quantity
    /// plus an `unmeasuredNote`, and the document is right about them: there is no number a
    /// spoon measures there, and a field offering one invites a measurement the recipe
    /// deliberately declines to make. Preparation and note still apply to those lines.
    private var canMeasure: Bool {
        resolved.line(id: lineID)?.quantity != nil || originalLine?.quantity != nil
    }

    @ViewBuilder
    private func amountSection(_ line: IngredientLine) -> some View {
        if canMeasure {
            Section {
                Toggle("Measured amount", isOn: $isMeasured)
                    .frame(minHeight: 44)
                if isMeasured {
                    // `QuantityField` and not a second numeric field: recipes are written
                    // in halves, thirds and quarters, and it is also the one place in the
                    // app where `exactDescription` is legitimate, because the field is
                    // editable text and not a label.
                    QuantityField(
                        label: "Amount",
                        value: $amount,
                        unitName: unit.name(for: amount)
                    )
                    UnitPicker(
                        label: "Unit",
                        dimension: unit.dimension,
                        countNoun: unit.isCount ? unit.code : "",
                        unit: $unit
                    )
                }
            } header: {
                Text("How much")
            } footer: {
                Text(amountFooter(line))
            }
        }
    }

    private func amountFooter(_ line: IngredientLine) -> String {
        guard isMeasured else {
            return "The line keeps its name and shows no amount, the way a pinch or a "
                 + "to-taste line does."
        }
        if amount.isZero {
            // A real zero is not a quantity anywhere in this schema -- nil means there is
            // no amount, and zero would enter arithmetic as one. So Save is blocked rather
            // than silently writing the one value the model forbids.
            return "Zero is not an amount. Type one, or switch the measured amount off."
        }
        let typed = Quantity(amount: amount, unit: unit).displayString()
        if line.isRange {
            // `shoppingAmount` returns `amountMax ?? amount`, so an exact override has to
            // drop the bundled upper bound or the shopping list keeps buying for the top
            // of a range he has already settled.
            return "Saves \(typed), and drops the recipe's upper figure -- the list will "
                 + "buy for your amount and not for the top of the range."
        }
        return "Saves \(typed)."
    }

    // MARK: - Preparation

    @ViewBuilder
    private var preparationSection: some View {
        Section {
            TextField("minced, drained, 1/2 inch thick", text: $preparation, axis: .vertical)
                .frame(minHeight: 44)
                .accessibilityLabel("Preparation")
        } header: {
            Text("Preparation")
        } footer: {
            // `IngredientOverride.effectivePreparation` treats "" as leave-the-bundled-
            // text-alone, so an empty field is a revert and NOT a way to delete the
            // document's own wording. Saying so is cheaper than him typing a space.
            Text("Emptying this puts the recipe's own wording back. It is kept apart from "
                 + "the name so that diced and sliced onion still merge into one line on "
                 + "the shopping list.")
        }
    }

    // MARK: - His note

    @ViewBuilder
    private var noteSection: some View {
        Section {
            TextField("Half this next time", text: $note, axis: .vertical)
                .frame(minHeight: 44)
                .accessibilityLabel("Note on this ingredient")
        } header: {
            Text("Note")
        } footer: {
            Text("One note that you rewrite, on this ingredient. Not a record per cook.")
        }
    }

    // MARK: - Revert

    /// REVERT IS A DELETE, AND `setQuantity(nil, …)` IS NOT IT.
    ///
    /// Read `TweakStore.apply(_:toLine:)`: a row that EXISTS carrying no quantity means he
    /// cleared the measurement -- the pinch representation applied to an override -- while
    /// NO override is the ABSENCE of the row. So `setQuantity(nil, …)` writes a row whose
    /// quantity differs from the bundled one, `finishIngredient` keeps it, and the line
    /// stays flagged as changed for ever with its amount gone. `clearIngredientOverride`
    /// is the only thing that puts the document's value back, and it is what
    /// `clearLapsed(_:in:)` calls for the same reason.
    @MainActor
    @ViewBuilder
    private var revertSection: some View {
        if resolved.isOverridden(lineID: lineID) {
            Section {
                Button("Back to as written", role: .destructive) {
                    tweakStore.clearIngredientOverride(lineID: lineID, in: resolved.id)
                    dismiss()
                }
                .frame(minHeight: 44)
            } footer: {
                if let text = asWrittenText, !text.isEmpty {
                    Text("Drops your change and puts back: \(text)")
                } else {
                    Text("Drops your change and leaves the line as the recipe file writes it.")
                }
            }
        }
    }

    // MARK: - Seeding and saving

    /// Seeded ONCE from the resolved line, so reopening the sheet shows his own values and
    /// not the document's. Seeded into `@State` rather than bound through to the store,
    /// because a field bound straight to a row makes a half-typed note a saved note.
    private func seed(_ line: IngredientLine) {
        guard !didSeed else { return }
        didSeed = true
        preparation = line.preparation
        note = line.note
        if let quantity = line.quantity {
            isMeasured = true
            amount = quantity.amount
            unit = quantity.unit
            return
        }
        isMeasured = false
        // A unit to come back to if he switches the amount on again. The document's own, so
        // the picker opens on the dimension the recipe measured this in -- volume, mass and
        // count are not interconvertible and `UnitPicker` offers only one of them.
        if let was = originalLine?.quantity {
            amount = was.amount
            unit = was.unit
        }
    }

    /// Blocked for a line that is gone -- the writers would no-op harmlessly, but an
    /// enabled Save that does nothing is a worse answer than a disabled one -- and for a
    /// measured amount of zero, which is the one value this schema's quantities never take:
    /// nil means there is no amount, and zero would enter arithmetic as one.
    private var isSaveBlocked: Bool {
        resolved.line(id: lineID) == nil || (canMeasure && isMeasured && amount.isZero)
    }

    /// Three writes, and the order between them does not matter: every writer in
    /// `TweakStore` fetches-or-creates the row for this line, seeds its quantity from the
    /// bundled value first, and drops the row again if what is left says nothing. So a save
    /// that changes only the note cannot erase the quantity, and a save that puts all three
    /// back leaves no residue.
    ///
    /// THE TEXT THAT MATCHES THE DOCUMENT IS WRITTEN AS `""`, AND THAT IS NOT TIDYING.
    /// `IngredientOverride.effectivePreparation` treats `""` as leave-the-bundled-text-
    /// alone, and `finishIngredient` keeps any row whose `preparationOverride` is non-empty.
    /// The fields are seeded from the resolved line so that reopening the sheet shows his
    /// own values — which means an untouched Save would otherwise write the document's own
    /// "minced" into the override and badge the line "Changed" for a change nobody made.
    /// Mapping equal-to-the-document back onto the sentinel also makes "type it back the way
    /// the recipe has it" a revert, which is what he would expect it to be.
    @MainActor
    private func save() {
        let store = tweakStore
        if canMeasure {
            let typed: Quantity? = isMeasured ? Quantity(amount: amount, unit: unit) : nil
            store.setQuantity(typed, forLine: lineID, in: resolved.id)
        }
        // Trimmed on this side too, because `TweakStore` trims what it stores: without it a
        // trailing space makes the comparison below miss and writes a one-space override.
        let typedPreparation = preparation.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // The document's side is trimmed as well. A bundled field with a trailing space
        // would otherwise never compare equal to anything he can type, and every save would
        // write an override that changes nothing visible.
        let bundledPreparation = (originalLine?.preparation ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledNote = (originalLine?.note ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        store.setPreparation(
            typedPreparation == bundledPreparation ? "" : typedPreparation,
            forLine: lineID,
            in: resolved.id
        )
        store.setIngredientNote(
            typedNote == bundledNote ? "" : typedNote,
            forLine: lineID,
            in: resolved.id
        )
        dismiss()
    }
}
