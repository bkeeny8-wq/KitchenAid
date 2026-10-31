import Foundation

/// Produces the `matchKey`: lowercase, strip diacritics and punctuation, collapse whitespace,
/// drop a leading article, drop parentheticals and trailing prep qualifiers (`, chopped`,
/// `, divided`, `(optional)`), then a conservative singularizer (`-ies→y`, `-oes→o`, `-s→∅`)
/// with a stoplist for `asparagus`, `couscous`, `molasses`, `greens`, `hummus`.
///
/// Deliberately **not** a stemmer — over-normalizing collides `butter`/`buttermilk`.
///
/// Normalization cannot solve synonymy, so it does not try. "Scallion" vs "green onion" is
/// the catalogue's shipped `aliases` first, and a `FoodItemAlias` row he adds second.
///
/// It is also the function that generates a content `lineID` slug, so the importer and the
/// app agree on what `butter-2` means. `slug` below is a line-for-line port of
/// `scripts/import_recipe.py`'s `slug()`, and **the Python one is the reference**: if they
/// ever disagree, the ids in the committed files are what the Python produced, so this is
/// what changes.
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
        // An unmatched "(" ends the loop, because the inner search fails.
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
        let characters = s.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        var words = String(characters).split(separator: " ").map { String($0) }

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
