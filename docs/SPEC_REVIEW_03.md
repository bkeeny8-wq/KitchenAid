# Spec review 03 — after the cut, and the last document-level round

Purchase-unit rounding was cut cleanly: −554 lines, 21 models, and zero
orphaned symbols. All seven surviving defects from review 02 were fixed. Three
rounds of review are now behind this document.

**11 findings remain** (3 regressions, 2 blocking, plus 8 minor). `readyToImplement: false`.

## These get fixed in the Swift, not in the document

The trend is clear — 12 blocking-or-regression findings after round 2, 5 after
round 3 — but so is the diminishing return. The next step transcribes §2 and §3
into real Swift files, and that is where these defects actually matter. Fixing
the prose first and the code second would mean fixing each one twice.

So the document is now the **design of record, not the contract**. Where the
code and this document disagree, the code wins. Each finding below is carried
into the build brief instead.

The two that would otherwise have cost build errors:

- **`CodingKeys` with cases matching no stored property, in four content
  types.** Swift validates the derived `Codable` conformance against the stored
  properties, so an extra case fails the derivation outright. The fix is a
  second private key enum for the importer's alternate spellings, keeping
  `CodingKeys` one-to-one so the encoder stays synthesized.
- **`Rational.init?(string:)` traps on `Int.min`** via unary minus and an
  unchecked multiply — the exact shape the file's own header comment claims was
  removed from the other initializer. Round 1 found it in `init(_:_:)`; it was
  fixed there and left here.

Two more worth keeping in view because they are behavioural, not syntactic:

- **A staple diverts a line after the status ladder has run**, so the flour
  example that is supposed to show a bridge warning is routed into the staples
  block instead. Flour really is a staple in the shipped catalogue, so this
  fires on real data.
- **`conversionNote` interpolates an exact rational**, so the butter case's
  note renders as "23 1111/1135 tsp". Correct, and unreadable.

---

### 1. [blocking] §2.0 / §2.1 / §2.2 / §2.3 / §2.4 (docs/ARCHITECTURE.md lines 823, 949, 1073-1074, 1203)

**Problem.** The four content types that implement §2.0's "accept the importer's spelling" rule declare extra `CodingKeys` cases that match no stored property, while relying on the *synthesized* `encode(to:)`. Swift's derived Codable conformance validates that the `CodingKeys` enum is a one-to-one match with the type's stored properties; an unmatched case fails the derivation with "CodingKey case 'X' does not match any stored properties" and "type 'X' does not conform to protocol 'Encodable'". Each of these types declares `Codable` (so Encodable must be derived) and supplies only `init(from:)`, so the Encodable half is synthesized and hits the check. §2.1 `struct Recipe: Codable, Identifiable, Hashable, Sendable`: ``` enum CodingKeys: String, CodingKey { case id, title, subtitle, summary case servingsNumerator, servingsDenominator /// The importer's spelling: a single whole number (§2.0). case servings ``` `servings` is a computed property in `extension Recipe`, not a stored one, so it is extraneous. §2.2 `struct RecipeComponent: Codable, Hashable, Sendable`: ``` /// The importer's spelling for `title` (§2.0). case name ``` §2.3 `struct IngredientLine: Codable, Identifiable, Hashable, Sendable` — seven extraneous cases: ``` case name, raw, qualifier, unit case hasQuantity, amountNumerator, amountDenominator ``` §2.4 `struct RecipeStep: Codable, Identifiable, Hashable, Sendable`: ``` /// The importer's spelling for `number` (§2.0). case order ``` This is one mistaken assumption repeated across four files, which is exactly the pattern `CLAUDE.md` says to grep for rather than fix one line of. The three types whose `CodingKeys` *are* one-to-one (`RecipeNote`, `RecipeTag`, `CatalogFile`, `CatalogEntry`, `RecipeFile`) are unaffected, and `Rational` is unaffected because it hand-writes both halves.

