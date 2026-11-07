import Foundation

/// Flattens a dish into the lines a shopping list can add up.
///
/// A pure namespace: no fetches, no SwiftData, no SwiftUI. Sub-recipes are reached through an
/// injected `resolve: (String) -> ResolvedRecipe?` rather than a relationship, because recipes
/// are immutable bundled content and `component.sourceRecipeID` is a content id string.
///
/// It walks `components` in array order and each component's `lines` in array order. There are
/// no `sortIndex` reads anywhere in here: a JSON array is already ordered, which is the one
/// genuine simplification the content/persistence split buys.
enum RecipeGraph {

    /// Who asked for a line, captured at flatten time and never reconstructed later. It is
    /// what the provenance row prints, and `recipeID` is a content id string rather than a
    /// UUID for the same reason `MealRecipe` holds one.
    struct Provenance: Hashable, Sendable {
        var mealID: UUID? = nil
        var mealDayKey: Int = 0
        var mealSlotRaw: String = ""
        var mealTitle: String = ""
        var recipeTitle: String = ""
        var recipeID: String = ""
        var scaleDescription: String = ""
    }

    struct FlatLine: Sendable {
        /// The content line's stable id, carried through so a buy-or-make decision and a
        /// `.tweaked` flag can be replayed on a regenerate.
        var lineID: String = ""
        /// "" when the importer could not place it; the caller resolves this to a `FoodItem`.
        var catalogName: String = ""
        var displayName: String = ""
        /// Already scaled, already overridden, and already the HIGH end of a range. nil means
        /// there is no quantity at all — "Pinch flaky salt" — and `unmeasuredNote` carries the
        /// words instead.
        var quantity: Quantity? = nil
        /// The recipe's OWN second measurement of the same ingredient, scaled identically:
        /// "1 1/2 cups all-purpose flour (190g)". Carried rather than resolved here because
        /// choosing between it and the primary needs the `FoodItem`'s preferred dimension,
        /// which the flattener has no business knowing. It is exact where `gramsPerCup` is an
        /// approximation, so the builder prefers it over a density conversion.
        var altQuantity: Quantity? = nil
        var unmeasuredNote: String = ""
        var preparation: String = ""
        var originalText: String = ""
        /// Through the display ladder, so the provenance row reads in units a cook reads.
        var scaledText: String = ""
        var wasTweaked: Bool = false
        /// ["NY Strip Crostini", "Creamed horseradish spinach"].
        var componentPath: [String] = []
        var provenance: Provenance = Provenance()
        var notes: [ScalingNote] = []
    }

    /// What could not be worked out, kept rather than logged. There is no console anywhere
    /// near a family phone, so the only place a bad reference can explain itself is a screen.
    enum Diagnostic: Hashable, Sendable {
        case cycle(recipeTitle: String)
        case depthExceeded(recipeTitle: String)
        /// The sub-recipe could not be expanded dimensionally, so the line stays a buy-it line
        /// and says so rather than being silently mis-scaled.
        case subRecipeNotExpandable(recipeTitle: String, lineText: String, reason: String)
        case unresolvedItem(text: String, recipeTitle: String)
        /// A `sourceRecipeID` or `subRecipeID` that the resolver cannot resolve. A content id
        /// is allowed to dangle and no delete rule can stop it — the thing on the other end is
        /// a file, not a row — so it is surfaced instead of silently contributing nothing.
        case missingRecipe(id: String, inRecipeTitle: String)
        case orphanedComponentReference(componentTitle: String, recipeTitle: String)
        /// A committed file whose serving count is zero or negative. `Recipe.servings`
        /// substitutes 1 so the planner still works, and this is what says it did.
        case zeroServings(recipeTitle: String)
    }

