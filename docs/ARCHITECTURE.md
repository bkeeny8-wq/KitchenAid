# KitchenAid — architecture specification, v1

**Status: THE BUILD CONTRACT.** Sections 1–3 are copied verbatim into the codebase; do
not improve them in passing. If a decision here looks wrong, change this file in its own
commit with the reason, then change the code — never the other way round.

**Code-fence convention, because half this document is a contract and half is a sketch.**
A `swift` fence is **compilable Swift** — every declaration in it has a body, and §1–§3
are entirely `swift` for that reason. A `text` fence is **everything else**: an API sketch
(signatures and field lists whose bodies are specified in the prose beside them), a
pseudocode body, a hand trace, a filename list or a tree. **There are no bare fences in this
document** — a block is `swift` or it is `text` — so a reader never has to guess whether a
block was meant to compile. The `text` blocks are §4.1, §4.2's step bodies, §4.3's worked
traces, §5.1–§5.4, §5.5's two namespaces, §6's view tree, §7's `PDFExportService`,
`PDFPaginator` and filename list, and §8.1's file tree. Everything else is `swift`: all of
§1–§3, §5.3's predicate snippet, §5.6's configuration and launch task, and §7.1's
`PrintPage` and `PDFPageWriter`. A bodiless `func`
or a
`{ get }` accessor requirement is a parse error outside a `protocol`, so one never appears
inside a `swift` fence anywhere in this document. If you are copying a block into Xcode:
`swift` blocks go in as written, `text` blocks are the signature you implement against.

This document reconciles `docs/ARCHITECTURE-PANEL.md` (a three-architecture judge panel's
output, kept as REFERENCE) against the decisions in `CLAUDE.md` and the twelve
requirements in `docs/REQUIREMENTS_FROM_FIXTURE.md`. Where the panel and `CLAUDE.md`
disagree, `CLAUDE.md` wins — its "Decisions Brandon has made" and "Declined, not
deferred" sections are not negotiable. Where the panel's own critics found a defect, the
defect is fixed here and the fix is named (§0.9).

Nothing in this repo has ever been compiled. Everything was written in a Linux container
with no Apple toolchain. Review is not a compiler. The first person to open this in Xcode
should expect build errors and should grep for the pattern rather than fixing one line.

---

## 0. Ground rules, in the order they bind

### 0.1 Platform

| | |
|---|---|
| Frameworks | SwiftUI + SwiftData + PDFKit. No third-party packages. |
| Deployment target | iOS 17.0. Anything 18+ is `@available`-gated or not used. |
| Swift | `SWIFT_VERSION = 5.0` |
| Devices | `TARGETED_DEVICE_FAMILY = "1,2"`, iPhone-first in layout |
| Bundle id | `com.brandonkeeny.KitchenAid` |
| Team | `DEVELOPMENT_TEAM = HHSFT2GD2H` |
| Backend | None. No server, no keys, no network calls. |
| Distribution | Never published. Sideloaded / TestFlight internal, family only. |
| Targets | `KitchenAid`, `KitchenAidTests`, `KitchenAidUITests` |
| Opens on | **Today.** Not the library, not the week. |

### 0.2 The content / persistence split — the rule the whole model layer hangs from

This is the single largest difference from the panel, which had it backwards.

Brandon's pipeline, in his words: *"I have claude create the pdf and drop to you to add."*
A recipe is authored in conversation, he edits it, and the PDF is dropped into a Claude
Code session where `scripts/import_recipe.py` parses it and the result is **committed as a
bundled resource**. Recipes are therefore immutable published content, not user-entered
rows — the same split his CFAL3 repo already uses between `Models/Content/` (JSON decoded
at launch) and `Models/Persistence/` (SwiftData).

| | Lives in | Mutable at runtime? |
|---|---|---|
| Recipes | `KitchenAid/Resources/Recipes/*.json`, decoded by `RecipeLoader` | **No** |
| Ingredient catalogue | `KitchenAid/Resources/ingredients.json`, decoded by `IngredientCatalog` | **No** |
| His tweaks and notes, and the last-made date | SwiftData (`RecipeTweak` and its children) | Yes |
| Plan, attendance, pantry, lists, ledger | SwiftData | Yes |

Three consequences, all load-bearing:

1. **`Recipe`, `RecipeComponent`, `IngredientLine`, `RecipeStep`, `RecipeNote` and
   `RecipeTag` are `Codable` value types, not `@Model` classes.** They have no identity in
   the store, no delete rule, and no relationship to anything persisted.
2. **SwiftData cannot hold a relationship to a non-model type.** Every edge that pointed at
   `Recipe` in the panel becomes a stored `recipeID: String` plus a
   resolve-through-`RecipeLoader` computed accessor. There is no `@Relationship` anywhere
   in this spec whose target is content.
3. **A `RecipeTweak` is an OVERLAY and never mutates bundled content.** It is modelled
   exactly as `LOSStudyStatus` overlays `LOS` content in CFAL3: a flat row keyed by the
   content's stable string id, holding only what the user changed.

**The cost, stated plainly.** A `recipeID` can dangle: if a recipe's JSON file is removed
or its id is changed, every `MealRecipe`, `RecipeTweak`, `ShoppingListSource` and
`InventoryTransaction` holding that id now points at nothing. **There is no cascade that
can fix this, because the thing deleted was never a row.** So:

- Every holder of a `recipeID` also stores a **title snapshot**, written when the edge was
  made. A 2027 meal plan whose recipe file was removed still reads
  "NY Strip Crostini (recipe no longer bundled)" rather than going blank.
- `RecipeLoader.isMissing(_:)` answers the question cheaply, and
  `Views/Settings/MissingRecipesView.swift` lists every dangling id with its snapshot and a
  "forget these rows" action. The app never deletes his history on its own.
- **Removing a recipe from the bundle is therefore a deliberate act with a known cost,**
  and the cheap alternative is always available: set `"archived": true` in the JSON, which
  hides it from the library while keeping every id resolvable. **Archive, do not delete.**
- A new recipe needs a rebuild, and family phones do not get it until they reinstall. He
  has been told. The model is arranged so a runtime importer (paste, or open a file) can be
  added later without reshaping anything — it would decode into the same in-memory
  `Recipe` value type (§9).

### 0.3 The ingredient catalogue is content too, and `FoodItem` is not a copy of it

`KitchenAid/Resources/ingredients.json` ships with the app, is built and tested by
`scripts/build_catalogue.py` / `scripts/test_catalogue.py`, and is **never hand-edited**.
Its schema is exactly what the build script emits — these field names, no others:

```json
{ "version": 1,
  "aisleOrder": ["Produce", "Bakery", "Butcher", "Seafood", "Dairy", "Dry goods",
                 "Canned", "Condiments", "Spices", "Baking", "Nuts", "Beverages",
                 "Frozen"],
  "items": [ { "name": "baguette", "aisle": "Bakery", "dimension": "count",
               "unit": "loaf", "bakingUnit": null, "gramsPerCup": null,
               "staple": false, "aliases": ["french bread"] } ] }
```

`name` is the canonical identity and is guaranteed collision-free (the build script fails
on a duplicate name, and on an alias colliding with a name or another alias — it already
caught `coriander`). `dimension` is `mass | volume | count`. `gramsPerCup` is an integer or
null. `bakingUnit` is the unit to prefer when the recipe is a bake, or null.

**`aisleOrder` is the authoritative store walk order** and the app READS it. The build
script owns it as `AISLE_WALK_ORDER`, checks it names every aisle and invents none, and
emits it into the JSON — so nothing in Swift and nothing in the seed hand-copies the list.
It is `Produce, Bakery, Butcher, Seafood, Dairy, Dry goods, Canned, Condiments, Spices,
Baking, Nuts, Beverages, Frozen`: perimeter first, centre aisles next, **frozen last** so
it is not going soft in the cart while he picks out spices.

**A catalogue entry is a TEMPLATE. A `FoodItem` is the SwiftData row for something actually
in the house.** The relationship is explicit and one-directional:

- `FoodItem.catalogName: String` is the entry's `name`, or `""` for a row he created from
  scratch. It is the only link, it is a string by design (the catalogue has no UUIDs and
  must stay diffable), and `IngredientCatalog.entry(named:)` resolves it.
- **The catalogue is NOT copied into SwiftData at launch.** Seeding 668 `FoodItem` rows for
  a house that stocks 80 of them makes every pantry screen a filter over mostly-empty rows,
  and makes a catalogue update a migration. `FoodItemResolver.findOrCreate` mints a
  `FoodItem` the first time something is actually needed, copying the template's
  `dimension`, `gramsPerCup` and `staple` onto it and resolving its `aisle` to a seeded
  `StoreSection`, so he can then override any of them. After that the row is his and the
  template is only provenance. Two details the mint cannot skip:
  **`gramsPerCup` is a two-field invariant** — the row stores
  `hasDensity` plus a numerator/denominator pair, and `FoodItem.gramsPerCup` returns nil
  without the Bool, so the mint sets `hasDensity = (entry.gramsPerCup != nil)` or §4.3(b′)'s
  density bridge silently never fires. And the template's **`unit` is deliberately NOT
  copied**: `FoodItem` has no unit field, the two unit fields it does have mean other things
  (`parLevelUnitCode` is the par level's unit), and inventing a meaning for one of them is
  worse than reading the template live — a default unit for an add-stock sheet is
  `catalog.entry(named: item.catalogName)?.defaultUnit` (§2.6).
- **Lookup order** in `FoodItemResolver`: existing `FoodItem.matchKey` → existing
  `FoodItem.aliasBlob` → catalogue `name` → catalogue `aliases` → create unresolved. So
  "scallion" finds the catalogue's `scallion` row and "green onion" finds it through the
  shipped alias, with no typing.
- **Staples** come from the catalogue's `staple` flag: salt, pepper, every oil, every
  vinegar, every spice. A staple is tracked present/absent with **no quantity** —
  `StockTrackingMode.staple`. Counting teaspoons of salt is work nobody does, and a list
  that keeps asking for salt is a list you stop reading.

The catalogue's `aisle` strings are the seeded `StoreSection` names, matched on `matchKey`.
**Walk order comes from the JSON's `aisleOrder`.** `items` is sorted alphabetically by
aisle, which is not a walk order, so `aisleOrder` carries it separately; `KitchenAidSeed`
reads `IngredientCatalog.aisleOrder` and writes each `StoreSection.sortIndex` from its
index in that array (§8). From then on the `sortIndex` is a row he can drag, and a
catalogue rebuild never silently reorders aisles he has already arranged.

### 0.4 CloudKit-readiness, enforced everywhere

CloudKit is **off** in v1 (`cloudKitDatabase: .none`, written explicitly and commented so
the day it flips is a one-line diff). Every rule below is obeyed now anyway, because
turning it on later must not reshape the store.

1. **No `@Attribute(.unique)` anywhere.** CloudKit-backed stores reject it. Identity is
   code discipline — `FoodItemResolver` plus a deterministic merge pass (§5.1).
2. **Every non-optional stored property has a default value.** No exceptions.
3. **Every relationship is optional.** Every to-many is `[T]? = []` with a non-optional
   ordered computed accessor, so no view ever writes `?? []`.
4. **Every to-many names its `inverse:` explicitly, and exactly one side of each edge
   carries the macro** — always the to-many side. The to-one side is a bare
   `var x: T? = nil` with a comment naming where its macro lives. SwiftData pairs
   un-inversed edges by *inference*, which is wrong at runtime and not at compile time.
   **SwiftData also rejects an inverse declared on BOTH sides**, which is the panel's first
   blocking defect; see §0.9.1.
5. **No `.deny`.** Only `.cascade` and `.nullify`, decided per edge in §2.8.
6. **No stored array attributes for data two devices might both append to.** A stored
   `[String]` is last-writer-wins on the *whole blob* and is invisible to `#Predicate`.
   Aliases are child **rows**. The **six** deliberate
   delimited-`String` fields, across **four** justifications, are named and justified in
   §2.8.
7. **Nothing is an incrementing counter.** There is no `cookCount` in this schema at all
   (§0.5): cooking history is a last-made date, and a date is set, not incremented.
8. **Zero is never an absent sentinel.** Durations, temperatures and prices are `Int?`. A
   quantity that does not exist is `nil`, not `0`.

If you add a model and cannot satisfy these, stop and say why rather than quietly using
`.unique`.

### 0.5 Declined, not deferred — cut entirely, with no hooks left behind

Brandon was offered each of these and said no. They are **absent**, not gated, not
commented out, not represented by a spare field.

| Cut | What that means concretely |
|---|---|
| **Photos, of any kind** | No `RecipePhoto` model. No `imageData` on any model or content type. No `PhotosUI` import, no `Resources/RecipePhotos/` folder, no `.externalStorage` attribute anywhere. `RecipeCardRow` and `RecipeDetailView` have no hero image and no placeholder for one. `CookFinishSheet` has no camera button. `RecipeStep` has no image. |
| **A cooking journal** | No `CookLogEntry`. No ratings, no `averageRating`, no `ratingSum`, no per-cook notes, no measured duration, no "how did it go", no `CookLogView`, no `cookCount`. **Cooking history is `RecipeTweak.lastMadeAt` and nothing else** — one optional `Date` per recipe. |
| **Dietary restrictions and allergy warnings** | No `DietaryRestriction`, no `DietaryKeyword`, no `AcknowledgedWarning`, no `DietGuard`, no `RestrictionKind`, no `RestrictionSeverity`, no `DietWarningBanner`, no `RestrictionEditorView`. **`Eater.restrictions` and `FoodItem.restrictions` are removed**, which is also why there is no many-to-many relationship left anywhere in the schema. No warning path, no warning triangle on a calendar cell, no diet row in the week brief, no diet section in any PDF. |
| **Web-link recipe import, cookbook-photo OCR** | No URL import, no recipe OCR. Receipt OCR for the pantry is still wanted and is in §9. |
| **A recipe authoring UI** | No `RecipeEditorView`, no `ComponentEditorSection`, no `StepEditorRow`, no `PasteImportView`, no `ParseReviewView`, no `ImportCoordinator`, no `RecipeTextParser`/`StepTextParser`/`QuantityTokenizer` in the app target. Recipes are written before they arrive. In-app editing is **notes and tweaks only** (§2.9–2.11, §6). |

### 0.6 Naming

Every path is `KitchenAid/`. The bundle id is `com.brandonkeeny.KitchenAid`, both
`UTType`s are `com.brandonkeeny.KitchenAid.recipe` and
`com.brandonkeeny.KitchenAid.plannedmeal`, and the targets are `KitchenAid`,
`KitchenAidTests`, `KitchenAidUITests`. The panel's 219 `Kitchen/` paths and 6
`com.brandonkeeny.Kitchen` ids are all corrected here.

Types named after the **app** take the full name: `KitchenAidApp`, `KitchenAidSchemaV1`,
`KitchenAidMigrationPlan`, `KitchenAidRouter`, `KitchenAidSeed`, `KitchenAidMaintenance`,
`KitchenAidFormatting`, `KitchenAidEnums.swift`. (`KitchenAidUTType.swift` is a file name,
not a type: it holds two `UTType` extension constants and declares no type of its own, so
it is deliberately absent from this list.) Types that are English
nouns about **kitchens in general** keep theirs: `KitchenUnit` is a unit used in a kitchen,
not a unit belonging to the product, and `KitchenAidUnit` in forty signatures buys nothing.
This line exists so nobody "fixes" it in either direction.

### 0.7 Correctness rules that outrank tidiness

- **Quantities are exact rationals.** Never `Double`. `1/3 cup × 3` must be exactly
  `1 cup`. Every portion factor, serving count and yield is an `Int`
  numerator/denominator pair; nothing is laundered through `Double` on the way to a scale.
- **Volume, mass and count are different dimensions and are not convertible without
  per-item data.** The app never guesses a density. It says so, once, and learns.
- **The app never silently drops a requirement and never silently guesses one.** An
  unresolvable line is flagged and shown. A depletion needing an absent bridge is
  *written* with `delta == nil` and lands in an inbox.
- **`docs/fixture-recipe-01.txt` is ground truth.** Any model that cannot represent it
  losslessly is wrong. `docs/REQUIREMENTS_FROM_FIXTURE.md` lists the twelve things it
  proves; all twelve are still binding and §8.2 maps each to its evidence in the seed.
- **`scripts/test_import.py` is the only automated check in this project that can
  execute.** It runs in a cloud session. If you touch the importer, run it.

### 0.8 Where this diverges from CFAL3, deliberately

CFAL3 is Brandon's established convention and is matched on layout, `@Model final class`
with a fully-defaulted explicit `init`, pure `enum` service namespaces, `@Observable`
services as `@State` on the App injected via `.environment(...)`, the defensive
`ModelContainer` with in-memory fallback, `UITestMode` with its throwaway defaults suite,
`accessibilityIdentifier` on everything a test touches, and comments that name the bug.

Two things differ:

1. **CFAL3 uses `@Attribute(.unique)`** on `Attempt.id`, `Session.id`,
   `FlashcardProgress.cardId`. KitchenAid cannot. See §5.1.
2. **CFAL3 has zero `@Relationship`.** KitchenAid's *content* follows CFAL3 exactly —
   `Codable` structs decoded from bundled JSON, joined to SwiftData by a string id. But
   its *persistence* side is a real object graph, for one decisive reason: de-duplicating a
   `FoodItem` means **enumerating every referrer**. With explicit inverses that is **three
   referrer arrays to repoint (`lots`, `transactions`, `shoppingLines`) plus one child
   array to union (`aliases`)**. With `foodItemID: UUID?` it is a
   full-store scan of every `StockLot`, `InventoryTransaction` and `ShoppingListLine` on
   every launch, forever.

CFAL3 is iPad-only; KitchenAid is `"1,2"` and the *primary* cooking surface is an iPhone
propped against the backsplash. The phone gets the designed path; iPad gets more columns,
not a different app.

### 0.9 The five blocking defects the panel's own critics found, and their fixes

**0.9.1 — `Recipe.tags` / `RecipeTag.recipes` declared `inverse:` on both sides.**
SwiftData rejects that. Largely moot here: tags are bundled content (`Recipe.tags: [RecipeTag]`
decoded from the JSON), so there is no persisted tag edge at all. The rule survives and is
stated in §0.4.4 — **whatever many-to-many exists must carry the macro on exactly one
side.** With `DietaryRestriction` cut, **this schema contains no many-to-many
relationship**, which is checked by inspection in §2.8: every edge in that table is
one-to-many or one-to-one.

**0.9.2 — `QuantitySubtotal.swift` was a manifest row with no spec whose contents were
owned elsewhere.** Resolved one way: `QuantitySubtotal` and `SubtotalRole` are declared,
once, in `KitchenAid/Models/Support/QuantitySubtotal.swift` (§3.5) as **top-level types**.
`QuantityMath.Subtotal` does not exist. Every signature in §3.6, §4 and §5 says
`QuantitySubtotal`, and `ShoppingListLineSubtotal` is the persisted mirror of it.

**0.9.3 — `LedgerDivergence`, `DeleteRefusal`, `CookTimer` and `ExportError` appeared only
in signatures and were never declared.** All four are declared here, each with one owning
file: `Models/Support/LedgerDivergence.swift` (§3.11),
`Models/Support/DeleteRefusal.swift` (§3.12), `Models/Support/CookTimer.swift` (§3.13),
`Services/ExportError.swift` (§3.14). `LedgerDivergence` carries the **unassigned-lot
bucket**, the **per-lot / per-item split** and the **cache-versus-ledger delta**, because
those are the three things the reconcile screen exists to show.

**0.9.4 — `AppTab`'s cases were never listed and "6 tabs" contradicted the four in the view
tree.** The enum is written out in §2.27: **five tabs — Today, Recipes, Plan, Shop,
Pantry.** Cook is a `fullScreenCover` and Settings is a sheet; neither is a tab. Every count
in this document says five. **The app opens on Today, which the panel did not have at all**,
so there is a Today screen the panel never specified; it is added in §6.1.

**0.9.5 — `Job.inventorySnapshot` had no owning view, and `Job.weekPlan` had to emit three
structurally different pages through a writer taking one.** Both fixed in §7:
`Views/Export/InventorySnapshotPrintPage.swift` is added and owns that job, and
`PDFPageWriter.write(pages:to:)` now takes `[PrintPage]` — a boxed, per-page-sized value —
with the media box set per page, so a landscape week grid, a portrait head-count page and a
portrait prep-ahead page are one document.

### 0.10 The decisions, one line each

| # | Decision | Why |
|---|---|---|
| 1 | **Recipes are immutable bundled content; everything the user does is SwiftData keyed by `recipeID: String`.** | His authoring pipeline is a PDF dropped into a session and committed. See §0.2. |
| 2 | **A `RecipeTweak` overlay, never a mutation of content.** | A tweak that rewrote the JSON would be lost on the next rebuild, and would make the bundle and the store disagree about what the recipe says. |
| 3 | **`recipeID` is an authored slug string, not a UUID.** | The file name is the id, the id is diffable in git, and a UUID in a hand-authored JSON file is a thing nobody can proofread. |
| 4 | **Components own ingredient lines only. `Recipe` owns a flat ordered `steps` array.** `RecipeStep.componentIndex` is an optional tag. | The fixture has three ingredient groups and ONE numbered 1–8 method that interleaves them (toast 2, sear 3, wilt 5, assemble 8). Steps reachable only through a component can represent nothing but all-steak-then-all-crostini. |
| 5 | **Two independent yields:** `servings` (the only scaling divisor) plus `yieldAmount` + `yieldUnitLabel` for display. | "Makes: 12 crostini (serves 4)". A single `baseYield` makes scale = 4/12 = 1/3 and the first shopping list buys one third of everything. |
| 6 | **Inventory is an append-only `InventoryTransaction` ledger** with `StockLot.remaining` as an explicitly-commented cache. No scalar `amount` anywhere. | Two offline devices each decrementing a scalar resolve last-writer-wins and one decrement vanishes with no conflict handler possible. This is the one gap that is genuinely not additive later. |
| 7 | **`FoodItem → lots` and `→ transactions` are `.nullify`, not `.cascade`**, with `foodItemNameSnapshot` on both. | A `.cascade` means one stray `.onDelete` destroys the audit trail the whole architecture is built on. A service-layer refusal the schema cannot enforce is not a rule. |
| 8 | **`level(of:)` sums the item's TRANSACTIONS, not its lots.** `StockLot → transactions` is `.nullify`; an orphaned transaction still counts, into an "unassigned lot" bucket. | Otherwise deleting a lot leaves transactions that remain in the ledger but silently stop contributing, producing a permanent divergence `reconcileReport` can never attribute. |
| 9 | **`Quantity` persists as five flat primitives** (`hasQuantity`, `amountNumerator`, `amountDenominator`, `unitCode`, `dimensionRaw`) behind `QuantityCarrying`, never as a `Codable` composite. | A `Codable` struct attribute is an opaque blob: unqueryable, unreadable in the CloudKit dashboard, and any change to `Rational` or the unit table needs a custom migration stage that decodes every stored row in the old shape. |
| 10 | **`hasQuantity == false` is how "Pinch" is stored.** Never a zero sentinel. | A nil quantity never enters arithmetic, never suppresses a line, and cannot be confused with a deliberate zero or a parse failure. `0` would aggregate into "2 pinches". |
| 11 | **Culinary conversion factors as exact rationals, volume base = teaspoon.** tsp 1 / tbsp 3 / fl oz 6 / cup 48 / pint 96 / quart 192 / gallon 768; metric anchored on 1 tsp = 5 mL. Mass: g 1, oz 567/20, lb 2268/5. | SI-exact factors make 1 cup = 236.588 mL, so a 240 mL carton leaves a 3.4 mL residue that surfaces as a spurious "1 tsp heavy cream" line. They also give 32-million denominators and the whole overflow-fallback path those require. |
| 12 | **`KitchenUnit` is a struct with a `code: String`, not an enum.** | Count nouns are an open set. More importantly each count noun is its own merge bucket, which is the only thing that stops `2 cloves + 1 head` summing to "4 cloves". |
| 13 | **The `.count` dimension is partitioned by count noun, and the partition is final.** `count:clove` and `count:head` are two buckets and stay two; the only collapse in v1 is volume↔mass on a per-item density. | "2 cloves + 1 head" must never read "3 cloves". Folding one count noun into another, or into a purchase noun, is **purchase-unit rounding** — it was added here on initiative, failed review twice, and was cut; see `CLAUDE.md` before re-adding it. So the fixture's baguette line ships honestly as **"12 slices"**, which is what the design mockup already said. |
| 14 | **Every shopping line carries an N-element set of per-dimension subtotal ROWS** for requested / have / toBuy / purchase. | Flour arriving as cup + gram + package is three dimensions. A single `secondaryText` slot drops the third. |
| 15 | **`toBuy` and `purchase` are separate stored roles, and receive-into-inventory posts the PURCHASE one.** In v1 `purchase` is a copy of `toBuy` — purchase-unit rounding is deferred (`CLAUDE.md`). | What enters the ledger must be what actually came home, not what the recipe asked for, or tracked stock drifts monotonically below reality and the pantry is useless within a month. Keeping the role separate while it holds the same number is what lets rounding arrive later as a writer rather than as a migration. |
| 16 | **`StoreSection` and `StorageLocation` are `@Model` rows under a `Store` parent**, with `sortIndex` and `defaultShelfLifeDays`. | Enums mean no "Fish counter" or "Garage fridge" without a build, and a walk order in `UserDefaults` is deliberately not synced — his iPad would shop a different store than his phone. |
| 17 | **The catalogue is not seeded into SwiftData.** `FoodItem` rows are minted on demand from a catalogue template, linked by `catalogName: String`. | 668 mostly-empty rows make every pantry screen a filter and every catalogue update a migration. See §0.3. |
| 18 | **Staples aggregate fully and divert at presentation.** The staples footer shows the summed quantity. | The fixture's kosher salt (1 tsp + 1/4 tsp = 1 1/4 tsp) is the document's own proof case for intra-recipe aggregation. Diverting salt to a quantity-less bucket means the arithmetic never runs on it and butter becomes the only surviving proof. |
| 19 | **A meal holds several recipes:** `PlannedMeal` + `MealRecipe` + `MealAttendance`. | He chose it. A dinner is a main and two sides, and each dish scales and is cooked separately. |
| 20 | **Named `Eater` rows, addable and removable, each full or half portion. Ship two, hardcode no count. A `guestCount` on `PlannedMeal` for parties — counted, never named.** | `CLAUDE.md`: named people with a full or half portion, no allergy or dietary data. "Sarah's parents came" must not permanently join the roster, and does not need a name to be fed. |
| 21 | **No `Household` entity.** The household *is* the set of `Eater` rows. | A singleton row created by bootstrap-if-empty means two offline devices both bootstrap, and now there are two rosters with attendance split across them. |
| 22 | **`dayKey: Int` (yyyymmdd) stored beside `date: Date`.** | A `#Predicate` on a `Date` range is correct until he crosses a timezone or a DST boundary, and then "Tuesday's dinner" renders on Monday night. Written in exactly one place, `PlannedMeal.setDate(_:)`. |
| 23 | **`ShoppingListSource` keeps denormalized snapshot strings AND a live `.nullify` edge to `plannedMeal`.** | The snapshots preserve history across a recipe revision; the live edge makes "drop Thursday's dinner" and "jump to the meal that caused this line" queries instead of a decode-every-blob scan. |
| 24 | **Sub-recipe expansion converts the line quantity into the sub-recipe's YIELD dimension and divides by `yieldAmount`** — never by a serving count. Impossible conversion or absent yield → the line is **not expanded**; it stays a buy-it line flagged `.unknownYield`. | Dividing millilitres by servings shops for 118 batches of stock, and the error compounds at every level of the recursion. |
| 25 | **The cycle guard `visited` is passed BY VALUE.** | As `inout` it becomes a global already-seen set, so one stock recipe feeding two of the week's meals contributes zero ingredients on the second use. |
| 26 | **Meals whose status is `.cooked` are excluded from collection, as well as `.skipped`.** | Cooking already depleted inventory; collecting it again shops twice for a meal already made. |
| 27 | **The defensive `ModelContainer` init falls back to an in-memory store**, and `UITestMode` is copied structurally from `CFAL3App.swift`. | A migration the runtime declines to infer should explain itself instead of crashing on every launch and locking him out of his own data. |

---

## 1. File manifest

Every Swift file to be created, grouped by folder, with what it owns. Complete and
non-overlapping — this is the build work-list, and **every type named anywhere in this
document has exactly one owning file below.** 21 `@Model` classes, 6 bundled content value
types, 5 tabs.

### `KitchenAid/App/`

| Path | Owns |
|---|---|
| `KitchenAid/App/KitchenAidApp.swift` | `@main`. The schema list, the defensive `ModelContainer` with in-memory fallback, `storeFailure`, every `@Observable` service as `@State` injected via `.environment(...)`, and the launch `.task` (load content → seed → reconcile → rebuild caches). |
| `KitchenAid/App/UITestMode.swift` | `-uitesting` launch arg, the in-memory store flag, and the `static let` throwaway `UserDefaults` suite. Copied structurally from `CFAL3App.swift`, comment and all. |
| `KitchenAid/App/AppTab.swift` | `AppTab` — the five-case tab enum with `title`, `symbol` and the test-addressable `identifier`. §2.27. |
| `KitchenAid/App/RootTabView.swift` | `TabView` over `AppTab`, the store-failure banner, the cook-mode `fullScreenCover`, the Settings sheet. |
| `KitchenAid/App/KitchenAidRouter.swift` | `@Observable`. Selected tab, presented sheets, the active cook-mode payload. Modelled on CFAL3's `TabRouter`. |

### `KitchenAid/Models/Schema/`

| Path | Owns |
|---|---|
| `KitchenAid/Models/Schema/KitchenAidSchema.swift` | `KitchenAidSchemaV1: VersionedSchema` with the single `models` array shared by the container and the tests, and `KitchenAidMigrationPlan: SchemaMigrationPlan` with empty `stages`. Written before the first build: adding a `VersionedSchema` *later* means the existing store carries no recorded version identity, so the first real migration has nothing to migrate from. |

### `KitchenAid/Models/Content/` — bundled, `Codable`, **no `@Model`, no SwiftData import**

| Path | Owns |
|---|---|
| `KitchenAid/Models/Content/Recipe.swift` | `Recipe` (the decoded recipe), `RecipeFile` (the one-recipe file envelope with its `schemaVersion`), and `Recipe`'s derived accessors. |
| `KitchenAid/Models/Content/RecipeComponent.swift` | `RecipeComponent`. An ingredient GROUP. Owns lines, never steps. |
| `KitchenAid/Models/Content/IngredientLine.swift` | `IngredientLine`. One line: optional quantity, recorded dimension, name/preparation split, `catalogName`, `subRecipeID`. |
| `KitchenAid/Models/Content/RecipeStep.swift` | `RecipeStep`. Flat, recipe-ordered. `title`/`body`, optional min/max minutes, optional temperatures, optional `componentIndex`. |
| `KitchenAid/Models/Content/RecipeNote.swift` | `RecipeNote`. One note bullet with a `kind`. |
| `KitchenAid/Models/Content/RecipeTag.swift` | `RecipeTag`. A tag as content, with `name` and `kind`. |
| `KitchenAid/Models/Content/CatalogEntry.swift` | `CatalogEntry` and `CatalogFile` — the decoded `ingredients.json`, field-for-field as `scripts/build_catalogue.py` emits it. |
| `KitchenAid/Models/Content/ResolvedRecipe.swift` | `ResolvedRecipe` and `ResolvedRecipe.LapsedOverride` — bundled content with the `RecipeTweak` overlay applied to a COPY, plus which lines and steps were overridden and which overrides have lapsed. What every view renders (§3.10). |
| `KitchenAid/Models/Content/ContentDiagnostic.swift` | `ContentDiagnostic` **and its nested `Kind`** — what `RecipeLoader` and `IngredientCatalog` report when a bundled file is malformed, duplicated or references a missing id. Surfaced in `StoreHealthView`, never silently swallowed. |

### `KitchenAid/Models/Overlay/` — the SwiftData side of content

| Path | Owns |
|---|---|
| `KitchenAid/Models/Overlay/RecipeTweak.swift` | `@Model`. One row per recipe id he has touched: `lastMadeAt`, free notes, and the override children. Modelled on CFAL3's `LOSStudyStatus`. |
| `KitchenAid/Models/Overlay/IngredientOverride.swift` | `@Model`. "This line's quantity is wrong; it is 1 tbsp." One row per overridden ingredient line. |
| `KitchenAid/Models/Overlay/StepOverride.swift` | `@Model`. "Step 6 should say 3 minutes." One row per corrected step. |

### `KitchenAid/Models/Catalog/`

| Path | Owns |
|---|---|
| `KitchenAid/Models/Catalog/FoodItem.swift` | `@Model`. The thing actually in the house. The only row that means "a thing in my kitchen". |
| `KitchenAid/Models/Catalog/FoodItemAlias.swift` | `@Model`. One alias row he added (`scallion` → green onion) with its own `matchKey`. Shipped aliases stay in the catalogue. |
| `KitchenAid/Models/Catalog/Store.swift` | `@Model`. A store, owning its own section geography. |
| `KitchenAid/Models/Catalog/StoreSection.swift` | `@Model`. One aisle with a `sortIndex` he drags. |
| `KitchenAid/Models/Catalog/StorageLocation.swift` | `@Model`. Pantry / fridge / freezer / garage fridge, with `defaultShelfLifeDays`. |
| `KitchenAid/Models/Catalog/MergeRecord.swift` | `@Model`. An audit row per de-dup merge, so Settings can say "merged 3 duplicates" instead of mutating his data silently. |
| `KitchenAid/Models/Catalog/SeedRecord.swift` | `@Model`. `seedKey` fetched before applying — idempotent seeding without `.unique`. |

### `KitchenAid/Models/Planning/`

| Path | Owns |
|---|---|
| `KitchenAid/Models/Planning/Eater.swift` | `@Model`. A household member with a full-or-half portion factor. |
| `KitchenAid/Models/Planning/AttendanceDefault.swift` | `@Model`. "Nobody is home Thursdays" — a weekday+slot rule applied when a `PlannedMeal` is created. |
| `KitchenAid/Models/Planning/PlannedMeal.swift` | `@Model`. The calendar cell: date, `dayKey`, slot, kind, guest count, the leftovers self-edge, attendance, dishes. |
| `KitchenAid/Models/Planning/MealRecipe.swift` | `@Model`. Join: a meal has a main and two sides. Carries `recipeID` + title snapshot, the per-dish scale override, `servingsCooked`, `plannedLeftoverServings`. |
| `KitchenAid/Models/Planning/MealAttendance.swift` | `@Model`. Join: WHO is eating and how much. Portions live on the edge. |

### `KitchenAid/Models/Inventory/`

| Path | Owns |
|---|---|
| `KitchenAid/Models/Inventory/StockLot.swift` | `@Model`. One physical lot. `remaining` is a documented CACHE. |
| `KitchenAid/Models/Inventory/InventoryTransaction.swift` | `@Model`. Append-only truth. Signed delta, optional (`pendingBridge`) delta, kind, provenance. |

### `KitchenAid/Models/Shopping/`

| Path | Owns |
|---|---|
| `KitchenAid/Models/Shopping/ShoppingList.swift` | `@Model`. A persisted, frozen trip. |
| `KitchenAid/Models/Shopping/ShoppingListLine.swift` | `@Model`. One line per `FoodItem` per list. |
| `KitchenAid/Models/Shopping/ShoppingListLineSubtotal.swift` | `@Model`. One (role, dimension) subtotal row. N per line. The persisted mirror of `QuantitySubtotal`. |
| `KitchenAid/Models/Shopping/ShoppingListSource.swift` | `@Model`. "Recipe asked for X" — snapshots plus the live meal edge. |

### `KitchenAid/Models/Support/` — value types, no `@Model`

| Path | Owns |
|---|---|
| `KitchenAid/Models/Support/Rational.swift` | `Rational`. Exact fractions. gcd-normalized, overflow-checked on `+ - * /`, an explicit `Codable` that routes through the validating init, `init(approximating:)`, `ceiling(toMultipleOf:)`, `rounded(toDenominator:)`, `mixedDescription`, `vulgarDescription`. |
| `KitchenAid/Models/Support/MeasureDimension.swift` | `MeasureDimension` — `volume / mass / count / unmeasured` and the base-unit identity of each. |
| `KitchenAid/Models/Support/KitchenUnit.swift` | `KitchenUnit`: `code`, `dimension`, `baseFactor: Rational`, singular/plural, `isHouseholdCommon`, `system`, `dimensionKey`. |
| `KitchenAid/Models/Support/UnitCatalog.swift` | `UnitCatalog`. The conversion table (culinary, exact rationals), synonym resolution (`T`/`tbsp`/`tablespoons`), `countUnit(noun:)` for the open set, `displayCandidates(for:system:)`. The only place a factor is written. |
| `KitchenAid/Models/Support/Quantity.swift` | `Quantity` (`amount` + `unit`, `base`, `scaled(by:)`, `converted(to:)`, `displayString(system:)`) **and the `QuantityCarrying` protocol** that gives a model holding one quantity its five stored primitives and one computed accessor. |
| `KitchenAid/Models/Support/QuantitySubtotal.swift` | `QuantitySubtotal` and `SubtotalRole`. One (dimension, count-noun) subtotal in base units, plus its role. **The only declaration of either** (§0.9.2). |
| `KitchenAid/Models/Support/QuantityMath.swift` | `QuantityMath` **and its nested `Contribution`**: `hintUnit`, `displayUnit(forBase:dimensionKey:hint:system:)`, `sum`, `collapseAcrossDimensions`, `bridgeHave`, `subtract`. The arithmetic under test. |
| `KitchenAid/Models/Support/MergeKey.swift` | `ItemIdentity` (`.cataloged(UUID)` / `.freeText(String)`) and `MergeKey`, the **subtotal** bucket `(item, dimensionKey)`. A LINE is keyed by `ItemIdentity` alone — one line per `FoodItem` per list — and `MergeKey` keys the buckets inside it, never a line (§3.7, §4.2 step 4). |
| `KitchenAid/Models/Support/KitchenAidEnums.swift` | `UnitSystem`, `MealSlot`, `MealEntryKind`, `AttendanceStatus`, `PlanStatus`, `CourseKind`, `Difficulty`, `ComponentKind`, `NoteKind`, `BatchGranularity`, `ScalingRule`, `SubRecipePolicy`, `StockTrackingMode`, `StorageKind`, `TransactionKind`, `ResolutionState`, `LineStatus`, `LineSourceKind`, `PlanScope`, `TagKind`. All `String`-raw-value-backed. |
| `KitchenAid/Models/Support/ScalingNote.swift` | `ScalingNote` — `.noAttendance / .unknownYield / .snappedToBatch / .overridden / .leftoversIncluded` and their badge text. |
| `KitchenAid/Models/Support/LineFlag.swift` | `LineFlag`, the shopping-line flag set (14 cases, **including `leftoversIncluded`** so `from(_:)` is total over `ScalingNote`), its `badge` text, and its `\|`-delimited blob encoding. |
| `KitchenAid/Models/Support/CalendarKey.swift` | `CalendarKey`: `dayKey(for:in:)`, `date(fromDayKey:)`, `weekInterval(containing:)`, `monthInterval(containing:)`, `dayKeys(in:)`. The ONLY place day math lives. |
| `KitchenAid/Models/Support/NameNormalizer.swift` | `NameNormalizer`. Lowercase, diacritic-fold, strip punctuation and parentheticals, drop trailing prep qualifiers, conservative singularize with a stoplist. `matchKey(_:)` and `slug(_:)` — the latter is the `lineID` / `stepID` / recipe-file-name slug, a line-for-line port of the importer's, and the Python one is the reference (§2.3, §2.4, §8.1). |
| `KitchenAid/Models/Support/LedgerDivergence.swift` | `LedgerDivergence` and `LedgerDivergence.Scope`. The reconcile screen's row type: per-lot and per-item, including the unassigned-lot bucket, carrying the cache-versus-ledger delta (§3.11). |
| `KitchenAid/Models/Support/DeleteRefusal.swift` | `DeleteRefusal` **and its nested `Reason`**. Why a delete was refused, and what to offer instead (§3.12). |
| `KitchenAid/Models/Support/CookTimer.swift` | `CookTimer`. One running step timer: step id, label, total and remaining seconds, notification request id (§3.13). |

### `KitchenAid/Models/Transfer/`

| Path | Owns |
|---|---|
| `KitchenAid/Models/Transfer/KitchenAidUTType.swift` | The two `UTType` **extension constants** `.kitchenAidRecipe` and `.kitchenAidPlannedMeal`, matching `Info.plist`'s exported type declarations. It declares no type of its own — the file is named for what it holds (§2.29). |
| `KitchenAid/Models/Transfer/RecipeTransfer.swift` | `RecipeTransfer`: `Codable + Transferable` drag payload — a `recipeID` and a title, plus `ProxyRepresentation(exporting: \.title)`. |
| `KitchenAid/Models/Transfer/PlannedMealTransfer.swift` | `PlannedMealTransfer`. Same shape for dragging a planned meal between calendar cells. Never a `@Model` — a `@Model` class is neither reliably `Codable` nor `Sendable`. |

### `KitchenAid/Services/` — pure `enum` namespaces (no SwiftData, no SwiftUI, unit-testable with no `ModelContainer`)

| Path | Owns |
|---|---|
| `KitchenAid/Services/RecipeGraph.swift` | `RecipeGraph`: `Provenance`, `FlatLine`, `Diagnostic`, `flatten(...)`, `childScale(for:subRecipe:)`. Component walk, sub-recipe expansion by id, dimensionally-sound child scale, by-value cycle guard, depth cap. |
| `KitchenAid/Services/MealScaling.swift` | `MealScaling` and `MealScaling.Result` — portions, exact `Rational` scale, batch snapping, `[ScalingNote]`, `description`. |
| `KitchenAid/Services/ShoppingListBuilder.swift` | `ShoppingListBuilder`: `Options`, `DraftSource`, `DraftLine`, `Draft`, `preview`, `build`. The algorithm in §4. Takes fetched values and closures, returns a `Draft`. No fetches, no mutation. |
| `KitchenAid/Services/PDFPaginator.swift` | `PDFPaginator` and its nested `MeasuredSection`. Measured section heights → page assignment, packing whole sections so nothing is cut mid-line. `paginate(sections:pageSize:name:)` (§7.1). |
| `KitchenAid/Services/MealPlanStats.swift` | `MealPlanStats` and its nested `Coverage`. `coverage(for:meals:)`, `repeats(in:)`, `neverMade(from:tweaks:)` — the numbers behind the week brief and the Today screen (§6.1). |
| `KitchenAid/Services/WeekBriefBuilder.swift` | `WeekBriefBuilder` and its nested `Brief`. Assembles the Plan tab's landing summary from plan + inventory (§6.2). |
| `KitchenAid/Services/ExportError.swift` | `ExportError`. Every way a render can fail, with user-facing text (§3.14). |
| `KitchenAid/Services/KitchenAidSeed.swift` | `KitchenAidSeed.applyIfNeeded(in:catalog:)`. A **static namespace**, called once from the launch task and never held as state. Store sections in the order `IngredientCatalog.aisleOrder` gives, storage locations and two `Eater` rows — all `SeedRecord`-gated. **It seeds no recipes and no catalogue rows.** |
| `KitchenAid/Services/KitchenAidMaintenance.swift` | `rebuildLotCaches(in:)`, `findDuplicateFoodItems(in:)`, `mergeDuplicateTweaks(in:)`, `forgetMissingRecipeRows(in:loader:)`. A **static namespace** — it holds no state between calls. Wired to remote-change notifications, not only to a Settings button. |

### `KitchenAid/Services/` — `@Observable` classes, `@State` on the App

(`PDFExportService` and `PDFPageWriter` below are `@MainActor` `enum` namespaces rather than
`@Observable` classes — they hold no state, but they import SwiftUI and so cannot sit in the
pure-`enum` group above. `KitchenAidSeed` and `KitchenAidMaintenance` are plain static
namespaces and are listed in the group above, not here: they are called as
`KitchenAidSeed.applyIfNeeded(…)` and `KitchenAidMaintenance.rebuildLotCaches(…)` and never
injected.)

| Path | Owns |
|---|---|
| `KitchenAid/Services/RecipeLoader.swift` | `@Observable`. Decodes every `Resources/Recipes/*.json` once at launch into `[String: Recipe]`, exposes `recipe(id:)`, `all`, `allIncludingArchived`, `allTags`, `isMissing(_:)`, `usages(of:)` (the "used in 6 dishes" count `RecipeUsageSection` renders, computed over content references rather than stored), `diagnostics`. **The only place a `Recipe` comes from.** |
| `KitchenAid/Services/IngredientCatalog.swift` | `@Observable`. Decodes `ingredients.json` once, exposes `entry(named:)`, `entry(matching:)` (name then alias, by `matchKey`), `all`, `aisleOrder` (**read from the JSON's `aisleOrder` — the authoritative walk order, never hand-copied**), `aisleNames` (the distinct `aisle` values actually present, for the `.unknownAisle` check), `diagnostics`. |
| `KitchenAid/Services/InventoryLedger.swift` | `@Observable`. `level(of:in:includeExpired:asOf:graceEnd:)` — which returns the **flags it raised** as well as the subtotals, because it is the only thing that can see a lot's `expiresAt` (§5.4) — plus FIFO lot selection, `apply`, `receive`, `recompute`, `rebuildAllCaches`, `reconcileReport`, `expiringSoon`, `pendingBridgeTransactions`, `resolve`. Holds its `ModelContainer` so `level` has a context on the hot path. |
| `KitchenAid/Services/FoodItemResolver.swift` | `@Observable`. The ONLY place a `FoodItem` is created. `matchKey` + alias + catalogue lookup, `findOrCreate(name:createIfMissing:in:)`, `findOrCreate(fromCatalog:in:)`, `addAlias(_:to:in:)`, `reindex(_:)`, `merge(_:into:in:)` (which writes the `MergeRecord` `MergeFoodItemsView` renders), `canDelete(_:)`, and the deterministic `reconcile(in:)`. |
| `KitchenAid/Services/TweakStore.swift` | `@Observable`. The overlay's accessor, spelled exactly as §5.2 declares it: `tweak(for:in:)`, `tweakIfExists(for:)`, `setQuantity(_:forLine:in:)`, `setPreparation(_:forLine:in:)`, `setStep(title:body:minMinutes:maxMinutes:forStep:in:)`, `setNotes(_:for:)`, `setFavorite(_:for:)`, `markMade(_:at:)`, `clearIngredientOverride(lineID:in:)`, `clearStepOverride(stepID:in:)`, `pruneIfEmpty(_:in:)`, and `effectiveRecipe(id:)` → a `ResolvedRecipe` (§3.10) with every override applied. **Nothing else reads an override row.** |
| `KitchenAid/Services/CookSession.swift` | `@Observable`. Active resolved recipe, live scale, completed step ids, concurrent `CookTimer`s. |
| `KitchenAid/Services/CookingService.swift` | `@Observable`. The cook-finish path: set `RecipeTweak.lastMadeAt`, deplete inventory, set the meal `.cooked`. There is no log row to write. |
| `KitchenAid/Services/MealPlanService.swift` | `@Observable`. Range queries, `plan(recipeID:title:on:slot:)` — the `title` argument is not optional, because this is the one place `MealRecipe.recipeTitleSnapshot` is written (§5.5) — plus `copyWeek`, `move`, `duplicate`, `makeLeftovers`, `setAttendance`, `setGuestCount`, attendance-default application. Owns the "exactly one leftovers path" validation. |
| `KitchenAid/Services/ShoppingListStore.swift` | `@Observable`. `materialize(draft:into:existing:)` — the spelling used in §4.2 step 10 and §5.5 — preserve check-state across a regenerate, `regenerate`, `diff`, `addManualLine`, `drop(meal:from:)`. |
| `KitchenAid/Services/ExportCoordinator.swift` | `@Observable`. Render progress, the last PDF `URL` for `ShareLink`, and `sweepTemporaryFiles()` — an **instance method**, called as `exporter.sweepTemporaryFiles()` from the launch task like every neighbouring service (§5.6). |
| `KitchenAid/Services/PDFExportService.swift` | `PDFExportService` and `PDFExportService.Job`. `render(_:loader:tweaks:context:)` → a vector PDF `URL`. `@MainActor`. The loader, the tweak store and the context are **parameters**, because three of the four jobs carry only ids and have to reach content and rows to render at all (§7). |
| `KitchenAid/Services/PDFPageWriter.swift` | `PDFPageWriter.write(pages:to:)`. The `CGContext(consumer:mediaBox:)` + `ImageRenderer.render` closure, with the media box set **per page** (§0.9.5, §7). |
| `KitchenAid/Services/AppPreferences.swift` | `@Observable`, `init(defaults:)`. Unit system, plan scope, last build options, default diner count. Deliberately not synced. |

### `KitchenAid/Views/Today/` — the launch surface

| Path | Owns |
|---|---|
| `KitchenAid/Views/Today/TodayView.swift` | The default tab. Today's meals in slot order, each with a Cook button; a prep-ahead strip for tomorrow; expiring-soon count. Falls back to `TodayRecentSection` when the plan is empty. |
| `KitchenAid/Views/Today/TodayMealCard.swift` | One meal: slot, dish titles, attendance chips, guest count, the big Cook button, scaled-for text. |
| `KitchenAid/Views/Today/TodayRecentSection.swift` | The empty-plan fallback: recently made recipes by `RecipeTweak.lastMadeAt`, then never-made ones. |

### `KitchenAid/Views/Recipes/`

| Path | Owns |
|---|---|
| `KitchenAid/Views/Recipes/RecipeLibraryView.swift` | Search, sort, filter chips, section index, over `RecipeLoader.all`. |
| `KitchenAid/Views/Recipes/RecipeCardRow.swift` | Title, total time, last made, "3 groups". No image. |
| `KitchenAid/Views/Recipes/RecipeFilterSheet.swift` | Tag / course / time / never-made, from `RecipeLoader.allTags`. |
| `KitchenAid/Views/Recipes/RecipeDetailView.swift` | The servings stepper that live-rescales, grouped ingredients, the flat method, notes, his tweaks called out, pinned Cook. |
| `KitchenAid/Views/Recipes/ComponentSectionView.swift` | One ingredient group. Renders no header when the recipe has a single unnamed group. |
| `KitchenAid/Views/Recipes/IngredientLineRow.swift` | Live-scaled quantity, preparation, the unmeasured note, an "edited" dot when an override applies. |
| `KitchenAid/Views/Recipes/RecipeMethodView.swift` | The flat 1–8 step list with per-step group pills. |
| `KitchenAid/Views/Recipes/RecipeNotesSection.swift` | The bundled note bullets, make-ahead called out, then his own notes. |
| `KitchenAid/Views/Recipes/RecipeUsageSection.swift` | "Used in 6 dishes" — computed from `RecipeLoader` over content references, not a stored edge. |
| `KitchenAid/Views/Recipes/TweakSheet.swift` | **The entire in-app editing surface.** Adjust one line's quantity, correct one step, type a note. Writes `IngredientOverride` / `StepOverride` / `RecipeTweak.notes`, with a per-row "back to as written". No authoring, no add-a-line, no add-a-step. |
| `KitchenAid/Views/Recipes/IngredientInboxView.swift` | Content ingredient lines that resolve to nothing in the catalogue, across all recipes, with "match to…" writing a `FoodItemAlias`. |

### `KitchenAid/Views/Cook/`

| Path | Owns |
|---|---|
| `KitchenAid/Views/Cook/CookModeView.swift` | The `fullScreenCover`. `isIdleTimerDisabled`, 20pt minimum body, 60pt tap targets. |
| `KitchenAid/Views/Cook/MiseEnPlaceView.swift` | Every group's ingredients at the chosen scale, make-ahead called out, before you start. |
| `KitchenAid/Views/Cook/CookStepList.swift` | The flat method; the whole row is the checkbox; completed steps dim but stay. |
| `KitchenAid/Views/Cook/CookIngredientHeader.swift` | Sticky, showing the scaled quantities for the group the current step touches. |
| `KitchenAid/Views/Cook/CookTimerBar.swift` | Concurrent `CookTimer` chips, with local notifications so a backgrounded app still rings. |
| `KitchenAid/Views/Cook/CookFinishSheet.swift` | Sets `lastMadeAt`, offers the inventory-depletion confirm, and offers one "note what you changed" field that writes `RecipeTweak.notes`. No rating, no photo, no duration. |

### `KitchenAid/Views/Plan/`

| Path | Owns |
|---|---|
| `KitchenAid/Views/Plan/PlanRootView.swift` | Scope switch. On iPhone the landing content is the week brief; the dense grid is iPad-only. |
| `KitchenAid/Views/Plan/WeekBriefView.swift` | "14 dinners planned, 3 takeout, 1 recipe you have never made, 3 things expiring." |
| `KitchenAid/Views/Plan/MonthCalendarView.swift` | Month grid with `.scrollTargetBehavior(.viewAligned)` paging. |
| `KitchenAid/Views/Plan/MonthDayCell.swift` | Slot dots, eater initial chips, guest badge, leftovers/takeout glyphs. A `.dropDestination`. |
| `KitchenAid/Views/Plan/WeekGridView.swift` | **iPad only.** 7 columns × slot rows of drop targets. |
| `KitchenAid/Views/Plan/DayPlanView.swift` | The day's meals, prep tasks, what is thawing. |
| `KitchenAid/Views/Plan/PlannedMealEditorSheet.swift` | Kind picker, recipe picker, the attendance grid, the guest stepper, leftovers source, scale override. |
| `KitchenAid/Views/Plan/AttendanceGrid.swift` | One chip per active member. Single tap cycles attending → away → maybe → leftoversOnly; long-press toggles full/half portion. Four taps for a four-person dinner, no sheet. |
| `KitchenAid/Views/Plan/DuplicateWeekSheet.swift` | "Same as last week" — the most-used action. |

### `KitchenAid/Views/Shop/`

| Path | Owns |
|---|---|
| `KitchenAid/Views/Shop/ShoppingListsView.swift` | History, archive. |
| `KitchenAid/Views/Shop/GenerateShoppingListSheet.swift` | Range presets, slot toggles, option switches, live preview counts from `preview()`. |
| `KitchenAid/Views/Shop/ShoppingListDetailView.swift` | Sectioned by aisle, check off, "Needs attention" pinned at top, "Already have" and "Staples (not checked)" as collapsed footers. |
| `KitchenAid/Views/Shop/ShoppingListLineRow.swift` | N subtotals, have in muted ink beside toBuy in full ink, flag badges. |
| `KitchenAid/Views/Shop/ShoppingLineDetailSheet.swift` | Provenance rows, the bridge-resolution affordance, destination location. |
| `KitchenAid/Views/Shop/ReceiveIntoInventorySheet.swift` | Checked lines → lots, posting the PURCHASE quantity. |
| `KitchenAid/Views/Shop/RegenerateDiffSheet.swift` | "3 new, 1 no longer needed, 2 changed quantity." |

### `KitchenAid/Views/Pantry/`

| Path | Owns |
|---|---|
| `KitchenAid/Views/Pantry/InventoryHomeView.swift` | Grouped by location, with running-low and expiring-soon banners and the two inbox badges. |
| `KitchenAid/Views/Pantry/LocationDetailView.swift` | One location's lots. |
| `KitchenAid/Views/Pantry/FoodItemDetailView.swift` | Lots, the transaction ledger as a timeline, aliases, density, section, tracking mode, par level, and the catalogue template it came from. |
| `KitchenAid/Views/Pantry/QuickAddStockView.swift` | Catalogue-backed name picker → quantity → location in three taps. **Picking, not typing.** |
| `KitchenAid/Views/Pantry/InventoryCountView.swift` | Walk a location and correct everything; writes `.inventoryCount` transactions. |
| `KitchenAid/Views/Pantry/UnresolvedDepletionsView.swift` | The `.pendingBridge` inbox. |
| `KitchenAid/Views/Pantry/ExpiringSoonView.swift` | What is about to go bad. |

### `KitchenAid/Views/Settings/`

| Path | Owns |
|---|---|
| `KitchenAid/Views/Settings/SettingsView.swift` | The sheet's root list. |
| `KitchenAid/Views/Settings/HouseholdView.swift` | `Eater` CRUD, colours, full-or-half portion, active toggle. No dietary section. |
| `KitchenAid/Views/Settings/AttendanceDefaultsView.swift` | The recurring attendance rules. |
| `KitchenAid/Views/Settings/StoreLayoutView.swift` | Stores and drag-to-reorder sections. |
| `KitchenAid/Views/Settings/StorageLocationsView.swift` | Locations and shelf lives. |
| `KitchenAid/Views/Settings/FoodItemCatalogView.swift` | His `FoodItem` rows: densities, sections, tracking mode, par levels. |
| `KitchenAid/Views/Settings/MergeFoodItemsView.swift` | The de-dup reconciliation and the `MergeRecord` log. |
| `KitchenAid/Views/Settings/ReconcileView.swift` | `LedgerDivergence` rows, surfaced not hidden. |
| `KitchenAid/Views/Settings/MissingRecipesView.swift` | Dangling `recipeID`s with their title snapshots, and "forget these rows" (§0.2). |
| `KitchenAid/Views/Settings/UnitPreferenceView.swift` | US / metric display. |
| `KitchenAid/Views/Settings/ExportView.swift` | Export jobs and `ShareLink`. |
| `KitchenAid/Views/Settings/StoreHealthView.swift` | Row counts, the store-failure detail, the schema version, `ContentDiagnostic`s from both loaders, and — when `sections.v1` has no `SeedRecord` because the catalogue failed to load — the "store sections not seeded yet" explanation (§8). |

### `KitchenAid/Views/Export/` — print views. **No `List`, no `ScrollView`, no `LazyVStack` anywhere inside these.**

| Path | Owns |
|---|---|
| `KitchenAid/Views/Export/PrintPage.swift` | `PrintPage` — one page's size and its boxed content. What `PDFPageWriter` iterates (§0.9.5). |
| `KitchenAid/Views/Export/PDFPreviewView.swift` | `PDFView` in a `UIViewRepresentable`, reusing `MMPDFReader`'s shape including the `@unchecked Sendable` box around the non-`Sendable` `PDFDocument`. |
| `KitchenAid/Views/Export/RecipePrintPage.swift` | Portrait 612×792. Ingredients left column, flat method right, notes footer. |
| `KitchenAid/Views/Export/ShoppingListPrintPage.swift` | Portrait, two columns by section, stroked checkbox glyphs, right-aligned `.monospacedDigit()` quantities, superscript source markers. |
| `KitchenAid/Views/Export/MealPlanWeekPrintPage.swift` | Landscape 792×612 week grid with the member-initial chip legend across the footer. |
| `KitchenAid/Views/Export/MealPlanHeadCountPrintPage.swift` | Head count per day per meal — its own page, including guests. |
| `KitchenAid/Views/Export/PrepAheadPrintPage.swift` | Every `.prep` entry and every make-ahead note in the range, in date order. |
| `KitchenAid/Views/Export/InventorySnapshotPrintPage.swift` | **The owner of `Job.inventorySnapshot`** (§0.9.5): one location or all, lots grouped by location with quantity, acquired and best-by, and an "unassigned lot" block. |
| `KitchenAid/Views/Export/ShoppingSourcesPrintBlock.swift` | The closing "Meals this list covers" block the superscripts key to. |
| `KitchenAid/Views/Export/PrintPrimitives.swift` | The page frame, hairline rule, checkbox glyph, chip, and the fixed print type scale. |

### `KitchenAid/Views/Root/` and `KitchenAid/Views/Components/`

| Path | Owns |
|---|---|
| `KitchenAid/Views/Root/StoreFailureBanner.swift` | The `\.storeUnavailable` banner: "running on a temporary store, your data on disk is untouched". |
| `KitchenAid/Views/Components/DesignComponents.swift` | Card, section header, empty-state card. |
| `KitchenAid/Views/Components/QuantityField.swift` | Amount + unit, with the dimension-scoped picker. |
| `KitchenAid/Views/Components/FractionKeypad.swift` | ½ ⅓ ¼ ⅔ ¾ ⅛ as one tap. |
| `KitchenAid/Views/Components/EaterChip.swift` | Initials in the member's colour. Shared by the grid, the calendar cell and the PDF legend. |
| `KitchenAid/Views/Components/StockPill.swift` | "have 1 lb" / "low" / "expires Tue". |
| `KitchenAid/Views/Components/FlagBadge.swift` | One shopping-line flag. |

### `KitchenAid/Utilities/` and `KitchenAid/Resources/`

| Path | Owns |
|---|---|
| `KitchenAid/Utilities/Theme.swift` | Colour tokens, `serif(_:weight:)`, radii, and the `\.storeUnavailable` `EnvironmentKey`. Warmer than CFAL3's parchment — kitchen, not daybook. |
| `KitchenAid/Utilities/KitchenAidFormatting.swift` | `Rational` → "1 1/3", unit pluralization, duration ranges ("7–8 min"), "About 35 minutes". |
| `KitchenAid/Utilities/AdaptiveLayout.swift` | The one place `horizontalSizeClass` decides brief-vs-grid. |
| `KitchenAid/Resources/Assets.xcassets` | App icon, accent colour. **No image assets for recipes or steps.** |
| `KitchenAid/Resources/ingredients.json` | The shipped catalogue. Built by `scripts/build_catalogue.py`; never hand-edited. |
| `KitchenAid/Resources/Recipes/*.json` | One file per recipe, named `<recipeID>.json`. Committed, immutable, added by the importer. |

### Tests

| Path | Owns |
|---|---|
| `KitchenAidTests/RationalTests.swift` | Reduction, overflow-reporting on all four operators, `approximating`, ceiling, and **`Codable` round-trip including a `denominator: 0` in the JSON**. Plus the two `Int.min` cases, which nothing else exercises: `Rational(Int.min, 1)` and `Rational(1, Int.min)` both yield zero rather than trapping, `(-2^62) * 2` reports overflow, and `Rational(approximating:)` at a value near the 1e15 bound with `maxDenominator: 10_000` terminates without trapping. |
| `KitchenAidTests/UnitCatalogTests.swift` | The full US volume ladder round-trip, and `1 cup == 240 mL` exactly. |
| `KitchenAidTests/QuantityMathTests.swift` | `2 tbsp + 1/4 cup == 6 tbsp`. **Count-noun partitioning, asserted as a partition that HOLDS**: `count:clove` and `count:head` on one line stay two subtotals, and `count:slice = 12` stays `count:slice = 12` — nothing folds one count noun into another. `collapseAcrossDimensions` merging a cup and a gram bucket at a known density, and declining with no density. `bridgeHave` converting a 4 oz mass lot against a 2 tbsp volume requirement at `gramsPerCup: 227`, and NOT raising `.needsBridge` when it succeeds. `displayUnit` including the `18 tsp → 6 tbsp` case that must not render as `3 fl oz`. |
| `KitchenAidTests/RecipeLoaderTests.swift` | Decodes every bundled recipe; asserts no duplicate ids, every `subRecipeID` and `sourceRecipeID` resolves, and the fixture decodes to the tree in §8.2. |
| `KitchenAidTests/IngredientCatalogTests.swift` | Decodes `ingredients.json`; asserts **all 16 of the fixture's ingredients resolve** by name or alias and land in a seeded aisle. |
| `KitchenAidTests/TweakStoreTests.swift` | An override applies; `effectiveRecipe` never mutates the loaded content; an override whose `lineID` no longer exists lapses silently and is reported. |
| `KitchenAidTests/MealScalingTests.swift` | 12-crostini/4-serving yields `scale = portions/4`. Half portions. Guest count. Batch snapping. No-attendance fallback. |
| `KitchenAidTests/RecipeGraphTests.swift` | By-value cycle guard: one sub-recipe used in two sibling branches contributes twice. Dimensional sub-recipe scale. Refusal when the yield is absent. |
| `KitchenAidTests/ShoppingListBuilderTests.swift` | The fixture's butter (2 tbsp) and **kosher salt (1 1/4 tsp, through the staple-diversion path)**. The 240 mL carton leaving no residue. **The baguette shipping as `12 slices`** — one count bucket, unfolded, which is what the list says now that purchase-unit rounding is cut (`CLAUDE.md`). **Garlic's `2 clove` against a `1 clove` lot leaving `1 clove`**, `.partiallyHave`, not "buy 1 head". `partiallyHave` on a half-covered line. `needsBridge` only when no bridge exists. Negative-have clamping. `.cooked` exclusion. Leftovers contributing nothing. |
| `KitchenAidTests/InventoryLedgerTests.swift` | FIFO order, orphaned-transaction accounting, `pendingBridge` writing, `LedgerDivergence` attribution. |
| `KitchenAidTests/FoodItemResolverTests.swift` | Catalogue-template creation, alias lookup, deterministic survivor, referrer repointing. |
| `KitchenAidUITests/…` | Launch on Today, cook a recipe, plan a meal, generate a list, export a PDF. Addressed by `accessibilityIdentifier`. |

**Four of these suites read the bundled fixture recipe** — `RecipeLoaderTests`,
`TweakStoreTests`, `MealScalingTests` and `ShoppingListBuilderTests` — and that file is **not
in the repo yet**: §8.1 is what generates and commits it. Generating it is therefore a
prerequisite of the first test run, not a later tidy.

---

## 2. The model layer

**This section is copied verbatim into the codebase.** It has two halves, and the split is
§0.2: `KitchenAid/Models/Content/` holds `Codable` value types decoded from the bundle, and
everything else is `@Model` obeying §0.4.

Counts, so nothing can drift: **6 content value types** — `Recipe`, `RecipeComponent`,
`IngredientLine`, `RecipeStep`, `RecipeNote`, `RecipeTag` — plus the six other value types
the manifest also places under `Models/Content/`: `RecipeFile`, `CatalogEntry`,
`CatalogFile`, `ContentDiagnostic`, `ResolvedRecipe` and its nested
`ResolvedRecipe.LapsedOverride`. Then **21 `@Model` classes**, matching
`KitchenAidSchemaV1.models` exactly (§2.28). The §1 `Models/Content/` folder listing
enumerates the same twelve.

### 2.0 One decoding rule for all content

Swift's synthesized `init(from:)` **does not fall back to a property's default value when
a key is absent** — it throws. These files are hand-authored and will grow keys over the
years, so every content type writes an explicit `init(from:)` built from
`decodeIfPresent(_:forKey:) ?? default`. A recipe written last year must keep decoding
after a field is added, and a recipe missing an optional field must not take the whole
library down with it.

`RecipeLoader` decodes each file individually and records a `ContentDiagnostic` for any
that fails, rather than aborting the launch. One malformed file costs one recipe.

**And one more rule, which exists because the importer is the author of these files.**
`scripts/import_recipe.py` is the only thing that writes a recipe file, so where its key
names differ from a property name here, **the decoder accepts the script's spelling** and
the script is not changed to suit Swift. Three places where that applies, each called out
at the type: `RecipeComponent` accepts `name` for `title`; `IngredientLine` accepts `name`
for `displayName`, `raw` for `rawText`, `qualifier` for `unmeasuredNote`, `unit` for
`unitCode`, and the script's **five flat quantity fields** (`hasQuantity`,
`amountNumerator`, `amountDenominator`, `unit`, `dimension`) in place of a nested `amount`
object; `RecipeStep` accepts `order` for `number`; and `RecipeNote` accepts a bare string.
The alternates are additive `decodeIfPresent` fallbacks, so a hand-written file using the
Swift spelling still decodes. **When the Swift decoder and the Python importer disagree,
the importer is right** — it is the one with a test that runs (§0.7).

### 2.1 `KitchenAid/Models/Content/Recipe.swift`

```swift
import Foundation

/// One recipe file. The envelope exists so a future content migration has a version to
/// branch on without re-reading every file to guess its shape.
///
/// It decodes BOTH shapes: `{"schemaVersion": 1, "recipe": {…}}`, and the flat
/// `{"schemaVersion": 1, "id": …, "title": …}` that `scripts/import_recipe.py` emits
/// directly. The flat form is what is actually committed, because it is the importer's
/// own output and a wrapping step that exists only to satisfy a Swift type is a step that
/// will eventually be forgotten. `schemaVersion` is read from the same object either way.
struct RecipeFile: Codable, Sendable {
    var schemaVersion: Int = 1
    var recipe: Recipe

    enum CodingKeys: String, CodingKey { case schemaVersion, recipe }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if let nested = try c.decodeIfPresent(Recipe.self, forKey: .recipe) {
            self.recipe = nested
        } else {
            // No `recipe` key: the whole object IS the recipe.
            self.recipe = try Recipe(from: decoder)
        }
    }

    init(schemaVersion: Int = 1, recipe: Recipe) {
        self.schemaVersion = schemaVersion
        self.recipe = recipe
    }
}

/// IMMUTABLE BUNDLED CONTENT. A value type, not a `@Model`.
///
/// Brandon writes a recipe in conversation, edits it, and the PDF is dropped into a Claude
/// Code session where `scripts/import_recipe.py` parses it and the JSON is committed to
/// `KitchenAid/Resources/Recipes/`. There is no authoring UI and there are no recipe rows
/// in the store. Everything he does to a recipe afterwards is a `RecipeTweak` overlay
/// keyed by `id` — the same split CFAL3 uses between `LOS` content and `LOSStudyStatus`.
///
/// ORDER IS FREE HERE. A JSON array is ordered, so components, lines, steps and notes need
/// no `sortIndex` — which is the one genuine simplification this split buys, since the
/// SwiftData side has to carry `sortIndex` on every ordered child precisely because a
/// to-many relationship does not preserve order.
struct Recipe: Codable, Identifiable, Hashable, Sendable {

    /// The stable id, and the file name: the fixture's
    /// `ny-strip-crostini-with-creamed-horseradish-spinach.json` holds
    /// `"ny-strip-crostini-with-creamed-horseradish-spinach"`. The importer assigns it as
    /// `slug(title)` — the FULL title, not an abbreviation, because an abbreviation is a
    /// second thing to keep in sync by hand and nothing reads the id aloud.
    /// A SLUG, not a UUID — the id is what every `MealRecipe`,
    /// `RecipeTweak` and `ShoppingListSource` stores, so it has to be readable in a diff
    /// and proofreadable by a human. **Once published, an id is never changed**: changing
    /// it dangles every row that references it (§0.2).
    var id: String = ""

    var title: String = ""
    var subtitle: String = ""
    var summary: String = ""

    // MARK: Yields — TWO independent numbers, and conflating them is the bug
    //
    // The fixture says "Makes: 12 crostini (serves 4)". Twelve is a produced-unit count;
    // four is a serving count; neither is derivable from the other. A single yield field
    // makes meal-plan scale = portions / 12, so planning this recipe for four people shops
    // for one third of every ingredient — and no zero-yield warning fires, because the
    // yield is not zero.
    //
    // `servings` is the ONLY value scaling divides by. `yieldAmount` is display, and it
    // scales alongside so six eaters reads "18 crostini".
    //
    // Stored as a numerator/denominator pair because a recipe can serve 2 1/2. The
    // importer writes a whole number as `"servings": 4`, which the decoder below accepts
    // into the pair.
    var servingsNumerator: Int = 4
    var servingsDenominator: Int = 1
    var yieldAmount: Rational? = nil
    var yieldUnitLabel: String = ""
    /// Verbatim, e.g. "12 crostini (serves 4)". Kept so a reparse is always possible.
    var yieldText: String = ""

    // MARK: Times — optional, never 0
    var activeMinutes: Int? = nil
    var totalMinutes: Int? = nil
    /// Both fixture times are prefixed "About", so the UI must not imply precision.
    var timesAreApproximate: Bool = true

    /// Continuous / halfBatches / wholeBatches. You cannot bake 1.4 loaves, and that is a
    /// property of the recipe, not of any one line.
    var batchGranularity: BatchGranularity = .continuous

    var course: CourseKind = .main
    var difficulty: Difficulty = .medium
    var cuisine: String = ""
    var sourceName: String = ""

    /// Hidden from the library but still resolvable by id. **This is how a recipe is
    /// retired** — see §0.2: deleting the file dangles every row that references it, and
    /// there is no cascade that can exist to clean them up.
    var isArchived: Bool = false
    /// A sauce or a stock: offered in the sub-recipe picker, de-emphasised in the library.
    var isReusableComponent: Bool = false

    /// Pulled out of the note bullets by the importer so the planner can surface it
    /// without re-reading prose. The note itself is NOT removed from `notes`.
    var makeAheadNote: String = ""

    /// The `pdftotext -layout` text this was parsed from, committed with it. Over years the
    /// importer improves, and a re-parse of 400 stored raw documents is a feature. It is
    /// also the only honest answer when a quantity on a shopping list looks wrong.
    var rawText: String = ""

    var addedAt: Date? = nil

    var tags: [RecipeTag] = []
    /// Ingredient GROUPS. They own lines, never steps.
    var components: [RecipeComponent] = []
    /// The method, FLAT and ordered across the whole dish.
    ///
    /// This is the single most-rebroken decision in the project. The fixture groups
    /// ingredients three ways but has ONE numbered 1–8 instruction list that moves freely
    /// between the groups: season the steak (1), toast the baguette (2), sear (3), wilt the
    /// spinach (5), assemble both (8). With steps nested under components the only
    /// representable method is all-steak-then-all-crostini, and the document's actual
    /// method cannot be stored. A component is NOT a self-contained mini-recipe.
    var steps: [RecipeStep] = []
    /// An ordered list, not a paragraph. The fixture's Notes section is four distinct
    /// ideas — make-ahead, key-step warning, variation, timing tip. Flattening them at
    /// import cannot be undone.
    var notes: [RecipeNote] = []

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, summary
        case servingsNumerator, servingsDenominator
        /// The importer's spelling: a single whole number (§2.0).
        case servings
        case yieldAmount, yieldUnitLabel, yieldText
        case activeMinutes, totalMinutes, timesAreApproximate
        case batchGranularity, course, difficulty, cuisine, sourceName
        case isArchived, isReusableComponent, makeAheadNote, rawText, addedAt
        case tags, components, steps, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        // The importer's `"servings": 4` wins when present; the explicit pair is the
        // hand-authored form for a recipe that serves 2 1/2.
        if let whole = try c.decodeIfPresent(Int.self, forKey: .servings) {
            self.servingsNumerator = whole
            self.servingsDenominator = 1
        } else {
            self.servingsNumerator = try c.decodeIfPresent(Int.self, forKey: .servingsNumerator) ?? 4
            self.servingsDenominator = try c.decodeIfPresent(Int.self, forKey: .servingsDenominator) ?? 1
        }
        self.yieldAmount = try c.decodeIfPresent(Rational.self, forKey: .yieldAmount)
        self.yieldUnitLabel = try c.decodeIfPresent(String.self, forKey: .yieldUnitLabel) ?? ""
        self.yieldText = try c.decodeIfPresent(String.self, forKey: .yieldText) ?? ""
        self.activeMinutes = try c.decodeIfPresent(Int.self, forKey: .activeMinutes)
        self.totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes)
        self.timesAreApproximate = try c.decodeIfPresent(Bool.self, forKey: .timesAreApproximate) ?? true
        self.batchGranularity = try c.decodeIfPresent(BatchGranularity.self, forKey: .batchGranularity) ?? .continuous
        self.course = try c.decodeIfPresent(CourseKind.self, forKey: .course) ?? .main
        self.difficulty = try c.decodeIfPresent(Difficulty.self, forKey: .difficulty) ?? .medium
        self.cuisine = try c.decodeIfPresent(String.self, forKey: .cuisine) ?? ""
        self.sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.isReusableComponent = try c.decodeIfPresent(Bool.self, forKey: .isReusableComponent) ?? false
        self.makeAheadNote = try c.decodeIfPresent(String.self, forKey: .makeAheadNote) ?? ""
        self.rawText = try c.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        self.addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        self.tags = try c.decodeIfPresent([RecipeTag].self, forKey: .tags) ?? []
        self.components = try c.decodeIfPresent([RecipeComponent].self, forKey: .components) ?? []
        self.steps = try c.decodeIfPresent([RecipeStep].self, forKey: .steps) ?? []
        self.notes = try c.decodeIfPresent([RecipeNote].self, forKey: .notes) ?? []
    }

    init(id: String = "", title: String = "") {
        self.id = id
        self.title = title
    }
}

extension Recipe {
    /// The scaling divisor. Guaranteed positive: a recipe whose servings were never set
    /// must not make `scale` explode or vanish.
    var servings: Rational {
        let r = Rational(servingsNumerator, max(1, servingsDenominator))
        return r > .zero ? r : .one
    }

    /// True when the recipe has exactly one unnamed ingredient group, which the UI renders
    /// with no header at all so a three-ingredient vinaigrette never shows the word "group".
    var hasSingleUnnamedComponent: Bool {
        components.count == 1 && components[0].title.isEmpty
    }

    var allLines: [IngredientLine] { components.flatMap(\.lines) }

    func component(at index: Int?) -> RecipeComponent? {
        guard let index, components.indices.contains(index) else { return nil }
        return components[index]
    }

    func line(id lineID: String) -> IngredientLine? {
        allLines.first { $0.lineID == lineID }
    }

    func step(id stepID: String) -> RecipeStep? {
        steps.first { $0.stepID == stepID }
    }

    /// Every other recipe this one reaches directly, for `RecipeLoader`'s reference check.
    var referencedRecipeIDs: [String] {
        components.compactMap(\.sourceRecipeID) + allLines.compactMap(\.subRecipeID)
    }

    /// The display yield at a given scale: 12 crostini × 3/2 reads "18 crostini".
    func scaledYieldLabel(at scale: Rational) -> String? {
        guard let q = yieldAmount, !yieldUnitLabel.isEmpty else { return nil }
        return "\((q * scale).mixedDescription) \(yieldUnitLabel)"
    }

    var makeAheadNotes: [RecipeNote] { notes.filter { $0.kind == .makeAhead } }
}
```

### 2.2 `KitchenAid/Models/Content/RecipeComponent.swift`

```swift
import Foundation

/// An ingredient GROUP — "Crostini and steak", "Creamed horseradish spinach",
/// "To finish". It owns ordered ingredient lines and NOTHING ELSE.
///
/// It deliberately does not own steps. See the long comment on `Recipe.steps`.
struct RecipeComponent: Codable, Hashable, Sendable {
    /// "" for a single-group recipe, which the UI then renders with no header.
    var title: String = ""
    var note: String = ""
    var kind: ComponentKind = .other
    var isOptional: Bool = false

    /// Set when this group IS another bundled recipe — "half a batch of the chimichurri".
    /// Its lines are read through `RecipeLoader` rather than duplicated here.
    ///
    /// An id that no longer resolves makes this an orphaned reference: the flattener emits
    /// `.orphanedComponentReference` and contributes nothing, and the UI renders
    /// "Chimichurri — recipe not bundled" rather than silently dropping a third of a dish.
    var sourceRecipeID: String? = nil
    var sourceScale: Rational = .one

    var makeAheadNote: String = ""
    var lines: [IngredientLine] = []

    enum CodingKeys: String, CodingKey {
        case title, note, kind, isOptional, sourceRecipeID, sourceScale, makeAheadNote, lines
        /// The importer's spelling for `title` (§2.0).
        case name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.kind = try c.decodeIfPresent(ComponentKind.self, forKey: .kind) ?? .other
        self.isOptional = try c.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
        self.sourceRecipeID = try c.decodeIfPresent(String.self, forKey: .sourceRecipeID)
        self.sourceScale = try c.decodeIfPresent(Rational.self, forKey: .sourceScale) ?? .one
        self.makeAheadNote = try c.decodeIfPresent(String.self, forKey: .makeAheadNote) ?? ""
        self.lines = try c.decodeIfPresent([IngredientLine].self, forKey: .lines) ?? []
    }

    init(title: String = "", kind: ComponentKind = .other, lines: [IngredientLine] = []) {
        self.title = title
        self.kind = kind
        self.lines = lines
    }

    /// A reference-only group: it names another recipe and carries no lines of its own.
    var isReference: Bool { sourceRecipeID != nil && lines.isEmpty }
}
```

### 2.3 `KitchenAid/Models/Content/IngredientLine.swift`

```swift
import Foundation

struct IngredientLine: Codable, Identifiable, Hashable, Sendable {

    /// THE OVERLAY JOIN KEY, and the one piece of content design the overlay forces.
    ///
    /// An `IngredientOverride` has to point at a line, and a line has no row id. So every
    /// line carries an authored stable id: the slugged ingredient name plus its occurrence
    /// number within the recipe — `butter-1`, `butter-2`, `kosher-salt-1`.
    ///
    /// Chosen over a positional id (`c1l3`) deliberately: a positional id silently
    /// re-points an override when a group or a line is reordered in a later revision of the
    /// file, which is the worst possible failure — his "1 tbsp not 2" lands on the wrong
    /// ingredient. A name-based id instead LAPSES when the ingredient itself changes, which
    /// is exactly when the override should stop applying. `TweakStore` reports a lapsed
    /// override rather than discarding it silently.
    var lineID: String = ""
    var id: String { lineID }

    // MARK: Quantity — genuinely optional
    //
    // "Pinch flaky salt" has no number. So do "to taste", "for garnish", "as needed". Such
    // a line must reach the shopping list as a PRESENCE item — never as 0, never dropped,
    // and never aggregated into "2 pinches". `amount == nil` means there is no quantity: it
    // never enters arithmetic, never suppresses a line, and cannot be confused with a parse
    // failure or a deliberate zero.
    //
    // ON THE WIRE this is the importer's FIVE FLAT FIELDS — `hasQuantity`,
    // `amountNumerator`, `amountDenominator`, `unit`, `dimension` — which is also decision
    // 9's persistence shape, so the file, the store and this type all say the same thing
    // with no translation layer. `hasQuantity: false` is exactly how "Pinch" arrives. The
    // decoder below folds the pair into `amount` and still accepts a nested
    // `"amount": {"numerator": …}` object or `"amount": "1 1/2"` from a hand-written file.
    var amount: Rational? = nil
    var unitCode: String = ""
    /// The resolved dimension, RECORDED rather than re-derived at read time.
    ///
    /// Bare "oz" is ambiguous and the fixture uses it as weight three times (16 oz steak,
    /// 10 oz spinach, 4 oz cream cheese). The importer resolves it by ingredient context
    /// ONCE; nothing downstream may guess again.
    var dimension: MeasureDimension = .unmeasured
    /// False when the importer guessed the dimension. Surfaced in the ingredient inbox, not
    /// as a blocking prompt — the recipe is already committed by then.
    var dimensionConfirmed: Bool = true
    /// "Pinch", "to taste", "for garnish" — round-trips verbatim.
    var unmeasuredNote: String = ""

    // MARK: Identity and display
    /// What the shopping list and the pantry match on: "shallot", not "shallot, minced".
    var displayName: String = ""
    /// "minced", "drained", "1/2 inch thick", "about 1.25 inches thick".
    ///
    /// Separate from the name so "1 cup onion, diced" and "1/2 cup onion, sliced" merge into
    /// "1 1/2 cups onion" on the list — you buy onions, not diced-ness — while both cook
    /// screens still say diced and sliced. A LENGTH in a recipe ("1/2 inch thick") is
    /// descriptive, not purchasable, and belongs here rather than in a quantity; there is
    /// deliberately no length dimension.
    var preparation: String = ""
    var note: String = ""
    /// The original line, exactly as `pdftotext` produced it, kept forever.
    ///
    /// Every comma-splitting parser is defeated by the fixture's "grated Parmesan", where
    /// the preparation adjective comes FIRST. This field is why that is recoverable rather
    /// than fatal: the parse is advisory, the raw text is truth, and the cook always sees it.
    var rawText: String = ""

    /// The catalogue entry's `name` (§0.3), or "" when the importer could not place it.
    /// NOT a `FoodItem` id: content cannot reference a row, and a row may not exist yet.
    /// `FoodItemResolver` turns this into a `FoodItem` on demand.
    var catalogName: String = ""
    /// One recipe consumed as a measured ingredient of another: "2 cups chicken stock".
    /// Distinct from `RecipeComponent.sourceRecipeID`, which means "this part of the dish
    /// IS that recipe".
    var subRecipeID: String? = nil

    var isOptional: Bool = false
    var isGarnish: Bool = false
    /// Tap water, ice for the bath. Never shopped.
    var excludeFromShopping: Bool = false
    /// `.fixed` is how "1 bay leaf" and the oil for the pan survive a 3× batch without
    /// becoming three bay leaves and a fistful of salt.
    var scalingRule: ScalingRule = .linear
    /// Buy it, or make it? A default only — the real decision is per shopping trip and is
    /// frozen onto the list so regenerating is reproducible.
    var subRecipePolicy: SubRecipePolicy = .treatAsItem

    enum CodingKeys: String, CodingKey {
        case lineID, amount, unitCode, dimension, dimensionConfirmed, unmeasuredNote
        case displayName, preparation, note, rawText, catalogName, subRecipeID
        case isOptional, isGarnish, excludeFromShopping, scalingRule, subRecipePolicy
        /// The importer's spellings (§2.0). `display` is read and discarded: it is the
        /// script's own rendering of the fraction, and `Rational.mixedDescription`
        /// reproduces it, so storing it would be a second copy that can disagree.
        case name, raw, qualifier, unit
        case hasQuantity, amountNumerator, amountDenominator
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lineID = try c.decode(String.self, forKey: .lineID)
        // The five flat fields first; a nested `amount` only if they are absent.
        var decodedAmount: Rational? = nil
        if try c.decodeIfPresent(Bool.self, forKey: .hasQuantity) == false {
            decodedAmount = nil
        } else if let n = try c.decodeIfPresent(Int.self, forKey: .amountNumerator) {
            let d = try c.decodeIfPresent(Int.self, forKey: .amountDenominator) ?? 1
            decodedAmount = Rational(n, d == 0 ? 1 : d)
        } else {
            decodedAmount = try c.decodeIfPresent(Rational.self, forKey: .amount)
        }
        let decodedDimension = try c.decodeIfPresent(MeasureDimension.self, forKey: .dimension)
            ?? .unmeasured
        self.amount = decodedAmount
        self.dimension = decodedDimension
        // A COUNT line with no unit column is how "1 shallot" arrives — the importer writes
        // `"unit": null, "dimension": "count"`. Falling back to the dimension's base unit
        // keeps it a count of one `each` instead of silently losing the quantity, because
        // `UnitCatalog.unit(code: "")` returns nil and `quantity` would then be nil.
        self.unitCode = try c.decodeIfPresent(String.self, forKey: .unitCode)
            ?? c.decodeIfPresent(String.self, forKey: .unit)
            ?? (decodedAmount == nil ? "" : decodedDimension.baseUnitCode)
        self.dimensionConfirmed = try c.decodeIfPresent(Bool.self, forKey: .dimensionConfirmed) ?? true
        self.unmeasuredNote = try c.decodeIfPresent(String.self, forKey: .unmeasuredNote)
            ?? c.decodeIfPresent(String.self, forKey: .qualifier)
            ?? ""
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        self.preparation = try c.decodeIfPresent(String.self, forKey: .preparation) ?? ""
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
            ?? c.decodeIfPresent(String.self, forKey: .raw)
            ?? ""
        self.catalogName = try c.decodeIfPresent(String.self, forKey: .catalogName) ?? ""
        self.subRecipeID = try c.decodeIfPresent(String.self, forKey: .subRecipeID)
        self.isOptional = try c.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
        self.isGarnish = try c.decodeIfPresent(Bool.self, forKey: .isGarnish) ?? false
        self.excludeFromShopping = try c.decodeIfPresent(Bool.self, forKey: .excludeFromShopping) ?? false
        self.scalingRule = try c.decodeIfPresent(ScalingRule.self, forKey: .scalingRule) ?? .linear
        self.subRecipePolicy = try c.decodeIfPresent(SubRecipePolicy.self, forKey: .subRecipePolicy) ?? .treatAsItem
    }

    init(lineID: String, displayName: String) {
        self.lineID = lineID
        self.displayName = displayName
    }
}

extension IngredientLine {
    /// nil means THERE IS NO QUANTITY. An unknown `unitCode` degrades to a count noun in
    /// its own bucket rather than zeroing the amount — see `UnitCatalog.unit(code:…)`.
    var quantity: Quantity? {
        guard let amount,
              let unit = UnitCatalog.unit(code: unitCode, fallbackDimension: dimension)
        else { return nil }
        return Quantity(amount: amount, unit: unit)
    }

    var quantityDisplay: String { quantity?.displayString() ?? unmeasuredNote }

    /// What the cook reads. Always prefers the verbatim line when there is one, because the
    /// parse is advisory.
    var cookDisplayText: String {
        rawText.isEmpty
            ? [quantityDisplay, displayName, preparation].filter { !$0.isEmpty }.joined(separator: " ")
            : rawText
    }
}
```

### 2.4 `KitchenAid/Models/Content/RecipeStep.swift`

```swift
import Foundation

/// One step of the method. FLAT and recipe-ordered; `componentIndex` is an optional tag
/// into `Recipe.components`, used by the cook-mode sticky header and the per-step group
/// pill. Nothing reaches a step through a component, so there is no "which parent wins"
/// question for a renderer, an exporter or a cook screen to get wrong.
struct RecipeStep: Codable, Identifiable, Hashable, Sendable {

    /// Stable, authored, and the `StepOverride` join key. **Slug-of-title plus an
    /// occurrence number**, exactly as `scripts/import_recipe.py` assigns it:
    /// `"sear-the-steak-1"`, `"rest-the-steak-1"`.
    ///
    /// Name-based for the same reason `lineID` is (§2.3), and emphatically NOT `"step-3"`:
    /// a positional id re-points "step 6 should say 3 minutes" onto whatever step 6 became
    /// when a step was inserted above it. A title-based id lapses instead, visibly, which
    /// is when it should. `number` still carries the printed 1–8 ordering; the occurrence
    /// suffix exists for the rare method that titles two steps the same.
    var stepID: String = ""
    var id: String { stepID }
    var number: Int = 0

    /// Every step in the fixture is "Title (duration). Body" — "Season the steak (30 min).
    /// Pat the steak dry and season all over with…". Split so cook mode can show the title
    /// big and the body small, and so the duration is a timer rather than prose.
    var title: String = ""
    /// Verbatim, including any temperatures. Never rewritten, so a later extraction pass
    /// needs no re-import.
    var body: String = ""

    /// Equal when the document gives a single value, both nil when it gives none. NOT
    /// `Int = 0`: the fixture's step 7 ("Slice the steak") and step 8 ("Assemble") have no
    /// duration at all, and step 3's is the RANGE "7 to 8 min".
    var minMinutes: Int? = nil
    var maxMinutes: Int? = nil

    /// Step 2 has an oven temperature (400F) and step 3 an internal target (125F). One
    /// field cannot hold both, and `0` is a real temperature.
    var ovenTemperatureF: Int? = nil
    var targetInternalTemperatureF: Int? = nil

    /// "Let it sit at room temperature" — nothing to do but wait. Drives the prep-ahead PDF
    /// page and the planner's `.prep` suggestion.
    var isPassiveRest: Bool = false
    var timerLabel: String = ""
    var componentIndex: Int? = nil

    enum CodingKeys: String, CodingKey {
        case stepID, number, title, body, minMinutes, maxMinutes
        case ovenTemperatureF, targetInternalTemperatureF, isPassiveRest, timerLabel, componentIndex
        /// The importer's spelling for `number` (§2.0).
        case order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.stepID = try c.decode(String.self, forKey: .stepID)
        self.number = try c.decodeIfPresent(Int.self, forKey: .number)
            ?? c.decodeIfPresent(Int.self, forKey: .order)
            ?? 0
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        self.minMinutes = try c.decodeIfPresent(Int.self, forKey: .minMinutes)
        self.maxMinutes = try c.decodeIfPresent(Int.self, forKey: .maxMinutes)
        self.ovenTemperatureF = try c.decodeIfPresent(Int.self, forKey: .ovenTemperatureF)
        self.targetInternalTemperatureF = try c.decodeIfPresent(Int.self, forKey: .targetInternalTemperatureF)
        self.isPassiveRest = try c.decodeIfPresent(Bool.self, forKey: .isPassiveRest) ?? false
        self.timerLabel = try c.decodeIfPresent(String.self, forKey: .timerLabel) ?? ""
        self.componentIndex = try c.decodeIfPresent(Int.self, forKey: .componentIndex)
    }

    init(stepID: String, number: Int, title: String = "", body: String = "") {
        self.stepID = stepID
        self.number = number
        self.title = title
        self.body = body
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

### 2.5 `KitchenAid/Models/Content/RecipeNote.swift` and `RecipeTag.swift`

```swift
// RecipeNote.swift
import Foundation

/// One note bullet.
///
/// A list element rather than a paragraph, because the fixture's Notes section is four
/// separate ideas: "the spinach can be made a day ahead" (make-ahead), "squeezing the
/// spinach dry is the key step" (warning), "for a sharper bite, stir in extra horseradish"
/// (variation), "toast the baguette just before serving" (timing). One of them is
/// semantically the make-ahead flag the meal planner wants. Flattening them into a
/// paragraph on import cannot be undone.
struct RecipeNote: Codable, Hashable, Sendable {
    var text: String = ""
    /// Classified on import by a keyword pass. Advisory; nothing branches on it except the
    /// make-ahead call-out and the prep-ahead PDF page.
    var kind: NoteKind = .general

    enum CodingKeys: String, CodingKey { case text, kind }

    init(from decoder: Decoder) throws {
        // A note may be a bare string — which is what `scripts/import_recipe.py` emits,
        // since the bullet text is all it can know — or an object once a kind has been
        // classified. The bare form decodes to `.general`, and the classification pass is
        // what turns the fixture's first bullet into `.makeAhead` (§8.1).
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            self.text = text
            self.kind = .general
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.kind = try c.decodeIfPresent(NoteKind.self, forKey: .kind) ?? .general
    }

    init(text: String, kind: NoteKind = .general) {
        self.text = text
        self.kind = kind
    }
}
```

```swift
// RecipeTag.swift
import Foundation

/// A tag, as CONTENT.
///
/// In the panel this was a `@Model` with a many-to-many edge to `Recipe`, which is also
/// where its first blocking defect lived — `inverse:` declared on both sides, which
/// SwiftData rejects. With recipes bundled, a tag is just a word the recipe file carries,
/// the library's filter chips come from `RecipeLoader.allTags`, and renaming a tag is a
/// find-and-replace in the repo rather than a write. There is no many-to-many left in this
/// schema at all (§0.9.1).
struct RecipeTag: Codable, Hashable, Sendable, Identifiable {
    var name: String = ""
    var kind: TagKind = .general
    var id: String { "\(kind.rawValue):\(name.lowercased())" }

    enum CodingKeys: String, CodingKey { case name, kind }

    init(from decoder: Decoder) throws {
        // A tag may be written either as a bare string — "weeknight" — or as an object.
        // The bare form is what a human types in a JSON file, and refusing it would make
        // every recipe file noisier for no gain.
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self.name = name
            self.kind = .general
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.kind = try c.decodeIfPresent(TagKind.self, forKey: .kind) ?? .general
    }

    init(name: String, kind: TagKind = .general) {
        self.name = name
        self.kind = kind
    }
}
```

### 2.6 `KitchenAid/Models/Content/CatalogEntry.swift`

```swift
import Foundation

/// `KitchenAid/Resources/ingredients.json`, decoded field-for-field as
/// `scripts/build_catalogue.py` emits it. **These names are the script's names.** If the
/// script changes a key, this file changes with it in the same commit, and
/// `IngredientCatalogTests` is what catches the mismatch.
struct CatalogFile: Codable, Sendable {
    var version: Int = 1
    /// **The authoritative store walk order**, emitted by the build script's
    /// `AISLE_WALK_ORDER` (§0.3). `items` is sorted alphabetically by aisle, which is not a
    /// walk order, so the order travels separately — and the app READS this rather than
    /// keeping a second copy in the seed, because two copies of a list drift and no test
    /// here can catch it.
    var aisleOrder: [String] = []
    var items: [CatalogEntry] = []

    enum CodingKeys: String, CodingKey { case version, aisleOrder, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.aisleOrder = try c.decodeIfPresent([String].self, forKey: .aisleOrder) ?? []
        self.items = try c.decodeIfPresent([CatalogEntry].self, forKey: .items) ?? []
    }
}

/// One catalogue entry: the TEMPLATE a `FoodItem` is created from (§0.3). Not a row, not
/// seeded into the store, and never written to.
struct CatalogEntry: Codable, Hashable, Sendable, Identifiable {
    /// The canonical name, collision-free by construction — the build script fails on a
    /// duplicate, and on an alias colliding with a name or another alias. This is the value
    /// `FoodItem.catalogName` stores.
    var name: String = ""
    var id: String { name }
    /// The store section, which is also a seeded `StoreSection.name` (§8).
    var aisle: String = ""
    /// mass | volume | count. Decides what can be ADDED to what, and is the reason
    /// "16 oz steak" never becomes a volume.
    var dimension: MeasureDimension = .count
    /// The unit to default to when he adds this by hand.
    var unit: String = "each"
    /// The unit to prefer when the recipe is a bake — 300 g of bread flour, not 2 1/2 cups,
    /// because volume measurement of flour varies by up to 20% and that is the difference
    /// between bread and a brick. nil = use `unit`.
    var bakingUnit: String? = nil
    /// Grams per US cup, or nil when the density is not settled. **nil means the app
    /// REFUSES to convert**, which is the whole point: kosher salt is deliberately absent
    /// from the script's table because Diamond Crystal is ~142 g/cup and Morton ~288.
    var gramsPerCup: Int? = nil
    /// Tracked present/absent with no quantity.
    var staple: Bool = false
    var aliases: [String] = []

    enum CodingKeys: String, CodingKey {
        case name, aisle, dimension, unit, bakingUnit, gramsPerCup, staple, aliases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.aisle = try c.decodeIfPresent(String.self, forKey: .aisle) ?? ""
        self.dimension = try c.decodeIfPresent(MeasureDimension.self, forKey: .dimension) ?? .count
        self.unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? "each"
        self.bakingUnit = try c.decodeIfPresent(String.self, forKey: .bakingUnit)
        self.gramsPerCup = try c.decodeIfPresent(Int.self, forKey: .gramsPerCup)
        self.staple = try c.decodeIfPresent(Bool.self, forKey: .staple) ?? false
        self.aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

extension CatalogEntry {
    var defaultUnit: KitchenUnit? { UnitCatalog.unit(code: unit, fallbackDimension: dimension) }
    var trackingMode: StockTrackingMode { staple ? .staple : .tracked }
    var matchKey: String { NameNormalizer.matchKey(name) }
    var aliasMatchKeys: [String] { aliases.map(NameNormalizer.matchKey) }
}
```

### 2.7 `KitchenAid/Models/Content/ContentDiagnostic.swift`

```swift
import Foundation

/// What a loader reports instead of trapping. Bundled content is committed, reviewed and
/// read-only, so a malformed file is a build-time mistake — but it must not be a crash on
/// a phone in a kitchen. One bad file costs one recipe, and `StoreHealthView` says which.
struct ContentDiagnostic: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case decodeFailed
        case duplicateID
        case missingReference      // a subRecipeID or sourceRecipeID that resolves to nothing
        case emptyRecipe           // no components AND no steps
        case duplicateLineID       // two lines in one recipe share a lineID — overrides would collide
        case unknownAisle          // a catalogue aisle with no seeded StoreSection
    }
    var id = UUID()
    var kind: Kind
    var fileName: String
    var detail: String
}
```

---

### 2.8 Delete rules and inverse placement, in one table

Each edge appears once. The macro lives on the side shown in bold; the other side is a bare
optional with a comment pointing here. **Every edge below is one-to-many or one-to-one —
there is no many-to-many in this schema** (§0.9.1), so the both-sides-inverse defect cannot
recur.

| Edge | Macro side | Rule | Why |
|---|---|---|---|
| RecipeTweak → **ingredientOverrides** | RecipeTweak | `.cascade` | An override has no life without the tweak row that groups it. |
| RecipeTweak → **stepOverrides** | RecipeTweak | `.cascade` | Same. |
| FoodItem → **aliases** | FoodItem | `.cascade` | An alias for a deleted item is nothing. |
| FoodItem → **lots**, **transactions** | FoodItem | **`.nullify`** | **Decision 7.** A cascade means one stray `.onDelete` torches the ledger. `foodItemNameSnapshot` on both keeps an orphan readable, and `FoodItemResolver.canDelete` refuses any item with history and offers "merge into…" instead — but the *schema* is what guarantees nothing is destroyed. |
| FoodItem ← **shoppingLines** | FoodItem | `.nullify` | Deleting an item must never eat a printed list. |
| StockLot → **transactions** | StockLot | `.nullify` | **Decision 8.** The lot is a cache home, not the parent. An orphan still contributes to `level(of:)` through the item, in an "unassigned lot" bucket, so divergence stays attributable. |
| StorageLocation ← **lots**, **foodItems**, **shoppingLines** | StorageLocation | `.nullify` | |
| Store → **sections** | Store | `.cascade` | A section belongs to its store's geography. |
| Store ← **shoppingLists** | Store | `.nullify` | Deleting a store must not delete last month's trips. |
| StoreSection ← **foodItems** | StoreSection | `.nullify` | |
| Eater → **attendanceDefaults** | Eater | `.cascade` | A rule about a person is meaningless without them. |
| Eater ← **attendance** | Eater | `.nullify` | History survives the person. `eaterNameSnapshot` carries the name. |
| PlannedMeal → **mealRecipes**, **attendance** | PlannedMeal | `.cascade` | Meaningless without their meal. |
| PlannedMeal → **leftoverMeals** (`PlannedMeal.leftoversFrom`) | PlannedMeal | `.nullify` | Tuesday's leftovers become an ordinary meal, not a deletion. A self-relationship still names its inverse explicitly. |
| PlannedMeal ← **shoppingSources**, **inventoryTransactions** | PlannedMeal | `.nullify` | Deleting a meal leaves the already-bought line and the already-recorded depletion alone. |
| ShoppingList → **lines** → **subtotals**, **sources** | each parent | `.cascade` | A list is one document. |
| ShoppingList ← **receivedTransactions** | ShoppingList | `.nullify` | Archiving a list must not un-buy the groceries. |

**Edges that do NOT exist, and why.** Every one of these was a `@Relationship` in the panel
and is now a stored `recipeID: String` plus a title snapshot, because SwiftData cannot hold
a relationship to a non-model type (§0.2):

| Panel edge | Replacement | Snapshot that keeps it readable |
|---|---|---|
| `Recipe.plannedMeals` ↔ `MealRecipe.recipe` | `MealRecipe.recipeID` | `MealRecipe.recipeTitleSnapshot` |
| `Recipe.components` / `.steps` / `.notes` / `.tags` | content arrays inside the JSON | — |
| `Recipe.usedAsComponentIn` / `.usedAsIngredientIn` | computed by `RecipeLoader` over `Recipe.referencedRecipeIDs` | — |
| `Recipe.mirrorFoodItems` ↔ `FoodItem.producedByRecipe` | `FoodItem.producedByRecipeID` | `FoodItem.name` is already the label |
| `Recipe.cookLog` ↔ `CookLogEntry.recipe` | **cut** (§0.5) — history is `RecipeTweak.lastMadeAt` | — |
| `IngredientLine.foodItem` ↔ `FoodItem.ingredientLines` | `IngredientLine.catalogName`, resolved on demand | `displayName` + `rawText` |
| `ShoppingListSource.recipeID: UUID?` | `ShoppingListSource.recipeID: String` | `recipeTitle` |

**The delimited-`String` exceptions, and the rule that admits them.** Rule 6 forbids a
stored *array* attribute for data two devices might both append to. A delimited `String` is
still a single last-writer-wins field, so it is admissible **only** where the value is
written exactly once, by one writer, and never appended to afterwards. Every use is listed
here; anything not on this list must be rows. **Six fields across four justifications** —
the count §0.4 rule 6 quotes, and the reason it is two numbers and not one is that two
rows below each hold a pair written by the same writer in the same breath.

| Field | Written by | Why a blob is safe |
|---|---|---|
| `FoodItem.aliasBlob` | `FoodItemResolver.reindex(_:)` | A **derived index** over the `FoodItemAlias` rows. The rows are the truth and both survive a merge; this exists only so alias lookup is a `#Predicate` rather than a full-catalogue fetch-and-scan on every line resolution. Rebuilt, never appended. |
| `ShoppingListLine.flagsBlob` | the generator, once | A generated line is a frozen historical record. `flagsBlob.contains("\|needsBridge\|")` is also predicate-queryable, which a `[String]` is not. |
| `ShoppingList.slotsBlob`, `ShoppingList.expandedLineIDBlob` | the generator, once | The frozen build options. There is deliberately **no** `includedMealIDs` blob: the live `ShoppingListSource.plannedMeal` edges *are* the included set, and they are queryable and re-pointable. |
| `MergeRecord.absorbedIDBlob`, `absorbedNameBlob` | `FoodItemResolver.merge` | An audit row, written once at the merge. |

`RecipeTweak.notes` is a plain `String` and is **not** on that list, because it is not a
blob encoding a collection — it is one free-text field he edits. It is last-writer-wins
across devices, and that is the deliberate choice: a per-note row carrying a date is a
cooking journal, which he declined (§0.5). One field he rewrites is a tweak; a list of
dated entries is the thing he said no to.

### 2.9 `KitchenAid/Models/Overlay/RecipeTweak.swift`

```swift
import Foundation
import SwiftData

/// THE OVERLAY. One row per recipe id he has actually touched.
///
/// This is `LOSStudyStatus` for recipes: bundled content is immutable, so everything the
/// user does to a recipe lives here, keyed by the content's stable string id. **A tweak
/// never mutates bundled content** — `TweakStore.effectiveRecipe(id:)` applies the overlay
/// to a COPY of the decoded value and hands that to the views.
///
/// Rows are created lazily. A recipe he has never favourited, never made and never adjusted
/// has no row at all, so the store stays proportional to what he has done rather than to
/// what is bundled.
///
/// `recipeID` is deliberately not unique — CloudKit forbids `@Attribute(.unique)`, so two
/// offline devices can both create a tweak for the same recipe. `TweakStore.tweak(for:)`
/// fetches with `fetchLimit` 1 ordered by `createdAt` then `id.uuidString` so both devices
/// converge on the same survivor, and `KitchenAidMaintenance` folds duplicates: notes are
/// concatenated once with a separator, `lastMadeAt` takes the later date, and override rows
/// are re-parented. The same deterministic-survivor discipline as `FoodItemResolver` (§5.1).
@Model
final class RecipeTweak {
    var id: UUID = UUID()

    /// The content id (§2.1). Allowed to dangle — see §0.2.
    var recipeID: String = ""
    /// Written when the row is created, so `MissingRecipesView` can name a recipe whose
    /// file is gone.
    var recipeTitleSnapshot: String = ""

    /// **The whole of cooking history.** No log rows, no ratings, no durations, no
    /// per-cook notes — he was offered a journal and declined it (§0.5). `nil` means never
    /// made, which the library and the Today screen both surface.
    var lastMadeAt: Date? = nil

    /// His notes on this recipe: "too much horseradish, 1 tbsp next time". One free-text
    /// field, not a list of dated entries. See the note under §2.8.
    var notes: String = ""

    /// Belongs on the overlay rather than in the JSON, because it is a fact about him and
    /// not about the recipe.
    var isFavorite: Bool = false

    var createdAt: Date = .now
    var updatedAt: Date = .now

    @Relationship(deleteRule: .cascade, inverse: \IngredientOverride.tweak)
    var ingredientOverrides: [IngredientOverride]? = []

    @Relationship(deleteRule: .cascade, inverse: \StepOverride.tweak)
    var stepOverrides: [StepOverride]? = []

    init(
        id: UUID = UUID(),
        recipeID: String = "",
        recipeTitleSnapshot: String = "",
        lastMadeAt: Date? = nil,
        notes: String = "",
        isFavorite: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.recipeID = recipeID
        self.recipeTitleSnapshot = recipeTitleSnapshot
        self.lastMadeAt = lastMadeAt
        self.notes = notes
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension RecipeTweak {
    var orderedIngredientOverrides: [IngredientOverride] {
        (ingredientOverrides ?? []).sorted { $0.lineID < $1.lineID }
    }

    var orderedStepOverrides: [StepOverride] {
        (stepOverrides ?? []).sorted { $0.stepID < $1.stepID }
    }

    func ingredientOverride(lineID: String) -> IngredientOverride? {
        (ingredientOverrides ?? []).first { $0.lineID == lineID }
    }

    func stepOverride(stepID: String) -> StepOverride? {
        (stepOverrides ?? []).first { $0.stepID == stepID }
    }

    /// True when this row is carrying nothing and can be dropped by maintenance.
    var isEmpty: Bool {
        lastMadeAt == nil && notes.isEmpty && !isFavorite
            && (ingredientOverrides ?? []).isEmpty && (stepOverrides ?? []).isEmpty
    }
}
```

### 2.10 `KitchenAid/Models/Overlay/IngredientOverride.swift`

```swift
import Foundation
import SwiftData

/// "That line says 2 tbsp; it should say 1." One row per overridden ingredient line.
///
/// It carries the five flat quantity primitives behind `QuantityCarrying` — the same shape
/// as everything else that holds a quantity, and for the same reason (§0.10, decision 9).
/// An existing row with `hasQuantity == false` means "this line has no measured quantity
/// any more", which is the `Pinch` representation applied to an override; it is NOT "no
/// override", because no override is the absence of the row.
@Model
final class IngredientOverride: QuantityCarrying {
    var id: UUID = UUID()

    /// `IngredientLine.lineID`. A name-based authored id, so an override LAPSES when the
    /// ingredient changes rather than silently re-pointing when lines are reordered —
    /// see the long comment on `IngredientLine.lineID`.
    var lineID: String = ""
    /// So a lapsed override can be shown and explained instead of vanishing.
    var lineTextSnapshot: String = ""

    // MARK: The five flat primitives
    var hasQuantity: Bool = false
    var amountNumerator: Int = 0
    var amountDenominator: Int = 1
    var unitCode: String = ""
    var dimensionRaw: String = MeasureDimension.unmeasured.rawValue

    /// "" = leave the bundled preparation alone. There is deliberately no name override:
    /// changing what an ingredient IS is authoring, not a tweak (§0.5).
    var preparationOverride: String = ""
    var note: String = ""
    var createdAt: Date = .now

    /// Owner. Macro lives on `RecipeTweak.ingredientOverrides`.
    var tweak: RecipeTweak? = nil

    init(
        id: UUID = UUID(),
        lineID: String = "",
        lineTextSnapshot: String = "",
        hasQuantity: Bool = false,
        amountNumerator: Int = 0,
        amountDenominator: Int = 1,
        unitCode: String = "",
        dimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        preparationOverride: String = "",
        note: String = "",
        createdAt: Date = .now,
        tweak: RecipeTweak? = nil
    ) {
        self.id = id
        self.lineID = lineID
        self.lineTextSnapshot = lineTextSnapshot
        self.hasQuantity = hasQuantity
        self.amountNumerator = amountNumerator
        self.amountDenominator = amountDenominator
        self.unitCode = unitCode
        self.dimensionRaw = dimensionRaw
        self.preparationOverride = preparationOverride
        self.note = note
        self.createdAt = createdAt
        self.tweak = tweak
    }
}
```

### 2.11 `KitchenAid/Models/Overlay/StepOverride.swift`

```swift
import Foundation
import SwiftData

/// "Step 6 should say 3 minutes, and the body is wrong." One row per corrected step.
///
/// `hasMinutesOverride` exists because `Int?` alone cannot distinguish "no override" from
/// "overridden to no duration". Zero is never an absent sentinel (§0.4.8), and a step he
/// has decided is untimed must be expressible.
@Model
final class StepOverride {
    var id: UUID = UUID()

    /// `RecipeStep.stepID`.
    var stepID: String = ""
    var stepTitleSnapshot: String = ""

    /// "" = leave the bundled text alone.
    var titleOverride: String = ""
    var bodyOverride: String = ""

    var hasMinutesOverride: Bool = false
    var minMinutes: Int? = nil
    var maxMinutes: Int? = nil

    var note: String = ""
    var createdAt: Date = .now

    /// Owner. Macro lives on `RecipeTweak.stepOverrides`.
    var tweak: RecipeTweak? = nil

    init(
        id: UUID = UUID(),
        stepID: String = "",
        stepTitleSnapshot: String = "",
        titleOverride: String = "",
        bodyOverride: String = "",
        hasMinutesOverride: Bool = false,
        minMinutes: Int? = nil,
        maxMinutes: Int? = nil,
        note: String = "",
        createdAt: Date = .now,
        tweak: RecipeTweak? = nil
    ) {
        self.id = id
        self.stepID = stepID
        self.stepTitleSnapshot = stepTitleSnapshot
        self.titleOverride = titleOverride
        self.bodyOverride = bodyOverride
        self.hasMinutesOverride = hasMinutesOverride
        self.minMinutes = minMinutes
        self.maxMinutes = maxMinutes
        self.note = note
        self.createdAt = createdAt
        self.tweak = tweak
    }
}
```

### 2.12 `KitchenAid/Models/Catalog/FoodItem.swift`

```swift
import Foundation
import SwiftData

/// The thing actually in the house. The only row that means "a thing in my kitchen".
///
/// It is NOT the catalogue. `KitchenAid/Resources/ingredients.json` is the shipped
/// catalogue of a few hundred TEMPLATES (§0.3); a `FoodItem` is minted from one by
/// `FoodItemResolver.findOrCreate` the first time something is actually needed, copying the
/// template's dimension, density and staple flag and resolving its aisle, so he can then
/// override any of them. The density copies as BOTH `hasDensity` and the `gramsPerCup`
/// pair, because the accessor below returns nil without the Bool. The template's **unit is
/// not copied — there is no unit field here to copy it into**; a default unit is read live
/// as `catalog.entry(named: catalogName)?.defaultUnit` (§0.3, §2.6).
/// After that the row is his and `catalogName` is only provenance.
///
/// The catalogue is deliberately NOT seeded into the store: 668 mostly-empty rows make
/// every pantry screen a filter over nothing and make a catalogue rebuild a migration.
@Model
final class FoodItem {
    var id: UUID = UUID()
    var name: String = ""

    /// Normalized `name`, used for identity matching. Deliberately NOT unique:
    /// CloudKit-backed stores reject `@Attribute(.unique)`, so two devices offline can and
    /// will both create "Shallot". The constraint does not exist; `FoodItemResolver` plus
    /// its deterministic merge pass is what actually keeps this single-rowed.
    var matchKey: String = ""

    /// The `CatalogEntry.name` this row was created from, or "" for a row he invented. A
    /// STRING by design: the catalogue is built by a Python script and has no UUIDs, and it
    /// must stay diffable in git.
    var catalogName: String = ""

    /// A DERIVED INDEX over the `aliases` rows — "|scallion|spring onion|" — rebuilt by
    /// `FoodItemResolver.reindex(_:)` whenever a row is added or merged.
    ///
    /// It exists only so alias lookup can be a `#Predicate` (`aliasBlob.contains`) instead
    /// of fetching and scanning the whole store on every line resolution, forever. The ROWS
    /// are the truth. Never append to this directly; add a `FoodItemAlias` and reindex, or a
    /// CloudKit merge of two devices that each added an alias silently loses one and
    /// "scallion" and "green onion" stop collapsing. **Shipped aliases are not in here** —
    /// they stay in the catalogue and are consulted after this.
    var aliasBlob: String = ""

    /// `StockTrackingMode`: tracked / staple / untracked. Seeded from `CatalogEntry.staple`.
    ///
    /// Salt, pepper, every oil, every vinegar and every spice are `.staple`: assumed
    /// present, never depleted, and never shopped unless `isRunningLow` or a par level
    /// trips. Without this the app demands he inventory his salt and he abandons it in week
    /// two. Staples still AGGREGATE fully and are shown with their summed quantity in a
    /// collapsed footer — decision 18, which is why the fixture's 1 tsp + 1/4 tsp kosher
    /// salt is a live test case and not a skipped path.
    var trackingModeRaw: String = StockTrackingMode.tracked.rawValue
    var isRunningLow: Bool = false

    // MARK: Volume <-> mass bridge
    //
    // Stored as an integer pair, not a Double. The whole reason `Rational` exists is to keep
    // Doubles out of the arithmetic, and a density that arrives as a Double and is then
    // `Rational(approximating:)`-ed reintroduces the imprecision at the one point it
    // matters. The catalogue says 120 for flour; that is 120/1 exactly.
    var hasDensity: Bool = false
    var gramsPerCupNumerator: Int = 0
    var gramsPerCupDenominator: Int = 1

    // MARK: Par level — a staple reaches the list by a RULE, not by a hand-flipped Bool
    var hasParLevel: Bool = false
    var parLevelNumerator: Int = 0
    var parLevelDenominator: Int = 1
    var parLevelUnitCode: String = ""
    var parLevelDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    var preferredDimensionRaw: String = MeasureDimension.mass.rawValue
    var notes: String = ""              // "the good anchovies, back of aisle 7"
    var createdAt: Date = .now

    /// The recipe this item is a batch OF — chimichurri, stock, pizza dough. A content id,
    /// not a relationship (§2.8), so a make-ahead batch can be stocked as a lot and drawn
    /// down like anything else. "" = not produced by a recipe.
    var producedByRecipeID: String = ""

    /// Macro lives on `StoreSection.foodItems`.
    var defaultSection: StoreSection? = nil
    /// Macro lives on `StorageLocation.foodItems`.
    var defaultLocation: StorageLocation? = nil

    @Relationship(deleteRule: .cascade, inverse: \FoodItemAlias.item)
    var aliases: [FoodItemAlias]? = []

    // MARK: The ledger edges are .nullify, and this is load-bearing
    //
    // A `.cascade` here means one `context.delete(foodItem)` from a stray SwiftUI
    // `.onDelete` destroys the entire append-only ledger the architecture is built around.
    // `.deny` is forbidden by CloudKit. Putting the guard only in a service is not a guard:
    // any other call site bypasses it, and the schema cannot enforce what the service
    // promises.
    //
    // So: `.nullify`, plus `foodItemNameSnapshot` on both children so an orphan is still
    // readable in the reconcile screen. `FoodItemResolver.canDelete` ALSO refuses an item
    // with history and offers "merge into…", but that is now a courtesy rather than the
    // only thing standing between him and a lost year.
    @Relationship(deleteRule: .nullify, inverse: \StockLot.item)
    var lots: [StockLot]? = []

    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.item)
    var transactions: [InventoryTransaction]? = []

    @Relationship(deleteRule: .nullify, inverse: \ShoppingListLine.foodItem)
    var shoppingLines: [ShoppingListLine]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        matchKey: String = "",
        catalogName: String = "",
        aliasBlob: String = "",
        trackingModeRaw: String = StockTrackingMode.tracked.rawValue,
        isRunningLow: Bool = false,
        hasDensity: Bool = false,
        gramsPerCupNumerator: Int = 0,
        gramsPerCupDenominator: Int = 1,
        hasParLevel: Bool = false,
        parLevelNumerator: Int = 0,
        parLevelDenominator: Int = 1,
        parLevelUnitCode: String = "",
        parLevelDimensionRaw: String = MeasureDimension.unmeasured.rawValue,
        preferredDimensionRaw: String = MeasureDimension.mass.rawValue,
        notes: String = "",
        createdAt: Date = .now,
        producedByRecipeID: String = "",
        defaultSection: StoreSection? = nil,
        defaultLocation: StorageLocation? = nil
    ) {
        self.id = id
        self.name = name
        self.matchKey = matchKey
        self.catalogName = catalogName
        self.aliasBlob = aliasBlob
        self.trackingModeRaw = trackingModeRaw
        self.isRunningLow = isRunningLow
        self.hasDensity = hasDensity
        self.gramsPerCupNumerator = gramsPerCupNumerator
        self.gramsPerCupDenominator = gramsPerCupDenominator
        self.hasParLevel = hasParLevel
        self.parLevelNumerator = parLevelNumerator
        self.parLevelDenominator = parLevelDenominator
        self.parLevelUnitCode = parLevelUnitCode
        self.parLevelDimensionRaw = parLevelDimensionRaw
        self.preferredDimensionRaw = preferredDimensionRaw
        self.notes = notes
        self.createdAt = createdAt
        self.producedByRecipeID = producedByRecipeID
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

    /// Grams per US cup, exact. nil means unknown, and unknown means the app REFUSES to
    /// convert rather than guessing: 1 cup = 240 g is right for water, off by 2× for flour
    /// and 1.4× for honey — and wrong SILENTLY, inside the number he is about to shop by.
    var gramsPerCup: Rational? {
        guard hasDensity else { return nil }
        return Rational(gramsPerCupNumerator, max(1, gramsPerCupDenominator))
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

    var hasLedgerHistory: Bool {
        !(lots ?? []).isEmpty || !(transactions ?? []).isEmpty
    }
}
```

### 2.13 `KitchenAid/Models/Catalog/FoodItemAlias.swift`

```swift
import Foundation
import SwiftData

/// One alias HE added. A ROW, never an element of a stored `[String]`.
///
/// This is bucketing correctness, not hygiene. Under CloudKit two devices each appending to
/// a stored array resolve last-writer-wins on the WHOLE array, so one alias is silently
/// lost — and a lost alias means two shopping lines for one purchase. Two rows both survive
/// the merge.
///
/// The SHIPPED synonyms ("scallion" / "green onion" / "spring onion") live in
/// `ingredients.json` and are consulted by `FoodItemResolver` after these. This table is
/// only for the one-tap "same as…" he uses on an unresolved line, so his vocabulary stays
/// his and a catalogue rebuild never overwrites it.
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

### 2.14 `Store.swift`, `StoreSection.swift`, `StorageLocation.swift`

```swift
// Store.swift
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

```swift
// StoreSection.swift
import Foundation
import SwiftData

/// One aisle, under a `Store`.
///
/// A MODEL and not an enum, for three reasons that each cost a shipped build otherwise: he
/// cannot add "Fish counter" without one; a second store cannot have its own geography; and
/// reordering an enum's cases is a migration while reordering `sortIndex` is a drag. Keeping
/// the walk order in `UserDefaults` is worse again — that suite is deliberately not synced,
/// so his iPad would shop a different aisle order than his phone.
///
/// The seeded `name`s are exactly the catalogue's 13 `aisle` values (§8), matched on
/// `matchKey`, so a `FoodItem` minted from a template lands in the right aisle with no
/// mapping table. **The walk order is READ from the JSON's `aisleOrder`** (§0.3), not kept
/// here: `ingredients.json`'s `items` array is sorted alphabetically by aisle, which is not
/// a walk order, so the file carries the order separately in `aisleOrder` and
/// `KitchenAidSeed` writes it into `sortIndex` once. From then on `sortIndex` is a row he
/// drags. This comment used to say the order lived here and the JSON could not carry one;
/// the second copy that invited had already drifted from the build script's (§8).
@Model
final class StoreSection {
    var id: UUID = UUID()
    var name: String = ""
    var matchKey: String = ""
    /// The order he physically walks the store. He will reorder these the first time he
    /// shops with the app.
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

```swift
// StorageLocation.swift
import Foundation
import SwiftData

/// Pantry, fridge, freezer, spice rack, bar, garage fridge. A model for the same reasons as
/// `StoreSection` — "Garage fridge" arrives without a build.
@Model
final class StorageLocation {
    var id: UUID = UUID()
    var name: String = ""
    var matchKey: String = ""
    /// `StorageKind`: a coarse classification for icons and default shelf lives; the NAME is
    /// what he reads.
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

### 2.15 `MergeRecord.swift` and `SeedRecord.swift`

```swift
// MergeRecord.swift
import Foundation
import SwiftData

/// An audit row per de-dup merge, so Settings can say "merged 3 duplicates" rather than
/// mutating his data mutely. A merge that happens silently is indistinguishable from data
/// loss.
@Model
final class MergeRecord {
    var id: UUID = UUID()
    var mergedAt: Date = .now
    var entityName: String = ""           // "FoodItem", "RecipeTweak"
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

```swift
// SeedRecord.swift
import Foundation
import SwiftData

/// Idempotent seeding without `.unique`: fetch by `seedKey` before applying. Covered by the
/// same reconcile pass as `FoodItem`, for the case where two devices seed in the same
/// minute.
@Model
final class SeedRecord {
    var id: UUID = UUID()
    var seedKey: String = ""      // "sections.v1", "locations.v1", "household.v1"
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

---

### 2.16 `KitchenAid/Models/Planning/Eater.swift`

```swift
import Foundation
import SwiftData

/// A household member.
///
/// `CLAUDE.md`: **named people with a full or half portion.** No allergy data, no dietary
/// data, no restrictions relationship — he was offered those and declined (§0.5). Rows are
/// addable and removable; two are seeded and **no count is hardcoded anywhere**. Anonymous
/// heads at a party are `PlannedMeal.guestCount`, counted and never named.
///
/// THERE IS NO `Household` MODEL. The household *is* the set of `Eater` rows. A singleton
/// created by a bootstrap-if-empty is a CloudKit liability: two devices both bootstrap, and
/// now there are two households with two rosters and attendance split across them.
/// Preferences that are genuinely per-device (unit system, default diner count, last plan
/// scope) live in `AppPreferences` and are deliberately not synced.
@Model
final class Eater {
    var id: UUID = UUID()
    var name: String = ""
    /// "Bk" — the calendar chip and the PDF legend.
    var shortName: String = ""
    var colorIndex: Int = 0
    var symbolName: String = "person.fill"

    /// Away at college: keep every history row, hide from pickers.
    var isActive: Bool = true

    /// Portion weight as EXACT INTEGERS, never a Double.
    ///
    /// `CLAUDE.md` says full or half, and `HouseholdView` offers exactly those two — but the
    /// STORAGE is a rational pair rather than a Bool, for one reason: a Bool cannot later
    /// become 3/2 for a teenager without a type-change migration stage, and a rational pair
    /// can. Three stored thirds as Doubles sum to 0.9999999 and are only recovered by a
    /// continued-fraction approximation that happens to snap; integers make the whole
    /// question disappear.
    ///
    /// This is what scales a recipe, not a head count: "4 eaters" meaning two adults and two
    /// half portions is 3 servings, and cooking 4 wastes food every time.
    var portionNumerator: Int = 1
    var portionDenominator: Int = 1

    var notes: String = ""
    var sortIndex: Int = 0
    var createdAt: Date = .now

    @Relationship(deleteRule: .cascade, inverse: \AttendanceDefault.eater)
    var attendanceDefaults: [AttendanceDefault]? = []

    /// `.nullify`, not `.cascade`: removing a person must not rewrite what the household
    /// ate. The attendance row survives carrying `eaterNameSnapshot`.
    @Relationship(deleteRule: .nullify, inverse: \MealAttendance.eater)
    var attendance: [MealAttendance]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        shortName: String = "",
        colorIndex: Int = 0,
        symbolName: String = "person.fill",
        isActive: Bool = true,
        portionNumerator: Int = 1,
        portionDenominator: Int = 1,
        notes: String = "",
        sortIndex: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.colorIndex = colorIndex
        self.symbolName = symbolName
        self.isActive = isActive
        self.portionNumerator = portionNumerator
        self.portionDenominator = portionDenominator
        self.notes = notes
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

extension Eater {
    var portion: Rational {
        let r = Rational(portionNumerator, max(1, portionDenominator))
        return r > .zero ? r : .one
    }

    /// What `HouseholdView` toggles. Anything else was set by a future build and is shown
    /// as-is rather than being rounded to one of two values.
    var isHalfPortion: Bool { portion == Rational(1, 2) }

    var initials: String {
        shortName.isEmpty ? String(name.prefix(2)) : shortName
    }
}
```

### 2.17 `KitchenAid/Models/Planning/AttendanceDefault.swift`

```swift
import Foundation
import SwiftData

/// "He is never home Thursdays." Applied when a `PlannedMeal` is created, so steady-state
/// attendance costs ZERO taps and "who is eating" only becomes work on an exceptional
/// night.
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

### 2.18 `KitchenAid/Models/Planning/PlannedMeal.swift`

```swift
import Foundation
import SwiftData

/// One calendar cell.
///
/// There is no `MealPlan` container entity. A plan object would mean ceremony before you can
/// plan Tuesday, and a week boundary is a view concern that would get baked into the data.
/// A date range is a query.
@Model
final class PlannedMeal {
    var id: UUID = UUID()

    var date: Date = Calendar.current.startOfDay(for: .now)
    /// yyyymmdd as an Int — the grouping, sorting and query key.
    ///
    /// A `#Predicate` on a `Date` range is correct until he plans a trip, crosses a timezone,
    /// or hits a DST boundary, and then "Tuesday's dinner" renders on Monday night — which he
    /// reads as "the app moved my dinner". An integer day is unambiguous, sorts, indexes, and
    /// costs four bytes. The real `Date` is kept for display and export. BOTH are written
    /// only by `setDate(_:)` so they cannot drift.
    var dayKey: Int = 0

    var slotRaw: String = MealSlot.dinner.rawValue
    /// Denormalized from the slot so a `SortDescriptor` can order breakfast before dinner
    /// without a computed property.
    var slotSortIndex: Int = MealSlot.dinner.sortIndex
    var orderInSlot: Int = 0

    /// `MealEntryKind`: recipe / leftovers / takeout / eatingOut / note.
    ///
    /// This is what lets a leftovers night contribute nothing to shopping WITHOUT being
    /// flagged skipped. With only `isSkipped`, "do not shop for this" and "we skipped it" are
    /// the same bit, so Tuesday's planned leftovers render on the calendar as a skipped meal
    /// and the two states are permanently indistinguishable.
    var kindRaw: String = MealEntryKind.recipe.rawValue

    var title: String = ""                 // used when kind != .recipe: "Thai takeout"
    var notes: String = ""
    var occasion: String = ""              // "Thanksgiving" — a label, not a container

    /// `PlanStatus`: planned / cooked / skipped / moved.
    ///
    /// `.cooked` is excluded from shopping collection as well as `.skipped`, because cooking
    /// already depleted inventory and collecting it again shops twice for a meal already
    /// made.
    var statusRaw: String = PlanStatus.planned.rawValue
    /// A per-meal override that is NOT about the kind. "We are eating out but I still want
    /// the dessert ingredients" is rare; this is for it.
    var excludeFromShopping: Bool = false

    // MARK: Guests — COUNTED, NEVER NAMED
    //
    // `CLAUDE.md`: named people with a portion are `Eater` rows. A party is a number. "Eight
    // for dinner Saturday" is one stepper, and nobody permanently joins the roster, which is
    // what the panel's `MealAttendance.guestName` would have done — a one-off guest row that
    // then shows up in every picker and every PDF legend forever.
    //
    // The portion is a single rational for the whole group, defaulting to a full portion. A
    // table of eight adults and a table of eight including four children differ by one
    // stepper, not by eight rows.
    var guestCount: Int = 0
    var guestPortionNumerator: Int = 1
    var guestPortionDenominator: Int = 1

    var costCents: Int? = nil              // takeout, optional
    var createdAt: Date = .now

    /// Tuesday is Sunday's ragù again.
    ///
    /// A leftovers meal contributes NOTHING to shopping and draws servings from its source.
    /// The source cooks extra via `MealRecipe.plannedLeftoverServings`.
    ///
    /// THE DOUBLE-COUNT RULE, decided: a separate leftovers meal draws down the source's
    /// `servingsCooked`. `.leftoversOnly` attendance AT THE SOURCE MEAL is the mutually
    /// exclusive alternative — for "he will take a plate to work", where there is no calendar
    /// entry to make. `PlannedMealEditorSheet` refuses both for the same person against the
    /// same source, because allowing both double-counts a portion and the calendar then
    /// cannot say "you are a portion short".
    ///
    /// Macro lives on `leftoverMeals` below. A self-relationship still needs the inverse
    /// named explicitly.
    var leftoversFrom: PlannedMeal? = nil

    @Relationship(deleteRule: .nullify, inverse: \PlannedMeal.leftoversFrom)
    var leftoverMeals: [PlannedMeal]? = []

    @Relationship(deleteRule: .cascade, inverse: \MealRecipe.meal)
    var mealRecipes: [MealRecipe]? = []

    @Relationship(deleteRule: .cascade, inverse: \MealAttendance.meal)
    var attendance: [MealAttendance]? = []

    /// The live edge that makes "drop Thursday's dinner from this list" and "jump to the meal
    /// that caused this line" into queries rather than a decode-every-blob scan. The
    /// snapshots on the source row preserve history; this edge preserves navigability. Both
    /// are needed.
    @Relationship(deleteRule: .nullify, inverse: \ShoppingListSource.plannedMeal)
    var shoppingSources: [ShoppingListSource]? = []

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
        guestCount: Int = 0,
        guestPortionNumerator: Int = 1,
        guestPortionDenominator: Int = 1,
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
        self.guestCount = guestCount
        self.guestPortionNumerator = guestPortionNumerator
        self.guestPortionDenominator = guestPortionDenominator
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

    var guestPortion: Rational {
        Rational(guestPortionNumerator, max(1, guestPortionDenominator))
    }

    /// The single predicate the shopping builder filters on.
    ///
    /// `.leftovers`, `.takeout`, `.eatingOut` and `.note` contribute nothing BY KIND, not by
    /// being marked skipped. `.cooked` is excluded because it already depleted.
    var contributesToShopping: Bool {
        kind == .recipe
            && !excludeFromShopping
            && status != .skipped
            && status != .cooked
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let names = orderedMealRecipes.map(\.displayTitle).filter { !$0.isEmpty }
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

### 2.19 `KitchenAid/Models/Planning/MealRecipe.swift`

```swift
import Foundation
import SwiftData

/// Join: one dish in a meal. A dinner is a main and two sides, and each dish scales and is
/// cooked separately. He chose several recipes per meal.
///
/// **`recipeID` is a content id, not a relationship.** SwiftData cannot hold a relationship
/// to a value type, and the panel's `recipe: Recipe?` edge cannot exist here. The id may
/// dangle; `recipeTitleSnapshot` is what keeps last March's plan readable, and
/// `MissingRecipesView` is where a dangling id is surfaced (§0.2).
@Model
final class MealRecipe {
    var id: UUID = UUID()
    var sortIndex: Int = 0

    /// `Recipe.id`. Resolve with `RecipeLoader.recipe(id:)`, never by fetching.
    var recipeID: String = ""
    /// Written when the dish is added. Survives the recipe file being removed, so a 2027
    /// plan does not go blank.
    var recipeTitleSnapshot: String = ""

    /// Beats the attendance calculation outright. nil = derive from attendance. Both nil or
    /// both set; the accessor guards it.
    var scaleOverrideNumerator: Int? = nil
    var scaleOverrideDenominator: Int? = nil

    /// Cooking extra on purpose, to feed a `.leftovers` meal later.
    var plannedLeftoverServings: Int? = nil
    /// What was actually made. The number a leftovers child draws down.
    var servingsCooked: Int? = nil

    /// Cook today, eat Thursday.
    var isPrepAhead: Bool = false
    var notes: String = ""

    /// Owner. Macro lives on `PlannedMeal.mealRecipes`.
    var meal: PlannedMeal? = nil

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        recipeID: String = "",
        recipeTitleSnapshot: String = "",
        scaleOverrideNumerator: Int? = nil,
        scaleOverrideDenominator: Int? = nil,
        plannedLeftoverServings: Int? = nil,
        servingsCooked: Int? = nil,
        isPrepAhead: Bool = false,
        notes: String = "",
        meal: PlannedMeal? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.recipeID = recipeID
        self.recipeTitleSnapshot = recipeTitleSnapshot
        self.scaleOverrideNumerator = scaleOverrideNumerator
        self.scaleOverrideDenominator = scaleOverrideDenominator
        self.plannedLeftoverServings = plannedLeftoverServings
        self.servingsCooked = servingsCooked
        self.isPrepAhead = isPrepAhead
        self.notes = notes
        self.meal = meal
    }
}

extension MealRecipe {
    var scaleOverride: Rational? {
        guard let n = scaleOverrideNumerator, let d = scaleOverrideDenominator, d != 0
        else { return nil }
        return Rational(n, d)
    }

    /// Resolution goes through the loader. The snapshot is the fallback, never the source.
    func recipe(_ loader: RecipeLoader) -> Recipe? { loader.recipe(id: recipeID) }

    var displayTitle: String { recipeTitleSnapshot }
}
```

### 2.20 `KitchenAid/Models/Planning/MealAttendance.swift`

```swift
import Foundation
import SwiftData

/// Join: WHO is eating, and how much.
///
/// An explicit join rather than a bare many-to-many because attendance CARRIES DATA: a
/// portion override and a status. Portions live on the EDGE, which is what makes "scale by
/// the number of eaters" correct for a table of two adults and a child, and makes fractional
/// servings fall out instead of being special-cased.
///
/// There is no `guestName` and no acknowledged-warning child. An unnamed head at a party is
/// `PlannedMeal.guestCount` (§2.18), and diet warnings were declined (§0.5). So every row
/// here is a household member, and `eater == nil` means only one thing: the person was
/// removed from the roster and `eaterNameSnapshot` is now the name.
@Model
final class MealAttendance {
    var id: UUID = UUID()

    /// `AttendanceStatus`: attending / away / maybe / leftoversOnly.
    var statusRaw: String = AttendanceStatus.attending.rawValue

    /// Exact integers. nil = use the snapshot. Both nil or both set.
    var portionOverrideNumerator: Int? = nil
    var portionOverrideDenominator: Int? = nil

    /// Denormalized on purpose: `Eater` deletion is `.nullify`, and a 2027 meal that says
    /// "3 eaters" must not become "0 eaters" because someone moved out. Integers, not a
    /// Double — this is an input to `scale`, and the one place a scale is derived must not
    /// launder its operands through floating point.
    var portionSnapshotNumerator: Int = 1
    var portionSnapshotDenominator: Int = 1
    var eaterNameSnapshot: String = ""

    var plateNote: String = ""             // "no horseradish", "sauce on the side"

    /// Macro lives on `Eater.attendance` (`.nullify`).
    var eater: Eater? = nil
    /// Owner. Macro lives on `PlannedMeal.attendance`.
    var meal: PlannedMeal? = nil

    init(
        id: UUID = UUID(),
        statusRaw: String = AttendanceStatus.attending.rawValue,
        portionOverrideNumerator: Int? = nil,
        portionOverrideDenominator: Int? = nil,
        portionSnapshotNumerator: Int = 1,
        portionSnapshotDenominator: Int = 1,
        eaterNameSnapshot: String = "",
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

    var displayName: String { eater?.name ?? eaterNameSnapshot }

    var initials: String { eater?.initials ?? String(displayName.prefix(2)) }

    /// `.attending` and `.leftoversOnly` both consume a portion of what is cooked; `.away`
    /// and `.maybe` do not. A `.maybe` is surfaced as a badge on the meal so he can decide,
    /// and is deliberately NOT counted — buying for a maybe every week is how a plan drifts
    /// into over-buying.
    var consumesPortion: Bool {
        status == .attending || status == .leftoversOnly
    }
}
```

### 2.21 `KitchenAid/Models/Inventory/StockLot.swift`

```swift
import Foundation
import SwiftData

/// One physical lot: this bag of flour, in this location, with this best-by.
///
/// Lots rather than one level per item because butter is simultaneously in the fridge and
/// the freezer with different expiries, because FIFO depletion needs per-lot dates, and
/// because "what is about to go bad" is the single most useful inventory screen. The cost is
/// more rows and more arithmetic. Accepted.
@Model
final class StockLot {
    var id: UUID = UUID()

    // MARK: `remaining` is a CACHE, not truth
    //
    // The truth is the signed sum of this item's `InventoryTransaction` rows. This cache
    // exists because "do I have enough butter" runs on every shopping-list build and every
    // recipe detail render, and summing a multi-year transaction log per item per render is
    // not viable.
    //
    // Every mutation goes through `InventoryLedger`, which writes both.
    // `InventoryLedger.recompute(lot:)` rebuilds it, and `reconcileReport` SURFACES
    // divergence in Settings rather than hiding it. A cache that silently drifts is worse
    // than no cache; a cache that reports its own drift is fine.
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

    /// Kept so a lot orphaned by a stray item delete is still readable in the reconcile
    /// screen. Same snapshot discipline as `MealAttendance.eaterNameSnapshot`.
    var foodItemNameSnapshot: String = ""

    /// Macro lives on `FoodItem.lots` (and is `.nullify`, see there).
    var item: FoodItem? = nil
    /// Macro lives on `StorageLocation.lots`.
    var location: StorageLocation? = nil

    /// `.nullify`, and `level(of:)` sums the ITEM's transactions rather than its lots.
    ///
    /// If this cascaded, deleting a lot would delete ledger rows. If it nullified while
    /// `level` summed lots, an orphaned transaction would remain in the ledger but silently
    /// stop contributing, producing a divergence `reconcileReport` could never attribute or
    /// clear. Summing at the item level means an orphan still counts — into an explicit
    /// "unassigned lot" bucket the reconcile screen names (`LedgerDivergence.Scope`, §3.11).
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
    /// Two quantities on one row, so this type cannot conform to `QuantityCarrying` — a type
    /// may conform once. It uses the same five-primitive SHAPE twice with distinct prefixes,
    /// which is the whole reason the protocol is a convenience rather than the contract.
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

### 2.22 `KitchenAid/Models/Inventory/InventoryTransaction.swift`

```swift
import Foundation
import SwiftData

/// Append-only. This is the TRUTH of what is in the kitchen.
///
/// Two reasons a scalar `onHand` was rejected, and the second is decisive:
///
/// 1. Answerability. He will open the app and ask "why does it think I have 3 lb of butter?"
///    A scalar has no answer. A ledger shows: bought 2 lb Oct 4, bought 2 lb Oct 19, cooked
///    -1 lb Oct 22.
/// 2. CloudKit merge semantics. With a scalar, his phone decrements butter by 1/2 cup and his
///    iPad by 2 tbsp while both are offline; CloudKit resolves field-level last-writer-wins
///    and ONE DECREMENT VANISHES, with no conflict handler possible. With append-only rows,
///    both are distinct records, both sync, and the derived level is correct with no conflict
///    handling at all.
///
/// This is also the one part of the architecture that is genuinely not additive later: adding
/// a ledger in year two cannot backfill history that was never recorded. Which is why it is
/// built on day one.
@Model
final class InventoryTransaction {
    var id: UUID = UUID()

    /// Signed. Negative depletes.
    ///
    /// `hasDelta == false` means the delta is UNKNOWN, not zero. That is the `.pendingBridge`
    /// case: a cook depletion that needs a density the `FoodItem` does not carry is WRITTEN,
    /// with no number, and lands in the "Unresolved depletions" inbox. A skipped depletion is
    /// an invisible overstatement of stock; a guessed one is a silent lie. Neither is
    /// acceptable, so the app records the question.
    var hasDelta: Bool = false
    var deltaNumerator: Int = 0
    var deltaDenominator: Int = 1
    var deltaUnitCode: String = ""
    var deltaDimensionRaw: String = MeasureDimension.unmeasured.rawValue

    /// `TransactionKind`: purchase / cookDepletion / waste / manualAdjustment / correction /
    /// inventoryCount / giftOut.
    var kindRaw: String = TransactionKind.manualAdjustment.rawValue
    /// `ResolutionState`: applied / pendingBridge / voided.
    var resolutionStateRaw: String = ResolutionState.applied.rawValue
    var occurredAt: Date = .now
    var note: String = ""
    var priceCents: Int? = nil

    /// So an orphan — from a stray item delete — is still readable and attributable in the
    /// reconcile screen.
    var foodItemNameSnapshot: String = ""

    /// Cook provenance WITHOUT a cook log. "Where did the cream go" stays answerable, which
    /// was the only thing `CookLogEntry.depletions` was load-bearing for; the rest of that
    /// model was the journal he declined (§0.5). "" when the depletion came from somewhere
    /// else.
    var recipeIDSnapshot: String = ""
    var recipeTitleSnapshot: String = ""

    /// Macro lives on `FoodItem.transactions` (`.nullify`).
    var item: FoodItem? = nil
    /// Macro lives on `StockLot.transactions` (`.nullify`). nil is legal and means
    /// "unassigned lot"; it still contributes to `level(of:)`.
    var lot: StockLot? = nil
    /// Macro lives on `ShoppingList.receivedTransactions`.
    var shoppingList: ShoppingList? = nil
    /// Macro lives on `PlannedMeal.inventoryTransactions`.
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
        recipeIDSnapshot: String = "",
        recipeTitleSnapshot: String = "",
        item: FoodItem? = nil,
        lot: StockLot? = nil,
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
        self.recipeIDSnapshot = recipeIDSnapshot
        self.recipeTitleSnapshot = recipeTitleSnapshot
        self.item = item
        self.lot = lot
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

---

### 2.23 `KitchenAid/Models/Shopping/ShoppingList.swift`

```swift
import Foundation
import SwiftData

/// A persisted, frozen trip. Not recomputed on view.
///
/// He checks things off while standing in the produce aisle, and he adds paper towels, which
/// came from no recipe. A list is also a historical document: if a recipe is revised in
/// March, the November list must still say what it said in November — which, with recipes
/// bundled and immutable, now also means "the list survives a `git revert` of a recipe file".
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
    // "Which options produced this list" is a question the regenerate path and the diff sheet
    // both ask, and an `optionsJSON: String` makes it a decode rather than a read. Real
    // fields are also what let a future option be added without touching stored rows.
    //
    // This is the WHOLE of `ShoppingListBuilder.Options` minus `range`/`slots`/
    // `expandedLineIDs` (which are the four range fields and the two blobs below) and minus
    // `now`. `now` is deliberately NOT frozen: `generatedAt` already records it, and a
    // second copy of the same instant is a second thing that can disagree.
    //
    // `unitSystemRaw` and `defaultDinerCount` are here because a regenerate without them is
    // not reproducible: the unit system changes every `preferredUnitCode` frozen onto the
    // subtotal rows, and the diner count changes the `.noAttendance` fallback scale, so a
    // list regenerated under a different preference silently differs from the one he
    // shopped.
    var subtractInventory: Bool = true
    var countExpiredAsAvailable: Bool = false
    var expiringGraceDays: Int = 0
    var includeStaples: Bool = false
    var includeOptionalLines: Bool = false
    var maxExpansionDepth: Int = 4
    /// `UnitSystem` raw value. Stored, never an enum (§0.4).
    var unitSystemRaw: String = UnitSystem.us.rawValue
    var defaultDinerCount: Int = 2
    /// `|`-delimited `MealSlot` raw values. Frozen at generation; single writer.
    var slotsBlob: String = ""
    /// `|`-delimited `IngredientLine.lineID` values: the buy-or-make decisions he made for
    /// THIS run, so a regenerate is reproducible. **Strings, not UUIDs**, because the lines
    /// are content now.
    ///
    /// A delimited blob under the §2.8 exception: written once at generation by one writer,
    /// never appended to afterwards. There is deliberately NO `includedMealIDs` blob — the
    /// live `ShoppingListSource.plannedMeal` edges ARE the included set, and they are
    /// queryable.
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
        maxExpansionDepth: Int = 4,
        unitSystemRaw: String = UnitSystem.us.rawValue,
        defaultDinerCount: Int = 2,
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
        self.maxExpansionDepth = maxExpansionDepth
        self.unitSystemRaw = unitSystemRaw
        self.defaultDinerCount = defaultDinerCount
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

    var expandedLineIDs: Set<String> {
        Set(expandedLineIDBlob.split(separator: "|").map(String.init).filter { !$0.isEmpty })
    }

    var slots: Set<MealSlot> {
        Set(slotsBlob.split(separator: "|").compactMap { MealSlot(rawValue: String($0)) })
    }

    var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .us }

    /// The meals this list covers, from the live edges. This is what "drop Thursday's dinner"
    /// iterates.
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

### 2.24 `KitchenAid/Models/Shopping/ShoppingListLine.swift`

```swift
import Foundation
import SwiftData

/// One line per `FoodItem` per list.
///
/// All of requested / have / toBuy / purchase are kept. A fully-covered line is marked
/// `isCovered` and rendered collapsed under "Already have (6)" — never removed. A silently
/// absent line is indistinguishable from a bug, and he needs to see the app's belief about
/// his fridge before he will trust it.
@Model
final class ShoppingListLine {
    var id: UUID = UUID()
    var sortIndex: Int = 0

    /// Snapshots: a line must stay readable across a catalogue merge or an item delete, and a
    /// printed list must not re-sort when he reorders his aisles in March.
    var displayName: String = ""
    var sectionNameSnapshot: String = ""
    var sectionSortIndex: Int = 0

    /// `LineStatus`: needed / haveEnough / partiallyHave / needsBridge / unresolvedItem /
    /// manual / staple.
    var statusRaw: String = LineStatus.needed.rawValue
    /// `|`-delimited `LineFlag` raw values.
    ///
    /// A delimited blob under the §2.8 exception: a generated line is frozen and nothing
    /// appends to it, and `flagsBlob.contains("|needsBridge|")` is predicate-queryable, which
    /// a stored `[String]` is not.
    var flagsBlob: String = ""

    var isChecked: Bool = false
    var checkedAt: Date? = nil
    /// Paper towels. Always survives a regenerate.
    var isManual: Bool = false
    /// Fully covered by inventory. Shown collapsed, never hidden.
    var isCovered: Bool = false
    /// Collected unmeasured notes: "to taste", "Pinch". Rendered instead of a number, never
    /// as 0 and never aggregated into "2 pinches".
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
    /// Flour legitimately requested by the cup, by the gram AND as "1 package" in the same
    /// week is THREE dimensions. A single `secondaryText` slot drops the third, and a line
    /// that is volume + mass + count has nowhere to put it. Rows also let the
    /// `conversionNote` ride with the SPECIFIC number that was converted, which a line-level
    /// string cannot.
    @Relationship(deleteRule: .cascade, inverse: \ShoppingListLineSubtotal.line)
    var subtotalRows: [ShoppingListLineSubtotal]? = []

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

    /// The relationship is named `subtotalRows` and this is `rows(for:)`, so there is no
    /// `subtotals` property shadowing a `subtotals(_:)` method — the panel had both, which
    /// reads ambiguously at every call site even where it compiles.
    func rows(for role: SubtotalRole) -> [ShoppingListLineSubtotal] {
        (subtotalRows ?? [])
            .filter { $0.role == role }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    var requested: [ShoppingListLineSubtotal] { rows(for: .requested) }
    var have: [ShoppingListLineSubtotal] { rows(for: .have) }
    var toBuy: [ShoppingListLineSubtotal] { rows(for: .toBuy) }
    /// What actually enters the ledger on the trip home. In v1 it is a copy of `toBuy`;
    /// it is its own stored row so purchase-unit rounding can be added later without a
    /// migration (deferred — see `CLAUDE.md`).
    var purchase: [ShoppingListLineSubtotal] { rows(for: .purchase) }

    var orderedSources: [ShoppingListSource] {
        (sources ?? []).sorted { ($0.mealDayKey, $0.sortIndex) < ($1.mealDayKey, $1.sortIndex) }
    }
}
```

### 2.25 `KitchenAid/Models/Shopping/ShoppingListLineSubtotal.swift`

```swift
import Foundation
import SwiftData

/// One (role, dimension) subtotal on one line. **The persisted mirror of `QuantitySubtotal`**
/// (§3.5) — same fields, same meaning, one in the store and one in flight.
///
/// `dimensionKey` is "volume" | "mass" | "count:clove" | "count:head". Partitioning count by
/// its NOUN is what stops "2 cloves garlic + 1 clove + 1 head" summing to "4 cloves" and
/// understating garlic by about 50 g — and it is why the merge key and the output type agree,
/// so the display can actually show what the aggregation correctly separated.
@Model
final class ShoppingListLineSubtotal {
    var id: UUID = UUID()
    /// `SubtotalRole`: requested / have / toBuy / purchase.
    var roleRaw: String = SubtotalRole.requested.rawValue
    var dimensionKey: String = ""
    /// The EXACT value in the dimension's base unit (tsp / g / count-of-noun), stored as
    /// integers so it survives any future change to the display ladder.
    var baseNumerator: Int = 0
    var baseDenominator: Int = 1
    /// The unit this should be rendered in, chosen at generation by `QuantityMath.displayUnit`.
    /// Frozen, so a printed list reads the same in March.
    var preferredUnitCode: String = ""
    /// Rides with the SPECIFIC number that was converted: "200 g counted as 1 2/3 cups at
    /// 120 g per cup".
    var conversionNote: String = ""
    /// Set when the stored exact value does not render to a denominator <= 8 and the display
    /// is an approximation prefixed "≈".
    var isApproximateDisplay: Bool = false
    var sortIndex: Int = 0
    /// Owner. Macro lives on `ShoppingListLine.subtotalRows`.
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
        guard let unit = UnitCatalog.unit(code: preferredUnitCode, fallbackDimension: nil),
              unit.baseFactor != .zero
        else { return nil }
        return Quantity(amount: base / unit.baseFactor, unit: unit)
    }

    var displayString: String {
        guard let q = quantity else { return base.mixedDescription }
        let text = q.displayString()
        return isApproximateDisplay ? "\u{2248} \(text)" : text
    }

    /// Round-trips to the in-flight type, so the builder and the store share one shape.
    var asSubtotal: QuantitySubtotal? {
        guard let unit = UnitCatalog.unit(code: preferredUnitCode, fallbackDimension: nil)
        else { return nil }
        return QuantitySubtotal(
            dimensionKey: dimensionKey,
            base: base,
            preferredUnit: unit,
            conversionNote: conversionNote,
            isApproximateDisplay: isApproximateDisplay
        )
    }
}
```

### 2.26 `KitchenAid/Models/Shopping/ShoppingListSource.swift`

```swift
import Foundation
import SwiftData

/// "Recipe asked for X" — the traceability he will want the moment a number looks wrong, and
/// the rows "drop Thursday's dinner from this list" iterates.
///
/// It carries BOTH denormalized snapshot strings AND a live `.nullify` edge to the meal. The
/// snapshots preserve history across a recipe revision — a list printed in November must
/// still read correctly in March — and the live edge is what makes "which lines did Thursday
/// cause" and "jump to the meal that caused this line" into queries instead of a
/// decode-every-blob scan. An opaque `sourcesJSON` string gives up the second, and a bare
/// relationship gives up the first.
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
    /// "Creamed horseradish spinach". For a nested sub-recipe this is the full path joined
    /// with " > ", so the provenance reads the way the dish is built.
    var componentPath: String = ""
    /// "3 tbsp prepared horseradish, drained" — exactly what the recipe said.
    var originalText: String = ""
    /// "4 1/2 tbsp (×1.5)" — what it became.
    var scaledText: String = ""
    /// "×1.5 — 6 eaters, recipe serves 4". On EVERY source row, so the arithmetic is never a
    /// mystery.
    var scaleDescription: String = ""

    // MARK: This source's own contribution, in base units
    var hasContribution: Bool = false
    var contributionDimensionKey: String = ""
    var contributionBaseNumerator: Int = 0
    var contributionBaseDenominator: Int = 1

    /// For "jump to the recipe". A **content id string** now, not a UUID. Allowed to dangle;
    /// `recipeTitle` carries the text (§0.2).
    var recipeID: String = ""
    /// The content line this came from, for the buy-or-make replay on a regenerate.
    var lineID: String = ""

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
        recipeID: String = "",
        lineID: String = "",
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
        self.lineID = lineID
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

### 2.27 `KitchenAid/App/AppTab.swift`

```swift
import Foundation

/// FIVE tabs, written out, because the panel named a count and never named the cases
/// (§0.9.4).
///
/// **Today is first and is the default**, because `CLAUDE.md` says the app opens on Today:
/// what is planned for today with a Cook button, falling back to recent recipes when the plan
/// is empty. Not the library, not the week. The library is the asset that compounds over ten
/// years, but it is not what he opens the app holding a knife to find.
///
/// Cook is a `fullScreenCover` and Settings is a sheet — CFAL3's "a sitting is a cover" rule.
/// Neither is a tab, and nothing in this document says six.
enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case today
    case recipes
    case plan
    case shop
    case pantry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .recipes: return "Recipes"
        case .plan: return "Plan"
        case .shop: return "Shop"
        case .pantry: return "Pantry"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "sun.horizon"
        case .recipes: return "book.closed"
        case .plan: return "calendar"
        case .shop: return "cart"
        case .pantry: return "shippingbox"
        }
    }

    /// What `KitchenAidUITests` addresses. A raw-value-derived identifier so a renamed title
    /// never breaks a test.
    var identifier: String { "tab.\(rawValue)" }
}
```

### 2.28 `KitchenAid/Models/Schema/KitchenAidSchema.swift`

```swift
import Foundation
import SwiftData

/// Versioned from v1, BEFORE there is any data to migrate.
///
/// Adding a `VersionedSchema` later means the existing store carries no recorded version
/// identity, so the first real migration has nothing to migrate FROM — which is exactly the
/// situation the in-memory fallback in `KitchenAidApp.init` exists to survive. Twenty lines,
/// written before the first build, and the highest-leverage twenty in the app.
enum KitchenAidSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    /// ONE array, shared by the container and the tests. A model added to one list and not
    /// the other is a runtime "entity not found", not a compile error.
    ///
    /// **21 entries. There is no `Recipe` here** — recipes are bundled content and have no
    /// row (§0.2).
    static var models: [any PersistentModel.Type] = [
        // Overlay — the SwiftData side of bundled content
        RecipeTweak.self, IngredientOverride.self, StepOverride.self,
        // Catalog
        FoodItem.self, FoodItemAlias.self,
        Store.self, StoreSection.self, StorageLocation.self,
        MergeRecord.self, SeedRecord.self,
        // Planning
        Eater.self, AttendanceDefault.self,
        PlannedMeal.self, MealRecipe.self, MealAttendance.self,
        // Inventory
        StockLot.self, InventoryTransaction.self,
        // Shopping
        ShoppingList.self, ShoppingListLine.self,
        ShoppingListLineSubtotal.self, ShoppingListSource.self
    ]
}

enum KitchenAidMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [KitchenAidSchemaV1.self]
    static var stages: [MigrationStage] = []
}
```

### 2.29 `KitchenAid/Models/Transfer/` — drag payloads

```swift
// KitchenAidUTType.swift
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist under UTExportedTypeDeclarations with the same identifier, or
    /// the `Transferable` conformance silently fails to register.
    static let kitchenAidRecipe = UTType(exportedAs: "com.brandonkeeny.KitchenAid.recipe")
    static let kitchenAidPlannedMeal = UTType(exportedAs: "com.brandonkeeny.KitchenAid.plannedmeal")
}
```

```swift
// RecipeTransfer.swift
import Foundation
import CoreTransferable

/// Carries only a content id and a title.
///
/// NEVER put a `@Model` in a drag payload: a `@Model` class is neither reliably `Codable` nor
/// `Sendable`, and the failure is a runtime crash during a drag rather than a compile error.
/// `Recipe` itself is now a `Codable` value type and would technically fit, but the payload
/// stays an id: dropping a 40 KB recipe into another app's pasteboard is not what a drop
/// between two calendar cells means.
///
/// The `ProxyRepresentation` means a drop into Notes yields readable text instead of nothing.
struct RecipeTransfer: Codable, Transferable, Sendable, Hashable {
    let recipeID: String
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kitchenAidRecipe)
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
        CodableRepresentation(contentType: .kitchenAidPlannedMeal)
        ProxyRepresentation(exporting: \.title)
    }
}
```

---

## 3. Supporting value types

**Also copied verbatim.** None of these touch SwiftData or SwiftUI, so they are
unit-testable with no `ModelContainer` — the shape of CFAL3's `ReviewScheduler`.

### 3.1 `KitchenAid/Models/Support/Rational.swift`

```swift
import Foundation

/// Exact fractions. NEVER `Double`.
///
/// Recipes are written in fractions. `1/3 cup × 3` must be exactly `1 cup`, not `0.9999999`,
/// and a shopping list that reads "0.33333333 cups flour" is a bug rather than precision.
/// `Decimal` does not help — thirds are not representable in base 10 either.
///
/// Every operator is overflow-checked. Addition is the operation the aggregation performs
/// most, and the gcd-first form below is mandatory: cross-multiplying naively
/// (n1*d2 + n2*d1 over d1*d2) reaches ~1e19 within a handful of lines once scales like 7/8
/// and 3/7 enter, and traps on Int64 — a crash while generating a shopping list in a grocery
/// store.
struct Rational: Hashable, Sendable, Comparable, CustomStringConvertible {
    let numerator: Int
    /// Invariant: always > 0, always reduced against the numerator.
    let denominator: Int

    /// TOTAL on `Int.min`, and that is not belt-and-braces.
    ///
    /// The earlier version asserted in a comment that `Int.min` "cannot arise from any
    /// input path" and then called `abs(n)`, which traps on exactly that value. Both halves
    /// of the claim were false. `(-2^62) * 2 == Int.min` and
    /// `multipliedReportingOverflow` returns `(Int.min, false)` — no overflow reported — so
    /// the overflow-checked operators below can hand `Int.min` straight in. And
    /// `Rational`'s hand-written `Codable` (bottom of this file) takes a numerator from a
    /// HAND-AUTHORED recipe file, which can contain `-9223372036854775808` as easily as any
    /// other integer. `if d < 0 { n = -n; d = -d }` traps the same way when `d == Int.min`.
    ///
    /// A crash here defeats the entire point of the overflow-fallback design below, whose
    /// own comment is "the alternative is a trap at the shelf", and of the `Codable`
    /// promise that "a typo in a committed recipe file must degrade, not crash". So the
    /// value is REJECTED rather than negated: `Int.min` as either term yields zero, which
    /// is wrong by an amount no recipe can express and is visible, instead of killing the
    /// app in a kitchen.
    init(_ n: Int, _ d: Int = 1) {
        precondition(d != 0, "Rational denominator must not be zero")
        guard n != .min, d != .min else {
            self.numerator = 0
            self.denominator = 1
            return
        }
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
    // Call these directly anywhere the caller wants to know. The operators below never trap;
    // they degrade to an approximation and say so.

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
        // `Int.min` counts as an overflow even though no operation reported one: it is the
        // one value `init(_:_:)` cannot normalize, so handing it on would silently produce
        // a zero instead of reporting that the exact answer was lost.
        if o1 || o2 || o3 || o4 || num == .min || den == .min { return (.zero, true) }
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
        // See `addingReportingOverflow`: `Int.min` is reported as overflow. `(-2^62) * 2`
        // is the concrete case — it returns `(Int.min, false)`.
        if o1 || o2 || num == .min || den == .min { return (.zero, true) }
        return (Rational(num, den), false)
    }

    // MARK: Operators
    //
    // With the culinary conversion table (§3.3) every factor's denominator is at most 20, so
    // the overflow branches below are effectively unreachable. They exist because
    // "effectively unreachable" is not "unreachable", and because the alternative is a trap
    // at the shelf.

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
    /// +1 lb of mass and -2 tbsp of volume must not produce a NEGATIVE have-subtotal, because
    /// `requested - (-2 tbsp)` silently INFLATES the purchase. Flooring only `toBuy` guards
    /// the wrong side.
    var clampedAtZero: Rational { isNegative ? .zero : self }

    // MARK: Approximation and rounding

    /// Continued fractions. Used only at the boundary — parsing "1.25", and the overflow
    /// fallbacks above. NOTHING in the scaling path goes through here.
    ///
    /// Every convergent is computed with the reporting operators and the loop BREAKS on
    /// overflow. The earlier version tested only `k2 > maxDenominator`, after computing
    /// `h2` — but `h2 ≈ value × k2`, so with `abs(value)` allowed up to 1e15 and `k2` free
    /// to reach `maxDenominator` before the test fires, `a * h1 + h0` reaches ~1e19 and
    /// traps. That matters more here than anywhere else in this file: this initializer sits
    /// on the path `+` and `*` take **to avoid** trapping, so a trap here crashes exactly
    /// where the recovery was supposed to save us.
    init(approximating value: Double, maxDenominator: Int = 64) {
        guard value.isFinite, abs(value) < 1e15 else { self.init(0); return }
        let negative = value < 0
        var x = abs(value)
        var (h0, h1) = (0, 1)
        var (k0, k1) = (1, 0)
        for _ in 0..<32 {
            guard x < 9.0e18 else { break }
            let a = Int(x.rounded(.down))
            let (ah, ahOverflow) = a.multipliedReportingOverflow(by: h1)
            let (h2, h2Overflow) = ahOverflow ? (0, true) : ah.addingReportingOverflow(h0)
            let (ak, akOverflow) = a.multipliedReportingOverflow(by: k1)
            let (k2, k2Overflow) = akOverflow ? (0, true) : ak.addingReportingOverflow(k0)
            if ahOverflow || h2Overflow || akOverflow || k2Overflow { break }
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

    /// Smallest integer >= self. Swift's integer division truncates toward zero, so the
    /// negative branch is already a ceiling.
    var ceilingInt: Int {
        numerator >= 0
            ? (numerator + denominator - 1) / denominator
            : numerator / denominator
    }

    /// Snapped UP to a multiple of `step`. Batch granularity: you cannot bake 1.4 loaves, so
    /// a half-batch recipe at 1.4 becomes 1 1/2.
    func ceiling(toMultipleOf step: Rational) -> Rational {
        guard step > .zero else { return self }
        return step * Rational((self / step).ceilingInt)
    }

    /// DISPLAY ONLY. A `Double` is acceptable here and nowhere else, because the result is
    /// never stored and never compared — `ShoppingListLineSubtotal` keeps the exact base
    /// value and renders this.
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

    /// "1½" where a glyph exists, otherwise `mixedDescription`.
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

// MARK: - Codable, written by hand and not synthesized
//
// This matters now that quantities arrive from HAND-AUTHORED JSON (§0.2). The synthesized
// `init(from:)` for a struct with `let` properties assigns them directly, bypassing
// `init(_:_:)` — so a file containing `{"numerator": 1, "denominator": 0}` would decode to an
// unnormalized, un-reduced, zero-denominatored value that later traps inside `/` or
// `mixedDescription`, in the kitchen, at the stove. A typo in a committed recipe file must
// degrade, not crash.
//
// It also accepts a bare integer and a bare string, because `"amount": 2` and
// `"amount": "1 1/2"` are both things a human writes in a recipe file, and refusing them
// would push the whole burden onto the importer forever.
extension Rational: Codable {
    enum CodingKeys: String, CodingKey { case numerator, denominator }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if let i = try? single.decode(Int.self) { self.init(i); return }
            if let s = try? single.decode(String.self), let parsed = Rational(string: s) {
                self = parsed
                return
            }
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try c.decode(Int.self, forKey: .numerator)
        let d = try c.decodeIfPresent(Int.self, forKey: .denominator) ?? 1
        // A zero denominator is a malformed file, not a runtime condition. Treat it as a
        // whole number so the recipe still opens; `RecipeLoaderTests` asserts this.
        self.init(n, d == 0 ? 1 : d)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(numerator, forKey: .numerator)
        try c.encode(denominator, forKey: .denominator)
    }

    /// "1 1/2", "3/4", "2". The same forms `scripts/import_recipe.py` emits in its `display`
    /// field, so a round-trip through either is lossless.
    init?(string: String) {
        let t = string.trimmingCharacters(in: .whitespaces)
        if let i = Int(t) { self.init(i); return }
        let parts = t.split(separator: " ")
        if parts.count == 2, let whole = Int(parts[0]) {
            let frac = parts[1].split(separator: "/")
            guard frac.count == 2, let n = Int(frac[0]), let d = Int(frac[1]), d != 0 else { return nil }
            self.init(whole * d + (whole < 0 ? -n : n), d)
            return
        }
        let frac = t.split(separator: "/")
        guard frac.count == 2, let n = Int(frac[0]), let d = Int(frac[1]), d != 0 else { return nil }
        self.init(n, d)
    }
}
```

### 3.2 `KitchenAid/Models/Support/MeasureDimension.swift`

```swift
import Foundation

/// Volume, mass and count are different physical dimensions and are NOT convertible without
/// per-item data. The app never guesses a density.
///
/// Requirement 6 from the fixture: units carry an explicit dimension, because bare "oz" means
/// weight ounces three times in that document and fluid ounces elsewhere. There is
/// deliberately NO `length` dimension: "1/2 inch thick" is descriptive and not purchasable,
/// so it lives in `IngredientLine.preparation`.
///
/// The raw values are `"volume"`, `"mass"`, `"count"` — which is exactly what
/// `scripts/build_catalogue.py` writes into `ingredients.json`, so `CatalogEntry.dimension`
/// decodes straight into this with no mapping table.
enum MeasureDimension: String, Codable, CaseIterable, Sendable {
    case volume      // base unit: teaspoon
    case mass        // base unit: gram
    case count       // base unit: the noun itself ("clove", "slice", "each")
    /// Reached by the parser, never persisted on a line with an amount. A pinch is a nil
    /// quantity plus an `unmeasuredNote`, not a unit.
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

### 3.3 `KitchenUnit.swift` and `UnitCatalog.swift`

```swift
// KitchenUnit.swift
import Foundation

/// A STRUCT, not an enum.
///
/// Count nouns are an open set that recipes extend — clove, head, slice, loaf, bunch, sprig,
/// stick, can, ear, fillet, rib, stalk, leaf. More importantly, each count noun must be its
/// own aggregation bucket: with a single `.count` dimension sharing a factor into "each",
/// "2 cloves garlic" + "1 clove" + "1 head garlic" sums to 4 and renders "4 cloves",
/// understating garlic by about 50 g. `dimensionKey` below is what prevents that, and it
/// costs nothing.
struct KitchenUnit: Hashable, Sendable, Identifiable {
    let code: String                 // PERSISTED. "tbsp", "g", "clove"
    let dimension: MeasureDimension
    /// Factor into the dimension's base unit, as an exact `Rational`.
    let baseFactor: Rational
    let singular: String
    let plural: String
    /// Excluded from DISPLAY selection when false. Without this, 18 tsp of butter legally
    /// renders as "3 fl oz", which is not a thing a cook says.
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
/// CULINARY factors, not SI-exact ones, and that is a decision rather than an approximation.
/// Three things follow from it:
///
/// 1. Volume base = teaspoon makes every US unit an exact INTEGER: tsp 1, tbsp 3, fl oz 6,
///    cup 48, pint 96, quart 192, gallon 768. So `2 tbsp + 1/4 cup` is `6 + 12 = 18 tsp`
///    exactly, and converts back to exactly 6 tbsp.
/// 2. Metric joins on the identity every recipe on earth already assumes: 1 tsp = 5 mL, so
///    1 tbsp = 15 mL and 1 cup = 240 mL EXACTLY. A 240 mL carton of cream therefore CANCELS
///    a 1-cup requirement exactly. With SI-exact factors (1 cup = 236.588 mL) the 3.4 mL
///    residue survives `max(0, required - onHand)` and surfaces on the shopping list as a
///    spurious "1 tsp heavy cream" line.
/// 3. Every denominator here is at most 20, so Int overflow stops being a design problem —
///    and the 32-million-denominator factors SI-exactness requires, along with the whole
///    overflow-fallback code path they need, simply do not exist.
///
/// SI-exactness buys nothing a cook can perceive and costs both of the above.
enum UnitCatalog {

    // MARK: Volume — base teaspoon
    static let teaspoon    = KitchenUnit(code: "tsp",  dimension: .volume, baseFactor: Rational(1),    singular: "tsp",    plural: "tsp",     isHouseholdCommon: true,  system: .us)
    static let tablespoon  = KitchenUnit(code: "tbsp", dimension: .volume, baseFactor: Rational(3),    singular: "tbsp",   plural: "tbsp",    isHouseholdCommon: true,  system: .us)
    /// NOT household-common. 18 tsp is exactly 3 fl oz, and nothing should ever pick it.
    static let fluidOunce  = KitchenUnit(code: "floz", dimension: .volume, baseFactor: Rational(6),    singular: "fl oz",  plural: "fl oz",   isHouseholdCommon: false, system: .us)
    static let cup         = KitchenUnit(code: "cup",  dimension: .volume, baseFactor: Rational(48),   singular: "cup",    plural: "cups",    isHouseholdCommon: true,  system: .us)
    static let pint        = KitchenUnit(code: "pt",   dimension: .volume, baseFactor: Rational(96),   singular: "pint",   plural: "pints",   isHouseholdCommon: true,  system: .us)
    static let quart       = KitchenUnit(code: "qt",   dimension: .volume, baseFactor: Rational(192),  singular: "quart",  plural: "quarts",  isHouseholdCommon: true,  system: .us)
    static let gallon      = KitchenUnit(code: "gal",  dimension: .volume, baseFactor: Rational(768),  singular: "gallon", plural: "gallons", isHouseholdCommon: false, system: .us)
    /// 1 tsp = 5 mL, so 1 mL = 1/5 tsp.
    static let milliliter  = KitchenUnit(code: "ml",   dimension: .volume, baseFactor: Rational(1, 5), singular: "mL",     plural: "mL",      isHouseholdCommon: true,  system: .metric)
    static let liter       = KitchenUnit(code: "l",    dimension: .volume, baseFactor: Rational(200),  singular: "L",      plural: "L",       isHouseholdCommon: true,  system: .metric)

    // MARK: Mass — base gram. 1 oz = 28.35 g, 1 lb = 453.6 g, so 16 oz = 453.6 EXACTLY.
    static let gram        = KitchenUnit(code: "g",    dimension: .mass, baseFactor: Rational(1),        singular: "g",  plural: "g",  isHouseholdCommon: true, system: .agnostic)
    static let kilogram    = KitchenUnit(code: "kg",   dimension: .mass, baseFactor: Rational(1000),     singular: "kg", plural: "kg", isHouseholdCommon: true, system: .metric)
    static let ounce       = KitchenUnit(code: "oz",   dimension: .mass, baseFactor: Rational(567, 20),  singular: "oz", plural: "oz", isHouseholdCommon: true, system: .us)
    static let pound       = KitchenUnit(code: "lb",   dimension: .mass, baseFactor: Rational(2268, 5),  singular: "lb", plural: "lb", isHouseholdCommon: true, system: .us)

    /// The generic count unit. Every other count noun is synthesized by `countUnit(noun:)`
    /// and gets its OWN bucket.
    static let each = KitchenUnit(code: "each", dimension: .count, baseFactor: Rational(1), singular: "", plural: "", isHouseholdCommon: true, system: .agnostic)

    /// Pre-registered count nouns, so the picker has something to show and so pluralization
    /// is right. The set is open: anything a recipe file names resolves. These are the same
    /// nouns `scripts/import_recipe.py` recognises in `COUNT_NOUNS`, plus the ones its unit
    /// column accepts.
    static let knownCountNouns: [String: String] = [
        "clove": "cloves", "head": "heads", "slice": "slices", "loaf": "loaves",
        "bunch": "bunches", "sprig": "sprigs", "stick": "sticks", "can": "cans",
        "package": "packages", "ear": "ears", "fillet": "fillets", "rib": "ribs",
        "stalk": "stalks", "leaf": "leaves", "dozen": "dozen", "sheet": "sheets",
        "strip": "strips", "wedge": "wedges", "pinch": "pinches", "bulb": "bulbs",
        "packet": "packets", "bag": "bags", "bottle": "bottles"
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

    /// Returns nil ONLY for an empty code, which is how a row or a content line says
    /// "no unit".
    ///
    /// Any unknown code becomes a count noun in its own bucket rather than being thrown away
    /// — that is the graceful-degradation path both for a unit written by a newer build on
    /// another device and for a hand-authored recipe file using a noun nobody registered.
    /// `fallbackDimension` is the recorded dimension; it is advisory, because an unknown code
    /// has no factor into volume or mass and so cannot honour a `.volume`/`.mass` claim.
    /// Treating it as count keeps the amount intact and visible instead of silently zeroing
    /// it.
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
        "pint": "pt", "pints": "pt",
        "quart": "qt", "quarts": "qt",
        "gallon": "gal", "gallons": "gal",
        "milliliter": "ml", "milliliters": "ml", "millilitre": "ml", "cc": "ml",
        "liter": "l", "liters": "l", "litre": "l", "litres": "l",
        "gram": "g", "grams": "g", "gm": "g",
        "kilogram": "kg", "kilograms": "kg", "kilo": "kg", "kilos": "kg",
        "ounce": "oz", "ounces": "oz",
        "pound": "lb", "pounds": "lb", "lbs": "lb", "#": "lb"
    ]

    /// Token -> unit, for the unit PICKER and for `CatalogEntry.unit`. Bare "oz" resolves to
    /// MASS here, because recipes mean weight far more often and the fixture uses it as
    /// weight three times. The importer already resolves it by ingredient context and
    /// RECORDS the result on the line, so nothing downstream re-guesses.
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
    /// `floz` and `gal` never appear. US and metric sets are separate so a US display never
    /// offers litres, while grams stay available in both because he owns a scale.
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

### 3.4 `KitchenAid/Models/Support/Quantity.swift` and `QuantityCarrying`

```swift
// Quantity.swift
import Foundation

/// An amount and a unit.
///
/// WHY NOT `Measurement<UnitVolume>`, decided once:
///
/// - It is `Double`-backed, so 1/3 cup renders as 0.333333 on the first screen he opens, and
///   1/3 cup × 3 is not 1 cup.
/// - It is GENERIC over its dimension, so one property cannot hold both "1/4 cup" and
///   "2 cloves" — and an ingredient list is heterogeneous by nature.
/// - `UnitVolume` has no `clove`, `bunch`, `package` or `to taste`, which is most of how
///   recipes are actually written.
/// - Any `Measurement` stored in SwiftData needs a `Codable` wrapper anyway, so the "free"
///   option was never free.
///
/// A custom type was therefore mandatory regardless; given that, one well-tested type beats a
/// `Measurement` for some lines and something else for the rest.
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

    /// nil across dimension keys — including across two different count nouns, which is the
    /// point. Nothing in v1 crosses two count nouns: that is purchase-unit rounding, and it
    /// is deferred (`CLAUDE.md`).
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

/// The five stored primitives a model that holds ONE quantity declares, and the computed
/// accessor they share.
///
/// Quantities persist as FLAT PRIMITIVES, never as a `Codable` composite attribute. SwiftData
/// stores a `Codable` struct as an opaque encoded blob: it is unqueryable by `#Predicate`,
/// unreadable in the CloudKit dashboard, and — decisively — any future change to `Rational`
/// or to the unit table requires a custom migration stage that decodes every stored row in
/// the OLD Codable shape before re-encoding it. That is precisely the migration this project
/// exists to avoid. Five defaulted scalars survive every additive schema change.
///
/// A type may conform once, so the models carrying TWO or MORE quantities — `StockLot`
/// (`remaining`, `original`), `FoodItem` (`gramsPerCup`, `parLevel`) — use
/// the same five-primitive shape with distinct prefixes and their own accessors instead. The
/// protocol is the convenience; the SHAPE is the contract. In this schema the one conformer
/// is `IngredientOverride`.
protocol QuantityCarrying: AnyObject {
    var hasQuantity: Bool { get set }
    var amountNumerator: Int { get set }
    var amountDenominator: Int { get set }
    var unitCode: String { get set }
    var dimensionRaw: String { get set }
}

extension QuantityCarrying {
    /// nil means THERE IS NO QUANTITY — "Pinch flaky salt", "salt to taste". A nil quantity
    /// never enters arithmetic, never suppresses a shopping line, and cannot be confused with
    /// a deliberate zero or with a parse failure.
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
                // All FIVE primitives are cleared together. Leaving `unitCode` and
                // `dimensionRaw` at their previous values leaves a row that has no quantity
                // and still claims `tbsp`/`volume` — which no accessor reads, and which
                // `StoreHealthView`, the CloudKit dashboard and any future migration all
                // read as a contradiction. §0.4.8's "a quantity that does not exist is nil"
                // is only true if the whole group goes.
                hasQuantity = false
                amountNumerator = 0
                amountDenominator = 1
                unitCode = ""
                dimensionRaw = MeasureDimension.unmeasured.rawValue
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

### 3.5 `KitchenAid/Models/Support/QuantitySubtotal.swift`

```swift
import Foundation

/// ONE (dimension, count-noun) subtotal, in base units. **The only declaration.**
///
/// The panel listed a `QuantitySubtotal.swift` in its manifest with no spec, while declaring
/// the same thing as a nested `QuantityMath.Subtotal` — so half its signatures said one and
/// half said the other, and neither had an owner (§0.9.2). Resolved here: this is a top-level
/// type in its own file, `QuantityMath.Subtotal` does not exist, and every signature in §3.6,
/// §4 and §5 names `QuantitySubtotal`. `ShoppingListLineSubtotal` (§2.25) is its persisted
/// mirror and converts both ways.
struct QuantitySubtotal: Hashable, Sendable {
    /// "volume" | "mass" | "count:clove". The aggregation bucket, and the reason clove and
    /// head are separate subtotals ON ONE LINE.
    var dimensionKey: String
    /// EXACT, in tsp / g / count-of-noun.
    var base: Rational
    /// The unit chosen for display. Frozen onto the persisted row so a printed list reads
    /// the same in March.
    var preferredUnit: KitchenUnit
    /// Rides with the SPECIFIC number that was converted, which a line-level string cannot
    /// express.
    var conversionNote: String = ""
    /// Set when the exact value does not render to a denominator <= 8 and the display is an
    /// approximation prefixed "≈". The exact value is still what is stored.
    var isApproximateDisplay: Bool = false

    var quantity: Quantity? {
        guard preferredUnit.baseFactor != .zero else { return nil }
        return Quantity(amount: base / preferredUnit.baseFactor, unit: preferredUnit)
    }

    var displayString: String {
        guard let q = quantity else { return base.mixedDescription }
        return q.displayString()
    }
}

/// Which of the four numbers on a shopping line this subtotal is.
///
/// All four are kept per line and per dimension. `toBuy` is what he shops by; `purchase` is
/// what `InventoryLedger.receive` posts (decision 15). In v1 `purchase` equals `toBuy`,
/// because purchase-unit rounding is deferred (`CLAUDE.md`) — it is a separate role so the
/// rounding can arrive as a writer rather than as a migration.
enum SubtotalRole: String, Codable, CaseIterable, Sendable {
    case requested, have, toBuy, purchase

    var title: String {
        switch self {
        case .requested: return "Need"
        case .have: return "Have"
        case .toBuy: return "Buy"
        case .purchase: return "Purchase"
        }
    }
}
```

---

### 3.6 `KitchenAid/Models/Support/QuantityMath.swift`

```swift
import Foundation

/// The arithmetic under test. A pure enum: no fetches, no mutation, no SwiftUI.
enum QuantityMath {

    /// One contribution on the way in, with the unit it was WRITTEN in (which is what the
    /// hint is computed from).
    struct Contribution: Hashable, Sendable {
        var quantity: Quantity
    }

    // MARK: - Display unit selection

    /// Picks the unit a human would use, and says when the answer is approximate.
    ///
    /// (a) If the HINT unit — the unit the most source lines were written in, ties broken
    ///     toward the FINER unit — yields an amount in [1/4, 64), use it. If every recipe
    ///     says tbsp, he wants tbsp.
    /// (b) Otherwise take the COARSEST candidate where base/factor >= 1. If that amount's
    ///     reduced denominator exceeds 8, step ONE unit finer and retry.
    /// (c) If nothing yields a denominator <= 8, keep the coarsest with amount >= 1, keep the
    ///     EXACT value, and report `isApproximate` so the caller displays it rounded to the
    ///     nearest 1/8 prefixed "≈".
    /// (d) If NOTHING on the ladder reaches 1 — 1/2 tsp of a volume, a base smaller than the
    ///     finest unit — use the FINEST unit. This is the hole every other "largest unit
    ///     whose value is >= 1" rule leaves open, and it is why 1/2 tsp renders as "1/2 tsp"
    ///     and not as "0 tbsp".
    ///
    /// `fl oz`, `gallon` and (in US mode) `kg`/`L` are not candidates at all, which is what
    /// guarantees 18 tsp of butter renders "6 tbsp" and never "3 fl oz".
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

    /// The hint: the unit the most contributions were written in. Ties go to the FINER unit,
    /// because the finer unit yields a whole-ish number more often — which is what makes
    /// `2 tbsp + 1/4 cup` display as "6 tbsp" rather than "3/8 cup".
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

    /// Partition by `dimensionKey`, add EXACTLY within each partition, then attempt the one
    /// collapse there is: volume <-> mass, on a per-item density.
    ///
    /// Count nouns are partitioned FIRST and are **never folded into one another**, which is
    /// why "2 cloves + 1 head" never becomes "3 cloves" — and why it stays two subtotals on
    /// one line instead of one purchase noun. Turning a count noun into a different purchase
    /// noun is purchase-unit rounding, which is deferred; see `CLAUDE.md`.
    static func sum(
        _ contributions: [Contribution],
        using item: FoodItem?,
        system: UnitSystem = .us
    ) -> [QuantitySubtotal] {
        var bases: [String: Rational] = [:]
        for c in contributions {
            guard c.quantity.dimension != .unmeasured else { continue }
            bases[c.quantity.dimensionKey, default: .zero] =
                bases[c.quantity.dimensionKey, default: .zero] + c.quantity.base
        }
        var subtotals = bases.map { key, base -> QuantitySubtotal in
            let hint = hintUnit(from: contributions, dimensionKey: key)
            let (unit, approx) = displayUnit(
                forBase: base, dimensionKey: key, hint: hint, system: system
            )
            return QuantitySubtotal(
                dimensionKey: key, base: base, preferredUnit: unit,
                isApproximateDisplay: approx
            )
        }
        subtotals = collapseAcrossDimensions(subtotals, using: item, system: system)
        return subtotals.sorted { $0.dimensionKey < $1.dimensionKey }
    }

    /// Volume <-> mass, and ONLY with a per-item density.
    ///
    /// "1 cup flour + 200 g flour" is answered here. With no `gramsPerCup`, both buckets
    /// SURVIVE on one line and the caller flags `.needsBridge`. The app never invents a
    /// density: 1 cup = 240 g is right for water, off by ~2× for flour and ~1.4× for honey —
    /// and wrong SILENTLY, inside the number he is about to shop by. This is also why the
    /// catalogue's `gramsPerCup` is null for anything whose density is not settled, and why
    /// kosher salt has none at all.
    static func collapseAcrossDimensions(
        _ subtotals: [QuantitySubtotal], using item: FoodItem?, system: UnitSystem
    ) -> [QuantitySubtotal] {
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
            kept.append(QuantitySubtotal(
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
            kept.append(QuantitySubtotal(
                dimensionKey: MeasureDimension.volume.rawValue, base: total,
                preferredUnit: unit,
                conversionNote: "\(mass.base.mixedDescription) g counted as \((mass.base / gramsPerTsp).mixedDescription) tsp at \(gramsPerCup.mixedDescription) g per cup",
                isApproximateDisplay: approx
            ))
        }
        return kept
    }

    // MARK: - Bridging the HAVE side

    /// Converts `have` buckets into the dimensions `requested` actually uses. **Nothing else
    /// in this file does this, and without it the pantry case is broken.**
    ///
    /// The defect this exists to fix: `collapseAcrossDimensions` is only called from `sum`,
    /// and it returns early unless BOTH a volume and a mass subtotal are present in the same
    /// array. `requested` and `have` are summed independently, so each side carries only its
    /// own dimensions and that condition is never met. For a 2 tbsp butter requirement
    /// against a 4 oz lot, `requested` held only `volume`, `have` held only `mass`, `subtract`
    /// matched purely on `dimensionKey`, found nothing, bought the full 2 tbsp of butter he
    /// already had — and flagged `.needsBridge` on an item the shipped catalogue gives
    /// `gramsPerCup: 227`. The bridge existed; nothing called it.
    ///
    /// It bridges on DENSITY alone — volume ↔ mass, from the item's `gramsPerCup`. A count
    /// bucket has nowhere to go, because count nouns are not bridged in v1, and anything
    /// that still has nowhere to go is returned as-is. THAT is what `.needsBridge` is for.
    static func bridgeHave(
        _ have: [QuantitySubtotal],
        toward requestedKeys: Set<String>,
        using item: FoodItem?,
        system: UnitSystem = .us
    ) -> (bridged: [QuantitySubtotal], unbridgeable: [QuantitySubtotal]) {
        guard let item else { return ([], have) }
        var bridged: [QuantitySubtotal] = []
        var unbridgeable: [QuantitySubtotal] = []
        let gramsPerTsp = item.gramsPerCup.flatMap { $0 == .zero ? nil : $0 / Rational(48) }

        for bucket in have {
            if requestedKeys.contains(bucket.dimensionKey) {
                bridged.append(bucket)
                continue
            }
            var moved: QuantitySubtotal? = nil

            // Volume <-> mass, and ONLY with a per-item density. A count bucket that the
            // requirement does not already use falls through to `unbridgeable`.
            if let g = gramsPerTsp {
                let volumeKey = MeasureDimension.volume.rawValue
                let massKey = MeasureDimension.mass.rawValue
                if bucket.dimensionKey == massKey, requestedKeys.contains(volumeKey) {
                    let base = bucket.base / g
                    let (unit, approx) = displayUnit(
                        forBase: base, dimensionKey: volumeKey, hint: nil, system: system
                    )
                    moved = QuantitySubtotal(
                        dimensionKey: volumeKey, base: base, preferredUnit: unit,
                        conversionNote: "\(bucket.base.mixedDescription) g on hand counted as \(base.mixedDescription) tsp at \((g * Rational(48)).mixedDescription) g per cup",
                        isApproximateDisplay: approx
                    )
                } else if bucket.dimensionKey == volumeKey, requestedKeys.contains(massKey) {
                    let base = bucket.base * g
                    let (unit, approx) = displayUnit(
                        forBase: base, dimensionKey: massKey, hint: nil, system: system
                    )
                    moved = QuantitySubtotal(
                        dimensionKey: massKey, base: base, preferredUnit: unit,
                        conversionNote: "\(bucket.base.mixedDescription) tsp on hand counted as \(base.mixedDescription) g at \((g * Rational(48)).mixedDescription) g per cup",
                        isApproximateDisplay: approx
                    )
                }
            }

            if let moved { bridged.append(moved) } else { unbridgeable.append(bucket) }
        }
        return (bridged, unbridgeable)
    }

    // MARK: - Subtraction

    /// `toBuy = max(0, requested - have)`, per dimension, with BOTH sides clamped.
    ///
    /// A butter lot holding +1 lb (mass) and -2 tbsp (volume, used in cooking) yields a
    /// NEGATIVE volume have-subtotal from the signed ledger. Flooring only `toBuy` guards the
    /// wrong side: `1 cup - (-2 tbsp)` becomes `1 cup + 2 tbsp` and the negative residue
    /// silently INFLATES the purchase. So `have` is clamped first.
    ///
    /// Then, BEFORE the per-requirement loop, `bridgeHave` is given the chance to move stock
    /// into a dimension the requirement actually uses. Only stock that survives that attempt
    /// raises `.needsBridge` — a known density must never produce a bridge warning, which is
    /// the second half of the defect `bridgeHave` fixes.
    ///
    /// When a requirement and the matching stock are in DIFFERENT dimensions and the item
    /// carries no usable bridge, `needed = requested` — assume NOTHING is on hand — and the
    /// line is flagged `.needsBridge`. Never silently subtract, and never silently treat the
    /// requirement as covered: buying a duplicate pound of butter is a far cheaper error than
    /// arriving at dinner without it.
    ///
    /// `didReduce` is returned so the caller can tell `.partiallyHave` from `.needed`
    /// (§4.2 step 6). A line where some bucket was genuinely reduced but not to zero is a
    /// different fact from a line nothing covered, and `ShoppingListDetailView` partitions
    /// on it.
    static func subtract(
        requested: [QuantitySubtotal],
        have: [QuantitySubtotal],
        item: FoodItem?,
        system: UnitSystem = .us
    ) -> (toBuy: [QuantitySubtotal], flags: Set<LineFlag>, didReduce: Bool) {
        var flags: Set<LineFlag> = []
        let requestedKeys = Set(requested.map(\.dimensionKey))
        let clamped = have.map {
            QuantitySubtotal(
                dimensionKey: $0.dimensionKey, base: $0.base.clampedAtZero,
                preferredUnit: $0.preferredUnit, conversionNote: $0.conversionNote,
                isApproximateDisplay: $0.isApproximateDisplay
            )
        }
        let (usable, unbridgeable) = bridgeHave(
            clamped, toward: requestedKeys, using: item, system: system
        )
        // ONLY stock that could not be converted raises the flag. The old condition read
        // `item?.gramsPerCup == nil`, which fired on a dimension mismatch the density could
        // in fact bridge, and the second condition fired whenever ANY bucket was unmatched —
        // so one unbridgeable row flagged every requirement on the line.
        if !unbridgeable.isEmpty { flags.insert(.needsBridge) }
        if usable.contains(where: { !$0.conversionNote.isEmpty }) { flags.insert(.converted) }

        let haveByKey = Dictionary(
            usable.map { ($0.dimensionKey, $0.base) },
            uniquingKeysWith: { $0 + $1 }
        )

        var out: [QuantitySubtotal] = []
        var didReduce = false
        for r in requested {
            let onHand = haveByKey[r.dimensionKey] ?? .zero
            if onHand != .zero { didReduce = true }
            let remainder = (r.base - onHand).clampedAtZero
            guard remainder != .zero else { continue }
            let (unit, approx) = displayUnit(
                forBase: remainder, dimensionKey: r.dimensionKey,
                hint: r.preferredUnit, system: system
            )
            out.append(QuantitySubtotal(
                dimensionKey: r.dimensionKey, base: remainder,
                preferredUnit: unit, conversionNote: r.conversionNote,
                isApproximateDisplay: approx
            ))
        }
        return (out, flags, didReduce)
    }
}
```

### 3.7 `KitchenAid/Models/Support/MergeKey.swift`

```swift
import Foundation

/// How a line is identified for aggregation.
enum ItemIdentity: Hashable, Sendable {
    /// `FoodItem.id`, post-reconcile so aliases have collapsed.
    case cataloged(UUID)
    /// A normalized name that matched no `FoodItem` and no catalogue entry. Still shoppable,
    /// flagged `.unresolvedItem`, and fixable with one tap in the ingredient inbox.
    case freeText(String)
}

/// The SUBTOTAL bucket. **It never keys a line.**
///
/// A shopping LINE is keyed by `ItemIdentity` alone — one line per `FoodItem` per list
/// (§2.25, §4.2 step 4) — and `MergeKey` keys the buckets within that line.
///
/// `dimensionKey` carries the count NOUN, so clove and head are separate subtotals ON ONE
/// LINE and the output type can display exactly what the merge key separated. Putting
/// `dimensionKey` in the LINE key instead splits one `FoodItem` asked for in two dimensions
/// into two lines, makes `DraftLine.requested` plural for nothing, and hands
/// `QuantityMath.sum` a group that is single-dimension by construction — which disables
/// `collapseAcrossDimensions` on the requested side, the one place it is most needed.
///
/// `preparation` is deliberately NOT in the key: you buy onions, not diced-ness, so "1 cup
/// onion, diced" and "1/2 cup onion, sliced" merge into "1 1/2 cups onion" while both cook
/// screens still say diced and sliced.
struct MergeKey: Hashable, Sendable {
    let item: ItemIdentity
    let dimensionKey: String
}
```

### 3.8 `KitchenAid/Models/Support/KitchenAidEnums.swift`

```swift
import Foundation

/// Every enum is `String`-raw-value-backed. On the SwiftData side it is stored as a
/// `…Raw: String` with a computed accessor that falls back to a default, so a value written
/// by a newer build on another device DEGRADES gracefully instead of failing to decode —
/// CFAL3's `Session.mode` convention. On the content side the same raw values are what a
/// recipe file writes.

enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case us, metric, agnostic
}

enum MealSlot: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A REAL slot, not a nicety. The fixture's step 1 is a 30-minute passive rest and its
    /// notes say the spinach can be made a day ahead, so "salt the steaks, uncovered in the
    /// fridge" has to land on Friday for Saturday's dinner. It sorts first because it is work
    /// done ahead of the day's meals.
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

    /// What `GenerateShoppingListSheet` offers and what the default list build uses. `.prep`
    /// is excluded because its ingredients belong to the meal it prepares for, and including
    /// both would buy the steak twice.
    static let shoppableDefaults: Set<MealSlot> =
        [.breakfast, .brunch, .lunch, .snack, .dinner, .dessert, .other]
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

enum TagKind: String, Codable, CaseIterable, Sendable {
    case cuisine, method, occasion, general
}

/// Applied to the WHOLE-RECIPE scale, with a `.snappedToBatch` note. A per-line "fixed" rule
/// handles the bay leaf but cannot express "you cannot bake 3/4 of a cake" — that is a
/// recipe-level property.
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

/// `.fixed` is how "1 bay leaf" and the oil for the pan survive a 3× batch without becoming
/// three bay leaves and a fistful of salt.
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
    /// Written with `hasDelta == false`. A cook depletion that needs a density the item does
    /// not carry is RECORDED, not skipped and not guessed, and lands in the "Unresolved
    /// depletions" inbox. A skipped depletion is an invisible overstatement of stock.
    case pendingBridge
    case voided
}

enum LineStatus: String, Codable, CaseIterable, Sendable {
    case needed, haveEnough, partiallyHave, needsBridge, unresolvedItem, manual, staple
}

enum LineSourceKind: String, Codable, CaseIterable, Sendable {
    case plannedMeal
    /// A staple reaches the list by a RULE when its rollup falls below par, rather than only
    /// when a Bool is flipped by hand.
    case parLevel
    case manual
}

enum PlanScope: String, Codable, CaseIterable, Sendable {
    case month, week, day, brief
}
```

### 3.9 `ScalingNote.swift`, `LineFlag.swift`, `CalendarKey.swift`, `NameNormalizer.swift`

```swift
// ScalingNote.swift
import Foundation

/// Surfaced as a BADGE on every affected shopping line, not swallowed.
///
/// A meal with nobody assigned must neither silently buy nothing nor silently buy for four,
/// and a snapped batch must say it snapped.
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

```swift
// LineFlag.swift
import Foundation

enum LineFlag: String, Codable, CaseIterable, Sendable {
    case needsBridge        // volume vs mass with no density; nothing assumed on hand
    case unresolvedItem     // matched no FoodItem and no catalogue entry
    case assumedOnHand      // a staple, diverted to the footer
    case converted          // the density bridge fired; see the conversionNote
    case expiredStockIgnored
    case expiringBeforeNeed // excluded by expiringGraceDays
    case tweaked            // an IngredientOverride changed this requirement
    case noAttendance
    case unknownYield
    case snappedToBatch
    case overridden
    /// Present because `ScalingNote` has it and §3.9 promises every scaling note is
    /// "surfaced as a BADGE on every affected shopping line, not swallowed". Without this
    /// case `from(_:)` mapped it to nil and the extra quantity bought for Tuesday's
    /// leftovers appeared on the list with nothing explaining it.
    case leftoversIncluded
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

    /// Total over `ScalingNote`: every note now has a flag, so nothing is swallowed.
    static func from(_ notes: [ScalingNote]) -> Set<LineFlag> {
        Set(notes.map {
            switch $0 {
            case .noAttendance: return .noAttendance
            case .unknownYield: return .unknownYield
            case .snappedToBatch: return .snappedToBatch
            case .overridden: return .overridden
            case .leftoversIncluded: return .leftoversIncluded
            }
        })
    }

    /// The badge text `FlagBadge` renders.
    var badge: String {
        switch self {
        case .needsBridge: return "needs weight per cup"
        case .unresolvedItem: return "not matched"
        case .assumedOnHand: return "assumed on hand"
        case .converted: return "converted"
        case .expiredStockIgnored: return "expired stock ignored"
        case .expiringBeforeNeed: return "expires before you need it"
        case .tweaked: return "your tweak"
        case .noAttendance: return "no eaters set"
        case .unknownYield: return "yield unknown"
        case .snappedToBatch: return "whole batch"
        case .overridden: return "scale overridden"
        case .leftoversIncluded: return "extra for leftovers"
        case .parLevel: return "below par"
        case .manual: return "added by hand"
        }
    }
}
```

```swift
// CalendarKey.swift
import Foundation

/// The ONLY place day math lives.
///
/// `dayKey` is yyyymmdd as an Int. A `#Predicate` on a `Date` range is correct until he plans
/// a trip, crosses a timezone or hits a DST boundary, and then "Tuesday's dinner" renders on
/// Monday night — which he reads as "the app moved my dinner". An integer day is unambiguous,
/// sorts, indexes, and costs four bytes.
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

```swift
// NameNormalizer.swift
import Foundation

/// Produces the `matchKey`: lowercase, strip diacritics and punctuation, collapse whitespace,
/// drop a leading article, drop parentheticals and trailing prep qualifiers (`, chopped`,
/// `, divided`, `(optional)`), then a conservative singularizer (`-ies→y`, `-oes→o`, `-s→∅`)
/// with a stoplist for `asparagus`, `couscous`, `molasses`, `greens`, `hummus`.
///
/// Deliberately **not** a stemmer — over-normalizing collides `butter`/`buttermilk`.
///
/// Normalization cannot solve synonymy, so it does not try. "Scallion" vs "green onion" is
/// the catalogue's shipped `aliases` first (§0.3), and a `FoodItemAlias` row he adds second.
///
/// It is also the function that generates a content `lineID` slug, so the importer and the
/// app agree on what `butter-2` means. `slug` below is a line-for-line port of
/// `scripts/import_recipe.py`'s `slug()`, and **the Python one is the reference**: if they
/// ever disagree, the ids in the committed files are what the Python produced, so this is
/// what changes (§0.7).
///
/// Written out rather than left as two signatures because §3 is copied verbatim into the
/// codebase, a bodiless `func` outside a `protocol` does not parse, and `matchKey` is
/// called from `CatalogEntry.matchKey`, `CatalogEntry.aliasMatchKeys`, §4.2 step 4 and
/// `FoodItemResolver` — so nothing downstream would have compiled either.
enum NameNormalizer {

    /// Trailing clauses that describe PREPARATION, not identity. Dropped from the match key
    /// so "Parmesan, grated" and "Parmesan" are one purchase. Deliberately short: the
    /// identity-changing adjectives (`prepared`, `fresh`, `dried`, `smoked`, `unsalted`)
    /// are NOT here, because prepared horseradish is a different product from horseradish
    /// root and `scripts/import_recipe.py` makes the same distinction.
    private static let prepQualifiers: Set<String> = [
        "chopped", "minced", "grated", "ground", "melted", "softened", "shredded",
        "sliced", "diced", "crushed", "smashed", "toasted", "cooked", "drained",
        "rinsed", "peeled", "trimmed", "divided", "optional", "to taste", "for garnish",
        "for serving", "finely chopped", "roughly chopped", "thinly sliced", "room temperature"
    ]

    /// Words whose plural is not an "s" suffix, or which simply end in one. Singularizing
    /// these produces "asparagu", which then matches nothing — and a conservative
    /// singularizer that occasionally leaves a plural alone is strictly better than one
    /// that invents a word.
    private static let singularStoplist: Set<String> = [
        "asparagus", "couscous", "molasses", "greens", "hummus", "swiss", "bass",
        "grass", "watercress", "chives", "capers", "oats", "peas", "beans", "lentils",
        "sprouts", "grits", "ribs", "leaves"
    ]

    /// Lowercase, diacritic-fold, drop parentheticals and trailing prep clauses, strip
    /// punctuation, collapse whitespace, drop a leading article, then singularize the last
    /// word conservatively.
    static func matchKey(_ raw: String) -> String {
        // Fold diacritics first, so "crème fraîche" and "creme fraiche" are one key.
        var s = raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                            locale: Locale(identifier: "en_US_POSIX"))

        // Parentheticals are always commentary: "butter (unsalted)", "flour (for dusting)".
        while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            s.replaceSubrange(open...close, with: " ")
        }

        // Trailing prep clauses, comma-delimited. Only trailing ones, and only known
        // qualifiers — "tomato, sun-dried" must keep its tail, because that is the product.
        var parts = s.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while parts.count > 1,
              let last = parts.last?.lowercased(),
              prepQualifiers.contains(last) {
            parts.removeLast()
        }
        s = parts.joined(separator: " ")

        // Keep letters, digits and spaces; everything else becomes a space. Hyphens go too,
        // so "flat-leaf parsley" and "flat leaf parsley" are one key.
        let scalars = s.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        var words = String(scalars).split(separator: " ").map(String.init)

        if words.count > 1, ["a", "an", "the"].contains(words[0]) { words.removeFirst() }
        guard var last = words.popLast() else { return "" }

        // Conservative singularizer. Not a stemmer: over-normalizing collides
        // `butter` / `buttermilk`, which is a wrong SHOPPING LINE and not a cosmetic slip.
        if !singularStoplist.contains(last) {
            if last.hasSuffix("ies"), last.count > 4 {
                last = String(last.dropLast(3)) + "y"
            } else if last.hasSuffix("oes"), last.count > 4 {
                last = String(last.dropLast(2))
            } else if last.hasSuffix("ves"), last.count > 4 {
                last = String(last.dropLast(3)) + "f"
            } else if last.hasSuffix("ses") || last.hasSuffix("xes") || last.hasSuffix("zes")
                        || last.hasSuffix("ches") || last.hasSuffix("shes") {
                last = String(last.dropLast(2))
            } else if last.hasSuffix("s"), !last.hasSuffix("ss"), last.count > 3 {
                last = String(last.dropLast())
            }
        }
        words.append(last)
        return words.joined(separator: " ")
    }

    /// "NY strip steak" -> "ny-strip-steak". Used for `lineID`, for `stepID` and for a
    /// recipe file name.
    ///
    /// A PORT of `scripts/import_recipe.py`'s `slug()`, and intentionally NOT built on
    /// `matchKey`: an id must be byte-stable for the life of the file, so it must not move
    /// when the singularizer or the qualifier list is improved. Alphanumerics survive,
    /// everything else collapses to a single hyphen, and the ends are trimmed.
    static func slug(_ raw: String) -> String {
        var out = ""
        for character in raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if let previous = out.last, previous != "-" {
                out.append("-")
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
```

### 3.10 `KitchenAid/Models/Content/ResolvedRecipe.swift`

```swift
import Foundation

/// Bundled content with the overlay applied — what every view actually renders.
///
/// `TweakStore.effectiveRecipe(id:)` builds one by copying the loaded `Recipe` VALUE and
/// writing the overrides into the copy. **The loaded content is never mutated**, so two
/// screens showing the same recipe cannot disagree, and the next launch re-reads the file as
/// written (§0.2).
///
/// It carries the override sets as well as the result, because the UI has to show which
/// numbers are his: an ingredient row with an override gets an "edited" dot and a "back to as
/// written" action, and the PDF prints the effective value with a footnote.
struct ResolvedRecipe: Sendable {
    /// Overrides already applied.
    var recipe: Recipe
    /// As bundled, for the "as written" comparison.
    var original: Recipe
    var overriddenLineIDs: Set<String> = []
    var overriddenStepIDs: Set<String> = []
    var lastMadeAt: Date? = nil
    var userNotes: String = ""
    var isFavorite: Bool = false

    /// Overrides whose `lineID` or `stepID` no longer exists in the bundled recipe, because
    /// the file was revised. They are REPORTED, not discarded: `TweakSheet` lists them as
    /// "this no longer applies — remove it?" so a lost tweak is visible rather than silent.
    var lapsedOverrides: [LapsedOverride] = []

    struct LapsedOverride: Identifiable, Sendable {
        var id = UUID()
        var kind: Kind
        var key: String
        var snapshot: String
        enum Kind: String, Sendable { case ingredient, step }
    }

    var hasTweaks: Bool {
        !overriddenLineIDs.isEmpty || !overriddenStepIDs.isEmpty || !userNotes.isEmpty
    }

    // MARK: Forwarding accessors onto the effective recipe
    //
    // `RecipeGraph.flatten` takes a `ResolvedRecipe` and walks its components and its id.
    // Without these, §4.2 step 3's `recipe.components` and `visited.contains(recipe.id)` do
    // not compile — `ResolvedRecipe` holds `recipe` and `original` and has neither member.
    // Forwarding rather than spelling `recipe.recipe.components` at every call site,
    // because `.recipe.recipe` is the kind of line a later reader "simplifies" wrongly.
    var id: String { recipe.id }
    var components: [RecipeComponent] { recipe.components }
    var steps: [RecipeStep] { recipe.steps }
    var title: String { recipe.title }
    var servings: Rational { recipe.servings }
    var batchGranularity: BatchGranularity { recipe.batchGranularity }
}
```

### 3.11 `KitchenAid/Models/Support/LedgerDivergence.swift`

```swift
import Foundation

/// One row of the reconcile report: **what the cache says, what the ledger says, and the
/// difference.** Declared here because the panel named it in `InventoryLedger`'s signature
/// and never wrote it down (§0.9.3).
///
/// It has to carry three things the panel's own prose demanded of it:
///
/// 1. **The per-lot / per-item split.** A lot's `remaining` can drift from the sum of that
///    lot's transactions, AND an item's total can drift from the sum of all its transactions.
///    They are different bugs with different fixes, so `scope` distinguishes them.
/// 2. **The unassigned-lot bucket.** `level(of:)` sums the item's transactions, not its lots
///    (decision 8), so a transaction whose lot was deleted still counts — and it has to be
///    attributable to something. `.unassignedLot` is that something, and a divergence that
///    lands there is the one case where the right action is "assign these to a lot" rather
///    than "rebuild the cache".
/// 3. **The delta**, per dimension, exactly. Not a Bool "diverged": the reconcile screen says
///    "cache says 2 lb, ledger says 1 lb 14 oz, short by 2 oz", because a number he can read
///    is the difference between trusting the repair and reinstalling the app.
struct LedgerDivergence: Identifiable, Sendable {
    enum Scope: Hashable, Sendable {
        /// One lot's `remaining` cache versus its own transactions.
        case lot(UUID)
        /// One item's rolled-up level versus the sum of all its transactions.
        case item(UUID)
        /// Transactions for this item whose `lot == nil`. Not an error on its own — it
        /// becomes one only when nothing accounts for them.
        case unassignedLot(itemID: UUID)
    }

    var id = UUID()
    var scope: Scope
    /// Readable even when the row it describes was orphaned, from `foodItemNameSnapshot`.
    var itemName: String
    var lotLabel: String = ""
    var dimensionKey: String

    /// What the cache claims, in base units.
    var cachedBase: Rational
    /// What the append-only ledger sums to, in base units. The TRUTH.
    var ledgerBase: Rational
    /// `ledgerBase - cachedBase`. Negative means the cache is overstating stock, which is the
    /// direction that makes him arrive at dinner without butter.
    var delta: Rational { ledgerBase - cachedBase }
    var isDiverged: Bool { delta != .zero }

    /// Transactions that could not be counted at all: `resolutionState == .pendingBridge`.
    /// Shown beside the delta because they EXPLAIN part of it, and clearing them is the fix.
    var pendingBridgeCount: Int = 0

    var preferredUnit: KitchenUnit

    func display(_ value: Rational) -> String {
        guard preferredUnit.baseFactor != .zero else { return value.mixedDescription }
        return Quantity(amount: value / preferredUnit.baseFactor, unit: preferredUnit).displayString()
    }
}
```

### 3.12 `KitchenAid/Models/Support/DeleteRefusal.swift`

```swift
import Foundation

/// Why a delete was refused, and what to offer instead. Declared here because the panel used
/// it in `FoodItemResolver.canDelete`'s return type and never wrote it down (§0.9.3).
///
/// The SCHEMA already guarantees nothing is destroyed — `FoodItem → lots/transactions` is
/// `.nullify` (decision 7). This is the courteous layer on top: it turns "that would orphan
/// your ledger" into a sentence and a button.
struct DeleteRefusal: Error, Identifiable, Sendable {
    enum Reason: String, Sendable {
        case hasLedgerHistory       // lots or transactions exist
        case isOnOpenShoppingList
        case isLastEater            // the roster must not reach zero; scaling has nothing to divide
        case isDefaultStore
        case isOnlyStorageLocation
    }

    var id = UUID()
    var reason: Reason
    var subjectName: String
    var affectedCount: Int = 0

    var message: String {
        switch reason {
        case .hasLedgerHistory:
            return "\(subjectName) has \(affectedCount) inventory records. Deleting it would leave them unattributed."
        case .isOnOpenShoppingList:
            return "\(subjectName) is on a shopping list you have not finished."
        case .isLastEater:
            return "Keep at least one person in the household — attendance is what scales a recipe."
        case .isDefaultStore:
            return "\(subjectName) is the default store. Make another one default first."
        case .isOnlyStorageLocation:
            return "\(subjectName) is the only place you can put groceries."
        }
    }

    /// The action the sheet offers instead of deleting.
    var suggestion: String {
        switch reason {
        case .hasLedgerHistory: return "Merge into another item"
        case .isOnOpenShoppingList: return "Remove it from the list first"
        case .isLastEater: return "Mark them inactive instead"
        case .isDefaultStore: return "Choose a new default"
        case .isOnlyStorageLocation: return "Add another location first"
        }
    }
}
```

### 3.13 `KitchenAid/Models/Support/CookTimer.swift`

```swift
import Foundation

/// One running step timer. View state on `CookSession`, never persisted — a timer that
/// survives a relaunch is a timer that fires for a dish that came out of the oven an hour
/// ago. Declared here because the panel put `timers: [CookTimer]` in `CookSession` and never
/// wrote the type down (§0.9.3).
///
/// A three-component plated dish cooks three things at once, so these are CONCURRENT and
/// rendered as chips. The timer runs to the LONGER end of a range (`RecipeStep.timerSeconds`
/// uses `maxMinutes ?? minMinutes`) so it never fires early on "7 to 8 min".
struct CookTimer: Identifiable, Hashable, Sendable {
    var id = UUID()
    /// `RecipeStep.stepID`, so the chip can scroll the list to its step.
    var stepID: String
    /// "Sear the steak" — what the notification says.
    var label: String
    var totalSeconds: Int
    var startedAt: Date
    /// Set when he pauses; nil while running.
    var pausedAt: Date? = nil
    var accumulatedPauseSeconds: Int = 0
    /// The `UNNotificationRequest` identifier, so cancelling the chip cancels the alert. A
    /// backgrounded app still has to ring — his hands are in a bowl.
    var notificationID: String

    func remainingSeconds(asOf now: Date = .now) -> Int {
        let reference = pausedAt ?? now
        let elapsed = Int(reference.timeIntervalSince(startedAt)) - accumulatedPauseSeconds
        return max(0, totalSeconds - max(0, elapsed))
    }

    func hasFired(asOf now: Date = .now) -> Bool { remainingSeconds(asOf: now) == 0 }
    var isPaused: Bool { pausedAt != nil }
}
```

### 3.14 `KitchenAid/Services/ExportError.swift`

```swift
import Foundation

/// Every way a PDF render can fail. Declared here because the panel threw
/// `ExportError.contextUnavailable` in `PDFPageWriter` and never wrote the type down
/// (§0.9.3).
///
/// Export is the one feature whose output leaves the device, so a failure gets a sentence he
/// can act on rather than a spinner that stops.
enum ExportError: LocalizedError, Sendable {
    case contextUnavailable
    case temporaryDirectoryUnwritable
    case nothingToExport
    /// A `recipeID` on the job no longer resolves (§0.2).
    case recipeMissing(id: String, titleSnapshot: String)
    case pageMeasurementFailed(page: String)

    var errorDescription: String? {
        switch self {
        case .contextUnavailable:
            return "Could not start a PDF document."
        case .temporaryDirectoryUnwritable:
            return "Could not write the file. There may be no space left."
        case .nothingToExport:
            return "There is nothing in this range to export."
        case .recipeMissing(_, let titleSnapshot):
            return "\(titleSnapshot.isEmpty ? "A recipe" : titleSnapshot) is no longer in the app, so it cannot be printed."
        case .pageMeasurementFailed(let page):
            return "Could not lay out the \(page) page."
        }
    }
}
```

---

## 4. The shopping-list algorithm

This is where the app is either good or useless. `ShoppingListBuilder` is a pure `enum` in
the spirit of CFAL3's `ReviewScheduler`: **no fetches, no mutation, no SwiftUI.** It reads
values and closures the caller already has and returns a value. Every step below is
independently unit-testable with no `ModelContainer`.

Content being bundled changes exactly two things here, and nothing else: the flattener takes
a `Recipe` **value** rather than fetching a row, and sub-recipes are resolved through an
injected `recipe: (String) -> Recipe?` closure instead of a relationship. The arithmetic is
untouched.

### 4.1 Types

**These three blocks are `text` API sketches, not copy-paste Swift** (see the fence
convention at the top of this document). The value types in them are final as written; the
function bodies are §4.2. Nothing below declares a body, which is exactly why these are not
`swift` fences — a bodiless `func` in a concrete `enum` is a parse error, and §1–§3 are
the only sections that promise to compile.

```text
// KitchenAid/Services/MealScaling.swift
enum MealScaling {
    struct Result: Sendable {
        let portions: Rational
        let scale: Rational
        let notes: [ScalingNote]
        /// "×1 1/2 — 6 eaters, recipe serves 4". Lands on EVERY source row.
        let description: String
    }

    /// `recipe` is passed in rather than reached for, because `MealRecipe` holds an id now.
    ///
    /// It takes a `Recipe`, so the builder — whose only resolver returns a
    /// `ResolvedRecipe?` — calls it as
    /// `MealScaling.scaling(for: mealRecipe, recipe: resolved?.recipe, defaultDinerCount: …)`.
    /// The scale depends on `servings` and `batchGranularity`, neither of which an override
    /// can touch (§5.2 rule 3), so the overlay is irrelevant here and passing the bundled
    /// value makes that explicit.
    static func scaling(
        for mealRecipe: MealRecipe,
        recipe: Recipe?,
        defaultDinerCount: Int
    ) -> Result
}
```

```text
// KitchenAid/Services/RecipeGraph.swift
enum RecipeGraph {
    struct Provenance: Hashable, Sendable {
        var mealID: UUID?
        var mealDayKey: Int
        var mealSlotRaw: String
        var mealTitle: String
        var recipeTitle: String
        /// A content id string, not a UUID.
        var recipeID: String
        var scaleDescription: String
    }

    struct FlatLine: Sendable {
        /// The content line's stable id, carried through so a buy-or-make decision and a
        /// `.tweaked` flag can be replayed on a regenerate.
        var lineID: String
        /// "" when the importer could not place it; the caller resolves this to a `FoodItem`.
        var catalogName: String
        var displayName: String
        /// Already scaled, and already overridden. nil = unmeasured; carries
        /// `unmeasuredNote` instead.
        var quantity: Quantity?
        var unmeasuredNote: String
        var preparation: String
        var originalText: String
        var scaledText: String
        var wasTweaked: Bool
        /// ["NY Strip Crostini", "Creamed horseradish spinach"] — captured at flatten time,
        /// never reconstructed later. It is what the provenance row prints.
        var componentPath: [String]
        var provenance: Provenance
        var notes: [ScalingNote]
    }

    enum Diagnostic: Hashable, Sendable {
        case cycle(recipeTitle: String)
        case depthExceeded(recipeTitle: String)
        /// The sub-recipe could not be expanded dimensionally. The line stays a buy-it line
        /// and says so, rather than being silently mis-scaled.
        case subRecipeNotExpandable(recipeTitle: String, lineText: String, reason: String)
        case unresolvedItem(text: String, recipeTitle: String)
        /// A `sourceRecipeID` or `subRecipeID` that `RecipeLoader` cannot resolve — the
        /// dangling-id case from §0.2, surfaced rather than silently contributing nothing.
        case missingRecipe(id: String, inRecipeTitle: String)
        case orphanedComponentReference(componentTitle: String, recipeTitle: String)
        case zeroServings(recipeTitle: String)
    }

    /// `visited` is passed BY VALUE and that is not a style choice.
    ///
    /// As `inout` it becomes a global already-seen set rather than a per-PATH cycle guard, so
    /// a sub-recipe used in two sibling branches — the chimichurri as a component AND
    /// referenced by a second component, or one stock recipe feeding two of the week's meals
    /// in a single build — silently contributes ZERO ingredients on every use after the
    /// first. By value, each branch carries its own path.
    ///
    /// `visited` is now a `Set<String>` of content ids rather than UUIDs. Same guarantee.
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
    ) -> [FlatLine]

    /// The dimensionally-sound sub-recipe scale. nil means DO NOT EXPAND.
    ///
    /// Takes a `Recipe`, so the call site inside `flatten` — where the sub-recipe arrived
    /// from `resolve: (String) -> ResolvedRecipe?` — reads
    /// `childScale(for: line, subRecipe: sub.recipe)`. The yield fields it divides by are
    /// bundled content that no override can change, same reasoning as `MealScaling` above.
    static func childScale(for line: IngredientLine, subRecipe: Recipe) -> Rational?
}
```

```text
// KitchenAid/Services/ShoppingListBuilder.swift
enum ShoppingListBuilder {
    struct Options: Hashable, Sendable {
        var range: DateInterval
        var slots: Set<MealSlot> = MealSlot.shoppableDefaults
        var subtractInventory: Bool = true
        var countExpiredAsAvailable: Bool = false
        /// Excludes stock expiring before the END of the plan range from the on-hand total,
        /// so a yogurt that dies Tuesday does not cover Friday's recipe.
        var expiringGraceDays: Int = 0
        var includeStaples: Bool = false
        var includeOptionalLines: Bool = false
        // There is deliberately NO `roundToPurchaseUnits` either: purchase-unit
        // rounding was cut (CLAUDE.md), and this flag outlived it in three places
        // with no reader anywhere, defaulting to true — so every persisted list
        // would have recorded "rounded to purchase units: yes" about a list
        // shopped by the exact need. Which is precisely the failure the comment
        // below describes.
        // There is deliberately NO `includeCoveredLines`. Step 6 and §2.24's rationale both
        // FORBID removing a covered line — it is kept and collapsed under "Already have",
        // because a silently absent line is indistinguishable from a bug and he needs to see
        // the app's belief about his fridge before he will trust it. An option nothing
        // honours and `ShoppingList` cannot freeze is worse than no option: it reads as a
        // promise the builder never made.
        /// Buy-or-make overrides for THIS run, by content `lineID`. Frozen onto the list so a
        /// regenerate is reproducible.
        var expandedLineIDs: Set<String> = []
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
        var recipeID: String
        var recipeTitle: String
        var lineID: String
        var componentPath: String
        var originalText: String
        var scaledText: String
        var scaleDescription: String
        var contribution: QuantitySubtotal?
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
        var requested: [QuantitySubtotal]
        var have: [QuantitySubtotal]
        var toBuy: [QuantitySubtotal]
        var purchase: [QuantitySubtotal]
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

    /// Steps 1–9, nothing persisted. The generation sheet calls this live as he toggles
    /// options: "32 items across 6 sections, 4 flagged".
    ///
    /// **THREE closures and two fetched values**, and that is the whole testability story:
    /// the builder never reaches for a `ModelContext`, a `RecipeLoader` or a `TweakStore`.
    /// (`meals` and `parLevelShortfalls` are the fetched values; `options` is configuration.)
    ///
    /// `inventoryLevel` takes the `Options` and returns FLAGS as well as subtotals, and that
    /// is not decoration. Step 6 documents three inventory exclusions — expired stock,
    /// stock expiring inside the grace window, and unapplied rows — and two line flags,
    /// `.expiredStockIgnored` and `.expiringBeforeNeed`. A closure of
    /// `(FoodItem) -> [QuantitySubtotal]` receives no dates and no options and returns no
    /// flags, so it could apply none of the filters and set neither flag: the two flags had
    /// no writer anywhere in this document. The ledger knows the lots and their dates, so
    /// the ledger applies the filters and reports what it dropped.
    static func preview(
        meals: [PlannedMeal],
        resolveRecipe: (String) -> ResolvedRecipe?,
        resolveItem: (_ catalogName: String, _ displayName: String) -> FoodItem?,
        inventoryLevel: (FoodItem, Options) -> (subtotals: [QuantitySubtotal], flags: Set<LineFlag>),
        parLevelShortfalls: [(FoodItem, QuantitySubtotal)],
        options: Options
    ) -> Draft

    /// Identical to `preview`. Named separately so the call sites read correctly;
    /// persistence is `ShoppingListStore.materialize(draft:into:existing:)`, steps 10–11.
    static func build(
        meals: [PlannedMeal],
        resolveRecipe: (String) -> ResolvedRecipe?,
        resolveItem: (_ catalogName: String, _ displayName: String) -> FoodItem?,
        inventoryLevel: (FoodItem, Options) -> (subtotals: [QuantitySubtotal], flags: Set<LineFlag>),
        parLevelShortfalls: [(FoodItem, QuantitySubtotal)],
        options: Options
    ) -> Draft
}
```

### 4.2 The steps

**Step 1 — collect the meals.**

```text
FetchDescriptor<PlannedMeal>(
    predicate: #Predicate { $0.dayKey >= startKey && $0.dayKey <= endKey },
    sortBy: [SortDescriptor(\.dayKey), SortDescriptor(\.slotSortIndex),
             SortDescriptor(\.orderInSlot)]
)
```

Keep `meal.contributesToShopping && options.slots.contains(meal.slot)`. That one accessor
drops, **by kind and not by a skipped flag**:

- `.leftovers` — Tuesday reheating Sunday's ragù. The single most important exclusion in this
  algorithm and the largest source of over-buying in a weekly plan.
- `.takeout`, `.eatingOut`, `.note` — nothing to buy.
- `status == .skipped` — he decided not to.
- **`status == .cooked`** — cooking already depleted inventory, so collecting it again shops
  twice for a meal already made.

Meals with no `MealRecipe` contribute nothing but are counted into `Draft.adHocMealCount`, so
the header can say "3 meals with no recipe".

**Step 2 — portions and scale, per dish.**
`MealScaling.scaling(for: mealRecipe, recipe: resolveRecipe(mealRecipe.recipeID)?.recipe, defaultDinerCount: options.defaultDinerCount)`
— note the `?.recipe` unwrap: the builder's resolver hands back a `ResolvedRecipe?` and
`MealScaling` takes a `Recipe?` (§4.1).

```text
portions = Σ over meal.attendance where consumesPortion of effectivePortion
         + guestCount × guestPortion                    // counted, never named
         + plannedLeftoverServings                      // note .leftoversIncluded
```

- `mealRecipe.scaleOverride != nil` wins outright → `scale = override`, note `.overridden`.
  Skip to the batch snap.
- `portions == 0` → `portions = Rational(options.defaultDinerCount)`, note `.noAttendance`. A
  meal with nobody assigned must **neither** silently buy nothing **nor** silently buy for
  four without saying so; the note becomes a badge on every line it touches.
- `recipe == nil` (a `recipeID` that no longer resolves) → `scale = 1`, note `.unknownYield`,
  and a `.missingRecipe` diagnostic. The meal still reports its title snapshot, so the list
  header can say "1 recipe in this range is no longer in the app" rather than quietly
  shopping for less (§0.2).
- `scale = portions / recipe.servings`.
  **`servings` is the divisor, never `yieldAmount`.** The fixture's yield is "12 crostini
  (serves 4)": dividing by 12 gives `4/12 = 1/3` and the first shopping list he generates
  buys one third of every ingredient, with no zero-yield warning because the yield is not
  zero. `Recipe.servings` is guaranteed positive by its accessor.
- Batch snap: `if let step = recipe.batchGranularity.step { scale = scale.ceiling(toMultipleOf: step) }`,
  note `.snappedToBatch` when it moved. You cannot bake 1.4 loaves.
- `description = "×\(scale.mixedDescription) — \(portions.mixedDescription) eaters, recipe serves \(servings.mixedDescription)"`.

All of `portions`, `servings` and `scale` are exact `Rational`s built from integer
numerator/denominator pairs. **Nothing is laundered through a `Double`.** Two full portions, a
half portion and three full-portion guests against a 4-serving recipe is exactly
`(11/2)/4 = 11/8`.

**Step 3 — flatten the recipe graph.** `RecipeGraph.flatten` walks the RESOLVED recipe's
`components` in array order, then each component's `lines` in array order — no `sortIndex`
reads, because content arrays are already ordered (§2.1).

`flatten` takes a `ResolvedRecipe`, and `recipe.components` / `recipe.id` below are the
**forwarding accessors declared on `ResolvedRecipe` in §3.10** — `recipe.recipe.components`
and `recipe.recipe.id` spelled once, in one place, rather than at every call site. Where a
function takes a bundled `Recipe` instead (`childScale`, `MealScaling`), the `.recipe`
unwrap is written out at the call, below.

- `component.sourceRecipeID != nil` → `resolve(id)`; on success recurse at
  `scale * component.sourceScale`, `componentPath + [component.title]`,
  `visited.union([recipe.id])`, `depth + 1`. A sub-recipe-as-component is part of the dish by
  definition, so it is always expanded.
- `resolve(id) == nil` → `.missingRecipe` diagnostic and contribute nothing, rather than
  silently contributing nothing.
- `component.isReference` with lines present but no resolvable source →
  `.orphanedComponentReference`.
- `line.subRecipeID != nil` → expand only if `line.lineID ∈ options.expandedLineIDs` or
  `line.subRecipePolicy == .expandToIngredients`. When expanding, the child scale is
  `RecipeGraph.childScale(for: line, subRecipe: sub.recipe)` — where
  `let sub = resolve(id)` is a `ResolvedRecipe`, so `.recipe` unwraps it to the bundled
  value the signature takes.

  **The body is written against its own parameter, `subRecipe`.** `sub` is a local of the
  CALLER and is not in scope inside the function, and `ResolvedRecipe` forwards only `id`,
  `components`, `steps`, `title`, `servings` and `batchGranularity` (§3.10) — no yield — so
  `sub.yieldAmount` would not resolve either way. No yield forwarder is added to §3.10: a
  yield is bundled content that no override can touch (§4.1), which is exactly why
  `childScale` takes the `Recipe`.

  ```text
  guard let q = line.quantity, let yieldAmount = subRecipe.yieldAmount else { return nil }
  // Not a `guard let`: `resolve` returns nil for a noun it does not know, and
  // `countUnit(noun:)` MINTS one for the open set and never fails (§3.3), so the
  // coalesced expression is non-optional. A guard that can never fire reads as a check
  // that is happening when none is.
  let yieldUnit = UnitCatalog.resolve(subRecipe.yieldUnitLabel)
               ?? UnitCatalog.countUnit(noun: subRecipe.yieldUnitLabel)
  let yieldBase = yieldAmount * yieldUnit.baseFactor
  guard q.dimensionKey == yieldUnit.dimensionKey, yieldBase != .zero else { return nil }
  return q.base / yieldBase
  ```

  **This is dimensionally sound and the naive version is not.** "2 cups chicken stock" against
  a recipe yielding "2 quarts" is `96 tsp / 384 tsp = 1/4` of a batch. Dividing a volume by a
  SERVING COUNT gives `473.2 / 4 ≈ 118`, so the flattener shops for 118 batches of stock — and
  because it happens inside the recursion, the error compounds at every level. `nil` means **do
  not expand**: the line stays an ordinary buy-it line flagged `.unknownYield`, with a
  `.subRecipeNotExpandable` diagnostic naming the reason. Guessing is never an option here.

- ordinary line → the EFFECTIVE quantity (the override if `ResolvedRecipe` has one, otherwise
  the bundled one), `scaled(by: line.scalingRule == .fixed ? .one : scale)`. A line whose
  quantity came from an override sets `wasTweaked`, which becomes `LineFlag.tweaked` on the
  shopping line — so a number that differs from what the printed recipe says is never a
  mystery.
- `line.quantity == nil` → passes through unscaled with its `unmeasuredNote`. "Pinch flaky
  salt" reaches the list as a presence item: never `0`, never dropped, never aggregated into
  "2 pinches".
- `line.excludeFromShopping` → dropped always. `line.isOptional && !includeOptionalLines` →
  dropped.
- **Cycle guard**: `visited.contains(recipe.id)` → `.cycle` diagnostic, return `[]`.
  `depth > options.maxExpansionDepth` → `.depthExceeded`, return `[]`. Stock referencing stock
  referencing stock is not hypothetical in a library that grows for ten years, and the failure
  without this is a hang while he is holding a phone in a grocery store.

**Step 4 — resolve and bucket.** `resolveItem(line.catalogName, line.displayName)` returns the
`FoodItem` if one exists or can be minted from a catalogue template (§0.3), and
`identity = item.map { .cataloged($0.id) } ?? .freeText(NameNormalizer.matchKey(displayName))`.

**Group the LINES by `identity` alone — never by `MergeKey`.** One line per `FoodItem` per
list (§1, §2.25), so every contribution to that item, in every dimension it was asked for,
goes into ONE call to `QuantityMath.sum`, which partitions by `dimensionKey` internally.
`MergeKey` is the key of those buckets inside the line and of nothing else (§3.7).

Putting `dimensionKey` in the line key instead splits "1 cup flour + 200 g flour" into two
lines, makes `DraftLine.requested: [QuantitySubtotal]` plural for nothing, contradicts step
5's "one per dimension, N per line", and hands `sum` a group that is single-dimension by
construction — so `collapseAcrossDimensions`, which returns early unless a volume AND a mass
bucket are both present, can never fire on the requested side, and §4.3(b)'s flour case
cannot happen. It is the same defect `bridgeHave` fixed on the `have` side.

Resolved lines bucket by the SURVIVOR `FoodItem.id` — `FoodItemResolver.reconcile` has already
run, so aliases have collapsed. Unresolved lines each get their own line with
`status = .unresolvedItem` and an inline "match to…" affordance, so the list is usable the day
a messy recipe lands.

Lines whose `quantity == nil` bypass bucketing entirely: they collapse to one line per item
with every provenance attached and **no arithmetic at all**. "Salt to taste" across six
recipes is still "salt, to taste".

**Step 5 — sum exactly within each bucket.** `QuantityMath.sum(_:using:system:)`: partition by
`dimensionKey`, add exact `Rational` base values, then the one collapse pass —
`collapseAcrossDimensions` (volume↔mass via `gramsPerCup`).

**Count nouns are not collapsed into one another.** Each noun is its own bucket and stays
one, so "3 cloves + 1 head" is two subtotals on one line and the fixture's baguette line
stays `count:slice = 12`. Rewriting a count noun into a *purchase* noun — twelve slices into
one loaf — is purchase-unit rounding, which was added here on initiative, failed review
twice, and is cut; read the section in `CLAUDE.md` before re-adding it.

**`.converted` is set here, by the builder, and the rule is explicit so it has a writer:**
after `sum` returns, `flags.insert(.converted)` **if any surviving subtotal has a non-empty
`conversionNote`.** `collapseAcrossDimensions` returns `[QuantitySubtotal]` with no flag
channel, by design — the note rides with the specific number that moved, which is the whole
reason subtotals are rows — so the derivation lives at the one call site that sees the
result. `QuantityMath.subtract` applies the same rule to the `have` side itself, because it
is the function that does that bridging (§3.6).

Surviving buckets become `requested` subtotals, one per dimension, N per line. Two or more
irreducible → `flags.insert(.needsBridge)`, and **both numbers are rendered on one line** with
an inline "these are the same — 1 cup = ___ g" affordance that writes `gramsPerCup` back onto
the `FoodItem`. One tap, once, forever: after a few months the dozen ingredients he genuinely
measures both ways are all populated and the issue disappears. The app learns, which is the
right shape for a ten-year project.

Note that the catalogue already ships `gramsPerCup` for **108 of its 668** ingredients, so
most of those taps never happen at all — which is the clearest single payoff of treating the
catalogue as content rather than asking him to populate it (§0.3). Both numbers are read off
`ingredients.json` and will move when the catalogue is rebuilt; `test_catalogue.py` prints
them, so the figures here are checkable rather than remembered.

**Step 6 — subtract inventory.** `options.subtractInventory` →
`inventoryLevel(item, options)`, which returns **both the subtotals and the flags it
raised**, because the filters below need the dates and the options and the flags need a
writer (§4.1). `InventoryLedger.level(of:in:includeExpired:asOf:graceEnd:)` — the spelling
§1 and §5.4 both declare, including the `graceEnd:` label that carries the window the third
exclusion below is phrased in — implements it by summing the item's **transactions** (not its
lots), excluding:

- rows whose `resolutionState != .applied` or `hasDelta == false`;
- rows whose **lot** has `expiresAt < options.now`, unless `countExpiredAsAvailable` → it
  returns `.expiredStockIgnored`;
- rows whose **lot** expires before `range.end + expiringGraceDays` → it returns
  `.expiringBeforeNeed`.

**A transaction with `lot == nil` is never expiry-filtered and always counts.** This is the
reconciliation between decision 8 — `level(of:)` sums transactions, and an orphan still
contributes through the "unassigned lot" bucket — and an exclusion rule phrased in terms of
lots. An orphan has no `expiresAt` to judge, and the alternative readings are both wrong:
dropping it understates stock permanently with nothing on screen to explain the gap, and
inventing an expiry date for it is a guess inside a number he shops by. So the filter is a
property of the LOT, orphans have no lot, and orphans count. `InventorySnapshotPrintPage`'s
closing "unassigned" block is the same decision on paper (§7.2).

`level` then runs the requested side's own machinery on what it found —
`QuantityMath.sum(_:using: item)`, same item, same collapse pass — so both sides
land on the same `dimensionKey`s wherever they can. Without that the two sides can be
summed into keys that never meet even when a bridge exists.

Then `QuantityMath.subtract(requested:have:item:)`, with **both sides clamped at zero**,
`bridgeHave` run first so a 4 oz butter lot actually covers a 2 tbsp requirement at
`gramsPerCup: 227`, and the cross-dimension rule applied only to what survives that attempt:
stock that still has nowhere to go → `needed = requested` for that bucket (assume nothing is
on hand) and `.needsBridge`. **A known density never raises `.needsBridge`.**

Status, from `subtract`'s return and the flags the line has accumulated. **The four rules are
evaluated in this order and the first that matches wins**, so a line carrying two facts is
never two statuses:

- `needed == 0` → `status = .haveEnough`, `isCovered = true`. Nothing left to buy outranks
  everything below, whatever flags the line carries: a covered line is not an action.
- `flags.contains(.needsBridge)` → **`status = .needsBridge`**, which **outranks
  `.partiallyHave` and `.needed`**, because it is the one state a single tap fixes. The flag
  has two writers and either sets the status: step 5, when two or more REQUESTED buckets are
  irreducible (§4.3(b)'s flour), and `QuantityMath.subtract`, when stock survives
  `bridgeHave` in a dimension the requirement does not use. Without this rule nothing in the
  document ever wrote `.needsBridge` into `statusRaw`, so `ShoppingList.needsAttention`
  (§2.23) — which filters on exactly `.needsBridge` and `.unresolvedItem` to fill the pinned
  "Needs attention" block — could never contain a bridge line, and §4.3(b)'s
  `status = .needsBridge` was unreachable. `.unresolvedItem` is set in step 4 and is not
  revisited here; where both would apply it wins, because an unmatched item has no density
  to fill in.
- `needed != 0 && didReduce` → **`status = .partiallyHave`**. Some bucket was genuinely
  reduced in a matching dimension and the line is still half-covered. Without this rule
  nothing in this document ever wrote `.partiallyHave`, the case was declared on
  `ShoppingListLine.statusRaw` and in `LineStatus`, and `ShoppingListDetailView`'s
  "Already have" / "Needs attention" partition silently lost the middle.
- `needed != 0 && !didReduce` → `status = .needed`.

A covered line is **kept and collapsed** under "Already have (6)", never removed: inventory
is sometimes wrong, a silently absent line is indistinguishable from a bug, and he needs to
see the app's belief about his fridge before he will trust it. There is no option to remove
it (§4.1). `isRunningLow` items count as zero on hand and are flagged "you said this was
low".

**Step 7 — staples, aggregated then diverted.** `item.trackingMode == .staple` and not
(`includeStaples || isRunningLow || par-level shortfall`) → `status = .staple`,
`flags.insert(.assumedOnHand)`, routed to the collapsed "Staples (not checked)" footer with a
one-tap "add anyway".

**The aggregation runs first and the summed quantity is shown in the footer.** The fixture's
kosher salt — 1 tsp in the steak group plus 1/4 tsp in the spinach group — is the document's
own proof case for intra-recipe aggregation, and diverting salt to a quantity-less bucket
means the arithmetic never runs on it, leaving butter as the only surviving proof.
`KitchenAidTests/ShoppingListBuilderTests` asserts `1 1/4 tsp` **through the staple path**.

So a diverted staple **keeps its `requested` subtotals** — that `1 1/4 tsp` — and has
**`toBuy` and `purchase` emptied**. A buy quantity printed beside "assumed on hand" is the
footer contradicting itself, and `purchase` is what `InventoryLedger.receive` posts, so a
non-empty one would restock something that was never bought.

Which ingredients are staples comes from the catalogue's `staple` flag (§0.3) — salt, pepper,
every oil, every vinegar, every spice — copied onto the `FoodItem` at creation and overridable
per item afterwards.

**Step 8 — par levels.** For `item.hasParLevel` whose rollup is below `parLevel`: **if a line
for that `ItemIdentity` already exists, append the `.parLevel` source to it** and flag it
`.parLevel`; only when no line exists is one created, with a single `.parLevel` source and no
meal. This is how a staple reaches the list by a rule rather than only when a Bool is flipped
by hand.

The de-duplication is not tidiness. Step 7 deliberately leaves a staple with a par-level
shortfall on the list as an ordinary line rather than diverting it, and kosher salt — the
fixture's own staple — is the likeliest item in the kitchen to carry a par level, so an
unconditional step 8 gives one `FoodItem` two lines on one list. It also breaks step 11,
which matches on `(ItemIdentity, dimensionKey set)`: two lines sharing an identity make the
check-state carry-over ambiguous, and a line he checked off comes back.

**Step 9 — section and sort.** The `purchase` subtotals are written here, and in v1 each one
is a **copy of the matching `toBuy` row**: with purchase-unit rounding cut (`CLAUDE.md`) there
is no pack to round toward, so the list shops by the exact need and says so. A staple
diverted in step 7 has an empty `toBuy`, so this copy correctly leaves its `purchase` empty
as well. The role still
gets its own stored rows, because `purchase` is what `InventoryLedger.receive` posts — what
came home, not what the recipe asked for — and because that is where a rounded pack quantity
lands if rounding is ever built, which makes it a new writer rather than a migration.

Group by `item.defaultSection`, sections ordered by `sortIndex` (his store's actual geography,
drag-reorderable, and a synced **row** rather than an unsynced `UserDefaults` value).
Alphabetical within a section.

**`Draft.sectionOrder` is written here, and this is its only writer**: the distinct section
names of `lines`, ordered by the `sectionSortIndex` snapshotted beside them, with "Unsorted"
last. The generation sheet's "32 items across 6 sections" reads it instead of re-deriving an
order the lines already carry.

A `FoodItem` minted from a catalogue template already has its
section, because the template's `aisle` matched a seeded `StoreSection` (§8) — so "Unsorted"
is now rare rather than the default state of a new kitchen. Unsectioned lines still land in a
trailing "Unsorted" group with a one-tap assign that writes `defaultSection`. Section name and
`sortIndex` are **snapshotted onto each line**, so reordering aisles in March does not
scramble a list printed in November.

**Step 10 — persist.** `ShoppingListStore.materialize(draft:into:existing:)` writes the
`ShoppingList`, its lines, their subtotal rows and their source rows, freezing the options
onto the list. The previous list is never mutated — he may already have shopped off it.
"Merge into current list" is an explicit action.

**Step 11 — regenerate, preserving check-state.** Lines are matched on
`(ItemIdentity, dimensionKey set)`; `isChecked`, `checkedAt`, `noteToSelf`,
`destinationLocation` and `priceCents` carry across. `isManual` lines always survive (paper
towels are in no recipe). The result is shown as a **diff sheet**: "3 new, 1 no longer needed,
2 changed quantity." Silently resurrecting a checked-off line is the bug this prevents.

**The trip home.** `InventoryLedger.receive(list:)` walks `isChecked` lines, creates a
`StockLot` at `destinationLocation ?? item.defaultLocation` with `original` = the **purchase**
quantity, sets `expiresAt` from the location's `defaultShelfLifeDays`, and appends a
`.purchase` `InventoryTransaction` carrying `priceCents`. Cost-per-meal reporting falls out of
this later with no schema change.

**And out again.** `CookingService.finish(...)` flattens the resolved recipe at the scale
actually cooked, calls `InventoryLedger.lotsForDepletion` per item, writes `.cookDepletion`
transactions stamped with `recipeIDSnapshot`, sets `RecipeTweak.lastMadeAt`, and sets the meal
`.cooked`. **There is no log row** — the depletion transactions and the last-made date are the
whole record (§0.5). A depletion needing an absent density bridge is **written** with
`hasDelta == false` and `resolutionState == .pendingBridge`, landing in the "Unresolved
depletions" inbox. The ledger never silently guesses and never silently skips.

### 4.3 Worked examples

**(a) `2 tbsp + 1/4 cup` of the same item — the test written first.**

| | |
|---|---|
| `2 tbsp` | `2 × 3 = 6` tsp |
| `1/4 cup` | `1/4 × 48 = 12` tsp |
| sum | **`18` tsp**, exactly |
| hint | tbsp and cup each used by one line → tie → **finer wins** → `tbsp` |
| rule (a) | `18 / 3 = 6`, and `6 ∈ [1/4, 64)` → **`6 tbsp`** |

Never `5.9999`, and never `3/8 cup`. It is also never **`3 fl oz`**, even though 18 tsp is
exactly that, because `floz.isHouseholdCommon == false` keeps it out of `displayCandidates`
entirely. If every source line *had* said cups, the hint would be `cup`, `18/48 = 1/4` is
still `>= 1/4`, and the answer would be `1/4 cup` — which is correct, because that is the unit
he writes in.

With no hint at all, rule (b) walks `[quart 192, pint 96, cup 48, tbsp 3, tsp 1]`:
quart/pint/cup all give `< 1`, tbsp gives `6` with denominator `1` → `6 tbsp`. Same answer by
a different road.

**The fixture's own cases, which come out of the same code:**

| Ingredient | Lines | Base | Result |
|---|---|---|---|
| butter | `1 tbsp` (crostini and steak) + `1 tbsp` (creamed spinach) | `3 + 3 = 6` tsp | **`2 tbsp`** |
| kosher salt | `1 tsp` (steak) + `1/4 tsp` (spinach) | `1 + 1/4 = 5/4` tsp | **`1¼ tsp`**, shown in the staples footer |

One recipe, planned once, already produces one butter line and one salt line. Any
implementation that only de-duplicates *across* recipes fails here. Note that both lines come
from ONE recipe file with two components — the aggregation runs across components inside a
recipe, not only across recipes in the plan.

**(b) `1 cup flour + 200 g flour`.**

*Without a density* (`hasDensity == false`) — the honest answer:

```text
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

It looks slightly unfinished and it is also the truth. In practice this exact case does not
arise for flour, because the shipped catalogue already carries `gramsPerCup: 120` for
all-purpose flour — the mechanism exists for the ingredients the catalogue deliberately leaves
null, which are the ones whose density is genuinely unsettled.

*With `gramsPerCup = 120`:*

```text
gramsPerTsp = 120/48 = 5/2
total       = 200 + 48 × 5/2 = 200 + 120 = 320 g
display     -> "320 g"
conversionNote (on THAT subtotal): "1 cup counted as 120 g at 120 g per cup"
```

One subtotal, `flags = [.converted]`. The conversion note rides with the **specific number
that was converted**, which a line-level `secondaryText` string cannot express.

*Now subtract inventory.* Suppose one unopened 1 lb bag:

- **With** the density: `have = 453.6 g`, `toBuy = max(0, 320 - 453.6) = 0` →
  `status = .haveEnough`, collapsed under "Already have".
- **Without** it: the mass bucket covers (`200 - 453.6 → 0`), but the **volume** bucket has no
  matching stock dimension and no bridge, so `needed = 1 cup` and `.needsBridge` is flagged.
  Honest, mildly annoying, and fixed forever by one tap. Buying a duplicate bag of flour is a
  far cheaper error than arriving at dinner without it.

**(b′) The fixture's butter against a 4 oz lot — the case `bridgeHave` exists for.**

Requirement: `1 tbsp + 1 tbsp = 6 tsp`, one `volume` bucket. Stock: one 4 oz lot, one `mass`
bucket at `4 × 567/20 = 113.4 g`. Butter's catalogue `gramsPerCup` is **227**.

```text
requestedKeys = {"volume"}
have          = [mass: 113.4 g]              -> not in requestedKeys
bridgeHave    : gramsPerTsp = 227/48
                113.4 / (227/48) = 5443.2/227 ≈ 23.98 tsp   -> volume bucket
toBuy         = max(0, 6 - 23.98) = 0        -> .haveEnough, collapsed
flags         = [.converted]                  NOT [.needsBridge]
```

Before the bridging step existed this line bought 2 tbsp of butter he already had **and**
warned that it needed a weight per cup — on an item whose weight per cup ships in the
catalogue. Both halves were wrong, and the second one is worse, because a bridge warning on
a bridged item teaches him to ignore bridge warnings.

**(c) The 240 mL carton, which the conversion table exists for.**

`3 tbsp heavy cream = 9 tsp`. A 240 mL carton in the fridge is `240 × 1/5 = 48 tsp`.
`toBuy = max(0, 9 - 48) = 0`. Covered, exactly. Had the requirement been `1 cup`, it would be
`48 - 48 = 0` — also exactly.

With SI-exact factors (`1 cup = 236.588 mL`) the carton is `236.588…` worth of teaspoons, the
subtraction leaves a `3.41 mL` residue, nothing in `max(0, required - onHand)` has an epsilon,
and the shopping list grows a spurious **"1 tsp heavy cream"** line. That single line is why
this spec uses culinary factors.

**(d) Garlic across two meals, and the fixture's baguette — the count-noun partition, and
what it does NOT do.**

`2 cloves` (steak group) + `1 clove` (another meal) + `1 head` (a third):

- Buckets: `count:clove = 3`, `count:head = 1`. **Never summed to 4** — the noun is in the
  dimension key, and that is the whole job of partitioning count by noun.
- They are also **never folded into each other**. Nothing converts a clove into a head, so
  the line carries two subtotals and reads *"3 cloves + 1 head"*. That is more useful to a
  shopper than "3 cloves + 50 g", and it is honest about what the app knows.

*And the pantry case, which is the one the fixture actually produces.* The steak group wants
`2 clove` and there is `1 clove` on hand:

```text
requested -> [count:clove = 2]
have      -> [count:clove = 1]           same key, no bridge needed
subtract  -> 2 - 1 = 1, didReduce = true
status    -> .partiallyHave
line      -> "1 clove"
```

**The baguette ships as it is written.** The fixture gives exactly one count bucket and
nothing moves it:

```text
sum                      -> [count:slice = 12]
collapseAcrossDimensions -> no mass bucket, no volume bucket -> unchanged
line                     -> "12 slices baguette"
```

**Purchase-unit rounding — "1 baguette", or "need 1 3/10 heads, buy 2 heads" — is deferred**,
and the section in `CLAUDE.md` is the one to read before re-adding it. It was added here on
initiative, failed review twice, and was cut because more than half the remaining cost of
making this spec implementable was being spent on it. The design mockup already said "12
slices baguette", so the list and the mockup now agree.

The catalogue lists `baguette` in Bakery with `dimension: count` and **`unit: loaf`**. The
recipe line's noun is `slice`, so the two are different buckets and the line renders in the
noun the recipe used — which is the behaviour the partition specifies, not a defect in it.

**(e) Why Tuesday's leftovers buy nothing.**

Sunday dinner: ragù, 4 portions attending, `plannedLeftoverServings = 2` → `portions = 6`,
`scale = 6/4 = 3/2`, note `.leftoversIncluded`. Tuesday: a `PlannedMeal` with
`kind == .leftovers` and `leftoversFrom == Sunday`. `contributesToShopping` is `false`
**by kind**, so it is dropped in step 1 — and it is still rendered on the calendar as planned
leftovers with a link to its source, because it was never marked skipped.

Sunday's `servingsCooked` is drawn down by its `leftoverMeals`, which is what lets the week
brief say *"you are a portion short Tuesday"*. The mutually exclusive alternative is
`.leftoversOnly` attendance **at Sunday**, for "he will take a plate to work" with no calendar
entry; the editor refuses both for the same person against the same source, because allowing
both double-counts a portion.

**(f) A party, counted and not named.**

Saturday dinner, the fixture, 2 residents at full portion and **`guestCount = 6`** at full
portion → `portions = 8`, `servings = 4`, `scale = 2`. The display yield reads **24
crostini**, butter totals `4 tbsp`, and nobody has joined the roster. Six guests at half
portion would be one stepper and `portions = 5` → `scale = 5/4` → `15 crostini`.

---

## 5. Service layer

Pure `enum` namespaces (`RecipeGraph`, `MealScaling`, `ShoppingListBuilder`, `QuantityMath`,
`PDFPaginator`, `CalendarKey`, `NameNormalizer`, `MealPlanStats`, `WeekBriefBuilder`,
`KitchenAidSeed`, `KitchenAidMaintenance`) take what the caller has and return a value. They
are covered in §3, §4, §7.1 and §8. The last two are on this list rather than among the
`@Observable` classes because every call site spells them statically —
`KitchenAidSeed.applyIfNeeded(in:catalog:)`, `KitchenAidMaintenance.rebuildLotCaches(in:)` —
and neither holds anything between calls. The `@Observable` classes below are held as
`@State` on `KitchenAidApp` and injected with `.environment(...)`, CFAL3's pattern.

**§5.1–§5.4 are `text` API sketches**, per the fence convention at the top: the member
lists and their doc comments are the contract, the bodies are the prose beside them. The
rest of §5 is a table for the same reason.

### 5.1 `RecipeLoader` and `IngredientCatalog` — the content side

```text
@Observable
final class RecipeLoader {
    /// Decoded ONCE at launch from `Bundle.main.urls(forResourcesWithExtension: "json",
    /// subdirectory: "Recipes")`, keyed by `Recipe.id`. Immutable thereafter.
    ///
    /// **The only place a `Recipe` comes from.** No view decodes JSON, and nothing else holds
    /// a `Recipe` it did not get from here, so "which version of this recipe am I looking at"
    /// has exactly one answer.
    private(set) var byID: [String: Recipe] = [:]
    private(set) var diagnostics: [ContentDiagnostic] = []

    func load()
    func recipe(id: String) -> Recipe?
    /// Non-archived, title-sorted. What the library shows.
    var all: [Recipe] { get }
    /// Including archived. What a `recipeID` resolves against.
    var allIncludingArchived: [Recipe] { get }
    var allTags: [RecipeTag] { get }
    /// **The dangling-id check** (§0.2). True when a stored `recipeID` resolves to nothing.
    func isMissing(_ recipeID: String) -> Bool
    /// "Where do I use this chimichurri", computed rather than stored — the panel's
    /// `usedAsComponentIn` / `usedAsIngredientIn` relationships cannot exist now, and over a
    /// few hundred bundled recipes this is a dictionary walk, not a store scan.
    func usages(of recipeID: String) -> [Recipe]
}
```

Loading is a per-file `do/catch`: a file that fails to decode produces a
`ContentDiagnostic(.decodeFailed)` and is skipped. **One malformed file costs one recipe, not
the launch.** Two files declaring the same `id` produce `.duplicateID` and the first wins
deterministically (sorted by file name), because a non-deterministic winner means two devices
show different recipes under one id. After loading, one pass checks that every
`referencedRecipeIDs` entry resolves and that no recipe has two lines sharing a `lineID`
(`.duplicateLineID` — an override would otherwise apply to both).

```text
@Observable
final class IngredientCatalog {
    /// `KitchenAid/Resources/ingredients.json`, decoded once (§0.3). NOT copied into
    /// SwiftData.
    private(set) var byName: [String: CatalogEntry] = [:]
    private(set) var byMatchKey: [String: CatalogEntry] = [:]
    private(set) var byAliasKey: [String: CatalogEntry] = [:]
    private(set) var diagnostics: [ContentDiagnostic] = []

    func load()
    func entry(named name: String) -> CatalogEntry?
    /// Name first, then alias. Both on `matchKey`, so "Green Onions" finds `scallion`.
    func entry(matching raw: String) -> CatalogEntry?
    var all: [CatalogEntry] { get }

    /// **THE WALK ORDER, read straight from the JSON's `aisleOrder`** (§0.3). Produce,
    /// Bakery, Butcher, Seafood, Dairy, Dry goods, Canned, Condiments, Spices, Baking,
    /// Nuts, Beverages, Frozen.
    ///
    /// The build script owns this list, validates that it names every aisle and invents
    /// none, and emits it. Nothing here and nothing in `KitchenAidSeed` keeps a second
    /// copy — a hand-copied order drifts from the script's with no test in this repo able
    /// to catch it, which is exactly what happened before.
    var aisleOrder: [String] { get }

    /// Every distinct `aisle` actually PRESENT in `items`, which is a different question
    /// from the walk order and is why both exist. Checked against the seeded
    /// `StoreSection` names at launch, and against `aisleOrder`: an aisle with no section,
    /// or an item in an aisle `aisleOrder` does not name, produces `.unknownAisle` rather
    /// than silently sending everything in it to "Unsorted".
    var aisleNames: [String] { get }
}
```

The build script already guarantees no name or alias collides, so `byAliasKey` cannot be
ambiguous — and if a future catalogue edit breaks that, `test_catalogue.py` fails before the
JSON is committed. That check is in Python, runs in a cloud session, and is the reason this
service can be a plain dictionary rather than a disambiguation UI.

### 5.2 `TweakStore` — the overlay side

```text
@Observable
final class TweakStore {
    init(container: ModelContainer, loader: RecipeLoader)

    /// Fetch-or-create. `fetchLimit` 1 on `#Predicate { $0.recipeID == id }`, ordered by
    /// `createdAt` then `id.uuidString` so two devices converge on one survivor without
    /// coordination (the same deterministic rule as `FoodItemResolver`, §5.3).
    func tweak(for recipeID: String, in context: ModelContext) -> RecipeTweak
    /// Read-only paths must not create rows just by looking.
    func tweakIfExists(for recipeID: String) -> RecipeTweak?

    /// **The function every view calls.** Content + overlay, applied to a COPY.
    func effectiveRecipe(id: String) -> ResolvedRecipe?

    func setQuantity(_ quantity: Quantity?, forLine lineID: String, in recipeID: String)
    func setPreparation(_ text: String, forLine lineID: String, in recipeID: String)
    func setStep(title: String?, body: String?, minMinutes: Int?, maxMinutes: Int?,
                 forStep stepID: String, in recipeID: String)
    func setNotes(_ text: String, for recipeID: String)
    func setFavorite(_ value: Bool, for recipeID: String)
    /// The ONLY writer of cooking history.
    func markMade(_ recipeID: String, at date: Date = .now)
    func clearIngredientOverride(lineID: String, in recipeID: String)
    func clearStepOverride(stepID: String, in recipeID: String)
    /// Drops a `RecipeTweak` once `isEmpty`, so "undo my tweak" leaves no residue.
    func pruneIfEmpty(_ tweak: RecipeTweak, in context: ModelContext)
}
```

`effectiveRecipe` is the one place content and overlay meet, and it obeys three rules:

1. **It never mutates `RecipeLoader.byID`.** `Recipe` is a value type, so applying an override
   is a copy — which is the whole reason content is a struct and not a class. A class would
   make "this screen scaled the recipe" visible on every other screen.
2. **An override whose key no longer exists LAPSES and is reported**, not discarded. It lands
   in `ResolvedRecipe.lapsedOverrides` with its snapshot, `TweakSheet` offers to remove it, and
   nothing happens automatically. A tweak that vanishes because a file was revised is exactly
   the kind of silent loss this architecture is built to avoid.
3. **An override never changes an ingredient's identity.** There is no name override and no
   add-a-line: `CLAUDE.md` says notes and tweaks only, and changing what an ingredient IS
   would desynchronise the shopping list from the printed recipe with nothing to reconcile
   them.

### 5.3 `FoodItemResolver`

```text
@Observable
final class FoodItemResolver {
    init(catalog: IngredientCatalog)

    /// The ONLY place a FoodItem is created. Nothing else may call
    /// `context.insert(FoodItem(...))` — not the shopping builder's caller, not the inventory
    /// editor, not a manual shopping line. This is the discipline that substitutes for the
    /// `@Attribute(.unique)` CloudKit forbids.
    func findOrCreate(name: String, createIfMissing: Bool = true, in context: ModelContext) throws -> FoodItem?

    /// Minted FROM A TEMPLATE when the name resolves to a catalogue entry: `dimension`,
    /// `staple`, the density and the aisle's `StoreSection` are copied, and `catalogName` is
    /// stamped. Everything afterwards is his to override (§0.3).
    ///
    /// The density is TWO fields and both are written —
    /// `hasDensity = (entry.gramsPerCup != nil)` as well as the numerator/denominator pair.
    /// `FoodItem.gramsPerCup` returns nil without the Bool (§2.12), so writing only the
    /// numbers leaves §4.3(b′)'s bridge unable to fire on an item whose density ships in the
    /// catalogue.
    ///
    /// The template's `unit` is NOT copied: `FoodItem` has no unit field, and landing it in
    /// `parLevelUnitCode` would give that field a second meaning. A default unit is read
    /// live off the template — `catalog.entry(named: item.catalogName)?.defaultUnit` (§2.6)
    /// — which is what `QuickAddStockView` shows.
    func findOrCreate(fromCatalog entry: CatalogEntry, in context: ModelContext) throws -> FoodItem

    func addAlias(_ text: String, to item: FoodItem, in context: ModelContext)
    /// Rebuilds `aliasBlob` from the rows. The rows are truth; the blob is the
    /// predicate-queryable cache.
    func reindex(_ item: FoodItem)

    @discardableResult
    func reconcile(in context: ModelContext) throws -> [MergeRecord]
    func merge(_ losers: [FoodItem], into survivor: FoodItem, in context: ModelContext) throws -> MergeRecord

    /// Refuses an item with lots or transactions, so the caller offers "merge into…" instead.
    /// The SCHEMA already guarantees no history is destroyed (`.nullify`); this is the
    /// courteous layer on top.
    func canDelete(_ item: FoodItem) -> Result<Void, DeleteRefusal>
}
```

**Lookup order**, and it is four steps rather than the panel's two, because the catalogue is
now part of it:

1. `#Predicate<FoodItem> { $0.matchKey == key }`, `fetchLimit = 1`.
2. His own aliases — and **the needle is built before the predicate, never inside it**:

   ```swift
   let needle = "|" + key + "|"
   let descriptor = FetchDescriptor<FoodItem>(
       predicate: #Predicate { $0.aliasBlob.contains(needle) }
   )
   ```

   `#Predicate { $0.aliasBlob.contains("|\(key)|") }` does **not** compile. The macro has
   to translate the closure body into a `PredicateExpression` tree and
   `DefaultStringInterpolation` has no representation there, so it fails to expand with
   "the expression could not be converted to a Predicate". A captured `let` is an
   expression the macro CAN represent. **This is a general rule for this codebase**: build
   every predicate operand outside the macro and capture it. `aliasBlob` exists solely so
   this lookup is a predicate rather than a fetch-and-scan of the whole store on every line
   resolution (§2.8, §2.12), so writing it in a form that cannot expand defeats the only
   reason the field is stored. The one place an interpolation-shaped argument is safe is a
   literal, as in `flagsBlob.contains("|needsBridge|")`.
3. `catalog.entry(matching: raw)` → mint from the template.
4. Create an unresolved row, or return nil when `createIfMissing` is false. The line is shown
   with `.unresolvedItem` and a one-tap "match to…".

`matchKey` and `aliasBlob` are **stored** precisely so steps 1 and 2 are predicate-queryable:
a computed property cannot appear in a `#Predicate`, and a stored `[String]` is a blob
predicates cannot see into. Step 3 is an in-memory dictionary hit, because the catalogue is
not in the store.

**The merge survivor is deterministic, and that is a convergence requirement rather than a
preference:**

1. Group all items by `matchKey`, **including every alias key**.
2. For each group of more than one, pick the survivor: **earliest `createdAt`, tie-broken by
   lowest `id.uuidString`.** Never a "best row" heuristic such as most-lots or longest-notes —
   two devices must pick the **same** survivor with no coordination, or the merge ping-pongs
   forever.
3. Repoint every referrer (`lots`, `transactions`, `shoppingLines`), union the alias rows,
   fill the survivor's absent scalars from the losers, reindex, delete the losers.
4. Write a `MergeRecord`, so Settings can report "merged 3 duplicates" instead of mutating his
   data mutely.

Step 3 is why KitchenAid's persistence side uses a real relationship graph where its content
side uses CFAL3's string-id join: merging requires **enumerating referrers**, which with
inverses is **three referrer arrays to repoint (`lots`, `transactions`, `shoppingLines`)
plus one child array to union (`aliases`)** — the same count §0.8
gives — and with `foodItemID: UUID?` is a full-store scan on every launch forever. The content side needs no merge at all, because content is single-sourced in
the bundle — which is exactly why the split is where it is.

### 5.4 `InventoryLedger`

```text
@Observable
final class InventoryLedger {
    /// Holds the container, because `level(of:)` runs on every shopping-list build and every
    /// recipe detail render and therefore needs a context on the hot path. This is the one
    /// service that must state where its context comes from.
    init(container: ModelContainer)

    /// Sums the item's TRANSACTIONS, not its lots. An orphaned transaction (`lot == nil`)
    /// still contributes, into an explicit "unassigned lot" bucket, so a deleted lot cannot
    /// create a divergence that is never attributable. **An orphan is never expiry-filtered
    /// and always counts** — it has no lot, so it has no `expiresAt` to judge, and both
    /// alternatives (drop it, or invent a date for it) are wrong inside a number he shops
    /// by (§4.2 step 6).
    ///
    /// It returns the FLAGS it raised as well as the numbers, because it is the only thing
    /// in the system that can see a lot's `expiresAt`: `.expiredStockIgnored` when a lot
    /// was excluded for being past its date and `includeExpired` is false, and
    /// `.expiringBeforeNeed` when a lot was excluded for dying inside
    /// `graceEnd`. `ShoppingListBuilder` cannot derive either — which is why those two
    /// `LineFlag` cases previously had no writer anywhere in the document.
    ///
    /// The subtotals it returns are `QuantityMath.sum(_:using: item)` output — **the same
    /// item and the same collapse pass the requested side runs**. Without that the
    /// two sides can be summed into keys that never meet even where a bridge exists, and
    /// `subtract` has nothing to match on.
    func level(of item: FoodItem, in location: StorageLocation? = nil,
               includeExpired: Bool = false, asOf: Date = .now,
               graceEnd: Date? = nil) -> (subtotals: [QuantitySubtotal], flags: Set<LineFlag>)

    /// The closure `ShoppingListBuilder` is handed, wired once at the call site:
    /// `{ item, options in ledger.level(of: item,
    ///                                 includeExpired: options.countExpiredAsAvailable,
    ///                                 asOf: options.now,
    ///                                 graceEnd: options.range.end
    ///                                     .addingTimeInterval(TimeInterval(options.expiringGraceDays) * 86_400)) }`

    /// FIFO by `expiresAt` then `acquiredAt`, PREFERRING an already-opened lot (you finish
    /// the open butter before cutting a new stick) and preferring lots whose dimension
    /// matches the request so no bridge is needed.
    func lotsForDepletion(_ item: FoodItem, needed: Quantity) -> [(StockLot, Quantity)]

    func apply(kind: TransactionKind, delta: Quantity?, to item: FoodItem,
               lot: StockLot?, meal: PlannedMeal?, recipeID: String, recipeTitle: String,
               note: String, in context: ModelContext) -> InventoryTransaction

    /// Posts the PURCHASE quantity, not the pre-rounding need. Restocking what the recipe
    /// needed drifts tracked stock monotonically to zero.
    func receive(_ list: ShoppingList, in context: ModelContext) throws

    func recompute(lot: StockLot)
    func rebuildAllCaches(in context: ModelContext) throws

    /// Surfaces cache-versus-ledger divergence rather than hiding it, per lot and per item,
    /// including the unassigned bucket. See `LedgerDivergence` (§3.11).
    func reconcileReport(in context: ModelContext) throws -> [LedgerDivergence]

    func expiringSoon(within days: Int, in context: ModelContext) throws -> [StockLot]
    func pendingBridgeTransactions(in context: ModelContext) throws -> [InventoryTransaction]
    func resolve(_ tx: InventoryTransaction, withDelta: Quantity, in context: ModelContext)
}
```

The `.pendingBridge` inbox, the reconcile screen and the ingredient inbox are three standing
queues for one busy cook, and that is a real cost — once the ledger goes stale,
`subtractInventory` silently produces a wrong shopping list, which is worse than having no
inventory feature. Four mitigations, all required:

1. `StockTrackingMode.staple`, seeded from the catalogue, means he never has to inventory his
   salt — and because the catalogue marks every spice, oil and vinegar a staple, that is the
   bulk of what would otherwise fill the queues, with no setup at all.
2. The shipped `gramsPerCup` table removes most of what would reach the `.pendingBridge` inbox
   before it is ever written.
3. The inbox counts are shown as **badges on the Pantry tab**, not buried in Settings, so they
   are visible without being modal.
4. `KitchenAidMaintenance.rebuildLotCaches` and `FoodItemResolver.reconcile` run on launch and
   on remote-change notifications, so the repairs actually run rather than waiting for him to
   visit a screen he has no reason to open.

### 5.5 The rest

**Two pure namespaces first, written out rather than only named.** §6.1, §6.2 and §9 all
route numbers through `MealPlanStats`, and `WeekBriefView` renders a `Brief`, but neither had
an API anywhere in the document — the §0.9.2 and §0.9.3 failure mode in miniature, so they
get the same treatment `LedgerDivergence` and `CookTimer` got.

```text
// KitchenAid/Services/MealPlanStats.swift
enum MealPlanStats {
    /// What `WeekBriefView`'s first sentence counts.
    struct Coverage: Sendable {
        /// Days in the interval with at least one `.recipe` meal in a shoppable slot.
        let plannedDayCount: Int
        let dayCount: Int
        /// Meals by kind, so "3 takeout" is a read rather than a filter at the view.
        let countsByKind: [MealEntryKind: Int]
        let dinnerCount: Int
    }

    static func coverage(for interval: DateInterval, meals: [PlannedMeal]) -> Coverage
    /// `recipeID` → the days it appears on, for anything appearing more than once.
    static func repeats(in meals: [PlannedMeal]) -> [String: [Int]]
    /// Planned `recipeID`s with no `RecipeTweak.lastMadeAt`. The "1 recipe you have never
    /// made" number, and the Today screen's never-made shelf.
    static func neverMade(from meals: [PlannedMeal], tweaks: [RecipeTweak]) -> [String]
}
```

```text
// KitchenAid/Services/WeekBriefBuilder.swift
enum WeekBriefBuilder {
    /// Exactly the fields §6.2's sentence needs — "14 dinners planned, 3 takeout, 1 recipe
    /// you have never made, 3 things expiring" — plus the two it links to. Declared so the
    /// sentence and the type cannot drift.
    struct Brief: Sendable {
        let interval: DateInterval
        let coverage: MealPlanStats.Coverage
        let dinnersPlanned: Int
        let takeoutCount: Int
        /// Title snapshots, so a dangling `recipeID` still reads (§0.2).
        let neverMadeTitles: [String]
        let expiringSoonCount: Int
        let unresolvedDepletionCount: Int
        let missingRecipeCount: Int
        /// "14 dinners planned, 3 takeout, 1 recipe you have never made, 3 things expiring."
        let sentence: String
    }

    static func brief(for interval: DateInterval, meals: [PlannedMeal],
                      tweaks: [RecipeTweak], expiringLots: [StockLot],
                      pendingBridgeCount: Int, loader: RecipeLoader) -> Brief
}
```

| Service | Responsibilities and public API |
|---|---|
| `MealPlanService` | `meals(in:)`, `mealsByDayKey(in:)`, `meals(onDayKey:)` (what the Today screen reads), `plan(recipeID:title:on:slot:)`, `planEntry(kind:title:on:slot:)`, `move(_:to:slot:index:)`, `duplicate(_:to:)`, `copyWeek(from:to:)`, `makeLeftovers(of:on:slot:servings:)`, `setAttendance(_:for:on:)`, `setGuestCount(_:portion:on:)`, `applyAttendanceDefaults(to:)`. Owns the "exactly one leftovers path" validation. Writes `MealRecipe.recipeTitleSnapshot` from the loader at the moment a dish is added — the one place that snapshot is set. |
| `CookingService` | `begin(recipeID:scale:meal:)`, `finish(session:depleteInventory:note:)`. Sets `RecipeTweak.lastMadeAt`, optionally appends to `RecipeTweak.notes`, drives the depletion path, sets the meal `.cooked`. **It writes no log row and no counter** (§0.5), which is also why it needs no `recomputeCookStats` repair pass — there is no derived count to drift. |
| `CookSession` | View state for the stove: `resolved: ResolvedRecipe`, `scale` (view state, **never** a write — cooking a double batch must not silently rewrite the recipe to serve 8 forever, and with content immutable it structurally cannot), `completedStepIDs: Set<String>`, `timers: [CookTimer]`. |
| `ShoppingListStore` | `materialize(draft:into:existing:)`, `regenerate(_:options:)`, `diff(_:against:)`, `addManualLine(_:to:)`, `drop(meal:from:)` (which uses the live `ShoppingListSource.plannedMeal` edges). |
| `ExportCoordinator` | Render progress, the last PDF `URL` for `ShareLink`, and `sweepTemporaryFiles()` — an **instance** method on the `@Observable` class, called as `exporter.sweepTemporaryFiles()`. It is not static: the sweep sets `lastExportURL = nil` when it deletes the file that URL pointed at, so it has state to touch, and a `ShareLink` still holding a deleted URL is the bug that makes it worth owning. |
| `AppPreferences(defaults:)` | Unit system, plan scope, last build options, default diner count. Reads `UITestMode.defaults`. Deliberately **not** synced — everything that must agree across devices is a row. |
| `KitchenAidSeed` | `applyIfNeeded(in:catalog:)`, `SeedRecord`-gated per key (§8). A static namespace, not an injected service. It takes the catalogue because the store-section walk order is `IngredientCatalog.aisleOrder` and is not copied here. |
| `KitchenAidMaintenance` | `rebuildLotCaches(in:)`, `findDuplicateFoodItems(in:)`, `mergeDuplicateTweaks(in:)`, `forgetMissingRecipeRows(in:loader:)`. Wired to `NSPersistentStoreRemoteChange` as well as a Settings button, because a repair nobody triggers is not a repair. |
| `KitchenAidRouter` | Selected tab (defaulting to `.today`), presented sheets, the cook-mode cover payload. |

### 5.6 `KitchenAid/App/KitchenAidApp.swift`

Structurally CFAL3's `CFAL3App`: the `UITestMode` enum with its `static let` throwaway suite
(including the `-uitesting-preserve-defaults` escape hatch and the comment explaining why it
is a `let` and not a computed property), the `do/catch` `ModelContainer` init with the
in-memory fallback and `storeFailure`, services as `@State` injected via `.environment`, and
`.environment(\.storeUnavailable, storeFailure != nil)` driving the banner.

```swift
let config = ModelConfiguration(
    schema: Schema(KitchenAidSchemaV1.models),
    isStoredInMemoryOnly: UITestMode.isActive,
    // Explicit, and commented, so the day the family wants sync is a one-line diff next to an
    // entitlement rather than an investigation. Everything in the schema already obeys
    // CloudKit's rules — no .unique, every property defaulted, every relationship optional
    // with an explicit single-sided inverse — so flipping this to
    // .private("iCloud.com.brandonkeeny.KitchenAid") is a capability change, not a reshape.
    //
    // Note what sync would NOT cover: bundled recipes and the ingredient catalogue are in the
    // app bundle, not the store, so they arrive with the build and not with the account. That
    // is the deliberate trade in §0.2.
    cloudKitDatabase: .none
)
```

and the launch `.task`, in this order, because each step depends on the one before:

```swift
.task {
    // `exporter`, not `ExportCoordinator` — it is an @Observable instance held as @State
    // alongside the others, and sweeping clears its `lastExportURL` (§5.5).
    exporter.sweepTemporaryFiles()
    catalog.load()                                            // templates, before anything
    loader.load()                                             // recipes, before any resolve
    // The seed takes the catalogue because StoreSection.sortIndex comes from
    // `catalog.aisleOrder`, which is why `catalog.load()` is above it and not below (§8).
    // If that load failed, `aisleOrder` is empty and the seed SKIPS `sections.v1` without
    // writing its SeedRecord, so the next good launch still seeds the aisles rather than
    // recording a store that has none as done (§8).
    try? KitchenAidSeed.applyIfNeeded(in: container.mainContext, catalog: catalog)
    try? resolver.reconcile(in: container.mainContext)         // aliases collapse first
    try? ledger.rebuildAllCaches(in: container.mainContext)    // then caches are rebuilt
}
```

There is no `recomputeCookStats` step, because there is no cook-count cache to rebuild.

Build settings: `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, `SWIFT_VERSION = 5.0`,
`TARGETED_DEVICE_FAMILY = "1,2"`,
`PRODUCT_BUNDLE_IDENTIFIER = com.brandonkeeny.KitchenAid`,
`DEVELOPMENT_TEAM = HHSFT2GD2H`. `KitchenAid/Resources/Recipes/` is added to the target as a
**folder reference**, so dropping in a new `*.json` needs no project-file edit — which matters
because adding a recipe is the single most frequent change this repo will ever see. No
`Config/Secrets.xcconfig` equivalent — nothing in this app has a key.

---

## 6. Screen-by-screen view tree

**Five tabs** via `RootTabView` + `AppTab` with a test-addressable `identifier`, copying
`CFAL3/Views/Root/RootTabView.swift`. **Today is first and is the default**, because
`CLAUDE.md` says the app opens on Today. Cook is a `fullScreenCover` and Settings is a sheet;
neither is a tab (§0.9.4).

```text
KitchenAidApp                                      KitchenAid/App/KitchenAidApp.swift
└── RootTabView  (Theme.tint, StoreFailureBanner via \.storeUnavailable,
                  CookModeView as a fullScreenCover, SettingsView as a sheet)
    │
    ├── Today ─────────────────────────────────── the launch surface
    │   ├── TodayView                   PlannedMeal, MealRecipe,     TodayView.swift
    │   │   │                           MealAttendance, RecipeTweak,
    │   │   │                           StockLot
    │   │   ├── TodayMealCard           PlannedMeal, MealAttendance  TodayMealCard.swift
    │   │   └── TodayRecentSection      RecipeTweak                  TodayRecentSection.swift
    │   └── (Cook button → CookModeView cover)
    │
    ├── Recipes ───────────────────────────────── the library that compounds
    │   ├── RecipeLibraryView           RecipeTweak                  RecipeLibraryView.swift
    │   │   ├── RecipeCardRow           RecipeTweak                  RecipeCardRow.swift
    │   │   └── RecipeFilterSheet       (content only)               RecipeFilterSheet.swift
    │   ├── RecipeDetailView            RecipeTweak, StockLot        RecipeDetailView.swift
    │   │   ├── ComponentSectionView    (content only)               ComponentSectionView.swift
    │   │   ├── IngredientLineRow       FoodItem                     IngredientLineRow.swift
    │   │   ├── RecipeMethodView        (content only)               RecipeMethodView.swift
    │   │   ├── RecipeNotesSection      RecipeTweak                  RecipeNotesSection.swift
    │   │   └── RecipeUsageSection      (content only)               RecipeUsageSection.swift
    │   ├── TweakSheet                  RecipeTweak,                 TweakSheet.swift
    │   │                               IngredientOverride, StepOverride
    │   └── IngredientInboxView         FoodItem, FoodItemAlias      IngredientInboxView.swift
    │
    ├── Plan ──────────────────────────────────── phone-shaped by default
    │   ├── PlanRootView                (scope switch)               PlanRootView.swift
    │   ├── WeekBriefView               PlannedMeal, MealAttendance, WeekBriefView.swift
    │   │                               RecipeTweak, StockLot
    │   ├── MonthCalendarView           PlannedMeal                  MonthCalendarView.swift
    │   │   └── MonthDayCell            PlannedMeal, MealAttendance  MonthDayCell.swift
    │   ├── WeekGridView   [iPad only]  PlannedMeal                  WeekGridView.swift
    │   ├── DayPlanView                 PlannedMeal, MealRecipe      DayPlanView.swift
    │   ├── PlannedMealEditorSheet      PlannedMeal, MealRecipe,     PlannedMealEditorSheet.swift
    │   │   │                           MealAttendance, Eater
    │   │   └── AttendanceGrid          MealAttendance, Eater        AttendanceGrid.swift
    │   └── DuplicateWeekSheet          PlannedMeal                  DuplicateWeekSheet.swift
    │
    ├── Shop
    │   ├── ShoppingListsView           ShoppingList                 ShoppingListsView.swift
    │   ├── GenerateShoppingListSheet   PlannedMeal, Store           GenerateShoppingListSheet.swift
    │   ├── ShoppingListDetailView      ShoppingList,                ShoppingListDetailView.swift
    │   │   │                           ShoppingListLine
    │   │   └── ShoppingListLineRow     ShoppingListLineSubtotal     ShoppingListLineRow.swift
    │   ├── ShoppingLineDetailSheet     ShoppingListSource, FoodItem ShoppingLineDetailSheet.swift
    │   ├── RegenerateDiffSheet         ShoppingListLine             RegenerateDiffSheet.swift
    │   └── ReceiveIntoInventorySheet   ShoppingListLine, StockLot   ReceiveIntoInventorySheet.swift
    │
    ├── Pantry
    │   ├── InventoryHomeView           StorageLocation, StockLot    InventoryHomeView.swift
    │   ├── LocationDetailView          StockLot                     LocationDetailView.swift
    │   ├── FoodItemDetailView          FoodItem, StockLot,          FoodItemDetailView.swift
    │   │                               InventoryTransaction,
    │   │                               FoodItemAlias
    │   ├── QuickAddStockView           FoodItem, StockLot           QuickAddStockView.swift
    │   ├── InventoryCountView          StockLot, InventoryTransaction InventoryCountView.swift
    │   ├── UnresolvedDepletionsView    InventoryTransaction         UnresolvedDepletionsView.swift
    │   └── ExpiringSoonView            StockLot                     ExpiringSoonView.swift
    │
    ├── Cook  (fullScreenCover, not a tab — CFAL3's "a sitting is a cover" rule)
    │   ├── CookModeView                RecipeTweak                  CookModeView.swift
    │   ├── MiseEnPlaceView             (content + overlay)          MiseEnPlaceView.swift
    │   ├── CookStepList                (content + overlay)          CookStepList.swift
    │   ├── CookIngredientHeader        (content + overlay)          CookIngredientHeader.swift
    │   ├── CookTimerBar                (CookSession)                CookTimerBar.swift
    │   └── CookFinishSheet             RecipeTweak, StockLot        CookFinishSheet.swift
    │
    └── Settings  (sheet)
        ├── SettingsView                (the sheet's root list)      SettingsView.swift
        ├── HouseholdView               Eater                        HouseholdView.swift
        ├── AttendanceDefaultsView      AttendanceDefault            AttendanceDefaultsView.swift
        ├── StoreLayoutView             Store, StoreSection          StoreLayoutView.swift
        ├── StorageLocationsView        StorageLocation              StorageLocationsView.swift
        ├── FoodItemCatalogView         FoodItem                     FoodItemCatalogView.swift
        ├── MergeFoodItemsView          FoodItem, MergeRecord        MergeFoodItemsView.swift
        ├── ReconcileView               StockLot,                    ReconcileView.swift
        │                               InventoryTransaction
        ├── MissingRecipesView          RecipeTweak, MealRecipe,     MissingRecipesView.swift
        │                               ShoppingListSource,
        │                               InventoryTransaction
        ├── UnitPreferenceView          (AppPreferences)             UnitPreferenceView.swift
        ├── ExportView                  (ExportCoordinator)          ExportView.swift
        │   └── PDFPreviewView          (a rendered URL)             PDFPreviewView.swift
        └── StoreHealthView             SeedRecord, MergeRecord      StoreHealthView.swift
```

`MissingRecipesView` queries **all four** holders of a `recipeID`, because §0.2 says a
removed recipe file dangles "every `MealRecipe`, `RecipeTweak`, `ShoppingListSource` and
`InventoryTransaction` holding that id" and `KitchenAidMaintenance.forgetMissingRecipeRows`
has to have something to show for each. The two mutable holders (`MealRecipe`,
`RecipeTweak`) are offered for forgetting; the two historical ones
(`ShoppingListSource.recipeID`/`recipeTitle`,
`InventoryTransaction.recipeIDSnapshot`/`recipeTitleSnapshot`) are listed **read-only**,
under a "kept as history" head, because a list he shopped and a depletion he actually made
are facts about the past that a missing file does not undo.

`PDFPreviewView` is presented from `ExportView`, as a sheet over the last rendered `URL`,
and that is its only presenter. It is worth having rather than going straight to
`ShareLink`: the artefact leaves the device, and he should be able to look at the page
before it is attached to an email.

### 6.0 Shared components, and which screens compose them

`Views/Components/` appeared in the manifest and in no tree, which made six files look
speculative — and two of them are the only quantity-entry affordances in the app.

| Component | Composed by |
|---|---|
| `DesignComponents` (card, section header, empty-state card) | every screen; the empty-state card is what `TodayRecentSection` and `ShoppingListsView` show first |
| `QuantityField` + `FractionKeypad` | `TweakSheet`'s *Quantities* section (this is what §6.2's "tap to adjust" presents), `QuickAddStockView`, `InventoryCountView`, `ShoppingLineDetailSheet`'s "1 cup of flour is ___ g" affordance, and `FoodItemCatalogView`'s density / par-level rows. **`FractionKeypad` is why ½ ⅓ ¼ is one tap and not a decimal keyboard**, which matters because every quantity in this app is a `Rational` and a decimal entry would be the one place a `Double` got in. |
| `EaterChip` | `AttendanceGrid`, `MonthDayCell`, `TodayMealCard`, and the legend on `MealPlanWeekPrintPage` — the same initials in the same colour on screen and on paper, which is the point of sharing it |
| `StockPill` | `RecipeDetailView`'s ingredient rows, `IngredientLineRow`, `InventoryHomeView`, `LocationDetailView` |
| `FlagBadge` | `ShoppingListLineRow`, `ShoppingLineDetailSheet`. One badge per `LineFlag`, text from `LineFlag.badge` (§3.9). |
| `StoreFailureBanner` | `RootTabView`, driven by `\.storeUnavailable` |

`Views/Export/PrintPrimitives.swift` is the shared base of every §7 print page — the page
frame, the hairline rule, the stroked checkbox glyph, the chip, and the fixed print type
scale. It is composed by all seven print pages and by nothing on screen, which is why it
lives under `Export/` and not here.

Note the `@Query` column: the Recipes tab queries **almost nothing**. `RecipeLibraryView`'s
only query is `RecipeTweak` (for last-made, favourites and the never-made filter); the recipes
themselves come from `RecipeLoader`. That is the content split showing up in the view layer,
and it is why the library is instant with four hundred recipes.

### 6.1 The Today screen, which the panel never specified

`CLAUDE.md`: **"Opens on Today — what's planned for today with a Cook button, falling back to
recent recipes when the plan is empty."** The panel defaulted to the library and had no Today
screen at all (§0.9.4), so this is specified here from scratch.

What it shows, in order:

1. **Today's meals**, `MealPlanService.meals(onDayKey:)` in `slotSortIndex` order. Each is a
   `TodayMealCard`: the slot, the dish titles, the attendance chips, a guest badge when
   `guestCount > 0`, the computed scale ("×1½ — 6 eaters"), and a **60pt Cook button** that
   opens `CookModeView` at that scale. One tap from launch to cooking is the whole point of
   this screen.
2. **A prep strip**, when any `.prep` entry or `makeAheadNote` falls on today or tomorrow:
   "Tomorrow: salt the steaks, uncovered in the fridge." The fixture needs this twice — step
   1's 30-minute rest and the note that the spinach can be made a day ahead.
3. **Expiring soon**, a one-line count that links to `ExpiringSoonView`. Three things going
   bad is actionable; a list of them is a different screen.
4. **`TodayRecentSection`**, when nothing is planned. Recently made first, by
   `RecipeTweak.lastMadeAt` descending (a `@Query` with a `SortDescriptor`, which is exactly
   why `lastMadeAt` is a stored row field rather than something derived), then a short
   never-made shelf. **Not the whole library** — an empty plan should offer four things, not
   four hundred.

A meal whose `recipeID` no longer resolves renders its title snapshot with "no longer in the
app" and no Cook button, rather than an empty card (§0.2).

### 6.2 Three interactions that are specified, not left to taste

**`AttendanceGrid`.** One chip per active `Eater`. A **single tap cycles** attending → away →
maybe → leftoversOnly. A **long-press toggles full/half portion**, which is the whole of
`CLAUDE.md`'s portion model. A four-person dinner is four taps with no sheet, and attendance
stops being the thing that makes planning feel like data entry. Combined with
`AttendanceDefaultsView`, steady-state attendance costs **zero** taps and "who is eating" only
becomes work on an exceptional night. The **guest stepper sits beside the grid**, not inside
it, because guests are a number and not people (§2.18).

**Plan's landing content is `WeekBriefView` on iPhone.** A 7-column × 8-slot-row grid of drop
targets does not fit on a phone, and the primary surface here is an iPhone propped against the
backsplash. The brief reads: *"14 dinners planned, 3 takeout, 1 recipe you have never made, 3
things expiring."* `WeekGridView` — the dense grid — is **iPad only**, gated in
`AdaptiveLayout`. `MonthCalendarView` uses `.scrollTargetBehavior(.viewAligned)` month paging.

**`TweakSheet` is the entire editing surface, and its shape is the decision.** Three sections
and nothing else: *Quantities* (one row per ingredient line; tapping one presents
`QuantityField` with `FractionKeypad`, so "1 tbsp not 2" and "⅓ not ¼" are both one tap and
neither goes through a decimal keyboard — §6.0; plus "back to as written" per row), *Steps*
(tap a step to correct its text or its minutes), *Notes* (one free-text field). There is no add, no delete, no reorder, and no name field — `CLAUDE.md` says
notes and tweaks only, and the absence of those affordances is what keeps the bundle and the
store from disagreeing about what a recipe IS. Every overridden row shows an "edited" dot, and
lapsed overrides appear at the bottom as "this no longer applies" rather than disappearing
(§5.2).

**Drag and drop** uses `RecipeTransfer` / `PlannedMealTransfer`: `Codable + Transferable`
structs carrying only an id and a title, a custom `UTType`, and
`ProxyRepresentation(exporting: \.title)` so a drop into Notes yields text. **Never a `@Model`
in a drag payload** — it is neither reliably `Codable` nor `Sendable`, and the failure is a
crash mid-drag rather than a compile error.

### 6.3 Cook mode, because it is where the app earns its keep

- `isIdleTimerDisabled = true` and `.persistentSystemOverlays(.hidden)`. The screen must not
  sleep with his hands in a bowl.
- 20pt minimum body scaling all the way up; **60pt minimum tap targets**, not 44 — wet fingers
  miss.
- **`MiseEnPlaceView` first**: every group's ingredients at the chosen scale, make-ahead items
  called out at the top. What you actually read before you start.
- Then the **flat method**, one step per row, the whole row the checkbox, completed steps
  dimmed but still on screen — you look back constantly. Each step shows a small pill for its
  tagged component when `componentIndex` is set.
- A **sticky header** carrying the scaled quantities for the component the current step
  touches, so he never leaves the step he is on to re-read how much butter.
- **Scaling on the fly**: ½× / 1× / 1½× / 2× / custom, recomputing every displayed quantity
  through `Quantity.scaled(by:)`. The scale is **view state on `CookSession`**. With content
  immutable this is now structurally guaranteed rather than merely intended — there is no
  writable recipe to accidentally rewrite — but the comment stays, because the obvious
  implementation of "scale this recipe" is still to write it down somewhere.
- **Concurrent `CookTimer`s** from `RecipeStep.minMinutes/maxMinutes` as tappable chips,
  timing the **longer** end of a range so a timer never fires early. `UNUserNotificationCenter`
  so a backgrounded app still rings. A three-component plated dish cooks three things at once;
  this is the highest-value feature in the app.
- **`CookFinishSheet`** does three things and no more: sets `lastMadeAt`, confirms the
  inventory depletion, and offers one optional "note what you changed" field that appends to
  `RecipeTweak.notes`. **No rating, no photo, no measured duration, no "how did it go"** — he
  was offered a journal and declined it (§0.5). The sheet is three controls, which is also why
  he will actually use it.
- Nothing in cook mode can fail: no network, no spinner, no async load. The recipe is in the
  bundle and everything else it needs is in the store before it opens.

---

## 7. PDF export

The `PDFExportService` and `PDFPaginator` blocks below are `text` API sketches (the fence
convention at the top of this document); `PrintPage` and `PDFPageWriter` in §7.1 are
`swift` and compile as written.

```text
enum PDFExportService {
    enum Job {
        /// A content id plus the scale, not a `Recipe` — so a job can be queued, logged and
        /// retried, and so a job whose recipe was removed fails with
        /// `ExportError.recipeMissing` rather than holding a stale copy.
        case recipe(recipeID: String, scale: Rational)
        case shoppingList(ShoppingList)
        case weekPlan(interval: DateInterval, meals: [PlannedMeal], eaters: [Eater])
        case inventorySnapshot(location: StorageLocation?)
    }

    /// The loader, the tweak store and the context are PARAMETERS, and that is the fix for
    /// three of the four jobs being unable to reach the data their page renders.
    ///
    /// `.recipe` carries only an id, yet §7.2 prints the effective `ResolvedRecipe` with
    /// tweak footnotes, which needs both the loader and the overlay — and
    /// `ExportError.recipeMissing(id:titleSnapshot:)` only has a writer if something here
    /// actually tries to resolve the id. `.inventorySnapshot` carries only a location, yet
    /// its page renders lots grouped by location plus a closing block of transactions with
    /// `lot == nil`, which is a fetch. `.weekPlan` carries meals and eaters, but
    /// `PrepAheadPrintPage` must also print every `makeAheadNote` in the range, and those
    /// live in bundled content.
    ///
    /// Taking the three collaborators keeps the jobs small and queueable, which was the
    /// reason they hold ids in the first place. The alternative — fattening each case with
    /// pre-fetched rows — makes a job a snapshot of the store at enqueue time, which is the
    /// stale copy the comment above says it is avoiding.
    @MainActor
    static func render(
        _ job: Job,
        loader: RecipeLoader,
        tweaks: TweakStore,
        context: ModelContext
    ) throws -> URL
}
```

Every job now has exactly one owning print view, which the panel's `inventorySnapshot` did not
(§0.9.5):

| Job | Pages it emits |
|---|---|
| `.recipe` | `RecipePrintPage` (portrait, 1–n) |
| `.shoppingList` | `ShoppingListPrintPage` (portrait, 1–n) + `ShoppingSourcesPrintBlock` |
| `.weekPlan` | `MealPlanWeekPrintPage` (**landscape**) + `MealPlanHeadCountPrintPage` (portrait) + `PrepAheadPrintPage` (portrait) |
| `.inventorySnapshot` | **`InventorySnapshotPrintPage`** (portrait, 1–n) |

### 7.1 `PrintPage` and the writer — the other half of defect 5

`Job.weekPlan` emits three structurally different pages, two of them a different SIZE and
ORIENTATION from the third. The panel's writer was `write<Page: View>(pages: [Page], ...)`,
which is generic over **one** page type with **one** `CGSize` — so the three-page week plan
could not be expressed at all, and `mediaBox` was fixed for the whole document.

Fixed by boxing the page and moving the size onto it:

```swift
// KitchenAid/Views/Export/PrintPage.swift
import SwiftUI

/// One page: its size and its content, type-erased.
///
/// `AnyView` is normally a smell, and here it is correct: these views are rendered ONCE into a
/// PDF context and never diffed, so the thing `AnyView` costs — identity for the update
/// algorithm — is not in play. What it buys is a heterogeneous page list, which is the only
/// way one document holds a landscape grid and two portrait pages.
struct PrintPage: Identifiable {
    let id = UUID()
    /// Points. 612×792 portrait, 792×612 landscape.
    let size: CGSize
    let content: AnyView
    /// For `ExportError.pageMeasurementFailed` and for the "(cont.)" head.
    let debugName: String

    init<V: View>(size: CGSize, name: String, @ViewBuilder content: () -> V) {
        self.size = size
        self.debugName = name
        self.content = AnyView(content())
    }

    static let portrait = CGSize(width: 612, height: 792)
    static let landscape = CGSize(width: 792, height: 612)
}
```

```swift
// KitchenAid/Services/PDFPageWriter.swift
import SwiftUI
import CoreGraphics

enum PDFPageWriter {
    @MainActor
    static func write(pages: [PrintPage], to url: URL) throws {
        guard let first = pages.first else { throw ExportError.nothingToExport }
        // The context's mediaBox is only the DEFAULT. Each page overrides it below, which is
        // what lets a landscape week grid and a portrait head-count page share one document.
        var box = CGRect(origin: .zero, size: first.size)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw ExportError.contextUnavailable }

        for page in pages {
            let pageBox = CGRect(origin: .zero, size: page.size)
            let info: [CFString: Any] = [kCGPDFContextMediaBox: CFDataCreate(
                nil, withUnsafeBytes(of: pageBox) { Array($0) }, MemoryLayout<CGRect>.size
            ) as Any]
            let renderer = ImageRenderer(content: page.content)
            renderer.proposedSize = ProposedViewSize(page.size)
            // The CGContext closure keeps text as VECTOR TEXT — selectable, searchable, sharp
            // when printed. `renderer.uiImage` gives a rasterized, unsearchable,
            // blurry-on-print page, which is what a quick implementation produces.
            renderer.render { _, draw in
                ctx.beginPDFPage(info as CFDictionary)
                draw(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
    }
}
```

**Two hard constraints, both as comments in the files:**

1. **No `List`, no `ScrollView`, no `LazyVStack`, no `LazyVGrid` anywhere inside a view handed
   to `ImageRenderer`.** It renders only laid-out content, and anything lazy silently renders
   empty or clipped. Print pages are plain `VStack`/`HStack`/`Grid`.
2. **Pagination packs whole measured sections, it does not slice.** `PDFPaginator` measures
   each section's ideal height and assigns whole sections to pages, repeating section heads
   with "(cont.)". Slicing one tall rendered image at 792pt boundaries cuts text through the
   middle of a line, and a fixed rows-per-page estimate clips.

`PDFPaginator` was named here and nowhere declared, while `ExportError.pageMeasurementFailed`
and the "(cont.)" head both depend on it. Its input and output types:

```text
// KitchenAid/Services/PDFPaginator.swift
enum PDFPaginator {
    /// One section, already measured, with everything needed to re-emit its head on the
    /// next page. `content` takes `isContinuation` so the head can read "Produce (cont.)"
    /// without the caller building two views.
    struct MeasuredSection: Identifiable {
        let id = UUID()
        let head: String
        /// `ImageRenderer`-measured ideal height in points, for the given page width.
        let height: CGFloat
        /// The height of the repeated head alone, subtracted from the budget on a
        /// continuation page.
        let headHeight: CGFloat
        let content: (_ isContinuation: Bool) -> AnyView
    }

    /// Whole sections, in order, into pages of `pageSize`. A section taller than one page
    /// gets a page of its own and stays whole — overflowing one page is a visible, honest
    /// failure, where slicing is an invisible one that cuts a line of text in half.
    /// Throws `ExportError.pageMeasurementFailed(page: name)` when a section reports a
    /// non-finite or non-positive height, which is what a lazy container inside a print
    /// view produces (constraint 1 above).
    static func paginate(
        sections: [MeasuredSection],
        pageSize: CGSize,
        name: String
    ) throws -> [PrintPage]
}
```

### 7.2 The documents, specified line by line because this is the artefact that leaves the device

- **`MealPlanWeekPrintPage`** — landscape 792×612. A 7-column week grid; each day lists slot ·
  title · a row of member-initial chips in each member's colour, with glyphs for leftovers /
  takeout / prep and a "+3" badge where `guestCount > 0`. A **member chip legend across the
  footer**, and "KitchenAid · Nov 3–9 · generated Oct 31". No warning triangle — there are no
  warnings (§0.5).
- **`MealPlanHeadCountPrintPage`** — head count per day per meal, **its own page**, because
  that is the page that gets texted to whoever is cooking. Residents and guests in separate
  columns, with a portions total.
- **`PrepAheadPrintPage`** — its own page: every `.prep` entry and every `makeAheadNote` in the
  range, in date order. This is how "salt the steaks the night before" survives, and the
  fixture needs it twice.
- **`ShoppingListPrintPage`** — portrait 612×792, **two columns**, grouped by section with a
  **hairline rule under each head**; a **stroked rounded-rect checkbox drawn as a glyph**, not
  an emoji; quantities **right-aligned in `.monospacedDigit()`**; `have` in `Theme.dust`
  beside `toBuy` in `Theme.ink`; and a **superscript marker per line** keyed to a closing
  `ShoppingSourcesPrintBlock` — "Meals this list covers".
- **`RecipePrintPage`** — ingredients in a left column grouped by component, the **flat
  method** in a right column, notes as a footer. Which is how the NY Strip sheet actually
  reads. It prints the **effective** recipe (`ResolvedRecipe`), with a footnote marker on any
  line he has tweaked and a closing "your notes" block when `RecipeTweak.notes` is non-empty —
  because the printed sheet taped to a cupboard should say what he actually does, while still
  admitting where it differs from the original.
- **`InventorySnapshotPrintPage`** — portrait. One location or all, lots grouped by location:
  item, quantity, acquired, best-by, with expiring rows in `Theme.ink` and the rest in
  `Theme.dust`. A closing **"unassigned"** block lists transactions with no lot, because the
  one thing a paper inventory must not do is silently omit stock the ledger knows about
  (decision 8).

Serif headers via `Theme.serif(_:weight:)`, matching CFAL3's voice.

**Sharing is `ShareLink`, and only `ShareLink`.**

```swift
ShareLink(item: url,
          preview: SharePreview(filename, image: Image(systemName: "doc.richtext")))
```

It reaches Mail, Messages, AirDrop and Files, needs no entitlement, no key and no account, and
nothing leaves the device unless he taps share. `MFMailComposeViewController` would add UIKit
plumbing and buy nothing. **Worth a comment in `ExportView` so nobody "improves" it into an
SMTP client.**

Files are written to `FileManager.default.temporaryDirectory` with a **human filename**,
because that string becomes the mail attachment name:

```text
KitchenAid - Shopping list, Nov 3-9.pdf
KitchenAid - Week of Nov 3.pdf
KitchenAid - NY Strip Crostini.pdf
KitchenAid - Pantry, Oct 31.pdf
```

`Transferable` conformance too, so drag-out works on iPad. `PDFPreviewView` wraps `PDFView` in
a `UIViewRepresentable`, reusing `CFAL3/Views/Review/MMPDFReader.swift`'s shape **including
the `@unchecked Sendable` box around the non-`Sendable` `PDFDocument`**.

---

## 8. Seeded data

Two kinds of starting data, and the difference is the point of §0.2–0.3:

| | Where it comes from | Seeded into SwiftData? |
|---|---|---|
| Recipes | `Resources/Recipes/*.json`, decoded by `RecipeLoader` | **No.** They are content. |
| The ingredient catalogue | `Resources/ingredients.json`, decoded by `IngredientCatalog` | **No.** `FoodItem` rows are minted on demand (§0.3). |
| Store sections, storage locations, the household | `KitchenAidSeed` | Yes, `SeedRecord`-gated per key. |

`KitchenAidSeed.applyIfNeeded(in:catalog:)` fetches each `seedKey` before applying, so
re-running is idempotent without `.unique`. It takes the catalogue because the store-section
walk order is read from it and not copied (§0.3), which is also why `catalog.load()` runs
before it in the launch task (§5.6).

| Seed key | Contents |
|---|---|
| `sections.v1` | One `Store` ("Default", `isDefault`) with one `StoreSection` row **per entry of `IngredientCatalog.aisleOrder`, `sortIndex` = that entry's index** — then `Household` and `Unsorted` appended after it for things the catalogue does not cover. **The seed keeps no copy of the order.** It reads it, which is the whole reason `ingredients.json` now ships `aisleOrder` (§0.3): the thirteen aisles are exactly the catalogue's `aisle` values, so a `FoodItem` minted from a template lands in the right aisle with no mapping table, and a hand-written list here would be a second copy that drifts from the build script's with no test in this repo able to notice. It had already drifted — the list this row used to spell put Bakery fifth and Frozen twelfth, where the script has Bakery second and Frozen last. After seeding, `sortIndex` is his to drag and the seed never runs again. **If `catalog.aisleOrder` is empty this key is SKIPPED and no `SeedRecord` is written.** `catalog.load()` is a per-file decode whose failure path reports a `ContentDiagnostic` and leaves `aisleOrder` at its declared `[]` (§2.6); seeding anyway would create zero aisle sections, append Household and Unsorted, record `sections.v1` as done, and then never run again — so every minted `FoodItem` would land in "Unsorted" forever with nothing on screen explaining it. Skipping leaves the next successful launch to seed it, and because the only way to reach an empty `aisleOrder` is a catalogue that failed to load, `StoreHealthView` already has the explanation to show: the catalogue's `.decodeFailed` diagnostic plus a missing `sections.v1` `SeedRecord` is the pair it reports as "store sections not seeded yet". |
| `locations.v1` | `StorageLocation` rows: Pantry, Fridge (`defaultShelfLifeDays: 7`), Freezer (90), Spice rack, Bar. |
| `household.v1` | **Two `Eater` rows, both full portion**, named "Me" and "Partner" for him to rename in `HouseholdView`. Two because `CLAUDE.md` says ship two; renameable and removable because it says addable and removable; and **no count is hardcoded anywhere else in the app** — every scale comes from `portions`, so a household of one or of nine needs no code change. |

**There is no `bridges.v1` row, and no count-bridge seed of any kind.** The table that used to
sit here gave `garlic` a `1 head` pack with `clove → 1/10 head`, `baguette` a `1 loaf` pack
with `slice → 1/12 loaf`, and input-noun rows for `butter`, `eggs` and `lemon` — all of it to
feed purchase-unit rounding, which is cut (`CLAUDE.md`). Nothing in the document ever wrote
those rows, which is the defect that cut the feature; the honest state is that they do not
exist. A recipe line's count noun is the noun the list shows.

What survives is the density bridge, and it needs no seed at all: the catalogue already ships
`gramsPerCup` on **108 of its 668** entries, `FoodItemResolver` copies it onto the `FoodItem`
it mints, and that is what lets a 4 oz butter lot cover a 2 tbsp requirement (§4.3b′). Where
a density is genuinely unsettled the catalogue leaves it null on purpose — kosher salt is
~142 g/cup as Diamond Crystal and ~288 as Morton — and the line shows both numbers with a
one-tap "these are the same" affordance that writes the density back (§4.2 step 5).

### 8.1 The fixture's bundled file

`docs/fixture-recipe-01.txt` is the source text and
`KitchenAid/Resources/Recipes/ny-strip-crostini-with-creamed-horseradish-spinach.json` is
**the file the build pass generates and commits**. It is not in the repo yet — the only
resource committed today is `KitchenAid/Resources/ingredients.json`, and
`KitchenAid/Resources/Recipes/` does not exist — and four test suites read it
(`RecipeLoaderTests`, `TweakStoreTests`, `MealScalingTests`, `ShoppingListBuilderTests`), so
generating it is the first step of that pass rather than a later tidy. One command produces
the parse:

```text
python3 -I scripts/import_recipe.py docs/fixture-recipe-01.txt \
    > KitchenAid/Resources/Recipes/ny-strip-crostini-with-creamed-horseradish-spinach.json
```

then the hand-classified fields listed below are added to it. The bundled file is
**generated by the importer, never hand-written** — building it by hand is what lets a schema
pass a test that the real capture path would fail.

**The importer emits this shape. It is no longer a gap.** `scripts/import_recipe.py` now
writes `schemaVersion`, `id` (= `slug(title)`, which is why the file name is the full title
slug), `title`, `summary`, `yieldText`, `yieldAmount`, `yieldUnitLabel`, `servings`,
`activeMinutes`, `totalMinutes`, per-line `lineID` and per-step `stepID`, and the five flat
quantity fields (`hasQuantity`, `amountNumerator`, `amountDenominator`, `unit`, `dimension`)
plus `display`. The ids are name-based with an occurrence number, exactly as §2.3 and §2.4
require: `butter-1`, `butter-2`, `kosher-salt-1`, `kosher-salt-2`, and
`season-the-steak-1`, `sear-the-steak-1`. `python3 -I scripts/test_import.py` asserts all
twelve fixture requirements against it and passes.

**Where it still spells a key differently, the Swift decoder bends and the script does
not** (§2.0): `components[].name` → `title`, `lines[].name` → `displayName`,
`lines[].raw` → `rawText`, `lines[].qualifier` → `unmeasuredNote`, `lines[].unit` →
`unitCode`, `steps[].order` → `number`, `servings` as a whole number into the
numerator/denominator pair, notes as bare strings, and the flat object read as a `RecipeFile`
with no `recipe` wrapper. Every one of those is an additive `decodeIfPresent` fallback in
§2.1–§2.5 and none of them changes the committed JSON.

**What is still a classification step rather than a parse** — done once, by hand or by a
keyword pass, and committed with the file: the four `notes[]` kinds (`makeAhead`, `keyStep`,
`variation`, `timing`) and the `makeAheadNote` lifted from the first of them; each step's
`componentIndex`; `ovenTemperatureF` on step 2 and `targetInternalTemperatureF` on step 3;
`isPassiveRest` on steps 1 and 4; and `rawText` at the recipe level (the importer keeps the
verbatim line per ingredient as `raw`, but not the whole document). None of these are
parse-ambiguous and none block the schema — they are judgements about prose that the
importer deliberately does not make, and `scripts/test_import.py` is the check that the
parse underneath them has not moved.

```text
RecipeFile
  schemaVersion        1
  recipe
    id                 "ny-strip-crostini-with-creamed-horseradish-spinach"
                                                    <- slug(title). The file name, and
                                                       every stored edge.
    title              "NY Strip Crostini with Creamed Horseradish Spinach"
    summary            "Crisp baguette, warm creamed horseradish spinach, and thin
                        slices of seared NY strip."
    yieldText          "12 crostini (serves 4)"
    servings           4 / 1                        <- the ONLY scaling divisor
    yieldAmount        12 / 1
    yieldUnitLabel     "crostini"                   <- display; "18 crostini" at ×1.5
    activeMinutes      35
    totalMinutes       70
    timesAreApproximate true                        <- both document values say "About"
    batchGranularity   continuous
    makeAheadNote      pulled from notes[0]; the note itself is KEPT
    rawText            the full pdftotext -layout source

    components (3 — ingredient GROUPS, each owning lines and NO steps)
    ┌ 0  "Crostini and steak"        protein
    │     baguette-1         12 slice   baguette         prep "1/2 inch thick"        count:slice
    │     olive-oil-1         3 tbsp    olive oil                                     volume  [staple]
    │     ny-strip-steak-1   16 oz      NY strip steak   prep "about 1.25 in thick"   MASS, confirmed
    │     kosher-salt-1       1 tsp     kosher salt                                   volume  [staple]
    │     black-pepper-1    1/2 tsp     black pepper                                  volume  [staple]
    │     butter-1            1 tbsp    butter                                        volume
    │     garlic-1            2 clove   garlic           prep "smashed"               count:clove
    ├ 1  "Creamed horseradish spinach"  side
    │     baby-spinach-1     10 oz      baby spinach                                  MASS, confirmed
    │     shallot-1           1 each    shallot          prep "minced"                count:each
    │     butter-2            1 tbsp    butter                                        volume
    │     cream-cheese-1      4 oz      cream cheese                                  MASS, confirmed
    │     heavy-cream-1       3 tbsp    heavy cream                                   volume
    │     prepared-horseradish-1
    │                          3 tbsp    prepared horseradish  prep "drained"          volume
    │     parmesan-1          2 tbsp    Parmesan         prep "grated"                volume
    │     lemon-juice-1       1 tsp     lemon juice                                   volume
    │     kosher-salt-2     1/4 tsp     kosher salt                                   volume  [staple]
    └ 2  "To finish"                   finish
          fresh-chives-1      1 tbsp    fresh chives     prep "finely chopped"        volume
          flaky-salt-1       (nil)      flaky salt       unmeasuredNote "Pinch"       NO QUANTITY

    steps (8 — FLAT, recipe-ordered, interleaving the groups)
      stepID is slug(title) + occurrence number, NOT "step-N" (§2.4). `number` carries the
      printed 1-8 ordering.
      1  season-the-steak-1          30/30 min   componentIndex 0   isPassiveRest
      2  toast-the-baguette-1         9/9  min   componentIndex 0   ovenTemperatureF 400
      3  sear-the-steak-1             7/8  min   componentIndex 0   targetInternal 125
      4  rest-the-steak-1             9/9  min   componentIndex 0   isPassiveRest
      5  wilt-the-spinach-1           5/5  min   componentIndex 1
      6  make-the-creamed-spinach-1   2/2  min   componentIndex 1
      7  slice-the-steak-1           nil/nil     componentIndex 0
      8  assemble-1                  nil/nil     componentIndex nil   (the whole dish)

    notes (4, ordered, each its own idea)
      makeAhead  "The spinach can be made a day ahead and gently rewarmed…"
      keyStep    "Squeezing the spinach dry is the key step…"
      variation  "For a sharper bite, stir a little extra horseradish…"
      timing     "Toast the baguette just before serving so it stays crisp."
```

Note `butter-1` / `butter-2` and `kosher-salt-1` / `kosher-salt-2`: the occurrence-numbered
`lineID` scheme (§2.3) is what lets an override land on the tablespoon of butter in the steak
group without touching the one in the spinach — which the fixture's own self-aggregation case
makes immediately necessary. The importer reports the same pair back as
`aggregatesWithinRecipe: ["butter", "kosher salt"]`, which is requirement 8 proving itself at
import time rather than waiting for a shopping list.

### 8.2 What this one recipe proves, and therefore what the tests assert

All twelve requirements in `docs/REQUIREMENTS_FROM_FIXTURE.md` remain binding. Each is mapped
to its evidence here:

| # | Requirement | Evidence in the bundled file |
|---|---|---|
| 1 | Ingredients group, steps are flat | 3 components, 8 recipe-level steps interleaving them (2 → 3 → 5 → 8). `RecipeComponent` has no `steps` array; `RecipeStep.componentIndex` is an optional tag. |
| 2 | Two different yields, both needed | `servings 4` and `yieldAmount 12` + `yieldUnitLabel "crostini"`; scaling divides by 4 only. |
| 3 | Two different times | 35 active vs 70 total, the gap explained by step 1's passive rest. `timesAreApproximate` keeps the UI from implying precision. |
| 4 | Fractions survive; decimals are not acceptable | `Rational` throughout, `1/2 tsp` and `1/4 tsp` stored as integer pairs, `1 tsp + 1/4 tsp = 5/4 tsp` exactly. `Rational`'s hand-written `Codable` is what keeps that true across the JSON boundary (§3.1). |
| 5 | Non-numeric quantities are real | `flaky-salt-1` has `amount == nil` and `unmeasuredNote "Pinch"`; it reaches the list as a presence item, never as 0 and never dropped. |
| 6 | `oz` is ambiguous, and is weight here three times | all three `.mass` with `dimensionConfirmed == true`, resolved once by the importer's `resolve_oz` and RECORDED. `1/2 inch` lives in `preparation`; there is no length dimension. |
| 7 | Name and preparation are separate fields | `shallot` / `minced`, `garlic` / `smashed`, and **`Parmesan` / `grated` where the adjective comes FIRST** — which every comma-splitting parser gets wrong, and which `rawText` makes recoverable. |
| 8 | **A recipe aggregates against ITSELF** | butter `1 tbsp + 1 tbsp = 2 tbsp` across components 0 and 1; kosher salt `1 tsp + 1/4 tsp = 1 1/4 tsp` **through the staple path**. Asserted in `ShoppingListBuilderTests`. |
| 9 | Bare counts whose unit lives in the name | `garlic-1` is `2 clove` (the importer lifted "cloves" out of "garlic cloves"); `shallot-1` is `1` with a null unit, which decodes to `each` from its recorded `count` dimension (§2.3); `baguette-1` is `12 slice`. Each its own merge bucket, and the buckets are never folded together — so the line ships as **"12 slices baguette"**, which is what the design mockup says. Turning that into "1 baguette" is purchase-unit rounding, deferred; see `CLAUDE.md` and §4.3(d). |
| 10 | Steps carry a title, a duration — sometimes a range — and a body | `sear-the-steak-1` is 7/8; `slice-the-steak-1` and `assemble-1` are `nil`/`nil`, not `0`. |
| 11 | Temperatures appear in step bodies and are worth extracting | `toast-the-baguette-1` oven 400F, `sear-the-steak-1` internal 125F, two fields, and `body` left verbatim so a later pass needs no re-import. |
| 12 | Notes are a list, not a blob | four `RecipeNote` entries with four kinds, `makeAhead` additionally lifted to `makeAheadNote` without removing the note. |

And the catalogue's own requirement, from `CLAUDE.md`: **all 16 of the fixture's ingredients
resolve.** `IngredientCatalogTests` asserts each one by name or alias and checks its aisle:
baguette (Bakery), olive oil (Condiments, staple), NY strip steak (Butcher), kosher salt
(Spices, staple), black pepper (Spices, staple), butter (Dairy), garlic (Produce), baby
spinach (Produce), shallot (Produce), cream cheese (Dairy), heavy cream (Dairy), prepared
horseradish (Condiments), Parmesan (Dairy), lemon juice (Beverages), fresh chives (Produce),
flaky salt (Spices, staple). `python3 -I scripts/test_catalogue.py` asserts the same thing in
Python and prints the catalogue's current size: **668 ingredients, 87 staples, 123 aliases,
13 aisles**, with `gramsPerCup` on 108 of them. Those are the figures this document quotes;
they come off the built JSON and that script is what re-checks them.

Planned for Saturday dinner with 2 residents at full portion → `portions = 2`, `servings = 4`,
`scale = 1/2` — and the yield reads **6 crostini**. With `guestCount = 2` at full portion →
`portions = 4`, `scale = 1`, **12 crostini**. For six → `scale = 3/2`, **18 crostini**, butter
totals `3 tbsp`, and a `.prep` entry lands on Friday carrying "salt the steaks, uncovered in
the fridge" from step 1.

---

## 9. Deliberately NOT in v1

Each of these is **designed for** rather than built. Check this list before assuming one needs
a migration. Everything Brandon **declined** is in §0.5 instead, and is not deferred — it is
absent.

| Deferred | Status in the schema, and what turning it on costs |
|---|---|
| **CloudKit sync** | Every rule in §0.4 is already obeyed. `cloudKitDatabase: .none` → `.private("iCloud.com.brandonkeeny.KitchenAid")` plus the entitlement. **No schema change.** This is the whole reason for the no-`.unique`, all-defaulted, all-optional-with-single-sided-inverses discipline, and for the ledger. Note what it would *not* carry: recipes and the catalogue are in the bundle, so they still arrive with a build. |
| **Runtime recipe import (paste, or open a file)** | **Designed for, and this is the one deferral the content split makes cheap.** A pasted block or an opened PDF would be parsed into the same `Recipe` value type and written to `Application Support/Recipes/`, which `RecipeLoader` would merge over the bundled set by id. No model changes, no migration, and the overlay keys still work because they key on the same ids. What it needs is the parser (`RecipeTextParser`, `StepTextParser`, `QuantityTokenizer` — the Python importer is the reference implementation, and **when the Swift parser and the Python one disagree, the Python one is right**, because it has a test that runs), a review sheet, and a decision about precedence when a bundled id collides with an imported one. |
| **Receipt scanning to bulk-add to the pantry** | **Asked for** (`CLAUDE.md`), not built. On-device OCR via `VNRecognizeTextRequest`, no network. Receipt text is abbreviated (`GV CRM CHS 8Z`), so it matches against the catalogue's `name` and `aliases` — which is `IngredientCatalog.entry(matching:)` with a fuzzier key — and asks about what it cannot place, **once, then remembers** by writing a `FoodItemAlias` row. Additive: one sheet, one matcher, no schema change. |
| **Barcode scanning** | **Asked for**, with a caveat that shapes the design: a barcode is only a number, and turning one into "heavy cream" needs a commercial product database, which means a subscription and a network call this app does not have. So the first scan of an item **asks what it is** and every later scan fills itself in. The kitchen becomes its own database. Additive: a `barcode: String` on `FoodItem` plus a scanner sheet feeding `QuickAddStockView`. **Do not design this as though a lookup service exists.** |
| **Purchase-unit rounding** ("1 baguette" instead of "12 slices"; "buy 2 heads" instead of "3 cloves") | **Deferred, after being added on initiative and cut.** It failed review twice — first because every gate required two count buckets and the fixture produces one, then because nothing in the document ever wrote the purchase pack or the count-equivalence rows the mechanism read — and five of the twelve defects left after two review rounds existed only because of it. `CLAUDE.md` holds the full account and the prerequisites. What is already in place for it: `SubtotalRole.purchase` is a separate stored role that v1 fills with a copy of `toBuy` (decision 15), so the rounding arrives as a writer for that role plus a pack field, with **no migration**. What it needs first is a real writer for the pack and the equivalences, and **one** purchase noun per ingredient settled before any Swift is written. |
| **Leftovers tracking** | Partly present: `MealEntryKind.leftovers`, the `leftoversFrom` self-edge, `plannedLeftoverServings` and `servingsCooked` all exist, and shopping already excludes a leftovers night. What is deferred is the REPORTING — "you are a portion short Tuesday" — which is `MealPlanStats` work, not schema work. |
| **Nutrition data** | Needs a per-ingredient nutrient table and a serving-size bridge. Cheapest path is a new section in `ingredients.json` (it is content, and the build script already owns that file) plus a reader; no stored rows change. |
| **Cost tracking and cost-per-meal** | `StockLot.unitCostCents`, `InventoryTransaction.priceCents` and `ShoppingListLine.priceCents` are **already stored**. Only the reporting views are missing. |
| **Substitutions** | A `Substitution` model (`from`, `to`, `ratio`, `note`) was specified and cut. Additive, with `.nullify` edges both ways — or, better, a content table, since substitutions are knowledge rather than user data. |
| **Saved plan templates** | `PlanTemplate` + `PlanTemplateEntry` can be added without touching `PlannedMeal`, because there is no `MealPlan` container to retrofit. `DuplicateWeekSheet` covers the common case in v1. |
| **A share extension target** | `.onOpenURL` plus the document type association covers "Open in KitchenAid" from Files and Mail. The extension is a new target, not a schema change. |
| **Apple Watch / widgets / Siri** | None of them change the store. A Today widget is now cheap, because Today is a specified screen with a single query. |

**Three things are deliberately NOT deferred, because they cannot be added later:**

1. **The inventory ledger** (§2.22). A scalar `onHand` cannot be upgraded to a transaction log,
   because the history was never recorded.
2. **Two yields on `Recipe`** (§2.1). Collapsing them at import and splitting them later cannot
   recover which number was which.
3. **`RecipeNote` entries and `RecipeStep.title`/`body`/`minMinutes`/`maxMinutes`** (§2.4,
   §2.5). Flattening four note bullets into a paragraph, or a range into one `Int`, is lossy at
   import and irreversible afterwards — and with content committed to the repo, a lossy import
   is a lossy commit.

A fourth belongs on that list now: **the stable `lineID` and `stepID` on content** (§2.3).
Adding them later would mean every existing recipe file's ids are assigned retroactively, and
every override written before that moment would have nothing to key on.

---

## 10. The riskiest decisions

**1. Recipes are immutable bundled content, keyed to the store by a string id.**

*The risk.* It is the largest structural bet in the document, and it has a cost nothing else
here has: **a `recipeID` can point at nothing, and no delete rule can ever fix that**, because
the thing it points at was never a row (§0.2). A new recipe needs a rebuild; family phones do
not get it until they reinstall. The overlay adds a second kind of dangling reference — an
`IngredientOverride` whose `lineID` no longer exists because the file was revised — and
`TweakStore` has to report lapses rather than hide them, which is one more thing on screen
that says "this used to work".

*Why anyway.* Because it is what his pipeline actually is. He writes a recipe in conversation,
edits it, and the PDF is dropped into a session to be parsed and committed. The panel's model —
`Recipe` as a SwiftData row with a full authoring UI — serves a product he does not use: it
means an authoring screen he never opens, an import path that writes into the store before he
has reviewed it, and a recipe library whose truth lives on one phone and syncs by hope. Content
in the bundle means recipes are reviewable in a diff, revertable in git, identical on every
device that has the build, and never the thing a migration can corrupt. It also makes the
library instant and makes `Recipe` a value type, which is what stops cook mode's "double the
batch" from rewriting the recipe to serve 8 forever.

*Mitigations, all required.* Every holder of a `recipeID` stores a title snapshot, so nothing
goes blank. `MissingRecipesView` lists dangling ids and lets him forget them deliberately.
`isArchived` in the JSON is the supported way to retire a recipe, so **deleting a file is never
necessary**, and the spec says so three times. The `lineID` scheme is name-based rather than
positional, so a revision that reorders lines does not silently move his quantity override onto
the wrong ingredient — it lapses it, visibly. And `RecipeLoader` diagnoses duplicate ids,
duplicate `lineID`s and unresolvable references at launch, into `StoreHealthView`, because a
content error is a build-time mistake that must not be a runtime mystery.

**2. Inventory is an append-only ledger with a per-lot cache, built on day one.**

*The risk.* It roughly doubles every write path and introduces a cache that can drift from
truth — a permanent class of bug this spec is choosing to own. It also creates three standing
chore queues (the ingredient inbox, the unresolved-depletions inbox, the reconcile report) for
one busy cook, and once the ledger goes stale `subtractInventory` silently produces a wrong
shopping list, which is **worse than having no inventory feature at all**.

*Why anyway.* The alternative is broken under the sync he will certainly ask for: a scalar
decremented on two offline devices resolves field-level last-writer-wins and **loses one
decrement silently**, with no conflict handler possible, and the error compounds forever. "Why
does it think I have 3 lb of butter" has no answer without a ledger. And retrofitting one in
year two means inventing history that was never recorded — this is the only part of the design
that is genuinely not additive. He also chose it explicitly: "the full ledger the panel
designed".

*Mitigations, all required.* The catalogue does most of the work for free: `staple` on 87 of
its 668 entries — every spice, oil and vinegar — means he never inventories his salt, and
**108** shipped `gramsPerCup` values mean most depletions never reach the `.pendingBridge`
inbox at all. The inbox counts are
**badges on the Pantry tab**, visible without being modal. `rebuildAllCaches` and `reconcile`
run on launch and on remote-change notifications, so the repairs actually run rather than
waiting for a Settings screen he has no reason to open. And `reconcileReport` **surfaces**
divergence instead of hiding it, as a readable number per lot and per item including the
unassigned bucket (§3.11): a cache that reports its own drift is acceptable, a cache that
drifts silently is not.

**3. No cross-dimension conversion without per-item data — a mixed line shows N numbers.**

*The risk.* The shopping list sometimes reads **"Flour — 1 cup + 200 g"** instead of one tidy
total. It looks unfinished, it looks like the app could not do the arithmetic, and it is the
thing a stranger would screenshot as a flaw. The same honesty produces `.needsBridge` lines
that over-buy on purpose, and a `.pendingBridge` depletion inbox that is one more queue.

*Why anyway.* The alternative is **inventing** a conversion. `1 cup = 240 g` is correct for
water, off by ~2× for flour and ~1.4× for honey — and wrong *silently*, inside the number he is
about to shop by. The catalogue makes the same judgment and is worth quoting: kosher salt has
no `gramsPerCup` because Diamond Crystal is about 142 g/cup and Morton about 288, a factor of
two from the same words on the box. A list that admits what it does not know is strictly better
than one that lies confidently, and trust is the only thing that keeps him using this in year
two. On the subtraction side the asymmetry is decisive: buying a duplicate pound of butter is a
far cheaper error than arriving at dinner without it, so an unbridgeable requirement assumes
**nothing** is on hand.

*Mitigation turns the flaw into the feature.* The shipped catalogue pre-populates the densities
that are settled, so this case is rare rather than routine on day one. Where it does fire,
every mixed line carries an inline *"these are the same — 1 cup of flour is ___ g"*; one tap,
one number, and every present and future sum for that ingredient resolves silently. **The app
learns his kitchen**, which is the right shape for a project whose whole premise is that he
keeps adding to it for ten years. Count nouns get no such bridge in v1: "3 cloves + 1 head"
stays two numbers, and turning either into a purchase noun is the cut feature (`CLAUDE.md`).

**Honourable mentions.**

*Storing `dayKey: Int` beside `date: Date`* is redundant data, which this spec otherwise
refuses. It stays because "which day is this meal on" is ambiguous across timezones and DST in a
way that produces a bug he reads as *"the app moved my dinner"*, and four bytes is cheap
insurance against a weekend of `Calendar` debugging. Both fields are written only by
`PlannedMeal.setDate(_:)`, so they cannot drift.

*`RecipeTweak.notes` as one last-writer-wins `String`* is the one place this spec accepts a
field two devices can both clobber. Rows would be safer and rows would also be a cooking
journal, which he declined. The safety is worth less than the line he drew.

*Nothing here has been compiled.* The schema, every `#Predicate`, every `@Relationship` macro
and every line of the arithmetic has been reviewed and not built. The two checks that can
actually run — `scripts/test_import.py` and `scripts/test_catalogue.py` — are in Python, and
they are why the content side of this split is the better-tested half of the app before a
single Swift file exists.
