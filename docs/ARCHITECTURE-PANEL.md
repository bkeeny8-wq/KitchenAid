> **STATUS: REFERENCE, NOT THE SPEC.** Read this preamble before using anything below.
>
> This document is the output of a three-architecture judge panel run on
> 2026-10-31, before Brandon had made most of his product decisions. It scored
> cook-first 7.8, inventory-truth 6.3, plan-first 6.2 and synthesised from the
> winner. It is kept because several of its mechanisms are genuinely good and
> worth lifting. It is **not** authoritative, for three reasons:
>
> **1. It describes a product Brandon has since ruled out.** It contains
> `RecipePhoto`, `CookLogEntry`, ratings, `DietaryRestriction`,
> `DietaryKeyword` and `AcknowledgedWarning` — photos, a cooking journal and
> allergy warnings were each offered to him and declined. See "Declined, not
> deferred" in CLAUDE.md.
>
> **2. It has recipes backwards.** `Recipe` here is a `@Model`: user-entered
> SwiftData rows with a full authoring UI. Brandon's actual pipeline is that
> Claude writes the recipe, he edits it, and the PDF is dropped into a session
> to be parsed and committed. Recipes are immutable bundled CONTENT with a
> SwiftData tweak overlay — the split his CFAL3 repo already uses. This is not
> a detail; it changes the model layer, the view layer and the migration story.
>
> **3. It is named wrong.** 219 paths say `Kitchen/` and the bundle id says
> `com.brandonkeeny.Kitchen`. The project is `KitchenAid` /
> `com.brandonkeeny.KitchenAid`. The synthesis agent flagged this itself.
>
> Its scale is also worth stating plainly: **32 `@Model` classes and 154 Swift
> files.** Applying Brandon's decisions removes a large fraction of that before
> a line is written.
>
> ### What IS worth lifting from it
>
> - **`Quantity` persisted as five flat primitives** (`hasQuantity`,
>   `amountNumerator`, `amountDenominator`, `unitCode`, `dimensionRaw`) behind a
>   `QuantityCarrying` protocol, rather than a `Codable` blob. A Codable
>   attribute is unqueryable and any change to the rational type or unit table
>   needs a custom migration that decodes every row. This is the single best
>   idea in the document.
> - **`hasQuantity == false`** as the representation for "Pinch flaky salt",
>   instead of a zero sentinel.
> - **Inventory level summed from transactions, not from lots.** Summing lots
>   lets an orphaned transaction sit in the ledger while silently not counting,
>   producing a divergence nothing can attribute.
> - **Two-pass count collapse**: count→count first (`clove → 1/10 head`,
>   `slice → 1/12 loaf`), then count→mass only if every noun shares a target.
>   This is what turns the fixture's "12 slices baguette" into "1 baguette" and
>   garlic into "need 1 3/10 heads, buy 2 heads" — the purchase-unit problem I
>   had deferred.
> - **Staples aggregate fully and divert at presentation**, so kosher salt's
>   `1 tsp + 1/4 tsp = 1 1/4 tsp` stays a live test even though the line never
>   reaches the shopping list.
>
> ### Known blocking defects its own critics found
>
> - `Recipe.tags` and `RecipeTag.recipes` both declare `@Relationship(inverse:)`.
>   SwiftData rejects an inverse declared on both sides, and the document's own
>   prose says the macro lives only on the tag.
> - `QuantitySubtotal.swift` is in the manifest with no spec, and its stated
>   contents are owned elsewhere.
> - `LedgerDivergence`, `DeleteRefusal`, `CookTimer` and `ExportError` appear
>   only in public signatures and are never declared.
> - `AppTab`'s cases are never listed, and "6 tabs" contradicts the four in the
>   view tree.
> - `Job.inventorySnapshot` has no owning view, and `Job.weekPlan` must emit
>   three structurally different pages through a writer that takes one.
>
> ---

# Kitchen — frozen architecture specification, v1

**Status: FROZEN.** This document is the build contract. Section 2 and Section 3 are
copied verbatim into the codebase; do not improve them in passing. If you believe a
decision here is wrong, change this file in its own commit with the reason, then change
the code — never the other way round.

Nothing in this repo has been compiled. Everything here was written in a Linux container
with no Apple toolchain. Review is not a compiler. The first person to open this in Xcode
should expect build errors, and should grep for the pattern rather than fixing one line
(see `CLAUDE.md`).

---

## 0. Ground rules, in the order they bind

### 0.1 Platform

| | |
|---|---|
| Frameworks | SwiftUI + SwiftData + PDFKit. No third-party packages. |
| Deployment target | iOS 17.0. Anything 18+ is `@available`-gated or not used. |
| Swift | `SWIFT_VERSION = 5.0` |
| Xcode | 27, `LastUpgradeCheck = 2700` |
| Devices | `TARGETED_DEVICE_FAMILY = "1,2"`, iPhone-first in layout |
| Bundle id | `com.brandonkeeny.Kitchen` |
| Team | `DEVELOPMENT_TEAM = HHSFT2GD2H` |
| Backend | None. No server, no keys, no network calls. |
| Distribution | Never published. Direct install / TestFlight internal, family only. |
| Targets | `Kitchen`, `KitchenTests`, `KitchenUITests` |

### 0.2 CloudKit-readiness, enforced everywhere

CloudKit is **off** in v1 (`cloudKitDatabase: .none`, written explicitly and commented so
the day it flips is a one-line diff). Every rule below is obeyed now anyway, because
turning it on later must not reshape the store.

1. **No `@Attribute(.unique)` anywhere.** Identity is code discipline — `FoodItemResolver`
   plus a deterministic merge pass (§5.1).
2. **Every non-optional stored property has a default value.** No exceptions.
3. **Every relationship is optional.** Every to-many is `[T]? = []` with a non-optional
   ordered computed accessor so no view ever writes `?? []`.
4. **Every to-many names its `inverse:` explicitly, and exactly one side of each edge
   carries the macro** — always the to-many side. The to-one side is a bare
   `var x: T? = nil` with a comment naming where its macro lives. SwiftData pairs
   un-inversed edges by *inference*, which is wrong at runtime and not at compile time;
   with four edges from `Recipe` into `RecipeComponent`/`IngredientLine`/`FoodItem` that
   is not a hypothetical.
5. **No `.deny`.** Only `.cascade` and `.nullify`, decided per edge in §2.1.
6. **No stored array attributes for data that two devices might both append to.** A
   stored `[String]` is last-writer-wins on the *whole blob* and is invisible to
   `#Predicate`. Aliases, count equivalences, diet keywords and recipe notes are all
   child **rows**. The two deliberate exceptions are named and justified in §2.1.
7. **Nothing is an incrementing counter.** `Recipe.cookCount` exists only as a
   declared cache whose single writer is the cook-finish path and whose truth is
   `cookLog.count` (§5.2).
8. **Zero is never an absent sentinel.** Durations, temperatures, ratings and prices are
   `Int?`. A quantity that does not exist is `nil`, not `0`.

### 0.3 Correctness rules that outrank tidiness

- **Quantities are exact rationals.** Never `Double`. `1/3 cup × 3` must be exactly
  `1 cup`. Every portion factor, serving count and yield is an `Int` numerator/denominator
  pair; nothing is laundered through `Double` on the way to a scale.
- **Volume, mass and count are different dimensions and are not convertible without
  per-item data.** The app never guesses a density. It says so, once, and learns.
- **The app never silently drops a requirement and never silently guesses one.** An
  unresolvable line is flagged and shown. A depletion that needs an absent bridge is
  *written* with `delta == nil` and lands in an inbox.
- **`docs/fixture-recipe-01.txt` is ground truth.** Any model that cannot represent it
  losslessly is wrong. `docs/REQUIREMENTS_FROM_FIXTURE.md` lists the twelve things it
  proves. The Python importer in `scripts/` already asserts all twelve and **runs in a
  cloud session** — it is the only automated check in this project that can execute.

### 0.4 Where this diverges from CFAL3, deliberately

CFAL3 is Brandon's established convention and is matched on layout, `@Model final class`
with a fully-defaulted explicit `init`, pure `enum` service namespaces, `@Observable`
services as `@State` on the App injected via `.environment(...)`, the defensive
`ModelContainer` with in-memory fallback, `UITestMode` with its throwaway defaults suite,
`accessibilityIdentifier` on everything a test touches, and comments that name the bug.

Three things cannot carry over:

1. **CFAL3 uses `@Attribute(.unique)`** on `Attempt.id`, `Session.id`,
   `FlashcardProgress.cardId`. Kitchen cannot. See §5.1.
2. **CFAL3 has zero `@Relationship`** — its graph is `Codable` structs decoded from a
   bundled JSON file, with SwiftData holding only flat progress rows joined by `UUID`
   strings. That works because its content is *shipped*. Kitchen's content is *authored
   continuously by him*, so it must be a real object graph. The decisive reason is the
   merge pass: de-duplicating a `FoodItem` means **enumerating every referrer**. With
   explicit inverses that is three array reads. With `foodItemID: UUID?` it is a
   full-store scan of every `IngredientLine`, `StockLot`, `InventoryTransaction` and
   `ShoppingListLine` on every launch, forever.
3. **CFAL3 is `TARGETED_DEVICE_FAMILY = 2`** (iPad only) and leans on split views.
   Kitchen is `"1,2"` and the *primary* cooking surface is an iPhone propped against the
   backsplash. The phone gets the designed path; iPad gets more columns, not a different
   app.

### 0.5 The decisions, one line each

Where the three candidate designs conflicted, this is the ruling and why.

| # | Decision | Why |
|---|---|---|
| 1 | **Components own ingredient lines only. `Recipe` owns a flat ordered `steps` relationship.** `RecipeStep.component` is an optional back-reference. | The fixture has three ingredient groups and ONE numbered 1–8 method that interleaves them (toast 2, sear 3, wilt 5, assemble 8). Steps reachable only through a component can represent nothing but all-steak-then-all-crostini. |
| 2 | **Two independent yields:** `servings` (the only scaling divisor) plus `yieldQuantity` + `yieldUnitLabel` for display. | "Makes: 12 crostini (serves 4)". A single `baseYield` makes scale = 4/12 = 1/3 and the first shopping list buys one third of everything. |
| 3 | **Inventory is an append-only `InventoryTransaction` ledger** with `StockLot.remaining` as an explicitly-commented cache. No scalar `amount` anywhere. | Two offline devices each decrementing a scalar resolve last-writer-wins and one decrement vanishes with no conflict handler possible. This is the one gap that is genuinely not additive later — a ledger cannot backfill history never recorded. |
| 4 | **`FoodItem → lots` and `FoodItem → transactions` are `.nullify`, not `.cascade`**, with `foodItemNameSnapshot` on both. | A `.cascade` means one stray `.onDelete` destroys the audit trail the whole architecture is built on. A service-layer refusal the schema cannot enforce is not a rule. |
| 5 | **`level(of:)` sums the item's TRANSACTIONS, not its lots.** `StockLot → transactions` is `.nullify`; an orphaned transaction still counts, into an "unassigned lot" bucket. | Otherwise deleting a lot leaves transactions that remain in the ledger but silently stop contributing, producing a permanent divergence `reconcileReport` can never attribute. |
| 6 | **`Quantity` persists as flat primitives** (`hasQuantity`, `amountNumerator`, `amountDenominator`, `unitCode`, `dimensionRaw`), never as a `Codable` composite. | A `Codable` struct attribute is an opaque blob: unqueryable, unreadable in the CloudKit dashboard, and any change to `Rational` or the unit table needs a custom migration stage that decodes every stored row in the old shape. |
| 7 | **Culinary conversion factors as exact rationals, volume base = teaspoon.** tsp 1 / tbsp 3 / fl oz 6 / cup 48 / pint 96 / quart 192 / gallon 768, metric anchored on 1 tsp = 5 mL. Mass: g 1, oz 567/20, lb 2268/5. | SI-exact factors make 1 cup = 236.588 mL, so a 240 mL carton leaves a 3.4 mL residue that surfaces as a spurious "1 tsp heavy cream" line. They also give 32-million denominators and the entire overflow-fallback code path those require. SI-exactness buys nothing a cook can perceive. |
| 8 | **`KitchenUnit` is a struct with a `code: String`, not an enum.** | Count nouns are an open set he extends by typing. More importantly, each count noun is its own merge bucket, which is the only thing that stops `2 cloves + 1 head` summing to "4 cloves". |
| 9 | **The `.count` dimension is partitioned by count noun first**, then collapsed across noun buckets through `CountEquivalence` only when every member has one. | `CountEquivalence` existed in one design but was consulted only when crossing *dimensions*, so the bridge could never fire within `.count` and garlic was understated by ~50 g. |
| 10 | **`CountEquivalence` is a per-`FoodItem` row table**, not a scalar `gramsPerCount`. | Garlic needs both clove→5 g and head→50 g. The fixture's "12 slices baguette" needs slice→loaf to ever shop as "1 baguette". One scalar structurally cannot hold two count units. |
| 11 | **Every shopping line carries an N-element set of per-dimension subtotal ROWS** for requested / have / toBuy / purchase. | Flour arriving as cup + gram + package is three dimensions. A single `secondaryText` or `neededSecondary` slot drops the third. |
| 12 | **Both `needed` and the rounded `purchase` quantity are stored, and receive-into-inventory posts the PURCHASE quantity.** | Restocking what the recipe needed makes tracked stock drift monotonically to zero and the pantry is useless within a month. The line reads "need 1 1/3 cups, buy 1 quart" and the quart enters the ledger. |
| 13 | **`StoreSection` and `StorageLocation` are `@Model` rows under a `Store` parent**, with `sortIndex` and `defaultShelfLifeDays`. | Enums mean no "Fish counter" or "Garage fridge" without a build, no per-store walk order, and a walk order in `UserDefaults` is deliberately not synced — his iPad would shop a different store than his phone. |
| 14 | **`PlannedMeal.leftoversFrom` self-relationship with an explicit `leftoverMeals` inverse, plus `MealEntryKind`.** | A leftovers night must contribute nothing to shopping *without* being `isSkipped`, which otherwise conflates "do not shop for this" with "we skipped it" and renders it as skipped on the calendar. |
| 15 | **A separate leftovers meal draws down the source's `servingsCooked`. `.leftoversOnly` attendance at the source is the mutually exclusive alternative, not an additional path.** The editor refuses both for the same person + source. | Otherwise the plan double-counts a portion and the calendar cannot say "you are a portion short". |
| 16 | **`DietaryRestriction` is a `@Model`** with `kind`, `severity`, keyword **rows** and explicit `FoodItem` links; every warning carries `path: [String]`. | "No cilantro for Dad" arrives in month four and an enum case is a migration. The path (`["NY Strip Crostini","Creamed horseradish spinach","heavy cream"]`) is what makes the answer a side plate rather than a cancelled dinner. |
| 17 | **No `Household` entity.** The household *is* the set of `Eater` rows. | A singleton row created by bootstrap-if-empty means two offline devices both bootstrap, and now there are two rosters with attendance split across them. |
| 18 | **`dayKey: Int` (yyyymmdd) stored beside `date: Date`.** | A `#Predicate` on a `Date` range is correct until he crosses a timezone or a DST boundary, and then "Tuesday's dinner" renders on Monday night. Four bytes against a weekend of `Calendar` debugging. Written in exactly one place, `CalendarKey.dayKey(for:)`. |
| 19 | **`ShoppingListSource` keeps denormalized snapshot strings AND a live `.nullify` edge to `plannedMeal`.** | The snapshots preserve history across a recipe edit; the live edge makes "drop Thursday's dinner" and "jump to the meal that caused this line" queries instead of a decode-every-blob scan. |
| 20 | **`Recipe.notes` is an ordered list of `RecipeNote` rows.** | The fixture has four distinct bullets: a make-ahead instruction, a key-step warning, a variation, a timing tip. One of them is semantically the make-ahead flag the planner wants. Flattening them on import cannot be undone. |
| 21 | **`RecipeStep` splits `title` / `body` and carries optional `minMinutes`/`maxMinutes`.** | Every step in the document is "Title (duration). Body". Step 3's duration is the range "7 to 8 min"; steps 7 and 8 have none. |
| 22 | **Sub-recipe expansion converts the line quantity into the sub-recipe's YIELD dimension and divides by `yieldQuantity`** — never by a serving count. If the conversion is impossible or the yield is absent, the line is **not expanded**; it stays a buy-it line flagged `.unknownYield`. | Dividing millilitres by servings shops for 118 batches of stock, and the error compounds at every level of the recursion. |
| 23 | **The cycle guard `visited` is passed BY VALUE.** | As `inout` it becomes a global already-seen set, so one stock recipe feeding two of the week's meals contributes zero ingredients on the second use. |
| 24 | **Meals whose status is `.cooked` are excluded from collection, as well as `.skipped`.** | Cooking already depleted inventory; collecting it again shops twice for a meal already made. |
| 25 | **Staples aggregate fully, then divert at presentation.** The staples footer shows the summed quantity. | The fixture's kosher salt (1 tsp + 1/4 tsp = 1 1/4 tsp) is the document's own proof case for intra-recipe aggregation. Diverting salt to a quantity-less bucket means the arithmetic never runs on it and butter becomes the only surviving proof. |
| 26 | **`ratingSum` is not in the schema.** Average over `cookLog.compactMap(\.rating)`. | Shipping a field already decided to be deleted turns a one-line cleanup into a migration. |

---

## 1. File manifest

Every Swift file to be created, grouped by folder, with what it owns. Complete and
non-overlapping — this is the build work-list. 30 `@Model` classes, 6 tabs.

### `Kitchen/App/`

| Path | Owns |
|---|---|
| `Kitchen/App/KitchenApp.swift` | `@main`. The schema list, the defensive `ModelContainer` with in-memory fallback, `storeFailure`, every `@Observable` service as `@State` injected via `.environment(...)`, and the launch `.task` (seed → reconcile → recompute caches). |
| `Kitchen/App/UITestMode.swift` | `-uitesting` launch arg, the in-memory store flag, and the `static let` throwaway `UserDefaults` suite. Copied structurally from `CFAL3App.swift`, comment and all. |
| `Kitchen/App/AppTab.swift` | The tab enum: `title`, `symbol`, and the test-addressable `identifier`. |
| `Kitchen/App/RootTabView.swift` | `TabView` over `AppTab`, the store-failure banner, the cook-mode `fullScreenCover`, the Settings sheet. |
| `Kitchen/App/KitchenRouter.swift` | `@Observable`. Selected tab, presented sheets, the active cook-mode payload. Modelled on CFAL3's `TabRouter`. |

### `Kitchen/Models/Schema/`

| Path | Owns |
|---|---|
| `Kitchen/Models/Schema/KitchenSchema.swift` | `KitchenSchemaV1: VersionedSchema` with the single `models` array shared by the container and the tests, and `KitchenMigrationPlan: SchemaMigrationPlan` with an empty `stages`. Written before the first build: adding a `VersionedSchema` *later* means the existing store carries no recorded version identity, so the first real migration has nothing to migrate from. |

### `Kitchen/Models/Support/` — value types, no `@Model`

| Path | Owns |
|---|---|
| `Kitchen/Models/Support/Rational.swift` | Exact fractions. gcd-normalized, overflow-checked on `+ - * /`, `init(approximating:)`, `ceiling(toMultipleOf:)`, `rounded(toDenominator:)`, `mixedDescription`, `vulgarDescription`. |
| `Kitchen/Models/Support/MeasureDimension.swift` | `volume / mass / count / unmeasured` and the base-unit identity of each. |
| `Kitchen/Models/Support/KitchenUnit.swift` | The unit struct: `code`, `dimension`, `baseFactor: Rational`, singular/plural, `isHouseholdCommon`, `system`, `dimensionKey`. |
| `Kitchen/Models/Support/UnitCatalog.swift` | The conversion table (culinary, exact rationals), synonym resolution (`T`/`tbsp`/`tablespoons`), `countUnit(noun:)` for the open set, `displayCandidates(for:system:)`. The only place a factor is written. |
| `Kitchen/Models/Support/Quantity.swift` | `amount` + `unit`, `base`, `scaled(by:)`, `converted(to:)`, `displayString(system:)`, **and the `QuantityCarrying` protocol** that gives every model holding a quantity its five stored primitives and one computed accessor. |
| `Kitchen/Models/Support/QuantityMath.swift` | `sum`, `subtract`, `collapse` across dimensions via density and `CountEquivalence`, and `displayUnit(forBase:dimensionKey:hint:)`. The arithmetic under test. |
| `Kitchen/Models/Support/QuantitySubtotal.swift` | The in-flight value type for one (dimension, countNoun) subtotal, and its `SubtotalRole`. Mirrors the persisted row. |
| `Kitchen/Models/Support/MergeKey.swift` | `ItemIdentity` (`.cataloged(UUID)` / `.freeText(String)`) and the aggregation bucket key `(item, dimensionKey)`. |
| `Kitchen/Models/Support/KitchenEnums.swift` | `MealSlot`, `MealEntryKind`, `AttendanceStatus`, `PlanStatus`, `CourseKind`, `Difficulty`, `BatchGranularity`, `StockTrackingMode`, `TransactionKind`, `ResolutionState`, `LineStatus`, `LineSourceKind`, `SubtotalRole`, `RestrictionKind`, `RestrictionSeverity`, `ScalingRule`, `SubRecipePolicy`, `StorageKind`, `UnitSystem`, `PlanScope`, `NoteKind`. All `String`-raw-value-backed. |
| `Kitchen/Models/Support/ScalingNote.swift` | `.noAttendance / .unknownYield / .snappedToBatch / .overridden / .leftoversIncluded` and their badge text. |
| `Kitchen/Models/Support/LineFlag.swift` | The shopping-line flag set and its `|`-delimited blob encoding. |
| `Kitchen/Models/Support/CalendarKey.swift` | `dayKey(for:in:)`, `date(fromDayKey:)`, `weekInterval(containing:)`, `monthInterval(containing:)`. The ONLY place day math lives. |
| `Kitchen/Models/Support/NameNormalizer.swift` | Lowercase, diacritic-fold, strip punctuation and parentheticals, drop trailing prep qualifiers, conservative singularize with a stoplist. Produces the `matchKey`. |

### `Kitchen/Models/Catalog/`

| Path | Owns |
|---|---|
| `Kitchen/Models/Catalog/FoodItem.swift` | `@Model`. The canonical thing you buy and stock. The only row that means "a thing in my kitchen". |
| `Kitchen/Models/Catalog/FoodItemAlias.swift` | `@Model`. One alias row (`scallion` → green onion) with its own `matchKey`. |
| `Kitchen/Models/Catalog/CountEquivalence.swift` | `@Model`. One count-unit bridge per row (clove → 5 g, head → 50 g, slice → 1/12 loaf). |
| `Kitchen/Models/Catalog/Store.swift` | `@Model`. A store, owning its own section geography. |
| `Kitchen/Models/Catalog/StoreSection.swift` | `@Model`. One aisle with a `sortIndex` he drags. |
| `Kitchen/Models/Catalog/StorageLocation.swift` | `@Model`. Pantry / fridge / freezer / garage fridge, with `defaultShelfLifeDays`. |
| `Kitchen/Models/Catalog/MergeRecord.swift` | `@Model`. An audit row per de-dup merge so Settings can say "merged 3 duplicates" instead of mutating his data silently. |
| `Kitchen/Models/Catalog/SeedRecord.swift` | `@Model`. `seedKey` fetched before applying — idempotent seeding without `.unique`. |

### `Kitchen/Models/Recipes/`

| Path | Owns |
|---|---|
| `Kitchen/Models/Recipes/Recipe.swift` | `@Model`. Title, the two yields, times, the four `Recipe`-rooted relationships with explicit inverses, and the declared-cache cook stats. |
| `Kitchen/Models/Recipes/RecipeComponent.swift` | `@Model`. An ingredient GROUP. Owns lines, never steps. |
| `Kitchen/Models/Recipes/IngredientLine.swift` | `@Model`. One ingredient line: optional quantity, resolved dimension, name/preparation split, `foodItem` and `subRecipe` links. |
| `Kitchen/Models/Recipes/RecipeStep.swift` | `@Model`. Flat, recipe-ordered. `title` / `body`, optional min/max minutes, optional temperatures, optional `component` tag. |
| `Kitchen/Models/Recipes/RecipeNote.swift` | `@Model`. One note bullet with a `kind`, ordered. |
| `Kitchen/Models/Recipes/RecipeTag.swift` | `@Model`. A renameable tag. |
| `Kitchen/Models/Recipes/RecipePhoto.swift` | `@Model`. `.externalStorage` image data, caption, hero flag. |
| `Kitchen/Models/Recipes/CookLogEntry.swift` | `@Model`. "Things that I do and make": measured duration, rating, notes, `changesMade`, photo, the scale actually cooked. |

### `Kitchen/Models/Planning/`

| Path | Owns |
|---|---|
| `Kitchen/Models/Planning/Eater.swift` | `@Model`. A household member or a recurring guest, with an integer portion factor. |
| `Kitchen/Models/Planning/AttendanceDefault.swift` | `@Model`. "Sarah is never home Thursdays" — a weekday+slot rule applied when a `PlannedMeal` is created. |
| `Kitchen/Models/Planning/DietaryRestriction.swift` | `@Model`. Kind, severity, eater links, explicit `FoodItem` links. |
| `Kitchen/Models/Planning/DietaryKeyword.swift` | `@Model`. One keyword row ("walnut") — a row, not a `[String]`. |
| `Kitchen/Models/Planning/PlannedMeal.swift` | `@Model`. The calendar cell: date, `dayKey`, slot, kind, the leftovers self-edge, attendance, dishes. |
| `Kitchen/Models/Planning/MealRecipe.swift` | `@Model`. Join: a meal has a main and two sides. Carries the per-dish scale override, `servingsCooked`, `plannedLeftoverServings`. |
| `Kitchen/Models/Planning/MealAttendance.swift` | `@Model`. Join: WHO is eating and how much. Portions live on the edge. |
| `Kitchen/Models/Planning/AcknowledgedWarning.swift` | `@Model`. "Yes I know, she's having the spinach plain" — a row, not a `[String]`. |

### `Kitchen/Models/Inventory/`

| Path | Owns |
|---|---|
| `Kitchen/Models/Inventory/StockLot.swift` | `@Model`. One physical lot. `remaining` is a documented CACHE. |
| `Kitchen/Models/Inventory/InventoryTransaction.swift` | `@Model`. Append-only truth. Signed delta, optional (`pendingBridge`) delta, kind, provenance. |

### `Kitchen/Models/Shopping/`

| Path | Owns |
|---|---|
| `Kitchen/Models/Shopping/ShoppingList.swift` | `@Model`. A persisted, frozen trip. |
| `Kitchen/Models/Shopping/ShoppingListLine.swift` | `@Model`. One line per `FoodItem` per list. |
| `Kitchen/Models/Shopping/ShoppingListLineSubtotal.swift` | `@Model`. One (role, dimension) subtotal row. N per line. |
| `Kitchen/Models/Shopping/ShoppingListSource.swift` | `@Model`. "Recipe asked for X" — snapshots plus the live meal edge. |

### `Kitchen/Models/Transfer/`

| Path | Owns |
|---|---|
| `Kitchen/Models/Transfer/KitchenUTType.swift` | The two custom `UTType`s, matching `Info.plist`'s exported type declarations. |
| `Kitchen/Models/Transfer/RecipeTransfer.swift` | `Codable + Transferable` drag payload: an id and a title, plus `ProxyRepresentation(exporting: \.title)`. Never a `@Model` — a `@Model` class is neither reliably `Codable` nor `Sendable`. |
| `Kitchen/Models/Transfer/PlannedMealTransfer.swift` | Same shape for dragging a planned meal between calendar cells. |

### `Kitchen/Services/` — pure `enum` namespaces (no SwiftData, no SwiftUI, unit-testable with no `ModelContainer`)

| Path | Owns |
|---|---|
| `Kitchen/Services/RecipeGraph.swift` | `flatten(recipe:scale:…)`. Component walk, sub-recipe expansion, dimensionally-sound child scale, by-value cycle guard, depth cap. |
| `Kitchen/Services/MealScaling.swift` | `scaling(for:)` → portions, exact `Rational` scale, batch snapping, `[ScalingNote]`, `scaleDescription`. |
| `Kitchen/Services/ShoppingListBuilder.swift` | The algorithm in §4. Takes fetched values, returns a `Draft`. No fetches, no mutation. |
| `Kitchen/Services/PDFPaginator.swift` | Measured section heights → page assignment, packing whole sections so nothing is cut mid-line. |
| `Kitchen/Services/QuantityTokenizer.swift` | `"1 1/2 cups, divided"` → `(Rational, KitchenUnit, note)`. Vulgar glyphs, mixed numbers, ranges, `1 (14.5 oz) can`, `1/4 cup plus 2 tbsp`. |
| `Kitchen/Services/RecipeTextParser.swift` | A pasted block → a `ParsedRecipe` value tree. Group headers, ingredient-vs-prose, the leading-prep-adjective rule. Nothing touches the store. |
| `Kitchen/Services/StepTextParser.swift` | `"Sear the steak (7 to 8 min). Heat a heavy skillet…"` → title, body, min/max minutes, oven temp, internal temp. |
| `Kitchen/Services/MealPlanStats.swift` | Coverage, repeat detection, never-cooked detection — the numbers behind the week brief. |
| `Kitchen/Services/WeekBriefBuilder.swift` | Assembles the Plan tab's landing summary from plan + diet + inventory. |

### `Kitchen/Services/` — `@Observable` classes, `@State` on the App

| Path | Owns |
|---|---|
| `Kitchen/Services/InventoryLedger.swift` | Levels from the ledger, FIFO lot selection, `apply`, `receive`, `recompute`, `reconcileReport`, `expiringSoon`. Holds its `ModelContainer` so `level(of:)` has a context on the hot path. |
| `Kitchen/Services/FoodItemResolver.swift` | The ONLY place a `FoodItem` is created. `matchKey` + alias lookup, `findOrCreate`, `alias`, and the deterministic `reconcile`. |
| `Kitchen/Services/CookSession.swift` | Active recipe, live scale, completed step ids, concurrent timers, the measured elapsed clock. |
| `Kitchen/Services/CookingService.swift` | The cook-finish path: write the `CookLogEntry`, deplete inventory, set the meal `.cooked`, update the declared caches. |
| `Kitchen/Services/MealPlanService.swift` | Range queries, `copyWeek`, `move`, `duplicate`, `makeLeftovers`, attendance defaults application. |
| `Kitchen/Services/DietGuard.swift` | Warnings with severity and a component `path`. |
| `Kitchen/Services/ShoppingListStore.swift` | Materialize a `Draft` into rows, preserve check-state across a regenerate, and diff. |
| `Kitchen/Services/ImportCoordinator.swift` | The pending `ParsedRecipe` awaiting review. Nothing is inserted until he confirms. |
| `Kitchen/Services/RecipeImportService.swift` | `PDFKit` text extraction, `.onOpenURL` document handling, hand-off to the parser. |
| `Kitchen/Services/ExportCoordinator.swift` | Render progress, the last PDF `URL` for `ShareLink`, temp-dir sweeping on launch. |
| `Kitchen/Services/PDFExportService.swift` | `render(job:)` → a vector PDF `URL`. The `CGContext(consumer:mediaBox:)` + `ImageRenderer.render` closure. |
| `Kitchen/Services/AppPreferences.swift` | `init(defaults:)`. Unit system, plan scope, last build options, default diner count. Deliberately not synced. |
| `Kitchen/Services/KitchenSeed.swift` | Sections, locations, ~150 common `FoodItem`s with bridges, and the fixture recipe — all `SeedRecord`-gated. |
| `Kitchen/Services/KitchenMaintenance.swift` | `recomputeCookStats`, `rebuildLotCaches`, `findDuplicateFoodItems`. Wired to remote-change notifications, not only to a Settings button. |

### `Kitchen/Views/Root/`

| Path | Owns |
|---|---|
| `Kitchen/Views/Root/StoreFailureBanner.swift` | The `\.storeUnavailable` banner: "running on a temporary store, your data on disk is untouched". |

### `Kitchen/Views/Recipes/`

| Path | Owns |
|---|---|
| `Kitchen/Views/Recipes/RecipeLibraryView.swift` | Search, sort, filter chips, section index. |
| `Kitchen/Views/Recipes/RecipeCardRow.swift` | Photo, total time, last cooked, "3 groups". |
| `Kitchen/Views/Recipes/RecipeFilterSheet.swift` | Tag / course / time / never-cooked. |
| `Kitchen/Views/Recipes/RecipeDetailView.swift` | Hero, the servings stepper that live-rescales, grouped ingredients, the flat method, notes, pinned Cook. |
| `Kitchen/Views/Recipes/ComponentSectionView.swift` | One ingredient group. Renders no header when the recipe has a single unnamed group. |
| `Kitchen/Views/Recipes/IngredientLineRow.swift` | Live-scaled quantity, preparation, the unmeasured note. |
| `Kitchen/Views/Recipes/RecipeMethodView.swift` | The flat 1–8 step list with per-step group pills. |
| `Kitchen/Views/Recipes/RecipeNotesSection.swift` | The note bullets, make-ahead called out. |
| `Kitchen/Views/Recipes/RecipeUsageSection.swift` | "Used in 6 dishes" — `usedAsComponentIn` + `usedAsIngredientIn`. |
| `Kitchen/Views/Recipes/RecipeEditorView.swift` | Drag-reorder groups, lines and steps. Owns the exactly-one-parent validation. |
| `Kitchen/Views/Recipes/ComponentEditorSection.swift` | Group title and its lines. |
| `Kitchen/Views/Recipes/IngredientLineEditor.swift` | The fraction keypad row, the unit picker scoped to dimension, catalogue autocomplete, the bare-`oz` dimension confirm. |
| `Kitchen/Views/Recipes/StepEditorRow.swift` | Title, body, min/max minutes, temperatures, optional group tag. |
| `Kitchen/Views/Recipes/PasteImportView.swift` | Paste or open a document. |
| `Kitchen/Views/Recipes/ParseReviewView.swift` | Per-line confidence, low-confidence lines pre-flagged, tap to fix. Nothing is saved until he confirms. |
| `Kitchen/Views/Recipes/IngredientInboxView.swift` | Unresolved lines across all recipes, with "match to…". |
| `Kitchen/Views/Recipes/CookLogView.swift` | This recipe's history and measured-vs-claimed time. |