**Fix.** Either (a) move the importer-alternate spellings out of `CodingKeys` into a second, private key enum read through its own container, keeping `CodingKeys` one-to-one so the encoder still synthesizes — e.g. in `IngredientLine`: ```swift private enum ImporterKeys: String, CodingKey { case name, raw, qualifier, unit case hasQuantity, amountNumerator, amountDenominator } ... let c = try decoder.container(keyedBy: CodingKeys.self) let ic = try decoder.container(keyedBy: ImporterKeys.self) self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ic.decodeIfPresent(String.self, forKey: .name) ?? "" ``` — or (b) add an explicit `encode(to:)` to each of the four types writing only the canonical keys, which stops all derivation and makes the extra cases legal. Option (a) is preferable because it keeps the encoder synthesized and keeps the one-to-one invariant that the next content type will also need. Whichever is chosen, add a sentence to §2.0 stating it, since §2.0 is the rule the next content type will be written from.

### 2. [blocking] §2.23 ShoppingList (docs/ARCHITECTURE.md:3081, :3123, :3146) + §4.1 ShoppingListBuilder.Options (:5652)

**Problem.** The cut left `roundToPurchaseUnits` behind as a live option for the feature that no longer exists. It is declared as a stored SwiftData property on `ShoppingList` (`var roundToPurchaseUnits: Bool = true`, :3081), as an `init` parameter (:3123) and as an `init` assignment (:3146), and as `ShoppingListBuilder.Options.roundToPurchaseUnits` (:5652). Nothing in the document reads it: the only four occurrences of the identifier are those declarations. §4.2 step 9 now writes `purchase` as an unconditional copy of `toBuy`, so there is no code path a `true` or a `false` can change. This is the exact defect the document already deleted once — three lines below the orphan, §4.1's own comment on the removed `includeCoveredLines` says "An option nothing honours and `ShoppingList` cannot freeze is worse than no option: it reads as a promise the builder never made." Here it is worse, because `ShoppingList` DOES freeze it: the dead flag ships in `KitchenAidSchemaV1`, so removing it after the first build is a store migration rather than an edit.

**Fix.** Delete all four declarations: the stored property, `init` parameter and `init` assignment on `ShoppingList` (§2.23), and the field on `ShoppingListBuilder.Options` (§4.1). §2.23's frozen-options comment ("This is the WHOLE of `ShoppingListBuilder.Options` minus range/slots/expandedLineIDs and minus now") stays true after both deletions, so it needs no edit. Do it before the first `git add` of §2 — after the first build it is a migration.

### 3. [important — REGRESSION] §4.2 step 7 (docs/ARCHITECTURE.md:5991-6005) vs step 6's status ladder (:5961-5983), §2.23 `needsAttention`/`staplesFooter` (:3175-3179), §4.3(b) (:6121-6124), KitchenAid/Resources/ingredients.json

**Problem.** Step 7 reassigns `status = .staple` for any `trackingMode == .staple` item, unconditionally and after step 6's explicitly ordered "first match wins" ladder, and nothing states which wins. The shipped catalogue marks `all-purpose flour` (plus granulated/brown sugar, cornstarch, baking powder/soda, honey, ketchup, mayonnaise, soy sauce, every vinegar and oil — 87 staples, 23 of them outside Spices) `staple: true`, so the flour line §4.3(b) prints as `status = .needsBridge` is diverted to the collapsed "Staples (not checked)" footer instead. `ShoppingList.needsAttention` (:3177-3179) filters on `statusRaw`, not on `flagsBlob`, so the line carrying `.needsBridge` can never reach the pinned "Needs attention" block and the one-tap "1 cup = ___ g" affordance is unreachable for it — which is exactly the reachability SPEC_REVIEW_02 finding 4 was applied to restore. Step 7 also does not clear `isCovered`, so a staple that step 6 covered is rendered twice, once in `coveredFooter` and once in `staplesFooter` (:3175-3176).

**Fix.** In step 7, state the precedence as a decision: divert to the staples footer only when the line's flags carry neither `.needsBridge` nor `.unresolvedItem` (a staple whose density is missing is still a one-tap fix and must stay visible), and set `isCovered = false` when diverting so footer membership is exclusive. Alternatively keep step 6's status and add `DraftLine.isStaple` / `ShoppingListLine.isStaple`, making `staplesFooter` filter on that Bool so status and footer membership stop competing for one field. Either way say in step 7 which of `.staple` and `.needsBridge` wins, the way step 6 now does for `.needsBridge` vs `.partiallyHave`.

