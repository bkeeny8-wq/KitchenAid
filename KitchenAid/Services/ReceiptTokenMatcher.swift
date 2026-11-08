import Foundation

/// A line of receipt text in; a ranked set of catalogue candidates out, or nothing.
///
/// **Pure.** No SwiftData, no SwiftUI, no fetches, and no camera. It takes the catalogue as an
/// array of value types and an optional lookup closure, exactly as `ShoppingListBuilder` takes
/// values and closures the caller already holds, and for exactly the same reason: it is the
/// only way any of this can be exercised without a `ModelContainer`, and on this project
/// nothing can be compiled at all, so a layer that can carry real assertions is the only layer
/// that can be trusted. Everything that touches the store is in `ReceiptIntake`; everything
/// that touches the camera is in the view layer, and it should be thin enough to be obviously
/// right.
///
/// **No frame reaches this file and none is stored anywhere.** The input is a `String` the
/// text recognizer already produced. There is no image parameter, no `Data`, and no path to
/// one — a receipt is a photograph of his bank balance, and photos are declined everywhere in
/// this app (`CLAUDE.md`).
///
/// ## The shape of the problem
///
/// Receipt text is abbreviated, upper-case, and padded out with things that are not food:
///
///     GV CRM CHS 8Z            4.99 F
///     KS ORG CHKN BRST 2 LB   12.99
///     2 @ 3.50
///     BANANAS                  1.27 F
///     SUBTOTAL                42.17
///     VISA DEBIT **** 1234
///     1234 MAIN ST
///
/// `GV CRM CHS 8Z` is Great Value cream cheese, 8 oz. Getting from there to the catalogue's
/// `cream cheese` needs four separate things, which is why `read(_:)` and `candidates(for:)`
/// are separate: one reads the ANATOMY of a line, the other matches what is left.
///
/// ## The rules, and why each one
///
/// 1. **A trailing price is stripped, and kept.** `4.99`, `$4.99`, `4.99 F`, `4.99-`. Kept
///    because `InventoryLedger.apply` already takes `priceCents`, so a scanned receipt can
///    record what he paid without a new field anywhere.
/// 2. **A size is read where one is written, and invented where it is not.** `8Z`, `2 LB`,
///    `12 CT`, `1.5 L`. A size the parser cannot read is ABSENT, never 1 — an invented
///    quantity is a wrong number in his pantry that nothing downstream can detect.
/// 3. **The size's unit is resolved per candidate, not here.** `8Z` is eight ounces, but
///    whether that is weight or fluid depends on the food: `UnitCatalog.unit(code:
///    fallbackDimension:)` already resolves exactly this ambiguity from the dimension, and
///    `CatalogEntry.dimension` is the dimension to hand it. So cream cheese gets 8 oz of mass
///    and almond milk gets 8 fl oz, from the same two characters.
/// 4. **A leading bare integer is a multiplier; a number followed by a unit is a size.** So
///    `12 CT EGGS` is a dozen eggs and `2 GV MLK` is two of them.
/// 5. **A store-brand prefix is dropped.** `GV`, `KS`, `365`. The list is deliberately tiny:
///    a word dropped wrongly is a word the match cannot use, and the recovery for a brand we
///    do not know is one alias he teaches the app once (`ReceiptIntake.learn`), which is
///    cheaper than a guessed list of fifty.
/// 6. **A run of five or more digits is a store code**, not a quantity and not a name. A
///    produce PLU and a UPC printed on the line both land here.
/// 7. **Vowel-dropped abbreviations match on a consonant skeleton or a subsequence.** `CRM`
///    is `cream` with its vowels gone; `CHKN` is `chicken` with four letters gone from the
///    middle. The skeleton is the stronger evidence and scores higher.
/// 8. **Lines that are not items at all are rejected with a named reason**, so the screen can
///    say why it skipped something instead of silently dropping a third of the receipt.
///
/// ## What it deliberately does not do
///
/// - It does not join a `2 @ 3.50` line to the line above it. That reading carries its
///   multiplier and price so a screen COULD, and nothing here guesses at the layout of a
///   receipt it has not seen.
/// - It does not stoplist a department header that happens to be one of the catalogue's own
///   aisle names (`DAIRY`, `PRODUCE`, `BAKERY`). Stoplisting them would mean a second copy of
///   the aisle list in this file, which is the kind of copy that drifts; `DAIRY` matches no
///   catalogue entry, so it comes back with no candidates and the screen offers nothing.
/// - It does not care about word order. `CHS CRM` matches `cream cheese`. Receipts are not
///   written to a grammar, and penalising disorder buys nothing.
struct ReceiptTokenMatcher {