### `Kitchen/Views/Cook/`

| Path | Owns |
|---|---|
| `Kitchen/Views/Cook/CookModeView.swift` | The `fullScreenCover`. `isIdleTimerDisabled`, 20pt minimum body, 60pt tap targets. |
| `Kitchen/Views/Cook/MiseEnPlaceView.swift` | Every group's ingredients at the chosen scale, make-ahead called out, before you start. |
| `Kitchen/Views/Cook/CookStepList.swift` | The flat method; the whole row is the checkbox; completed steps dim but stay. |
| `Kitchen/Views/Cook/CookIngredientHeader.swift` | Sticky, showing the scaled quantities for the group the current step touches. |
| `Kitchen/Views/Cook/CookTimerBar.swift` | Concurrent timers as chips, with local notifications so a backgrounded app still rings. |
| `Kitchen/Views/Cook/CookFinishSheet.swift` | Measured duration, rating, notes, photo, "fold these changes into the recipe?", and the inventory depletion confirm. |

### `Kitchen/Views/Plan/`

| Path | Owns |
|---|---|
| `Kitchen/Views/Plan/PlanRootView.swift` | Scope switch. On iPhone the landing content is the week brief; the dense grid is iPad-only. |
| `Kitchen/Views/Plan/WeekBriefView.swift` | "14 dinners planned, 3 takeout, Sarah away Thu–Fri, 2 warnings, 1 recipe you have never cooked, 3 things expiring." |
| `Kitchen/Views/Plan/MonthCalendarView.swift` | Month grid with `.scrollTargetBehavior(.viewAligned)` paging. |
| `Kitchen/Views/Plan/MonthDayCell.swift` | Slot dots, eater initial chips, leftovers/takeout glyphs, warning triangle. A `.dropDestination`. |
| `Kitchen/Views/Plan/WeekGridView.swift` | **iPad only.** 7 columns × slot rows of drop targets. |
| `Kitchen/Views/Plan/DayPlanView.swift` | The day's meals, prep tasks, what is thawing. |
| `Kitchen/Views/Plan/PlannedMealEditorSheet.swift` | Kind picker, recipe picker, the attendance grid, guests, leftovers source, scale override, diet banner. |
| `Kitchen/Views/Plan/AttendanceGrid.swift` | One chip per active member. Single tap cycles attending → away → maybe → leftoversOnly; long-press opens a portion stepper and a plate note. Four taps for a four-person dinner, no sheet. |
| `Kitchen/Views/Plan/DietWarningBanner.swift` | Severity-ordered warnings with the component path, dismissible per warning. |
| `Kitchen/Views/Plan/DuplicateWeekSheet.swift` | "Same as last week" — the most-used action. |

### `Kitchen/Views/Shop/`

| Path | Owns |
|---|---|
| `Kitchen/Views/Shop/ShoppingListsView.swift` | History, archive. |
| `Kitchen/Views/Shop/GenerateShoppingListSheet.swift` | Range presets, slot toggles, option switches, live preview counts from `preview()`. |
| `Kitchen/Views/Shop/ShoppingListDetailView.swift` | Sectioned by aisle, check off, "Needs attention" pinned at top, "Already have" and "Staples (not checked)" as collapsed footers. |
| `Kitchen/Views/Shop/ShoppingListLineRow.swift` | N subtotals, have in muted ink beside toBuy in full ink, flag badges. |
| `Kitchen/Views/Shop/ShoppingLineDetailSheet.swift` | Provenance rows, the bridge-resolution affordance, destination location. |
| `Kitchen/Views/Shop/ReceiveIntoInventorySheet.swift` | Checked lines → lots, posting the PURCHASE quantity. |
| `Kitchen/Views/Shop/RegenerateDiffSheet.swift` | "3 new, 1 no longer needed, 2 changed quantity." |

### `Kitchen/Views/Pantry/`

| Path | Owns |
|---|---|
| `Kitchen/Views/Pantry/InventoryHomeView.swift` | Grouped by location, with running-low and expiring-soon banners. |
| `Kitchen/Views/Pantry/LocationDetailView.swift` | One location's lots. |
| `Kitchen/Views/Pantry/FoodItemDetailView.swift` | Lots, the transaction ledger as a timeline, aliases, bridges, purchase pack, section, tracking mode, "used in N recipes". |
| `Kitchen/Views/Pantry/QuickAddStockView.swift` | Name → quantity → location in three taps. |
| `Kitchen/Views/Pantry/InventoryCountView.swift` | Walk a location and correct everything; writes `.inventoryCount` transactions. |
| `Kitchen/Views/Pantry/UnresolvedDepletionsView.swift` | The `.pendingBridge` inbox. |
| `Kitchen/Views/Pantry/ExpiringSoonView.swift` | What is about to go bad. |

### `Kitchen/Views/Settings/`

| Path | Owns |
|---|---|
| `Kitchen/Views/Settings/SettingsView.swift` | The sheet's root list. |
| `Kitchen/Views/Settings/HouseholdView.swift` | `Eater` CRUD, colours, portion factors, active toggle. |
| `Kitchen/Views/Settings/AttendanceDefaultsView.swift` | The recurring attendance rules. |
| `Kitchen/Views/Settings/RestrictionEditorView.swift` | Kind, severity, keyword rows, explicit item links. |
| `Kitchen/Views/Settings/StoreLayoutView.swift` | Stores and drag-to-reorder sections. |
| `Kitchen/Views/Settings/StorageLocationsView.swift` | Locations and shelf lives. |
| `Kitchen/Views/Settings/FoodItemCatalogView.swift` | Densities, count equivalences, sections, purchase packs, tracking mode, par levels. |
| `Kitchen/Views/Settings/MergeFoodItemsView.swift` | The de-dup reconciliation and the `MergeRecord` log. |
| `Kitchen/Views/Settings/ReconcileView.swift` | Ledger-vs-cache divergence, surfaced not hidden. |
| `Kitchen/Views/Settings/UnitPreferenceView.swift` | US / metric display. |
| `Kitchen/Views/Settings/ExportView.swift` | Export jobs and `ShareLink`. |
| `Kitchen/Views/Settings/StoreHealthView.swift` | Row counts, the store-failure detail, the schema version. |

### `Kitchen/Views/Export/` — print views. **No `List`, no `ScrollView`, no `LazyVStack` anywhere inside these.**

| Path | Owns |
|---|---|
| `Kitchen/Views/Export/PDFPreviewView.swift` | `PDFView` in a `UIViewRepresentable`, reusing `MMPDFReader`'s shape including the `@unchecked Sendable` box around the non-`Sendable` `PDFDocument`. |
| `Kitchen/Views/Export/RecipePrintPage.swift` | Portrait 612×792. Ingredients left column, flat method right, notes footer. |
| `Kitchen/Views/Export/ShoppingListPrintPage.swift` | Portrait, two columns by section, stroked checkbox glyphs, right-aligned `.monospacedDigit()` quantities, superscript source markers. |
| `Kitchen/Views/Export/MealPlanWeekPrintPage.swift` | Landscape 792×612 week grid with the member-initial chip legend across the footer. |
| `Kitchen/Views/Export/MealPlanHeadCountPrintPage.swift` | Head count per day per meal — its own page. |
| `Kitchen/Views/Export/PrepAheadPrintPage.swift` | Every `.prep` entry and every make-ahead note in the range, in date order. |
| `Kitchen/Views/Export/ShoppingSourcesPrintBlock.swift` | The closing "Meals this list covers" block the superscripts key to. |
| `Kitchen/Views/Export/PrintPrimitives.swift` | The page frame, hairline rule, checkbox glyph, chip, and the fixed print type scale. |

### `Kitchen/Views/Components/`

| Path | Owns |
|---|---|
| `Kitchen/Views/Components/DesignComponents.swift` | Card, section header, empty-state card. |
| `Kitchen/Views/Components/QuantityField.swift` | Amount + unit, with the dimension-scoped picker. |
| `Kitchen/Views/Components/FractionKeypad.swift` | ½ ⅓ ¼ ⅔ ¾ ⅛ as one tap. |
| `Kitchen/Views/Components/EaterChip.swift` | Initials in the member's colour. Shared by the grid, the calendar cell and the PDF legend. |
| `Kitchen/Views/Components/StockPill.swift` | "have 1 lb" / "low" / "expires Tue". |
| `Kitchen/Views/Components/FlagBadge.swift` | One shopping-line flag. |

### `Kitchen/Utilities/`

| Path | Owns |
|---|---|
| `Kitchen/Utilities/Theme.swift` | Colour tokens, `serif(_:weight:)`, radii, and the `\.storeUnavailable` `EnvironmentKey`. Warmer than CFAL3's parchment — kitchen, not daybook. |
| `Kitchen/Utilities/KitchenFormatting.swift` | `Rational` → "1 1/3", unit pluralization, duration ranges ("7–8 min"), "About 35 minutes". |
| `Kitchen/Utilities/AdaptiveLayout.swift` | The one place `horizontalSizeClass` decides brief-vs-grid. |

### `Kitchen/Resources/`

| Path | Owns |
|---|---|
| `Kitchen/Resources/Assets.xcassets` | App icon, accent colour. |
| `Kitchen/Resources/RecipePhotos/` | Seed imagery only. Every user photo is `.externalStorage` on the model, never a filename — filenames do not sync, `.externalStorage` becomes a `CKAsset` and does. |

### Tests

| Path | Owns |
|---|---|
| `KitchenTests/RationalTests.swift` | Reduction, overflow-reporting on all four operators, `approximating`, ceiling. |
| `KitchenTests/UnitCatalogTests.swift` | The full US volume ladder round-trip, and `1 cup == 240 mL` exactly. |
| `KitchenTests/QuantityMathTests.swift` | `2 tbsp + 1/4 cup == 6 tbsp`. Count-noun partitioning. `CountEquivalence` collapse. `displayUnit` including the `18 tsp → 6 tbsp` case that must not render as `3 fl oz`. |
| `KitchenTests/MealScalingTests.swift` | 12-crostini/4-serving yields `scale = portions/4`. Batch snapping. No-attendance fallback. |
| `KitchenTests/RecipeGraphTests.swift` | By-value cycle guard: one sub-recipe used in two sibling branches contributes twice. Dimensional sub-recipe scale. Refusal when the yield is absent. |
| `KitchenTests/ShoppingListBuilderTests.swift` | The fixture's butter (2 tbsp) and **kosher salt (1 1/4 tsp, through the staple-diversion path)**. The 240 mL carton leaving no residue. `needsBridge`. Negative-have clamping. `.cooked` exclusion. Leftovers contributing nothing. |
| `KitchenTests/InventoryLedgerTests.swift` | FIFO order, orphaned-transaction accounting, `pendingBridge` writing, `reconcileReport` attribution. |
| `KitchenTests/FoodItemResolverTests.swift` | Alias lookup, deterministic survivor, referrer repointing. |
| `KitchenTests/RecipeTextParserTests.swift` | The fixture text, asserting the same twelve requirements the Python test asserts. |
| `KitchenUITests/…` | Launch, create a recipe, plan a meal, generate a list, export a PDF. Addressed by `accessibilityIdentifier`. |

---

## 2. The SwiftData models

**This section is copied verbatim into the codebase.** Every class obeys §0.2. 30 models, matching `KitchenSchemaV1.models` exactly.

### 2.1 Delete rules and inverse placement, in one table

Each edge appears once. The macro lives on the side shown in bold; the other side is a
bare optional with a comment pointing here.

| Edge | Macro side | Rule | Why |
|---|---|---|---|
| Recipe → **components** → lines | Recipe / RecipeComponent | `.cascade` | A recipe's ingredient groups have no life of their own. |
| Recipe → **steps** | Recipe | `.cascade` | The method is the recipe's. Steps are flat and recipe-owned (decision 1). |
| Recipe → **notes**, **photos**, **cookLog** | Recipe | `.cascade` | Same. |
| Recipe → **usedAsComponentIn** (`RecipeComponent.sourceRecipe`) | Recipe | `.nullify` | Deleting the chimichurri must not gut the six dishes that used it. What is left is a titled tombstone the UI offers to relink. |
| Recipe → **usedAsIngredientIn** (`IngredientLine.subRecipe`) | Recipe | `.nullify` | Same, for a measured reference. `rawText` still cooks. |
| Recipe → **mirrorFoodItems** (`FoodItem.producedByRecipe`) | Recipe | `.nullify` | A make-ahead batch stocked as inventory outlives a recipe edit. |
| Recipe ← **plannedMeals** (`MealRecipe.recipe`) | Recipe | `.nullify` | Deleting a recipe must not erase what he ate. `recipeTitleSnapshot` carries it. |
| RecipeComponent → **ingredientLines** | RecipeComponent | `.cascade` | |
| RecipeComponent ← **taggedSteps** (`RecipeStep.component`) | RecipeComponent | `.nullify` | A step survives the regrouping of ingredients. |
| RecipeTag ↔ **recipes** | RecipeTag | `.nullify` | Genuine many-to-many; macro on the tag so "rename weeknight to fast" is one write. |
| FoodItem → **aliases**, **countEquivalences** | FoodItem | `.cascade` | A bridge for a deleted item is nothing. |
| FoodItem → **lots**, **transactions** | FoodItem | **`.nullify`** | **Decision 4.** A cascade means one stray `.onDelete` torches the ledger. `foodItemNameSnapshot` on both keeps an orphan readable, and `InventoryLedger.delete(item:)` refuses any item with history and offers "merge into…" instead — but the *schema* is what guarantees nothing is destroyed. |
| FoodItem ← **ingredientLines**, **shoppingLines** | FoodItem | `.nullify` | Deleting an item must never eat recipe text or a printed list. |
| FoodItem ← **restrictions** (`DietaryRestriction.foodItems`) | DietaryRestriction | `.nullify` | |
| StockLot → **transactions** | StockLot | `.nullify` | **Decision 5.** The lot is a cache home, not the parent. An orphan still contributes to `level(of:)` through the item, in an "unassigned lot" bucket, so divergence stays attributable. |
| StorageLocation ← **lots**, **foodItems**, **shoppingLines** | StorageLocation | `.nullify` | |
| Store → **sections** | Store | `.cascade` | |
| StoreSection ← **foodItems** | StoreSection | `.nullify` | |
| Eater → **attendanceDefaults** | Eater | `.cascade` | A rule about a person is meaningless without them. |
| Eater ← **attendance** | Eater | `.nullify` | History survives the person. `eaterNameSnapshot`. |
| Eater ↔ **restrictions** | DietaryRestriction | `.nullify` | |
| DietaryRestriction → **keywords** | DietaryRestriction | `.cascade` | |
| PlannedMeal → **mealRecipes**, **attendance** | PlannedMeal | `.cascade` | Meaningless without their meal. |
| PlannedMeal → **leftoverMeals** (`PlannedMeal.leftoversFrom`) | PlannedMeal | `.nullify` | Tuesday's leftovers become an ordinary meal, not a deletion. |
| PlannedMeal ← **shoppingSources**, **cookLog**, **inventoryTransactions** | PlannedMeal | `.nullify` | Deleting a meal leaves the already-bought line and the already-cooked record alone. |
| MealAttendance → **acknowledgedWarnings** | MealAttendance | `.cascade` | |
| ShoppingList → **lines** → **subtotals**, **sources** | each parent | `.cascade` | A list is one document. |
| ShoppingListSource → **plannedMeal** | PlannedMeal | `.nullify` | See above. |

**The delimited-`String` exceptions, and the rule that admits them.** Rule 6 forbids a
stored *array* attribute for data two devices might both append to. A delimited `String`
is still a single last-writer-wins field, so it is admissible **only** where the value is
written exactly once, by one writer, and never appended to afterwards. Every use is
listed here; anything not on this list must be rows.

| Field | Written by | Why a blob is safe |
|---|---|---|
| `FoodItem.aliasBlob` | `FoodItemResolver.reindex(_:)` | A **derived index** over the `FoodItemAlias` rows. The rows are the truth and both survive a merge; this exists only so alias lookup is a `#Predicate` rather than a full-catalogue fetch-and-scan on every line resolution. Rebuilt, never appended. |
| `ShoppingListLine.flagsBlob` | the generator, once | A generated line is a frozen historical record. `flagsBlob.contains("\|needsBridge\|")` is also predicate-queryable, which a `[String]` is not. |
| `ShoppingList.slotsBlob`, `ShoppingList.expandedLineIDBlob` | the generator, once | The frozen build options. Note there is deliberately **no** `includedMealIDs` blob: the live `ShoppingListSource.plannedMeal` edges *are* the included set, and they are queryable and re-pointable. |
| `MergeRecord.absorbedIDBlob`, `absorbedNameBlob` | `FoodItemResolver.merge` | An audit row, written once at the merge. |

Everything else that a design might have made an array is rows: `FoodItemAlias`,
`CountEquivalence`, `DietaryKeyword`, `RecipeNote`, `AcknowledgedWarning`,
`ShoppingListLineSubtotal`, and `DietaryRestriction` in place of an `avoidedItems`
array.

### 2.2 `Kitchen/Models/Recipes/Recipe.swift`

```swift
import Foundation
import SwiftData

@Model
final class Recipe {
    var id: UUID = UUID()

    var title: String = ""
    var subtitle: String = ""
    /// Stored, not computed, because a `#Predicate` cannot call a computed property
    /// and search is the most-used thing in the library.
    var normalizedTitle: String = ""
    var summary: String = ""

    // MARK: Yields — TWO independent numbers, and conflating them is the bug
    //
    // The fixture says "Makes: 12 crostini (serves 4)". Twelve is a produced-unit
    // count; four is a serving count; neither is derivable from the other. A single
    // yield field makes meal-plan scale = portions / 12, so planning this recipe for
    // four people shops for one third of every ingredient — and no zero-yield warning
    // fires, because the yield is not zero.
    //
    // `servings` is the ONLY value scaling divides by. `yieldQuantity` is display,
    // and it scales alongside so six eaters reads "18 crostini".
    var servingsNumerator: Int = 4
    var servingsDenominator: Int = 1
    var hasYieldQuantity: Bool = false
    var yieldQuantityNumerator: Int = 0
    var yieldQuantityDenominator: Int = 1
    var yieldUnitLabel: String = ""
    /// Verbatim, e.g. "12 crostini (serves 4)". Kept so a reparse is always possible.
    var yieldText: String = ""

    // MARK: Times
    //
    // Optional, not `0`. The fixture's steps 7 and 8 have no duration at all, and
    // changing `Int = 0` to `Int?` later is a type-change migration stage rather than
    // an additive field.
    var activeMinutes: Int? = nil
    var totalMinutes: Int? = nil
    /// Both fixture times are prefixed "About", so the UI must not imply precision.
    var timesAreApproximate: Bool = true

    // MARK: Scaling behaviour
    /// `BatchGranularity`: continuous / wholeBatches / halfBatches. You cannot bake
    /// 1.4 loaves, and that is a property of the recipe, not of any one line.
    var batchGranularityRaw: String = BatchGranularity.continuous.rawValue

    var courseRaw: String = CourseKind.main.rawValue
    var difficultyRaw: String = Difficulty.medium.rawValue
    var cuisine: String = ""

    var sourceName: String = ""
    var sourceURLString: String = ""
    /// The paste or PDF text this came from, kept forever. Over years the parser
    /// improves, and a re-parse of 400 stored raw documents is a feature. It is also
    /// the only honest answer when a quantity looks wrong on a shopping list.
    var importedRawText: String = ""

    /// Pulled out of the note rows at import so the planner can surface it without
    /// re-reading prose. The note row it came from is NOT deleted.
    var makeAheadNote: String = ""

    var isFavorite: Bool = false
    var isArchived: Bool = false
    var isReusableComponent: Bool = false

    var createdAt: Date = .now
    var updatedAt: Date = .now

    // MARK: Declared caches — single writer, repairable, never the truth
    //
    // `SortDescriptor` cannot sort a `@Query` by an aggregate over a child
    // relationship, and "what do I cook most" is the library's most-used sort, so
    // these are denormalized. Both are written in exactly ONE place —
    // `CookingService.finish(...)` — and `KitchenMaintenance.recomputeCookStats`
    // rebuilds them from `cookLog`, which is the truth.
    //
    // `cookCount` is NEVER incremented as a source of truth: under CloudKit's
    // field-level last-writer-wins, two cooks logged on two devices permanently lose
    // one increment. The rows both survive; the counter does not. recomputeCookStats
    // runs on remote-change notifications, not only from a Settings screen, because
    // a repair that nobody triggers is not a repair.
    var cookCount: Int = 0
    var lastCookedAt: Date? = nil

    // MARK: Relationships
    //
    // Recipe has FOUR edges into the recipe graph and every one names its inverse.
    // Left to inference SwiftData pairs them arbitrarily and the graph is wrong at
    // runtime, not at compile time.

    /// Ingredient GROUPS. They own lines, never steps. See `RecipeStep`.
    @Relationship(deleteRule: .cascade, inverse: \RecipeComponent.recipe)
    var components: [RecipeComponent]? = []

    /// The method, FLAT and ordered across the whole dish.
    ///
    /// This is the single most-rebroken decision in the project. The fixture groups
    /// ingredients three ways but has ONE numbered 1-8 instruction list that moves
    /// freely between the groups: season the steak (1), toast the baguette (2), sear
    /// (3), wilt the spinach (5), assemble both (8). With steps reachable only
    /// through a component, order sorts within a component and components sort among
    /// themselves, so the only representable method is all-steak-then-all-crostini.
    /// The document's actual method cannot be stored. A component is NOT a
    /// self-contained mini-recipe.
    @Relationship(deleteRule: .cascade, inverse: \RecipeStep.recipe)
    var steps: [RecipeStep]? = []

    /// An ordered list of rows, not a String. The fixture's Notes section is four
    /// distinct ideas — a make-ahead instruction, a key-step warning, a variation, a
    /// timing tip. Flattening them into one paragraph at import is lossy and cannot
    /// be reversed.
    @Relationship(deleteRule: .cascade, inverse: \RecipeNote.recipe)
    var notes: [RecipeNote]? = []

    @Relationship(deleteRule: .cascade, inverse: \RecipePhoto.recipe)
    var photos: [RecipePhoto]? = []

    @Relationship(deleteRule: .cascade, inverse: \CookLogEntry.recipe)
    var cookLog: [CookLogEntry]? = []

    @Relationship(deleteRule: .nullify, inverse: \RecipeTag.recipes)
    var tags: [RecipeTag]? = []

    /// "Where do I use this chimichurri" as a traversal rather than a full-store scan.
    @Relationship(deleteRule: .nullify, inverse: \RecipeComponent.sourceRecipe)
    var usedAsComponentIn: [RecipeComponent]? = []

    @Relationship(deleteRule: .nullify, inverse: \IngredientLine.subRecipe)
    var usedAsIngredientIn: [IngredientLine]? = []

    /// The mirror catalogue rows this recipe produces, so a batch of make-ahead stock
    /// can be stocked as inventory and drawn down like anything else.
    @Relationship(deleteRule: .nullify, inverse: \FoodItem.producedByRecipe)
    var mirrorFoodItems: [FoodItem]? = []

    @Relationship(deleteRule: .nullify, inverse: \MealRecipe.recipe)
    var plannedMeals: [MealRecipe]? = []

    init(
        id: UUID = UUID(),
        title: String = "",
        subtitle: String = "",
        normalizedTitle: String = "",
        summary: String = "",
        servingsNumerator: Int = 4,
        servingsDenominator: Int = 1,
        hasYieldQuantity: Bool = false,
        yieldQuantityNumerator: Int = 0,
        yieldQuantityDenominator: Int = 1,
        yieldUnitLabel: String = "",
        yieldText: String = "",
        activeMinutes: Int? = nil,
        totalMinutes: Int? = nil,
        timesAreApproximate: Bool = true,
        batchGranularityRaw: String = BatchGranularity.continuous.rawValue,
        courseRaw: String = CourseKind.main.rawValue,
        difficultyRaw: String = Difficulty.medium.rawValue,
        cuisine: String = "",
        sourceName: String = "",
        sourceURLString: String = "",
        importedRawText: String = "",
        makeAheadNote: String = "",
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isReusableComponent: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        cookCount: Int = 0,
        lastCookedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.normalizedTitle = normalizedTitle
        self.summary = summary
        self.servingsNumerator = servingsNumerator
        self.servingsDenominator = servingsDenominator
        self.hasYieldQuantity = hasYieldQuantity
        self.yieldQuantityNumerator = yieldQuantityNumerator
        self.yieldQuantityDenominator = yieldQuantityDenominator
        self.yieldUnitLabel = yieldUnitLabel
        self.yieldText = yieldText
        self.activeMinutes = activeMinutes
        self.totalMinutes = totalMinutes
        self.timesAreApproximate = timesAreApproximate
        self.batchGranularityRaw = batchGranularityRaw
        self.courseRaw = courseRaw
        self.difficultyRaw = difficultyRaw
        self.cuisine = cuisine
        self.sourceName = sourceName
        self.sourceURLString = sourceURLString
        self.importedRawText = importedRawText
        self.makeAheadNote = makeAheadNote
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.isReusableComponent = isReusableComponent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cookCount = cookCount
        self.lastCookedAt = lastCookedAt
    }
}