### 4. [important — REGRESSION] §4.1 `Options.roundToPurchaseUnits` (docs/ARCHITECTURE.md:5652) and §2.23 `ShoppingList` (:3081, :3123, :3146)

**Problem.** Purchase-unit rounding is cut, but the option survived the cut in three places and still defaults to `true`, while step 9 (:6024-6031) unconditionally copies each `toBuy` row into `purchase`. So the flag has no reader anywhere in the document and is frozen onto every persisted list as `true` — a stored list that records "rounded to purchase units: yes" about a list that was shopped by the exact need. §4.1's own comment on `includeCoveredLines` (:5653-5658) rules out exactly this shape: "An option nothing honours and `ShoppingList` cannot freeze is worse than no option: it reads as a promise the builder never made." Here `ShoppingList` does freeze it, which is worse again, and the §2.23 comment above it claims the frozen block is "the WHOLE of `ShoppingListBuilder.Options`" minus a named list that does not mention this field.

**Fix.** Delete `roundToPurchaseUnits` from `Options` (:5652) and from `ShoppingList`'s stored properties, `init` parameters and `init` body (:3081, :3123, :3146). Nothing is implemented yet, so removing a stored property now is free where removing it after the first build is a migration. If it is kept deliberately as a reserved field, default it to `false` and say in one line that it is unread in v1 and that `purchase == toBuy` regardless — a reserved flag defaulted `true` is the one spelling that cannot be right.

### 5. [minor — REGRESSION] §2 intro (docs/ARCHITECTURE.md:650–656) vs §1 `Models/Content/` (:364–377)

**Problem.** Count drift created by applying SPEC_REVIEW_02 finding 12. The intro enumerates "6 content value types" plus "the six other value types the manifest also places under `Models/Content/`: `RecipeFile`, `CatalogEntry`, `CatalogFile`, `ContentDiagnostic`, `ResolvedRecipe` and its nested `ResolvedRecipe.LapsedOverride`", then asserts "The §1 `Models/Content/` folder listing enumerates the same twelve." It no longer does: finding 12's fix added "**and its nested `Kind`**" to the `ContentDiagnostic.swift` row, so the folder listing now names thirteen types. The intro's list counts one nested type (`LapsedOverride`) and omits the other (`ContentDiagnostic.Kind`), which is the inconsistency, not the arithmetic.

**Fix.** Add `ContentDiagnostic.Kind` to the intro's second list and change "six other value types" / "the same twelve" to seven and thirteen. The two nested types are then treated alike and §1 and §2 agree again.

### 6. [important] §3.1 `Rational.init?(string:)` (docs/ARCHITECTURE.md line 4000)

**Problem.** The mixed-number branch does three unchecked integer operations and can trap, in the one initializer whose own file comment promises it will not: ```swift guard frac.count == 2, let n = Int(frac[0]), let d = Int(frac[1]), d != 0 else { return nil } self.init(whole * d + (whole < 0 ? -n : n), d) ``` `-n` traps when `n == Int.min` and `whole < 0` — the exact `Int.min`-plus-unary-minus shape §3.1's long header comment says was removed from `init(_:_:)`. `whole * d` traps on multiplication overflow, and the `+` traps on addition overflow. This is reachable from committed content, not just from code: `Rational.init(from:)` routes a bare string through here — ```swift if let s = try? single.decode(String.self), let parsed = Rational(string: s) { ``` — so a hand-authored `"amount": "-1 -9223372036854775808/3"` or `"amount": "4611686018427387904 1/2"` in `Resources/Recipes/*.json` crashes the loader instead of degrading. That directly contradicts the file's stated contract ("A typo in a committed recipe file must degrade, not crash") and the claim that `Rational` is total on `Int.min`. `init(_:_:)` itself is clean — its `guard n != .min, d != .min` holds, and both reporting operators correctly treat an `Int.min` `partialValue` as an overflow and return `(.zero, true)`, so no operator hands `Int.min` onward; this string parser is the one remaining hole.

