import Foundation

// Reading the bundled content the way a cook at a stove needs it read.
//
// These helpers live in Views/Cook/ and not in Models/Content/ on purpose. Every
// one of them is a judgement about how this screen should PRESENT a step, not a
// fact the content model asserts, and the model layer is frozen. Where one of
// them later proves to be a property of the content itself -- `isShouted` is the
// likeliest -- it should move, and the importer should write it.

extension RecipeNote {

    /// `DO. NOT. SALT.` and `DO NOT USE SALTED BUTTER.` are the whole point of
    /// the roast turkey: it, its butter and its gravy are all deliberately
    /// unsalted so the cook salts once at the end. The importer was dropping
    /// both lines entirely at one point, and a note shouted in the document is
    /// the one that must survive every screen -- including this one, where he is
    /// actually holding the butter.
    ///
    /// The same test is spelled out privately inside `RecipeDetailView`. It is
    /// duplicated rather than shared because that file is frozen; if the two
    /// ever need to disagree, that is the bug, and this is the copy to delete.
    var isShouted: Bool {
        let letters = text.filter { $0.isLetter }
        return letters.count > 3 && letters.allSatisfy { $0.isUppercase }
    }
}

extension RecipeStep {

    /// Waiting, not work.
    ///
    /// `isPassiveRest` is the authored answer and wins whenever it is set -- but
    /// `scripts/import_recipe.py` does not write it yet, so across all eight
    /// bundled recipes it is false everywhere, including on the fixture's
    /// 30-minute "Season the steak / Let it sit at room temperature". A cook
    /// screen that trusted the flag alone would present the project's own
    /// headline example of a rest as thirty minutes of work.
    ///
    /// So the flag is backed by a deliberately NARROW reading of the text. Each
    /// clause below was checked against the step text of all eight recipes and
    /// the set matches exactly the three real rests -- the fixture's steps 1 and
    /// 4 and the turkey's step 10 -- and nothing else:
    ///
    /// - `"rest the"` ANYWHERE is wrong: the pancake's step 4 says "fold in the
    ///   rest the way you would…", so the title prefix is tested instead.
    /// - `"to rest"` anywhere is wrong too: the gravy's step 1 opens "After the
    ///   turkey comes out to rest, pour the vegetables and drippings…", which is
    ///   active work that merely mentions somebody else's rest. Hence the title
    ///   SUFFIX, which is how the turkey's "Move the turkey to a board to rest"
    ///   reads and how the gravy's step does not.
    ///
    /// Widening this is how a step that needs a cook standing over it starts
    /// reading as one he can walk away from, so widen it against the real files.
    var readsAsPassiveRest: Bool {
        if isPassiveRest { return true }
        let heading = title.trimmingCharacters(in: .whitespaces).lowercased()
        if heading.hasPrefix("rest ") || heading.hasSuffix("to rest") { return true }
        let prose = body.lowercased()
        for phrase in ["let it sit", "let it rest", "let them sit", "let them rest"] {
            if prose.contains(phrase) { return true }
        }
        return false
    }

    /// "Oven 400 F", "125 F inside", or both. Two fields because one cannot hold
    /// both and 0 is a real temperature.
    var cookTemperatureText: String {
        var parts: [String] = []
        if let oven = ovenTemperatureF { parts.append("Oven \(oven)\u{00B0}F") }
        if let target = targetInternalTemperatureF { parts.append("\(target)\u{00B0}F inside") }
        return parts.joined(separator: "   \u{00B7}   ")
    }

    /// True when the step gives the cook a window rather than a number -- the
    /// fixture's step 3 is "7 to 8 min". The timer runs to the LONGER end
    /// (`timerSeconds`), so the screen has to say so rather than let a cook
    /// think 7 minutes was promised.
    var hasDurationRange: Bool {
        guard let lo = minMinutes, let hi = maxMinutes else { return false }
        return lo != hi
    }
}

/// What a quantity says on the cook screen at a given scale.
///
/// A deliberate parallel to `PDFExportService.ingredientRow(for:scale:marker:)`,
/// which is private to the exporter and returns a PDF row. The three rules it
/// encodes are the ones this screen needs too and must not get differently:
/// `.fixed` lines do not scale, a RANGE STAYS A RANGE because the latitude is
/// the point of writing one, and every number is rendered through
/// `displayString()`/`humanDescription`, never `exactDescription` -- which is
/// what produced the "23 1111/1135 tsp" label review 03 found.
enum CookQuantity {

    /// The amount for one line, scaled. "" is never returned for a line that
    /// has something to say: an unmeasured line gives back its own note
    /// ("Pinch", "to taste"), which is a presence, not a zero.
    static func text(for line: IngredientLine, scale: Rational) -> String {
        // One bay leaf and the oil for the pan survive a triple batch without
        // becoming three bay leaves and a fistful of salt.
        let factor = line.scalingRule == .fixed ? Rational.one : scale
        guard let quantity = line.quantity else { return line.unmeasuredNote }
        let low = quantity.scaled(by: factor)
        guard let high = line.amountMax,
              let unit = UnitCatalog.unit(code: line.unitCode, fallbackDimension: line.dimension)
        else { return low.displayString() }
        let top = Quantity(amount: high * factor, unit: unit)
        return "\(low.amount.humanDescription) to \(top.displayString())"
    }

    /// The recipe's OWN second measurement, scaled -- "1 1/2 cups flour (190g)".
    /// Exact and written by whoever wrote the recipe, so it beats any density
    /// conversion and for a baking recipe it is the one to weigh by.
    static func altText(for line: IngredientLine, scale: Rational) -> String? {
        let factor = line.scalingRule == .fixed ? Rational.one : scale
        guard let alt = line.altQuantity else { return nil }
        return alt.scaled(by: factor).displayString()
    }

    /// "not scaled", "optional", "garnish" -- the things that qualify an amount
    /// without changing it.
    static func qualifiers(for line: IngredientLine, scale: Rational) -> String {
        var parts: [String] = []
        if line.isOptional { parts.append("optional") }
        if line.isGarnish { parts.append("garnish") }
        if line.scalingRule == .fixed, scale != .one { parts.append("not scaled") }
        if !line.note.isEmpty { parts.append(line.note) }
        return parts.joined(separator: "   \u{00B7}   ")
    }
}

/// Seconds as a clock, and as a sentence for VoiceOver.
enum CookClock {

    /// "4:05", "1:02:30". Monospaced digits at the call site so the width does
    /// not jump every second.
    static func text(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "4 minutes 5 seconds". A clock face read aloud as "four oh five" is a
    /// time of day, not a duration, so the spoken form is spelled out.
    static func spoken(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}
