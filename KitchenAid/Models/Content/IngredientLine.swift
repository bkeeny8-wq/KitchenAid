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
    // `amountNumerator`, `amountDenominator`, `unit`, `dimension` — which is also the
    // persistence shape the `@Model` side uses, so the file, the store and this type all say
    // the same thing with no translation layer. `hasQuantity: false` is exactly how "Pinch"
    // arrives. The decoder below folds the pair into `amount` and still accepts a nested
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

    /// The catalogue entry's `name`, or "" when the importer could not place it. NOT a
    /// `FoodItem` id: content cannot reference a row, and a row may not exist yet.
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

    /// One-to-one with the stored properties. Review 03 finding 1 found seven extraneous
    /// cases here, which is where the derived conformance failed hardest; they are all in
    /// `ImporterKeys` below. See the note on `Recipe.CodingKeys`.
    enum CodingKeys: String, CodingKey {
        case lineID, amount, unitCode, dimension, dimensionConfirmed, unmeasuredNote
        case displayName, preparation, note, rawText, catalogName, subRecipeID
        case isOptional, isGarnish, excludeFromShopping, scalingRule, subRecipePolicy
    }

    /// The importer's spellings.
    ///
    /// `display` is deliberately not read: it is the script's own rendering of the
    /// fraction, which `Quantity.displayString()` reproduces, so storing it would be a
    /// second copy that can disagree.
    ///
    /// `unitUnrecognized` IS read, and an earlier version of this comment claimed it
    /// needn't be because `dimensionConfirmed` already carried the same signal. That was
    /// false. In `scripts/import_recipe.py`, `dimensionConfirmed` is written ONLY on the
    /// `oz` branch of `split_quantity_cell`; `unitUnrecognized` is written on the
    /// unknown-unit branch, which writes no `dimensionConfirmed` at all. So a line like
    /// "12 rounds baguette" decoded with `dimensionConfirmed` at its `true` default and
    /// looked fully resolved, when in fact the script had no idea what a "round" was.
    private enum ImporterKeys: String, CodingKey {
        case name, raw, qualifier, unit
        case hasQuantity, amountNumerator, amountDenominator
        case unitUnrecognized
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let importer = try decoder.container(keyedBy: ImporterKeys.self)

        self.lineID = try c.decode(String.self, forKey: .lineID)

        // The five flat fields first; a nested `amount` only if they are absent. The
        // `hasQuantity: false` test leads, because that is the ONLY thing separating "Pinch
        // flaky salt" from a real zero — the importer writes numerator 0 / denominator 1
        // alongside it.
        var decodedAmount: Rational? = nil
        if try importer.decodeIfPresent(Bool.self, forKey: .hasQuantity) == false {
            decodedAmount = nil
        } else if let n = try importer.decodeIfPresent(Int.self, forKey: .amountNumerator) {
            let d = try importer.decodeIfPresent(Int.self, forKey: .amountDenominator) ?? 1
            decodedAmount = Rational(n, d == 0 ? 1 : d)
        } else {
            decodedAmount = try c.decodeIfPresent(Rational.self, forKey: .amount)
        }
        let decodedDimension = c.decodeRawValue(
            MeasureDimension.self, forKey: .dimension, fallback: .unmeasured
        )
        self.amount = decodedAmount
        self.dimension = decodedDimension

        // A COUNT line with no unit column is how "1 shallot" arrives — the importer writes
        // `"unit": null, "dimension": "count"`. Falling back to the dimension's base unit
        // keeps it a count of one `each` instead of silently losing the quantity, because
        // `UnitCatalog.unit(code: "")` returns nil and `quantity` would then be nil.
        self.unitCode = try c.decodeIfPresent(String.self, forKey: .unitCode)
            ?? importer.decodeIfPresent(String.self, forKey: .unit)
            ?? (decodedAmount == nil ? "" : decodedDimension.baseUnitCode)

        // An unrecognized unit is an unconfirmed dimension: the importer parked the token
        // in a count bucket because it had nowhere better to put it, which is a guess, not
        // a reading. Either signal routes the line to the inbox for him to confirm.
        let unitWasUnrecognized =
            try importer.decodeIfPresent(Bool.self, forKey: .unitUnrecognized) ?? false
        self.dimensionConfirmed =
            try (c.decodeIfPresent(Bool.self, forKey: .dimensionConfirmed) ?? true)
            && !unitWasUnrecognized
        self.unmeasuredNote = try c.decodeIfPresent(String.self, forKey: .unmeasuredNote)
            ?? importer.decodeIfPresent(String.self, forKey: .qualifier)
            ?? ""
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            ?? importer.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        self.preparation = try c.decodeIfPresent(String.self, forKey: .preparation) ?? ""
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
            ?? importer.decodeIfPresent(String.self, forKey: .raw)
            ?? ""
        self.catalogName = try c.decodeIfPresent(String.self, forKey: .catalogName) ?? ""
        self.subRecipeID = try c.decodeIfPresent(String.self, forKey: .subRecipeID)
        self.isOptional = try c.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
        self.isGarnish = try c.decodeIfPresent(Bool.self, forKey: .isGarnish) ?? false
        self.excludeFromShopping = try c.decodeIfPresent(Bool.self, forKey: .excludeFromShopping) ?? false
        self.scalingRule = c.decodeRawValue(ScalingRule.self, forKey: .scalingRule, fallback: .linear)
        self.subRecipePolicy = c.decodeRawValue(
            SubRecipePolicy.self, forKey: .subRecipePolicy, fallback: .treatAsItem
        )
    }

    init(lineID: String, displayName: String) {
        self.lineID = lineID
        self.displayName = displayName
    }
}

extension IngredientLine {
    /// nil means THERE IS NO QUANTITY. An unknown `unitCode` degrades to a count noun in its
    /// own bucket rather than zeroing the amount — see `UnitCatalog.unit(code:…)`.
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

    /// The key the pantry and the shopping list aggregate on. Butter at 1 tbsp in two
    /// components of ONE recipe has to merge, which is requirement 11 from the fixture.
    var matchKey: String {
        NameNormalizer.matchKey(catalogName.isEmpty ? displayName : catalogName)
    }
}
