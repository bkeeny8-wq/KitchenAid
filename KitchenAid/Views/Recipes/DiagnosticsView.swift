import SwiftUI
import SwiftData

/// What is wrong with the recipe files, and what is wrong with his edits to them.
///
/// This is the screen that makes the add-a-recipe loop usable. Brandon's
/// pipeline is that a recipe is authored, imported, committed and the app
/// rebuilt — so when a file is malformed, the failure surfaces on his phone,
/// away from any console. A loader that silently skips a bad file and an app
/// with one fewer recipe look exactly the same, and the difference is a
/// afternoon of wondering where the gravy went.
///
/// Every diagnostic names the FILE, because that is the thing he can go and fix.
///
/// The third section is a third kind of thing, and the distinction is the whole
/// reason it is here rather than folded into the warnings: a diagnostic means a
/// file could not be used, a warning means it loaded but the importer could not
/// work something out — and a LAPSE means the file is perfectly fine and his own
/// edit no longer fits it.
struct DiagnosticsView: View {
    @Environment(RecipeLoader.self) private var loader

    /// OPTIONAL, and that is load-bearing rather than caution: the App injects the overlay
    /// from its launch task, so a non-optional `@Environment` lookup traps on any render
    /// that beats it — the trap `CookView` documents at its own declaration. No fallback
    /// store is minted here, unlike `CookView`: absent means nothing has been tweaked yet
    /// in this launch, and the right answer is to omit the section rather than to fetch an
    /// empty one.
    @Environment(TweakStore.self) private var tweaks: TweakStore?

    /// Reactivity only; the reports come from the store's own fetch, the same shape as
    /// `PendingDepletionsView`. It earns its place: every clearing path in `TweakStore`
    /// calls `RecipeTweak.touch()` and then prunes a row left carrying nothing, so
    /// "Forget this tweak" always writes the tweak table and this list recomputes with it.
    @Query private var tweakRows: [RecipeTweak]

    /// Recipes the importer had reservations about. Distinct from a diagnostic:
    /// these files loaded fine and the app works, but something in them could
    /// not be worked out, so a quantity or an ingredient will behave oddly
    /// later. Seven exist across the eight bundled files and all seven are true.
    private var warned: [Recipe] {
        loader.allIncludingArchived
            .filter { !$0.warnings.isEmpty }
            .sorted { $0.title < $1.title }
    }

    /// His tweaks that no longer join onto anything.
    ///
    /// `lapseReport()` ran on every `effectiveRecipe(id:)` call and was READ BY NOTHING
    /// until this section existed — code review 01's second open item. That mattered
    /// because `scripts/import_recipe.py` assigns name-based ids (`butter-2`) rather than
    /// positional ones precisely so a revised document makes an override lapse VISIBLY
    /// instead of silently re-pointing his one-tablespoon butter at the flour. Visibly was
    /// the half nothing implemented.
    @MainActor
    private var lapsedTweaks: [TweakStore.LapseReport] {
        tweaks?.lapseReport() ?? []
    }

    var body: some View {
        List {
            if loader.diagnostics.isEmpty && warned.isEmpty && lapsedTweaks.isEmpty {
                Section {
                    Label("Every recipe loaded cleanly", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if !loader.diagnostics.isEmpty {
                Section {
                    Text("These files are in the app but could not be used. Everything "
                         + "else loaded normally.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(grouped, id: \.0) { fileName, items in
                    Section(fileName) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.kind.title).font(.subheadline.weight(.semibold))
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            if !warned.isEmpty {
                Section {
                    Text("These loaded and work. The importer could not work something "
                         + "out about them, which usually shows up later as a quantity "
                         + "that will not scale or an ingredient that never reaches a "
                         + "shopping list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(warned) { recipe in
                    Section(recipe.title) {
                        ForEach(Array(recipe.warnings.enumerated()), id: \.offset) { _, warning in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text(warning).font(.caption)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }

            lapsedBlock
        }
        .navigationTitle("Recipe files")
    }

    /// The explainer is written as a leading section rather than a `footer:`, to match the
    /// two blocks above it: three blocks that explain themselves the same way read as one
    /// screen, and this one has the hardest distinction to land.
    ///
    /// `@MainActor` for the same reason `CookView` annotates its own builders: `TweakStore`
    /// is main-actor isolated, `View.body` is inferred so and a plain helper is not, so
    /// without this the reads below and the clearing closure are cross-actor references.
    @MainActor
    @ViewBuilder
    private var lapsedBlock: some View {
        if !lapsedTweaks.isEmpty {
            Section {
                Text("These recipe files are fine. It is your own edits that no longer "
                     + "fit them: the document was revised, the ingredient or step you "
                     + "had adjusted is not in it any more, and the edit has stopped "
                     + "applying. It is shown rather than deleted so a lost tweak is "
                     + "something you decided to lose.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(lapsedTweaks) { report in
                Section(report.title) {
                    // `.missing` is handled WHOLE — one row, no list of lines. The file
                    // carrying this id is not bundled at all, so there is nothing to
                    // compare his overrides against, and `lapseReport` deliberately
                    // reports no lapses for it: offering "forget it?" line by line for a
                    // file that may come back on the next build is a screenful of
                    // decisions he should not be asked to make.
                    if report.status == .missing {
                        missingRow
                    } else {
                        ForEach(report.lapses) { lapse in
                            lapsedRow(lapse, in: report.recipeID)
                        }
                    }
                }
            }
        }
    }

    private var missingRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("This recipe is no longer in the app")
                .font(.subheadline.weight(.semibold))
            Text("Your edits and notes for it are kept. If the file comes back in a later "
                 + "build they apply again on their own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func lapsedRow(
        _ lapse: ResolvedRecipe.LapsedOverride, in recipeID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "pencil.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(Self.heading(for: lapse.kind))
                    .font(.subheadline.weight(.semibold))
            }
            // The SNAPSHOT, which is the line or step title as it read when he edited it.
            // It is the only thing on screen he can recognise — the key is `butter-2` and
            // the content it pointed at is gone — and it is what the snapshot columns on
            // `IngredientOverride` and `StepOverride` are stored for.
            if !lapse.snapshot.isEmpty {
                Text(lapse.snapshot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Forget this tweak", role: .destructive) {
                tweaks?.clearLapsed(lapse, in: recipeID)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private static func heading(for kind: ResolvedRecipe.LapsedOverride.Kind) -> String {
        switch kind {
        case .ingredient: return "An ingredient you had changed"
        case .step: return "A step you had changed"
        }
    }

    /// Grouped by file, since one bad file usually produces several complaints
    /// and a flat list of them reads as several broken files.
    private var grouped: [(String, [ContentDiagnostic])] {
        Dictionary(grouping: loader.diagnostics, by: \.fileName)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}