    // MARK: - What a line was read as

    /// Why a line is not an item. Named rather than a Bool, because "skipped 14 lines" is a
    /// bug report and "skipped 14 lines: 9 totals, 3 payment, 2 department" is an explanation.
    enum Rejection: String, Codable, CaseIterable, Sendable {
        case blank
        /// Nothing but digits, punctuation and a price. A price-only line lands here.
        case noLetters
        /// SUBTOTAL, TAX, TOTAL, CHANGE, SAVINGS.
        case totals
        /// A card, an account, an approval code, a masked number.
        case payment
        /// GROCERY, DELI, HBA — a department header.
        case department
        /// A street address: leading digits and a street suffix.
        case address
        /// `2 @ 3.50` — a quantity-and-unit-price line belonging to the item above it.
        case quantityOnly
        /// Everything on the line was a price, a size or a store code. Nothing left to match.
        case noName

        var label: String {
            switch self {
            case .blank: return "Blank line"
            case .noLetters: return "No words"
            case .totals: return "Totals"
            case .payment: return "Payment"
            case .department: return "Department header"
            case .address: return "Store address"
            case .quantityOnly: return "Quantity line"
            case .noName: return "No item name"
            }
        }
    }

    /// The anatomy of one line. A value type with no behaviour beyond reading itself back, so
    /// a screen can show him what the app thought the line said before it shows him what it
    /// thought the line meant.
    struct Reading: Hashable, Sendable {
        var raw: String = ""
        var rejection: Rejection? = nil

        /// The store-brand word that was dropped, in the case the receipt printed it, or "".
        var brand: String = ""

        /// The name words in the receipt's own case — `"CRM CHS"`. This is what
        /// `ReceiptIntake.learn` stores as the alias, so his "same as…" list reads back what
        /// his receipt actually says.
        var nameDisplay: String = ""

        /// `NameNormalizer.matchKey(nameDisplay)`. What a lookup and a `#Predicate` arrive on,
        /// and what the word matching below works over.
        var nameKey: String = ""

        /// `nameKey` split on spaces.
        var nameWords: [String] = []

        /// The size printed on the line, with its unit left UNRESOLVED — see rule 3.
        /// nil means no size was written, never "one of them".
        var sizeAmount: Rational? = nil
        var sizeUnitCode: String = ""

        /// A leading count: `2 GV MLK`. nil means none was written.
        var multiplier: Int? = nil

        /// The trailing price in cents. nil means none was written.
        var priceCents: Int? = nil

        /// Store codes, tax flags and stray numbers, kept so a screen can show the line being
        /// taken apart rather than asking him to trust it.
        var droppedWords: [String] = []

        var isItemLine: Bool { rejection == nil }

        /// The size as a real `Quantity`, resolved against the dimension of whatever food this
        /// turns out to be. `UnitCatalog.unit(code:fallbackDimension:)` is what makes `oz`
        /// weight for cheese and fluid for milk; passing nil gets its default, which is weight.
        func size(preferring dimension: MeasureDimension?) -> Quantity? {
            guard let amount = sizeAmount, !sizeUnitCode.isEmpty,
                  let unit = UnitCatalog.unit(code: sizeUnitCode, fallbackDimension: dimension)
            else { return nil }
            return Quantity(amount: amount, unit: unit)
        }
    }

    // MARK: - What a line matched

