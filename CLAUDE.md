# KitchenAid

A personal iOS app for Brandon's cooking: recipes, a calendar meal plan, who is
eating each meal, a shopping list generated from the plan, and a household food
inventory. Plus PDF export through the iOS share sheet.

This is a **long-running project**. Recipes and features get added continuously
as he cooks, usually one session at a time. Read this file and
`docs/ARCHITECTURE.md` before changing the model layer.

## Decisions Brandon has made

These came from him directly. Do not quietly redesign around them; if one looks
wrong, say so and ask.

| | |
|---|---|
| **Opens on** | **Today** — what's planned for today with a Cook button, falling back to recent recipes when the plan is empty. Not the library, not the week. |
| **Cooking history** | **Last-made date only.** No journal, no ratings, no "how did it go". He was offered a full journal and declined it. |
| **In-app editing** | **Notes and tweaks only.** Adjust a quantity, fix a step, add a note after cooking. No authoring UI — recipes are written before they arrive. |
| **Household** | **Named people with a full or half portion**, addable and removable at will. Today it is "mostly just me plus 1 adult", so ship two and never hardcode a count. Plus a **guest count** per meal for when there's a party — counted, not named. No allergy or dietary data; he declined it. Attendance drives scaling. |
| **Inventory** | **The full ledger.** Offered a simple current-amount version, he chose lots with purchase dates, a transaction record of every add and depletion, par levels and reconciliation. ~8 models, and he knows it. Level is summed from **transactions, not lots**. |
| **A meal** | **Several recipes per meal.** Tuesday dinner is a main plus sides, scaled together for whoever is eating. Costs the `MealRecipe` join; he picked it over one-recipe-per-slot. |
| **Photos** | **None, anywhere.** Not on recipes, not on steps. Do not add `PhotosUI`, an asset folder, or an image property "for later". |
| **Units** | Per-ingredient, per-context. See the catalogue section. |

### Where recipes come from, and why it shapes the schema

His pipeline, in his words: *"I have claude create the pdf and drop to you to
add."* So a recipe is authored in conversation, he edits it, and the PDF is
dropped into a Claude Code session, where `scripts/import_recipe.py` parses it
and the result is committed as a bundled resource.

That makes recipes **immutable bundled content**, not user-entered rows — the
same split as his CFAL3 repo, which separates `Models/Content/` (JSON loaded at
launch) from `Models/Persistence/` (SwiftData):

- **Recipes live in `KitchenAid/Resources/Recipes/*.json`**, loaded at launch by
  a `RecipeLoader` service. They are read-only at runtime.
- **Everything the user does lives in SwiftData**: the meal plan, who ate,
  the pantry, shopping lists, last-made dates, and his tweaks and notes.
- **Tweaks are an overlay**, keyed by recipe id, exactly as `LOSStudyStatus`
  overlays `LOS` content in CFAL3. A tweak never mutates the bundled recipe.

The cost, which is real and he has been told: **a new recipe needs a rebuild**,
and family phones do not get it until they reinstall. The model is deliberately
arranged so a runtime importer (paste, or open a file) can be added later
without reshaping anything — it would load into the same in-memory recipe type.

## Read this first: nothing here was ever compiled

Most of this codebase was written in a **Linux cloud container with no Apple
toolchain**. There is no `swiftc`, no `xcodebuild`, no simulator. Swift that has
been reviewed is not Swift that has been compiled.

Consequences for anyone working here:

- If you are in a cloud session, **you cannot verify Swift changes**. Say so
  plainly rather than implying a change is known-good. Do not claim a build
  passes.
- If you are on Brandon's Mac, **build first, before anything else**, and fix
  what falls out.
- A build error is rarely alone. The same mistaken assumption about an API is
  usually repeated across several files, so when one appears, grep for the
  pattern rather than fixing the one line.

## Hard platform constraints

| | |
|---|---|
| Frameworks | SwiftUI + SwiftData. No third-party packages. |
| Deployment target | **iOS 17.0**. Anything needing 18+ must be `@available`-gated or not used. |
| Swift version | 5.0 (`SWIFT_VERSION = 5.0`) |
| Devices | Universal, `TARGETED_DEVICE_FAMILY = "1,2"`, iPhone-first in layout |
| Bundle id | `com.brandonkeeny.KitchenAid` |
| Team | `HHSFT2GD2H` |
| Backend | **None.** No server, no API keys, no network calls. |
| Distribution | Never published. Sideloaded / TestFlight internal, family only. |

## CloudKit-readiness rules — follow these even though CloudKit is off

Family sharing of *data* is a likely future ask, and turning on SwiftData's
CloudKit backing later must not require reshaping the store. These rules cost
nothing now and a migration later, so they are not negotiable:

1. **No `@Attribute(.unique)` anywhere.** CloudKit-backed stores reject it.
   De-duplicate ingredients in code, not with a constraint.
2. **Every non-optional property has a default value.**
3. **Every relationship is optional**, and every to-many has an explicit
   `inverse:`.
4. Be deliberate about `.cascade` vs `.nullify`. A cascade that reaches a
   shared, reusable recipe will silently delete it.

If you add a model and cannot satisfy these, stop and say why rather than
quietly using `.unique`.

## The fixture is ground truth

`docs/fixture-recipe-01.txt` is Brandon's first real recipe — NY Strip Crostini
with Creamed Horseradish Spinach. `docs/REQUIREMENTS_FROM_FIXTURE.md` lists the
twelve things it proves about the schema, each with the evidence that forces it.

