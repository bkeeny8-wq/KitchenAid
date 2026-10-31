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

    private static let byCode: [String: KitchenUnit] = {
        var table: [String: KitchenUnit] = [:]
        for unit in allMeasured { table[unit.code] = unit }
        table[each.code] = each
        return table
    }()

    /// A count noun becomes a unit whose base factor is 1 in its own bucket.
    static func countUnit(noun: String) -> KitchenUnit {
        let code = noun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty else { return each }
        // "each" must come back as the STATIC, whose singular and plural are both empty.
        // Synthesizing it here instead gave singular "each" and plural "eaches", so the
        // fixture's "1 shallot" rendered as "1 each shallot" — and `displayUnit`'s hint
        // check compares against the static by value, so a synthesized twin also failed to
        // match and silently fell through to the next candidate.
        if code == each.code { return each }
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
    /// For an UNKNOWN code, `fallbackDimension` is deliberately not honoured: an unknown
    /// code has no factor into volume or mass and so cannot satisfy a `.volume`/`.mass`
    /// claim. Treating it as count keeps the amount intact and visible instead of silently
    /// zeroing it.
    ///
    /// For an AMBIGUOUS KNOWN code it is honoured, and must be. `oz` is weight ounces in
    /// `byCode` because recipes mean weight far more often — the fixture uses it that way
    /// three times. But `scripts/import_recipe.py`'s `resolve_oz()` resolves it by
    /// ingredient and records the answer, returning `volume` for anything containing water,
    /// stock, broth, milk, cream, wine, juice or oil. Looking `oz` up and discarding that
    /// recorded dimension threw away the entire point of recording it, and turned
    /// "8 oz chicken stock" into half a pound of liquid.
    static func unit(code: String, fallbackDimension: MeasureDimension?) -> KitchenUnit? {
        let key = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let wanted = fallbackDimension, let byDimension = ambiguousCodes[key],
           let resolved = byDimension[wanted] {
            return resolved
        }
        if let known = byCode[key] { return known }
        return countUnit(noun: key)
    }

    /// Codes that name a different unit depending on the dimension the line recorded.
    /// Only `oz` is genuinely ambiguous in recipe writing; everything else in the table
    /// means one thing.
    private static let ambiguousCodes: [String: [MeasureDimension: KitchenUnit]] = [
        "oz": [.mass: ounce, .volume: fluidOunce]
    ]

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
        if knownCountNouns[key] != nil { return countUnit(noun: key) }
        // A plural is singularized by REVERSE LOOKUP, never by dropping a letter. The
        // blanket `dropLast()` that used to be here turned "loaves" into "loave" and
        // "bunches" into "bunche", each of which becomes its own `count:` bucket — so
        // "1 loaf bread" and "2 loaves bread" never merged. That is precisely the
        // same-purchase-two-buckets failure the dimension key exists to prevent.
        if let singular = singularOfPlural[key] { return countUnit(noun: singular) }
        // Only a regular plural of an unregistered noun falls back to trimming the s.
        if key.hasSuffix("s"), key.count > 2 {
            let stem = String(key.dropLast())
            if knownCountNouns[stem] != nil { return countUnit(noun: stem) }
        }
        return nil
    }

    private static let singularOfPlural: [String: String] = {
        var table: [String: String] = [:]
        for (singular, plural) in knownCountNouns { table[plural] = singular }
        return table
    }()

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
        // Spelled out rather than switching on an optional tuple: there is no compiler here
        // to confirm that an enum-case pattern promotes into `Optional`, and nothing is
        // gained by finding out on Brandon's Mac.
        guard let dimension = MeasureDimension(rawValue: dimensionKey) else { return [] }
        switch dimension {
        case .volume:
            return system == .metric ? [liter, milliliter] : [quart, pint, cup, tablespoon, teaspoon]
        case .mass:
            return system == .metric ? [kilogram, gram] : [pound, ounce, gram]
        case .count, .unmeasured:
            return []
        }
    }
}
