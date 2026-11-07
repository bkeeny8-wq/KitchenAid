import Foundation
import Observation
import SwiftData

/// THE OVERLAY'S ACCESSOR. Nothing else reads or writes an override row.
///
/// Bundled content is immutable, so every adjustment he makes lives in `RecipeTweak` and
/// its two override children, keyed by the recipe's string id — `LOSStudyStatus` over `LOS`
/// in CFAL3. `effectiveRecipe(id:)` is the one place content and overlay meet, and it
/// applies the overlay to a COPY: `Recipe` is a value type precisely so that "this screen
/// adjusted the butter" cannot become visible on every other screen.
///
/// `@MainActor` because `ModelContainer.mainContext` is main-actor isolated and this
/// service writes through it. The alternative — holding a private `ModelContext` of its
/// own — would mean views driven by `@Query` on the main context do not see a tweak until
/// something else refetches, which reads as the edit not having saved.
@MainActor
@Observable
final class TweakStore {

    private let container: ModelContainer
    private let loader: RecipeLoader

    init(container: ModelContainer, loader: RecipeLoader) {
        self.container = container
        self.loader = loader
    }

    private var context: ModelContext { container.mainContext }

    // MARK: - Fetch or create

    /// Fetch-or-create.
    ///
    /// `recipeID` is deliberately not constrained — CloudKit-backed stores reject the
    /// uniqueness attribute — so two offline devices can both mint a row for one recipe.
    /// The survivor is chosen by `createdAt` and then by `id.uuidString`, a total order
    /// both devices compute identically with no coordination.
    ///
    /// The tie-break is applied HERE in Swift rather than as a second `SortDescriptor`:
    /// `UUID` is not `Comparable` and `uuidString` is computed, so a store-side sort on it
    /// is not expressible. Duplicates are at most a handful, so fetching them all costs
    /// nothing.
    func tweak(for recipeID: String, in context: ModelContext) -> RecipeTweak {
        if let existing = existingTweak(for: recipeID, in: context) { return existing }
        let created = RecipeTweak(
            recipeID: recipeID,
            recipeTitleSnapshot: loader.recipe(id: recipeID)?.title ?? ""
        )
        context.insert(created)
        return created
    }

    /// Read-only paths must not create a row just by looking at a recipe. The store stays
    /// proportional to what he has done, not to what is bundled.
    func tweakIfExists(for recipeID: String) -> RecipeTweak? {
        existingTweak(for: recipeID, in: context)
    }

