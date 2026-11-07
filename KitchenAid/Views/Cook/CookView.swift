import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// COOK MODE. One step at a time, in type you can read from arm's length, with
/// a control big enough to hit with the back of a knuckle.
///
/// This screen is used with wet hands at a stove, so every trade-off goes the
/// same way: legibility over density, one decision per screen, and nothing that
/// needs a second tap to read. The detail screen already shows the whole recipe
/// at once and is the right screen for choosing what to cook; this one is for
/// cooking it.
///
/// Four things in the real recipes shaped it, and each is cited where it lands:
///
/// - Steps are FLAT across the whole dish, so there is a single 1-of-N spine and
///   no nesting. A component groups ingredients and nothing else.
/// - A duration can be a number (30 min), a RANGE (7 to 8 min) or absent, and a
///   step can be a passive rest. All four read differently here.
/// - The turkey has no total time at all: it times at 13 minutes per pound and
///   keeps an eight-row weight chart. He reads his bird's row instead of doing
///   arithmetic at the oven.
/// - The turkey's two ALL-CAPS notes are the point of the recipe, so they are
///   shown before the first step and pinned above every step after it.
///
/// Finishing sets `lastMadeAt` through `TweakStore`, which is the only cooking
/// history this app keeps -- he was offered a journal with ratings and per-cook
/// notes and declined it.
struct CookView: View {

    let recipeID: String

    /// The scale the meal plan worked out from who is eating, passed in rather
    /// than derived here: `MealScaling` owns that arithmetic and needs a
    /// `MealRecipe`, which a recipe opened straight from the library does not
    /// have. Defaults to 1, which is what every caller can honestly pass today.
    var scale: Rational = .one

    @Environment(RecipeLoader.self) private var loader
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// OPTIONAL on purpose. `KitchenAidApp` does not inject a `TweakStore` yet
    /// (it injects the loader and the catalogue), and an `@Environment` lookup
    /// declared non-optional traps when the value is absent -- which would make
    /// opening this screen a crash rather than a missing overlay. See
    /// `tweakStore` below for what stands in meanwhile.
    @Environment(TweakStore.self) private var injectedTweakStore: TweakStore?
    /// Both for the pantry depletion below, and both read the same way as the tweak store
    /// above: the ledger optional because the launch task may not have run, the catalogue
    /// non-optional because the App injects it unconditionally.
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?
    @Environment(IngredientCatalog.self) private var catalog

    @State private var stepIndex = 0
    @State private var completedStepIDs: Set<String> = []
    /// nil means "whatever the plan said". Set by the batch menu.
    @State private var batchOverride: Rational? = nil
    /// Component index to chosen `lineID`, for a pick-one group like the
    /// pancake's spice mix-ins. Session-only and never written to the store:
    /// persisting it would be authoring a variant, which is out of scope.
    @State private var choices: [Int: String] = [:]
    /// The first column of the weight-chart row he picked, e.g. "14 lb".
    @State private var chartKey: String = ""
    @State private var showIngredients = false
    @State private var showChart = false
    @State private var showShouted = false
    @State private var didOfferShouted = false
    @State private var confirmFinish = false

    var body: some View {
        if let resolved = resolvedRecipe {
            cooking(resolved)
        } else {
            EmptyStateView(
                kind: .somethingWrong,
                symbol: "questionmark.folder",
                headline: "Recipe not found",
                detail: "No bundled recipe has this id, so there is nothing to cook. "
                      + "It may have been renamed or removed in a later build."
            )
            .navigationTitle("Cook")
        }
    }

    // MARK: - Content and overlay

    /// `TweakStore` holds no state of its own -- it is a container plus the
    /// loader, and every method fetches -- so standing one up here when the
    /// environment has none is cheap and cannot disagree with an injected one.
    /// It is the honest fallback rather than skipping the overlay, because his
    /// adjusted quantities are exactly what he wants to see at the stove.
    @MainActor
    private var tweakStore: TweakStore {
        injectedTweakStore ?? TweakStore(container: modelContext.container, loader: loader)
    }

    /// Content plus his tweaks, which is what every view renders. Nothing here
    /// writes a `Recipe`: the overlay is applied to a copy.
    @MainActor
    private var resolvedRecipe: ResolvedRecipe? {
        tweakStore.effectiveRecipe(id: recipeID)
    }

    private var effectiveScale: Rational { batchOverride ?? scale }

    // MARK: - The screen

