# Code review 02 — receipt and barcode scanning

Review of the scanning layer: one `@Model`, four services, six screens, 27 tests, about
3,000 lines. Two adversarial lenses — compile-correctness, and behaviour-and-constraint —
over work split so the pure logic landed before any camera touched it.

**Four blocking, five important, eight minor.** All four blocking are fixed.

## The lesson, which is worth more than the findings

**The author's own verification was not a verification.**

The agent that wrote the matcher did the right thing by any normal standard: it ported its
own `read()` and `candidates()` to Python, ran them over the real shipped 670-entry
catalogue, swept 67 realistic receipt lines, and reported **zero confident-and-wrong
matches**. It wrote that number into its summary and I believed it, because it was not a
claim from reading the diff — it was a claim from executing the algorithm against real
data, which is exactly the kind of evidence this project has learned to ask for.

The independent verifier ported the same functions from the Swift — not from the
description — swept ~190 lines, and found five confident-and-wrong matches:

| line | confident answer | should have been |
|---|---|---|
| `CHS 3.99`, `CHS 8Z` | **chives** at 94 | a cheese (all five sit at 77) |
| `CHOC MLK QT` | **milk chocolate** at 83 | chocolate milk |
| `PASTA SCE 24Z` | **pasta** at 80 | pasta sauce |
| `APPLE SCE 24Z` | **apple** at 80 | apple sauce |
| `SPRING WATER 1 GAL` | **sparkling water** at 97 | spring water |

Both agents ran a sweep. One found nothing and one found five. The difference was not
effort or honesty — it was **which lines they thought to try**, and an author picks the
lines its own algorithm was designed around. 67 cases chosen by the author found nothing;
190 chosen by an adversary found the floor of the scoring function.

So: a self-sweep is a smoke test. It establishes the thing works at all. It cannot
establish the thing does not fail, because the author chooses the inputs.

## The four blocking defects

**1. "The first scan asks, every later one fills itself in" failed for every catalogue
pick.** A late guard decided newness from `previous.item?.id != row.item?.id`, but
`BarcodeScanRow.item` only matches `case .item`, and the headline path — an unknown number
resolved by picking a catalogue entry — produces `.entry`, which has no `FoodItem` yet by
construction. So `nil != nil` was false, `remember` never ran, nothing reached
`FoodItemBarcode`, the row never became ready, and the next scan of the same tin asked
again. The one promise this feature cannot break.

**2. Confident-and-wrong matches, two proven root causes.**
`score(tokenCoverage: 50, nameCoverage: 100, strength: 100)` equals `confidentScore`
**exactly**, so any two-word line where one word is a whole single-word entry is confident
*by construction* whenever the runner-up trails by the gap. And the 70-point subsequence
tier on a fully covered short name outscores a half-covered correct multi-word name:
`chs` is a subsequence of `chives`, `spring` of `sparkling`.

What they share is the real lesson: in every case the identity-bearing head noun
(`cheese`, `sauce`, `chocolate milk`, `spring water`) **has no catalogue entry at all**, so
the only survivor wins outright instead of being asked about. The matcher has to be safe
against a catalogue that does not contain the answer.

**3. A price-per-pound read as a weight.** `BANANAS 0.59 LB 1.27 F` — the 0.59 is dollars
per pound. It became a 0.59 lb size, confident on the food, wrong on the amount, and the
row pre-filled a lot to write. True weight is 1.27 ÷ 0.59 ≈ 2.15 lb. This fires on all
weighed produce, meat, deli and seafood, which is most of a real receipt.

It passes the letter of "never invent a quantity" — the number *is* printed on the paper —
while breaking precisely what that rule exists for. A rule obeyed to the letter and
defeated in substance is worth more attention than a rule simply broken.

**4. A confident match became a permanent alias with no way out.** On confirm, every
`.entry` draft called `learn`, including drafts whose answer came from the matcher's own
proposal. One wrong confident match wrote the receipt's wording as a `FoodItemAlias` on the
wrong food — after which `resolve` answers that token from *his own aliases* at step 2,
ahead of the shipped catalogue, for ever. `addAlias` had no counterpart anywhere in the
app, so the only escape was deleting the `FoodItem` with its lots and history.

Defects 2 and 4 together are the dangerous pair: the first produces a wrong answer and the
second makes it permanent. Either alone is a nuisance.

## What held up

The two constraints that would have been hardest to get right were both genuinely right,
and the verifier could not break either.

- **No image is ever stored.** Verified by grep over the whole tree rather than by reading
  comments: `PhotosUI`, `UIImage`, `CGImage`, `jpegData`, `CVPixelBuffer`, `PHPicker`,
  `UIImagePickerController` and `VNDocumentCamera*` appear in exactly two places — comments
  saying why they are absent, and the allow/deny lists in `check_swift.py`. No `@Model`
  anywhere has a `Data` or `[UInt8]` property, so **the schema cannot hold a frame whatever
  a later call site does**. `DataScannerViewController` was chosen precisely because it
  returns text and barcodes and never pixels.
- **No network.** The only `URL` in the scanning layer is
  `UIApplication.openSettingsURLString`. No lookup client, no cached product payload, no
  placeholder field for one. A barcode resolves through the table he filled or not at all.

The deny-list in `check_swift.py` is the part worth keeping: adding any picture-returning
API now **fails the checker**, which forces a conversation instead of allowing a quiet
regression.

## One finding was wrong

The review reported a missing `import Vision` for `VNRecognizeTextRequest`. It occurs once,
in a doc comment explaining what was deliberately *not* done. Checked before acting.
Recorded because a review's findings are evidence, not verdicts — the same standard this
document applies to the author's sweep.

## Still open

1. `matchKey` singularizes only the LAST word, so `EGGS LG DOZ`, `CARROTS 2LB BAG` and most
   bagged produce return **zero candidates**. Fails safe — it asks — but he answers by hand
   every time until `learn` covers each spelling.
2. A bare unit word with no number is swallowed into the name, so `365 WHL MILK GAL` reads
   **no size** for a gallon of milk, and the stray word costs coverage twice over.
3. `testAnAmbiguousTokenReturnsMoreThanOneCandidate` passes for the wrong reason: it uses a
   13-entry stand-in with no `chives` in it, so it will go green on a Mac while the
   shipping behaviour is the opposite of what it claims to protect. Nothing in the test
   target exercises `candidates()` against the real catalogue, which is the only place
   these collisions live.
4. `BarcodeRegistry.repoint(from:to:in:)` has no caller: `FoodItemResolver.merge` repoints
   lots, transactions and shopping lines by walking inverse arrays and cannot see barcode
   rows, which use a string key.
5. `FoodItemBarcode` has **no relationship** to `FoodItem`, deliberately — a to-one with no
   `inverse:` is rejected by a CloudKit-backed store, and `FoodItem.swift` was outside the
   writing agent's file list, so it used the `InventoryTransaction` key-plus-snapshot
   pattern instead. Worth revisiting now that both files can be edited together.
6. **Nothing has been compiled, and the 27 tests have never run.** Every number in them was
   derived from a Python port of the algorithm rather than from Swift.
