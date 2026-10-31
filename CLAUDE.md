# KitchenAid

A personal iOS app for Brandon's cooking: recipes, a calendar meal plan, who is
eating each meal, a shopping list generated from the plan, and a household food
inventory. Plus PDF export through the iOS share sheet.

This is a **long-running project**. Recipes and features get added continuously
as he cooks, usually one session at a time. Read this file and
`docs/ARCHITECTURE.md` before changing the model layer.

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

CloudKit sync · photo/OCR recipe import (receipts yes, recipes not yet) ·
nutrition data · unit conversion by ingredient density (so volume↔mass is
refused, not guessed — same-dimension conversion like tbsp↔ml does work) ·
purchase-unit rounding ("1 baguette" instead of "12 slices") · leftovers
tracking.

Several of these are *designed for* without being built. Check
`docs/ARCHITECTURE.md` before assuming one needs a migration.
