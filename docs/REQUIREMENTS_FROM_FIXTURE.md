# What the first real recipe proves about the schema

Source: `docs/fixture-recipe-01.txt` — "NY Strip Crostini with Creamed Horseradish
Spinach", Brandon's first sample, supplied as a 2-page ReportLab PDF.

This is ground truth. Any model that cannot represent this document losslessly is
wrong. Each numbered item below is a requirement, with the evidence from the
document that forces it.

---

## 1. Ingredients are GROUPED, but steps are FLAT

The document has three ingredient groups — **"Crostini and steak"**, **"Creamed
horseradish spinach"**, **"To finish"** — and then a *single* numbered instruction
list, 1–8, that moves freely between them (step 2 toasts the baguette, step 5 wilts
the spinach, step 8 assembles both).

This corrects the assumption I started from. A component is **not** a self-contained
mini-recipe with its own steps. The grouping applies to *ingredients*; the method is
recipe-level.

**Requirement:** `RecipeComponent` owns an ordered list of ingredient lines and has a
name. Steps belong to the `Recipe`, ordered across the whole dish. A step MAY
optionally reference a component (for future per-component cook mode), but must not
be required to. A recipe with one unnamed default component must render as a plain
ungrouped ingredient list, so simple recipes don't look bureaucratic.

## 2. Two different yields, both needed

> Makes: **12 crostini (serves 4)**

A count of produced units (12 crostini) *and* a serving count (4). These are not the
same number and neither is derivable from the other.

**Requirement:** `yieldQuantity` + `yieldUnitLabel` ("12", "crostini") for display, and
a separate `servings` (4) that is the ONLY thing meal-plan scaling divides by. Scaling
for 6 eaters means ×1.5 → 18 crostini, and the yield label must scale with it.

## 3. Two different times

> Active time: **About 35 minutes** · Total time: **About 1 hour 10 minutes**

**Requirement:** separate `activeMinutes` and `totalMinutes`. The gap is real and
explained by step 1 — a 30-minute passive rest. Both are prefixed "About", so the UI
should not imply false precision.

## 4. Fractions must survive. Decimals are not acceptable.

Observed: `1/2 inch`, `1/2 tsp`, `1/4 tsp`, `1/4 tsp`, `1.25 inches`.

A `Double` round-trips `1/3 cup` as `0.3333333333`, and scaling ×3 must give back
exactly `1 cup`, not `0.9999999`.

**Requirement:** quantities stored as an exact rational (integer numerator +
denominator), formatted back to vulgar fractions for display. Scaling is rational
multiplication. This is the single highest-value correctness decision in the app.

## 5. Non-numeric quantities are real

> **Pinch** flaky salt

There is no number. Elsewhere, recipes say "to taste", "for garnish", "as needed".

**Requirement:** the quantity must be optional/`nil`-able with a free-text qualifier
that round-trips, and such a line must be carried to the shopping list as a
*presence* item ("flaky salt") with no quantity to aggregate — never as `0`, and never
dropped.

## 6. `oz` is ambiguous and this document uses it as weight three times

> `16 oz` NY strip steak · `10 oz` baby spinach · `4 oz` cream cheese

All three are **weight** ounces. But `oz` in recipes also means **fluid** ounces. Guess
wrong and "16 oz steak" becomes a volume.

**Requirement:** units carry an explicit dimension (mass / volume / count / length).
The importer must resolve bare `oz` by ingredient context and record the resolved
dimension, not re-guess at read time. `1/2 inch thick` also shows a **length** used
descriptively, not as a purchasable quantity — length belongs in the preparation
note, not the quantity.

## 7. Ingredient name and preparation must be separate fields

Observed: `baguette, 1/2 inch thick` · `shallot, minced` · `garlic cloves, smashed` ·
`prepared horseradish, drained` · `fresh chives, finely chopped` · `grated Parmesan` ·
`NY strip steak, about 1.25 inches thick`.

The shopping list needs "shallot", not "shallot, minced" — and it must match the
"shallot" already in the pantry.

**Requirement:** `IngredientLine.preparation` separate from the canonical
`Ingredient.name`. Aggregation and inventory matching key on the ingredient, never on
the display string. Note `grated Parmesan`, where the prep adjective comes *first* —
the importer cannot just split on the first comma.

## 8. THIS RECIPE AGGREGATES AGAINST ITSELF — the best test case in the document

| Ingredient | Line A | Line B | Correct total |
|---|---|---|---|
| butter | `1 tbsp` (crostini and steak) | `1 tbsp` (creamed spinach) | **2 tbsp** |
| kosher salt | `1 tsp` (steak) | `1/4 tsp` (spinach) | **1 1/4 tsp** |

A single recipe, planned once, must already produce a shopping list with *one* butter
line and *one* salt line. Any implementation that only de-duplicates across recipes
fails here.

**Requirement:** aggregation runs across components within a recipe as well as across
recipes in the plan. The `1 tsp + 1/4 tsp = 1 1/4 tsp` case also re-proves #4.

## 9. Bare counts whose unit lives in the name

> `2` garlic cloves, smashed · `1` shallot, minced · `12 slices` baguette

"2" has no unit; "clove" is embedded in the name. "12 slices" has a unit that is
really a cut of a larger purchasable item (one baguette).

**Requirement:** a `count` dimension with an optional label. And, deferred but
designed for: a purchase-unit concept, because the shopping list should eventually say
"1 baguette", not "12 slices baguette". v1 may carry "12 slices" through verbatim, but
the model must not make the better answer impossible.

## 10. Steps carry a title, a duration — sometimes a RANGE — and a body

> 1. **Season the steak (30 min).** Pat the steak dry and season…
> 3. **Sear the steak (7 to 8 min).** Heat a heavy skillet…

Every step follows `Title (duration). Body`. Step 3's duration is a **range**, and step
7 ("Slice the steak") and 8 ("Assemble") have **no** duration at all.

**Requirement:** `RecipeStep` has `title`, `body`, and optional
`minMinutes`/`maxMinutes` (equal when not a range, both nil when absent). This feeds a
cook-mode timer and is why the duration is parsed out rather than left in prose.

## 11. Temperatures appear in step bodies and are worth extracting

> Heat the oven to **400F** … medium rare (**125F**)

**Requirement:** not v1-critical, but do not destroy them. Leave step bodies verbatim
so a later pass can extract oven temp and target internal temp without re-import.

## 12. Notes are a list, not a blob

Four separate bulleted notes, each a distinct idea: one make-ahead instruction, one
"the key step" warning, one variation, one timing tip.

**Requirement:** `notes` is an ordered array of strings. One of them ("can be made a
day ahead") is semantically a make-ahead flag the meal planner would want later —
store as text now, don't flatten the bullets into one paragraph.

---

## Carried forward to the importer

The document is machine-regular: a title line, a one-line description, a
Makes/Active/Total table, `Ingredients` with group subheads and
quantity-unit-name columns, a numbered `Instructions` list, and a bulleted `Notes`
section. `pdftotext -layout` preserves the column structure cleanly.

Brandon will be adding recipes continuously, so this layout is worth targeting
directly with a paste-and-parse importer rather than hand-entering each one.