extension Recipe {
    /// SwiftData does not preserve to-many array order, and under CloudKit the order
    /// read back is arbitrary. Ingredients or steps in the wrong order is the worst
    /// possible bug in a cooking app, so order is DATA (`sortIndex`) on every ordered
    /// child, and every collection is read through a sorted accessor. Never iterate
    /// the relationship directly.
    var orderedComponents: [RecipeComponent] {
        (components ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var orderedSteps: [RecipeStep] {
        (steps ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var orderedNotes: [RecipeNote] {
        (notes ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var orderedPhotos: [RecipePhoto] {
        (photos ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var heroPhoto: RecipePhoto? {
        orderedPhotos.first(where: { $0.isHero }) ?? orderedPhotos.first
    }

    var orderedCookLog: [CookLogEntry] {
        (cookLog ?? []).sorted { $0.cookedAt > $1.cookedAt }
    }

    /// The scaling divisor. Guaranteed positive: a recipe whose servings were never
    /// set must not make `scale` explode or vanish.
    var servings: Rational {
        let r = Rational(servingsNumerator, max(1, servingsDenominator))
        return r > Rational(0) ? r : Rational(1)
    }

    var yieldQuantity: Rational? {
        guard hasYieldQuantity else { return nil }
        return Rational(yieldQuantityNumerator, max(1, yieldQuantityDenominator))
    }

    var batchGranularity: BatchGranularity {
        BatchGranularity(rawValue: batchGranularityRaw) ?? .continuous
    }

    var course: CourseKind { CourseKind(rawValue: courseRaw) ?? .main }
    var difficulty: Difficulty { Difficulty(rawValue: difficultyRaw) ?? .medium }

    /// True when the recipe has exactly one unnamed ingredient group, which the UI
    /// renders with no header at all so a three-ingredient vinaigrette never shows
    /// the word "group".
    var hasSingleUnnamedComponent: Bool {
        let c = orderedComponents
        return c.count == 1 && c[0].title.isEmpty
    }

    /// Averaged over the log rows. There is deliberately no `ratingSum` field: a
    /// stored sum is a counter, and a counter loses a write under last-writer-wins.
    var averageRating: Double? {
        let ratings = orderedCookLog.compactMap(\.rating)
        guard !ratings.isEmpty else { return nil }
        return Double(ratings.reduce(0, +)) / Double(ratings.count)
    }

    /// The display yield at a given scale: 12 crostini x 3/2 reads "18 crostini".
    func scaledYieldLabel(at scale: Rational) -> String? {
        guard let q = yieldQuantity, !yieldUnitLabel.isEmpty else { return nil }
        return "\((q * scale).mixedDescription) \(yieldUnitLabel)"
    }
}
```

### 2.3 `Kitchen/Models/Recipes/RecipeComponent.swift`

```swift
import Foundation
import SwiftData

/// An ingredient GROUP — "Crostini and steak", "Creamed horseradish spinach",
/// "To finish". It owns ordered ingredient lines and NOTHING ELSE.
///
/// It deliberately does not own steps. See the long comment on `Recipe.steps`.
@Model
final class RecipeComponent {
    var id: UUID = UUID()
    var sortIndex: Int = 0
    /// "" for a single-group recipe, which the UI then renders with no header.
    var title: String = ""
    var note: String = ""
    var kindRaw: String = ComponentKind.other.rawValue
    var isOptional: Bool = false

    /// Set when this group IS a reusable recipe — "half a batch of the chimichurri".
    /// Its lines are read through here rather than duplicated.
    ///
    /// `.nullify` from the Recipe side: deleting the chimichurri must not delete the
    /// six dishes that used it. What is left is a component whose `title` is intact
    /// and whose `sourceRecipe` is nil — a tombstone the UI renders as
    /// "Chimichurri — recipe deleted, tap to relink".
    var sourceRecipe: Recipe? = nil
    var sourceScaleNumerator: Int = 1
    var sourceScaleDenominator: Int = 1

    var makeAheadNote: String = ""

    @Relationship(deleteRule: .cascade, inverse: \IngredientLine.component)
    var ingredientLines: [IngredientLine]? = []

    /// Steps that MENTION this group. The step's owner is always its `Recipe`; this
    /// is a tag for the cook-mode sticky header and the per-step group pill, and it
    /// is `.nullify` so regrouping ingredients never deletes a step.
    @Relationship(deleteRule: .nullify, inverse: \RecipeStep.component)
    var taggedSteps: [RecipeStep]? = []

    /// Owner. Macro lives on `Recipe.components`.
    var recipe: Recipe? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        title: String = "",
        note: String = "",
        kindRaw: String = ComponentKind.other.rawValue,
        isOptional: Bool = false,
        sourceRecipe: Recipe? = nil,
        sourceScaleNumerator: Int = 1,
        sourceScaleDenominator: Int = 1,
        makeAheadNote: String = "",
        recipe: Recipe? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.title = title
        self.note = note
        self.kindRaw = kindRaw
        self.isOptional = isOptional
        self.sourceRecipe = sourceRecipe
        self.sourceScaleNumerator = sourceScaleNumerator
        self.sourceScaleDenominator = sourceScaleDenominator
        self.makeAheadNote = makeAheadNote
        self.recipe = recipe
    }
}

extension RecipeComponent {
    var orderedLines: [IngredientLine] {
        (ingredientLines ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var sourceScale: Rational {
        Rational(sourceScaleNumerator, max(1, sourceScaleDenominator))
    }

    var kind: ComponentKind { ComponentKind(rawValue: kindRaw) ?? .other }

    /// A group whose source recipe was deleted. Rendered as a relink prompt rather
    /// than silently contributing nothing to the shopping list.
    var isOrphanedReference: Bool {
        sourceRecipe == nil && ingredientLines?.isEmpty != false && !title.isEmpty
    }
}
```

### 2.4 `Kitchen/Models/Recipes/IngredientLine.swift`

```swift
import Foundation
import SwiftData

@Model
final class IngredientLine {
    var id: UUID = UUID()
    var sortIndex: Int = 0

    // MARK: Quantity — genuinely optional
    //
    // "Pinch flaky salt" has no number. So do "to taste", "for garnish", "as needed".
    // Such a line must reach the shopping list as a PRESENCE item — never as 0,
    // never dropped, and never aggregated into "2 pinches".
    //
    // `hasQuantity == false` means there is no quantity. A nil quantity never enters
    // arithmetic, never suppresses a line, and cannot be confused with a parse
    // failure or with a deliberate zero. Pinch/dash/drizzle/splash are classified
    // `.unmeasured` and land here, NOT as fractional teaspoons — otherwise nutmeg
    // surfaces on a shopping list as "3/16 tsp".
    var hasQuantity: Bool = false
    var amountNumerator: Int = 0
    var amountDenominator: Int = 1
    var unitCode: String = ""
    /// The resolved dimension, RECORDED rather than re-derived at read time.
    ///
    /// Bare "oz" is ambiguous and the fixture uses it as weight three times (16 oz
    /// steak, 10 oz spinach, 4 oz cream cheese). The importer resolves it by
    /// ingredient context ONCE; nothing downstream may guess again. It is also the
    /// graceful degradation path for a unit code written by a future version of the
    /// app that this build does not know.
    var dimensionRaw: String = MeasureDimension.unmeasured.rawValue
    /// False when the importer guessed the dimension and wants a one-tap confirm.
    var dimensionConfirmed: Bool = false
    /// "Pinch", "to taste", "for garnish" — round-trips verbatim.
    var unmeasuredNote: String = ""

    // MARK: Identity and display
    /// What the shopping list and the pantry match on: "shallot", not "shallot, minced".
    var displayName: String = ""
    /// "minced", "drained", "1/2 inch thick", "about 1.25 inches thick".
    ///
    /// Separate from the name so "1 cup onion, diced" and "1/2 cup onion, sliced"
    /// merge into "1 1/2 cups onion" on the list — you buy onions, not diced-ness —
    /// while both cook screens still say diced and sliced. A LENGTH in a recipe
    /// ("1/2 inch thick") is descriptive, not purchasable, and belongs here rather
    /// than in a quantity; there is deliberately no length dimension.
    var preparation: String = ""
    var note: String = ""
    /// The original line, exactly as typed or imported, kept forever.
    ///
    /// Every comma-splitting parser is defeated by the fixture's "grated Parmesan",
    /// where the preparation adjective comes FIRST. This field is why that is
    /// recoverable rather than fatal: the parse is advisory, the raw text is truth,
    /// and the cook always sees it.
    var rawText: String = ""
    /// 0...1 from the parser. Below threshold the review sheet pre-flags the line so
    /// he fixes it at the kitchen table instead of discovering it at the stove.
    var parseConfidence: Double = 1.0

    // MARK: Behaviour
    var isOptional: Bool = false
    var isGarnish: Bool = false
    /// Tap water, ice for the bath. Never shopped.
    var excludeFromShopping: Bool = false
    /// `ScalingRule`: `.linear` or `.fixed`. `.fixed` is how "1 bay leaf" and the oil
    /// for the pan survive a 3x batch without becoming three bay leaves and a
    /// fistful of salt.
    var scalingRuleRaw: String = ScalingRule.linear.rawValue
    /// Buy it, or make it? A default only — the real decision is per shopping trip
    /// and is frozen onto the list so regenerating is reproducible.
    var subRecipePolicyRaw: String = SubRecipePolicy.treatAsItem.rawValue

    // MARK: Links
    /// The catalogue row. nil = unresolved; the line still renders from `rawText` and
    /// appears in the ingredient inbox. A recipe is never blocked on catalogue
    /// cleanliness. Macro lives on `FoodItem.ingredientLines`.
    var foodItem: FoodItem? = nil
    /// One recipe consumed as a measured ingredient of another: "2 cups chicken
    /// stock". Distinct from `RecipeComponent.sourceRecipe`, which means "this part of
    /// the dish IS that recipe". Macro lives on `Recipe.usedAsIngredientIn`.
    var subRecipe: Recipe? = nil
    /// Owner. Macro lives on `RecipeComponent.ingredientLines`.
    var component: RecipeComponent? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        hasQuantity: Bool = false,
        amountNumerator: Int = 0,
        amountDenominator: Int = 1,
        unitCode: String = "",
        dimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        dimensionConfirmed: Bool = false,
        unmeasuredNote: String = "",
        displayName: String = "",
        preparation: String = "",
        note: String = "",
        rawText: String = "",
        parseConfidence: Double = 1.0,
        isOptional: Bool = false,
        isGarnish: Bool = false,
        excludeFromShopping: Bool = false,
        scalingRuleRaw: String = ScalingRule.linear.rawValue,
        subRecipePolicyRaw: String = SubRecipePolicy.treatAsItem.rawValue,
        foodItem: FoodItem? = nil,
        subRecipe: Recipe? = nil,
        component: RecipeComponent? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.hasQuantity = hasQuantity
        self.amountNumerator = amountNumerator
        self.amountDenominator = amountDenominator
        self.unitCode = unitCode
        self.dimensionRaw = dimensionRaw
        self.dimensionConfirmed = dimensionConfirmed
        self.unmeasuredNote = unmeasuredNote
        self.displayName = displayName
        self.preparation = preparation
        self.note = note
        self.rawText = rawText
        self.parseConfidence = parseConfidence
        self.isOptional = isOptional
        self.isGarnish = isGarnish
        self.excludeFromShopping = excludeFromShopping
        self.scalingRuleRaw = scalingRuleRaw
        self.subRecipePolicyRaw = subRecipePolicyRaw
        self.foodItem = foodItem
        self.subRecipe = subRecipe
        self.component = component
    }
}

extension IngredientLine: QuantityCarrying {}

extension IngredientLine {
    var scalingRule: ScalingRule { ScalingRule(rawValue: scalingRuleRaw) ?? .linear }
    var subRecipePolicy: SubRecipePolicy {
        SubRecipePolicy(rawValue: subRecipePolicyRaw) ?? .treatAsItem
    }

    /// What the cook reads. Always prefers the verbatim line when there is one,
    /// because the parse is advisory.
    var cookDisplayText: String {
        rawText.isEmpty ? [quantityDisplay, displayName, preparation]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            : rawText
    }

    var quantityDisplay: String {
        guard let q = quantity else { return unmeasuredNote }
        return q.displayString()
    }
}
```

### 2.5 `Kitchen/Models/Recipes/RecipeStep.swift`

```swift
import Foundation
import SwiftData

/// One step of the method. Flat and RECIPE-ordered.
///
/// `recipe` is always set and is the owner. `component` is an OPTIONAL tag.
///
/// This resolves the "exactly one parent" invariant that a schema cannot enforce: by
/// making the component the only optional side, neither-set and both-set rows cannot
/// appear, so no renderer, exporter or cook screen ever has to guess which parent
/// wins. `RecipeEditorView` additionally refuses to create a step with no recipe.
@Model
final class RecipeStep {
    var id: UUID = UUID()
    var sortIndex: Int = 0

    /// Every step in the fixture is "Title (duration). Body" — "Season the steak
    /// (30 min). Pat the steak dry and season all over with…". Split so cook mode can
    /// show the title big and the body small, and so the duration is a timer rather
    /// than prose.
    var title: String = ""
    /// Verbatim, including any temperatures. Never rewritten, so a later extraction
    /// pass needs no re-import.
    var body: String = ""

    /// Equal when the document gives a single value, both nil when it gives none.
    ///
    /// NOT `Int = 0`. The fixture's step 7 ("Slice the steak") and step 8
    /// ("Assemble") have no duration at all, and step 3's is the RANGE "7 to 8 min".
    /// Zero as the absent sentinel makes those indistinguishable from an instant
    /// step, and changing `Int` to `Int?` later is a type-change migration stage.
    var minMinutes: Int? = nil
    var maxMinutes: Int? = nil

    /// Step 2 has an oven temperature (400F) and step 3 an internal target (125F).
    /// One field cannot hold both, and `0` is a real temperature.
    var ovenTemperatureF: Int? = nil
    var targetInternalTemperatureF: Int? = nil

    /// "Let it sit at room temperature" — nothing to do but wait. Drives the
    /// prep-ahead PDF page and the planner's `.prep` suggestion.
    var isPassiveRest: Bool = false
    var timerLabel: String = ""

    @Attribute(.externalStorage) var imageData: Data? = nil

    /// Owner, always set. Macro lives on `Recipe.steps`.
    var recipe: Recipe? = nil
    /// Optional tag. Macro lives on `RecipeComponent.taggedSteps`.
    var component: RecipeComponent? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        title: String = "",
        body: String = "",
        minMinutes: Int? = nil,
        maxMinutes: Int? = nil,
        ovenTemperatureF: Int? = nil,
        targetInternalTemperatureF: Int? = nil,
        isPassiveRest: Bool = false,
        timerLabel: String = "",
        imageData: Data? = nil,
        recipe: Recipe? = nil,
        component: RecipeComponent? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.title = title
        self.body = body
        self.minMinutes = minMinutes
        self.maxMinutes = maxMinutes
        self.ovenTemperatureF = ovenTemperatureF
        self.targetInternalTemperatureF = targetInternalTemperatureF
        self.isPassiveRest = isPassiveRest
        self.timerLabel = timerLabel
        self.imageData = imageData
        self.recipe = recipe
        self.component = component
    }
}

extension RecipeStep {
    /// "30 min", "7-8 min", or nil.
    var durationText: String? {
        switch (minMinutes, maxMinutes) {
        case let (lo?, hi?) where lo != hi: return "\(lo)-\(hi) min"
        case let (lo?, _): return "\(lo) min"
        case let (nil, hi?): return "\(hi) min"
        default: return nil
        }
    }

    /// Cook mode times the longer end, so a timer never fires early on a range.
    var timerSeconds: Int? {
        guard let m = maxMinutes ?? minMinutes else { return nil }
        return m * 60
    }
}
```

### 2.6 `Kitchen/Models/Recipes/RecipeNote.swift`

```swift
import Foundation
import SwiftData

/// One note bullet.
///
/// A row rather than an element of a `[String]`, and the whole `notes` field rather
/// than a `String`, because the fixture's Notes section is four separate ideas:
/// "the spinach can be made a day ahead" (make-ahead), "squeezing the spinach dry is
/// the key step" (warning), "for a sharper bite, stir in extra horseradish"
/// (variation), "toast the baguette just before serving" (timing). One of them is
/// semantically the make-ahead flag the meal planner wants. Flattening them into a
/// paragraph on import cannot be undone.
@Model
final class RecipeNote {
    var id: UUID = UUID()
    var sortIndex: Int = 0
    var text: String = ""
    /// `NoteKind`: makeAhead / keyStep / variation / timing / general. Classified on
    /// import by a keyword pass; always overridable, never destructive.
    var kindRaw: String = NoteKind.general.rawValue
    /// Owner. Macro lives on `Recipe.notes`.
    var recipe: Recipe? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        text: String = "",
        kindRaw: String = NoteKind.general.rawValue,
        recipe: Recipe? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.text = text
        self.kindRaw = kindRaw
        self.recipe = recipe
    }
}

extension RecipeNote {
    var kind: NoteKind { NoteKind(rawValue: kindRaw) ?? .general }
}
```

### 2.7 `Kitchen/Models/Recipes/RecipeTag.swift`

```swift
import Foundation
import SwiftData

/// A model rather than `[String]` on `Recipe`, so renaming "weeknight" to "fast" is
/// one write instead of two hundred, and so a `#Predicate` can filter by it. A stored
/// `[String]` is an opaque blob that predicates cannot see into.
@Model
final class RecipeTag {
    var id: UUID = UUID()
    var name: String = ""
    var normalizedName: String = ""
    var colorIndex: Int = 0
    var kindRaw: String = "general"   // cuisine | method | occasion | general
    var createdAt: Date = .now

    /// Genuine many-to-many. The macro lives HERE and `Recipe.tags` is bare, because
    /// SwiftData rejects an inverse declared on both sides.
    @Relationship(deleteRule: .nullify, inverse: \Recipe.tags)
    var recipes: [Recipe]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        normalizedName: String = "",
        colorIndex: Int = 0,
        kindRaw: String = "general",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName
        self.colorIndex = colorIndex
        self.kindRaw = kindRaw
        self.createdAt = createdAt
    }
}
```

### 2.8 `Kitchen/Models/Recipes/RecipePhoto.swift`

```swift
import Foundation
import SwiftData

@Model
final class RecipePhoto {
    var id: UUID = UUID()
    var sortIndex: Int = 0
    var caption: String = ""
    var isHero: Bool = false
    var createdAt: Date = .now
    /// `.externalStorage`, never a filename. A filename does not sync; external
    /// storage becomes a `CKAsset` and does. Getting this wrong now means re-homing
    /// every photo later.
    @Attribute(.externalStorage) var imageData: Data? = nil
    /// Owner. Macro lives on `Recipe.photos`.
    var recipe: Recipe? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        caption: String = "",
        isHero: Bool = false,
        createdAt: Date = .now,
        imageData: Data? = nil,
        recipe: Recipe? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.caption = caption
        self.isHero = isHero
        self.createdAt = createdAt
        self.imageData = imageData
        self.recipe = recipe
    }
}
```

### 2.9 `Kitchen/Models/Recipes/CookLogEntry.swift`

```swift
import Foundation
import SwiftData

/// "Things that I do and make." The table that will be most valuable in year three,
/// cheap now and impossible to backfill later.
///
/// It is also the TRUTH behind `Recipe.cookCount` and `Recipe.lastCookedAt`, which are
/// declared caches. Rows survive a CloudKit merge; a counter does not.
@Model
final class CookLogEntry {
    var id: UUID = UUID()
    var cookedAt: Date = .now
    /// yyyymmdd. See `CalendarKey`.
    var dayKey: Int = 0

    /// The scale actually cooked, as exact integers. Never a Double: the whole point
    /// of `Rational` is defeated if the one number that matters is approximated.
    var scaleNumerator: Int = 1
    var scaleDenominator: Int = 1
    var servingsCooked: Int? = nil

    var rating: Int? = nil            // 1...5; nil = unrated, NOT 0
    var notes: String = ""
    /// The next version of the recipe, in his words — "too much horseradish, 1 tbsp
    /// next time". One tap folds it into the recipe. This is how a recipe becomes his.
    var changesMade: String = ""
    /// MEASURED by cook mode, not estimated. After five cooks the app can tell him
    /// the recipe's claimed 35 active minutes is really 55. nil when he cooked without
    /// the timer running.
    var durationSeconds: Int? = nil
    /// Set when the depletion ran, so a re-run cannot double-deplete.
    var didDepleteInventory: Bool = false

    @Attribute(.externalStorage) var photoData: Data? = nil

    /// Macro lives on `Recipe.cookLog`.
    var recipe: Recipe? = nil
    /// Macro lives on `PlannedMeal.cookLog`.
    var plannedMeal: PlannedMeal? = nil

    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.cookLogEntry)
    var depletions: [InventoryTransaction]? = []

    init(
        id: UUID = UUID(),
        cookedAt: Date = .now,
        dayKey: Int = 0,
        scaleNumerator: Int = 1,
        scaleDenominator: Int = 1,
        servingsCooked: Int? = nil,
        rating: Int? = nil,
        notes: String = "",
        changesMade: String = "",
        durationSeconds: Int? = nil,
        didDepleteInventory: Bool = false,
        photoData: Data? = nil,
        recipe: Recipe? = nil,
        plannedMeal: PlannedMeal? = nil
    ) {
        self.id = id
        self.cookedAt = cookedAt
        self.dayKey = dayKey
        self.scaleNumerator = scaleNumerator
        self.scaleDenominator = scaleDenominator
        self.servingsCooked = servingsCooked
        self.rating = rating
        self.notes = notes
        self.changesMade = changesMade
        self.durationSeconds = durationSeconds
        self.didDepleteInventory = didDepleteInventory
        self.photoData = photoData
        self.recipe = recipe
        self.plannedMeal = plannedMeal
    }
}

extension CookLogEntry {
    var scale: Rational { Rational(scaleNumerator, max(1, scaleDenominator)) }
}
```

### 2.10 `Kitchen/Models/Catalog/FoodItem.swift`

```swift
import Foundation
import SwiftData

/// The canonical thing you buy and stock. The only row that means "a thing in my
/// kitchen". Recipes, plans and lists are transactions against this catalogue, never
/// independent copies of ingredient text.
@Model
final class FoodItem {
    var id: UUID = UUID()
    var name: String = ""

    /// Normalized `name`, used for identity matching. Deliberately NOT unique:
    /// CloudKit-backed stores reject `@Attribute(.unique)`, so two devices offline
    /// can and will both create "Shallot". The constraint does not exist;
    /// `FoodItemResolver` plus its deterministic merge pass is what actually keeps
    /// this catalogue single-rowed.
    var matchKey: String = ""

    /// A DERIVED INDEX over the `aliases` rows — "|scallion|spring onion|" — rebuilt
    /// by `FoodItemResolver.reindex(_:)` whenever a row is added or merged.
    ///
    /// It exists only so alias lookup can be a `#Predicate` (`aliasBlob.contains`)
    /// instead of fetching and scanning the whole catalogue on every single line
    /// resolution, forever. The ROWS are the truth. Never append to this directly;
    /// add a `FoodItemAlias` and reindex, or a CloudKit merge of two devices that each
    /// added an alias silently loses one and "scallion" and "green onion" stop
    /// collapsing.
    var aliasBlob: String = ""

    /// `StockTrackingMode`: tracked / staple / untracked.
    ///
    /// Salt, pepper, olive oil and flour are `.staple`: assumed present, never
    /// depleted, and never shopped unless `isRunningLow` or a par level trips.
    /// Without this the app demands he inventory his salt and he abandons it in week
    /// two. Staples still AGGREGATE fully and are shown with their summed quantity in
    /// a collapsed "Staples (not checked)" footer with a one-tap "add anyway" — see
    /// decision 25, which is also why the fixture's 1 tsp + 1/4 tsp kosher salt is a
    /// live test case and not a skipped path.
    var trackingModeRaw: String = StockTrackingMode.tracked.rawValue
    var isRunningLow: Bool = false

    // MARK: Volume <-> mass bridge
    //
    // Stored as an integer pair, not a Double. The whole reason `Rational` exists is
    // to keep Doubles out of the arithmetic, and a density that arrives as a Double
    // and is then `Rational(approximating:)`-ed reintroduces the imprecision at the
    // one point it matters. He types "120" for flour; that is 120/1 exactly.
    var hasDensity: Bool = false
    var gramsPerCupNumerator: Int = 0
    var gramsPerCupDenominator: Int = 1

    // MARK: Purchase pack — what you can actually put in a cart
    var purchasePackHasQuantity: Bool = false
    var purchasePackNumerator: Int = 0
    var purchasePackDenominator: Int = 1
    var purchasePackUnitCode: String = ""
    var purchasePackDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    // MARK: Par level — a staple reaches the list by a RULE, not by a hand-flipped Bool
    var hasParLevel: Bool = false
    var parLevelNumerator: Int = 0
    var parLevelDenominator: Int = 1
    var parLevelUnitCode: String = ""
    var parLevelDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    var preferredDimensionRaw: String = MeasureDimension.mass.rawValue
    var notes: String = ""              // "the good anchovies, back of aisle 7"
    var createdAt: Date = .now

    /// The recipe this item is a batch OF — chimichurri, stock, pizza dough. Closes
    /// the loop between the library and the pantry: a make-ahead batch is stocked as
    /// a lot and drawn down like anything else. Macro lives on `Recipe.mirrorFoodItems`.
    var producedByRecipe: Recipe? = nil

    /// Macro lives on `StoreSection.foodItems`.
    var defaultSection: StoreSection? = nil
    /// Macro lives on `StorageLocation.foodItems`.
    var defaultLocation: StorageLocation? = nil
    /// Macro lives on `DietaryRestriction.foodItems`.
    var restrictions: [DietaryRestriction]? = []

    @Relationship(deleteRule: .cascade, inverse: \FoodItemAlias.item)
    var aliases: [FoodItemAlias]? = []

    @Relationship(deleteRule: .cascade, inverse: \CountEquivalence.item)
    var countEquivalences: [CountEquivalence]? = []

    // MARK: The ledger edges are .nullify, and this is load-bearing
    //
    // A `.cascade` here means one `context.delete(foodItem)` from a stray SwiftUI
    // `.onDelete` destroys the entire append-only ledger the architecture is built
    // around. `.deny` is forbidden by CloudKit. Putting the guard only in a service
    // is not a guard: any other call site bypasses it, and the schema cannot enforce
    // what the service promises.
    //
    // So: `.nullify`, plus `foodItemNameSnapshot` on both children so an orphan is
    // still readable in the reconcile screen. `InventoryLedger.delete(item:)` ALSO
    // refuses an item with history and offers "merge into…", but that is now a
    // courtesy rather than the only thing standing between him and a lost year.
    @Relationship(deleteRule: .nullify, inverse: \StockLot.item)
    var lots: [StockLot]? = []

    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.item)
    var transactions: [InventoryTransaction]? = []

    @Relationship(deleteRule: .nullify, inverse: \IngredientLine.foodItem)
    var ingredientLines: [IngredientLine]? = []

    @Relationship(deleteRule: .nullify, inverse: \ShoppingListLine.foodItem)
    var shoppingLines: [ShoppingListLine]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        matchKey: String = "",
        aliasBlob: String = "",
        trackingModeRaw: String = StockTrackingMode.tracked.rawValue,
        isRunningLow: Bool = false,
        hasDensity: Bool = false,
        gramsPerCupNumerator: Int = 0,
        gramsPerCupDenominator: Int = 1,
        purchasePackHasQuantity: Bool = false,
        purchasePackNumerator: Int = 0,
        purchasePackDenominator: Int = 1,
        purchasePackUnitCode: String = "",
        purchasePackDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        hasParLevel: Bool = false,
        parLevelNumerator: Int = 0,
        parLevelDenominator: Int = 1,
        parLevelUnitCode: String = "",
        parLevelDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        preferredDimensionRaw: String = MeasureDimension.mass.rawValue,
        notes: String = "",
        createdAt: Date = .now,
        producedByRecipe: Recipe? = nil,
        defaultSection: StoreSection? = nil,
        defaultLocation: StorageLocation? = nil
    ) {
        self.id = id
        self.name = name
        self.matchKey = matchKey
        self.aliasBlob = aliasBlob
        self.trackingModeRaw = trackingModeRaw
        self.isRunningLow = isRunningLow
        self.hasDensity = hasDensity
        self.gramsPerCupNumerator = gramsPerCupNumerator
        self.gramsPerCupDenominator = gramsPerCupDenominator
        self.purchasePackHasQuantity = purchasePackHasQuantity
        self.purchasePackNumerator = purchasePackNumerator
        self.purchasePackDenominator = purchasePackDenominator
        self.purchasePackUnitCode = purchasePackUnitCode
        self.purchasePackDimensionRaw = purchasePackDimensionRaw
        self.hasParLevel = hasParLevel
        self.parLevelNumerator = parLevelNumerator
        self.parLevelDenominator = parLevelDenominator
        self.parLevelUnitCode = parLevelUnitCode
        self.parLevelDimensionRaw = parLevelDimensionRaw
        self.preferredDimensionRaw = preferredDimensionRaw
        self.notes = notes
        self.createdAt = createdAt
        self.producedByRecipe = producedByRecipe
        self.defaultSection = defaultSection
        self.defaultLocation = defaultLocation
    }
}

extension FoodItem {
    var trackingMode: StockTrackingMode {
        StockTrackingMode(rawValue: trackingModeRaw) ?? .tracked
    }
    var preferredDimension: MeasureDimension {
        MeasureDimension(rawValue: preferredDimensionRaw) ?? .mass
    }

    /// Grams per US cup, exact. nil means unknown, and unknown means the app REFUSES
    /// to convert rather than guessing: 1 cup = 240 g is right for water, off by 2x
    /// for flour and 1.4x for honey — and wrong SILENTLY, inside the number he is
    /// about to shop by.
    var gramsPerCup: Rational? {
        guard hasDensity else { return nil }
        return Rational(gramsPerCupNumerator, max(1, gramsPerCupDenominator))
    }

    var purchasePack: Quantity? {
        guard purchasePackHasQuantity,
              let unit = UnitCatalog.unit(
                  code: purchasePackUnitCode,
                  fallbackDimension: MeasureDimension(rawValue: purchasePackDimensionRaw)
              )
        else { return nil }
        return Quantity(
            amount: Rational(purchasePackNumerator, max(1, purchasePackDenominator)),
            unit: unit
        )
    }

    var parLevel: Quantity? {
        guard hasParLevel,
              let unit = UnitCatalog.unit(
                  code: parLevelUnitCode,
                  fallbackDimension: MeasureDimension(rawValue: parLevelDimensionRaw)
              )
        else { return nil }
        return Quantity(
            amount: Rational(parLevelNumerator, max(1, parLevelDenominator)),
            unit: unit
        )
    }

    var orderedAliases: [FoodItemAlias] {
        (aliases ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// Every count bridge this item knows. Garlic carries BOTH clove (5 g) and head
    /// (50 g); a single `gramsPerCount` scalar structurally cannot hold two count
    /// units, and the fixture's "12 slices baguette" needs slice-to-loaf to ever shop
    /// as "1 baguette".
    func countEquivalence(forNoun noun: String) -> CountEquivalence? {
        (countEquivalences ?? []).first { $0.countUnitCode == noun }
    }
}
```

### 2.11 `Kitchen/Models/Catalog/FoodItemAlias.swift`

```swift
import Foundation
import SwiftData

/// One alias. A ROW, never an element of a stored `[String]`.
///
/// This is bucketing correctness, not hygiene. Under CloudKit two devices each
/// appending to a stored array resolve last-writer-wins on the WHOLE array, so one
/// alias is silently lost — and a lost alias means "scallion" and "green onion" stop
/// collapsing and the sum quietly splits into two shopping lines. Two rows both
/// survive the merge.
///
/// There is deliberately no built-in synonym dictionary. His vocabulary is his;
/// aliasing is a one-tap "same as…" from any unresolved line.
@Model
final class FoodItemAlias {
    var id: UUID = UUID()
    var text: String = ""
    var matchKey: String = ""
    var createdAt: Date = .now
    /// Owner. Macro lives on `FoodItem.aliases`.
    var item: FoodItem? = nil

    init(
        id: UUID = UUID(),
        text: String = "",
        matchKey: String = "",
        createdAt: Date = .now,
        item: FoodItem? = nil
    ) {
        self.id = id
        self.text = text
        self.matchKey = matchKey
        self.createdAt = createdAt
        self.item = item
    }
}
```

### 2.12 `Kitchen/Models/Catalog/CountEquivalence.swift`

```swift
import Foundation
import SwiftData

/// One count-unit bridge for one `FoodItem`: clove -> 5 g, head -> 50 g,
/// slice -> 1/12 loaf, egg -> 50 g.
///
/// A per-item ROW TABLE rather than a single `gramsPerCount`/`gramsPerPiece` scalar,
/// because garlic in the fixture needs clove for the ingredient line and head for the
/// purchase, and "12 slices baguette" needs slice-to-loaf. One scalar per item can
/// hold exactly one count unit, which is not enough for either case.
///
/// The target may itself be a count unit (slice -> loaf), which is how a count bucket
/// collapses into another count bucket. See `QuantityMath.collapseCountBuckets`.
@Model
final class CountEquivalence {
    var id: UUID = UUID()
    /// The count noun being defined: "clove", "head", "slice", "bunch".
    var countUnitCode: String = ""
    /// What one of them equals.
    var equalsNumerator: Int = 0
    var equalsDenominator: Int = 1
    var equalsUnitCode: String = ""
    var equalsDimensionRaw: String = MeasureDimension.mass.rawValue
    var createdAt: Date = .now
    /// Owner. Macro lives on `FoodItem.countEquivalences`.
    var item: FoodItem? = nil

    init(
        id: UUID = UUID(),
        countUnitCode: String = "",
        equalsNumerator: Int = 0,
        equalsDenominator: Int = 1,
        equalsUnitCode: String = "",
        equalsDimensionRaw: String = MeasureDimension.mass.rawValue,
        createdAt: Date = .now,
        item: FoodItem? = nil
    ) {
        self.id = id
        self.countUnitCode = countUnitCode
        self.equalsNumerator = equalsNumerator
        self.equalsDenominator = equalsDenominator
        self.equalsUnitCode = equalsUnitCode
        self.equalsDimensionRaw = equalsDimensionRaw
        self.createdAt = createdAt
        self.item = item
    }
}

extension CountEquivalence {
    var equals: Quantity? {
        guard let unit = UnitCatalog.unit(
            code: equalsUnitCode,
            fallbackDimension: MeasureDimension(rawValue: equalsDimensionRaw)
        ) else { return nil }
        return Quantity(
            amount: Rational(equalsNumerator, max(1, equalsDenominator)),
            unit: unit
        )
    }
}
```

### 2.13 `Kitchen/Models/Catalog/Store.swift`

```swift
import Foundation
import SwiftData

@Model
final class Store {
    var id: UUID = UUID()
    var name: String = "Default"
    var isDefault: Bool = true
    var sortIndex: Int = 0
    var notes: String = ""
    var createdAt: Date = .now

    @Relationship(deleteRule: .cascade, inverse: \StoreSection.store)
    var sections: [StoreSection]? = []

    @Relationship(deleteRule: .nullify, inverse: \ShoppingList.store)
    var shoppingLists: [ShoppingList]? = []

    init(
        id: UUID = UUID(),
        name: String = "Default",
        isDefault: Bool = true,
        sortIndex: Int = 0,
        notes: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.sortIndex = sortIndex
        self.notes = notes
        self.createdAt = createdAt
    }
}

extension Store {
    var orderedSections: [StoreSection] {
        (sections ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }
}
```

### 2.14 `Kitchen/Models/Catalog/StoreSection.swift`

```swift
import Foundation
import SwiftData

/// One aisle, under a `Store`.
///
/// A MODEL and not an enum, for three reasons that each cost a shipped build
/// otherwise: he cannot add "Fish counter" without one; a second store cannot have its
/// own geography; and reordering an enum's cases is a migration while reordering
/// `sortIndex` is a drag. Keeping the walk order in `UserDefaults` is worse again —
/// that suite is deliberately not synced, so his iPad would shop a different aisle
/// order than his phone.
@Model
final class StoreSection {
    var id: UUID = UUID()
    var name: String = ""
    var matchKey: String = ""
    /// The order he physically walks the store. He will reorder these the first time
    /// he shops with the app.
    var sortIndex: Int = 0
    var symbolName: String = "basket"
    var colorIndex: Int = 0
    var createdAt: Date = .now

    /// Owner. Macro lives on `Store.sections`.
    var store: Store? = nil

    @Relationship(deleteRule: .nullify, inverse: \FoodItem.defaultSection)
    var foodItems: [FoodItem]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        matchKey: String = "",
        sortIndex: Int = 0,
        symbolName: String = "basket",
        colorIndex: Int = 0,
        createdAt: Date = .now,
        store: Store? = nil
    ) {
        self.id = id
        self.name = name
        self.matchKey = matchKey
        self.sortIndex = sortIndex
        self.symbolName = symbolName
        self.colorIndex = colorIndex
        self.createdAt = createdAt
        self.store = store
    }
}
```

### 2.15 `Kitchen/Models/Catalog/StorageLocation.swift`

```swift
import Foundation
import SwiftData

/// Pantry, fridge, freezer, spice rack, bar, garage fridge. A model for the same
/// reasons as `StoreSection` — "Garage fridge" arrives without a build.
@Model
final class StorageLocation {
    var id: UUID = UUID()
    var name: String = ""
    var matchKey: String = ""
    /// `StorageKind`: pantry / fridge / freezer / spice / bar / other. A coarse
    /// classification for icons and default shelf lives; the NAME is what he reads.
    var kindRaw: String = StorageKind.pantry.rawValue
    var sortIndex: Int = 0
    var symbolName: String = "cabinet"
    /// Used to pre-fill `StockLot.expiresAt` on receive. nil, not 0 — zero days is a
    /// meaningful (if silly) value and absent is not.
    var defaultShelfLifeDays: Int? = nil
    var createdAt: Date = .now

    @Relationship(deleteRule: .nullify, inverse: \StockLot.location)
    var lots: [StockLot]? = []

    @Relationship(deleteRule: .nullify, inverse: \FoodItem.defaultLocation)
    var foodItems: [FoodItem]? = []

    @Relationship(deleteRule: .nullify, inverse: \ShoppingListLine.destinationLocation)
    var shoppingLines: [ShoppingListLine]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        matchKey: String = "",
        kindRaw: String = StorageKind.pantry.rawValue,
        sortIndex: Int = 0,
        symbolName: String = "cabinet",
        defaultShelfLifeDays: Int? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.matchKey = matchKey
        self.kindRaw = kindRaw
        self.sortIndex = sortIndex
        self.symbolName = symbolName
        self.defaultShelfLifeDays = defaultShelfLifeDays
        self.createdAt = createdAt
    }
}

extension StorageLocation {
    var kind: StorageKind { StorageKind(rawValue: kindRaw) ?? .pantry }
}
```

### 2.16 `Kitchen/Models/Catalog/MergeRecord.swift`

```swift
import Foundation
import SwiftData

/// An audit row per de-dup merge, so Settings can say "merged 3 duplicates" rather
/// than mutating his data mutely. A merge that happens silently is indistinguishable
/// from data loss.
@Model
final class MergeRecord {
    var id: UUID = UUID()
    var mergedAt: Date = .now
    var entityName: String = ""           // "FoodItem", "StoreSection"
    var survivorID: UUID = UUID()
    var survivorName: String = ""
    /// `|`-delimited. A frozen audit row written once by one writer; nothing appends.
    var absorbedIDBlob: String = ""
    var absorbedNameBlob: String = ""
    var repointedCount: Int = 0
    var note: String = ""

    init(
        id: UUID = UUID(),
        mergedAt: Date = .now,
        entityName: String = "",
        survivorID: UUID = UUID(),
        survivorName: String = "",
        absorbedIDBlob: String = "",
        absorbedNameBlob: String = "",
        repointedCount: Int = 0,
        note: String = ""
    ) {
        self.id = id
        self.mergedAt = mergedAt
        self.entityName = entityName
        self.survivorID = survivorID
        self.survivorName = survivorName
        self.absorbedIDBlob = absorbedIDBlob
        self.absorbedNameBlob = absorbedNameBlob
        self.repointedCount = repointedCount
        self.note = note
    }
}
```

### 2.17 `Kitchen/Models/Catalog/SeedRecord.swift`

```swift
import Foundation
import SwiftData

/// Idempotent seeding without `.unique`: fetch by `seedKey` before applying.
/// Covered by the same reconcile pass as `FoodItem`, for the case where two devices
/// seed in the same minute.
@Model
final class SeedRecord {
    var id: UUID = UUID()
    var seedKey: String = ""      // "sections.v1", "locations.v1", "recipe.nyStrip.v1"
    var appliedAt: Date = .now
    var appVersion: String = ""

    init(
        id: UUID = UUID(),
        seedKey: String = "",
        appliedAt: Date = .now,
        appVersion: String = ""
    ) {
        self.id = id
        self.seedKey = seedKey
        self.appliedAt = appliedAt
        self.appVersion = appVersion
    }
}
```

### 2.18 `Kitchen/Models/Inventory/StockLot.swift`

```swift
import Foundation
import SwiftData

/// One physical lot: this bag of flour, in this location, with this best-by.
///
/// Lots rather than one level per item because butter is simultaneously in the fridge
/// and the freezer with different expiries, because FIFO depletion needs per-lot
/// dates, and because "what is about to go bad" is the single most useful inventory
/// screen. The cost is more rows and more arithmetic. Accepted.
@Model
final class StockLot {
    var id: UUID = UUID()

