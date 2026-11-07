import SwiftUI
import SwiftData

/// Building a list, and rebuilding one he is halfway through.
///
/// The preview line is live: every toggle re-runs the whole of `ShoppingListBuilder.build`,
/// which is cheap because the builder is pure and the kitchen is small, and it answers the
/// only question worth asking before committing — "what will this give me?" — with the real
/// numbers rather than an estimate of them.
///
/// Rebuilding **never edits the list he is holding.** `ShoppingListStore.regenerate` writes a
/// NEW list, carries across what he already checked off and every line he added by hand, and
/// returns a diff he can read: "3 new, 1 no longer needed, 2 changed quantity". Silently
/// resurrecting a checked-off line is the bug that whole path exists to prevent, and a diff he
/// can read is how he can tell it did not happen.
struct GenerateShoppingListSheet: View {
    /// The list being replaced, or nil for the first one.
    var replacing: ShoppingList? = nil

    @Environment(RecipeLoader.self) private var loader
    @Environment(IngredientCatalog.self) private var catalog
    @Environment(ShoppingListStore.self) private var shopping
    @Environment(TweakStore.self) private var tweaks: TweakStore?
    @Environment(InventoryLedger.self) private var ledger: InventoryLedger?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var startDate: Date = .now
    @State private var days: Int = 7
    @State private var subtractInventory = true
    @State private var includeStaples = false
    @State private var includeOptionalLines = false
    @State private var includePrep = false
    @State private var preview: ShoppingListBuilder.Draft? = nil
    @State private var diffSentence: String? = nil

    var body: some View {
        NavigationStack {
            List {
                rangeSection
                optionsSection
                previewSection
                if let sentence = diffSentence {
                    Section {
                        Text(sentence)
                            .font(.subheadline)
                    } header: {
                        Text("What would change")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(replacing == nil ? "New list" : "Rebuild the list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(replacing == nil ? "Build" : "Replace") { commit() }
                        .disabled(preview == nil)
                }
            }
            // See `ShoppingLineDetailView`: a non-Sendable closure formed in `body` inherits
            // its main-actor isolation, which is what the builder's collaborators need.
            .onAppear { refresh() }
            .onChange(of: signature) { refresh() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var rangeSection: some View {
        Section {
            DatePicker(
                "Starting",
                selection: $startDate,
                displayedComponents: [.date]
            )
            Stepper(value: $days, in: 1...21) {
                Text(days == 1 ? "1 day" : "\(days) days")
            }
            .frame(minHeight: 44)
        } header: {
            Text("Which days")
        } footer: {
            Text("Whole days, start to finish. A meal planned for this morning is still in a "
               + "range that starts today.")
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            Toggle("Subtract what the pantry has", isOn: $subtractInventory)
                .frame(minHeight: 44)
            Toggle("Ask for staples too", isOn: $includeStaples)
                .frame(minHeight: 44)
            Toggle("Include optional ingredients", isOn: $includeOptionalLines)
                .frame(minHeight: 44)
            Toggle("Include prep-ahead meals", isOn: $includePrep)
                .frame(minHeight: 44)
        } header: {
            Text("What to count")
        } footer: {
            Text("Prep-ahead slots are off by default: their ingredients belong to the meal "
               + "they prepare for, and counting both buys the steak twice.")
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            if let draft = preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary(draft))
                        .font(.subheadline.weight(.medium))
                    if draft.adHocMealCount > 0 {
                        Text(draft.adHocMealCount == 1
                             ? "1 meal has no recipe, so nothing could be counted for it."
                             : "\(draft.adHocMealCount) meals have no recipe, so nothing "
                               + "could be counted for them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !draft.diagnostics.isEmpty {
                        Label(
                            draft.diagnostics.count == 1
                                ? "1 problem with a recipe"
                                : "\(draft.diagnostics.count) problems with recipes",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text("Working it out\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Preview")
        } footer: {
            Text("These are the real numbers, from the same build that gets saved.")
        }
    }

    /// "32 items across 6 sections, 4 flagged" — the sentence the generation sheet was
    /// specified to show, built from the draft rather than from a guess at it.
    private func summary(_ draft: ShoppingListBuilder.Draft) -> String {
        let items = draft.lines.count
        guard items > 0 else {
            return draft.mealCount == 0
                ? "Nothing planned in these days, so there is nothing to buy."
                : "Nothing to buy: the pantry covers everything these meals ask for."
        }
        let sections = draft.sectionOrder.count
        let flagged = draft.lines.filter { !$0.flags.isEmpty }.count
        var text = "\(items) item\(items == 1 ? "" : "s") across "
                 + "\(sections) section\(sections == 1 ? "" : "s")"
        if flagged > 0 { text += ", \(flagged) flagged" }
        let meals = draft.mealCount
        return text + " \u{00B7} from \(meals) meal\(meals == 1 ? "" : "s")"
    }

    // MARK: - Options and the build

    /// One value that changes whenever anything the build depends on changes, so the preview
    /// is refreshed by a single `onChange` rather than by five that can fall out of step.
    private var signature: String {
        [
            String(Int(startDate.timeIntervalSince1970) / 86_400),
            String(days),
            String(subtractInventory),
            String(includeStaples),
            String(includeOptionalLines),
            String(includePrep)
        ].joined(separator: "|")
    }

    private var options: ShoppingListBuilder.Options {
        var slots = MealSlot.shoppableDefaults
        if includePrep { slots.insert(.prep) }
        return ShoppingListBuilder.Options(
            range: ShoppingListGeneration.range(from: startDate, days: days),
            slots: slots,
            subtractInventory: subtractInventory,
            includeStaples: includeStaples,
            includeOptionalLines: includeOptionalLines
        )
    }

    /// Both services are `@MainActor`, so they cannot be built in a property initializer, and
    /// both hold no state of their own — `TweakStore` is a container plus the loader and
    /// `InventoryLedger` keeps only a display preference — so standing one up when the
    /// environment has none is cheap and cannot disagree with an injected one. The same
    /// fallback `CookView` uses, and for the same reason: the window between first render and
    /// the launch task is real, if short.
    @MainActor
    private var generation: ShoppingListGeneration {
        ShoppingListGeneration(
            loader: loader,
            catalog: catalog,
            tweaks: tweaks ?? TweakStore(container: context.container, loader: loader),
            ledger: ledger ?? InventoryLedger(container: context.container),
            context: context
        )
    }

    @MainActor
    private func refresh() {
        let draft = generation.draft(options: options)
        preview = draft
        // Computed WITHOUT writing anything, so the sheet can say what replacing costs before
        // he commits to it.
        if let existing = replacing {
            diffSentence = shopping.diff(draft, against: existing).sentence
        }
    }

    @MainActor
    private func commit() {
        let draft = preview ?? generation.draft(options: options)
        if let existing = replacing {
            _ = shopping.regenerate(existing, from: draft, in: context)
            // The store deliberately does NOT archive the list it replaced — he may have
            // shopped off it, and that is his call, not a side effect of regenerating. This
            // screen makes the call explicitly, because the button he pressed says "Replace"
            // and two live lists would be two lists claiming to be this week's.
            existing.isArchived = true
            existing.completedAt = .now
        } else {
            _ = shopping.materialize(draft: draft, into: context)
        }
        dismiss()
    }
}
