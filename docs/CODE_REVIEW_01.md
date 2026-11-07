# Code review 01 — the Swift

The three `SPEC_REVIEW_*` rounds reviewed the **document**. This is the first
review of the **code**, run after the last three tabs landed: 105 files, 22,169
lines, none of it ever compiled.

Three lenses in parallel (compile-correctness, the shopping algorithm's twelve
findings, a hand-trace against the real recipes), then an adversarial verify of
every fix.

## What it found

**Ten blocking, all real.** Nine were other people's; one was mine from an hour
earlier. Every one is fixed in `b9d419e` except where noted.

| | Defect | Why the checkers missed it |
|---|---|---|
| 1–4 | `CookTimerBar`, `CookIngredientsSheet`, `CookTimingChartSheet`, `CookShoutedSheet` constructed in `CookView` and declared **nowhere** | `check_swift.py` collected type names only from *type positions*. A view that is only ever constructed was invisible. **Hole closed** — it now scans constructor position too. |
| 5 | `try?` double-unwrapped in `depleteFromPantry` | SE-0230 flattens `try?`; not a structural error |
| 6 | `CookView` instantiated nowhere — Today rendered the bare word "Dinner" | No checker looks for an unreachable screen |
| 7 | `HouseholdView` instantiated nowhere | Same |
| 8 | `displayUnit` rung (a) returned "18 tsp" where its own doc comment two lines above promised "6 tbsp" | Arithmetic; needs a trace, not a grep |
| 9 | `testVolumeAndMassCollapseWhenADensityExists` asserted the opposite of what `sum` does | The tests have never been run |
| 10 | `testNoDisplayStringLeaksAnAbsurdFraction` asserted **nothing** — `toBuy` was empty so the loop body never ran | Same |

Wiring cook mode up then exposed an eleventh: the Cook link dropped the dish
identity, so a cooked meal never reached `.cooked` and the shopping builder
would shop for it again after deducting its ingredients — the exact double-shop
`contributesToShopping` excludes `.cooked` to prevent.

## The lesson worth keeping

**Three unbuilt product decisions, each written up as though built.** Items 6
and 7 were not bugs in code — they were screens that existed, worked, and could
not be reached from anywhere, while this repo's own commit messages said the
tabs were done. The third (in-app tweaks) is still open below.

A static checker can tell you a type is missing. Nothing but reading the
decision table against the running app tells you a feature nobody can reach.
So: when a commit claims a decision is built, name the screen it is reachable
**from**.

**The first fix for item 8 was worse than the bug.** Narrowing rung (a) with
rung (b)'s own `<= 8` test changed 44 displays and made 12 strictly worse — 4
tsp became "1 1/3 tbsp", 18 oz became "1 1/8 lb". Caught only because the
verifier re-swept it over Python `Fraction`s instead of reading the diff. Any
change to the display ladder gets a numeric sweep, not an eyeball.

**Two tests passed for the wrong reason.** With no toolchain, a test that
cannot run is indistinguishable from a test that passes — and one of these had
no assertion reachable at all, guarding the worst display bug this project has
had. Until these run on a Mac, treat every assertion as unverified.

## Still open

1. **In-app tweaks have no surface.** CLAUDE.md's decision is "notes and tweaks
   only — adjust a quantity, fix a step, add a note after cooking". The whole
   writer half of `TweakStore` (`setQuantity`, `setPreparation`,
   `setIngredientNote`, `setNotes`, `setFavorite`) has no caller, and
   `RecipeDetailView` reads `loader.recipe(id:)` — the **bundled** value — so
   even a tweak that existed would be invisible there. Cook, Shop and the PDF
   all go through the overlay correctly.
2. **Lapsed overrides are computed and shown nowhere.** `lapseReport()` and
   `clearLapsed(_:in:)` have no reader. When a recipe file is revised and an
   override's `lineID` disappears, his tweak stops applying silently. Belongs as
   a third section on `DiagnosticsView`.
3. **`ShoppingListStore.recompute` does not re-derive `.needsBridge`.** It seeds
   from the stored flags and only unions in new ones, so dropping the meal that
   asked for flour by the gram leaves the flag set for ever.
4. **`roast-turkey.json` carries `"servings": null` and silently becomes 4.**
   The decoder's `?? 4` fallback means a document that states no serving count
   never reaches `ShoppingListBuilder`'s `.zeroServings` diagnostic. Needs
   Brandon's answer and then a `servingsStated` distinction.
5. **Nothing has been compiled.** Five checkers pass; none is a compiler.