    /// One catalogue entry this line might mean, and the arithmetic that put it there.
    ///
    /// The numbers are carried rather than discarded because the screen has to decide whether
    /// to ask him, and "92, two words of two, matched on `cream cheese`" is a decision it can
    /// make. No explicit `init`, so the memberwise one survives.
    struct Candidate: Hashable, Sendable {
        var entry: CatalogEntry
        /// 0...100. See `score(...)` for the formula and why it is weighted the way it is.
        var score: Int = 0
        var matchedWords: Int = 0
        /// How much of the receipt token was consumed, as a percentage.
        var tokenCoverage: Int = 0
        /// How much of the catalogue name was accounted for, as a percentage.
        var nameCoverage: Int = 0
        /// The average confidence of the individual word matches.
        var strength: Int = 0
        /// The catalogue name or alias that actually matched, so "why did it pick that" has an
        /// answer: `HVY WHIP CRM` matched `heavy cream` **via** `heavy whipping cream`.
        var matchedVia: String = ""
        /// The catalogue named this outright — an exact name or an exact shipped alias. There
        /// is nothing to ask about.
        var isExact: Bool = false
        /// The line's size, resolved against this entry's dimension. nil when the line wrote
        /// no size.
        var size: Quantity? = nil

        var name: String { entry.name }
    }

    /// A line, taken apart and matched.
    struct Match: Hashable, Sendable {
        var reading: Reading
        /// Ranked, best first. Empty means nothing in the catalogue came close enough.
        var candidates: [Candidate] = []

        var best: Candidate? { candidates.first }

        /// Whether the top candidate is clear enough to fill in without asking.
        ///
        /// Computed, never stored, so it cannot disagree with the candidates it describes. The
        /// test is deliberately strict in both directions: an exact catalogue name is always
        /// confident, and an abbreviation match has to be both strong AND clearly ahead of the
        /// runner-up. A confident wrong answer puts the wrong food in his pantry and he finds
        /// out in a supermarket; a question costs him one tap.
        var isConfident: Bool {
            guard let top = candidates.first else { return false }
            if top.isExact { return true }
            guard top.score >= ReceiptTokenMatcher.confidentScore else { return false }
            guard candidates.count > 1 else { return true }
            return top.score - candidates[1].score >= ReceiptTokenMatcher.confidentGap
        }

        /// What the screen asks about: it matched something, but not well enough to assume.
        var needsAnswer: Bool { reading.isItemLine && !isConfident }
    }

    // MARK: - Thresholds

    /// Below this a candidate is not offered at all. One word of three matching a two-word
    /// name lands around here, which is the floor of "worth showing him".
    static let minimumScore = 50
    /// A top candidate must reach this before the screen may skip the question.
    static let confidentScore = 80
    /// ...and be this far ahead of the runner-up.
    static let confidentGap = 15

    // MARK: - The index

    /// One matchable string: a catalogue name or one of its aliases, pre-split.
    ///
    /// Built once per matcher rather than per line. The catalogue ships 670 entries and 669
    /// aliases, so this is about 1,300 strings; rebuilding it for each of forty receipt lines
    /// is forty times the work for no gain. Hold the matcher for the length of a scan.
    private struct Indexed {
        let entry: CatalogEntry
        let text: String
        let words: [String]
        /// The first letter of every word. Every match tier below requires equal first
        /// letters, so this is a sound and very cheap rejection.
        let initials: Set<Character>
    }

    private let indexed: [Indexed]
    private let exactLookup: ((String) -> CatalogEntry?)?

    /// `entries` is `IngredientCatalog.all` in the app and a hand-built array in the tests.
    ///
    /// `exactLookup` is `IngredientCatalog.entry(matching:)` — name first, then shipped alias,
    /// both on `matchKey`. It is consulted BEFORE any abbreviation work, because the build
    /// script guarantees no two entries share a name or an alias, so an exact hit is
    /// unambiguous by construction and nothing cleverer can improve on it.
    init(entries: [CatalogEntry], exactLookup: ((String) -> CatalogEntry?)? = nil) {
        var rows: [Indexed] = []
        for entry in entries {
            for text in entry.allMatchKeys {
                let words = text.split(separator: " ").map(String.init)
                guard !words.isEmpty else { continue }
                var initials = Set<Character>()
                for word in words {
                    if let first = word.first { initials.insert(first) }
                }
                rows.append(Indexed(entry: entry, text: text, words: words, initials: initials))
            }
        }
        self.indexed = rows
        self.exactLookup = exactLookup
    }