**Fix.** Use the reporting operators and fail the initializer rather than trapping, e.g.: ```swift guard frac.count == 2, let n = Int(frac[0]), let d = Int(frac[1]), d != 0, n != .min, d != .min, whole != .min else { return nil } let (scaled, o1) = whole.multipliedReportingOverflow(by: d) let (total, o2) = scaled.addingReportingOverflow(whole < 0 ? -n : n) guard !o1, !o2 else { return nil } self.init(total, d) ``` Returning nil is correct here: the caller in `init(from:)` already falls through to the keyed-container path, and `RecipeLoader` records a `ContentDiagnostic` for a file it cannot decode. Add the case to `RationalTests` beside the two existing `Int.min` cases, which do not cover this entry point.

### 7. [important] §4.3(b) "With `gramsPerCup = 120`" (docs/ARCHITECTURE.md:6131-6141) vs §3.6 `collapseAcrossDimensions` (:4580-4606) and §0.3's mint rule (:139-141)

**Problem.** The worked example asserts the volume+mass flour buckets collapse to `320 g` with the note "1 cup counted as 120 g at 120 g per cup". That is the `item.preferredDimension == .mass` branch, but `all-purpose flour` ships `"dimension": "volume"` and §0.3 says the mint copies the template's `dimension` onto the row, so `preferredDimension` is `.volume` and the else branch runs: `total = 48 + 200/(120/48) = 128` tsp, `displayUnit` with hint `cup` gives `128/48 = 8/3` (denominator 3 ≤ 8) → **"2 2/3 cups"**, with the volume-branch note instead. §4.3 is written as the test oracle ("the test written first"), so an implementer transcribing this case writes an assertion the specified code fails. The catalogue's `bakingUnit` — `"g"` for flour, the one field that would justify a mass preference — is decoded in §2.6 (:1382, :1401) and read by nothing in the document.

**Fix.** Pick one and write it down: either state in §0.3/§5.3 that the mint sets `preferredDimensionRaw` from `entry.bakingUnit`'s dimension when `bakingUnit` is non-null and from `entry.dimension` otherwise (which gives flour `.mass`, makes §4.3(b) correct as printed, and gives `bakingUnit` its first reader), or rewrite §4.3(b)'s with-density block to the volume answer — `128 tsp → 2 2/3 cups`, note "200 g counted as 80 tsp at 120 g per cup" — and keep the mint copying `dimension` only.

### 8. [important] §3.6 `conversionNote` interpolations (docs/ARCHITECTURE.md:4591, :4603, :4657, :4667) vs §4.3(b) (:6137), §4.3(b′) (:6157-6163) and §2.25 (:3365-3366)

**Problem.** Every `conversionNote` is built by interpolating a raw base-unit `Rational` through `mixedDescription`, which prints the exact fraction and never approximates, so the notes the document quotes cannot be produced and case 4's note is unreadable. Traced for the fixture's butter against a 4 oz lot: `bridgeHave` (:4657) yields `567/5 ÷ 227/48 = 27216/1135` and the note renders "113 2/5 g on hand counted as 23 1111/1135 tsp at 227 g per cup" — a 1135-denominator fraction on the line §4.3(b′) says he sees collapsed under "Already have", in tsp while the subtotal beside it displays tbsp. Likewise §4.3(b) quotes "1 cup counted as 120 g" but :4591 renders the volume side as `Quantity(amount: volume.base, unit: UnitCatalog.teaspoon).displayString()`, whose hint is tsp and `48 ∈ [1/4, 64)`, so rule (a) returns tsp → "48 tsp counted as 120 g"; and §2.25's stored example "200 g counted as 1 2/3 cups" cannot occur because the volume branch (:4603) always prints tsp → "200 g counted as 80 tsp". `isApproximateDisplay` governs the number but nothing governs the sentence printed next to it.

