# What the second document proves

Source: `docs/fixture-recipe-02.txt` — "Fluffy Whipped Egg White Pancakes and
Compotes", Brandon's second batch, a 4-page PDF. Asserted by R14–R28 in
`scripts/test_import.py`.

Recipe 01 was one recipe with a tabulated header, bulleted notes and a single
measurement per line. This document breaks every one of those assumptions, and
parsed by the recipe-01 rules it produced **one** recipe with one component,
sixteen merged steps and a total time of three minutes lifted out of "about 3
minutes" in a whipping instruction — while reporting **no warnings at all.**

The silence was the real defect. A parser that mangles a document and says so
costs ten minutes; one that mangles it quietly puts the wrong quantity on a
shopping list months later. Several requirements below exist only to make that
shape of failure loud.

---

## 1. A document can hold several recipes

Four: a pancake batter and three compotes, one per page, each with its own
title, ingredients, method and closing note.

**Requirement:** the importer emits a document envelope with a `recipes` array
and splits on the repeated page footer (`<document title>   Page N`). A
single-recipe document has no footer and comes back as one entry, so recipe 01
is unaffected. `--out-dir` writes one bundled file per recipe, because the app
has no concept of "page 3 of a PDF".

## 2. Not every recipe has an `Ingredients` header

The pancake's groups — "Pancake Batter" and "Spice Mix-Ins (add to the dry
ingredients)" — sit straight under the description. Requiring the header found
the *blueberry compote's* section four pages later and attributed it to the
pancake.

**Requirement:** with no header, ingredients are everything between the
description and the method. Header rows (`Makes`, `Active time`, a bare
`Ingredients`) are excluded, or the yield table arrives as two ingredients.

## 3. A yield can live in the description

> Base recipe with spice mix-ins. Compotes follow, one per page. **Makes about 8
> pancakes, serves 4.**

Recipe 01 tabulated this as "12 crostini (serves 4)".

**Requirement:** read both shapes. "about" is dropped; the number is kept.

## 4. Times must be read from the header only

Step 3 says "until stiff, glossy peaks form, **about 3 minutes**". Searching the
whole document made that the recipe's total time.

**Requirement:** times come from the first six non-empty lines and nowhere else.
And `Makes about 8 pancakes` matches the time pattern with an *empty* capture,
so empty matches must be filtered — otherwise a timeless recipe looks timed.

## 5. An alternatives group is not an ingredient group

> **Spice Mix-Ins** (add to the dry ingredients)
> `Cinnamon | 1/2 tsp, good with the apple compote`
> `Nutmeg | 1/4 tsp, freshly grated if possible`
> `Both | 1/4 tsp cinnamon plus 1/8 tsp nutmeg for a lighter touch`

The first column names the **choice** and the amount is in the second, so every
quantity parser reads the row backwards and produces an ingredient called
"Cinnamon" with no quantity.

**Requirement:** a first column with no digits that is not a known qualifier
marks a choice row: label plus text, no quantity. In Swift this is
`IngredientLine.isChoice`, deliberately **not** `isOptional`, which already
means "may be left out". A choice row must never reach a shopping list — it is
one of several ways to make the recipe, not a thing to buy.

## 6. Quantities can be ranges

> `2 to 3 tbsp` maple syrup, adjusted to the sweetness of the berries

In all three compotes. Read as one number it became quantity 2 with the unit
"to 3 tbsp".

**Requirement:** store both ends. `amount` is the low end so a range-unaware
reader still works; `amountMax` is the high end. **The shopping list buys the
high end** — arriving a spoonful short is worse than a spoonful over — while
the cook sees "2 to 3", because the latitude is the point of writing it that way.

## 7. The recipe often gives BOTH measurements

> `1 1/2 cups` all-purpose flour **(190g)**, spooned and leveled
> `2 cups` blueberries **(300g)**
> `3 medium` apples **(about 1 lb or 450g)**

This is exactly the volume-and-weight pair Brandon asked for — *"1/4 cup of
milk… when baking 300g of bread flour"* — except here it is exact and written by
whoever wrote the recipe, rather than approximated from `gramsPerCup`.

**Requirement:** keep it as `altAmount` + `altUnitCode`. Where a parenthetical
offers two ("about 1 lb or 450g") take the **last**, because these documents put
metric second and grams are the useful one. When present, prefer it over any
density conversion.

## 8. A parenthetical without a number is commentary

> baking powder **(do not skip)** · cream of tartar **(optional, helps the
> whites hold)**

**Requirement:** move it to `preparation`. Left in the name, "baking powder (do
not skip)" matches no catalogue entry — and the second case was worse, because
splitting on the first comma cut *inside* the brackets and produced an
ingredient literally called `cream of tartar (optional`.

## 9. A trailing clause can follow a colon

> `2 cups` mixed berries (300g)**:** any mix of strawberries, blueberries,
> raspberries, and blackberries, with strawberries hulled and quartered

**Requirement:** split the name on a comma **or** a colon, whichever comes
first. Also: that line **wraps**, and the continuation has no quantity column —
a wrapped clause must append to the row above rather than become an ingredient
of its own, judged by its lowercase start.

## 10. A size word is not a unit

> `3 medium` apples

"medium" in the unit column gives a `count:medium` bucket that never merges with
plain apples.

**Requirement:** a known size word becomes preparation; the dimension stays
`count`. The same applies to a leading size word in the name: `large eggs` is
bought as `eggs`.

## 11. An either/or with no comma

> `1/4 cup` water **or** apple cider

**Requirement:** the first option is the name, the rest becomes preparation.
Left whole, "water or apple cider" resolves against nothing and reaches the
shopping list unresolved.

## 12. "1 pinch" and "Pinch" are different lines

Recipe 01 wrote a bare `Pinch` with no number. This document writes `1 pinch`
four times.

**Requirement:** both work — the bare word as a qualifier with no quantity, the
numbered one as a counted `pinch`.

## 13. Notes can be labelled paragraphs instead of bullets

> **Tip:** mash a few berries against the side of the pan for a thicker,
> jammier sauce.
> **Fluff checklist:** use fresh baking powder, weigh or spoon the flour, keep
> the whites stiff…

**Requirement:** a bullet **or** a label starts a note. And because these sit
after the numbered method with no header between, the step parser was swallowing
each one into the body of the final step — so the labelled paragraph has to
terminate the method, not join it.

## 14. Recipes write plurals; the catalogue is singular

`3 apples` failed to resolve against a catalogue entry called `apple`.

**Requirement:** `build_catalogue.py` derives the **regular** plural for every
entry and the collision check rejects anything ambiguous. Irregular ones stay
explicit: `-f`/`-fe` words are skipped entirely, and `-o` words are listed,
because English does not decide `tomatoes` and `avocados` by rule. A wrong alias
is worse than a missing one — it matches nothing while looking handled.

`mixed berries` was added as its own entry. All 17 distinct ingredients across
these four recipes now resolve.

## 15. What the document does not say must be reported

The three compotes give no serving count, no yield and no times. They are
sauces, so that is reasonable of them — but **meal-plan scaling needs a serving
count**, and a recipe that silently has none scales by nothing.

**Requirement:** warn for a missing serving count, a missing yield, missing
times, and any quantity cell that could not be read. Ten warnings across these
four recipes, every one of them true.

**Open, and needs Brandon:** the compotes cannot be scaled until they have a
serving count. Either he gives them one, or a compote planned alongside the
pancakes should inherit the meal's portion count rather than scale on its own.
