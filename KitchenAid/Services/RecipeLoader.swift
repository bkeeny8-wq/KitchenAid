import Foundation
import Observation

/// THE ONLY PLACE A `Recipe` COMES FROM.
///
/// Recipes are immutable bundled content, so there is no fetch and no store behind this —
/// every `Resources/Recipes/*.json` is decoded once at launch into `[String: Recipe]` and
/// never written again. Nothing else decodes recipe JSON, which is what makes "which
/// version of this recipe am I looking at" have exactly one answer: this dictionary.
///
/// `@Observable` and held as `@State` on the App, injected with `.environment(...)`, so a
/// view that renders a diagnostic updates when `load()` finishes. It is NOT `@MainActor`:
/// it touches no SwiftData and no SwiftUI, so a test can build one against a test bundle
/// with no container at all.
@Observable
final class RecipeLoader {

    /// Keyed by `Recipe.id`, which is the slug the file is named after. Archived recipes
    /// are IN here — a stored `recipeID` has to resolve against them, or archiving a
    /// recipe would look identical to deleting it (`RecipeContentStatus` exists for that
    /// distinction).
    private(set) var byID: [String: Recipe] = [:]

    /// Everything that went wrong, kept rather than logged. A recipe that silently fails
    /// to appear is the failure mode this project cannot debug from a family phone: there
    /// is no console, no crash report and no server, so the only place a bad file can
    /// explain itself is the Settings screen that renders these.
    private(set) var diagnostics: [ContentDiagnostic] = []

    /// Which file each id came from, so the post-load passes can name the file in a
    /// diagnostic rather than guessing `id + ".json"` — the two differ as soon as someone
    /// renames a file without re-importing it.
    private var fileNameByID: [String: String] = [:]

    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    // MARK: - Loading

    /// Idempotent: clears first, so a reload after a diagnostic is fixed does not leave the
    /// old diagnostics on screen beside the new ones.
    func load() {
        byID = [:]
        fileNameByID = [:]
        var found: [ContentDiagnostic] = []

        let decoder = JSONDecoder()
        // ISO-8601 because the only producer of a date in these files is
        // `scripts/import_recipe.py`, and `addedAt` is the one date field `Recipe` has.
        // The default strategy reads a bare `Double` of seconds, which no Python importer
        // would emit, so the default is the one spelling that is certainly wrong.
        decoder.dateDecodingStrategy = .iso8601

        for url in recipeFileURLs() {
            let fileName = url.lastPathComponent
            do {
                let data = try Data(contentsOf: url)
                let file = try decoder.decode(RecipeFile.self, from: data)
                let recipe = file.recipe

                // An id is the join key for every `MealRecipe`, `RecipeTweak` and
                // `ShoppingListSource` row, so a file without one is unusable rather than
                // merely odd — admitting it would mint rows that can never resolve.
                guard !recipe.id.isEmpty else {
                    found.append(ContentDiagnostic(
                        kind: .decodeFailed, fileName: fileName,
                        detail: "no \"id\", so nothing can reference this recipe"
                    ))
                    continue
                }

                // FIRST FILE WINS, and the walk is sorted by file name so "first" is the
                // same answer on every device. A non-deterministic winner means two phones
                // show different recipes under one id and neither is wrong.
                if let existing = fileNameByID[recipe.id] {
                    found.append(ContentDiagnostic(
                        kind: .duplicateID, fileName: fileName,
                        detail: "id \"\(recipe.id)\" is already loaded from \(existing); this file is ignored"
                    ))
                    continue
                }

                byID[recipe.id] = recipe
                fileNameByID[recipe.id] = fileName
            } catch {
                // ONE BAD FILE COSTS ONE RECIPE, NOT THE LAUNCH. The per-file do/catch is
                // the whole point: these files are hand-edited between imports, and a
                // trailing comma in the eighth must not take the other seven down.
                found.append(ContentDiagnostic(
                    kind: .decodeFailed, fileName: fileName, detail: describe(error)
                ))
            }
        }

        diagnostics = found + integrityDiagnostics()
    }