    // MARK: `remaining` is a CACHE, not truth
    //
    // The truth is the signed sum of this item's `InventoryTransaction` rows. This
    // cache exists because "do I have enough butter" runs on every shopping-list
    // build and every recipe detail render, and summing a multi-year transaction log
    // per item per render is not viable.
    //
    // Every mutation goes through `InventoryLedger`, which writes both.
    // `InventoryLedger.recompute(lot:)` rebuilds it, and `reconcileReport` SURFACES
    // divergence in Settings rather than hiding it. A cache that silently drifts is
    // worse than no cache; a cache that reports its own drift is fine.
    var remainingHasQuantity: Bool = false
    var remainingNumerator: Int = 0
    var remainingDenominator: Int = 1
    var remainingUnitCode: String = ""
    var remainingDimensionRaw: String = MeasureDimension.unmeasured.rawValue
    var cacheRebuiltAt: Date = .now

    var originalHasQuantity: Bool = false
    var originalNumerator: Int = 0
    var originalDenominator: Int = 1
    var originalUnitCode: String = ""
    var originalDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    var acquiredAt: Date = .now
    var expiresAt: Date? = nil
    var openedAt: Date? = nil
    var unitCostCents: Int? = nil
    var label: String = ""                  // "Costco 2-pack", "the big bag", "from Mom"
    var notes: String = ""

    /// Kept so a lot orphaned by a stray item delete is still readable in the
    /// reconcile screen. Same snapshot discipline as `MealAttendance.eaterNameSnapshot`.
    var foodItemNameSnapshot: String = ""

    /// Macro lives on `FoodItem.lots` (and is `.nullify`, see there).
    var item: FoodItem? = nil
    /// Macro lives on `StorageLocation.lots`.
    var location: StorageLocation? = nil

    /// `.nullify`, and `level(of:)` sums the ITEM's transactions rather than its lots.
    ///
    /// If this cascaded, deleting a lot would delete ledger rows. If it nullified
    /// while `level` summed lots, an orphaned transaction would remain in the ledger
    /// but silently stop contributing, producing a divergence `reconcileReport` could
    /// never attribute or clear. Summing at the item level means an orphan still
    /// counts — into an explicit "unassigned lot" bucket the reconcile screen names.
    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.lot)
    var transactions: [InventoryTransaction]? = []

    init(
        id: UUID = UUID(),
        remainingHasQuantity: Bool = false,
        remainingNumerator: Int = 0,
        remainingDenominator: Int = 1,
        remainingUnitCode: String = "",
        remainingDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        cacheRebuiltAt: Date = .now,
        originalHasQuantity: Bool = false,
        originalNumerator: Int = 0,
        originalDenominator: Int = 1,
        originalUnitCode: String = "",
        originalDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        acquiredAt: Date = .now,
        expiresAt: Date? = nil,
        openedAt: Date? = nil,
        unitCostCents: Int? = nil,
        label: String = "",
        notes: String = "",
        foodItemNameSnapshot: String = "",
        item: FoodItem? = nil,
        location: StorageLocation? = nil
    ) {
        self.id = id
        self.remainingHasQuantity = remainingHasQuantity
        self.remainingNumerator = remainingNumerator
        self.remainingDenominator = remainingDenominator
        self.remainingUnitCode = remainingUnitCode
        self.remainingDimensionRaw = remainingDimensionRaw
        self.cacheRebuiltAt = cacheRebuiltAt
        self.originalHasQuantity = originalHasQuantity
        self.originalNumerator = originalNumerator
        self.originalDenominator = originalDenominator
        self.originalUnitCode = originalUnitCode
        self.originalDimensionRaw = originalDimensionRaw
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.openedAt = openedAt
        self.unitCostCents = unitCostCents
        self.label = label
        self.notes = notes
        self.foodItemNameSnapshot = foodItemNameSnapshot
        self.item = item
        self.location = location
    }
}

extension StockLot {
    var remaining: Quantity? {
        guard remainingHasQuantity,
              let unit = UnitCatalog.unit(
                  code: remainingUnitCode,
                  fallbackDimension: MeasureDimension(rawValue: remainingDimensionRaw)
              )
        else { return nil }
        return Quantity(
            amount: Rational(remainingNumerator, max(1, remainingDenominator)),
            unit: unit
        )
    }

    var original: Quantity? {
        guard originalHasQuantity,
              let unit = UnitCatalog.unit(
                  code: originalUnitCode,
                  fallbackDimension: MeasureDimension(rawValue: originalDimensionRaw)
              )
        else { return nil }
        return Quantity(
            amount: Rational(originalNumerator, max(1, originalDenominator)),
            unit: unit
        )
    }

    var isOpen: Bool { openedAt != nil }

    func expires(before date: Date) -> Bool {
        guard let e = expiresAt else { return false }
        return e < date
    }
}
```

### 2.19 `Kitchen/Models/Inventory/InventoryTransaction.swift`

```swift
import Foundation
import SwiftData

/// Append-only. This is the TRUTH of what is in the kitchen.
///
/// Two reasons a scalar `onHand` was rejected, and the second is decisive:
///
/// 1. Answerability. He will open the app and ask "why does it think I have 3 lb of
///    butter?" A scalar has no answer. A ledger shows: bought 2 lb Oct 4, bought 2 lb
///    Oct 19, cooked -1 lb Oct 22.
/// 2. CloudKit merge semantics. With a scalar, his phone decrements butter by 1/2 cup
///    and his iPad by 2 tbsp while both are offline; CloudKit resolves field-level
///    last-writer-wins and ONE DECREMENT VANISHES, with no conflict handler possible.
///    With append-only rows, both are distinct records, both sync, and the derived
///    level is correct with no conflict handling at all.
///
/// This is also the one part of the architecture that is genuinely not additive
/// later: adding a ledger in year two cannot backfill history that was never
/// recorded. Which is why it is built on day one.
@Model
final class InventoryTransaction {
    var id: UUID = UUID()

    /// Signed. Negative depletes.
    ///
    /// `hasDelta == false` means the delta is UNKNOWN, not zero. That is the
    /// `.pendingBridge` case: a cook depletion that needs a density the `FoodItem`
    /// does not carry is WRITTEN, with no number, and lands in the "Unresolved
    /// depletions" inbox. A skipped depletion is an invisible overstatement of stock;
    /// a guessed one is a silent lie. Neither is acceptable, so the app records the
    /// question.
    var hasDelta: Bool = false
    var deltaNumerator: Int = 0
    var deltaDenominator: Int = 1
    var deltaUnitCode: String = ""
    var deltaDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    /// `TransactionKind`: purchase / cookDepletion / waste / manualAdjustment /
    /// correction / inventoryCount / giftOut.
    var kindRaw: String = TransactionKind.manualAdjustment.rawValue
    /// `ResolutionState`: applied / pendingBridge / voided.
    var resolutionStateRaw: String = ResolutionState.applied.rawValue
    var occurredAt: Date = .now
    var note: String = ""
    var priceCents: Int? = nil

    /// So an orphan — from a stray item delete — is still readable and attributable
    /// in the reconcile screen.
    var foodItemNameSnapshot: String = ""

    /// Macro lives on `FoodItem.transactions` (`.nullify`).
    var item: FoodItem? = nil
    /// Macro lives on `StockLot.transactions` (`.nullify`). nil is legal and means
    /// "unassigned lot"; it still contributes to `level(of:)`.
    var lot: StockLot? = nil
    /// Macro lives on `CookLogEntry.depletions`.
    var cookLogEntry: CookLogEntry? = nil
    /// Macro lives on `ShoppingList.receivedTransactions`.
    var shoppingList: ShoppingList? = nil
    /// "Where did the cream go" is answerable. Macro lives on
    /// `PlannedMeal.inventoryTransactions`.
    var plannedMeal: PlannedMeal? = nil

    init(
        id: UUID = UUID(),
        hasDelta: Bool = false,
        deltaNumerator: Int = 0,
        deltaDenominator: Int = 1,
        deltaUnitCode: String = "",
        deltaDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        kindRaw: String = TransactionKind.manualAdjustment.rawValue,
        resolutionStateRaw: String = ResolutionState.applied.rawValue,
        occurredAt: Date = .now,
        note: String = "",
        priceCents: Int? = nil,
        foodItemNameSnapshot: String = "",
        item: FoodItem? = nil,
        lot: StockLot? = nil,
        cookLogEntry: CookLogEntry? = nil,
        shoppingList: ShoppingList? = nil,
        plannedMeal: PlannedMeal? = nil
    ) {
        self.id = id
        self.hasDelta = hasDelta
        self.deltaNumerator = deltaNumerator
        self.deltaDenominator = deltaDenominator
        self.deltaUnitCode = deltaUnitCode
        self.deltaDimensionRaw = deltaDimensionRaw
        self.kindRaw = kindRaw
        self.resolutionStateRaw = resolutionStateRaw
        self.occurredAt = occurredAt
        self.note = note
        self.priceCents = priceCents
        self.foodItemNameSnapshot = foodItemNameSnapshot
        self.item = item
        self.lot = lot
        self.cookLogEntry = cookLogEntry
        self.shoppingList = shoppingList
        self.plannedMeal = plannedMeal
    }
}

extension InventoryTransaction {
    var delta: Quantity? {
        guard hasDelta,
              let unit = UnitCatalog.unit(
                  code: deltaUnitCode,
                  fallbackDimension: MeasureDimension(rawValue: deltaDimensionRaw)
              )
        else { return nil }
        return Quantity(
            amount: Rational(deltaNumerator, max(1, deltaDenominator)),
            unit: unit
        )
    }

    var kind: TransactionKind { TransactionKind(rawValue: kindRaw) ?? .manualAdjustment }
    var resolutionState: ResolutionState {
        ResolutionState(rawValue: resolutionStateRaw) ?? .applied
    }
    /// Only `.applied` rows with a delta contribute to a level.
    var countsTowardLevel: Bool { resolutionState == .applied && hasDelta }
}
```

### 2.20 `Kitchen/Models/Planning/Eater.swift`

```swift
import Foundation
import SwiftData

/// A household member, or a recurring guest who keeps a dietary record.
///
/// THERE IS NO `Household` MODEL. The household *is* the set of `Eater` rows. A
/// singleton created by a bootstrap-if-empty is a CloudKit liability: two devices both
/// bootstrap, and now there are two households with two rosters and attendance split
/// across them. Household-wide preferences that are genuinely per-device (unit system,
/// default diner count, last-used plan scope) live in `AppPreferences` and are
/// deliberately not synced. Everything that must agree across devices — the store walk
/// order, the roster, the locations — is a row.
@Model
final class Eater {
    var id: UUID = UUID()
    var name: String = ""
    /// "Bk" — the calendar chip and the PDF legend.
    var shortName: String = ""
    var colorIndex: Int = 0
    var symbolName: String = "person.fill"

    var isHouseholdMember: Bool = true
    /// Kid at college: keep every history row, hide from pickers.
    var isActive: Bool = true

    /// Portion weight as EXACT INTEGERS, never a Double.
    ///
    /// A 7-year-old is 1/2 and a teenager is 3/2. This is what scales a recipe, not a
    /// head count: "4 eaters" meaning two adults and two toddlers is 3 servings, and
    /// cooking 4 wastes food every time. Three stored thirds as Doubles sum to
    /// 0.9999999 and are only recovered by a continued-fraction approximation that
    /// happens to snap; integers make the whole question disappear.
    var defaultPortionNumerator: Int = 1
    var defaultPortionDenominator: Int = 1

    var birthday: Date? = nil
    var notes: String = ""
    var sortIndex: Int = 0
    var createdAt: Date = .now

    @Relationship(deleteRule: .cascade, inverse: \AttendanceDefault.eater)
    var attendanceDefaults: [AttendanceDefault]? = []

    /// `.nullify`, not `.cascade`: removing a person must not rewrite what the
    /// household ate. The attendance row survives carrying `eaterNameSnapshot`.
    @Relationship(deleteRule: .nullify, inverse: \MealAttendance.eater)
    var attendance: [MealAttendance]? = []

    /// Macro lives on `DietaryRestriction.eaters`.
    var restrictions: [DietaryRestriction]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        shortName: String = "",
        colorIndex: Int = 0,
        symbolName: String = "person.fill",
        isHouseholdMember: Bool = true,
        isActive: Bool = true,
        defaultPortionNumerator: Int = 1,
        defaultPortionDenominator: Int = 1,
        birthday: Date? = nil,
        notes: String = "",
        sortIndex: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.colorIndex = colorIndex
        self.symbolName = symbolName
        self.isHouseholdMember = isHouseholdMember
        self.isActive = isActive
        self.defaultPortionNumerator = defaultPortionNumerator
        self.defaultPortionDenominator = defaultPortionDenominator
        self.birthday = birthday
        self.notes = notes
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

extension Eater {
    var defaultPortion: Rational {
        Rational(defaultPortionNumerator, max(1, defaultPortionDenominator))
    }

    var initials: String {
        shortName.isEmpty ? String(name.prefix(2)) : shortName
    }
}
```

### 2.21 `Kitchen/Models/Planning/AttendanceDefault.swift`

```swift
import Foundation
import SwiftData

/// "Sarah is never home Thursdays." Applied when a `PlannedMeal` is created, so
/// steady-state attendance costs ZERO taps and "who is eating" only becomes work on
/// an exceptional night.
@Model
final class AttendanceDefault {
    var id: UUID = UUID()
    /// `Calendar` weekday, 1 = Sunday. nil = every day.
    var weekday: Int? = nil
    /// `MealSlot` raw value. "" = every slot.
    var slotRaw: String = ""
    /// `AttendanceStatus` to apply.
    var statusRaw: String = AttendanceStatus.attending.rawValue
    var isEnabled: Bool = true
    var note: String = ""
    /// Owner. Macro lives on `Eater.attendanceDefaults`.
    var eater: Eater? = nil

    init(
        id: UUID = UUID(),
        weekday: Int? = nil,
        slotRaw: String = "",
        statusRaw: String = AttendanceStatus.attending.rawValue,
        isEnabled: Bool = true,
        note: String = "",
        eater: Eater? = nil
    ) {
        self.id = id
        self.weekday = weekday
        self.slotRaw = slotRaw
        self.statusRaw = statusRaw
        self.isEnabled = isEnabled
        self.note = note
        self.eater = eater
    }
}

extension AttendanceDefault {
    var status: AttendanceStatus { AttendanceStatus(rawValue: statusRaw) ?? .attending }

    func applies(weekday day: Int, slot: MealSlot) -> Bool {
        guard isEnabled else { return false }
        if let w = weekday, w != day { return false }
        if !slotRaw.isEmpty, slotRaw != slot.rawValue { return false }
        return true
    }
}
```

### 2.22 `Kitchen/Models/Planning/DietaryRestriction.swift`

```swift
import Foundation
import SwiftData

/// A MODEL, not an enum. "No cilantro for Dad" arrives in month four, and an enum
/// case is a code change plus a migration. A `dietaryNotes: String` cannot express
/// severity, and an `avoidedItems: [FoodItem]` cannot say WHERE the allergen is.
///
/// Both matching modes are carried because both are needed: keyword rows catch a
/// hand-typed line that never resolved to the catalogue; explicit `FoodItem` links
/// catch the aliased ones. Severity is what decides whether the answer is "spinach on
/// the side" or "do not serve this".
@Model
final class DietaryRestriction {
    var id: UUID = UUID()
    var label: String = ""                 // "Tree nuts", "No cilantro"
    /// `RestrictionKind`: allergy / intolerance / medical / religious / preference / dislike.
    var kindRaw: String = RestrictionKind.allergy.rawValue
    /// `RestrictionSeverity`: lifeThreatening / strict / avoid / prefer.
    var severityRaw: String = RestrictionSeverity.avoid.rawValue
    var notes: String = ""
    var createdAt: Date = .now

    @Relationship(deleteRule: .cascade, inverse: \DietaryKeyword.restriction)
    var keywords: [DietaryKeyword]? = []

    /// Many-to-many. Macro HERE; `Eater.restrictions` is bare.
    @Relationship(deleteRule: .nullify, inverse: \Eater.restrictions)
    var eaters: [Eater]? = []

    /// Many-to-many. Macro HERE; `FoodItem.restrictions` is bare. Declaring the
    /// inverse is not optional: a to-many with no named inverse is paired by SwiftData
    /// *inference*, which is a runtime graph error and not a compile error.
    @Relationship(deleteRule: .nullify, inverse: \FoodItem.restrictions)
    var foodItems: [FoodItem]? = []

    init(
        id: UUID = UUID(),
        label: String = "",
        kindRaw: String = RestrictionKind.allergy.rawValue,
        severityRaw: String = RestrictionSeverity.avoid.rawValue,
        notes: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.label = label
        self.kindRaw = kindRaw
        self.severityRaw = severityRaw
        self.notes = notes
        self.createdAt = createdAt
    }
}

extension DietaryRestriction {
    var kind: RestrictionKind { RestrictionKind(rawValue: kindRaw) ?? .allergy }
    var severity: RestrictionSeverity {
        RestrictionSeverity(rawValue: severityRaw) ?? .avoid
    }
    var orderedKeywords: [DietaryKeyword] {
        (keywords ?? []).sorted { $0.text < $1.text }
    }
}
```

### 2.23 `Kitchen/Models/Planning/DietaryKeyword.swift`

```swift
import Foundation
import SwiftData

/// One keyword — "walnut", "pecan", "marzipan". A ROW, for the same reason as
/// `FoodItemAlias`: a stored `[String]` is last-writer-wins on the whole blob under
/// CloudKit, and a silently lost allergy keyword is the worst bug in this app.
@Model
final class DietaryKeyword {
    var id: UUID = UUID()
    var text: String = ""
    var matchKey: String = ""
    /// Owner. Macro lives on `DietaryRestriction.keywords`.
    var restriction: DietaryRestriction? = nil

    init(
        id: UUID = UUID(),
        text: String = "",
        matchKey: String = "",
        restriction: DietaryRestriction? = nil
    ) {
        self.id = id
        self.text = text
        self.matchKey = matchKey
        self.restriction = restriction
    }
}
```

### 2.24 `Kitchen/Models/Planning/PlannedMeal.swift`

```swift
import Foundation
import SwiftData

/// One calendar cell.
///
/// There is no `MealPlan` container entity. A plan object would mean ceremony before
/// you can plan Tuesday, and a week boundary is a view concern that would get baked
/// into the data. A date range is a query.
@Model
final class PlannedMeal {
    var id: UUID = UUID()

    var date: Date = Calendar.current.startOfDay(for: .now)
    /// yyyymmdd as an Int — the grouping, sorting and query key.
    ///
    /// A `#Predicate` on a `Date` range is correct until he plans a trip, crosses a
    /// timezone, or hits a DST boundary, and then "Tuesday's dinner" renders on
    /// Monday night — which he reads as "the app moved my dinner". An integer day is
    /// unambiguous, sorts, indexes, and costs four bytes. The real `Date` is kept for
    /// display and export. BOTH are written only by `setDate(_:)` so they cannot
    /// drift.
    var dayKey: Int = 0

    var slotRaw: String = MealSlot.dinner.rawValue
    /// Denormalized from the slot so a `SortDescriptor` can order breakfast before
    /// dinner without a computed property.
    var slotSortIndex: Int = MealSlot.dinner.sortIndex
    var orderInSlot: Int = 0

    /// `MealEntryKind`: recipe / leftovers / takeout / eatingOut / note.
    ///
    /// This is what lets a leftovers night contribute nothing to shopping WITHOUT
    /// being flagged skipped. With only `isSkipped`, "do not shop for this" and "we
    /// skipped it" are the same bit, so Tuesday's planned leftovers render on the
    /// calendar as a skipped meal and the two states are permanently
    /// indistinguishable.
    var kindRaw: String = MealEntryKind.recipe.rawValue

    var title: String = ""                 // used when kind != .recipe: "Thai takeout"
    var notes: String = ""
    var occasion: String = ""              // "Thanksgiving" — a label, not a container

    /// `PlanStatus`: planned / cooked / skipped / moved.
    ///
    /// `.cooked` is excluded from shopping collection as well as `.skipped`, because
    /// cooking already depleted inventory and collecting it again shops twice for a
    /// meal already made.
    var statusRaw: String = PlanStatus.planned.rawValue
    /// A per-meal override that is NOT about the kind. "We are eating out but I still
    /// want the dessert ingredients" is rare; this is for it.
    var excludeFromShopping: Bool = false

    /// Anonymous heads: "Sarah's parents came." Named one-off guests go through
    /// `MealAttendance` with `eater == nil` and a `guestName`, so a dinner guest does
    /// not permanently join the roster.
    var extraGuestCount: Int = 0
    var extraGuestPortionNumerator: Int = 1
    var extraGuestPortionDenominator: Int = 1

    var costCents: Int? = nil              // takeout, optional
    var createdAt: Date = .now

    /// Tuesday is Sunday's ragu again.
    ///
    /// A leftovers meal contributes NOTHING to shopping and draws servings from its
    /// source. The source cooks extra via `MealRecipe.plannedLeftoverServings`.
    ///
    /// THE DOUBLE-COUNT RULE, decided: a separate leftovers meal draws down the
    /// source's `servingsCooked`. `.leftoversOnly` attendance AT THE SOURCE MEAL is
    /// the mutually exclusive alternative — for "Sarah will take a plate to work",
    /// where there is no calendar entry to make. `PlannedMealEditorSheet` refuses both
    /// for the same person against the same source, because allowing both
    /// double-counts a portion and the calendar then cannot say "you are a portion
    /// short".
    ///
    /// Macro lives on `leftoverMeals` below. A self-relationship still needs the
    /// inverse named explicitly.
    var leftoversFrom: PlannedMeal? = nil

    @Relationship(deleteRule: .nullify, inverse: \PlannedMeal.leftoversFrom)
    var leftoverMeals: [PlannedMeal]? = []

    @Relationship(deleteRule: .cascade, inverse: \MealRecipe.meal)
    var mealRecipes: [MealRecipe]? = []

    @Relationship(deleteRule: .cascade, inverse: \MealAttendance.meal)
    var attendance: [MealAttendance]? = []

    /// The live edge that makes "drop Thursday's dinner from this list" and "jump to
    /// the meal that caused this line" into queries rather than a decode-every-blob
    /// scan. The snapshots on the source row preserve history; this edge preserves
    /// navigability. Both are needed.
    @Relationship(deleteRule: .nullify, inverse: \ShoppingListSource.plannedMeal)
    var shoppingSources: [ShoppingListSource]? = []

    @Relationship(deleteRule: .nullify, inverse: \CookLogEntry.plannedMeal)
    var cookLog: [CookLogEntry]? = []

    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.plannedMeal)
    var inventoryTransactions: [InventoryTransaction]? = []

    init(
        id: UUID = UUID(),
        date: Date = Calendar.current.startOfDay(for: .now),
        dayKey: Int = 0,
        slotRaw: String = MealSlot.dinner.rawValue,
        slotSortIndex: Int = MealSlot.dinner.sortIndex,
        orderInSlot: Int = 0,
        kindRaw: String = MealEntryKind.recipe.rawValue,
        title: String = "",
        notes: String = "",
        occasion: String = "",
        statusRaw: String = PlanStatus.planned.rawValue,
        excludeFromShopping: Bool = false,
        extraGuestCount: Int = 0,
        extraGuestPortionNumerator: Int = 1,
        extraGuestPortionDenominator: Int = 1,
        costCents: Int? = nil,
        createdAt: Date = .now,
        leftoversFrom: PlannedMeal? = nil
    ) {
        self.id = id
        self.date = date
        self.dayKey = dayKey
        self.slotRaw = slotRaw
        self.slotSortIndex = slotSortIndex
        self.orderInSlot = orderInSlot
        self.kindRaw = kindRaw
        self.title = title
        self.notes = notes
        self.occasion = occasion
        self.statusRaw = statusRaw
        self.excludeFromShopping = excludeFromShopping
        self.extraGuestCount = extraGuestCount
        self.extraGuestPortionNumerator = extraGuestPortionNumerator
        self.extraGuestPortionDenominator = extraGuestPortionDenominator
        self.costCents = costCents
        self.createdAt = createdAt
        self.leftoversFrom = leftoversFrom
    }
}

extension PlannedMeal {
    var slot: MealSlot { MealSlot(rawValue: slotRaw) ?? .dinner }
    var kind: MealEntryKind { MealEntryKind(rawValue: kindRaw) ?? .recipe }
    var status: PlanStatus { PlanStatus(rawValue: statusRaw) ?? .planned }

    var orderedMealRecipes: [MealRecipe] {
        (mealRecipes ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var orderedAttendance: [MealAttendance] {
        (attendance ?? []).sorted {
            ($0.eater?.sortIndex ?? .max, $0.displayName)
                < ($1.eater?.sortIndex ?? .max, $1.displayName)
        }
    }

    var extraGuestPortion: Rational {
        Rational(extraGuestPortionNumerator, max(1, extraGuestPortionDenominator))
    }

    /// The single predicate the shopping builder filters on.
    ///
    /// `.leftovers`, `.takeout`, `.eatingOut` and `.note` contribute nothing BY KIND,
    /// not by being marked skipped. `.cooked` is excluded because it already depleted.
    var contributesToShopping: Bool {
        kind == .recipe
            && !excludeFromShopping
            && status != .skipped
            && status != .cooked
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let names = orderedMealRecipes.compactMap { $0.displayTitle.isEmpty ? nil : $0.displayTitle }
        if !names.isEmpty { return names.joined(separator: " + ") }
        return kind == .recipe ? "Untitled meal" : kind.defaultTitle
    }

    /// Total cooked across the meal's dishes — what a leftovers child draws down.
    var servingsCookedTotal: Int {
        orderedMealRecipes.reduce(0) { $0 + ($1.servingsCooked ?? 0) }
    }

    /// The ONLY place `date` and `dayKey` are written, so they cannot disagree.
    func setDate(_ newDate: Date, calendar: Calendar = .current) {
        date = calendar.startOfDay(for: newDate)
        dayKey = CalendarKey.dayKey(for: date, in: calendar)
    }

    func setSlot(_ newSlot: MealSlot) {
        slotRaw = newSlot.rawValue
        slotSortIndex = newSlot.sortIndex
    }
}
```

### 2.25 `Kitchen/Models/Planning/MealRecipe.swift`

```swift
import Foundation
import SwiftData

/// Join: one dish in a meal. A dinner is a main and two sides, and each dish scales
/// and is cooked separately.
@Model
final class MealRecipe {
    var id: UUID = UUID()
    var sortIndex: Int = 0

    /// Beats the attendance calculation outright. nil = derive from attendance.
    /// Both nil or both set; the accessor guards it.
    var scaleOverrideNumerator: Int? = nil
    var scaleOverrideDenominator: Int? = nil

    /// Cooking extra on purpose, to feed a `.leftovers` meal later.
    var plannedLeftoverServings: Int? = nil
    /// What was actually made. The number a leftovers child draws down.
    var servingsCooked: Int? = nil

    /// Cook today, eat Thursday.
    var isPrepAhead: Bool = false
    var notes: String = ""

    /// Survives a deleted recipe, so last March's plan does not go blank.
    var recipeTitleSnapshot: String = ""

    /// Macro lives on `Recipe.plannedMeals` (`.nullify`).
    var recipe: Recipe? = nil
    /// Owner. Macro lives on `PlannedMeal.mealRecipes`.
    var meal: PlannedMeal? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        scaleOverrideNumerator: Int? = nil,
        scaleOverrideDenominator: Int? = nil,
        plannedLeftoverServings: Int? = nil,
        servingsCooked: Int? = nil,
        isPrepAhead: Bool = false,
        notes: String = "",
        recipeTitleSnapshot: String = "",
        recipe: Recipe? = nil,
        meal: PlannedMeal? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.scaleOverrideNumerator = scaleOverrideNumerator
        self.scaleOverrideDenominator = scaleOverrideDenominator
        self.plannedLeftoverServings = plannedLeftoverServings
        self.servingsCooked = servingsCooked
        self.isPrepAhead = isPrepAhead
        self.notes = notes
        self.recipeTitleSnapshot = recipeTitleSnapshot
        self.recipe = recipe
        self.meal = meal
    }
}

extension MealRecipe {
    var scaleOverride: Rational? {
        guard let n = scaleOverrideNumerator, let d = scaleOverrideDenominator, d != 0
        else { return nil }
        return Rational(n, d)
    }

    var displayTitle: String {
        recipe?.title ?? recipeTitleSnapshot
    }
}
```

### 2.26 `Kitchen/Models/Planning/MealAttendance.swift`

```swift
import Foundation
import SwiftData

/// Join: WHO is eating, and how much.
///
/// An explicit join rather than a bare many-to-many because attendance CARRIES DATA:
/// a portion override, a maybe, a plate note, a per-warning acknowledgement, and a
/// named one-off guest with no roster row. A bare to-many holds none of it, and
/// "Sarah's parents came for dinner" must not permanently add two people to the
/// household.
///
/// Portions live on the EDGE. That one fact is what makes "scale by the number of
/// eaters" correct for a table of two adults and a toddler, and it makes fractional
/// servings fall out instead of being special-cased.
@Model
final class MealAttendance {
    var id: UUID = UUID()

    /// `AttendanceStatus`: attending / away / maybe / leftoversOnly.
    var statusRaw: String = AttendanceStatus.attending.rawValue

    /// Exact integers. nil = use the snapshot. Both nil or both set.
    var portionOverrideNumerator: Int? = nil
    var portionOverrideDenominator: Int? = nil

    /// Denormalized on purpose: `Eater` deletion is `.nullify`, and a 2027 meal that
    /// says "3 eaters" must not become "0 eaters" because someone moved out. Integers,
    /// not a Double — this is an input to `scale`, and the one place a scale is
    /// derived must not launder its operands through floating point.
    var portionSnapshotNumerator: Int = 1
    var portionSnapshotDenominator: Int = 1
    var eaterNameSnapshot: String = ""

    /// Set when `eater == nil`.
    var guestName: String = ""
    var plateNote: String = ""             // "no horseradish", "sauce on the side"

    /// Macro lives on `Eater.attendance` (`.nullify`).
    var eater: Eater? = nil
    /// Owner. Macro lives on `PlannedMeal.attendance`.
    var meal: PlannedMeal? = nil

    /// "Yes I know, she's having the spinach plain." ROWS, not a stored `[String]`.
    @Relationship(deleteRule: .cascade, inverse: \AcknowledgedWarning.attendance)
    var acknowledgedWarnings: [AcknowledgedWarning]? = []

    init(
        id: UUID = UUID(),
        statusRaw: String = AttendanceStatus.attending.rawValue,
        portionOverrideNumerator: Int? = nil,
        portionOverrideDenominator: Int? = nil,
        portionSnapshotNumerator: Int = 1,
        portionSnapshotDenominator: Int = 1,
        eaterNameSnapshot: String = "",
        guestName: String = "",
        plateNote: String = "",
        eater: Eater? = nil,
        meal: PlannedMeal? = nil
    ) {
        self.id = id
        self.statusRaw = statusRaw
        self.portionOverrideNumerator = portionOverrideNumerator
        self.portionOverrideDenominator = portionOverrideDenominator
        self.portionSnapshotNumerator = portionSnapshotNumerator
        self.portionSnapshotDenominator = portionSnapshotDenominator
        self.eaterNameSnapshot = eaterNameSnapshot
        self.guestName = guestName
        self.plateNote = plateNote
        self.eater = eater
        self.meal = meal
    }
}

extension MealAttendance {
    var status: AttendanceStatus { AttendanceStatus(rawValue: statusRaw) ?? .attending }

    var effectivePortion: Rational {
        if let n = portionOverrideNumerator, let d = portionOverrideDenominator, d != 0 {
            return Rational(n, d)
        }
        return Rational(portionSnapshotNumerator, max(1, portionSnapshotDenominator))
    }

    var displayName: String {
        if let e = eater { return e.name }
        if !guestName.isEmpty { return guestName }
        return eaterNameSnapshot
    }

    var initials: String {
        eater?.initials ?? String(displayName.prefix(2))
    }

    /// `.attending` and `.leftoversOnly` both consume a portion of what is cooked;
    /// `.away` and `.maybe` do not. A `.maybe` is surfaced as a badge on the meal so
    /// he can decide, and is deliberately NOT counted — buying for a maybe every week
    /// is how a plan drifts into over-buying.
    var consumesPortion: Bool {
        status == .attending || status == .leftoversOnly
    }
}
```

### 2.27 `Kitchen/Models/Planning/AcknowledgedWarning.swift`

```swift
import Foundation
import SwiftData

/// One dismissed diet warning. A ROW rather than an element of a stored
/// `[String]` — same last-writer-wins reasoning as `FoodItemAlias`, and the same
/// `#Predicate` invisibility.
@Model
final class AcknowledgedWarning {
    var id: UUID = UUID()
    /// `DietGuard.Warning.id` — stable across rebuilds, derived from
    /// (restriction id, offending item key, path).
    var warningKey: String = ""
    var acknowledgedAt: Date = .now
    var note: String = ""
    /// Owner. Macro lives on `MealAttendance.acknowledgedWarnings`.
    var attendance: MealAttendance? = nil

    init(
        id: UUID = UUID(),
        warningKey: String = "",
        acknowledgedAt: Date = .now,
        note: String = "",
        attendance: MealAttendance? = nil
    ) {
        self.id = id
        self.warningKey = warningKey
        self.acknowledgedAt = acknowledgedAt
        self.note = note
        self.attendance = attendance
    }
}
```

### 2.28 `Kitchen/Models/Shopping/ShoppingList.swift`

```swift
import Foundation
import SwiftData

/// A persisted, frozen trip. Not recomputed on view.
///
/// He checks things off while standing in the produce aisle, and he adds paper towels,
/// which came from no recipe. A list is also a historical document: if he edits the
/// spinach recipe in March, the November list must still say what it said in November.
@Model
final class ShoppingList {
    var id: UUID = UUID()
    var title: String = ""                 // "Nov 3-9"
    var generatedAt: Date = .now
    var rangeStart: Date = .now
    var rangeEnd: Date = .now
    var rangeStartDayKey: Int = 0
    var rangeEndDayKey: Int = 0
    var isArchived: Bool = false
    var completedAt: Date? = nil
    var notes: String = ""