    @MainActor
    @ViewBuilder
    private func cooking(_ resolved: ResolvedRecipe) -> some View {
        let steps = resolved.steps
        let shouted = resolved.notes.filter { $0.isShouted }

        VStack(spacing: 0) {
            stepRail(steps)
            if !shouted.isEmpty {
                shoutedBand(shouted)
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let step = step(at: stepIndex, in: steps) {
                        CookStepCard(
                            step: step,
                            number: stepIndex + 1,
                            total: steps.count,
                            componentTitle: resolved.component(at: step.componentIndex)?.title ?? "",
                            isDone: completedStepIDs.contains(step.stepID)
                        )
                        // Keyed by step so the running clock is reset by moving
                        // on, rather than following the cook to the next step.
                        CookTimerBar(step: step)
                            .id(step.stepID)
                    } else {
                        noSteps
                    }
                    facts(resolved)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            controls(resolved, steps: steps)
        }
        .navigationTitle(resolved.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(resolved) }
        .sheet(isPresented: $showIngredients) {
            CookIngredientsSheet(
                resolved: resolved,
                scale: effectiveScale,
                choices: $choices
            )
        }
        .sheet(isPresented: $showChart) {
            if let table = resolved.recipe.tables.first {
                CookTimingChartSheet(
                    table: table,
                    minutesPerPound: resolved.recipe.minutesPerPound,
                    ovenTempF: resolved.recipe.ovenTempF,
                    selectedKey: $chartKey
                )
            }
        }
        .sheet(isPresented: $showShouted) {
            CookShoutedSheet(notes: resolved.notes.filter { $0.isShouted })
        }
        .confirmationDialog(
            "Finished cooking?",
            isPresented: $confirmFinish,
            titleVisibility: .visible
        ) {
            Button("Made it, and take it out of the pantry") {
                tweakStore.markMade(resolved.id)
                depleteFromPantry(resolved)
                dismiss()
            }
            Button("Mark as made today") {
                tweakStore.markMade(resolved.id)
                dismiss()
            }
            Button("Close without recording") { dismiss() }
            Button("Keep cooking", role: .cancel) { }
        } message: {
            Text("The date is the only thing kept -- there is no cooking journal. Taking it "
               + "out of the pantry writes one depletion per ingredient, which is what makes "
               + "the next shopping list right.")
        }
        .onAppear {
            keepScreenAwake(true)
            // Shown ONCE per visit, before the first step, because a shout is
            // the kind of instruction that is useless after the fact: knowing
            // the butter had to be unsalted does not help once it is on the
            // bird. The band below keeps them visible afterwards.
            if !didOfferShouted, !resolved.notes.filter({ $0.isShouted }).isEmpty {
                didOfferShouted = true
                showShouted = true
            }
        }
        .onDisappear { keepScreenAwake(false) }
    }

    // MARK: - The spine

    private func step(at index: Int, in steps: [RecipeStep]) -> RecipeStep? {
        guard steps.indices.contains(index) else { return nil }
        return steps[index]
    }

    /// "Step 3 of 8" and a tappable number for every step.
    ///
    /// The rail is how he gets BACK. Cooking is not linear in practice -- the
    /// spinach is wilting while the steak rests -- and a screen that only moves
    /// forward makes re-reading the step he is actually standing over a matter
    /// of counting taps.
    @ViewBuilder
    private func stepRail(_ steps: [RecipeStep]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(steps.isEmpty ? "No steps" : "Step \(stepIndex + 1) of \(steps.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if effectiveScale != .one {
                    Text("\u{00D7}\(effectiveScale.humanDescription)")
                        .font(.footnote.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .accessibilityLabel(
                            "scaled \(effectiveScale.humanDescription) times the recipe"
                        )
                }
            }
            if steps.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(steps) { step in
                            railButton(step, steps: steps)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func railButton(_ step: RecipeStep, steps: [RecipeStep]) -> some View {
        let position = steps.firstIndex(where: { $0.stepID == step.stepID }) ?? 0
        let isCurrent = position == stepIndex
        let isDone = completedStepIDs.contains(step.stepID)
        return Button {
            stepIndex = position
        } label: {
            Text("\(step.number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    Circle().fill(
                        isCurrent ? Color.accentColor.opacity(0.22)
                                  : (isDone ? Color.secondary.opacity(0.16) : Color.clear)
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        isCurrent ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: isCurrent ? 2 : 1
                    )
                )
                .foregroundStyle(isDone && !isCurrent ? .secondary : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(railLabel(step, isDone: isDone))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// Built by concatenation rather than one interpolated string: a number, an
    /// optional state and an optional title nested three deep in one literal is
    /// unreadable and is the kind of line a later edit breaks silently.
    private func railLabel(_ step: RecipeStep, isDone: Bool) -> String {
        var label = "Step \(step.number)"
        if !step.title.isEmpty { label += ", " + step.title }
        if isDone { label += ", done" }
        return label
    }

    /// The shouts, pinned. Tappable, because the band is deliberately one line
    /// each and the sheet is where the full text lives.
    @ViewBuilder
    private func shoutedBand(_ notes: [RecipeNote]) -> some View {
        Button {
            showShouted = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(note.text)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the recipe warnings in full")
    }

    // MARK: - Facts under the step

    /// What the recipe says that is not a step: the oven, the rate, the yield at
    /// this scale, and the mix-ins he picked.
    @ViewBuilder
    private func facts(_ resolved: ResolvedRecipe) -> some View {
        let lines = factLines(resolved)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    private func factLines(_ resolved: ResolvedRecipe) -> [String] {
        var lines: [String] = []
        if let oven = resolved.recipe.ovenTempF {
            lines.append("Oven \(oven)\u{00B0}F")
        }
        // The turkey times by weight and has no total at all, which is the
        // correct answer rather than a missing one.
        if let perPound = resolved.recipe.minutesPerPound {
            lines.append("\(perPound.humanDescription) minutes per pound")
        }
        if let yield = resolved.scaledYieldLabel(at: effectiveScale) {
            lines.append("Makes \(yield)")
        }
        if !chartKey.isEmpty {
            lines.append("Timing read for a \(chartKey) bird")
        }
        for (index, lineID) in choices.sorted(by: { $0.key < $1.key }) {
            guard let component = resolved.component(at: index),
                  let chosen = component.lines.first(where: { $0.lineID == lineID })
            else { continue }
            let label = component.title.isEmpty ? "Chosen" : component.title
            lines.append("\(label): \(chosen.displayName)")
        }
        return lines
    }

    // MARK: - The pantry

    /// Cooking takes food out of the house, and until this existed nothing in the app said
    /// so: `InventoryLedger.depleteForCook` was written, commented and called by nobody, so
    /// every level drifted upward for ever and the pantry comparison on each new shopping
    /// list was wrong in the same direction.
    ///
    /// It is a SEPARATE button from "Mark as made today" rather than a side effect of it.
    /// Changing what the house is recorded as holding is not something to do silently on a
    /// screen he opened to read the method.
    ///
    /// Four decisions about which lines count, each of which can be wrong in a way he would
    /// have to unpick by hand:
    ///
    /// 1. **A pick-one group deplete only what he picked.** `choices` is already tracked for
    ///    the spice mix-ins; without consulting it, cooking one variation would take all of
    ///    them out of the pantry.
    /// 2. **Optional and garnish lines are skipped**, matching `includeOptionalLines: false`
    ///    on the shopping side. He may not have used them, and the cost of guessing wrong
    ///    here is silent: a level that is too low asks him to buy what is already in the
    ///    cupboard.
    /// 3. **`createIfMissing: false`.** Cooking must not mint pantry rows. The four column
    ///    labels the turkey document carries ("Fat", "Stock") would otherwise become items
    ///    the first time he cooks it.
    /// 4. **`.fixed` lines do not scale**, the same rule `CookQuantity.text` applies -- a
    ///    triple batch does not use three bay leaves.
    ///
    /// Known limitation, stated rather than papered over: a line whose `subRecipePolicy` is
    /// `.expandToIngredients` is depleted AS ITSELF, not as the ingredients it expands to.
    /// Expanding needs `RecipeGraph.flatten` and a full `Options`, which this screen has no
    /// reason to hold. The ledger records the stock, not the stock's onions.
    @MainActor
    private func depleteFromPantry(_ resolved: ResolvedRecipe) {
        guard let ledger = injectedLedger else { return }
        let resolver = FoodItemResolver(catalog: catalog)

        var requirements: [InventoryLedger.CookRequirement] = []
        for (index, component) in resolved.components.enumerated() {
            // A component offering a choice contributes exactly one line, or none when he
            // walked past the question.
            let chosenID = choices[index]
            let offersChoice = component.lines.contains { $0.isChoice }

            for line in component.lines {
                if offersChoice, line.isChoice, line.lineID != chosenID { continue }
                if line.isOptional || line.isGarnish { continue }
                if line.excludeFromShopping { continue }

                let name = line.catalogName.isEmpty ? line.displayName : line.catalogName
                guard !name.isEmpty else { continue }
                // ONE binding, not two. `findOrCreate` is `throws -> FoodItem?`, and
                // SE-0230 (in effect at SWIFT_VERSION 5.0) flattens `try?` rather than
                // nesting it, so this expression is `FoodItem?` and a second `let` on the
                // result would not compile. The two sibling call sites --
                // ShoppingListGeneration and AddStockSheet -- get this right.
                guard let item = try? resolver.findOrCreate(
                    name: name, createIfMissing: false, in: modelContext
                ) else { continue }

                let factor = line.scalingRule == .fixed ? Rational.one : effectiveScale
                requirements.append(InventoryLedger.CookRequirement(
                    item: item,
                    needed: line.quantity?.scaled(by: factor),
                    recipeID: resolved.id,
                    recipeTitle: resolved.title,
                    note: line.unmeasuredNote
                ))
            }
        }

        guard !requirements.isEmpty else { return }
        ledger.depleteForCook(requirements, in: modelContext)
    }

    @ViewBuilder
    private var noSteps: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "list.number",
            headline: "No method to follow",
            detail: "This recipe has ingredients but no numbered steps, so there is "
                  + "nothing to walk through. The ingredients button still works."
        )
    }

    // MARK: - The big control

    @MainActor
    @ViewBuilder
    private func controls(_ resolved: ResolvedRecipe, steps: [RecipeStep]) -> some View {
        let isLast = stepIndex >= steps.count - 1
        HStack(spacing: 12) {
            Button {
                stepIndex = max(0, stepIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.bordered)
            .disabled(stepIndex == 0)
            .accessibilityLabel("Previous step")

            Button {
                if let step = step(at: stepIndex, in: steps) {
                    completedStepIDs.insert(step.stepID)
                }
                if isLast || steps.isEmpty {
                    confirmFinish = true
                } else {
                    stepIndex = min(steps.count - 1, stepIndex + 1)
                }
            } label: {
                Text(isLast || steps.isEmpty ? "Done cooking" : "Next step")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Toolbar

    @MainActor
    @ToolbarContentBuilder
    private func toolbarContent(_ resolved: ResolvedRecipe) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showIngredients = true
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .accessibilityLabel("Ingredients")
        }
        if !resolved.recipe.tables.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showChart = true
                } label: {
                    Image(systemName: "tablecells")
                }
                .accessibilityLabel("Cooking times for your weight")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            batchMenu(resolved)
        }
    }

    /// Halving and doubling, at the stove.
    ///
    /// The plan screen is where attendance decides a scale, and when it exists
    /// it passes one in. This menu is the manual override for a recipe opened
    /// straight from the library -- without it the scaled rendering below is
    /// dead code, because nothing in the app passes anything but 1 today. It
    /// changes nothing in the store: `MealRecipe.scaleOverride` is where a
    /// remembered override belongs, and that belongs to a planned meal.
    @MainActor
    @ViewBuilder
    private func batchMenu(_ resolved: ResolvedRecipe) -> some View {
        Menu {
            ForEach(batchOptions, id: \.self) { option in
                Button {
                    batchOverride = option == scale ? nil : option
                } label: {
                    if option == effectiveScale {
                        Label(batchLabel(option), systemImage: "checkmark")
                    } else {
                        Text(batchLabel(option))
                    }
                }
            }
        } label: {
            Image(systemName: "multiply.circle")
        }
        .accessibilityLabel("Batch size, \(effectiveScale.humanDescription) times the recipe")
    }

    /// Exact rationals, never 0.5 and 1.5: scaling 1/3 cup by 3 has to give
    /// exactly 1 cup, and a batch menu that introduced a `Double` here would be
    /// the one place the whole pipeline leaked.
    private var batchOptions: [Rational] {
        var options = [Rational(1, 2), Rational.one, Rational(3, 2), Rational(2), Rational(3)]
        if !options.contains(scale) { options.append(scale) }
        return options.sorted()
    }

    private func batchLabel(_ option: Rational) -> String {
        let base = "\u{00D7}\(option.humanDescription)"
        return option == scale && scale != .one ? "\(base) (from the plan)" : base
    }

    // MARK: - Keeping the screen on

    /// A screen that locks mid-step means drying your hands to unlock it, which
    /// is the single most predictable annoyance of cooking from a phone. Undone
    /// on disappear, because leaving the idle timer disabled for the rest of the
    /// app's life would quietly cost him a day of battery.
    ///
    /// `isIdleTimerDisabled` is UIKit and there is no SwiftUI equivalent on iOS
    /// 17, so it is reached directly and guarded for a platform without it.
    @MainActor
    private func keepScreenAwake(_ awake: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }
}