    // MARK: - Reading a line

    /// Takes one line apart. Static, because the anatomy of a receipt line has nothing to do
    /// with what is in the catalogue.
    static func read(_ line: String) -> Reading {
        var reading = Reading(raw: line)

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reading.rejection = .blank
            return reading
        }

        // One pass: letters and digits survive, the handful of characters a receipt uses
        // structurally survive, everything else becomes a space. `@` is spaced out on both
        // sides so `2@3.50` and `2 @ 3.50` tokenize identically.
        var cleaned = ""
        for character in trimmed {
            if character.isLetter || character.isNumber {
                cleaned.append(character)
            } else if character == "@" {
                cleaned.append(" @ ")
            } else if character == "." || character == "/" || character == "$"
                        || character == "*" || character == "#" || character == "-" {
                cleaned.append(character)
            } else {
                cleaned.append(" ")
            }
        }

        let words = cleaned.split(separator: " ").map(String.init)
        let lowered = words.map { $0.lowercased() }
        guard !words.isEmpty else {
            reading.rejection = .blank
            return reading
        }

        // --- Whole-line rejections, in the order that costs the least to be wrong about.

        // `2 @ 3.50`. Read for its numbers anyway: a screen that wants to apply them to the
        // line above has them, and nothing here pretends to know that it should.
        if let at = lowered.firstIndex(of: "@") {
            if at > 0 { reading.multiplier = Int(words[at - 1]) }
            if at + 1 < words.count { reading.priceCents = moneyCents(words[at + 1]) }
            reading.rejection = .quantityOnly
            return reading
        }

        if words.contains(where: { $0.contains("*") })
            || lowered.contains(where: { paymentWords.contains($0) }) {
            reading.rejection = .payment
            return reading
        }

        if lowered.contains(where: { totalsWords.contains($0) }) {
            reading.rejection = .totals
            return reading
        }

        // Leading digits AND a street suffix at the END. The suffix has to be last, or
        // `2 LB ST LOUIS RIBS` is read as an address — which is a real cut of pork and would
        // have been dropped off every receipt with nothing saying so.
        if let first = lowered.first, let last = lowered.last,
           isAllDigits(first), streetWords.contains(last) {
            reading.rejection = .address
            return reading
        }

        let hasLetter = lowered.contains { word in word.contains { $0.isLetter } }
        if !hasLetter {
            reading.rejection = .noLetters
            return reading
        }

        // --- Word by word.

        var nameWords: [String] = []
        var dropped: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let lower = lowered[index]

            // A brand word is a name word for now; the first-position check happens below,
            // once it is known whether anything follows it. `365` would otherwise be eaten by
            // the bare-number rule.
            if brandPrefixes.contains(lower) {
                nameWords.append(word)
                index += 1
                continue
            }

            // A number and a unit, written apart: `2 LB`, `12 CT`, `1 GAL`. Checked before the
            // price rule so `2.34 LB` is a weight and not a price.
            if let amount = rational(fromNumber: lower), index + 1 < words.count,
               let code = sizeUnitCodes[lowered[index + 1]] {
                if reading.sizeAmount == nil {
                    reading.sizeAmount = amount
                    reading.sizeUnitCode = code
                } else {
                    dropped.append(word)
                    dropped.append(words[index + 1])
                }
                index += 2
                continue
            }

            // ...and written together: `8Z`, `64Z`, `16.9FZ`.
            if let split = numberAndSuffix(lower), let code = sizeUnitCodes[split.suffix],
               let amount = rational(fromNumber: split.number) {
                if reading.sizeAmount == nil {
                    reading.sizeAmount = amount
                    reading.sizeUnitCode = code
                } else {
                    dropped.append(word)
                }
                index += 1
                continue
            }

            if let cents = moneyCents(word) {
                // The LAST money-shaped word wins: a receipt that prints a unit price and a
                // line total prints the total last.
                reading.priceCents = cents
                dropped.append(word)
                index += 1
                continue
            }