    private func existingTweak(for recipeID: String, in context: ModelContext) -> RecipeTweak? {
        guard !recipeID.isEmpty else { return nil }
        // Hoisted into a local because `#Predicate` cannot translate string interpolation
        // or a member access on `self` — the macro has to capture a plain value.
        let needle = recipeID
        var descriptor = FetchDescriptor<RecipeTweak>(
            predicate: #Predicate<RecipeTweak> { $0.recipeID == needle },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 8
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return nil }
        let survivor = rows.min { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
        return survivor ?? rows.first
    }

    /// Every tweak row, for the diagnostics and lapse screens.
    func allTweaks() -> [RecipeTweak] {
        let descriptor = FetchDescriptor<RecipeTweak>(
            sortBy: [SortDescriptor(\.recipeID, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - The resolver

    /// THE FUNCTION EVERY VIEW CALLS. Content plus overlay, applied to a copy.
    ///
    /// Returns nil only when the id resolves to no bundled recipe at all. That is
    /// `RecipeContentStatus.missing` and it is handled WHOLE — one row reading "recipe no
    /// longer bundled", not one lapse notice per override for a file that may well come
    /// back on the next build.
    func effectiveRecipe(id recipeID: String) -> ResolvedRecipe? {
        guard let original = loader.recipe(id: recipeID) else { return nil }
        guard let tweakRow = tweakIfExists(for: recipeID) else {
            return ResolvedRecipe(recipe: original, original: original)
        }

        var resolved = original
        var overriddenLineIDs: Set<String> = []
        var overriddenStepIDs: Set<String> = []

        var lineRows: [String: IngredientOverride] = [:]
        for row in tweakRow.orderedIngredientOverrides where !row.lineID.isEmpty {
            // First row wins for a given key. Two rows for one line should not exist, but
            // `orderedIngredientOverrides` is sorted, so if they do the same one applies
            // on every launch rather than whichever the array happened to hand back first.
            if lineRows[row.lineID] == nil { lineRows[row.lineID] = row }
        }
        if !lineRows.isEmpty {
            for componentIndex in resolved.components.indices {
                for lineIndex in resolved.components[componentIndex].lines.indices {
                    let lineID = resolved.components[componentIndex].lines[lineIndex].lineID
                    guard let row = lineRows[lineID] else { continue }
                    Self.apply(row, toLine: &resolved.components[componentIndex].lines[lineIndex])
                    overriddenLineIDs.insert(lineID)
                }
            }
        }

        var stepRows: [String: StepOverride] = [:]
        for row in tweakRow.orderedStepOverrides where !row.stepID.isEmpty {
            if stepRows[row.stepID] == nil { stepRows[row.stepID] = row }
        }
        if !stepRows.isEmpty {
            for stepIndex in resolved.steps.indices {
                let stepID = resolved.steps[stepIndex].stepID
                guard let row = stepRows[stepID] else { continue }
                Self.apply(row, toStep: &resolved.steps[stepIndex])
                overriddenStepIDs.insert(stepID)
            }
        }

        return ResolvedRecipe(
            recipe: resolved,
            original: original,
            overriddenLineIDs: overriddenLineIDs,
            overriddenStepIDs: overriddenStepIDs,
            lastMadeAt: tweakRow.lastMadeAt,
            userNotes: tweakRow.notes,
            isFavorite: tweakRow.isFavorite,
            lapsedOverrides: lapses(for: tweakRow, in: original)
        )
    }

    private static func apply(_ row: IngredientOverride, toLine line: inout IngredientLine) {
        if let quantity = row.quantity {
            line.amount = quantity.amount
            line.unitCode = quantity.unit.code
            line.dimension = quantity.unit.dimension
            // He typed this quantity, so the dimension is no longer a guess the importer
            // made from an ambiguous unit.
            line.dimensionConfirmed = true
            // A RANGE CANNOT SURVIVE AN EXACT OVERRIDE. `shoppingAmount` returns
            // `amountMax ?? amount`, so leaving the bundled upper bound in place would
            // have the shopping list keep buying for "2 to 3 lb" after he settled on 2.
            line.amountMax = nil
        } else {
            // The row exists and carries no quantity: he cleared the measurement, which is
            // the pinch representation applied to an override. NO override is the ABSENCE
            // of the row, which is why every writer below seeds the five primitives from
            // the bundled line before touching anything else.
            line.amount = nil
            line.unitCode = ""
            line.dimension = .unmeasured
            line.amountMax = nil
        }

        line.preparation = row.effectivePreparation(bundled: line.preparation) ?? line.preparation
        if !row.note.isEmpty { line.note = row.note }

        // `rawText` IS CLEARED, and this is not tidying. `cookDisplayText` prefers
        // `rawText` whenever it is non-empty, so leaving the importer's verbatim line in
        // place would render "Butter 2 sticks, UNSALTED" on the cook screen over the one
        // stick he just set — the edit saved, and invisible, which is the worst of both.
        line.rawText = ""
    }

    private static func apply(_ row: StepOverride, toStep step: inout RecipeStep) {
        step.title = row.effectiveTitle(bundled: step.title)
        step.body = row.effectiveBody(bundled: step.body)
        let minutes = row.effectiveMinutes(bundledMin: step.minMinutes, bundledMax: step.maxMinutes)
        step.minMinutes = minutes.min
        step.maxMinutes = minutes.max
        // `StepOverride.note` deliberately does not merge into `body`: appending to the
        // method would make his aside indistinguishable from the authored text the next
        // time the file is revised. The tweak sheet renders it beside the step instead.
    }

    // MARK: - Lapsing

    /// LAPSES ARE VISIBLE, NEVER SILENT.
    ///
    /// Overrides join content on `lineID`/`stepID`, which are name-plus-occurrence
    /// (`butter-1`, `butter-2`) and deliberately NOT positional. So when a recipe file is
    /// revised, an override whose key is gone stops applying and says so, rather than
    /// re-pointing at whatever ingredient now occupies that slot — a tweak that quietly
    /// moves from butter to flour is worse than one that stops.
    ///
    /// The live-id sets come from the recipe the caller already resolved, and
    /// `RecipeTweak`'s own queries guard the empty case: an unresolvable recipe has no live
    /// ids at all, and reporting every override as lapsed would offer him a screenful of
    /// "remove it?" for a file that may come back on the next build. The `filter` here is
    /// part of that guard — a content file whose lines all carry an empty `lineID` would
    /// otherwise produce a non-empty set of empty strings and defeat it.
    private func lapses(for tweak: RecipeTweak, in recipe: Recipe) -> [ResolvedRecipe.LapsedOverride] {
        let liveLineIDs = Set(recipe.allLines.map { $0.lineID }.filter { !$0.isEmpty })
        let liveStepIDs = Set(recipe.steps.map { $0.stepID }.filter { !$0.isEmpty })

        var out: [ResolvedRecipe.LapsedOverride] = []
        for row in tweak.lapsedIngredientOverrides(liveLineIDs: liveLineIDs) {
            out.append(ResolvedRecipe.LapsedOverride(
                kind: .ingredient, key: row.lineID, snapshot: row.lapseDescription
            ))
        }
        for row in tweak.lapsedStepOverrides(liveStepIDs: liveStepIDs) {
            out.append(ResolvedRecipe.LapsedOverride(
                kind: .step, key: row.stepID, snapshot: row.lapseDescription
            ))
        }
        return out
    }

    /// One row per tweak that needs his attention, for the Settings screen.
    ///
    /// A recipe whose file is GONE is listed with no lapses and `.missing`, because that is
    /// a whole-row decision — forget it, or wait for the file to come back — and not an
    /// override-by-override one.
    struct LapseReport: Identifiable, Sendable {
        var recipeID: String = ""
        var title: String = ""
        var status: RecipeContentStatus = .present
        var lapses: [ResolvedRecipe.LapsedOverride] = []
        var id: String { recipeID }
    }

    func lapseReport() -> [LapseReport] {
        var out: [LapseReport] = []
        for tweak in allTweaks() {
            let status = loader.status(of: tweak.recipeID)
            guard let recipe = loader.recipe(id: tweak.recipeID) else {
                // Nothing to report for a row carrying nothing; maintenance drops those.
                if tweak.isEmpty { continue }
                out.append(LapseReport(
                    recipeID: tweak.recipeID,
                    title: tweak.displayTitle(resolvedTitle: nil, status: status),
                    status: status,
                    lapses: []
                ))
                continue
            }
            let found = lapses(for: tweak, in: recipe)
            if found.isEmpty { continue }
            out.append(LapseReport(
                recipeID: tweak.recipeID,
                title: tweak.displayTitle(resolvedTitle: recipe.title, status: status),
                status: status,
                lapses: found
            ))
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Writing the overlay

    func setQuantity(_ quantity: Quantity?, forLine lineID: String, in recipeID: String) {
        guard !recipeID.isEmpty, !lineID.isEmpty else { return }
        let row = ingredientOverride(forLine: lineID, in: recipeID)
        row.quantity = quantity
        finishIngredient(row, forLine: lineID, in: recipeID)
    }

    func setPreparation(_ text: String, forLine lineID: String, in recipeID: String) {
        guard !recipeID.isEmpty, !lineID.isEmpty else { return }
        let row = ingredientOverride(forLine: lineID, in: recipeID)
        row.preparationOverride = text.trimmingCharacters(in: .whitespacesAndNewlines)
        finishIngredient(row, forLine: lineID, in: recipeID)
    }

    /// "Add a note after cooking", at the level of one ingredient. `IngredientOverride.note`
    /// has no other writer, and a note is explicitly in scope where authoring is not.
    func setIngredientNote(_ text: String, forLine lineID: String, in recipeID: String) {
        guard !recipeID.isEmpty, !lineID.isEmpty else { return }
        let row = ingredientOverride(forLine: lineID, in: recipeID)
        row.note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        finishIngredient(row, forLine: lineID, in: recipeID)
    }

    /// `nil` for either text field leaves the bundled text alone.
    ///
    /// The minute bounds are the sheet's full state, not a delta, so they are compared
    /// against the bundled pair: equal means there is no timing override and
    /// `hasMinutesOverride` goes false, while `nil, nil` that differs from the content
    /// means he has declared the step untimed. That distinction is the entire reason the
    /// flag exists rather than being inferred from the two `Int?`s.
    func setStep(
        title: String?,
        body: String?,
        minMinutes: Int?,
        maxMinutes: Int?,
        forStep stepID: String,
        in recipeID: String
    ) {
        guard !recipeID.isEmpty, !stepID.isEmpty else { return }
        let row = stepOverride(forStep: stepID, in: recipeID)
        if let title = title {
            row.titleOverride = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let body = body {
            row.bodyOverride = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Spelled out with two `var`s rather than `loader.recipe(...)?.step(...)?.minMinutes`,
        // because chaining an optional property off an optional step gives a doubly-wrapped
        // `Int??` that compares unequal to a plain `Int?` in ways there is no compiler here
        // to check.
        var bundledMin: Int? = nil
        var bundledMax: Int? = nil
        if let bundledStep = loader.recipe(id: recipeID)?.step(id: stepID) {
            bundledMin = bundledStep.minMinutes
            bundledMax = bundledStep.maxMinutes
        }
        row.hasMinutesOverride = !(bundledMin == minMinutes && bundledMax == maxMinutes)
        row.minMinutes = minMinutes
        row.maxMinutes = maxMinutes

        finishStep(row, in: recipeID)
    }

    func setNotes(_ text: String, for recipeID: String) {
        guard !recipeID.isEmpty else { return }
        let tweakRow = tweak(for: recipeID, in: context)
        tweakRow.notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
        tweakRow.touch()
        save()
        pruneIfEmpty(tweakRow, in: context)
        save()
    }

    func setFavorite(_ value: Bool, for recipeID: String) {
        guard !recipeID.isEmpty else { return }
        let tweakRow = tweak(for: recipeID, in: context)
        tweakRow.isFavorite = value
        tweakRow.touch()
        save()
        pruneIfEmpty(tweakRow, in: context)
        save()
    }

    /// THE ONLY WRITER OF COOKING HISTORY. A date, and nothing else: he was offered a
    /// journal with ratings and per-cook notes and declined it.
    func markMade(_ recipeID: String, at date: Date = .now) {
        guard !recipeID.isEmpty else { return }
        let tweakRow = tweak(for: recipeID, in: context)
        tweakRow.lastMadeAt = date
        tweakRow.touch(at: date)
        save()
    }

    func clearIngredientOverride(lineID: String, in recipeID: String) {
        guard let tweakRow = tweakIfExists(for: recipeID),
              let row = tweakRow.ingredientOverride(lineID: lineID) else { return }
        context.delete(row)
        tweakRow.touch()
        // SAVED BEFORE PRUNING, and the order is the point: until the delete is saved the
        // relationship array still holds the row, so `RecipeTweak.isEmpty` would answer
        // "no" and the now-empty row would survive as residue.
        save()
        pruneIfEmpty(tweakRow, in: context)
        save()
    }

    func clearStepOverride(stepID: String, in recipeID: String) {
        guard let tweakRow = tweakIfExists(for: recipeID),
              let row = tweakRow.stepOverride(stepID: stepID) else { return }
        context.delete(row)
        tweakRow.touch()
        save()
        pruneIfEmpty(tweakRow, in: context)
        save()
    }

    /// Removing a lapsed override is an explicit act, offered by the tweak sheet and never
    /// done on his behalf. It takes the report's own value so the caller can pass back
    /// exactly what it rendered.
    func clearLapsed(_ lapse: ResolvedRecipe.LapsedOverride, in recipeID: String) {
        switch lapse.kind {
        case .ingredient:
            clearIngredientOverride(lineID: lapse.key, in: recipeID)
        case .step:
            clearStepOverride(stepID: lapse.key, in: recipeID)
        }
    }

    /// Drops a `RecipeTweak` once it is carrying nothing, so "undo my tweak" leaves no
    /// residue and the store stays proportional to what he has actually done.
    func pruneIfEmpty(_ tweak: RecipeTweak, in context: ModelContext) {
        guard tweak.isEmpty else { return }
        context.delete(tweak)
    }

    // MARK: - Private writers

    /// Fetch-or-create the override row for one line, SEEDING THE QUANTITY FROM THE
    /// BUNDLED LINE.
    ///
    /// The seeding is load-bearing, not politeness. `IngredientOverride.hasQuantity`
    /// defaults to false and a false flag means "this line has no measured quantity any
    /// more", so a row minted bare to carry a preparation note would read on the next
    /// launch as him having deleted the 2 tbsp — an edit to one field silently erasing
    /// another. Seeding makes `hasQuantity == false` mean only what it says.
    private func ingredientOverride(forLine lineID: String, in recipeID: String) -> IngredientOverride {
        let tweakRow = tweak(for: recipeID, in: context)
        if let existing = tweakRow.ingredientOverride(lineID: lineID) { return existing }

        var seedQuantity: Quantity? = nil
        var snapshot = ""
        if let bundledLine = loader.recipe(id: recipeID)?.line(id: lineID) {
            seedQuantity = bundledLine.quantity
            snapshot = bundledLine.cookDisplayText
        }

        let row = IngredientOverride(lineID: lineID, lineTextSnapshot: snapshot)
        row.quantity = seedQuantity
        context.insert(row)
        // The to-one side is assigned and the array is left alone: `inverse:` is declared
        // on `RecipeTweak.ingredientOverrides`, so SwiftData maintains the other end.
        // Writing both would risk the row appearing twice.
        row.tweak = tweakRow
        return row
    }

    private func stepOverride(forStep stepID: String, in recipeID: String) -> StepOverride {
        let tweakRow = tweak(for: recipeID, in: context)
        if let existing = tweakRow.stepOverride(stepID: stepID) { return existing }

        var snapshot = ""
        if let bundledStep = loader.recipe(id: recipeID)?.step(id: stepID) {
            snapshot = bundledStep.title
        }

        let row = StepOverride(stepID: stepID, stepTitleSnapshot: snapshot)
        context.insert(row)
        row.tweak = tweakRow
        return row
    }

    /// Touch, drop a row that now says nothing, prune, save. One place, because the call
    /// site that forgets `touch()` is invisible until duplicate-folding picks the wrong
    /// survivor — a bug that surfaces months later on a second device.
    private func finishIngredient(_ row: IngredientOverride, forLine lineID: String, in recipeID: String) {
        let tweakRow = tweak(for: recipeID, in: context)
        tweakRow.touch()

        // A row whose quantity matches the content and whose text fields are empty is not
        // an override, it is a row he undid. Keeping it would mark the line as tweaked in
        // every view that reads `ResolvedRecipe.overriddenLineIDs`.
        var bundledQuantity: Quantity? = nil
        if let bundledLine = loader.recipe(id: recipeID)?.line(id: lineID) {
            bundledQuantity = bundledLine.quantity
        }
        if row.preparationOverride.isEmpty, row.note.isEmpty, row.quantity == bundledQuantity {
            context.delete(row)
        }

        save()
        pruneIfEmpty(tweakRow, in: context)
        save()
    }

    private func finishStep(_ row: StepOverride, in recipeID: String) {
        let tweakRow = tweak(for: recipeID, in: context)
        tweakRow.touch()

        if row.titleOverride.isEmpty, row.bodyOverride.isEmpty, row.note.isEmpty,
           !row.hasMinutesOverride {
            context.delete(row)
        }

        save()
        pruneIfEmpty(tweakRow, in: context)
        save()
    }

    /// `try?` rather than `try`: a failed save on a notes field must not propagate out of a
    /// SwiftUI action, and there is no recovery available on a family phone anyway.
    private func save() {
        try? context.save()
    }
}
