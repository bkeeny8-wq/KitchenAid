import SwiftUI
import SwiftData

/// One recipe, in full.
///
/// This screen is the reason the app can be called stable: it has to render
/// everything the eight bundled documents contain, and between them they
/// contain every shape the content model allows — grouped ingredients with a
/// flat method, a component that is prose with no lines at all, a choice group,
/// quantity ranges, the author's own gram equivalents, a weight-to-time lookup
/// table, timing as a rate rather than a duration, and all-caps instructions
/// that matter more than anything else on the page.
///
/// It renders the EFFECTIVE recipe — content plus his overlay, through
/// `TweakStore.effectiveRecipe(id:)` — and it is where the overlay is written.
/// Both halves were missing. The screen read `loader.recipe(id:)`, the bundled
/// value, so a tweak would have been invisible on the very screen he would make
/// it from while Cook, Shop and the PDF all resolved correctly; and the whole
/// writer half of `TweakStore` had no caller anywhere in the tree. That is code
/// review 01's third unbuilt product decision, and the `loader` is now reached
/// for one thing only: naming a recipe id that resolves to no file at all.
///
/// The boundary is CLAUDE.md's, not this file's. Adjusting an existing line or
/// step is a tweak; adding or removing a line, adding or deleting a step, and
/// retitling the recipe are authoring, which is declined — so there is no
/// affordance for any of them and no hook left for one. Cooking history is the
/// last-made date and nothing else: no rating, no note per cook.
struct RecipeDetailView: View {
    let recipeID: String

    /// Kept for the missing-file case ONLY. Everything on screen comes through the
    /// overlay; `loader` answers the one question the overlay cannot, which is whether
    /// the id resolves to a bundled file at all.
    @Environment(RecipeLoader.self) private var loader
    @Environment(\.modelContext) private var modelContext

    /// OPTIONAL on purpose. The App builds `TweakStore` in its launch task, and an
    /// `@Environment` lookup declared non-optional traps when the value is absent — which
    /// would make opening a recipe a crash rather than a missing overlay. The window
    /// between first render and that task is short and real.
    @Environment(TweakStore.self) private var injectedTweakStore: TweakStore?

    /// THE INVALIDATION, not the data. `resolvedRecipe` reads it; see the note there.
    @Query private var allTweaks: [RecipeTweak]

    /// Which line or step the tweak sheet is open on, nil for closed.
    @State private var editing: RecipeTweakTarget?
    @State private var noteDraft = ""
    @State private var didSeedNote = false

    var body: some View {
        if let resolved = resolvedRecipe {
            content(resolved)
        } else {
            missing
        }
    }

    // MARK: - Content and overlay

    /// `TweakStore` holds no state of its own — it is a container plus the loader, and
    /// every method fetches — so standing one up when the environment has none is cheap
    /// and cannot disagree with the injected one. `CookView` does the same.
    @MainActor
    private var tweakStore: TweakStore {
        injectedTweakStore ?? TweakStore(container: modelContext.container, loader: loader)
    }

    /// Content plus his tweaks, applied to a COPY. Nothing here mutates a `Recipe`.
    @MainActor
    private var resolvedRecipe: ResolvedRecipe? {
        // READING THE QUERY IS THE SUBSCRIPTION, and the subscription is the only reason
        // an edit made on this screen appears on it. `TweakStore` is `@Observable` but
        // holds no observable state — a container plus a loader, every method fetching —
        // so writing an override through it notifies nothing at all. `@Query` is what
        // invalidates a view when a row changes, and SwiftData fetches it lazily, so a
        // query nobody reads is a query nobody is subscribed to: the favourite toggle and
        // the saved note would both appear to do nothing until the screen was left and
        // reopened, which reads as the write having failed.
        //
        // Unfiltered, as `TodayView` has it: a `#Predicate` would need `recipeID` at
        // `init`, and rows are proportional to the recipes he has actually touched.
        _ = allTweaks.count
        return tweakStore.effectiveRecipe(id: recipeID)
    }