Two are counterintuitive and get re-broken often:

- **Ingredients are grouped into components; steps are flat.** The document has
  three ingredient groups and one numbered method that moves between them. A
  component is *not* a mini-recipe with its own steps.
- **A single recipe aggregates against itself.** Butter appears as 1 tbsp in two
  components; kosher salt as 1 tsp + 1/4 tsp. A shopping list built from this one
  recipe must already merge them.

Quantities are **exact rationals**, never `Double`. Scaling 1/3 cup by 3 has to
give exactly 1 cup.

## The shipped ingredient catalogue

`KitchenAid/Resources/ingredients.json` ships with the app and is loaded on
first launch. It exists for one reason: **adding something must be picking, not
typing.** Brandon is not going to populate a few hundred ingredients by hand,
and an app that asks him to is an app he stops opening.

```bash
python3 -I scripts/build_catalogue.py   # regenerate the JSON
python3 -I scripts/test_catalogue.py    # rebuild + check it
```

Never hand-edit `ingredients.json` — edit `scripts/build_catalogue.py` and
regenerate, or the next build silently reverts the change.

Each entry carries `name`, `aisle` (orders the shopping list the way you walk a
store), `dimension` (mass/volume/count — decides what can be added to what),
`unit`, `staple`, and `aliases`.

Two rules the tests enforce:

- **No ambiguous lookups.** A name or alias resolving to two purchases makes the
  pantry match whichever comes first. The build script fails on collisions; it
  already caught `coriander`, which is the herb in British usage and the dried
  seed in American. Only `fresh coriander` maps to cilantro.
- **Recipe 01 must be fully covered.** All 16 of its ingredients have to resolve
  and land in a sensible aisle. A catalogue that misses ingredients from the
  first real recipe is not doing its job.

**Staples** (salt, pepper, oils, vinegars, every spice) are tracked present or
absent with **no quantity**. Counting teaspoons of salt is work nobody does, and
a list that keeps asking for salt is a list you stop reading.

## Importer

Recipes in the ReportLab PDF layout go in via the importer rather than by hand:

```bash
pdftotext -layout recipe.pdf - | python3 -I scripts/import_recipe.py -
```

```bash
python3 -I scripts/test_import.py
```

The test asserts all twelve requirements against the fixture. **It runs
anywhere, including cloud sessions** — so if you touch the importer, run it.
It is the only automated check in this project that can actually execute.

## Layout and style

Mirrors the CFAL3 repo, which is Brandon's established convention:

```
KitchenAid/App/        @main App, root tab view, UITestMode
KitchenAid/Models/     @Model classes and value types
KitchenAid/Views/<Feature>/
KitchenAid/Services/   @Observable services
KitchenAid/Resources/
scripts/               Python importer + its test
docs/                  ARCHITECTURE.md, fixture, requirements
```

- `@Model final class` with an explicit `init` whose parameters all have defaults.
- `@Observable` services held as `@State` on the App, injected via
  `.environment(...)`. Not `ObservableObject`.
- The App's `ModelContainer` init falls back to an in-memory store on failure, so
  a migration the runtime declines to infer explains itself instead of crashing
  on every launch and locking the user out of their own data.
- **Comments explain why, not what**, and cite the bug that motivated them where
  there was one. Match the voice in `CFAL3/App/CFAL3App.swift`.

## Asked for, not yet built

Brandon asked for these after seeing the design, so they are intended, not
speculative:

- **Receipt scanning** to bulk-add to the pantry. On-device OCR via the Vision
  framework, no network. Receipt text is abbreviated (`GV CRM CHS 8Z`), so it
  matches against the catalogue and its aliases and asks about what it cannot
  place — once, then remembers.
- **Barcode scanning**, with a caveat that shapes the design: a barcode is only
  a number. Turning one into "heavy cream" needs a commercial product database,
  which means a subscription and a network call this app does not have. So the
  first scan of an item asks what it is and every later scan fills itself in.
  The kitchen becomes its own database. Do not design this as though a lookup
  service exists.

## Deliberately not in v1

CloudKit sync · runtime recipe import (paste or open a file — offered in v1 and
he chose to defer it, since he is in a build loop anyway; designed for, so it
drops in without reshaping anything) · leftovers tracking · nutrition data ·
a recipe authoring UI.

**Purchase-unit rounding is now IN v1**, not deferred: the panel specified a
two-pass count collapse (count→count first, so `clove → 1/10 head` and
`slice → 1/12 loaf`; then count→mass only if every noun shares a target). That
turns the fixture's "12 slices baguette" into "1 baguette" and garlic into
"need 1 3/10 heads, buy 2 heads". The mechanism is written, so the marginal
cost is low and it makes the core feature correct rather than merely working.

Several of these are *designed for* without being built. Check
`docs/ARCHITECTURE.md` before assuming one needs a migration.

## Declined, not deferred

Brandon was offered these and said no. Do not build them, and do not leave
hooks for them:

- **Photos** of any kind.
- **A cooking journal** — ratings, notes-per-cook, "how did it go". Only the
  last-made date is kept.
- **Dietary restrictions and allergy warnings** per household member.
- **Web-link recipe import** and **cookbook-photo OCR**. Receipt OCR for the
  pantry is still wanted; recipe OCR is not.