    /// `visited` is passed BY VALUE and that is not a style choice.
    ///
    /// As `inout` it becomes a global already-seen set rather than a per-PATH cycle guard, so a
    /// stock recipe feeding two of the week's meals in one build silently contributes ZERO
    /// ingredients on every use after the first. By value, each branch carries its own path.
    static func flatten(
        recipe: ResolvedRecipe,
        scale: Rational,
        options: ShoppingListBuilder.Options,
        provenance: Provenance,
        componentPath: [String],
        resolve: (String) -> ResolvedRecipe?,
        visited: Set<String>,
        depth: Int,
        diagnostics: inout [Diagnostic]
    ) -> [FlatLine] {
        // Stock referencing stock referencing stock is not hypothetical in a library that
        // grows for ten years, and the failure without these two guards is a hang while he is
        // holding a phone in a grocery store.
        if visited.contains(recipe.id) {
            diagnostics.append(.cycle(recipeTitle: recipe.title))
            return []
        }
        if depth > options.maxExpansionDepth {
            diagnostics.append(.depthExceeded(recipeTitle: recipe.title))
            return []
        }

        var out: [FlatLine] = []
        let nextVisited = visited.union([recipe.id])

        for component in recipe.components {
            // An unnamed single group adds nothing to the path, so a three-ingredient
            // vinaigrette's provenance does not read "Vinaigrette > ".
            let path = component.title.isEmpty ? componentPath : componentPath + [component.title]

            if let sourceID = component.sourceRecipeID, !sourceID.isEmpty {
                if let sub = resolve(sourceID) {
                    // A sub-recipe AS A COMPONENT is part of the dish by definition, so it is
                    // always expanded — there is no buy-or-make decision to make about half a
                    // batch of the chimichurri that the dish is built from.
                    out.append(contentsOf: flatten(
                        recipe: sub,
                        scale: scale * component.sourceScale,
                        options: options,
                        provenance: provenance,
                        componentPath: path,
                        resolve: resolve,
                        visited: nextVisited,
                        depth: depth + 1,
                        diagnostics: &diagnostics
                    ))
                } else if component.lines.isEmpty {
                    diagnostics.append(.missingRecipe(
                        id: sourceID, inRecipeTitle: recipe.title
                    ))
                } else {
                    // It names a recipe that is gone AND carries lines of its own. The lines
                    // below still count — they are ingredients the file lists — and this says
                    // the referenced part is missing rather than dropping a third of a dish.
                    diagnostics.append(.orphanedComponentReference(
                        componentTitle: component.title, recipeTitle: recipe.title
                    ))
                }
            }

            for line in component.lines {
                // Tap water and ice for the bath are never shopped.
                if line.excludeFromShopping { continue }
                // A choice row is one of several WAYS to make the recipe — the pancake's
                // Cinnamon / Nutmeg / Both — and never a thing to buy. It carries no quantity
                // of its own, so without this it would reach the list as a presence item.
                if line.isChoice { continue }
                if line.isOptional && !options.includeOptionalLines { continue }

                var lineNotes: [ScalingNote] = []
                // `.fixed` is how "1 bay leaf" and the oil for the pan survive a 3× batch
                // without becoming three bay leaves and a fistful of salt.
                let lineScale = line.scalingRule == .fixed ? Rational.one : scale

                if let subID = line.subRecipeID, !subID.isEmpty {
                    let wantsExpansion = options.expandedLineIDs.contains(line.lineID)
                        || line.subRecipePolicy == .expandToIngredients
                    if line.subRecipePolicy == .assumeOnHand && !wantsExpansion {
                        // "I always have stock in the freezer." Not bought and not expanded.
                        continue
                    }
                    if wantsExpansion {
                        if let sub = resolve(subID) {
                            if let child = childScale(for: line, subRecipe: sub.recipe) {
                                out.append(contentsOf: flatten(
                                    recipe: sub,
                                    scale: lineScale * child,
                                    options: options,
                                    provenance: provenance,
                                    componentPath: path,
                                    resolve: resolve,
                                    visited: nextVisited,
                                    depth: depth + 1,
                                    diagnostics: &diagnostics
                                ))
                                continue
                            }
                            // Guessing is never an option here: see `childScale`. The line
                            // stays an ordinary buy-it line and is badged.
                            diagnostics.append(.subRecipeNotExpandable(
                                recipeTitle: sub.title,
                                lineText: line.cookDisplayText,
                                reason: "its yield is missing, zero, or in a different "
                                    + "dimension from this line"
                            ))
                            lineNotes.append(.unknownYield)
                        } else {
                            diagnostics.append(.missingRecipe(
                                id: subID, inRecipeTitle: recipe.title
                            ))
                        }
                    }
                }

                var scaled: Quantity? = nil
                if let written = shoppingQuantity(of: line) {
                    scaled = written.scaled(by: lineScale)
                }

                // The author's gram equivalent is written for the amount the line states, not
                // for the top of a range, so a ranged line keeps its own unit and drops the
                // alternate rather than scaling someone else's number by a factor they never
                // wrote.
                var alt: Quantity? = nil
                if line.amountMax == nil, let written = line.altQuantity {
                    alt = written.scaled(by: lineScale)
                }

                let scaledText = scaled.map { $0.displayString(system: options.unitSystem) }
                    ?? line.unmeasuredNote

                out.append(FlatLine(
                    lineID: line.lineID,
                    catalogName: line.catalogName,
                    displayName: line.displayName.isEmpty ? line.rawText : line.displayName,
                    quantity: scaled,
                    altQuantity: alt,
                    unmeasuredNote: line.unmeasuredNote,
                    preparation: line.preparation,
                    originalText: line.cookDisplayText,
                    scaledText: scaledText,
                    // A number that differs from what the printed recipe says must never be a
                    // mystery, so his tweak becomes a badge on the shopping line.
                    wasTweaked: recipe.isOverridden(lineID: line.lineID),
                    componentPath: path,
                    provenance: provenance,
                    notes: lineNotes
                ))
            }
        }

        return out
    }