    @MainActor
    @ViewBuilder
    private func content(_ resolved: ResolvedRecipe) -> some View {
        List {
            header(resolved)
            emphasis(resolved)
            cook(resolved)
            lapsedNotice(resolved)
            yours(resolved)
            ingredients(resolved)
            method(resolved)
            tables(resolved)
            notes(resolved)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(resolved.title)
        .navigationBarTitleDisplayMode(.inline)
        // The sheet is handed the resolved VALUE it was opened over, so it cannot be
        // re-resolving underneath itself while he types. Dismissing it clears `editing`,
        // which re-runs this body and re-resolves — which is how his new amount appears on
        // the row behind without anything having to tell it to.
        .sheet(item: $editing) { target in
            NavigationStack {
                switch target.kind {
                case .ingredient:
                    IngredientTweakSheet(resolved: resolved, lineID: target.key)
                case .step:
                    StepTweakSheet(resolved: resolved, stepID: target.key)
                }
            }
        }
        // `onAppear` and not `task`: the closure `task` takes is `@Sendable` and so is not
        // main-actor isolated, and this reads the resolved overlay.
        .onAppear { seedNote(resolved) }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ resolved: ResolvedRecipe) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(resolved.title).font(.title3.weight(.semibold))
                if !resolved.summary.isEmpty {
                    Text(resolved.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    if !resolved.yieldText.isEmpty {
                        metric("Makes", resolved.yieldText)
                    }
                    metric("Serves", servingsText(resolved))
                    if let active = resolved.activeMinutes {
                        metric("Active", "\(active) min")
                    }
                    if let total = resolved.totalMinutes {
                        metric("Total", minutesText(total))
                    }
                }
                // The turkey times by weight and has no total at all, which is
                // the correct answer rather than a missing one.
                //
                // Through `resolved.recipe` because `ResolvedRecipe` forwards most of the
                // content surface but not these three. `CookView` reaches them the same
                // way; the alternative is widening a type two other agents are reading.
                if let perPound = resolved.recipe.minutesPerPound {
                    HStack(spacing: 18) {
                        metric("Per pound", "\(perPound.humanDescription) min")
                        if let temp = resolved.recipe.ovenTempF {
                            metric("Oven", "\(temp)\u{00B0}F")
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium))
        }
    }

    /// "4", or "about 4" when the number is one Brandon supplied in passing
    /// rather than one the document claims.
    private func servingsText(_ resolved: ResolvedRecipe) -> String {
        let n = resolved.servings.humanDescription
        return resolved.recipe.servingsApproximate ? "about \(n)" : n
    }

    private func minutesText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }

    // MARK: - Shouted instructions