    // MARK: The build options, FROZEN as real fields rather than a JSON blob
    //
    // "Which options produced this list" is a question the regenerate path and the
    // diff sheet both ask, and an `optionsJSON: String` makes it a decode rather
    // than a read. Real fields are also what let a future option be added without
    // touching stored rows.
    var subtractInventory: Bool = true
    var countExpiredAsAvailable: Bool = false
    var expiringGraceDays: Int = 0
    var includeStaples: Bool = false
    var includeOptionalLines: Bool = false
    var roundToPurchaseUnits: Bool = true
    var maxExpansionDepth: Int = 4
    /// `|`-delimited `MealSlot` raw values. Frozen at generation; single writer.
    var slotsBlob: String = ""
    /// `|`-delimited `IngredientLine` UUID strings: the buy-or-make decisions he made
    /// for THIS run, so a regenerate is reproducible.
    ///
    /// A delimited blob under the §2.1 exception: written once at generation by one
    /// writer, never appended to afterwards. Note there is deliberately NO
    /// `includedMealIDs` blob — the live `ShoppingListSource.plannedMeal` edges ARE
    /// the included set, and they are queryable.
    var expandedLineIDBlob: String = ""

    /// Macro lives on `Store.shoppingLists`.
    var store: Store? = nil

    @Relationship(deleteRule: .cascade, inverse: \ShoppingListLine.list)
    var lines: [ShoppingListLine]? = []

    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.shoppingList)
    var receivedTransactions: [InventoryTransaction]? = []

    init(
        id: UUID = UUID(),
        title: String = "",
        generatedAt: Date = .now,
        rangeStart: Date = .now,
        rangeEnd: Date = .now,
        rangeStartDayKey: Int = 0,
        rangeEndDayKey: Int = 0,
        isArchived: Bool = false,
        completedAt: Date? = nil,
        notes: String = "",
        subtractInventory: Bool = true,
        countExpiredAsAvailable: Bool = false,
        expiringGraceDays: Int = 0,
        includeStaples: Bool = false,
        includeOptionalLines: Bool = false,
        roundToPurchaseUnits: Bool = true,
        maxExpansionDepth: Int = 4,
        slotsBlob: String = "",
        expandedLineIDBlob: String = "",
        store: Store? = nil
    ) {
        self.id = id
        self.title = title
        self.generatedAt = generatedAt
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.rangeStartDayKey = rangeStartDayKey
        self.rangeEndDayKey = rangeEndDayKey
        self.isArchived = isArchived
        self.completedAt = completedAt
        self.notes = notes
        self.subtractInventory = subtractInventory
        self.countExpiredAsAvailable = countExpiredAsAvailable
        self.expiringGraceDays = expiringGraceDays
        self.includeStaples = includeStaples
        self.includeOptionalLines = includeOptionalLines
        self.roundToPurchaseUnits = roundToPurchaseUnits
        self.maxExpansionDepth = maxExpansionDepth
        self.slotsBlob = slotsBlob
        self.expandedLineIDBlob = expandedLineIDBlob
        self.store = store
    }
}

extension ShoppingList {
    var orderedLines: [ShoppingListLine] {
        (lines ?? []).sorted {
            ($0.sectionSortIndex, $0.sortIndex, $0.displayName)
                < ($1.sectionSortIndex, $1.sortIndex, $1.displayName)
        }
    }

    /// Grouped for display, preserving the walk order snapshotted on each line.
    var linesBySection: [(sectionName: String, lines: [ShoppingListLine])] {
        var order: [String] = []
        var buckets: [String: [ShoppingListLine]] = [:]
        for line in orderedLines where line.status != .staple && !line.isCovered {
            if buckets[line.sectionNameSnapshot] == nil { order.append(line.sectionNameSnapshot) }
            buckets[line.sectionNameSnapshot, default: []].append(line)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var staplesFooter: [ShoppingListLine] { orderedLines.filter { $0.status == .staple } }
    var coveredFooter: [ShoppingListLine] { orderedLines.filter(\.isCovered) }
    var needsAttention: [ShoppingListLine] {
        orderedLines.filter { $0.status == .needsBridge || $0.status == .unresolvedItem }
    }

    var expandedLineIDs: Set<UUID> {
        Set(expandedLineIDBlob.split(separator: "|").compactMap { UUID(uuidString: String($0)) })
    }

    /// The meals this list covers, from the live edges. This is what "drop Thursday's
    /// dinner" iterates.
    var coveredMeals: [PlannedMeal] {
        var seen: Set<UUID> = []
        var out: [PlannedMeal] = []
        for line in orderedLines {
            for source in line.orderedSources {
                guard let m = source.plannedMeal, !seen.contains(m.id) else { continue }
                seen.insert(m.id)
                out.append(m)
            }
        }
        return out.sorted { ($0.dayKey, $0.slotSortIndex) < ($1.dayKey, $1.slotSortIndex) }
    }
}
```

### 2.29 `Kitchen/Models/Shopping/ShoppingListLine.swift`

```swift
import Foundation
import SwiftData

/// One line per `FoodItem` per list.
///
/// All of requested / have / toBuy / purchase are kept. A fully-covered line is marked
/// `isCovered` and rendered collapsed under "Already have (6)" — never removed. A
/// silently absent line is indistinguishable from a bug, and he needs to see the app's
/// belief about his fridge before he will trust it.
@Model
final class ShoppingListLine {
    var id: UUID = UUID()
    var sortIndex: Int = 0

    /// Snapshots: a line must stay readable across a catalogue merge or an item
    /// delete, and a printed list must not re-sort when he reorders his aisles in
    /// March.
    var displayName: String = ""
    var sectionNameSnapshot: String = ""
    var sectionSortIndex: Int = 0

    /// `LineStatus`: needed / haveEnough / partiallyHave / needsBridge /
    /// unresolvedItem / manual / staple.
    var statusRaw: String = LineStatus.needed.rawValue
    /// `|`-delimited `LineFlag` raw values.
    ///
    /// A delimited blob under the §2.1 exception: a generated line is frozen and
    /// nothing appends to it, and `flagsBlob.contains("|needsBridge|")` is
    /// predicate-queryable, which a stored `[String]` is not.
    var flagsBlob: String = ""

    var isChecked: Bool = false
    var checkedAt: Date? = nil
    /// Paper towels. Always survives a regenerate.
    var isManual: Bool = false
    /// Fully covered by inventory. Shown collapsed, never hidden.
    var isCovered: Bool = false
    /// Collected unmeasured notes: "to taste", "Pinch". Rendered instead of a number,
    /// never as 0 and never aggregated into "2 pinches".
    var unmeasuredNote: String = ""
    var noteToSelf: String = ""
    var priceCents: Int? = nil

    /// Macro lives on `FoodItem.shoppingLines` (`.nullify`).
    var foodItem: FoodItem? = nil
    /// Macro lives on `StorageLocation.shoppingLines`.
    var destinationLocation: StorageLocation? = nil
    /// Owner. Macro lives on `ShoppingList.lines`.
    var list: ShoppingList? = nil

    /// N subtotals, one per (role, dimension).
    ///
    /// Flour legitimately requested by the cup, by the gram AND as "1 package" in the
    /// same week is THREE dimensions. A single `secondaryText` or `neededSecondary`
    /// slot drops the third, and a line that is volume + mass + count has nowhere to
    /// put it. Rows also let the `conversionNote` ride with the SPECIFIC number that
    /// was converted, which a line-level string cannot.
    @Relationship(deleteRule: .cascade, inverse: \ShoppingListLineSubtotal.line)
    var subtotals: [ShoppingListLineSubtotal]? = []

    @Relationship(deleteRule: .cascade, inverse: \ShoppingListSource.line)
    var sources: [ShoppingListSource]? = []

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        displayName: String = "",
        sectionNameSnapshot: String = "",
        sectionSortIndex: Int = 0,
        statusRaw: String = LineStatus.needed.rawValue,
        flagsBlob: String = "",
        isChecked: Bool = false,
        checkedAt: Date? = nil,
        isManual: Bool = false,
        isCovered: Bool = false,
        unmeasuredNote: String = "",
        noteToSelf: String = "",
        priceCents: Int? = nil,
        foodItem: FoodItem? = nil,
        destinationLocation: StorageLocation? = nil,
        list: ShoppingList? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.displayName = displayName
        self.sectionNameSnapshot = sectionNameSnapshot
        self.sectionSortIndex = sectionSortIndex
        self.statusRaw = statusRaw
        self.flagsBlob = flagsBlob
        self.isChecked = isChecked
        self.checkedAt = checkedAt
        self.isManual = isManual
        self.isCovered = isCovered
        self.unmeasuredNote = unmeasuredNote
        self.noteToSelf = noteToSelf
        self.priceCents = priceCents
        self.foodItem = foodItem
        self.destinationLocation = destinationLocation
        self.list = list
    }
}

extension ShoppingListLine {
    var status: LineStatus { LineStatus(rawValue: statusRaw) ?? .needed }
    var flags: Set<LineFlag> { LineFlag.decode(flagsBlob) }

    func subtotals(_ role: SubtotalRole) -> [ShoppingListLineSubtotal] {
        (subtotals ?? [])
            .filter { $0.role == role }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    var requested: [ShoppingListLineSubtotal] { subtotals(.requested) }
    var have: [ShoppingListLineSubtotal] { subtotals(.have) }
    var toBuy: [ShoppingListLineSubtotal] { subtotals(.toBuy) }
    /// What actually enters the ledger on the trip home: the rounded pack.
    var purchase: [ShoppingListLineSubtotal] { subtotals(.purchase) }

    var orderedSources: [ShoppingListSource] {
        (sources ?? []).sorted { ($0.mealDayKey, $0.sortIndex) < ($1.mealDayKey, $1.sortIndex) }
    }
}
```

### 2.30 `Kitchen/Models/Shopping/ShoppingListLineSubtotal.swift`

```swift
import Foundation
import SwiftData

/// One (role, dimension) subtotal on one line.
///
/// `dimensionKey` is "volume" | "mass" | "count:clove" | "count:head". Partitioning
/// count by its NOUN is what stops "2 cloves garlic + 1 clove + 1 head" summing to
/// "4 cloves" and understating garlic by about 50 g — and it is why the merge key and
/// the output type agree, so the display can actually show what the aggregation
/// correctly separated.
@Model
final class ShoppingListLineSubtotal {
    var id: UUID = UUID()
    /// `SubtotalRole`: requested / have / toBuy / purchase.
    var roleRaw: String = SubtotalRole.requested.rawValue
    var dimensionKey: String = ""
    /// The EXACT value in the dimension's base unit (tsp / g / count-of-noun), stored
    /// as integers so it survives any future change to the display ladder.
    var baseNumerator: Int = 0
    var baseDenominator: Int = 1
    /// The unit this should be rendered in, chosen at generation by
    /// `QuantityMath.displayUnit`. Frozen, so a printed list reads the same in March.
    var preferredUnitCode: String = ""
    /// Rides with the SPECIFIC number that was converted:
    /// "200 g counted as 1 2/3 cups at 120 g per cup".
    var conversionNote: String = ""
    /// Set when the stored exact value does not render to a denominator <= 8 and the
    /// display is an approximation prefixed "≈".
    var isApproximateDisplay: Bool = false
    var sortIndex: Int = 0
    /// Owner. Macro lives on `ShoppingListLine.subtotals`.
    var line: ShoppingListLine? = nil

    init(
        id: UUID = UUID(),
        roleRaw: String = SubtotalRole.requested.rawValue,
        dimensionKey: String = "",
        baseNumerator: Int = 0,
        baseDenominator: Int = 1,
        preferredUnitCode: String = "",
        conversionNote: String = "",
        isApproximateDisplay: Bool = false,
        sortIndex: Int = 0,
        line: ShoppingListLine? = nil
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.dimensionKey = dimensionKey
        self.baseNumerator = baseNumerator
        self.baseDenominator = baseDenominator
        self.preferredUnitCode = preferredUnitCode
        self.conversionNote = conversionNote
        self.isApproximateDisplay = isApproximateDisplay
        self.sortIndex = sortIndex
        self.line = line
    }
}

extension ShoppingListLineSubtotal {
    var role: SubtotalRole { SubtotalRole(rawValue: roleRaw) ?? .requested }
    var base: Rational { Rational(baseNumerator, max(1, baseDenominator)) }

    var quantity: Quantity? {
        guard let unit = UnitCatalog.unit(code: preferredUnitCode, fallbackDimension: nil)
        else { return nil }
        guard unit.baseFactor != Rational(0) else { return nil }
        return Quantity(amount: base / unit.baseFactor, unit: unit)
    }

    var displayString: String {
        guard let q = quantity else { return base.mixedDescription }
        let text = q.displayString()
        return isApproximateDisplay ? "≈ \(text)" : text
    }
}
```

### 2.31 `Kitchen/Models/Shopping/ShoppingListSource.swift`

```swift
import Foundation
import SwiftData

/// "Recipe asked for X" — the traceability he will want the moment a number looks
/// wrong, and the rows "drop Thursday's dinner from this list" iterates.
///
/// It carries BOTH denormalized snapshot strings AND a live `.nullify` edge to the
/// meal. The snapshots preserve history across a recipe edit — a list printed in
/// November must still read correctly in March — and the live edge is what makes
/// "which lines did Thursday cause" and "jump to the meal that caused this line" into
/// queries instead of a decode-every-blob scan. An opaque `sourcesJSON` string gives
/// up the second, and a bare relationship gives up the first.
@Model
final class ShoppingListSource {
    var id: UUID = UUID()
    var sortIndex: Int = 0
    /// `LineSourceKind`: plannedMeal / parLevel / manual.
    var kindRaw: String = LineSourceKind.plannedMeal.rawValue

    // MARK: Snapshots
    var mealDayKey: Int = 0
    var mealSlotRaw: String = ""
    var mealTitle: String = ""
    var recipeTitle: String = ""
    /// "Creamed horseradish spinach". For a nested sub-recipe this is the full path
    /// joined with " > ", so the provenance reads the way the dish is built.
    var componentPath: String = ""
    /// "3 tbsp prepared horseradish, drained" — exactly what the recipe said.
    var originalText: String = ""
    /// "4 1/2 tbsp (x1.5)" — what it became.
    var scaledText: String = ""
    /// "x1.5 - 6 eaters, recipe serves 4". On EVERY source row, so the arithmetic is
    /// never a mystery.
    var scaleDescription: String = ""

    // MARK: This source's own contribution, in base units
    var hasContribution: Bool = false
    var contributionDimensionKey: String = ""
    var contributionBaseNumerator: Int = 0
    var contributionBaseDenominator: Int = 1

    /// For "jump to the recipe". Allowed to dangle; the snapshot carries the text.
    var recipeID: UUID? = nil

    /// The live edge. Macro lives on `PlannedMeal.shoppingSources` (`.nullify`).
    var plannedMeal: PlannedMeal? = nil
    /// Owner. Macro lives on `ShoppingListLine.sources`.
    var line: ShoppingListLine? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        kindRaw: String = LineSourceKind.plannedMeal.rawValue,
        mealDayKey: Int = 0,
        mealSlotRaw: String = "",
        mealTitle: String = "",
        recipeTitle: String = "",
        componentPath: String = "",
        originalText: String = "",
        scaledText: String = "",
        scaleDescription: String = "",
        hasContribution: Bool = false,
        contributionDimensionKey: String = "",
        contributionBaseNumerator: Int = 0,
        contributionBaseDenominator: Int = 1,
        recipeID: UUID? = nil,
        plannedMeal: PlannedMeal? = nil,
        line: ShoppingListLine? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.kindRaw = kindRaw
        self.mealDayKey = mealDayKey
        self.mealSlotRaw = mealSlotRaw
        self.mealTitle = mealTitle
        self.recipeTitle = recipeTitle
        self.componentPath = componentPath
        self.originalText = originalText
        self.scaledText = scaledText
        self.scaleDescription = scaleDescription
        self.hasContribution = hasContribution
        self.contributionDimensionKey = contributionDimensionKey
        self.contributionBaseNumerator = contributionBaseNumerator
        self.contributionBaseDenominator = contributionBaseDenominator
        self.recipeID = recipeID
        self.plannedMeal = plannedMeal
        self.line = line
    }
}

extension ShoppingListSource {
    var kind: LineSourceKind { LineSourceKind(rawValue: kindRaw) ?? .plannedMeal }
    var contributionBase: Rational? {
        guard hasContribution else { return nil }
        return Rational(contributionBaseNumerator, max(1, contributionBaseDenominator))
    }
}
```

### 2.32 `Kitchen/Models/Schema/KitchenSchema.swift`

```swift
import Foundation
import SwiftData

/// Versioned from v1, BEFORE there is any data to migrate.
///
/// Adding a `VersionedSchema` later means the existing store carries no recorded
/// version identity, so the first real migration has nothing to migrate FROM — which
/// is exactly the situation the in-memory fallback in `KitchenApp.init` exists to
/// survive. Twenty lines, written before the first build, and the highest-leverage
/// twenty in the app.
enum KitchenSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    /// ONE array, shared by the container and the tests. A model added to one list and
    /// not the other is a runtime "entity not found", not a compile error.
    static var models: [any PersistentModel.Type] = [
        // Recipes
        Recipe.self, RecipeComponent.self, IngredientLine.self, RecipeStep.self,
        RecipeNote.self, RecipeTag.self, RecipePhoto.self, CookLogEntry.self,
        // Catalog
        FoodItem.self, FoodItemAlias.self, CountEquivalence.self,
        Store.self, StoreSection.self, StorageLocation.self,
        MergeRecord.self, SeedRecord.self,
        // Planning
        Eater.self, AttendanceDefault.self, DietaryRestriction.self, DietaryKeyword.self,
        PlannedMeal.self, MealRecipe.self, MealAttendance.self, AcknowledgedWarning.self,
        // Inventory
        StockLot.self, InventoryTransaction.self,
        // Shopping
        ShoppingList.self, ShoppingListLine.self,
        ShoppingListLineSubtotal.self, ShoppingListSource.self
    ]
}

enum KitchenMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [KitchenSchemaV1.self]
    static var stages: [MigrationStage] = []
}
```

### 2.33 `Kitchen/Models/Transfer/` — drag payloads

```swift
// KitchenUTType.swift
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist under UTExportedTypeDeclarations with the same
    /// identifier, or the Transferable conformance silently fails to register.
    static let kitchenRecipe = UTType(exportedAs: "com.brandonkeeny.Kitchen.recipe")
    static let kitchenPlannedMeal = UTType(exportedAs: "com.brandonkeeny.Kitchen.plannedmeal")
}
```

```swift
// RecipeTransfer.swift
import Foundation
import CoreTransferable

/// Carries only an id and a title.
///
/// NEVER put a `@Model` in a drag payload: a `@Model` class is neither reliably
/// `Codable` nor `Sendable`, and the failure is a runtime crash during a drag rather
/// than a compile error. The `ProxyRepresentation` means a drop into Notes yields
/// readable text instead of nothing.
struct RecipeTransfer: Codable, Transferable, Sendable, Hashable {
    let recipeID: UUID
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kitchenRecipe)
        ProxyRepresentation(exporting: \.title)
    }
}
```

```swift
// PlannedMealTransfer.swift
import Foundation
import CoreTransferable

struct PlannedMealTransfer: Codable, Transferable, Sendable, Hashable {
    let mealID: UUID
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kitchenPlannedMeal)
        ProxyRepresentation(exporting: \.title)
    }
}
```

---

## 3. Supporting value types

**Also copied verbatim.** None of these touch SwiftData or SwiftUI, so they are
unit-testable with no `ModelContainer` — the shape of CFAL3's `ReviewScheduler`.

### 3.1 `Kitchen/Models/Support/Rational.swift`

```swift
import Foundation

/// Exact fractions. NEVER `Double`.
///
/// Recipes are written in fractions. `1/3 cup x 3` must be exactly `1 cup`, not
/// `0.9999999`, and a shopping list that reads "0.33333333 cups flour" is a bug
/// rather than precision. `Decimal` does not help — thirds are not representable in
/// base 10 either.
///
/// Every operator is overflow-checked. Addition is the operation the aggregation
/// performs most, and the gcd-first form below is mandatory: cross-multiplying
/// naively (n1*d2 + n2*d1 over d1*d2) reaches ~1e19 within a handful of lines once
/// scales like 7/8 and 3/7 enter, and traps on Int64 — a crash while generating a
/// shopping list in a grocery store.
struct Rational: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    let numerator: Int
    /// Invariant: always > 0, always reduced against the numerator.
    let denominator: Int

    /// Int.min numerators cannot arise from any input path — every numerator comes
    /// from a parsed integer or from an overflow-checked operation below — so the
    /// `abs` here is safe.
    init(_ n: Int, _ d: Int = 1) {
        precondition(d != 0, "Rational denominator must not be zero")
        var n = n
        var d = d
        if d < 0 { n = -n; d = -d }
        let g = Rational.gcd(abs(n), d)
        self.numerator = n / g
        self.denominator = d / g
    }

    static let zero = Rational(0)
    static let one = Rational(1)

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a
        var b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    var doubleValue: Double { Double(numerator) / Double(denominator) }
    var isZero: Bool { numerator == 0 }
    var isNegative: Bool { numerator < 0 }
    var description: String { mixedDescription }

    // MARK: Overflow-reporting arithmetic
    //
    // Call these directly anywhere the caller wants to know. The operators below
    // never trap; they degrade to an approximation and say so in a comment.

    static func addingReportingOverflow(
        _ a: Rational, _ b: Rational
    ) -> (partialValue: Rational, overflow: Bool) {
        let g = gcd(a.denominator, b.denominator)
        let l1 = b.denominator / g
        let l2 = a.denominator / g
        let (p1, o1) = a.numerator.multipliedReportingOverflow(by: l1)
        let (p2, o2) = b.numerator.multipliedReportingOverflow(by: l2)
        let (num, o3) = p1.addingReportingOverflow(p2)
        let (den, o4) = a.denominator.multipliedReportingOverflow(by: l1)
        if o1 || o2 || o3 || o4 { return (.zero, true) }
        return (Rational(num, den), false)
    }

    static func multipliedReportingOverflow(
        _ a: Rational, _ b: Rational
    ) -> (partialValue: Rational, overflow: Bool) {
        // Cross-reduce BEFORE multiplying, so 3/4 * 8/9 never forms 24/36.
        let g1 = gcd(abs(a.numerator), b.denominator)
        let g2 = gcd(abs(b.numerator), a.denominator)
        let (num, o1) = (a.numerator / g1).multipliedReportingOverflow(by: b.numerator / g2)
        let (den, o2) = (a.denominator / g2).multipliedReportingOverflow(by: b.denominator / g1)
        if o1 || o2 { return (.zero, true) }
        return (Rational(num, den), false)
    }

    // MARK: Operators
    //
    // With the culinary conversion table (§3.3) every factor's denominator is at most
    // 20, so the overflow branches below are effectively unreachable. They exist
    // because "effectively unreachable" is not "unreachable", and because the
    // alternative is a trap at the shelf.

    static func + (a: Rational, b: Rational) -> Rational {
        let r = addingReportingOverflow(a, b)
        if !r.overflow { return r.partialValue }
        let retry = addingReportingOverflow(
            a.limitingDenominator(to: 10_000), b.limitingDenominator(to: 10_000)
        )
        return retry.overflow
            ? Rational(approximating: a.doubleValue + b.doubleValue, maxDenominator: 10_000)
            : retry.partialValue
    }

    static func - (a: Rational, b: Rational) -> Rational { a + b.negated }

    static func * (a: Rational, b: Rational) -> Rational {
        let r = multipliedReportingOverflow(a, b)
        if !r.overflow { return r.partialValue }
        let retry = multipliedReportingOverflow(
            a.limitingDenominator(to: 10_000), b.limitingDenominator(to: 10_000)
        )
        return retry.overflow
            ? Rational(approximating: a.doubleValue * b.doubleValue, maxDenominator: 10_000)
            : retry.partialValue
    }

    static func / (a: Rational, b: Rational) -> Rational {
        precondition(!b.isZero, "Rational division by zero")
        return a * b.reciprocal
    }

    static func < (a: Rational, b: Rational) -> Bool {
        let (l, lo) = a.numerator.multipliedReportingOverflow(by: b.denominator)
        let (r, ro) = b.numerator.multipliedReportingOverflow(by: a.denominator)
        if lo || ro { return a.doubleValue < b.doubleValue }
        return l < r
    }

    var negated: Rational { Rational(-numerator, denominator) }

    var reciprocal: Rational {
        precondition(!isZero, "Rational zero has no reciprocal")
        return Rational(denominator, numerator)
    }

    /// Clamped at zero. Used on BOTH sides of the inventory subtraction: a lot holding
    /// +1 lb of mass and -2 tbsp of volume must not produce a NEGATIVE have-subtotal,
    /// because `requested - (-2 tbsp)` silently INFLATES the purchase. Flooring only
    /// `toBuy` guards the wrong side.
    var clampedAtZero: Rational { isNegative ? .zero : self }

    // MARK: Approximation and rounding

    /// Continued fractions. Used only at the boundary — parsing "1.25", and the
    /// overflow fallbacks above. NOTHING in the scaling path goes through here.
    init(approximating value: Double, maxDenominator: Int = 64) {
        guard value.isFinite, abs(value) < 1e15 else { self.init(0); return }
        let negative = value < 0
        var x = abs(value)
        var (h0, h1) = (0, 1)
        var (k0, k1) = (1, 0)
        for _ in 0..<32 {
            let a = Int(x.rounded(.down))
            let h2 = a * h1 + h0
            let k2 = a * k1 + k0
            if k2 > maxDenominator { break }
            (h0, h1) = (h1, h2)
            (k0, k1) = (k1, k2)
            let frac = x - Double(a)
            if frac < 1e-12 { break }
            x = 1 / frac
        }
        self.init(negative ? -h1 : h1, max(1, k1))
    }

    func limitingDenominator(to maximum: Int) -> Rational {
        guard denominator > maximum else { return self }
        return Rational(approximating: doubleValue, maxDenominator: maximum)
    }

    /// Smallest integer >= self. Swift's integer division truncates toward zero, so
    /// the negative branch is already a ceiling.
    var ceilingInt: Int {
        numerator >= 0
            ? (numerator + denominator - 1) / denominator
            : numerator / denominator
    }

    /// Snapped UP to a multiple of `step`. Batch granularity: you cannot bake 1.4
    /// loaves, so a half-batch recipe at 1.4 becomes 1 1/2.
    func ceiling(toMultipleOf step: Rational) -> Rational {
        guard step > .zero else { return self }
        return step * Rational((self / step).ceilingInt)
    }

    /// DISPLAY ONLY. A `Double` is acceptable here and nowhere else, because the
    /// result is never stored and never compared — `ShoppingListLineSubtotal` keeps
    /// the exact base value and renders this.
    func rounded(toDenominator d: Int) -> Rational {
        guard d > 0 else { return self }
        let scaled = (Double(numerator) * Double(d) / Double(denominator)).rounded()
        return Rational(Int(scaled), d)
    }

    // MARK: Display

    /// "2", "3/4", "1 1/4". Never "1.3333".
    var mixedDescription: String {
        if denominator == 1 { return "\(numerator)" }
        let sign = numerator < 0 ? "-" : ""
        let n = abs(numerator)
        let whole = n / denominator
        let rem = n % denominator
        if whole == 0 { return "\(sign)\(rem)/\(denominator)" }
        return "\(sign)\(whole) \(rem)/\(denominator)"
    }

    private static let vulgars: [String: String] = [
        "1/2": "\u{00BD}", "1/3": "\u{2153}", "2/3": "\u{2154}",
        "1/4": "\u{00BC}", "3/4": "\u{00BE}", "1/8": "\u{215B}",
        "3/8": "\u{215C}", "5/8": "\u{215D}", "7/8": "\u{215E}"
    ]

    /// "1\u{00BD}" where a glyph exists, otherwise `mixedDescription`.
    var vulgarDescription: String {
        guard denominator != 1 else { return "\(numerator)" }
        let sign = numerator < 0 ? "-" : ""
        let n = abs(numerator)
        let whole = n / denominator
        let rem = n % denominator
        guard let glyph = Rational.vulgars["\(rem)/\(denominator)"] else {
            return mixedDescription
        }
        return whole == 0 ? "\(sign)\(glyph)" : "\(sign)\(whole)\(glyph)"
    }
}
```

### 3.2 `Kitchen/Models/Support/MeasureDimension.swift`

```swift
import Foundation

/// Volume, mass and count are different physical dimensions and are NOT convertible
/// without per-item data. The app never guesses a density.
///
/// Requirement 6 from the fixture: units carry an explicit dimension, because bare
/// "oz" means weight ounces three times in that document and fluid ounces elsewhere.
/// There is deliberately NO `length` dimension: "1/2 inch thick" is descriptive and
/// not purchasable, so it lives in `IngredientLine.preparation`.
enum MeasureDimension: String, Codable, CaseIterable, Sendable {
    case volume      // base unit: teaspoon
    case mass        // base unit: gram
    case count       // base unit: the noun itself ("clove", "slice", "each")
    /// Reached by the parser, never persisted on a line. A pinch is `nil` quantity
    /// plus an `unmeasuredNote`, not a unit.
    case unmeasured

    var baseUnitCode: String {
        switch self {
        case .volume: return "tsp"
        case .mass: return "g"
        case .count: return "each"
        case .unmeasured: return ""
        }
    }

    var title: String {
        switch self {
        case .volume: return "Volume"
        case .mass: return "Weight"
        case .count: return "Count"
        case .unmeasured: return "Unmeasured"
        }
    }
}
```

### 3.3 `Kitchen/Models/Support/KitchenUnit.swift` and `UnitCatalog.swift`

```swift
// KitchenUnit.swift
import Foundation

/// A STRUCT, not an enum.
///
/// Count nouns are an open set he extends by typing — clove, head, slice, loaf,
/// bunch, sprig, stick, can, ear, fillet, rib, stalk, leaf. More importantly, each
/// count noun must be its own aggregation bucket: with a single `.count` dimension
/// sharing a factor into "each", "2 cloves garlic" + "1 clove" + "1 head garlic" sums
/// to 4 and renders "4 cloves", understating garlic by about 50 g. `dimensionKey`
/// below is what prevents that, and it costs nothing.
struct KitchenUnit: Hashable, Sendable, Identifiable {
    let code: String                 // PERSISTED. "tbsp", "g", "clove"
    let dimension: MeasureDimension
    /// Factor into the dimension's base unit, as an exact `Rational`.
    let baseFactor: Rational
    let singular: String
    let plural: String
    /// Excluded from DISPLAY selection when false. Without this, 18 tsp of butter
    /// legally renders as "3 fl oz", which is not a thing a cook says.
    let isHouseholdCommon: Bool
    let system: UnitSystem           // .us, .metric, .agnostic

    var id: String { code }
    var isCount: Bool { dimension == .count }

    /// The aggregation bucket. "volume" | "mass" | "count:clove" | "unmeasured".
    var dimensionKey: String {
        dimension == .count ? "count:\(code)" : dimension.rawValue
    }

    func name(for amount: Rational) -> String {
        amount == .one ? singular : plural
    }
}
```

```swift
// UnitCatalog.swift
import Foundation

/// The ONLY place a conversion factor is written.
///
/// CULINARY factors, not SI-exact ones, and that is a decision rather than an
/// approximation. Three things follow from it:
///
/// 1. Volume base = teaspoon makes every US unit an exact INTEGER: tsp 1, tbsp 3,
///    fl oz 6, cup 48, pint 96, quart 192, gallon 768. So `2 tbsp + 1/4 cup` is
///    `6 + 12 = 18 tsp` exactly, and converts back to exactly 6 tbsp.
/// 2. Metric joins on the identity every recipe on earth already assumes:
///    1 tsp = 5 mL, so 1 tbsp = 15 mL and 1 cup = 240 mL EXACTLY. A 240 mL carton of
///    cream therefore CANCELS a 1-cup requirement exactly. With SI-exact factors
///    (1 cup = 236.588 mL) the 3.4 mL residue survives `max(0, required - onHand)`
///    and surfaces on the shopping list as a spurious "1 tsp heavy cream" line.
/// 3. Every denominator here is at most 20, so Int overflow stops being a design
///    problem — and the 32-million-denominator factors SI-exactness requires, along
///    with the whole overflow-fallback code path they need, simply do not exist.
///
/// SI-exactness buys nothing a cook can perceive and costs both of the above.
enum UnitCatalog {

    // MARK: Volume — base teaspoon
    static let teaspoon    = KitchenUnit(code: "tsp",    dimension: .volume, baseFactor: Rational(1),      singular: "tsp",   plural: "tsp",    isHouseholdCommon: true,  system: .us)
    static let tablespoon  = KitchenUnit(code: "tbsp",   dimension: .volume, baseFactor: Rational(3),      singular: "tbsp",  plural: "tbsp",   isHouseholdCommon: true,  system: .us)
    /// NOT household-common. 18 tsp is exactly 3 fl oz, and nothing should ever pick it.
    static let fluidOunce  = KitchenUnit(code: "floz",   dimension: .volume, baseFactor: Rational(6),      singular: "fl oz", plural: "fl oz",  isHouseholdCommon: false, system: .us)
    static let cup         = KitchenUnit(code: "cup",    dimension: .volume, baseFactor: Rational(48),     singular: "cup",   plural: "cups",   isHouseholdCommon: true,  system: .us)
    static let pint        = KitchenUnit(code: "pt",     dimension: .volume, baseFactor: Rational(96),     singular: "pint",  plural: "pints",  isHouseholdCommon: true,  system: .us)
    static let quart       = KitchenUnit(code: "qt",     dimension: .volume, baseFactor: Rational(192),    singular: "quart", plural: "quarts", isHouseholdCommon: true,  system: .us)
    static let gallon      = KitchenUnit(code: "gal",    dimension: .volume, baseFactor: Rational(768),    singular: "gallon",plural: "gallons",isHouseholdCommon: false, system: .us)
    /// 1 tsp = 5 mL, so 1 mL = 1/5 tsp.
    static let milliliter  = KitchenUnit(code: "ml",     dimension: .volume, baseFactor: Rational(1, 5),   singular: "mL",    plural: "mL",     isHouseholdCommon: true,  system: .metric)
    static let liter       = KitchenUnit(code: "l",      dimension: .volume, baseFactor: Rational(200),    singular: "L",     plural: "L",      isHouseholdCommon: true,  system: .metric)

