import SwiftUI
import SwiftData

/// "Step 6 should say 3 minutes, and the body is wrong."
///
/// One step of the method, and the writer for `StepOverride` -- which had no caller
/// anywhere in the tree before this sheet. CLAUDE.md's decision is "notes and tweaks only:
/// adjust a quantity, fix a step, add a note after cooking", and this is the fix-a-step
/// half.
///
/// **It edits a step; it does not write the method.** There is no add-a-step, no
/// delete-a-step and no reorder. `stepID` is slug-of-title plus an occurrence number, so
/// inserting or removing steps is a change to the bundled file, and the file is where the
/// method is authored. The timing is here as well as the text because `StepOverride`'s own
/// example is a duration -- a step whose stated time is wrong at his altitude, in his
/// oven, with his pan, is the commonest correction a cook makes.
struct StepTweakSheet: View {

    /// Content plus overlay, as the detail screen resolved it when the sheet was
    /// presented. A VALUE; every write below dismisses and the screen behind re-resolves.
    let resolved: ResolvedRecipe
    let stepID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RecipeLoader.self) private var loader

    /// Optional for the same reason every other reader declares it so: the App injects it
    /// in its launch task, and a non-optional `@Environment` lookup traps when the value
    /// is absent.
    @Environment(TweakStore.self) private var injectedTweakStore: TweakStore?

    @State private var title = ""
    /// Not `body`, which is the one property name a `View` cannot spend on anything else.
    @State private var bodyText = ""
    @State private var isTimed = false
    @State private var minutes = 0
    @State private var hasUpperBound = false
    @State private var upperMinutes = 0
    /// The pair the step arrived with, kept so a save that changes only the text can write
    /// the timing back in the SHAPE it came in. See `sameTiming`.
    @State private var seededMin: Int?
    @State private var seededMax: Int?
    @State private var didSeed = false

    var body: some View {
        Group {
            if let step = resolved.step(id: stepID) {
                form(step)
            } else {
                EmptyStateView(
                    kind: .somethingWrong,
                    symbol: "questionmark.circle",
                    headline: "That step is gone",
                    detail: "The recipe no longer has this step, so there is nothing to fix."
                )
            }
        }
        .navigationTitle("Fix step")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    // A step that is gone has nothing to write. The writers would no-op
                    // harmlessly, but an enabled Save that does nothing is a worse answer
                    // than a disabled one.
                    .disabled(resolved.step(id: stepID) == nil)
            }
        }
    }

    /// Stood up when the environment has none, exactly as `CookView` does it: the service
    /// holds no state of its own, so a local one cannot disagree with the injected one.
    @MainActor
    private var tweakStore: TweakStore {
        injectedTweakStore ?? TweakStore(container: modelContext.container, loader: loader)
    }

    private var originalStep: RecipeStep? { resolved.originalStep(id: stepID) }

    // MARK: - The form

    @MainActor
    @ViewBuilder
    private func form(_ step: RecipeStep) -> some View {
        Form {
            asWrittenSection(step)
            textSection
            timingSection
            revertSection
        }
        .onAppear { seed(step) }
    }

    /// The document's own words, beside his. Same reason the PDF prints footnotes: an
    /// artefact that silently disagrees with the recipe file cannot be debugged later.
    @ViewBuilder
    private func asWrittenSection(_ step: RecipeStep) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Step \(step.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let original = resolved.originalStep(id: stepID) {
                    if !original.title.isEmpty {
                        Text(original.title).font(.subheadline.weight(.medium))
                    }
                    if !original.body.isEmpty {
                        Text("As written: \(original.body)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let duration = original.durationText {
                        Text("As written: \(duration)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var textSection: some View {
        Section {
            TextField("Title", text: $title, axis: .vertical)
                .frame(minHeight: 44)
                .accessibilityLabel("Step title")
            TextField("What to do", text: $bodyText, axis: .vertical)
                .frame(minHeight: 88)
                .accessibilityLabel("Step instructions")
        } header: {
            Text("The step")
        } footer: {
            // `effectiveTitle`/`effectiveBody` treat "" as leave-the-bundled-text-alone, so
            // emptying a field is a revert and not a way to blank out the document's words.
            Text("Emptying either one puts the recipe's own wording back.")
        }
    }

    // MARK: - Timing

    @ViewBuilder
    private var timingSection: some View {
        Section {
            Toggle("Has a timing", isOn: $isTimed)
                .frame(minHeight: 44)
            if isTimed {
                Stepper(value: $minutes, in: 0...1440) {
                    Text("\(minutes) min").monospacedDigit()
                }
                .frame(minHeight: 44)
                .accessibilityValue("\(minutes) minutes")
                Toggle("Up to a longer time", isOn: $hasUpperBound)
                    .frame(minHeight: 44)
                if hasUpperBound {
                    Stepper(value: $upperMinutes, in: 0...1440) {
                        Text("up to \(upperMinutes) min").monospacedDigit()
                    }
                    .frame(minHeight: 44)
                    .accessibilityValue("up to \(upperMinutes) minutes")
                }
            }
        } header: {
            Text("How long")
        } footer: {
            Text(timingFooter)
        }
    }

    private var timingFooter: String {
        guard isTimed else {
            // `hasMinutesOverride` with both bounds nil is the one way to say "this step is
            // untimed" as a deliberate decision rather than as a step nobody has touched.
            // It is why the flag exists instead of being inferred from the two `Int?`s.
            return "Saved as a step with no duration, which is different from a step whose "
                 + "timing you have never touched. Cook mode shows no timer for it."
        }
        if hasUpperBound {
            // The two steppers are independent, so the upper bound is sorted at write time
            // rather than by narrowing the second stepper's range -- a `ClosedRange` whose
            // lower bound passes its upper traps, and a stepper is the wrong place to find
            // that out.
            let high = max(minutes, upperMinutes)
            let low = min(minutes, upperMinutes)
            return low == high
                ? "Saved as \(low) min."
                : "Saved as \(low) to \(high) min. Cook mode times the longer end, so a "
                  + "timer never fires early on a range."
        }
        return "Saved as \(minutes) min."
    }

    // MARK: - Revert

    /// The row is DELETED, which is the only thing that puts the document's step back.
    /// Writing empty strings would leave a row that reports the step as changed while
    /// changing nothing -- see the same note on `IngredientTweakSheet.revertSection`.
    @MainActor
    @ViewBuilder
    private var revertSection: some View {
        if resolved.isOverridden(stepID: stepID) {
            Section {
                Button("Back to as written", role: .destructive) {
                    tweakStore.clearStepOverride(stepID: stepID, in: resolved.id)
                    dismiss()
                }
                .frame(minHeight: 44)
            } footer: {
                Text("Drops your change and leaves the step as the recipe file writes it.")
            }
        }
    }

    // MARK: - Seeding and saving

    /// Seeded once from the RESOLVED step, so reopening shows his own words. A field bound
    /// straight to the store would make every keystroke a saved edit.
    private func seed(_ step: RecipeStep) {
        guard !didSeed else { return }
        didSeed = true
        title = step.title
        bodyText = step.body
        let low = step.minMinutes
        let high = step.maxMinutes
        seededMin = low
        seededMax = high
        isTimed = low != nil || high != nil
        minutes = low ?? high ?? 0
        upperMinutes = high ?? low ?? 0
        // A single stated duration arrives as an equal pair, so "has an upper bound" means
        // the document gave two DIFFERENT figures -- the fixture's step 3 is "7 to 8 min".
        hasUpperBound = low != nil && high != nil && low != high
    }

    /// Both texts and both bounds, every time, because `setStep` takes the sheet's FULL
    /// state and not a delta: it compares the minute pair against the bundled one to
    /// decide `hasMinutesOverride`, and it treats a nil text as "leave the stored override
    /// alone", which a sheet that owns the text must never ask for.
    ///
    /// TEXT THAT MATCHES THE DOCUMENT IS WRITTEN AS `""`. `effectiveTitle`/`effectiveBody`
    /// read `""` as leave-the-bundled-text-alone, and `finishStep` keeps any row whose
    /// title or body is non-empty. The fields are seeded from the resolved step so that
    /// reopening shows his own words — so without this an untouched Save would store the
    /// document's own title as an override and badge the step "Changed" for a change nobody
    /// made. It also makes retyping the recipe's own wording a revert.
    @MainActor
    private func save() {
        var low: Int? = isTimed ? min(minutes, hasUpperBound ? upperMinutes : minutes) : nil
        var high: Int? = isTimed ? max(minutes, hasUpperBound ? upperMinutes : minutes) : nil
        // Written back in the shape it arrived in when the controls say the same thing, so
        // a fix to the WORDING cannot flag the timing as changed as well.
        if sameTiming((low, high), (seededMin, seededMax)) {
            low = seededMin
            high = seededMax
        }
        // Both sides trimmed, because `TweakStore` trims what it stores and a bundled field
        // with a trailing space would otherwise never compare equal to anything he types.
        let typedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledTitle = (originalStep?.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledBody = (originalStep?.body ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        tweakStore.setStep(
            title: typedTitle == bundledTitle ? "" : typedTitle,
            body: typedBody == bundledBody ? "" : typedBody,
            minMinutes: low,
            maxMinutes: high,
            forStep: stepID,
            in: resolved.id
        )
        dismiss()
    }

    /// Whether two minute pairs state the SAME timing, which is not the same question as
    /// whether they are equal.
    ///
    /// `setStep` decides `hasMinutesOverride` by comparing the pair it is given against the
    /// bundled pair, and the steppers can only produce a both-or-neither pair. So a file
    /// that stated a minimum and no maximum would come back as an equal pair, differ from
    /// the bundle, and leave the step badged "Changed" with an "as written: 30 min" caption
    /// for a change he never made — the silent-disagreement defect, arrived at from the
    /// other end. Every bundled file today carries both bounds or neither, so this guards
    /// the next import rather than fixing a live bug.
    private func sameTiming(_ a: (Int?, Int?), _ b: (Int?, Int?)) -> Bool {
        (a.0 ?? a.1) == (b.0 ?? b.1) && (a.1 ?? a.0) == (b.1 ?? b.0)
    }
}