    /// `DO. NOT. SALT.` and `DO NOT USE SALTED BUTTER.` are the whole point of
    /// the turkey — it, its butter and its gravy are all deliberately unsalted
    /// so the cook salts once at the end. The importer was dropping both lines
    /// entirely, so they get the most prominent treatment on the screen rather
    /// than being filed with the other notes.
    @ViewBuilder
    private func emphasis(_ resolved: ResolvedRecipe) -> some View {
        let shouted = resolved.notes.filter { isShouted($0.text) }
        if !shouted.isEmpty {
            Section {
                ForEach(Array(shouted.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(note.text).font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    private func isShouted(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        return letters.count > 3 && letters.allSatisfy { $0.isUppercase }
    }

    // MARK: - Cook

    /// Into cook mode, at ×1.
    ///
    /// `.one` is the honest scale here and not a placeholder: a recipe opened from the
    /// library has no meal behind it, so there is no attendance to divide by servings.
    /// The plan's scale comes from `MealScaling` on the Today screen, where a
    /// `MealRecipe` exists to derive it from — a dish cooked off a plan must reach the
    /// stove at the scale it was planned at.
    ///
    /// Below the shouted notes on purpose. `DO NOT USE SALTED BUTTER.` is the kind of
    /// instruction that is useless after the fact, so it stays above the button that
    /// starts the cooking — the same reason `CookView` shows the shouts before its
    /// first step.
    @ViewBuilder
    private func cook(_ resolved: ResolvedRecipe) -> some View {
        Section {
            NavigationLink {
                CookView(recipeID: resolved.id, scale: .one)
            } label: {
                Label("Cook this", systemImage: "flame.fill")
                    .font(.body.weight(.medium))
            }
        } footer: {
            Text("One step at a time, in type you can read from the stove. Finishing "
                 + "records the date and nothing else.")
        }
    }

    // MARK: - Lapsed overrides

    /// One line, and then it points somewhere else.
    ///
    /// An override joins content on `lineID`/`stepID`, so a revised recipe file makes a
    /// stale tweak LAPSE rather than silently re-pointing at whatever ingredient now
    /// occupies that slot. Saying so here is the difference between a tweak that stopped
    /// applying and a tweak he thinks is still applying.
    ///
    /// The full report — which override, what it said, and the action that clears it —
    /// belongs on `DiagnosticsView` beside the other content problems, and is deliberately
    /// NOT duplicated here: `TweakStore.clearLapsed(_:in:)` wants one caller, not two
    /// screens inventing two sets of words for the same decision.
    @ViewBuilder
    private func lapsedNotice(_ resolved: ResolvedRecipe) -> some View {
        let count = resolved.lapsedOverrides.count
        if count > 0 {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "doc.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text(count == 1
                         ? "One of your changes no longer matches this recipe file."
                         : "\(count) of your changes no longer match this recipe file.")
                        .font(.subheadline)
                }
            } footer: {
                Text("Nothing has been removed. The recipe warnings screen lists them and "
                     + "can clear them \u{2014} reach it from the orange banner at the top "
                     + "of any tab.")
            }
        }
    }

    // MARK: - His own layer

    /// The favourite flag, one note he rewrites, and the date he last made it.
    ///
    /// That date is THE WHOLE OF COOKING HISTORY. He was offered a journal — a rating and
    /// a note per cook, "how did it go" — and declined it, so there is nothing here per
    /// occasion and no room left for one: `RecipeTweak.notes` is deliberately one field he
    /// overwrites rather than a list of dated entries, because a note row carrying a date
    /// IS the journal.
    @MainActor
    @ViewBuilder
    private func yours(_ resolved: ResolvedRecipe) -> some View {
        Section {
            Toggle("Favourite", isOn: favoriteBinding(resolved))
                .frame(minHeight: 44)
            if let made = resolved.lastMadeAt {
                LabeledContent(
                    "Last made",
                    value: made.formatted(date: .abbreviated, time: .omitted)
                )
            }
            // Seeded into `@State` and saved on a tap. A `TextField` bound straight to the
            // store writes on every keystroke, which makes a half-typed note a saved note.
            TextField(
                "Too much horseradish, 1 tbsp next time",
                text: $noteDraft,
                axis: .vertical
            )
            .frame(minHeight: 44)
            .accessibilityLabel("Your notes on this recipe")
            if noteIsDirty(resolved) {
                Button("Save note") {
                    tweakStore.setNotes(noteDraft, for: resolved.id)
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text("Yours")
        } footer: {
            Text("Cooking history is the date, and finishing a cook writes it. Your note "
                 + "and your changes are kept apart from the recipe file, so re-importing "
                 + "the document does not touch them.")
        }
    }

    /// Trimmed on both sides of the comparison, because `TweakStore.setNotes` trims what it
    /// stores: without it a trailing space leaves "Save note" on screen for ever, offering
    /// to save something that is already saved.
    private func noteIsDirty(_ resolved: ResolvedRecipe) -> Bool {
        noteDraft.trimmingCharacters(in: .whitespacesAndNewlines) != resolved.userNotes
    }

    private func seedNote(_ resolved: ResolvedRecipe) {
        guard !didSeedNote else { return }
        didSeedNote = true
        noteDraft = resolved.userNotes
    }

    /// Written through on every flip rather than held in `@State`: there is one field, the
    /// write is a row update, and a local copy could disagree with the store after a cook
    /// screen or the diagnostics screen has touched the same row.
    @MainActor
    private func favoriteBinding(_ resolved: ResolvedRecipe) -> Binding<Bool> {
        Binding(
            get: { resolved.isFavorite },
            set: { newValue in tweakStore.setFavorite(newValue, for: resolved.id) }
        )
    }

    // MARK: - Ingredients

    @MainActor
    @ViewBuilder
    private func ingredients(_ resolved: ResolvedRecipe) -> some View {
        ForEach(Array(resolved.components.enumerated()), id: \.offset) { _, component in
            Section {
                if !component.summary.isEmpty {
                    Text(component.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(component.lines) { line in
                    if line.isChoice {
                        // NOT editable, and not an oversight. A choice row is one of
                        // several ways to make the recipe — the pancake offers Cinnamon,
                        // Nutmeg, or Both — and carries no quantity of its own, so there is
                        // no amount to adjust. Which one he uses is `CookView.choices`, and
                        // that is session state on purpose: persisting it would be
                        // authoring a variant.
                        choiceRow(line)
                    } else if line.lineID.isEmpty {
                        // An override joins on `lineID`, and every `TweakStore` writer
                        // guards on it being non-empty. Offering a tap that would silently
                        // do nothing is worse than offering none; `RecipeLoader`'s
                        // integrity pass already reports the file.
                        ingredientRow(line, in: resolved, isEditable: false)
                    } else {
                        Button {
                            editing = RecipeTweakTarget(kind: .ingredient, key: line.lineID)
                        } label: {
                            ingredientRow(line, in: resolved, isEditable: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Adjust the amount, preparation or note")
                    }
                }
            } header: {
                // A single unnamed group is the whole ingredient list, so
                // labelling it "Ingredients" reads better than a blank header.
                Text(component.title.isEmpty
                     ? (resolved.hasSingleUnnamedComponent ? "Ingredients" : "")
                     : component.title)
            }
        }
    }

    @ViewBuilder
    private func ingredientRow(
        _ line: IngredientLine,
        in resolved: ResolvedRecipe,
        isEditable: Bool
    ) -> some View {
        let isChanged = resolved.isOverridden(lineID: line.lineID)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(quantityText(line))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 76, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.displayName)
                if !line.preparation.isEmpty {
                    Text(line.preparation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // The author's own second measurement, when the document gave
                // one: "1 1/2 cups all-purpose flour (190g)".
                if let alt = line.altQuantity {
                    Text("or \(alt.displayString())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // SHOWN, NOT IMPLIED. A screen that silently disagrees with the recipe
                // file is the one artefact nobody can debug, which is why the PDF exporter
                // already prints a footnote for each of these. `cookDisplayText` is the
                // same string it footnotes, so the sheet, the row and the printed page
                // cannot word one fact three ways.
                if isChanged, let asWritten = asWrittenText(line, in: resolved) {
                    Text("As written: \(asWritten)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !line.note.isEmpty {
                    Text(line.note)
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isChanged { changedBadge }
            if isEditable {
                Image(systemName: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // The row is the button and already carries its own hint; a second
                    // announcement for the glyph is noise in front of it.
                    .accessibilityHidden(true)
            }
        }
    }

    private var changedBadge: some View {
        Text("Changed")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .accessibilityLabel("Changed by you")
    }

    /// `quantityDisplay` goes through `displayString()` and `humanDescription` and never
    /// `exactDescription`, which is what produced the "23 1111/1135 tsp" label review 03
    /// found. It is EMPTY for a line with neither a quantity nor an unmeasured note, which
    /// is exactly what an override that clears the measurement leaves — and a blank column
    /// reads as a rendering fault rather than as "no amount".
    private func quantityText(_ line: IngredientLine) -> String {
        let text = line.quantityDisplay
        return text.isEmpty ? "\u{2014}" : text
    }

    private func asWrittenText(_ line: IngredientLine, in resolved: ResolvedRecipe) -> String? {
        guard let original = resolved.originalLine(id: line.lineID) else { return nil }
        let text = original.cookDisplayText
        return text.isEmpty ? nil : text
    }

    /// One of several ways to make the recipe, not a thing to buy. The pancake
    /// offers Cinnamon, Nutmeg, or Both.
    private func choiceRow(_ line: IngredientLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.displayName).font(.subheadline.weight(.medium))
                if !line.choiceText.isEmpty {
                    Text(line.choiceText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Method

    /// One flat list across the whole dish. A component groups ingredients; it
    /// is not a mini-recipe with its own steps, and the first fixture proved it.
    ///
    /// Each step is tappable to FIX it — its wording and its timing. There is no add, no
    /// delete and no reorder: `stepID` is slug-of-title plus an occurrence number, so
    /// changing the shape of the method is a change to the bundled file, and the file is
    /// where the method is authored.
    @MainActor
    @ViewBuilder
    private func method(_ resolved: ResolvedRecipe) -> some View {
        if !resolved.steps.isEmpty {
            Section("Method") {
                ForEach(resolved.steps) { step in
                    if step.stepID.isEmpty {
                        stepRow(step, in: resolved, isEditable: false)
                    } else {
                        Button {
                            editing = RecipeTweakTarget(kind: .step, key: step.stepID)
                        } label: {
                            stepRow(step, in: resolved, isEditable: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Fix the wording or the timing of this step")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stepRow(
        _ step: RecipeStep,
        in resolved: ResolvedRecipe,
        isEditable: Bool
    ) -> some View {
        let isChanged = resolved.isOverridden(stepID: step.stepID)
        // Hoisted out of the view tree rather than computed inside the `if` below: a
        // declaration nested in a result-builder branch is one more thing with no compiler
        // here to check, and this reads the same.
        let changedCaption = isChanged ? stepAsWrittenCaption(step, in: resolved) : ""
        HStack(alignment: .top, spacing: 12) {
            Text("\(step.number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                // The timing and the Changed badge used to live INSIDE `if
                // !step.title.isEmpty`, which hid both on an untitled step — and
                // untitled is the common case, not the edge: 6 of the turkey's 10
                // steps have no title, 7 of the gravy's, 6 of the pancakes'. The
                // caption below is not inside that branch, so a timing-only tweak
                // on an untitled step rendered "As written: 30 min" with his new
                // value nowhere on the row: the silent disagreement this screen's
                // own comments are about, arrived at from the other end.
                // `CookStepCard` always had this right.
                if !step.title.isEmpty || step.durationText != nil || isChanged {
                    HStack(spacing: 6) {
                        if !step.title.isEmpty {
                            Text(step.title).font(.subheadline.weight(.semibold))
                        }
                        if let duration = step.durationText {
                            Text(duration)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        if isChanged { changedBadge }
                    }
                }
                Text(step.body).font(.subheadline)
                if !changedCaption.isEmpty {
                    Text(changedCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isEditable {
                Image(systemName: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }

    /// Only the parts that actually differ, because a step body is a paragraph and
    /// reprinting the whole of it under every corrected step would bury the correction.
    private func stepAsWrittenCaption(_ step: RecipeStep, in resolved: ResolvedRecipe) -> String {
        guard let original = resolved.originalStep(id: step.stepID) else { return "" }
        var parts: [String] = []
        if step.title != original.title, !original.title.isEmpty {
            parts.append(original.title)
        }
        if step.body != original.body, !original.body.isEmpty {
            parts.append(original.body)
        }
        if step.minMinutes != original.minMinutes || step.maxMinutes != original.maxMinutes {
            parts.append(original.durationText ?? "no timing")
        }
        guard !parts.isEmpty else { return "" }
        return "As written: " + parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Printed tables

    /// The turkey's weight-to-time chart. Eight rows of weight against total,
    /// covered and uncovered time, because a 10 lb bird and a 24 lb bird share
    /// the recipe and nothing else.
    ///
    /// Not tweakable: the chart is the document's, and no override row points at a table.
    @ViewBuilder
    private func tables(_ resolved: ResolvedRecipe) -> some View {
        ForEach(resolved.recipe.tables) { table in
            Section(table.name) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(table.labelled(row).enumerated()), id: \.offset) { index, pair in
                            if index == 0 {
                                Text(pair.value).font(.subheadline.weight(.semibold))
                            } else {
                                HStack {
                                    Text(pair.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 8)
                                    Text(pair.value).font(.caption.weight(.medium))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Notes

    @ViewBuilder
    private func notes(_ resolved: ResolvedRecipe) -> some View {
        let ordinary = resolved.notes.filter { !isShouted($0.text) }
        if !ordinary.isEmpty {
            Section("Notes") {
                ForEach(Array(ordinary.enumerated()), id: \.offset) { _, note in
                    Text(note.text).font(.subheadline)
                }
            }
        }
    }

    // MARK: - Missing

    /// A recipe id that resolves to nothing. Across the content and persistence
    /// boundary there is no cascade that could have prevented this: the far end
    /// is a file in the app, not a row, so a plan or a tweak can outlive the
    /// recipe it points at. Saying so is better than an empty screen.
    private var missing: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(loader.isMissing(recipeID) ? "Recipe not found" : "No recipe")
                .font(.headline)
            // `isMissing` is false for an EMPTY id, and that is the distinction worth
            // drawing: an empty id is an entry that never named a recipe, not a lost one.
            Text(loader.isMissing(recipeID)
                 ? "No bundled recipe has the id \u{201C}\(recipeID)\u{201D}. It may have "
                   + "been renamed or removed in a later build."
                 : "Nothing named a recipe here, so there is nothing to show.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .navigationTitle("Not found")
    }
}

// MARK: - Which tweak sheet is open

/// `.sheet(item:)` needs an `Identifiable`, and a `lineID` or a `stepID` is a `String`,
/// which is `Identifiable` nowhere in the SDK. Scoped to this screen deliberately rather
/// than made a conformance on `String`: a public extension making every string in the app
/// identifiable by its own value is the kind of thing that collides with another file.
/// `PlanSheetDay` is the same move for a `Date`.
struct RecipeTweakTarget: Identifiable, Hashable {
    enum Kind: String, Hashable { case ingredient, step }

    let kind: Kind
    /// The `lineID` or `stepID` the sheet writes against.
    let key: String

    /// Both sheets share one piece of state, and nothing stops a line and a step slugging
    /// to the same string, so the kind is part of the identity.
    var id: String { "\(kind.rawValue):\(key)" }
}