    /// The dimensionally-sound sub-recipe scale. **nil means DO NOT EXPAND.**
    ///
    /// "2 cups chicken stock" against a recipe yielding "2 quarts" is `96 tsp / 384 tsp = 1/4`
    /// of a batch. Dividing a volume by a SERVING COUNT instead gives ~118, so the flattener
    /// shops for 118 batches of stock — and because it happens inside the recursion, the error
    /// compounds at every level.
    ///
    /// It takes the bundled `Recipe`: a yield is content that no override can change, which is
    /// also why `ResolvedRecipe` forwards it rather than owning it.
    static func childScale(for line: IngredientLine, subRecipe: Recipe) -> Rational? {
        guard let needed = shoppingQuantity(of: line),
              let yieldAmount = subRecipe.yieldAmount
        else { return nil }
        // Not a `guard let`: `resolve` returns nil for a noun it does not know and
        // `countUnit(noun:)` MINTS one for the open set and never fails, so the coalesced
        // expression is non-optional. A guard that can never fire reads as a check that is
        // happening when none is.
        let yieldUnit = UnitCatalog.resolve(subRecipe.yieldUnitLabel)
            ?? UnitCatalog.countUnit(noun: subRecipe.yieldUnitLabel)
        let yieldBase = yieldAmount * yieldUnit.baseFactor
        guard needed.dimensionKey == yieldUnit.dimensionKey, yieldBase != .zero else {
            return nil
        }
        return needed.base / yieldBase
    }

    /// What to BUY for a line: the top of a range, or the only amount there is.
    ///
    /// `amountMax` exists because the cook may use either end — three of the compotes ask for
    /// "2 to 3 tbsp" maple syrup — and arriving a spoonful short is worse than a spoonful
    /// over. `IngredientLine.quantity` is the LOW end and is what the cook screen renders;
    /// this is the shopping number.
    private static func shoppingQuantity(of line: IngredientLine) -> Quantity? {
        guard let amount = line.shoppingAmount,
              let unit = UnitCatalog.unit(
                  code: line.unitCode, fallbackDimension: line.dimension
              )
        else { return nil }
        return Quantity(amount: amount, unit: unit)
    }
}