    // MARK: Mass — base gram. 1 oz = 28.35 g, 1 lb = 453.6 g, so 16 oz = 453.6 EXACTLY.
    static let gram        = KitchenUnit(code: "g",      dimension: .mass,   baseFactor: Rational(1),         singular: "g",  plural: "g",      isHouseholdCommon: true,  system: .agnostic)
    static let kilogram    = KitchenUnit(code: "kg",     dimension: .mass,   baseFactor: Rational(1000),      singular: "kg", plural: "kg",     isHouseholdCommon: true,  system: .metric)
    static let ounce       = KitchenUnit(code: "oz",     dimension: .mass,   baseFactor: Rational(567, 20),   singular: "oz", plural: "oz",     isHouseholdCommon: true,  system: .us)
    static let pound       = KitchenUnit(code: "lb",     dimension: .mass,   baseFactor: Rational(2268, 5),   singular: "lb", plural: "lb",     isHouseholdCommon: true,  system: .us)

    /// The generic count unit. Every other count noun is synthesized by
    /// `countUnit(noun:)` and gets its OWN bucket.
    static let each = KitchenUnit(code: "each", dimension: .count, baseFactor: Rational(1), singular: "", plural: "", isHouseholdCommon: true, system: .agnostic)

    /// Pre-registered count nouns, so the picker has something to show and so
    /// pluralization is right. The set is open: anything he types resolves.
    static let knownCountNouns: [String: String] = [
        "clove": "cloves", "head": "heads", "slice": "slices", "loaf": "loaves",
        "bunch": "bunches", "sprig": "sprigs", "stick": "sticks", "can": "cans",
        "package": "packages", "ear": "ears", "fillet": "fillets", "rib": "ribs",
        "stalk": "stalks", "leaf": "leaves", "dozen": "dozen", "sheet": "sheets",
        "strip": "strips", "wedge": "wedges", "pinch": "pinches"
    ]

    static let allMeasured: [KitchenUnit] = [
        teaspoon, tablespoon, fluidOunce, cup, pint, quart, gallon, milliliter, liter,
        gram, kilogram, ounce, pound
    ]

    private static let byCode: [String: KitchenUnit] = Dictionary(
        uniqueKeysWithValues: allMeasured.map { ($0.code, $0) } + [(each.code, each)]
    )

    /// A count noun becomes a unit whose base factor is 1 in its own bucket.
    static func countUnit(noun: String) -> KitchenUnit {
        let code = noun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty else { return each }
        let plural = knownCountNouns[code] ?? (code.hasSuffix("s") ? code : code + "s")
        return KitchenUnit(
            code: code, dimension: .count, baseFactor: Rational(1),
            singular: code, plural: plural, isHouseholdCommon: true, system: .agnostic
        )
    }

    /// Returns nil ONLY for an empty code, which is how a row says "no unit".
    ///
    /// Any unknown code becomes a count noun in its own bucket rather than being
    /// thrown away — that is the graceful-degradation path for a unit written by a
    /// newer build on another device. `fallbackDimension` is the recorded dimension
    /// from the row; it is accepted for symmetry with the persistence accessors and is
    /// advisory, because an unknown code has no factor into volume or mass and so
    /// cannot honour a `.volume`/`.mass` claim. Treating it as count keeps the amount
    /// intact and visible instead of silently zeroing it.
    static func unit(code: String, fallbackDimension: MeasureDimension?) -> KitchenUnit? {
        let key = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let known = byCode[key] { return known }
        _ = fallbackDimension
        return countUnit(noun: key)
    }

    private static let synonyms: [String: String] = [
        "t": "tsp", "teaspoon": "tsp", "teaspoons": "tsp", "tsps": "tsp",
        "tb": "tbsp", "tbs": "tbsp", "tbsps": "tbsp",
        "tablespoon": "tbsp", "tablespoons": "tbsp",
        "c": "cup", "cups": "cup",
        "fluidounce": "floz", "fluidounces": "floz", "fl oz": "floz", "fl.oz": "floz",
        "pt": "pt", "pint": "pt", "pints": "pt",
        "qt": "qt", "quart": "qt", "quarts": "qt",
        "gal": "gal", "gallon": "gal", "gallons": "gal",
        "milliliter": "ml", "milliliters": "ml", "millilitre": "ml", "cc": "ml",
        "liter": "l", "liters": "l", "litre": "l", "litres": "l",
        "gram": "g", "grams": "g", "gm": "g",
        "kilogram": "kg", "kilograms": "kg", "kilo": "kg", "kilos": "kg",
        "ounce": "oz", "ounces": "oz",
        "pound": "lb", "pounds": "lb", "lbs": "lb", "#": "lb"
    ]

    /// Token -> unit. Bare "oz" resolves to MASS here, because recipes mean weight far
    /// more often, and the fixture uses it as weight three times. The importer may
    /// override by ingredient context; once resolved, the decision is RECORDED on the
    /// line and nothing downstream re-guesses it.
    static func resolve(_ token: String) -> KitchenUnit? {
        var key = token.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        if key.isEmpty { return nil }
        if let mapped = synonyms[key] { key = mapped }
        if let u = byCode[key] { return u }
        if knownCountNouns[key] != nil || knownCountNouns.values.contains(key) {
            return countUnit(noun: key.hasSuffix("s") ? String(key.dropLast()) : key)
        }
        return nil
    }

    /// Display candidates, DESCENDING by base factor.
    ///
    /// `floz` and `gal` never appear. US and metric sets are separate so a US display
    /// never offers litres, while grams stay available in both because he owns a scale.
    static func displayCandidates(
        for dimensionKey: String, system: UnitSystem
    ) -> [KitchenUnit] {
        if dimensionKey.hasPrefix("count:") {
            let noun = String(dimensionKey.dropFirst("count:".count))
            return [countUnit(noun: noun)]
        }
        switch (MeasureDimension(rawValue: dimensionKey), system) {
        case (.volume, .metric): return [liter, milliliter]
        case (.volume, _):       return [quart, pint, cup, tablespoon, teaspoon]
        case (.mass, .metric):   return [kilogram, gram]
        case (.mass, _):         return [pound, ounce, gram]
        default:                 return []
        }
    }
}
```

### 3.4 `Kitchen/Models/Support/Quantity.swift` and `QuantityCarrying`

```swift
// Quantity.swift
import Foundation

/// An amount and a unit.
///
/// WHY NOT `Measurement<UnitVolume>`, decided once:
///
/// - It is `Double`-backed, so 1/3 cup renders as 0.333333 on the first screen he
///   opens, and 1/3 cup x 3 is not 1 cup.
/// - It is GENERIC over its dimension, so one property cannot hold both "1/4 cup" and
///   "2 cloves" — and an ingredient list is heterogeneous by nature.
/// - `UnitVolume` has no `clove`, `bunch`, `package` or `to taste`, which is most of
///   how recipes are actually written.
/// - Any `Measurement` stored in SwiftData needs a `Codable` wrapper anyway, so the
///   "free" option was never free.
///
/// A custom type was therefore mandatory regardless; given that, one well-tested type
/// beats a `Measurement` for some lines and something else for the rest.
/// `MeasurementFormatter` is still used inside `displayString` for metric output — we
/// wrap Foundation, we do not fight it.
struct Quantity: Hashable, Sendable {
    var amount: Rational
    var unit: KitchenUnit

    var dimension: MeasureDimension { unit.dimension }
    var dimensionKey: String { unit.dimensionKey }

    /// In tsp / g / count-of-this-noun.
    var base: Rational { amount * unit.baseFactor }

    func scaled(by factor: Rational) -> Quantity {
        Quantity(amount: amount * factor, unit: unit)
    }

    /// nil across dimension keys — including across two different count nouns, which
    /// is the point. Crossing those needs a `CountEquivalence` and goes through
    /// `QuantityMath`.
    func converted(to target: KitchenUnit) -> Quantity? {
        guard target.dimensionKey == dimensionKey, target.baseFactor != .zero else { return nil }
        return Quantity(amount: base / target.baseFactor, unit: target)
    }

    func displayString(system: UnitSystem = .us) -> String {
        let (chosen, approximate) = QuantityMath.displayUnit(
            forBase: base, dimensionKey: dimensionKey, hint: unit, system: system
        )
        let value = chosen.baseFactor == .zero ? amount : base / chosen.baseFactor
        let shown = approximate ? value.rounded(toDenominator: 8) : value
        let prefix = approximate ? "\u{2248} " : ""
        let name = chosen.name(for: shown)
        return name.isEmpty
            ? "\(prefix)\(shown.vulgarDescription)"
            : "\(prefix)\(shown.vulgarDescription) \(name)"
    }
}
```

```swift
// Quantity.swift (same file) — the persistence bridge
import Foundation

/// The five stored primitives every model that holds a quantity declares, and the one
/// computed accessor they all share.
///
/// Quantities persist as FLAT PRIMITIVES, never as a `Codable` composite attribute.
/// SwiftData stores a `Codable` struct as an opaque encoded blob: it is unqueryable by
/// `#Predicate`, unreadable in the CloudKit dashboard, and — decisively — any future
/// change to `Rational` or to the unit table requires a custom migration stage that
/// decodes every stored row in the OLD Codable shape before re-encoding it. That is
/// precisely the migration this project exists to avoid. Five defaulted scalars
/// survive every additive schema change.
protocol QuantityCarrying: AnyObject {
    var hasQuantity: Bool { get set }
    var amountNumerator: Int { get set }
    var amountDenominator: Int { get set }
    var unitCode: String { get set }
    var dimensionRaw: String { get set }
}

extension QuantityCarrying {
    /// nil means THERE IS NO QUANTITY — "Pinch flaky salt", "salt to taste". A nil
    /// quantity never enters arithmetic, never suppresses a shopping line, and cannot
    /// be confused with a deliberate zero or with a parse failure.
    var quantity: Quantity? {
        get {
            guard hasQuantity,
                  let unit = UnitCatalog.unit(
                      code: unitCode,
                      fallbackDimension: MeasureDimension(rawValue: dimensionRaw)
                  )
            else { return nil }
            return Quantity(
                amount: Rational(amountNumerator, max(1, amountDenominator)),
                unit: unit
            )
        }
        set {
            guard let q = newValue else {
                hasQuantity = false
                amountNumerator = 0
                amountDenominator = 1
                return
            }
            hasQuantity = true
            amountNumerator = q.amount.numerator
            amountDenominator = q.amount.denominator
            unitCode = q.unit.code
            dimensionRaw = q.unit.dimension.rawValue
        }
    }
}
```

### 3.5 `Kitchen/Models/Support/QuantityMath.swift`

```swift
import Foundation

/// The arithmetic under test. A pure enum: no fetches, no mutation, no SwiftUI.
enum QuantityMath {

    /// One (dimension, count-noun) subtotal, in base units.
    struct Subtotal: Hashable, Sendable {
        var dimensionKey: String
        /// EXACT, in tsp / g / count-of-noun.
        var base: Rational
        /// The unit chosen for display. Frozen onto the persisted row so a printed
        /// list reads the same in March.
        var preferredUnit: KitchenUnit
        /// Rides with the SPECIFIC number that was converted.
        var conversionNote: String = ""
        var isApproximateDisplay: Bool = false
    }

    /// One contribution on the way in, with the unit it was WRITTEN in (which is what
    /// the hint is computed from).
    struct Contribution: Hashable, Sendable {
        var quantity: Quantity
    }

    // MARK: - Display unit selection

    /// Picks the unit a human would use, and says when the answer is approximate.
    ///
    /// (a) If the HINT unit — the unit the most source lines were written in, ties
    ///     broken toward the FINER unit — yields an amount in [1/4, 64), use it. If
    ///     every recipe says tbsp, he wants tbsp.
    /// (b) Otherwise take the COARSEST candidate where base/factor >= 1. If that
    ///     amount's reduced denominator exceeds 8, step ONE unit finer and retry.
    /// (c) If nothing yields a denominator <= 8, keep the coarsest with amount >= 1,
    ///     keep the EXACT value, and report `isApproximate` so the caller displays it
    ///     rounded to the nearest 1/8 prefixed "\u{2248}".
    /// (d) If NOTHING on the ladder reaches 1 — 1/2 tsp of a volume, a base smaller
    ///     than the finest unit — use the FINEST unit. This is the hole every other
    ///     "largest unit whose value is >= 1" rule leaves open, and it is why
    ///     1/2 tsp renders as "1/2 tsp" and not as "0 tbsp".
    ///
    /// `fl oz`, `gallon` and (in US mode) `kg`/`L` are not candidates at all, which is
    /// what guarantees 18 tsp of butter renders "6 tbsp" and never "3 fl oz".
    static func displayUnit(
        forBase base: Rational,
        dimensionKey: String,
        hint: KitchenUnit?,
        system: UnitSystem = .us
    ) -> (unit: KitchenUnit, isApproximate: Bool) {
        let candidates = UnitCatalog.displayCandidates(for: dimensionKey, system: system)
            .filter(\.isHouseholdCommon)
        guard let finest = candidates.last else { return (UnitCatalog.each, false) }

        // (a)
        if let h = hint, h.isHouseholdCommon, candidates.contains(h), h.baseFactor != .zero {
            let amount = base / h.baseFactor
            if amount >= Rational(1, 4) && amount < Rational(64) { return (h, false) }
        }

        // (b) and (c)
        for (index, unit) in candidates.enumerated() where unit.baseFactor != .zero {
            let amount = base / unit.baseFactor
            guard amount >= .one else { continue }
            if amount.denominator <= 8 { return (unit, false) }
            if index + 1 < candidates.count {
                let finer = candidates[index + 1]
                if finer.baseFactor != .zero, (base / finer.baseFactor).denominator <= 8 {
                    return (finer, false)
                }
            }
            return (unit, true)
        }

        // (d)
        let amount = finest.baseFactor == .zero ? base : base / finest.baseFactor
        return (finest, amount.denominator > 8)
    }

    /// The hint: the unit the most contributions were written in. Ties go to the FINER
    /// unit, because the finer unit yields a whole-ish number more often — which is
    /// what makes `2 tbsp + 1/4 cup` display as "6 tbsp" rather than "3/8 cup".
    static func hintUnit(from contributions: [Contribution], dimensionKey: String) -> KitchenUnit? {
        var counts: [KitchenUnit: Int] = [:]
        for c in contributions where c.quantity.dimensionKey == dimensionKey {
            counts[c.quantity.unit, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.baseFactor < rhs.key.baseFactor
            }
            .first?.key
    }

    // MARK: - Summation

    /// Partition by `dimensionKey`, add EXACTLY within each partition, then attempt
    /// the two collapses. Count nouns are partitioned FIRST and only bridged by
    /// `CountEquivalence`, which is why "2 cloves + 1 head" never becomes "3 cloves".
    static func sum(
        _ contributions: [Contribution],
        using item: FoodItem?,
        system: UnitSystem = .us
    ) -> [Subtotal] {
        var bases: [String: Rational] = [:]
        for c in contributions {
            guard c.quantity.dimension != .unmeasured else { continue }
            bases[c.quantity.dimensionKey, default: .zero] =
                bases[c.quantity.dimensionKey, default: .zero] + c.quantity.base
        }
        var subtotals = bases.map { key, base -> Subtotal in
            let hint = hintUnit(from: contributions, dimensionKey: key)
            let (unit, approx) = displayUnit(
                forBase: base, dimensionKey: key, hint: hint, system: system
            )
            return Subtotal(
                dimensionKey: key, base: base, preferredUnit: unit,
                isApproximateDisplay: approx
            )
        }
        subtotals = collapseCountBuckets(subtotals, using: item, system: system)
        subtotals = collapseAcrossDimensions(subtotals, using: item, system: system)
        return subtotals.sorted { $0.dimensionKey < $1.dimensionKey }
    }

    /// Collapses `.count` buckets of the same item. TWO passes, in this order.
    ///
    /// Pass 1, count -> count. A noun whose `CountEquivalence` is expressed in ANOTHER
    /// noun present on the line folds into it: with clove -> 1/10 head, "3 cloves +
    /// 1 head" becomes 1 3/10 heads, which purchase-rounds to "buy 2 heads". With
    /// slice -> 1/12 loaf, the fixture's "12 slices baguette" becomes exactly 1 loaf,
    /// which is what finally lets it shop as "1 baguette" instead of "12 slices".
    /// Iterated to a fixed point, capped, because clove -> head -> braid is legal.
    ///
    /// Pass 2, count -> mass or volume. Only when EVERY remaining count bucket has an
    /// equivalence resolving to the SAME non-count dimension. If only some nouns have
    /// one, nothing is collapsed: "3 cloves + 1 head" is more useful to a shopper than
    /// "3 cloves + 50 g".
    ///
    /// The two passes together are the fix for the bug where `.count` shares one
    /// dimension with a factor into "each": there, "2 cloves garlic + 1 clove +
    /// 1 head garlic" sums to base 4 and renders "4 cloves", understating garlic by
    /// about 50 g, and "6 slices baguette + 1 loaf" renders "7 slices". The data to
    /// fix it existed on the model but was consulted only when crossing DIMENSIONS, so
    /// the bridge could never fire inside `.count`. Partition by noun first, then
    /// bridge — in that order.
    static func collapseCountBuckets(
        _ subtotals: [Subtotal], using item: FoodItem?, system: UnitSystem
    ) -> [Subtotal] {
        guard let item else { return subtotals }
        var working = subtotals
        guard working.filter({ $0.dimensionKey.hasPrefix("count:") }).count > 1 else {
            return working
        }

        // Pass 1: fold a count noun into another count noun present on the line.
        for _ in 0..<8 {
            let countKeys = Set(working.filter { $0.dimensionKey.hasPrefix("count:") }.map(\.dimensionKey))
            guard countKeys.count > 1 else { break }
            var changed = false
            for key in countKeys.sorted() {
                let noun = String(key.dropFirst("count:".count))
                guard let eq = item.countEquivalence(forNoun: noun),
                      let equals = eq.equals,
                      equals.dimensionKey.hasPrefix("count:"),
                      equals.dimensionKey != key,
                      countKeys.contains(equals.dimensionKey),
                      let sourceIndex = working.firstIndex(where: { $0.dimensionKey == key }),
                      let targetIndex = working.firstIndex(where: { $0.dimensionKey == equals.dimensionKey })
                else { continue }
                let source = working[sourceIndex]
                let moved = source.base * equals.base
                let total = working[targetIndex].base + moved
                let (unit, approx) = displayUnit(
                    forBase: total, dimensionKey: equals.dimensionKey,
                    hint: working[targetIndex].preferredUnit, system: system
                )
                let note = "\(source.base.mixedDescription) \(noun) counted as \(moved.mixedDescription) \(equals.unit.code)"
                working[targetIndex] = Subtotal(
                    dimensionKey: equals.dimensionKey, base: total, preferredUnit: unit,
                    conversionNote: [working[targetIndex].conversionNote, note]
                        .filter { !$0.isEmpty }.joined(separator: "; "),
                    isApproximateDisplay: approx
                )
                working.remove(at: sourceIndex)
                changed = true
                break
            }
            if !changed { break }
        }

        // Pass 2: fold every remaining count noun into one shared non-count dimension.
        let countBuckets = working.filter { $0.dimensionKey.hasPrefix("count:") }
        guard countBuckets.count > 1 else { return working }

        var targets: Set<String> = []
        var converted: [(Subtotal, Rational, String)] = []
        for bucket in countBuckets {
            let noun = String(bucket.dimensionKey.dropFirst("count:".count))
            guard let eq = item.countEquivalence(forNoun: noun),
                  let equals = eq.equals,
                  !equals.dimensionKey.hasPrefix("count:")
            else { return working }
            targets.insert(equals.dimensionKey)
            converted.append((bucket, bucket.base * equals.base, noun))
        }
        guard targets.count == 1, let targetKey = targets.first else { return working }

        var kept = working.filter { !$0.dimensionKey.hasPrefix("count:") }
        var total: Rational = kept.first(where: { $0.dimensionKey == targetKey })?.base ?? .zero
        var notes: [String] = kept
            .first(where: { $0.dimensionKey == targetKey })
            .map { $0.conversionNote.isEmpty ? [] : [$0.conversionNote] } ?? []
        kept.removeAll { $0.dimensionKey == targetKey }
        for (bucket, value, noun) in converted {
            total = total + value
            notes.append("\(bucket.base.mixedDescription) \(noun) counted as \(value.mixedDescription)")
        }
        let (unit, approx) = displayUnit(
            forBase: total, dimensionKey: targetKey, hint: nil, system: system
        )
        kept.append(Subtotal(
            dimensionKey: targetKey, base: total, preferredUnit: unit,
            conversionNote: notes.joined(separator: "; "), isApproximateDisplay: approx
        ))
        return kept
    }

    /// Volume <-> mass, and ONLY with a per-item density.
    ///
    /// "1 cup flour + 200 g flour" is answered here. With no `gramsPerCup`, both
    /// buckets SURVIVE on one line and the caller flags `.needsBridge`. The app never
    /// invents a density: 1 cup = 240 g is right for water, off by ~2x for flour and
    /// ~1.4x for honey — and wrong SILENTLY, inside the number he is about to shop by.
    static func collapseAcrossDimensions(
        _ subtotals: [Subtotal], using item: FoodItem?, system: UnitSystem
    ) -> [Subtotal] {
        guard let item, let gramsPerCup = item.gramsPerCup, gramsPerCup != .zero else {
            return subtotals
        }
        guard let volume = subtotals.first(where: { $0.dimensionKey == MeasureDimension.volume.rawValue }),
              let mass = subtotals.first(where: { $0.dimensionKey == MeasureDimension.mass.rawValue })
        else { return subtotals }

        var kept = subtotals.filter {
            $0.dimensionKey != MeasureDimension.volume.rawValue
                && $0.dimensionKey != MeasureDimension.mass.rawValue
        }
        // volume base is tsp; 48 tsp = 1 cup = gramsPerCup grams.
        let gramsPerTsp = gramsPerCup / Rational(48)

        if item.preferredDimension == .mass {
            let total = mass.base + volume.base * gramsPerTsp
            let (unit, approx) = displayUnit(
                forBase: total, dimensionKey: MeasureDimension.mass.rawValue,
                hint: mass.preferredUnit, system: system
            )
            let shownVolume = Quantity(amount: volume.base, unit: UnitCatalog.teaspoon)
                .displayString(system: system)
            kept.append(Subtotal(
                dimensionKey: MeasureDimension.mass.rawValue, base: total,
                preferredUnit: unit,
                conversionNote: "\(shownVolume) counted as \((volume.base * gramsPerTsp).mixedDescription) g at \(gramsPerCup.mixedDescription) g per cup",
                isApproximateDisplay: approx
            ))
        } else {
            let total = volume.base + mass.base / gramsPerTsp
            let (unit, approx) = displayUnit(
                forBase: total, dimensionKey: MeasureDimension.volume.rawValue,
                hint: volume.preferredUnit, system: system
            )
            kept.append(Subtotal(
                dimensionKey: MeasureDimension.volume.rawValue, base: total,
                preferredUnit: unit,
                conversionNote: "\(mass.base.mixedDescription) g counted as \((mass.base / gramsPerTsp).mixedDescription) tsp at \(gramsPerCup.mixedDescription) g per cup",
                isApproximateDisplay: approx
            ))
        }
        return kept
    }

    // MARK: - Subtraction

    /// `toBuy = max(0, requested - have)`, per dimension, with BOTH sides clamped.
    ///
    /// A butter lot holding +1 lb (mass) and -2 tbsp (volume, used in cooking) yields
    /// a NEGATIVE volume have-subtotal from the signed ledger. Flooring only `toBuy`
    /// guards the wrong side: `1 cup - (-2 tbsp)` becomes `1 cup + 2 tbsp` and the
    /// negative residue silently INFLATES the purchase. So `have` is clamped first.
    ///
    /// When a requirement and the matching stock are in DIFFERENT dimensions and the
    /// item carries no bridge, `needed = requested` — assume NOTHING is on hand — and
    /// the line is flagged `.needsBridge`. Never silently subtract, and never silently
    /// treat the requirement as covered: buying a duplicate pound of butter is a far
    /// cheaper error than arriving at dinner without it.
    static func subtract(
        requested: [Subtotal],
        have: [Subtotal],
        item: FoodItem?,
        system: UnitSystem = .us
    ) -> (toBuy: [Subtotal], flags: Set<LineFlag>) {
        var flags: Set<LineFlag> = []
        let haveByKey = Dictionary(
            have.map { ($0.dimensionKey, $0.base.clampedAtZero) },
            uniquingKeysWith: { $0 + $1 }
        )
        let hasUnmatchedStock = have.contains { haveByKey[$0.dimensionKey] != nil }
            && !have.allSatisfy { h in requested.contains { $0.dimensionKey == h.dimensionKey } }
        if hasUnmatchedStock && item?.gramsPerCup == nil { flags.insert(.needsBridge) }

        var out: [Subtotal] = []
        for r in requested {
            let onHand = haveByKey[r.dimensionKey] ?? .zero
            if onHand == .zero && hasUnmatchedStock { flags.insert(.needsBridge) }
            let remainder = (r.base - onHand).clampedAtZero
            guard remainder != .zero else { continue }
            let (unit, approx) = displayUnit(
                forBase: remainder, dimensionKey: r.dimensionKey,
                hint: r.preferredUnit, system: system
            )
            out.append(Subtotal(
                dimensionKey: r.dimensionKey, base: remainder,
                preferredUnit: unit, conversionNote: r.conversionNote,
                isApproximateDisplay: approx
            ))
        }
        return (out, flags)
    }

    /// Rounds up to a purchasable pack. `5 eggs -> 1 dozen`, `0.3 bunch -> 1 bunch`,
    /// `1 1/3 cups -> 1 quart`. Returns the exact `toBuy` unchanged when the item has
    /// no pack, because inflating a number silently is how a list loses trust — the
    /// rounding is always SHOWN beside the need.
    static func purchaseQuantity(
        forToBuy toBuy: [Subtotal], item: FoodItem?, system: UnitSystem = .us
    ) -> [Subtotal] {
        guard let item, let pack = item.purchasePack, pack.base != .zero else { return toBuy }
        return toBuy.map { subtotal in
            guard subtotal.dimensionKey == pack.dimensionKey else { return subtotal }
            let packs = Rational((subtotal.base / pack.base).ceilingInt)
            let total = packs * pack.base
            let (unit, approx) = displayUnit(
                forBase: total, dimensionKey: subtotal.dimensionKey,
                hint: pack.unit, system: system
            )
            return Subtotal(
                dimensionKey: subtotal.dimensionKey, base: total, preferredUnit: unit,
                conversionNote: "need \(subtotal.base.mixedDescription), buy \(packs.mixedDescription) x \(pack.displayString(system: system))",
                isApproximateDisplay: approx
            )
        }
    }
}
```

### 3.6 `Kitchen/Models/Support/MergeKey.swift`

```swift
import Foundation

/// How a line is identified for aggregation.
enum ItemIdentity: Hashable, Sendable {
    case cataloged(UUID)        // FoodItem.id, post-reconcile so aliases have collapsed
    case freeText(String)       // normalized name; still shoppable, flagged unresolved
}

/// The aggregation bucket.
///
/// `dimensionKey` carries the count NOUN, so clove and head are separate subtotals
/// ON ONE LINE and the output type can display exactly what the merge key separated.
///
/// `preparation` is deliberately NOT in the key: you buy onions, not diced-ness, so
/// "1 cup onion, diced" and "1/2 cup onion, sliced" merge into "1 1/2 cups onion"
/// while both cook screens still say diced and sliced.
struct MergeKey: Hashable, Sendable {
    let item: ItemIdentity
    let dimensionKey: String
}
```

### 3.7 `Kitchen/Models/Support/KitchenEnums.swift`

```swift
import Foundation
import SwiftUI

/// Every enum is `String`-raw-value-backed and stored as a `…Raw: String` with a
/// computed accessor that falls back to a default. A value written by a newer build on
/// another device then DEGRADES gracefully instead of failing to decode — CFAL3's
/// `Session.mode` convention.

enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case us, metric, agnostic
}

enum MealSlot: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A REAL slot, not a nicety. The fixture's step 1 is a 30-minute passive rest and
    /// its notes say the spinach can be made a day ahead, so "salt the steaks,
    /// uncovered in the fridge" has to land on Friday for Saturday's dinner. It sorts
    /// first because it is work done ahead of the day's meals.
    case prep
    case breakfast, brunch, lunch, snack, dinner, dessert, other

    var id: String { rawValue }

    var sortIndex: Int {
        switch self {
        case .prep: return 0
        case .breakfast: return 1
        case .brunch: return 2
        case .lunch: return 3
        case .snack: return 4
        case .dinner: return 5
        case .dessert: return 6
        case .other: return 7
        }
    }

    var title: String {
        switch self {
        case .prep: return "Prep ahead"
        case .breakfast: return "Breakfast"
        case .brunch: return "Brunch"
        case .lunch: return "Lunch"
        case .snack: return "Snack"
        case .dinner: return "Dinner"
        case .dessert: return "Dessert"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .prep: return "clock.badge.checkmark"
        case .breakfast: return "sunrise"
        case .brunch: return "sun.max"
        case .lunch: return "sun.min"
        case .snack: return "carrot"
        case .dinner: return "moon.stars"
        case .dessert: return "birthday.cake"
        case .other: return "fork.knife"
        }
    }
}

enum MealEntryKind: String, Codable, CaseIterable, Sendable {
    case recipe, leftovers, takeout, eatingOut, note

    var defaultTitle: String {
        switch self {
        case .recipe: return "Meal"
        case .leftovers: return "Leftovers"
        case .takeout: return "Takeout"
        case .eatingOut: return "Eating out"
        case .note: return "Note"
        }
    }

    var symbol: String {
        switch self {
        case .recipe: return "book.closed"
        case .leftovers: return "arrow.triangle.2.circlepath"
        case .takeout: return "bag"
        case .eatingOut: return "building.2"
        case .note: return "note.text"
        }
    }
}

enum AttendanceStatus: String, Codable, CaseIterable, Sendable {
    case attending, away, maybe, leftoversOnly

    /// One tap cycles in this order. Four taps for a four-person dinner, no sheet.
    var next: AttendanceStatus {
        switch self {
        case .attending: return .away
        case .away: return .maybe
        case .maybe: return .leftoversOnly
        case .leftoversOnly: return .attending
        }
    }
}

enum PlanStatus: String, Codable, CaseIterable, Sendable {
    case planned, cooked, skipped, moved
}

enum CourseKind: String, Codable, CaseIterable, Sendable {
    case appetizer, main, side, sauce, component, dessert, breakfast, drink, bake
}

enum Difficulty: String, Codable, CaseIterable, Sendable {
    case easy, medium, project
}

enum ComponentKind: String, Codable, CaseIterable, Sendable {
    case protein, base, side, sauce, garnish, finish, other
}

enum NoteKind: String, Codable, CaseIterable, Sendable {
    case makeAhead, keyStep, variation, timing, general
}

/// Applied to the WHOLE-RECIPE scale, with a `.snappedToBatch` note. A per-line
/// "fixed" rule handles the bay leaf but cannot express "you cannot bake 3/4 of a
/// cake" — that is a recipe-level property.
enum BatchGranularity: String, Codable, CaseIterable, Sendable {
    case continuous, halfBatches, wholeBatches

    var step: Rational? {
        switch self {
        case .continuous: return nil
        case .halfBatches: return Rational(1, 2)
        case .wholeBatches: return Rational(1)
        }
    }
}

/// `.fixed` is how "1 bay leaf" and the oil for the pan survive a 3x batch without
/// becoming three bay leaves and a fistful of salt.
enum ScalingRule: String, Codable, CaseIterable, Sendable {
    case linear, fixed
}

enum SubRecipePolicy: String, Codable, CaseIterable, Sendable {
    case expandToIngredients, treatAsItem, assumeOnHand
}

enum StockTrackingMode: String, Codable, CaseIterable, Sendable {
    case tracked, staple, untracked
}

enum StorageKind: String, Codable, CaseIterable, Sendable {
    case pantry, fridge, freezer, spice, bar, other
}

enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case purchase, cookDepletion, waste, manualAdjustment, correction, inventoryCount, giftOut
}

enum ResolutionState: String, Codable, CaseIterable, Sendable {
    case applied
    /// Written with `hasDelta == false`. A cook depletion that needs a density the
    /// item does not carry is RECORDED, not skipped and not guessed, and lands in the
    /// "Unresolved depletions" inbox. A skipped depletion is an invisible
    /// overstatement of stock.
    case pendingBridge
    case voided
}

enum LineStatus: String, Codable, CaseIterable, Sendable {
    case needed, haveEnough, partiallyHave, needsBridge, unresolvedItem, manual, staple
}

enum LineSourceKind: String, Codable, CaseIterable, Sendable {
    case plannedMeal
    /// A staple reaches the list by a RULE when its rollup falls below par, rather
    /// than only when a Bool is flipped by hand.
    case parLevel
    case manual
}

enum SubtotalRole: String, Codable, CaseIterable, Sendable {
    case requested, have, toBuy, purchase
}

enum RestrictionKind: String, Codable, CaseIterable, Sendable {
    case allergy, intolerance, medical, religious, preference, dislike
}