**Fix.** Build both halves of every note through the display ladder rather than from base units: render each side as `Quantity(amount: base / unit.baseFactor, unit: unit).displayString(system:)` using the subtotal's own `preferredUnit` (the bridged subtotal already carries one from the `displayUnit` call two lines above), and apply the same `rounded(toDenominator: 8)` + "≈" rule §3.4:4296-4297 uses, so the butter note reads "≈ 3 3/4 oz on hand counted as ≈ 8 tbsp at 227 g per cup". Then correct the three quoted notes in §4.3(b), §4.3(b′) and §2.25 to whatever the chosen spelling produces.

### 9. [important] §4.2 step 9 (docs/ARCHITECTURE.md:6024-6047), §4.1 `DraftLine` (:5684-5699), §2.23 `orderedLines` (:3157-3161), §2.24 `sortIndex` (:3223)

**Problem.** "Alphabetical within a section" has no writer and no stated collation, so the finished list's within-section order is not the order the document claims. `DraftLine` declares no `sortIndex`, nothing in steps 9-10 writes `ShoppingListLine.sortIndex`, and its default is `0`, so every line in a section ties and `orderedLines` falls through to `$0.displayName` compared with raw Swift `String <`, which is Unicode-scalar ordering. The fixture at 4 eaters makes it visible: Dairy renders "Parmesan, butter, cream cheese, heavy cream" because 'P' (U+0050) sorts before 'b' (U+0062), and Butcher's "NY strip steak" sorts ahead of any lowercase neighbour. Section ORDER itself is fine — `aisleOrder` is read, not copied, and the fixture's seven aisles come out Produce, Bakery, Butcher, Dairy, Condiments, Beverages.

**Fix.** In step 9, say that lines within a section are ordered by `localizedStandardCompare` on `displayName` (or by `NameNormalizer.matchKey`, :5185, which already lowercases) and that `materialize` writes `ShoppingListLine.sortIndex` from that position; add `sortIndex: Int` to `DraftLine` so the draft carries the order the preview sheet already shows. Then change §2.23's `orderedLines` tiebreak to the same comparison so a stored list re-sorts identically.

### 10. [important] §0.3 (docs/ARCHITECTURE.md:148)

**Problem.** A factual claim about the schema that the cut invalidated, inside the paragraph that defines the mint. The sentence reads "`FoodItem` has no unit field, the two unit fields it does have mean other things (`parLevelUnitCode` is the par level's unit)". `FoodItem` (§2.12, :1757–1935) now has exactly ONE unit-bearing property, `parLevelUnitCode` — the second was `purchasePackUnitCode`, removed with purchase-unit rounding. The parenthetical names only one field, so the sentence contradicts itself in its own clause, and §5.3's parallel sentence (:6419) is already correctly singular ("landing it in `parLevelUnitCode` would give that field a second meaning"). An implementer following §0.3 goes looking for a second unit field on `FoodItem` and does not find it.

**Fix.** Rewrite as "`FoodItem` has no unit field — the one unit-bearing property it does have, `parLevelUnitCode`, is the par level's unit, and inventing a second meaning for it is worse than reading the template live". That also makes it match §5.3 word for word.

### 11. [important] §4.2 "The trip home" (docs/ARCHITECTURE.md:6060) vs §5.4 (:6532)

**Problem.** Half-applied signature spelling, the failure shape SPEC_REVIEW_02 finding 6 raised for `level` and that was fixed there but not here. §4.2 writes `InventoryLedger.receive(list:)`; §5.4 declares `func receive(_ list: ShoppingList, in context: ModelContext) throws`, i.e. `receive(_:in:)`. The call-site spelling invents a `list:` label the declaration does not have and drops the non-defaulted `in:` the declaration requires, so neither label survives contact with the declaration. The §1 manifest row (:480) names it bare as `receive`, so §4.2 is the only place a reader sees labels for it, and they are both wrong.

**Fix.** Write `InventoryLedger.receive(_:in:)` at :6060, matching §5.4's declaration verbatim — the same correction already applied to `level(of:in:includeExpired:asOf:graceEnd:)` at :5930.