            if isAllDigits(lower) {
                if lower.count >= 5 {
                    // A store code or a UPC printed on the line. Not a quantity and not a name.
                    dropped.append(word)
                } else if index == 0 && words.count > 1 {
                    reading.multiplier = Int(lower)
                } else {
                    // A trailing bare number is a weight, a code or a count we cannot place.
                    // Dropping it is the honest answer; see rule 2.
                    dropped.append(word)
                }
                index += 1
                continue
            }

            // A one-character word is a tax or department flag: `F`, `T`, `N`, `X`.
            if lower.count < 2 {
                dropped.append(word)
                index += 1
                continue
            }

            nameWords.append(word)
            index += 1
        }

        // The brand prefix, now that it is known whether a name follows it.
        if let first = nameWords.first, nameWords.count > 1,
           brandPrefixes.contains(first.lowercased()) {
            reading.brand = first
            nameWords.removeFirst()
        }

        if nameWords.count == 1, departmentWords.contains(nameWords[0].lowercased()) {
            reading.rejection = .department
            reading.droppedWords = dropped
            return reading
        }

        reading.droppedWords = dropped
        reading.nameDisplay = nameWords.joined(separator: " ")
        reading.nameKey = NameNormalizer.matchKey(reading.nameDisplay)
        reading.nameWords = reading.nameKey.split(separator: " ").map(String.init)

        if reading.nameWords.isEmpty {
            reading.rejection = .noName
        }
        return reading
    }

    // MARK: - Matching

    /// Read and match in one call, which is what a screen wants per line.
    func match(_ line: String, limit: Int = 5) -> Match {
        let reading = ReceiptTokenMatcher.read(line)
        return Match(reading: reading, candidates: candidates(for: reading, limit: limit))
    }

    /// Ranked candidates for an already-read line, best first.
    ///
    /// Several are returned wherever it is genuinely ambiguous. `CHS` is five cheeses and the
    /// honest answer is five cheeses: the screen is going to ask him, and a confident wrong
    /// answer is worse than a question.
    func candidates(for reading: Reading, limit: Int = 5) -> [Candidate] {
        guard reading.isItemLine, !reading.nameWords.isEmpty else { return [] }

        // The catalogue's own lookup first — name, then shipped alias, both on `matchKey`.
        if let lookup = exactLookup, let hit = lookup(reading.nameDisplay) {
            return [Candidate(
                entry: hit,
                score: 100,
                matchedWords: reading.nameWords.count,
                tokenCoverage: 100,
                nameCoverage: 100,
                strength: 100,
                matchedVia: hit.name,
                isExact: true,
                size: reading.size(preferring: hit.dimension)
            )]
        }

        let tokenWords = reading.nameWords
        let significant = tokenWords.filter { !ReceiptTokenMatcher.packWords.contains($0) }
        let significantCount = max(1, significant.count)
        var initials = Set<Character>()
        for word in tokenWords {
            if let first = word.first { initials.insert(first) }
        }

        // Best scoring string per ENTRY. `chicken breast` is reachable by its own name and by
        // the alias `boneless skinless chicken breast`, which scores lower for having two
        // words nothing matched; the entry must appear once, at its best.
        var bestByEntry: [String: Candidate] = [:]

        for row in indexed {
            guard !row.initials.isDisjoint(with: initials) else { continue }

            let aligned = ReceiptTokenMatcher.align(tokenWords, to: row.words)
            guard aligned.matched > 0 else { continue }

            var matchedSignificant = 0
            for position in aligned.positions
            where !ReceiptTokenMatcher.packWords.contains(tokenWords[position]) {
                matchedSignificant += 1
            }
            // At least one word that carries identity has to match. Without this, `ORG` alone
            // reaching `orange` by subsequence put oranges on a chicken line.
            guard matchedSignificant > 0 else { continue }

            let tokenCoverage = min(100, 100 * matchedSignificant / significantCount)
            guard tokenCoverage >= 50 else { continue }
            let nameCoverage = 100 * aligned.matched / max(1, row.words.count)
            let strength = aligned.points / aligned.matched
            let score = ReceiptTokenMatcher.score(
                tokenCoverage: tokenCoverage, nameCoverage: nameCoverage, strength: strength
            )
            guard score >= ReceiptTokenMatcher.minimumScore else { continue }

            let candidate = Candidate(
                entry: row.entry,
                score: score,
                matchedWords: aligned.matched,
                tokenCoverage: tokenCoverage,
                nameCoverage: nameCoverage,
                strength: strength,
                matchedVia: row.text,
                isExact: row.text == reading.nameKey,
                size: reading.size(preferring: row.entry.dimension)
            )
            if let existing = bestByEntry[row.entry.name], existing.score >= candidate.score {
                continue
            }
            bestByEntry[row.entry.name] = candidate
        }

        // Deterministic to the last tie-break. Two devices, two runs and a test all have to
        // agree on the order, or "the first one" means something different each time.
        let ranked = bestByEntry.values.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.matchedWords != b.matchedWords { return a.matchedWords > b.matchedWords }
            if a.nameCoverage != b.nameCoverage { return a.nameCoverage > b.nameCoverage }
            return a.entry.name < b.entry.name
        }
        return limit > 0 ? Array(ranked.prefix(limit)) : ranked
    }

    // MARK: - The scoring, written down

    /// `(2 × tokenCoverage + 2 × nameCoverage + strength) / 5`, all integers.
    ///
    /// Integers and not a `Double` — not because a score is a quantity, but because this
    /// codebase keeps floating point out of anything a decision is made on, and a ranking that
    /// is reproducible to the unit is one less thing to wonder about when a test disagrees.
    ///
    /// Why those weights:
    ///
    /// - **Token coverage** is what the brief asks for — how much of what the receipt said was
    ///   accounted for. `CRM CHS` against `cream cheese` consumes all of it.
    /// - **Name coverage** is weighted the same, and that is a fix rather than a preference.
    ///   At a lower weight `MLK` scored `milk` and `milk chocolate` thirteen points apart,
    ///   under the gap `isConfident` requires, so the one unambiguous reading in the dairy
    ///   aisle became a question. A candidate that uses all of its own name is stronger
    ///   evidence than one that uses half of it.
    /// - **Strength** breaks ties between tiers: two words matched on their consonant
    ///   skeletons beat two matched only as subsequences.
    static func score(tokenCoverage: Int, nameCoverage: Int, strength: Int) -> Int {
        (2 * tokenCoverage + 2 * nameCoverage + strength) / 5
    }

    /// Greedily aligns receipt words to catalogue words, each catalogue word used once.
    ///
    /// Greedy and not optimal: a true assignment would cost a matrix and a Hungarian pass to
    /// change the answer on a two-word grocery name approximately never. Order is ignored (see
    /// the note at the top).
    static func align(
        _ tokenWords: [String], to entryWords: [String]
    ) -> (points: Int, matched: Int, positions: [Int]) {
        var used = Array(repeating: false, count: entryWords.count)
        var points = 0
        var positions: [Int] = []

        for (position, token) in tokenWords.enumerated() {
            var bestPoints = 0
            var bestIndex = -1
            for (index, word) in entryWords.enumerated() where !used[index] {
                let scored = wordPoints(token, word)
                if scored > bestPoints {
                    bestPoints = scored
                    bestIndex = index
                }
            }
            if bestIndex >= 0 {
                used[bestIndex] = true
                points += bestPoints
                positions.append(position)
            }
        }
        return (points: points, matched: positions.count, positions: positions)
    }

    /// How much one receipt word is worth against one catalogue word. 0 = no match.
    ///
    /// **Every tier requires the same first letter**, which is what makes the index's
    /// `initials` rejection sound, and what keeps `BTR` off `butter`'s neighbours while
    /// `buttermilk` stays off `MLK`.
    ///
    /// The tiers, strongest first:
    ///
    /// - **100, equal.** After `NameNormalizer.matchKey`, so `BANANAS` is already `banana`.
    /// - **90, a prefix.** `CHOC` of `chocolate`. Three letters minimum: two-letter prefixes
    ///   match far too much.
    /// - **85, the consonant skeleton.** `CRM` is `cream`, `CHS` is `cheese`, `HVY` is
    ///   `heavy`, `MLK` is `milk`, `BF` is `beef`. This is the receipt convention and it is
    ///   strong evidence, so it outranks the catch-all below.
    /// - **70, a subsequence.** `CHKN` of `chicken`, `BRST` of `breast`, `BTR` of `butter` —
    ///   abbreviations that drop consonants too, which no skeleton rule can reach. It is the
    ///   loose tier on purpose and it scores like one: `CRM` is also a subsequence of
    ///   `cardamom`, which is exactly why cream cheese has to win on points rather than on
    ///   being asked first.
    static func wordPoints(_ token: String, _ word: String) -> Int {
        guard let tokenFirst = token.first, let wordFirst = word.first,
              tokenFirst == wordFirst
        else { return 0 }
        if token == word { return 100 }
        guard token.count >= 2 else { return 0 }
        if token.count >= 3, word.count > token.count, word.hasPrefix(token) { return 90 }
        if consonantSkeleton(word) == token { return 85 }
        if token.count >= 3, isSubsequence(token, of: word) { return 70 }
        return 0
    }

    /// First character always, then everything that is not a vowel. `cheese` -> `chs`.
    ///
    /// The first character survives even when it is a vowel, because an abbreviation keeps it:
    /// `apple` abbreviates to `APL`, never to `PL`. `y` is treated as a consonant, which is
    /// what makes `HVY` reach `heavy`.
    static func consonantSkeleton(_ word: String) -> String {
        guard let first = word.first else { return "" }
        var out = String(first)
        for character in word.dropFirst() where !vowels.contains(character) {
            out.append(character)
        }
        return out
    }

    /// Walked with `String.Index` rather than by slicing, so nothing depends on which
    /// `Substring` initializer exists — there is no compiler here to ask.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = needle.startIndex
        for character in haystack {
            if index == needle.endIndex { return true }
            if needle[index] == character { index = needle.index(after: index) }
        }
        return index == needle.endIndex
    }

    // MARK: - Number reading

    /// `"4.99"`, `"$4.99"`, `"4.99-"` -> 499. nil for anything without cents.
    ///
    /// Cents are required. A bare integer on a receipt line is a count, a weight or a store
    /// code far more often than it is a price, and reading one as money loses the quantity.
    /// Parsed digit by digit rather than through a formatter so that no `Double` is involved
    /// in a number he will see next to a dollar sign.
    static func moneyCents(_ word: String) -> Int? {
        var text = word
        if text.hasPrefix("$") { text.removeFirst() }
        if text.hasSuffix("-") { text.removeLast() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2 else { return nil }
        let whole = String(parts[0])
        let cents = String(parts[1])
        guard !whole.isEmpty, whole.count <= 7, isAllDigits(whole), isAllDigits(cents),
              let dollars = Int(whole), let fraction = Int(cents)
        else { return nil }
        return dollars * 100 + fraction
    }

    /// `"12"`, `"1.5"`, `"1/2"` -> an exact `Rational`. nil for anything else.
    ///
    /// A decimal becomes `15/10`, which `Rational` reduces to `3/2` — exact, because
    /// quantities in this app are never `Double` (`CLAUDE.md`). Three decimal places is the
    /// ceiling: nothing on a receipt is written finer, and the cap keeps the denominator
    /// nowhere near overflow.
    static func rational(fromNumber text: String) -> Rational? {
        if text.contains("/") { return Rational(string: text) }
        if text.contains(".") {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let whole = String(parts[0])
            let fraction = String(parts[1])
            guard whole.count <= 7, isAllDigits(whole),
                  !fraction.isEmpty, fraction.count <= 3, isAllDigits(fraction),
                  let wholeValue = Int(whole),
                  let fractionValue = Int(fraction)
            else { return nil }
            var scale = 1
            for _ in 0..<fraction.count { scale *= 10 }
            return Rational(wholeValue * scale + fractionValue, scale)
        }
        guard !text.isEmpty, text.count <= 7, isAllDigits(text), let value = Int(text) else {
            return nil
        }
        return Rational(value)
    }

    /// `"8z"` -> `("8", "z")`. A leading run of digits, dots and slashes, then letters or `#`.
    static func numberAndSuffix(_ word: String) -> (number: String, suffix: String)? {
        var number = ""
        var suffix = ""
        for character in word {
            if suffix.isEmpty, character.isNumber || character == "." || character == "/" {
                number.append(character)
            } else if character.isLetter || character == "#" {
                suffix.append(character)
            } else {
                return nil
            }
        }
        guard !number.isEmpty, !suffix.isEmpty, suffix.count <= 5 else { return nil }
        return (number: number, suffix: suffix)
    }

    static func isAllDigits(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for character in text {
            if !"0123456789".contains(character) { return false }
        }
        return true
    }

    // MARK: - The word lists, all deliberately short

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Three abbreviations and two spelled-out names. Short on purpose: a word dropped
    /// wrongly is a word the match cannot use, and the recovery for an unknown brand is one
    /// alias he teaches the app once.
    private static let brandPrefixes: Set<String> = [
        "gv", "ks", "365", "kirkland", "marketside"
    ]

    /// Packaging and grade words. NOT removed — they still get a chance to match — but they
    /// do not count against a candidate when they match nothing, because a grade word is not
    /// evidence against a reading. `KS ORG CHKN BRST` must score `chicken breast` at full
    /// coverage; `ORG` has no catalogue word to find.
    ///
    /// `fresh`, `dried`, `smoked` and `whole` are deliberately absent: they change identity
    /// rather than describe a pack, which is the same judgement `NameNormalizer` makes about
    /// its own qualifier list, and the catalogue ships `whole milk` and `fresh coriander` as
    /// real aliases.
    private static let packWords: Set<String> = [
        "org", "organic", "lg", "sm", "med", "xl", "jumbo", "fam", "family",
        "prem", "premium", "select", "value", "pack", "pk", "bag", "box", "bx", "ct"
    ]

    private static let totalsWords: Set<String> = [
        "subtotal", "total", "tax", "balance", "change", "due", "tender", "cash",
        "savings", "saved", "discount", "coupon", "rounding", "refund", "void", "items"
    ]

    private static let paymentWords: Set<String> = [
        "visa", "mastercard", "amex", "discover", "ebt", "snap", "debit", "credit",
        "acct", "account", "auth", "approved", "approval", "terminal", "merchant",
        "cashier", "register", "reg", "lane", "ref", "trace"
    ]

    /// Department headers that are NOT one of the catalogue's aisle names. The aisle names are
    /// left out on purpose — see the note at the top of this file.
    private static let departmentWords: Set<String> = [
        "grocery", "deli", "meat", "hba", "gm", "household", "merchandise",
        "pharmacy", "dept", "department", "misc", "miscellaneous", "general"
    ]

    private static let streetWords: Set<String> = [
        "st", "street", "ave", "avenue", "rd", "road", "blvd", "boulevard",
        "dr", "drive", "hwy", "highway", "ln", "lane", "pkwy", "parkway",
        "ste", "suite", "unit"
    ]

    /// Receipt size suffixes to `UnitCatalog` codes. `Z` is the one that matters: it is how
    /// every receipt writes ounces, and `UnitCatalog` has no idea what a `z` is.
    ///
    /// `CT`, `PK` and `EA` all become `each`, so a count lands in the `count:each` bucket
    /// `KitchenUnit.dimensionKey` keeps separate from weight and volume.
    private static let sizeUnitCodes: [String: String] = [
        "z": "oz", "oz": "oz", "ozs": "oz", "ounce": "oz", "ounces": "oz",
        "fz": "floz", "floz": "floz", "flz": "floz",
        "lb": "lb", "lbs": "lb", "#": "lb", "pound": "lb", "pounds": "lb",
        "g": "g", "gm": "g", "gr": "g", "grm": "g",
        "kg": "kg", "kgs": "kg",
        "ml": "ml", "mls": "ml",
        "l": "l", "lt": "l", "ltr": "l", "liter": "l", "litre": "l",
        "qt": "qt", "qts": "qt", "quart": "qt",
        "pt": "pt", "pts": "pt", "pint": "pt",
        "gal": "gal", "gl": "gal", "gallon": "gal",
        "ct": "each", "cnt": "each", "pk": "each", "pack": "each",
        "pc": "each", "pcs": "each", "ea": "each", "each": "each",
        "dz": "dozen", "doz": "dozen", "dozen": "dozen"
    ]
}