enum RestrictionSeverity: String, Codable, CaseIterable, Sendable {
    case lifeThreatening, strict, avoid, prefer

    var sortIndex: Int {
        switch self {
        case .lifeThreatening: return 0
        case .strict: return 1
        case .avoid: return 2
        case .prefer: return 3
        }
    }
}

enum PlanScope: String, Codable, CaseIterable, Sendable {
    case month, week, day, brief
}
```

### 3.8 `Kitchen/Models/Support/ScalingNote.swift`

```swift
import Foundation

/// Surfaced as a BADGE on every affected shopping line, not swallowed.
///
/// A meal with nobody assigned must neither silently buy nothing nor silently buy for
/// four, and a snapped batch must say it snapped.
enum ScalingNote: String, Codable, CaseIterable, Sendable {
    case noAttendance
    case unknownYield
    case snappedToBatch
    case overridden
    case leftoversIncluded

    var badge: String {
        switch self {
        case .noAttendance: return "no eaters set"
        case .unknownYield: return "yield unknown"
        case .snappedToBatch: return "whole batch"
        case .overridden: return "scale overridden"
        case .leftoversIncluded: return "extra for leftovers"
        }
    }
}
```

### 3.9 `Kitchen/Models/Support/LineFlag.swift`

```swift
import Foundation

enum LineFlag: String, Codable, CaseIterable, Sendable {
    case needsBridge        // volume vs mass with no density; nothing assumed on hand
    case unresolvedItem     // never matched a catalogue row
    case assumedOnHand      // a staple, diverted to the footer
    case converted          // a density or count bridge fired; see the conversionNote
    case expiredStockIgnored
    case expiringBeforeNeed // excluded by expiringGraceDays
    case noAttendance
    case unknownYield
    case snappedToBatch
    case overridden
    case parLevel
    case manual

    /// `|a|b|` so `flagsBlob.contains("|needsBridge|")` works in a `#Predicate`.
    static func encode(_ flags: Set<LineFlag>) -> String {
        guard !flags.isEmpty else { return "" }
        return "|" + flags.map(\.rawValue).sorted().joined(separator: "|") + "|"
    }

    static func decode(_ blob: String) -> Set<LineFlag> {
        Set(blob.split(separator: "|").compactMap { LineFlag(rawValue: String($0)) })
    }

    static func from(_ notes: [ScalingNote]) -> Set<LineFlag> {
        Set(notes.compactMap {
            switch $0 {
            case .noAttendance: return .noAttendance
            case .unknownYield: return .unknownYield
            case .snappedToBatch: return .snappedToBatch
            case .overridden: return .overridden
            case .leftoversIncluded: return nil
            }
        })
    }
}
```

### 3.10 `Kitchen/Models/Support/CalendarKey.swift`

```swift
import Foundation