    /// Bundled recipe files, sorted by name.
    ///
    /// The subdirectory is tried first and the bundle root second, because whether
    /// `Resources/Recipes` survives as a folder in the built product depends on how the
    /// Xcode project references it — a group flattens it, a folder reference keeps it — and
    /// a loader that silently finds nothing is indistinguishable from a loader that works
    /// on an empty library. `ingredients.json` is excluded by name: it lives at the root,
    /// it is not a recipe, and decoding it would post a `decodeFailed` for a file that is
    /// perfectly valid.
    private func recipeFileURLs() -> [URL] {
        if let nested = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Recipes"),
           !nested.isEmpty {
            return nested.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let flat = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return flat
            .filter { $0.lastPathComponent != "ingredients.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The passes that need every file loaded before they can run.
    private func integrityDiagnostics() -> [ContentDiagnostic] {
        var out: [ContentDiagnostic] = []
        let ordered = byID.values.sorted { byTitle($0, $1) }
        for recipe in ordered {
            let fileName = fileNameByID[recipe.id] ?? "\(recipe.id).json"

            if recipe.isEmpty {
                out.append(ContentDiagnostic(
                    kind: .emptyRecipe, fileName: fileName,
                    detail: "\"\(recipe.title)\" has no ingredients and no method"
                ))
            }

            // A duplicate `lineID` is reported because overrides join on it: two lines
            // sharing `butter-1` means one tweak silently applies to both, which is the
            // re-pointing failure the name-plus-occurrence key exists to prevent.
            var seenLineIDs: Set<String> = []
            for line in recipe.allLines {
                guard !line.lineID.isEmpty else { continue }
                if seenLineIDs.contains(line.lineID) {
                    out.append(ContentDiagnostic(
                        kind: .duplicateLineID, fileName: fileName,
                        detail: "two ingredients share the id \"\(line.lineID)\", so one tweak would apply to both"
                    ))
                } else {
                    seenLineIDs.insert(line.lineID)
                }
            }

            for referenced in Set(recipe.referencedRecipeIDs).sorted() {
                guard !referenced.isEmpty, byID[referenced] == nil else { continue }
                out.append(ContentDiagnostic(
                    kind: .missingReference, fileName: fileName,
                    detail: "refers to recipe \"\(referenced)\", which is not bundled"
                ))
            }
        }
        return out
    }

    // MARK: - Reading

    /// Resolves against archived recipes too: archiving hides a recipe from the library,
    /// it does not break the ids that point at it. `MealRecipe.recipe(_:)` calls exactly
    /// this spelling.
    func recipe(id: String) -> Recipe? {
        byID[id]
    }

    /// What the library shows: not archived, title-sorted.
    var all: [Recipe] {
        byID.values.filter { !$0.isArchived }.sorted { byTitle($0, $1) }
    }

    /// What a stored `recipeID` resolves against, archived included.
    var allIncludingArchived: [Recipe] {
        byID.values.sorted { byTitle($0, $1) }
    }

    /// Distinct tags across everything bundled, archived included, so a filter chip does
    /// not vanish because the one recipe carrying it was archived.
    var allTags: [RecipeTag] {
        var seen: Set<String> = []
        var out: [RecipeTag] = []
        for recipe in allIncludingArchived {
            for tag in recipe.tags where !seen.contains(tag.id) {
                seen.insert(tag.id)
                out.append(tag)
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// THE DANGLING-ID CHECK. A `recipeID` can dangle and no delete rule can stop it: the
    /// thing on the other end of the string is a file, not a row.
    ///
    /// An EMPTY id is not missing. A `MealRecipe` holding `""` is a takeout or note entry
    /// that never named a recipe, and reporting it as a lost recipe would put "recipe no
    /// longer bundled" on a row that never had one.
    func isMissing(_ recipeID: String) -> Bool {
        !recipeID.isEmpty && byID[recipeID] == nil
    }

    /// Three states, not two — see `RecipeContentStatus`. The middle one is the whole
    /// reason `"isArchived": true` is the cheap alternative to deleting a file.
    func status(of recipeID: String) -> RecipeContentStatus {
        guard let recipe = byID[recipeID] else { return .missing }
        return recipe.isArchived ? .archived : .present
    }

    /// "Where do I use this chimichurri." Computed over content references rather than
    /// stored, because a bundled recipe cannot hold a SwiftData relationship to another
    /// one and over a few hundred recipes this is a dictionary walk.
    ///
    /// Archived recipes are included: a component still used by an archived dish is still
    /// used, and hiding that would make a "nothing uses this" answer wrong.
    func usages(of recipeID: String) -> [Recipe] {
        guard !recipeID.isEmpty else { return [] }
        return byID.values
            .filter { $0.id != recipeID && $0.referencedRecipeIDs.contains(recipeID) }
            .sorted { byTitle($0, $1) }
    }

    /// Recipes he has never cooked are surfaced by title; ties fall back to the id so the
    /// order is total. `localizedStandardCompare` rather than `<`, because raw `String <`
    /// is Unicode-scalar ordering and sorts "NY Strip" above every lowercase neighbour —
    /// the same defect SPEC_REVIEW_03 finding 9 raised against the shopping list.
    private func byTitle(_ a: Recipe, _ b: Recipe) -> Bool {
        let result = a.title.localizedStandardCompare(b.title)
        if result == .orderedSame { return a.id < b.id }
        return result == .orderedAscending
    }

    // MARK: - Diagnostics

    var hasDiagnostics: Bool { !diagnostics.isEmpty }

    /// A decode failure is reported with the key and the path, not just "could not be
    /// read": the file is hand-edited, and a diagnostic that does not say WHERE costs a
    /// re-read of a 400-line JSON file to find a renamed key.
    private func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing key \"\(key.stringValue)\"\(pathText(context))"
        case .typeMismatch(let type, let context):
            return "wrong type where \(type) was expected\(pathText(context))"
        case .valueNotFound(let type, let context):
            return "null where \(type) was required\(pathText(context))"
        case .dataCorrupted(let context):
            return "malformed JSON\(pathText(context))"
        @unknown default:
            return error.localizedDescription
        }
    }

    private func pathText(_ context: DecodingError.Context) -> String {
        let parts = context.codingPath.map { $0.stringValue }.filter { !$0.isEmpty }
        return parts.isEmpty ? "" : " at \(parts.joined(separator: " / "))"
    }
}