/// The ONLY place day math lives.
///
/// `dayKey` is yyyymmdd as an Int. A `#Predicate` on a `Date` range is correct until
/// he plans a trip, crosses a timezone or hits a DST boundary, and then "Tuesday's
/// dinner" renders on Monday night — which he reads as "the app moved my dinner". An
/// integer day is unambiguous, sorts, indexes, and costs four bytes.
enum CalendarKey {
    static func dayKey(for date: Date, in calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    static func date(fromDayKey key: Int, in calendar: Calendar = .current) -> Date? {
        var c = DateComponents()
        c.year = key / 10_000
        c.month = (key / 100) % 100
        c.day = key % 100
        return calendar.date(from: c)
    }

    static func weekInterval(containing date: Date, in calendar: Calendar = .current) -> DateInterval {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func monthInterval(containing date: Date, in calendar: Calendar = .current) -> DateInterval {
        let start = calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func dayKeys(in interval: DateInterval, calendar: Calendar = .current) -> [Int] {
        var keys: [Int] = []
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            keys.append(dayKey(for: cursor, in: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }
}
```

---

## 4. The shopping-list algorithm

This is where the app is either good or useless. `ShoppingListBuilder` is a pure
`enum` in the spirit of CFAL3's `ReviewScheduler`: **no fetches, no mutation, no
SwiftUI.** It reads values the caller already has and returns a value. Every step
below is independently unit-testable with no `ModelContainer`.

### 4.1 Types

```swift
// Kitchen/Services/MealScaling.swift
enum MealScaling {
    struct Result: Sendable {
        let portions: Rational
        let scale: Rational
        let notes: [ScalingNote]
        /// "x1 1/2 - 6 eaters, recipe serves 4". Lands on EVERY source row.
        let description: String
    }

    static func scaling(for mealRecipe: MealRecipe, defaultDinerCount: Int) -> Result
}
```

```swift
// Kitchen/Services/RecipeGraph.swift
enum RecipeGraph {
    struct Provenance: Hashable, Sendable {
        var mealID: UUID?
        var mealDayKey: Int
        var mealSlotRaw: String
        var mealTitle: String
        var recipeTitle: String
        var recipeID: UUID?
        var scaleDescription: String
    }

    struct FlatLine {
        var identity: ItemIdentity
        var foodItem: FoodItem?
        var displayName: String
        /// Already scaled. nil = unmeasured; carries `unmeasuredNote` instead.
        var quantity: Quantity?
        var unmeasuredNote: String
        var preparation: String
        var originalText: String
        var scaledText: String
        var isStaple: Bool
        var isRunningLow: Bool
        /// ["NY Strip Crostini", "Creamed horseradish spinach"] — captured at flatten
        /// time, never reconstructed later. `DietGuard` uses the same path so a
        /// warning can say WHERE the allergen is.
        var componentPath: [String]
        var provenance: Provenance
        var notes: [ScalingNote]
    }

    enum Diagnostic: Hashable, Sendable {
        case cycle(recipeTitle: String)
        case depthExceeded(recipeTitle: String)
        /// The sub-recipe could not be expanded dimensionally. The line stays a
        /// buy-it line and says so, rather than being silently mis-scaled.
        case subRecipeNotExpandable(recipeTitle: String, lineText: String, reason: String)
        case unresolvedItem(text: String, recipeTitle: String)
        case orphanedComponentReference(componentTitle: String, recipeTitle: String)
        case zeroServings(recipeTitle: String)
    }

    /// `visited` is passed BY VALUE and that is not a style choice.
    ///
    /// As `inout` it becomes a global already-seen set rather than a per-PATH cycle
    /// guard, so a sub-recipe used in two sibling branches — the chimichurri as a
    /// component AND referenced by a second component, or one stock recipe feeding two
    /// of the week's meals in a single build — silently contributes ZERO ingredients on
    /// every use after the first. By value, each branch carries its own path.
    static func flatten(
        recipe: Recipe,
        scale: Rational,
        options: ShoppingListBuilder.Options,
        provenance: Provenance,
        componentPath: [String],
        visited: Set<UUID>,
        depth: Int,
        diagnostics: inout [Diagnostic]
    ) -> [FlatLine]

    /// The dimensionally-sound sub-recipe scale. nil means DO NOT EXPAND.
    static func childScale(for line: IngredientLine, subRecipe: Recipe) -> Rational?
}
```

```swift
// Kitchen/Services/ShoppingListBuilder.swift
enum ShoppingListBuilder {
    struct Options: Hashable, Sendable {
        var range: DateInterval
        var slots: Set<MealSlot> = [.breakfast, .brunch, .lunch, .snack, .dinner, .dessert]
        var subtractInventory: Bool = true
        var countExpiredAsAvailable: Bool = false
        /// Excludes stock expiring before the END of the plan range from the on-hand
        /// total, so a yogurt that dies Tuesday does not cover Friday's recipe.
        var expiringGraceDays: Int = 0
        var includeStaples: Bool = false
        var includeOptionalLines: Bool = false
        var roundToPurchaseUnits: Bool = true
        var includeCoveredLines: Bool = true
        /// Buy-or-make overrides for THIS run. Frozen onto the list so a regenerate
        /// is reproducible.
        var expandedLineIDs: Set<UUID> = []
        var maxExpansionDepth: Int = 4
        var unitSystem: UnitSystem = .us
        var defaultDinerCount: Int = 2
        var now: Date = .now
    }

    struct DraftSource: Sendable {
        var kind: LineSourceKind
        var mealID: UUID?
        var mealDayKey: Int
        var mealSlotRaw: String
        var mealTitle: String
        var recipeTitle: String
        var componentPath: String
        var originalText: String
        var scaledText: String
        var scaleDescription: String
        var contribution: QuantityMath.Subtotal?
    }

    struct DraftLine: Sendable {
        var identity: ItemIdentity
        var foodItemID: UUID?
        var displayName: String
        var sectionName: String
        var sectionSortIndex: Int
        var status: LineStatus
        var flags: Set<LineFlag>
        var unmeasuredNote: String
        var requested: [QuantityMath.Subtotal]
        var have: [QuantityMath.Subtotal]
        var toBuy: [QuantityMath.Subtotal]
        var purchase: [QuantityMath.Subtotal]
        var sources: [DraftSource]
        var isCovered: Bool
    }

    struct Draft: Sendable {
        var lines: [DraftLine]            // already sectioned and sorted
        var diagnostics: [RecipeGraph.Diagnostic]
        var mealCount: Int
        var adHocMealCount: Int
        var sectionOrder: [String]
    }

    /// Steps 1-9, nothing persisted. The generation sheet calls this live as he
    /// toggles options: "32 items across 6 sections, 4 flagged".
    static func preview(
        meals: [PlannedMeal],
        inventoryLevel: (FoodItem) -> [QuantityMath.Subtotal],
        parLevelShortfalls: [(FoodItem, QuantityMath.Subtotal)],
        options: Options
    ) -> Draft

    /// Identical to `preview`. Named separately so the call sites read correctly;
    /// persistence is `ShoppingListStore.materialize(draft:into:)`, step 10-11.
    static func build(
        meals: [PlannedMeal],
        inventoryLevel: (FoodItem) -> [QuantityMath.Subtotal],
        parLevelShortfalls: [(FoodItem, QuantityMath.Subtotal)],
        options: Options
    ) -> Draft
}
```

`inventoryLevel` is injected as a CLOSURE rather than the builder reaching for a
`ModelContext`. That is what keeps the whole algorithm testable with hand-built values
and no store, and it is why `InventoryLedger` (which does hold a container) is a
separate type.

### 4.2 The steps

**Step 1 — collect the meals.**

```
FetchDescriptor<PlannedMeal>(
    predicate: #Predicate { $0.dayKey >= startKey && $0.dayKey <= endKey },
    sortBy: [SortDescriptor(\.dayKey), SortDescriptor(\.slotSortIndex),
             SortDescriptor(\.orderInSlot)]
)
```

Keep `meal.contributesToShopping && options.slots.contains(meal.slot)`. That one
accessor drops, **by kind and not by a skipped flag**:

- `.leftovers` — Tuesday reheating Sunday's ragù. The single most important exclusion
  in this algorithm and the largest source of over-buying in a weekly plan.
- `.takeout`, `.eatingOut`, `.note` — nothing to buy.
- `status == .skipped` — he decided not to.
- **`status == .cooked`** — cooking already depleted inventory, so collecting it again
  shops twice for a meal already made.

Meals with no `MealRecipe` contribute nothing but are counted into
`Draft.adHocMealCount`, so the header can say "3 meals with no recipe".

**Step 2 — portions and scale, per dish.** `MealScaling.scaling(for:defaultDinerCount:)`:

```
portions = Σ over meal.attendance where consumesPortion of effectivePortion
         + extraGuestCount x extraGuestPortion
         + plannedLeftoverServings            // note .leftoversIncluded
```

- `mealRecipe.scaleOverride != nil` wins outright → `scale = override`, note
  `.overridden`. Skip to the batch snap.
- `portions == 0` → `portions = Rational(options.defaultDinerCount)`, note
  `.noAttendance`. A meal with nobody assigned must **neither** silently buy nothing
  **nor** silently buy for four without saying so; the note becomes a badge on every
  line it touches.
- `recipe == nil` → `scale = 1`, note `.unknownYield`, diagnostic.
- `scale = portions / recipe.servings`.
  **`servings` is the divisor, never `yieldQuantity`.** The fixture's yield is "12
  crostini (serves 4)": dividing by 12 gives `4/12 = 1/3` and the first shopping list
  he generates buys one third of every ingredient, with no zero-yield warning because
  the yield is not zero. `Recipe.servings` is guaranteed positive by its accessor.
- Batch snap: `if let step = recipe.batchGranularity.step { scale = scale.ceiling(toMultipleOf: step) }`,
  note `.snappedToBatch` when it moved. You cannot bake 1.4 loaves.
- `description = "x\(scale.mixedDescription) - \(portions.mixedDescription) eaters, recipe serves \(servings.mixedDescription)"`.

All of `portions`, `servings` and `scale` are exact `Rational`s built from integer
numerator/denominator pairs. **Nothing is laundered through a `Double`.** Three adults
and a toddler against a 4-serving recipe is exactly `(7/2)/4 = 7/8`.

**Step 3 — flatten the recipe graph.** `RecipeGraph.flatten`, walking
`recipe.orderedComponents` then each component's `orderedLines`:

- `component.sourceRecipe != nil` → recurse at `scale * component.sourceScale`,
  `componentPath + [component.title]`, `visited.union([recipe.id])`, `depth + 1`. A
  sub-recipe-as-component is part of the dish by definition, so it is always expanded.
- `component.isOrphanedReference` → emit `.orphanedComponentReference` and contribute
  nothing, rather than silently contributing nothing.
- `line.subRecipe != nil` → expand only if `line.id ∈ options.expandedLineIDs` or
  `line.subRecipePolicy == .expandToIngredients`. When expanding, the child scale is
  `RecipeGraph.childScale(for:subRecipe:)`:

  ```
  guard let q = line.quantity                           else { return nil }
  guard let yieldAmount = sub.yieldQuantity,
        let yieldUnit = UnitCatalog.resolve(sub.yieldUnitLabel)
                     ?? UnitCatalog.countUnit(noun: sub.yieldUnitLabel) as KitchenUnit?
                                                        else { return nil }
  let yieldBase = (yieldAmount * yieldUnit.baseFactor)
  guard q.dimensionKey == yieldUnit.dimensionKey, yieldBase != .zero else { return nil }
  return q.base / yieldBase
  ```

  **This is dimensionally sound and the naive version is not.** "2 cups chicken stock"
  against a recipe yielding "2 quarts" is `96 tsp / 384 tsp = 1/4` of a batch. Dividing
  a volume by a SERVING COUNT gives `473.2 / 4 ≈ 118`, so the flattener shops for 118
  batches of stock — and because it happens inside the recursion, the error compounds at
  every level. `nil` means **do not expand**: the line stays an ordinary buy-it line
  flagged `.unknownYield`, with a `.subRecipeNotExpandable` diagnostic naming the reason.
  Guessing is never an option here.

- ordinary line → `line.quantity?.scaled(by: line.scalingRule == .fixed ? .one : scale)`.
- `line.quantity == nil` → passes through unscaled with its `unmeasuredNote`. "Pinch
  flaky salt" reaches the list as a presence item: never `0`, never dropped, never
  aggregated into "2 pinches".
- `line.excludeFromShopping` → dropped always. `line.isOptional && !includeOptionalLines`
  → dropped.
- **Cycle guard**: `visited.contains(recipe.id)` → `.cycle` diagnostic, return `[]`.
  `depth > options.maxExpansionDepth` → `.depthExceeded`, return `[]`. Stock referencing
  stock referencing stock is not hypothetical in a library that grows for ten years, and
  the failure without this is a hang while he is holding a phone in a grocery store.

**Step 4 — resolve and bucket.** `identity = foodItem.map(ItemIdentity.cataloged) ?? .freeText(NameNormalizer.matchKey(displayName))`.
Group by `MergeKey(item:dimensionKey:)`.

Resolved lines bucket by the SURVIVOR `FoodItem.id` — `FoodItemResolver.reconcile` has
already run, so aliases have collapsed. Unresolved lines each get their own line with
`status = .unresolvedItem` and an inline "match to…" affordance, so the list is usable
the day he imports a messy recipe.

Lines whose `quantity == nil` bypass bucketing entirely: they collapse to one line per
item with every provenance attached and **no arithmetic at all**. "Salt to taste" across
six recipes is still "salt, to taste".

**Step 5 — sum exactly within each bucket.** `QuantityMath.sum(_:using:system:)`:
partition by `dimensionKey`, add exact `Rational` base values, then
`collapseCountBuckets` (count→count, then count→mass/volume) and
`collapseAcrossDimensions` (volume↔mass via `gramsPerCup`). Surviving buckets become
`requested` subtotals, one per dimension, N per line. Two or more irreducible →
`flags.insert(.needsBridge)`, and **both numbers are rendered on one line** with an
inline "these are the same — 1 cup = ___ g" affordance that writes `gramsPerCup` back
onto the `FoodItem`. One tap, once, forever: after a few months the dozen ingredients he
genuinely measures both ways are all populated and the issue disappears. The app learns,
which is the right shape for a ten-year project.

**Step 6 — subtract inventory.** `options.subtractInventory` → `inventoryLevel(item)`,
which `InventoryLedger` implements by summing the item's **transactions** (not its lots),
excluding:

- rows whose `resolutionState != .applied` or `hasDelta == false`;
- lots with `expiresAt < options.now` unless `countExpiredAsAvailable` → flag
  `.expiredStockIgnored`;
- lots expiring before `range.end + expiringGraceDays` → flag `.expiringBeforeNeed`.

Then `QuantityMath.subtract(requested:have:item:)`, with **both sides clamped at zero**
and the cross-dimension rule: requirement and stock in different dimensions with no
bridge → `needed = requested` (assume nothing is on hand) and `.needsBridge`.

`needed == 0` → `status = .haveEnough`, `isCovered = true`. The line is **kept and
collapsed** under "Already have (6)", never removed: inventory is sometimes wrong, a
silently absent line is indistinguishable from a bug, and he needs to see the app's
belief about his fridge before he will trust it. `isRunningLow` items count as zero on
hand and are flagged "you said this was low".

**Step 7 — staples, aggregated then diverted.** `item.trackingMode == .staple` and not
(`includeStaples || isRunningLow || par-level shortfall`) → `status = .staple`,
`flags.insert(.assumedOnHand)`, routed to the collapsed "Staples (not checked)" footer
with a one-tap "add anyway".

**The aggregation runs first and the summed quantity is shown in the footer.** The
fixture's kosher salt — 1 tsp in the steak group plus 1/4 tsp in the spinach group —
is the document's own proof case for intra-recipe aggregation, and diverting salt to a
quantity-less bucket means the arithmetic never runs on it, leaving butter as the only
surviving proof. `KitchenTests/ShoppingListBuilderTests` asserts `1 1/4 tsp` **through
the staple path**.

**Step 8 — par levels.** For `item.hasParLevel` whose rollup is below `parLevel`, add a
line with a single `.parLevel` source and no meal. This is how a staple reaches the list
by a rule rather than only when a Bool is flipped by hand.

**Step 9 — purchase rounding, section, sort.**
`QuantityMath.purchaseQuantity(forToBuy:item:)` → the `purchase` subtotals, kept
**alongside** `toBuy`. The line reads "need 1 1/3 cups, buy 1 quart", and it is the
**quart** that `InventoryLedger.receive` posts. Feeding the pre-rounding number back
drifts tracked stock monotonically below reality and makes the pantry — the feature the
whole inventory model exists for — untrustworthy within weeks.

Group by `item.defaultSection`, sections ordered by `sortIndex` (his store's actual
geography, drag-reorderable, and a synced **row** rather than an unsynced `UserDefaults`
value). Alphabetical within a section. Unsectioned lines land in a trailing "Unsorted"
group with a one-tap assign that writes `defaultSection` — learned once. Section name and
`sortIndex` are **snapshotted onto each line**, so reordering aisles in March does not
scramble a list printed in November.

**Step 10 — persist.** `ShoppingListStore.materialize(draft:into:existing:)` writes the
`ShoppingList`, its lines, their subtotal rows and their source rows, freezing the
options onto the list. The previous list is never mutated — he may already have shopped
off it. "Merge into current list" is an explicit action.

**Step 11 — regenerate, preserving check-state.** Lines are matched on
`(ItemIdentity, dimensionKey set)`; `isChecked`, `checkedAt`, `noteToSelf`,
`destinationLocation` and `priceCents` carry across. `isManual` lines always survive
(paper towels are in no recipe). The result is shown as a **diff sheet**: "3 new, 1 no
longer needed, 2 changed quantity." Silently resurrecting a checked-off line is the bug
this prevents.

**The trip home.** `InventoryLedger.receive(list:)` walks `isChecked` lines, creates a
`StockLot` at `destinationLocation ?? item.defaultLocation` with `original` = the
**purchase** quantity, sets `expiresAt` from the location's `defaultShelfLifeDays`, and
appends a `.purchase` `InventoryTransaction` carrying `priceCents`. Cost-per-meal
reporting falls out of this later with no schema change.

**And out again.** `CookingService.finish(...)` flattens at the scale actually cooked,
calls `InventoryLedger.lotsForDepletion` per item, writes `.cookDepletion` transactions,
updates the declared caches and sets the meal `.cooked`. A depletion needing an absent
density bridge is **written** with `hasDelta == false` and
`resolutionState == .pendingBridge`, landing in the "Unresolved depletions" inbox. The
ledger never silently guesses and never silently skips.

### 4.3 Worked examples

**(a) `2 tbsp + 1/4 cup` of the same item — the test written first.**

| | |
|---|---|
| `2 tbsp` | `2 x 3 = 6` tsp |
| `1/4 cup` | `1/4 x 48 = 12` tsp |
| sum | **`18` tsp**, exactly |
| hint | tbsp and cup each used by one line → tie → **finer wins** → `tbsp` |
| rule (a) | `18 / 3 = 6`, and `6 ∈ [1/4, 64)` → **`6 tbsp`** |

Never `5.9999`, and never `3/8 cup`. It is also never **`3 fl oz`**, even though 18 tsp
is exactly that, because `floz.isHouseholdCommon == false` keeps it out of
`displayCandidates` entirely. If every source line *had* said cups, the hint would be
`cup`, `18/48 = 1/4` is still `>= 1/4`, and the answer would be `1/4 cup` — which is
correct, because that is the unit he writes in.

With no hint at all, rule (b) walks `[quart 192, pint 96, cup 48, tbsp 3, tsp 1]`:
quart/pint/cup all give `< 1`, tbsp gives `6` with denominator `1` → `6 tbsp`. Same
answer by a different road.

**The fixture's own cases, which come out of the same code:**

| Ingredient | Lines | Base | Result |
|---|---|---|---|
| butter | `1 tbsp` (crostini and steak) + `1 tbsp` (creamed spinach) | `3 + 3 = 6` tsp | **`2 tbsp`** |
| kosher salt | `1 tsp` (steak) + `1/4 tsp` (spinach) | `1 + 1/4 = 5/4` tsp | **`1¼ tsp`**, shown in the staples footer |

One recipe, planned once, already produces one butter line and one salt line. Any
implementation that only de-duplicates *across* recipes fails here.

**(b) `1 cup flour + 200 g flour`.**

*Without a density* (`hasDensity == false`) — the honest answer:

```
volume bucket : 48 tsp     -> hint cup -> 48/48 = 1          -> "1 cup"
mass   bucket : 200 g      -> hint g, 200 >= 64 so (a) fails
                              (b) lb: 200/(2268/5) = 250/567 < 1   skip
                                  oz: 200/(567/20) = 4000/567, denominator 567 > 8
                                      -> step one finer
                                  g : 200/1 = 200, denominator 1    -> "200 g"
```

One line, two subtotals, `status = .needsBridge`:

> **Flour** — need **1 cup + 200 g** · ⚠ needs weight per cup
> *"These are the same — 1 cup of flour is ___ g"*

It looks slightly unfinished and it is also the truth. The alternative is inventing a
conversion, and `1 cup = 240 g` is right for water, off by ~2× for flour and ~1.4× for
honey — wrong **silently**, inside the number he is about to shop by. A list that admits
what it does not know is strictly better than one that lies confidently, and the inline
fix means each ingredient costs one tap once.

*With `gramsPerCup = 120`:*

```
gramsPerTsp = 120/48 = 5/2
total       = 200 + 48 x 5/2 = 200 + 120 = 320 g
display     -> "320 g"
conversionNote (on THAT subtotal): "1 cup counted as 120 g at 120 g per cup"
```

One subtotal, `flags = [.converted]`. Note the conversion note rides with the **specific
number that was converted**, which a line-level `secondaryText` string cannot express.

*Now subtract inventory.* Suppose one unopened 1 lb bag:

- **With** the density: `have = 453.6 g`, `toBuy = max(0, 320 - 453.6) = 0` →
  `status = .haveEnough`, collapsed under "Already have".
- **Without** it: the mass bucket covers (`200 - 453.6 → 0`), but the **volume** bucket
  has no matching stock dimension and no bridge, so `needed = 1 cup` and
  `.needsBridge` is flagged. It reads *"Flour — need 1 cup · have 1 lb · buy 1 cup ⚠"*.
  Honest, mildly annoying, and fixed forever by one tap. Buying a duplicate bag of flour
  is a far cheaper error than arriving at dinner without it.

**(c) The 240 mL carton, which the conversion table exists for.**

`3 tbsp heavy cream = 9 tsp`. A 240 mL carton in the fridge is `240 x 1/5 = 48 tsp`.
`toBuy = max(0, 9 - 48) = 0`. Covered, exactly. Had the requirement been `1 cup`, it
would be `48 - 48 = 0` — also exactly.

With SI-exact factors (`1 cup = 236.588 mL`) the carton is `236.588... ` worth of
teaspoons, the subtraction leaves a `3.41 mL` residue, nothing in
`max(0, required - onHand)` has an epsilon, and the shopping list grows a spurious
**"1 tsp heavy cream"** line. That single line is why this spec uses culinary factors.

**(d) Garlic across two meals, and the fixture's baguette.**

`2 cloves` (steak group) + `1 clove` (another meal) + `1 head` (a third):

- Buckets: `count:clove = 3`, `count:head = 1`. **Never summed to 4** — the noun is in
  the dimension key.
- Seed gives garlic `clove → 1/10 head` and `head → 50 g`. Pass 1 folds clove into head:
  `3/10 + 1 = 13/10 heads` → *"1 3/10 heads"*.
- Purchase pack `1 head` → `ceil(13/10) = 2` → **"need 1 3/10 heads, buy 2 heads"**.

The fixture's `12 slices baguette` with `slice → 1/12 loaf` folds to exactly **1 loaf**,
which is what finally lets it shop as *"1 baguette"* rather than *"12 slices baguette"*.
If only *some* nouns have an equivalence, nothing collapses and the line reads
*"3 cloves + 1 head"* — more useful to a shopper than *"3 cloves + 50 g"*.

**(e) Why Tuesday's leftovers buy nothing.**

Sunday dinner: ragù, 4 attending, `plannedLeftoverServings = 2` → `portions = 6`,
`scale = 6/4 = 3/2`, note `.leftoversIncluded`. Tuesday: a `PlannedMeal` with
`kind == .leftovers` and `leftoversFrom == Sunday`. `contributesToShopping` is `false`
**by kind**, so it is dropped in step 1 — and it is still rendered on the calendar as
planned leftovers with a link to its source, because it was never marked skipped.

Sunday's `servingsCooked` is drawn down by its `leftoverMeals`, which is what lets the
week brief say *"you are a portion short Tuesday"*. The mutually exclusive alternative
is `.leftoversOnly` attendance **at Sunday**, for "Sarah will take a plate to work" with
no calendar entry; the editor refuses both for the same person against the same source,
because allowing both double-counts a portion.

---

## 5. Service layer

Pure `enum` namespaces (`RecipeGraph`, `MealScaling`, `ShoppingListBuilder`,
`QuantityMath`, `PDFPaginator`, the parsers, `CalendarKey`, `NameNormalizer`,
`MealPlanStats`, `WeekBriefBuilder`) take what the caller has and return a value. They
are covered in §3 and §4. The `@Observable` classes below are held as `@State` on
`KitchenApp` and injected with `.environment(...)`, CFAL3's pattern.

### 5.1 `FoodItemResolver`

```swift
@Observable
final class FoodItemResolver {
    /// The ONLY place a FoodItem is created. Nothing else may call
    /// `context.insert(FoodItem(...))` — not the parser, not the inventory editor,
    /// not a manual shopping line. This is the discipline that substitutes for the
    /// `@Attribute(.unique)` CloudKit forbids.
    func findOrCreate(name: String, createIfMissing: Bool = true, in context: ModelContext) throws -> FoodItem?

    /// Adds a `FoodItemAlias` row and reindexes `aliasBlob`.
    func addAlias(_ text: String, to item: FoodItem, in context: ModelContext)

    /// Rebuilds `aliasBlob` from the rows. The rows are truth; the blob is the
    /// predicate-queryable cache.
    func reindex(_ item: FoodItem)

    /// Runs on launch and after every remote-change notification.
    @discardableResult
    func reconcile(in context: ModelContext) throws -> [MergeRecord]

    func merge(_ losers: [FoodItem], into survivor: FoodItem, in context: ModelContext) throws -> MergeRecord

    /// Refuses an item with lots or transactions and returns a reason, so the caller
    /// offers "merge into…" instead. The SCHEMA already guarantees no history is
    /// destroyed (`.nullify`); this is the courteous layer on top.
    func canDelete(_ item: FoodItem) -> Result<Void, DeleteRefusal>
}
```

Lookup is `#Predicate<FoodItem> { $0.matchKey == key }` with `fetchLimit = 1`, then a
fallback on `$0.aliasBlob.contains("|\(key)|")`. `matchKey` and `aliasBlob` are
**stored** precisely so they are predicate-queryable: a computed property cannot appear
in a `#Predicate`, and a stored `[String]` is a blob predicates cannot see into.

`NameNormalizer.matchKey(_:)`: lowercase, strip diacritics and punctuation, collapse
whitespace, drop a leading article, drop parentheticals and trailing prep qualifiers
(`, chopped`, `, divided`, `(optional)`), then a conservative singularizer (`-ies→y`,
`-oes→o`, `-s→∅`) with a stoplist for `asparagus`, `couscous`, `molasses`, `greens`,
`hummus`. Deliberately **not** a stemmer — over-normalizing collides
`butter`/`buttermilk`.

Normalization cannot solve synonymy, so it does not try. "Scallion" vs "green onion"
is a `FoodItemAlias` row, added by a one-tap "same as…" from any unresolved line. There
is no built-in synonym dictionary; his vocabulary is his.

**The merge survivor is deterministic, and that is a convergence requirement rather
than a preference:**

1. Group all items by `matchKey`, **including every alias key**.
2. For each group of more than one, pick the survivor: **earliest `createdAt`,
   tie-broken by lowest `id.uuidString`.** Never a "best row" heuristic such as
   most-lots or longest-notes — two devices must pick the **same** survivor with no
   coordination, or the merge ping-pongs forever.
3. Repoint every referrer (`ingredientLines`, `lots`, `transactions`, `shoppingLines`,
   `restrictions`), union the alias and count-equivalence rows, fill the survivor's
   absent scalars from the losers, reindex, delete the losers.
4. Write a `MergeRecord`, so Settings can report "merged 3 duplicates" instead of
   mutating his data mutely.

Step 3 is why Kitchen uses a real relationship graph where CFAL3 used UUID strings:
merging requires **enumerating referrers**, which with inverses is four array reads and
with `foodItemID: UUID?` is a full-store scan on every launch forever.

`MergeFoodItemsView` in Settings also offers a manual merge. Both exist: the manual
screen is better UX, the deterministic rule is what converges.

### 5.2 `InventoryLedger`

```swift
@Observable
final class InventoryLedger {
    /// Holds the container, because `level(of:)` runs on every shopping-list build and
    /// every recipe detail render and therefore needs a context on the hot path. This
    /// is the one service that must state where its context comes from.
    init(container: ModelContainer)

    /// Sums the item's TRANSACTIONS, not its lots. An orphaned transaction
    /// (`lot == nil`) still contributes, into an explicit "unassigned lot" bucket, so
    /// a deleted lot cannot create a divergence that is never attributable.
    func level(of item: FoodItem, in location: StorageLocation? = nil,
               includeExpired: Bool = false, asOf: Date = .now) -> [QuantityMath.Subtotal]

    /// FIFO by `expiresAt` then `acquiredAt`, PREFERRING an already-opened lot (you
    /// finish the open butter before cutting a new stick) and preferring lots whose
    /// dimension matches the request so no bridge is needed.
    func lotsForDepletion(_ item: FoodItem, needed: Quantity) -> [(StockLot, Quantity)]

    func apply(kind: TransactionKind, delta: Quantity?, to item: FoodItem,
               lot: StockLot?, meal: PlannedMeal?, cookLog: CookLogEntry?,
               note: String, in context: ModelContext) -> InventoryTransaction

    /// Posts the PURCHASE quantity, not the pre-rounding need. Restocking what the
    /// recipe needed drifts tracked stock monotonically to zero.
    func receive(_ list: ShoppingList, in context: ModelContext) throws

    func recompute(lot: StockLot)
    func rebuildAllCaches(in context: ModelContext) throws

    /// Surfaces cache-versus-ledger divergence rather than hiding it, per lot and per
    /// item, including the unassigned bucket.
    func reconcileReport(in context: ModelContext) throws -> [LedgerDivergence]

    func expiringSoon(within days: Int, in context: ModelContext) throws -> [StockLot]
    func pendingBridgeTransactions(in context: ModelContext) throws -> [InventoryTransaction]
    func resolve(_ tx: InventoryTransaction, withDelta: Quantity, in context: ModelContext)
}
```

The `.pendingBridge` inbox, the reconcile screen and the ingredient inbox are three
standing queues for one busy cook, and that is a real cost — once the ledger goes stale,
`subtractInventory` silently produces a wrong shopping list, which is worse than having
no inventory feature. Three mitigations, all required:

1. `StockTrackingMode.staple` means he never has to inventory his salt, which is the
   bulk of what would otherwise fill the queues.
2. The inbox counts are shown as **badges on the Pantry tab**, not buried in Settings,
   so they are visible without being modal.
3. `KitchenMaintenance.rebuildLotCaches` and `FoodItemResolver.reconcile` run on launch
   and on remote-change notifications, so the repairs actually run rather than waiting
   for him to visit a screen he has no reason to open.

### 5.3 The rest

| Service | Responsibilities and public API |
|---|---|
| `MealPlanService` | `meals(in:)`, `mealsByDayKey(in:)`, `plan(recipe:on:slot:attendees:)`, `planEntry(kind:title:on:slot:)`, `move(_:to:slot:index:)`, `duplicate(_:to:)`, `copyWeek(from:to:)`, `makeLeftovers(of:on:slot:servings:)`, `setAttendance(_:for:on:)`, `addGuest(named:to:portion:)`, `applyAttendanceDefaults(to:)`. Owns the "exactly one leftovers path" validation. |
| `CookingService` | `begin(recipe:scale:meal:)`, `finish(session:rating:notes:changes:photo:depleteInventory:)`. The SINGLE writer of `Recipe.cookCount` and `lastCookedAt`, the writer of `CookLogEntry`, and the caller of the depletion path. Also `foldChangesIntoRecipe(_:)`. |
| `CookSession` | View state for the stove: `recipe`, `scale` (view state, **never** a mutation of the recipe — cooking a double batch must not silently rewrite the recipe to serve 8 forever), `completedStepIDs`, `timers: [CookTimer]`, `elapsed`. |
| `DietGuard` | `warnings(for:)`, `warnings(in:)`. Each `Warning` carries `id` (stable: restriction id + item key + path), `eaterName`, `restrictionLabel`, `severity`, `offendingName`, `matchedVia` (`.itemLink` / `.alias` / `.keyword` / `.subRecipe`) and **`path: [String]`** — `["NY Strip Crostini", "Creamed horseradish spinach", "heavy cream"]`, so the resolution is "spinach on the side" rather than a cancelled dish. Sorted by `severity.sortIndex`. |
| `ShoppingListStore` | `materialize(draft:into:existing:)`, `regenerate(_:options:)`, `diff(_:against:)`, `addManualLine(_:to:)`, `drop(meal:from:)` (which uses the live `ShoppingListSource.plannedMeal` edges). |
| `ImportCoordinator` | Holds the pending `ParsedRecipe`. **Nothing is inserted until he confirms** in `ParseReviewView`: an auto-saving importer that gets a group boundary wrong writes garbage he has to find later. |
| `RecipeImportService` | `text(fromPDF:)` via `PDFDocument.string`, `.onOpenURL` document handling, hand-off to `RecipeTextParser`. The fixture arrives as a ReportLab PDF, and `scripts/import_recipe.py` is the reference implementation of the same rules — **when the Swift parser and the Python one disagree, the Python one is right**, because it has a test that runs. |
| `ExportCoordinator` | Render progress, the last PDF `URL` for `ShareLink`, temp-dir sweep on launch. |
| `AppPreferences(defaults:)` | Unit system, plan scope, last build options, default diner count. Reads `UITestMode.defaults`. Deliberately **not** synced — everything that must agree across devices is a row. |
| `KitchenSeed` | `applyIfNeeded(in:)`, `SeedRecord`-gated per key. |
| `KitchenMaintenance` | `recomputeCookStats(in:)`, `rebuildLotCaches(in:)`, `findDuplicateFoodItems(in:)`. Wired to `NSPersistentStoreRemoteChange` as well as a Settings button, because a repair nobody triggers is not a repair. |
| `KitchenRouter` | Selected tab, presented sheets, the cook-mode cover payload. |

### 5.4 `Kitchen/App/KitchenApp.swift`

Structurally CFAL3's `CFAL3App`: the `UITestMode` enum with its `static let` throwaway
suite (including the `-uitesting-preserve-defaults` escape hatch and the comment
explaining why it is a `let` and not a computed property), the `do/catch`
`ModelContainer` init with the in-memory fallback and `storeFailure`, services as
`@State` injected via `.environment`, and `.environment(\.storeUnavailable, storeFailure != nil)`
driving the banner.

Two additions beyond CFAL3:

```swift
let config = ModelConfiguration(
    schema: Schema(KitchenSchemaV1.models),
    isStoredInMemoryOnly: UITestMode.isActive,
    // Explicit, and commented, so the day the family wants sync is a one-line diff
    // next to an entitlement rather than an investigation. Everything in the schema
    // already obeys CloudKit's rules — no .unique, every property defaulted, every
    // relationship optional with an explicit inverse — so flipping this to
    // .private("iCloud.com.brandonkeeny.Kitchen") is a capability change, not a
    // reshape.
    cloudKitDatabase: .none
)
```

and the launch `.task`, in this order, because each step depends on the one before:

```swift
.task {
    ExportCoordinator.sweepTemporaryFiles()
    try? KitchenSeed.applyIfNeeded(in: container.mainContext)
    try? resolver.reconcile(in: container.mainContext)        // aliases collapse first
    try? ledger.rebuildAllCaches(in: container.mainContext)   // then caches are rebuilt
    KitchenMaintenance.recomputeCookStats(in: container.mainContext)
}
```

Build settings: `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, `SWIFT_VERSION = 5.0`,
`LastUpgradeCheck = 2700`, `TARGETED_DEVICE_FAMILY = "1,2"`,
`PRODUCT_BUNDLE_IDENTIFIER = com.brandonkeeny.Kitchen`,
`DEVELOPMENT_TEAM = HHSFT2GD2H`. No `Config/Secrets.xcconfig` equivalent — nothing in
this app has a key.

---

## 6. Screen-by-screen view tree

Six tabs via `RootTabView` + `AppTab` with a test-addressable `identifier`, copying
`CFAL3/Views/Root/RootTabView.swift`. **Recipes is first and is the default tab** — the
library is the asset that compounds over ten years, and plan, shop and pantry are views
over it.

```
KitchenApp                                         Kitchen/App/KitchenApp.swift
└── RootTabView  (Theme.tint, StoreFailureBanner via \.storeUnavailable,
                  CookModeView as a fullScreenCover, SettingsView as a sheet)
    │
    ├── Recipes ───────────────────────────────── the heart
    │   ├── RecipeLibraryView            Recipe                       RecipeLibraryView.swift
    │   │   ├── RecipeCardRow            Recipe, CookLogEntry         RecipeCardRow.swift
    │   │   └── RecipeFilterSheet        RecipeTag                    RecipeFilterSheet.swift
    │   ├── RecipeDetailView             Recipe, RecipeComponent,     RecipeDetailView.swift
    │   │   │                            IngredientLine, RecipeStep,
    │   │   │                            RecipeNote, StockLot
    │   │   ├── ComponentSectionView     RecipeComponent              ComponentSectionView.swift
    │   │   ├── IngredientLineRow        IngredientLine, FoodItem     IngredientLineRow.swift
    │   │   ├── RecipeMethodView         RecipeStep                   RecipeMethodView.swift
    │   │   ├── RecipeNotesSection       RecipeNote                   RecipeNotesSection.swift
    │   │   └── RecipeUsageSection       RecipeComponent,             RecipeUsageSection.swift
    │   │                                IngredientLine
    │   ├── RecipeEditorView             all of the above             RecipeEditorView.swift
    │   │   ├── ComponentEditorSection   RecipeComponent              ComponentEditorSection.swift
    │   │   ├── IngredientLineEditor     IngredientLine, FoodItem     IngredientLineEditor.swift
    │   │   └── StepEditorRow            RecipeStep, RecipeComponent  StepEditorRow.swift
    │   ├── PasteImportView              (none — values only)         PasteImportView.swift
    │   │   └── ParseReviewView          (none until confirmed)       ParseReviewView.swift
    │   ├── IngredientInboxView          IngredientLine, FoodItem     IngredientInboxView.swift
    │   └── CookLogView                  CookLogEntry                 CookLogView.swift
    │
    ├── Plan ──────────────────────────────────── phone-shaped by default
    │   ├── PlanRootView                 (scope switch)               PlanRootView.swift
    │   ├── WeekBriefView                PlannedMeal, MealAttendance, WeekBriefView.swift
    │   │                                Recipe, StockLot
    │   ├── MonthCalendarView            PlannedMeal                  MonthCalendarView.swift
    │   │   └── MonthDayCell             PlannedMeal, MealAttendance  MonthDayCell.swift
    │   ├── WeekGridView   [iPad only]   PlannedMeal                  WeekGridView.swift
    │   ├── DayPlanView                  PlannedMeal, MealRecipe      DayPlanView.swift
    │   ├── PlannedMealEditorSheet       PlannedMeal, MealRecipe,     PlannedMealEditorSheet.swift
    │   │   │                            MealAttendance, Eater, Recipe
    │   │   ├── AttendanceGrid           MealAttendance, Eater        AttendanceGrid.swift
    │   │   └── DietWarningBanner        DietaryRestriction,          DietWarningBanner.swift
    │   │                                AcknowledgedWarning
    │   └── DuplicateWeekSheet           PlannedMeal                  DuplicateWeekSheet.swift
    │
    ├── Shop
    │   ├── ShoppingListsView            ShoppingList                 ShoppingListsView.swift
    │   ├── GenerateShoppingListSheet    PlannedMeal, Store           GenerateShoppingListSheet.swift
    │   ├── ShoppingListDetailView       ShoppingList,                ShoppingListDetailView.swift
    │   │   │                            ShoppingListLine
    │   │   └── ShoppingListLineRow      ShoppingListLineSubtotal     ShoppingListLineRow.swift
    │   ├── ShoppingLineDetailSheet      ShoppingListSource, FoodItem ShoppingLineDetailSheet.swift
    │   ├── RegenerateDiffSheet          ShoppingListLine             RegenerateDiffSheet.swift
    │   └── ReceiveIntoInventorySheet    ShoppingListLine, StockLot   ReceiveIntoInventorySheet.swift
    │
    ├── Pantry
    │   ├── InventoryHomeView            StorageLocation, StockLot    InventoryHomeView.swift
    │   ├── LocationDetailView           StockLot                     LocationDetailView.swift
    │   ├── FoodItemDetailView           FoodItem, StockLot,          FoodItemDetailView.swift
    │   │                                InventoryTransaction,
    │   │                                FoodItemAlias, CountEquivalence
    │   ├── QuickAddStockView            FoodItem, StockLot           QuickAddStockView.swift
    │   ├── InventoryCountView           StockLot, InventoryTransaction InventoryCountView.swift
    │   ├── UnresolvedDepletionsView     InventoryTransaction         UnresolvedDepletionsView.swift
    │   └── ExpiringSoonView             StockLot                     ExpiringSoonView.swift
    │
    ├── Cook  (fullScreenCover, not a tab — CFAL3's "a sitting is a cover" rule)
    │   ├── MiseEnPlaceView              Recipe, RecipeComponent      MiseEnPlaceView.swift
    │   ├── CookStepList                 RecipeStep                   CookStepList.swift
    │   ├── CookIngredientHeader         IngredientLine               CookIngredientHeader.swift
    │   ├── CookTimerBar                 (CookSession)                CookTimerBar.swift
    │   └── CookFinishSheet              CookLogEntry, StockLot       CookFinishSheet.swift
    │
    └── Settings  (sheet)
        ├── HouseholdView                Eater                        HouseholdView.swift
        ├── AttendanceDefaultsView       AttendanceDefault            AttendanceDefaultsView.swift
        ├── RestrictionEditorView        DietaryRestriction,          RestrictionEditorView.swift
        │                                DietaryKeyword
        ├── StoreLayoutView              Store, StoreSection          StoreLayoutView.swift
        ├── StorageLocationsView         StorageLocation              StorageLocationsView.swift
        ├── FoodItemCatalogView          FoodItem, CountEquivalence   FoodItemCatalogView.swift
        ├── MergeFoodItemsView           FoodItem, MergeRecord        MergeFoodItemsView.swift
        ├── ReconcileView                StockLot,                    ReconcileView.swift
        │                                InventoryTransaction
        ├── UnitPreferenceView           (AppPreferences)             UnitPreferenceView.swift
        ├── ExportView                   (ExportCoordinator)          ExportView.swift
        └── StoreHealthView              SeedRecord, MergeRecord      StoreHealthView.swift
```

### 6.1 Three interactions that are specified, not left to taste

**`AttendanceGrid`.** One chip per active `Eater`. A **single tap cycles**
attending → away → maybe → leftoversOnly. A **long-press** opens a portion stepper and
a plate note. A four-person dinner is four taps with no sheet, and attendance stops
being the thing that makes planning feel like data entry. Combined with
`AttendanceDefaultsView` ("Sarah is never home Thursdays", applied at meal creation),
steady-state attendance costs **zero** taps and "who is eating" only becomes work on an
exceptional night.

**Plan's landing content is `WeekBriefView` on iPhone.** A 7-column × 8-slot-row grid of
drop targets does not fit on a phone, and the primary surface here is an iPhone propped
against the backsplash. The brief reads: *"14 dinners planned, 3 takeout, Sarah away
Thu–Fri, 2 warnings, 1 recipe you have never cooked, 3 things expiring."* `WeekGridView`
— the dense grid — is **iPad only**, gated in `AdaptiveLayout`. `MonthCalendarView` uses
`.scrollTargetBehavior(.viewAligned)` month paging.

**Drag and drop** uses `RecipeTransfer` / `PlannedMealTransfer`: `Codable + Transferable`
structs carrying only an id and a title, a custom `UTType`, and
`ProxyRepresentation(exporting: \.title)` so a drop into Notes yields text. **Never a
`@Model` in a drag payload** — it is neither reliably `Codable` nor `Sendable`, and the
failure is a crash mid-drag rather than a compile error.

### 6.2 Cook mode, because it is where the app earns its keep

- `isIdleTimerDisabled = true` and `.persistentSystemOverlays(.hidden)`. The screen must
  not sleep with his hands in a bowl.
- 20pt minimum body scaling all the way up; **60pt minimum tap targets**, not 44 — wet
  fingers miss.
- **`MiseEnPlaceView` first**: every group's ingredients at the chosen scale, make-ahead
  items called out at the top. What you actually read before you start.
- Then the **flat method**, one step per row, the whole row the checkbox, completed steps
  dimmed but still on screen — you look back constantly. Each step shows a small pill for
  its tagged group when it has one.
- A **sticky header** carrying the scaled quantities for the group the current step
  touches, so he never leaves the step he is on to re-read how much butter.
- **Scaling on the fly**: ½× / 1× / 1½× / 2× / custom, recomputing every displayed
  quantity through `Quantity.scaled(by:)`. The scale is **view state on `CookSession`,
  never a mutation of the recipe.** Cooking a double batch must not silently rewrite the
  recipe to serve 8 forever. (Comment-worthy: it is the obvious implementation and it is
  wrong.)
- **Concurrent timers** from `RecipeStep.minMinutes/maxMinutes`, as tappable chips, timing
  the **longer** end of a range so a timer never fires early. `UNUserNotificationCenter`
  so a backgrounded app still rings. A three-component plated dish cooks three things at
  once; this is the highest-value feature in the app.
- **`CookFinishSheet`** is the capture moment the whole project is premised on: the
  measured duration (so the recipe's claimed 35 active minutes becomes the real 55 after
  five cooks), rating, notes, photo, *"fold these changes into the recipe?"*, and the
  inventory-depletion confirm.
- Nothing in cook mode can fail: no network, no spinner, no async load. Everything it
  needs is in the store before it opens.

---

## 7. PDF export

```swift
enum PDFExportService {
    enum Job {
        case recipe(Recipe, scale: Rational)
        case shoppingList(ShoppingList)
        case weekPlan(interval: DateInterval, meals: [PlannedMeal], eaters: [Eater])
        case inventorySnapshot(location: StorageLocation?)
    }
    @MainActor static func render(_ job: Job) throws -> URL
}
```

**Vector, not a screenshot.** `ImageRenderer`'s `render` closure hands a
`CGContext`-drawing block; drive it into a `CGContext(consumer:mediaBox:)`:

```swift
enum PDFPageWriter {
    @MainActor
    static func write<Page: View>(pages: [Page], size: CGSize, to url: URL) throws {
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw ExportError.contextUnavailable }
        for page in pages {
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(size)
            // The CGContext closure keeps text as VECTOR TEXT — selectable, searchable,
            // sharp when printed. `renderer.uiImage` gives a rasterized, unsearchable,
            // blurry-on-print page, which is what a quick implementation produces.
            renderer.render { _, draw in
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
    }
}
```

**Two hard constraints, both as comments in the files:**

1. **No `List`, no `ScrollView`, no `LazyVStack`, no `LazyVGrid` anywhere inside a view
   handed to `ImageRenderer`.** It renders only laid-out content, and anything lazy
   silently renders empty or clipped. Print pages are plain `VStack`/`HStack`/`Grid`.
2. **Pagination packs whole measured sections, it does not slice.** `PDFPaginator`
   measures each section's ideal height and assigns whole sections to pages, repeating
   section heads with "(cont.)". Slicing one tall rendered image at 792pt boundaries cuts
   text through the middle of a line, and a fixed rows-per-page estimate clips.

**The three documents, specified line by line because this is the artefact that leaves
the device:**

- **`MealPlanWeekPrintPage`** — landscape 792×612. A 7-column week grid; each day lists
  slot · title · a row of member-initial chips in each member's colour, with glyphs for
  leftovers / takeout / prep and a small triangle where a diet warning sits. A **member
  chip legend across the footer**, and "Kitchen · Nov 3–9 · generated Oct 31".
- **`PrepAheadPrintPage`** — its own page: every `.prep` entry and every
  `Recipe.makeAheadNote` in the range, in date order. This is how "salt the steaks the
  night before" survives, and the fixture needs it twice (step 1's 30-minute rest, and
  the note that the spinach can be made a day ahead).
- **`MealPlanHeadCountPrintPage`** — head count per day per meal, **its own page**,
  because that is the page that gets texted to whoever is cooking.
- **`ShoppingListPrintPage`** — portrait 612×792, **two columns**, grouped by section
  with a **hairline rule under each head**; a **stroked rounded-rect checkbox drawn as a
  glyph**, not an emoji; quantities **right-aligned in `.monospacedDigit()`**; `have` in
  `Theme.dust` beside `toBuy` in `Theme.ink`; and a **superscript marker per line** keyed
  to a closing `ShoppingSourcesPrintBlock` — "Meals this list covers".
- **`RecipePrintPage`** — ingredients in a left column grouped by component, the **flat
  method** in a right column, notes as a footer. Which is how the NY Strip sheet actually
  reads.

Serif headers via `Theme.serif(_:weight:)`, matching CFAL3's voice.

**Sharing is `ShareLink`, and only `ShareLink`.**

```swift
ShareLink(item: url,
          preview: SharePreview(filename, image: Image(systemName: "doc.richtext")))
```

It reaches Mail, Messages, AirDrop and Files, needs no entitlement, no key and no
account, and nothing leaves the device unless he taps share. `MFMailComposeViewController`
would add UIKit plumbing and buy nothing. **Worth a comment in `ExportView` so nobody
"improves" it into an SMTP client.**

Files are written to `FileManager.default.temporaryDirectory` with a **human filename**,
because that string becomes the mail attachment name:

```
Kitchen - Shopping list, Nov 3-9.pdf
Kitchen - Week of Nov 3.pdf
Kitchen - NY Strip Crostini.pdf
```

`Transferable` conformance too, so drag-out works on iPad. `PDFPreviewView` wraps
`PDFView` in a `UIViewRepresentable`, reusing `CFAL3/Views/Review/MMPDFReader.swift`'s
shape **including the `@unchecked Sendable` box around the non-`Sendable`
`PDFDocument`**.

---

## 8. Seeded sample data

`KitchenSeed` is `SeedRecord`-gated per key, so re-running is idempotent without
`.unique`.

| Seed key | Contents |
|---|---|
| `sections.v1` | One `Store` ("Default", `isDefault`) with `StoreSection` rows in walk order: Produce, Butcher, Seafood, Deli, Bakery, Dairy, Eggs, Frozen, Pantry (dry), Canned & jarred, Spices, Condiments, Baking, Beverages, Wine & beer, Household, Unsorted. |
| `locations.v1` | `StorageLocation` rows: Pantry, Fridge (`defaultShelfLifeDays: 7`), Freezer (90), Spice rack, Bar. |
| `foodItems.v1` | ~150 common items with `defaultSection`, `defaultLocation`, `trackingMode`, and the bridges that matter: `gramsPerCup` for flour (120), sugar (200), butter (227), heavy cream (240), water (240); `CountEquivalence` rows for garlic (`clove → 1/10 head`, `head → 50 g`), eggs (`each → 50 g`), baguette (`slice → 1/12 loaf`), butter (`stick → 113 g`), lemon (`each → 3 tbsp` juice). Salt, pepper, olive oil, neutral oil, flour and sugar are `.staple`. |
| `recipe.nyStrip.v1` | The fixture, below. |

### 8.1 The fixture's shape

`docs/fixture-recipe-01.txt` is the full text and
`scripts/import_recipe.py` already produces exactly this tree, so **the seed runs the
same parser rather than hand-building the graph in code**. Building it in code is what
lets a schema pass a test that the real capture path would fail.

```
Recipe
  title                "NY Strip Crostini with Creamed Horseradish Spinach"
  summary              "Crisp baguette, warm creamed horseradish spinach, and thin
                        slices of seared NY strip."
  yieldText            "12 crostini (serves 4)"
  servings             4 / 1            <- the ONLY scaling divisor
  hasYieldQuantity     true
  yieldQuantity        12 / 1
  yieldUnitLabel       "crostini"       <- display; scales to "18 crostini" at x1.5
  activeMinutes        35
  totalMinutes         70
  timesAreApproximate  true             <- both document values say "About"
  batchGranularity     .continuous
  makeAheadNote        pulled from note[0]; the note ROW is kept

  components (3 — ingredient GROUPS, each owning lines and NO steps)
  ┌ 0  "Crostini and steak"        .protein
  │     12 slice   baguette                 prep "1/2 inch thick"      count:slice
  │      3 tbsp    olive oil                                           volume
  │     16 oz      NY strip steak           prep "about 1.25 in thick" MASS, confirmed
  │      1 tsp     kosher salt                                         volume   [staple]
  │    1/2 tsp     black pepper                                        volume   [staple]
  │      1 tbsp    butter                                              volume
  │      2 clove   garlic                   prep "smashed"             count:clove
  ├ 1  "Creamed horseradish spinach"  .side
  │     10 oz      baby spinach                                        MASS, confirmed
  │      1 each    shallot                  prep "minced"              count:each
  │      1 tbsp    butter                                              volume
  │      4 oz      cream cheese                                        MASS, confirmed
  │      3 tbsp    heavy cream                                         volume
  │      3 tbsp    prepared horseradish     prep "drained"             volume
  │      2 tbsp    Parmesan                 prep "grated"              volume
  │      1 tsp     lemon juice                                         volume
  │    1/4 tsp     kosher salt                                         volume   [staple]
  └ 2  "To finish"                   .finish
        1 tbsp    fresh chives             prep "finely chopped"       volume
        (nil)     flaky salt               unmeasuredNote "Pinch"      NO QUANTITY

  steps (8 — FLAT, recipe-ordered, interleaving the groups)
    1  "Season the steak"      30/30 min   component -> [0]   isPassiveRest
    2  "Toast the baguette"     9/9  min   component -> [0]   ovenTemperatureF 400
    3  "Sear the steak"         7/8  min   component -> [0]   targetInternal 125
    4  "Rest the steak"         9/9  min   component -> [0]   isPassiveRest
    5  "Wilt the spinach"       5/5  min   component -> [1]
    6  "Make the creamed spinach" 2/2 min  component -> [1]
    7  "Slice the steak"       nil/nil     component -> [0]
    8  "Assemble"              nil/nil     component -> nil   (the whole dish)

  notes (4 rows, ordered, each its own idea)
    0  .makeAhead  "The spinach can be made a day ahead and gently rewarmed…"
    1  .keyStep    "Squeezing the spinach dry is the key step…"
    2  .variation  "For a sharper bite, stir a little extra horseradish…"
    3  .timing     "Toast the baguette just before serving so it stays crisp."
```

**What this one recipe proves, and therefore what the tests assert:**

| Claim | Evidence in the seed |
|---|---|
| Ingredients group, steps are flat | 3 components, 8 recipe-owned steps interleaving them (2 → 3 → 5 → 8) |
| Both yields are needed | `servings 4` and `yieldQuantity 12 crostini`; scaling divides by 4 |
| Both times are needed | 35 active vs 70 total, the gap explained by step 1's passive rest |
| Durations are optional, and sometimes a range | step 3 is 7–8; steps 7 and 8 are `nil`/`nil`, not `0` |
| Two temperatures, two fields | step 2's oven 400F and step 3's internal 125F |
| Quantities are optional | `Pinch flaky salt` → `quantity == nil`, `unmeasuredNote "Pinch"` |
| `oz` is weight here, three times | all three `.mass` with `dimensionConfirmed == true` |
| Name and preparation split | `shallot` / `minced`, `garlic` / `smashed`, and **`Parmesan` / `grated` where the adjective comes FIRST** — which every comma-splitting parser gets wrong, and which `rawText` makes recoverable |
| A recipe aggregates against ITSELF | butter `1 tbsp + 1 tbsp = 2 tbsp`; kosher salt `1 tsp + 1/4 tsp = 1 1/4 tsp` **through the staple path** |
| Count units with no volume equivalent | `slice`, `clove`, `each` — each its own merge bucket |
| Notes are a list | four rows with four different kinds |
| Length is not a quantity | `1/2 inch thick` and `about 1.25 inches thick` live in `preparation` |

Planned for Saturday dinner with 2 residents + 2 full-portion guests → `portions = 4`,
`servings = 4`, `scale = 1`. For six eaters → `scale = 3/2`, the display yield reads
**18 crostini**, butter totals `3 tbsp`, and a `.prep` entry lands on Friday carrying
"salt the steaks, uncovered in the fridge" from step 1. If a guest has a dairy
restriction, `DietGuard` reports
`path: ["NY Strip Crostini…", "Creamed horseradish spinach", "heavy cream"]` — so the
answer is a side plate, not a cancelled dinner.

---

## 9. Deliberately NOT in v1

Each of these is **designed for** rather than built. Check this list before assuming one
needs a migration.

| Deferred | Status in the schema, and what turning it on costs |
|---|---|
| **CloudKit sync** | Every rule in §0.2 is already obeyed. `cloudKitDatabase: .none` → `.private("iCloud.com.brandonkeeny.Kitchen")` plus the entitlement. **No schema change.** This is the whole reason for the no-`.unique`, all-defaulted, all-optional-with-inverses discipline, and for the ledger. |
| **OCR / photo recipe import** | `RecipeImportService` already has the PDF and paste paths, and both feed one `RecipeTextParser` and one `ParseReviewView`. OCR is a third `text(from:)` source via on-device `VNRecognizeTextRequest` — no network, no keys. Additive. |
| **A share extension target** | `.onOpenURL` plus the document type association covers "Open in Kitchen" from Files and Mail in v1. The extension is a new target, not a schema change. |
| **Nutrition data** | Needs a per-`FoodItem` nutrient table and a serving-size bridge. Additive: new models plus one `.nullify` edge from `FoodItem`. No existing row changes. |
| **Barcode scanning** | Additive: a `barcode: String` on `FoodItem` plus a scanner sheet feeding `QuickAddStockView`. |
| **Cost tracking and cost-per-meal** | `StockLot.unitCostCents`, `InventoryTransaction.priceCents` and `ShoppingListLine.priceCents` are **already stored**. Only the reporting views are missing. |
| **Substitutions** | A `Substitution` model (`from`, `to`, `ratio`, `note`) was specified and cut from v1. Additive, with `.nullify` edges both ways. |
| **Saved plan templates** | `PlanTemplate` + `PlanTemplateEntry` can be added without touching `PlannedMeal`, because there is no `MealPlan` container to retrofit. `DuplicateWeekSheet` covers the common case in v1. |
| **Per-store ingredient pricing / multiple stores in one trip** | `Store` and `StoreSection` are already rows; a `StoreItemPrice` join is additive. |
| **Apple Watch / widgets / Siri** | None of them change the store. |
| **A second unit system per-recipe** | `UnitSystem` is already on the unit table and threaded through display; only a per-recipe override field is missing. |

**Three things are deliberately NOT deferred, because they cannot be added later:**

1. **The inventory ledger** (§2.19). A scalar `onHand` cannot be upgraded to a
   transaction log, because the history was never recorded.
2. **Two yields on `Recipe`** (§2.2). Collapsing them at import and splitting them later
   cannot recover which number was which.
3. **`RecipeNote` rows and `RecipeStep.title`/`body`/`minMinutes`/`maxMinutes`** (§2.5,
   §2.6). Flattening four note bullets into a paragraph, or a range into one `Int`, is
   lossy at import and irreversible afterwards.

---

## 10. The three riskiest decisions

**1. Inventory is an append-only ledger with a per-lot cache, built on day one.**

*The risk.* It roughly doubles every write path and introduces a cache that can drift
from truth — a permanent class of bug this spec is choosing to own. It also creates three
standing chore queues (the ingredient inbox, the unresolved-depletions inbox, the
reconcile report) for one busy cook, and once the ledger goes stale `subtractInventory`
silently produces a wrong shopping list, which is **worse than having no inventory
feature at all**.

*Why anyway.* The alternative is broken under the sync he will certainly ask for: a
scalar decremented on two offline devices resolves field-level last-writer-wins and
**loses one decrement silently**, with no conflict handler possible, and the error
compounds forever. "Why does it think I have 3 lb of butter" has no answer without a
ledger. And retrofitting one in year two means inventing history that was never recorded
— this is the only part of the design that is genuinely not additive.

*Mitigations, all required.* `StockTrackingMode.staple` means he never inventories his
salt, which is most of what would fill the queues. The inbox counts are **badges on the
Pantry tab**, visible without being modal. `rebuildAllCaches` and `reconcile` run on
launch and on remote-change notifications, so the repairs actually run rather than
waiting for a Settings screen he has no reason to open. And `reconcileReport` **surfaces**
divergence instead of hiding it: a cache that reports its own drift is acceptable, a
cache that drifts silently is not.

**2. A hand-rolled `Rational` + `Quantity` instead of `Measurement`, persisted as flat
primitives.**

*The risk.* This spec is writing a numeric type. A bug in `Rational.+` is a bug in
literally every number the app displays. It forfeits `MeasurementFormatter`'s free
localization, and it accepts `Int` overflow as something that has to be designed against
rather than assumed away.

*Why anyway.* `Measurement` is `Double`-backed, so `1/3 cup × 3` is not `1 cup` and a
shopping list reads "0.333333 cups" on the first screen he opens. It is also **generic
over its dimension**, so one property cannot hold both "1/4 cup" and "2 cloves" — and an
ingredient list is heterogeneous by nature. `UnitVolume` has no `clove`, `bunch`,
`package` or `to taste`, which is most of how recipes are written. And any `Measurement`
in SwiftData needs a `Codable` wrapper anyway, so the "free" option was never free. A
custom type was mandatory regardless; given that, one well-tested type beats a
`Measurement` for some lines and something else for the rest.

*Mitigations.* gcd reduction after every operation and **gcd-first addition**, which is
the form that keeps the aggregation from reaching 1e19; overflow-reporting variants of
all four operators with a documented approximation fallback; **culinary conversion
factors whose denominators are all ≤ 20**, which makes overflow essentially unreachable
rather than merely guarded; `MeasurementFormatter` still used inside `displayString` for
metric; and flat-primitive persistence so a future change to `Rational` is not a custom
migration stage over every stored row. The first test files written are
`RationalTests`, `UnitCatalogTests` and `QuantityMathTests`, with the full US volume
ladder round-tripped.

**3. No cross-dimension conversion without per-item data — a mixed line shows N
numbers.**

*The risk.* The shopping list sometimes reads **"Flour — 1 cup + 200 g"** instead of one
tidy total. It looks unfinished, it looks like the app could not do the arithmetic, and
it is the thing a stranger would screenshot as a flaw. The same honesty produces
`.needsBridge` lines that over-buy on purpose, and a `.pendingBridge` depletion inbox
that is one more queue.

*Why anyway.* The alternative is **inventing** a conversion. `1 cup = 240 g` is correct
for water, off by ~2× for flour and ~1.4× for honey — and wrong *silently*, inside the
number he is about to shop by. A list that admits what it does not know is strictly
better than one that lies confidently, and trust is the only thing that keeps him using
this in year two. On the subtraction side the asymmetry is decisive: buying a duplicate
pound of butter is a far cheaper error than arriving at dinner without it, so an
unbridgeable requirement assumes **nothing** is on hand.

*Mitigation turns the flaw into the feature.* Every mixed line carries an inline *"these
are the same — 1 cup of flour is ___ g"*; one tap, one number, and every present and
future sum for flour resolves silently. `CountEquivalence` rows do the same for count
nouns, which is what makes "2 heads of garlic" and "1 baguette" possible at all. Within a
few months the dozen ingredients he genuinely measures both ways are all populated and
this stops happening. **The app learns his kitchen**, which is the right shape for a
project whose whole premise is that he keeps adding to it for ten years.

**Honourable mention.** Storing `dayKey: Int` beside `date: Date` is redundant data,
which this spec otherwise refuses. It stays because "which day is this meal on" is
ambiguous across timezones and DST in a way that produces a bug he reads as *"the app
moved my dinner"*, and four bytes is cheap insurance against a weekend of `Calendar`
debugging. Both fields are written only by `PlannedMeal.setDate(_:)`, so they cannot
drift.
