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
///
/// STORAGE IS EXACT; DISPLAY ROUNDS. `description` — what string interpolation reaches for —
/// is the rounded, human form, and the exact form has to be asked for by name
/// (`exactDescription`). That is deliberate: a note built by interpolating the exact value
/// rendered as "23 1111/1135 tsp" (SPEC_REVIEW_03 finding 8), which is correct and unusable.
/// `debugDescription` stays exact, so the debugger and test failures still show the real
/// number.
struct Rational: Hashable, Sendable, Comparable, CustomStringConvertible, CustomDebugStringConvertible {
    let numerator: Int
    /// Invariant: always > 0, always reduced against the numerator, and always <= `Int.max`
    /// in magnitude — as is `numerator`, so negating either one is always defined.
    let denominator: Int

    /// TOTAL: no input traps, `Int.min` included.
    ///
    /// What the code actually guarantees, rather than what an earlier comment claimed:
    /// the sign is read off the two inputs and the reduction runs on `magnitude`, which is
    /// `UInt` and is defined for every `Int`, so nothing is ever negated on the way in.
    /// `abs(n)` and `if d < 0 { n = -n; d = -d }` were the two shapes that trapped on
    /// `Int.min` — review 01 found the first, review 03 found the second shape still alive in
    /// `init?(string:)` — and neither exists any more.
    ///
    /// One magnitude still cannot be stored: `2^63`, which survives reduction only when
    /// `Int.min` meets a denominator sharing no factor with it (`Rational(Int.min, 1)`, but
    /// not `Rational(Int.min, 2)`, which is exactly `-2^62`). That case DEGRADES to zero —
    /// wrong by an amount no recipe can express, and visible, instead of killing the app in
    /// a kitchen. `Rational`'s hand-written `Codable` takes its numerator from a
    /// hand-authored recipe file, which can hold `-9223372036854775808` as easily as any
    /// other integer, so this is an input path and not a theoretical one.
    ///
    /// A zero denominator stays a precondition: it is a programmer error, and both paths
    /// that take a denominator from a file (`init(from:)` and `init?(string:)`) reject it
    /// before calling here.
    init(_ n: Int, _ d: Int = 1) {
        precondition(d != 0, "Rational denominator must not be zero")
        let negative = (n < 0) != (d < 0)
        let g = Rational.gcd(n.magnitude, d.magnitude)
        let reducedNumerator = n.magnitude / g
        let reducedDenominator = d.magnitude / g
        let limit = UInt(Int.max)
        guard reducedNumerator <= limit, reducedDenominator <= limit else {
            self.numerator = 0
            self.denominator = 1
            return
        }
        let storedMagnitude = Int(reducedNumerator)
        self.numerator = negative ? -storedMagnitude : storedMagnitude
        self.denominator = Int(reducedDenominator)
    }

    static let zero = Rational(0)
    static let one = Rational(1)

    /// gcd of the MAGNITUDES. `UInt` in and `UInt` out, so no caller needs `abs`.
    static func gcd(_ a: UInt, _ b: UInt) -> UInt {
        var a = a
        var b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    /// The `Int` convenience, for the arithmetic below.
    ///
    /// It reduces magnitudes, so it cannot trap on `Int.min`. The one result that does not
    /// fit back into `Int` is `gcd(Int.min, Int.min) == 2^63`; it returns 1, which is always
    /// a valid divisor and leaves the fraction unreduced, rather than converting and
    /// trapping. Stored values never reach that case — the initializer's invariant rules out
    /// an `Int.min` numerator or denominator — but this is also called on raw operands.
    static func gcd(_ a: Int, _ b: Int) -> Int {
        let g = gcd(a.magnitude, b.magnitude)
        return g > UInt(Int.max) ? 1 : Int(g)
    }

    var doubleValue: Double { Double(numerator) / Double(denominator) }
    var isZero: Bool { numerator == 0 }
    var isNegative: Bool { numerator < 0 }

    /// Absolute value. Defined for every stored value: see the invariant on `denominator`.
    var magnitude: Rational { isNegative ? negated : self }

    /// The rounded, human form — see the type comment.
    var description: String { humanDescription }
    /// Exact, for the debugger and for test-failure output.
    var debugDescription: String { exactDescription }

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
        // An `Int.min` partial value counts as an overflow even though no operation reported
        // one: `init(_:_:)` can normalize it only when the other term shares a factor of 2
        // with it, so handing it on risks a silent zero where the caller asked to be told
        // that the exact answer was lost.
        if o1 || o2 || o3 || o4 || num == .min || den == .min { return (.zero, true) }
        return (Rational(num, den), false)
    }

    static func multipliedReportingOverflow(
        _ a: Rational, _ b: Rational
    ) -> (partialValue: Rational, overflow: Bool) {
        // Cross-reduce BEFORE multiplying, so 3/4 * 8/9 never forms 24/36.
        let g1 = gcd(a.numerator, b.denominator)
        let g2 = gcd(b.numerator, a.denominator)
        let (num, o1) = (a.numerator / g1).multipliedReportingOverflow(by: b.numerator / g2)
        let (den, o2) = (a.denominator / g2).multipliedReportingOverflow(by: b.denominator / g1)
        // See `addingReportingOverflow`: `Int.min` is reported as an overflow. `(-2^62) * 2`
        // is the concrete case — it returns `(Int.min, false)`.
        if o1 || o2 || num == .min || den == .min { return (.zero, true) }
        return (Rational(num, den), false)
    }

    // MARK: Operators
    //
    // With the culinary conversion table (UnitCatalog) every factor's denominator is at most
    // 20, so a line of a recipe cannot reach the overflow branches below. They exist because
    // the quantities also come from hand-authored JSON, where any Int64 is writable, and
    // because the alternative is a trap at the shelf.

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
    /// overflow, including on an `Int.min` partial value. Earlier versions tested only
    /// `k2 > maxDenominator`, after computing `h2` — but `h2 ≈ value × k2`, so with
    /// `abs(value)` allowed up to 1e15 and `k2` free to reach `maxDenominator` before the
    /// test fires, `a * h1 + h0` reaches ~1e19 and traps. That matters more here than
    /// anywhere else in this file: this initializer sits on the path `+` and `*` take **to
    /// avoid** trapping, so a trap here crashes exactly where the recovery was supposed to
    /// save us.
    ///
    /// Defined behaviour on every input: a non-finite or absurdly large `value` yields zero,
    /// and an overflow mid-expansion yields the last convergent that fit.
    init(approximating value: Double, maxDenominator: Int = 64) {
        guard value.isFinite, value.magnitude < 1e15 else { self.init(0); return }
        let negative = value < 0
        var x = value.magnitude
        var (h0, h1) = (0, 1)
        var (k0, k1) = (1, 0)
        for _ in 0..<32 {
            guard x < 9.0e18 else { break }
            let a = Int(x.rounded(.down))
            // All four steps run unconditionally and the breaks are collected: a reporting
            // operator fed a wrapped partial value still reports rather than traps, and a
            // ternary mixing a bare tuple with a labelled one is exactly the kind of
            // construct this file cannot risk, having no compiler to ask.
            let (ah, ahOverflow) = a.multipliedReportingOverflow(by: h1)
            let (h2, h2Overflow) = ah.addingReportingOverflow(h0)
            let (ak, akOverflow) = a.multipliedReportingOverflow(by: k1)
            let (k2, k2Overflow) = ak.addingReportingOverflow(k0)
            if ahOverflow || h2Overflow || akOverflow || k2Overflow { break }
            if h2 == .min || k2 == .min { break }
            if k2 > maxDenominator { break }
            (h0, h1) = (h1, h2)
            (k0, k1) = (k1, k2)
            let frac = x - Double(a)
            if frac < 1e-12 { break }
            x = 1 / frac
        }
        let found = Rational(h1, max(1, k1))
        self = negative ? found.negated : found
    }

    func limitingDenominator(to maximum: Int) -> Rational {
        guard denominator > maximum else { return self }
        return Rational(approximating: doubleValue, maxDenominator: maximum)
    }

    /// Smallest integer >= self.
    ///
    /// Written as quotient-plus-remainder rather than `(numerator + denominator - 1) / d`:
    /// that form overflows for a numerator near `Int.max`, and Swift's integer division
    /// already truncates toward zero, which is the ceiling for a negative value.
    var ceilingInt: Int {
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        return remainder > 0 ? quotient + 1 : quotient
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
    ///
    /// Returns `self` unchanged when the scaled value will not fit in an `Int`:
    /// `Int(_: Double)` traps on an out-of-range magnitude, and the callers of this treat a
    /// result whose denominator is not a divisor of `d` as "no kitchen fraction fits".
    func rounded(toDenominator d: Int) -> Rational {
        guard d > 0 else { return self }
        let scaled = (Double(numerator) * Double(d) / Double(denominator)).rounded()
        guard scaled.isFinite, scaled.magnitude < 9.0e18 else { return self }
        return Rational(Int(scaled), d)
    }

    // MARK: Display

    /// The kitchen fractions. Halves, thirds, quarters and eighths — the denominators a
    /// measuring spoon actually has.
    private static let kitchenDenominators = [1, 2, 3, 4, 8]

    /// The rounded form a human reads, with the exact value's fate reported.
    ///
    /// `value` is what to pluralize against, `text` is what to print, and `isApproximate`
    /// says whether anything was lost — the caller places the "≈" itself, because a label
    /// and a sentence put it in different places.
    ///
    /// The ladder: an exact kitchen denominator prints as-is; otherwise the closest kitchen
    /// fraction wins if it is within `max(1/64, |self|/50)`, which is what turns
    /// `27216/1135` tsp into "8 tbsp" instead of "23 1111/1135 tsp"; otherwise one decimal
    /// place, which is honest about a value no spoon measures.
    func kitchenRounded() -> (value: Rational, text: String, isApproximate: Bool) {
        if Rational.kitchenDenominators.contains(denominator) {
            return (self, exactVulgarDescription, false)
        }

        var best: Rational?
        var bestError: Rational?
        for d in Rational.kitchenDenominators {
            let candidate = rounded(toDenominator: d)
            // `rounded(toDenominator:)` returns `self` when it cannot scale; a reduced
            // denominator that does not divide `d` is that case, and is not a candidate.
            guard candidate.denominator <= d, d % candidate.denominator == 0 else { continue }
            let error = (candidate - self).magnitude
            if bestError == nil || error < bestError! {
                best = candidate
                bestError = error
            }
        }
        let tolerance = max(Rational(1, 64), magnitude / Rational(50))
        if let best = best, let bestError = bestError, bestError <= tolerance {
            return (best, best.exactVulgarDescription, true)
        }

        let scaled = (doubleValue * 10).rounded()
        guard scaled.isFinite, scaled.magnitude < 9.0e18 else {
            // Nothing a kitchen reads. Truncate to a whole number rather than print a
            // nineteen-digit fraction.
            let whole = Rational(numerator / denominator)
            return (whole, whole.exactDescription, true)
        }
        let tenths = Rational(Int(scaled), 10)
        if tenths.isZero { return (.zero, "0", true) }
        return (tenths, String(format: "%.1f", tenths.doubleValue), true)
    }

    /// "2", "1½", "≈ 8", "0.2". What every user-facing label and note prints.
    var humanDescription: String {
        let rounded = kitchenRounded()
        return rounded.isApproximate ? "\u{2248} \(rounded.text)" : rounded.text
    }

    /// EXACT: "2", "3/4", "1 1/4", "23 1111/1135". Never rounded, never "1.3333". For
    /// storage, round-tripping and arithmetic — not for a label.
    var exactDescription: String {
        if denominator == 1 { return "\(numerator)" }
        let sign = numerator < 0 ? "-" : ""
        let n = numerator.magnitude
        let whole = n / UInt(denominator)
        let rem = n % UInt(denominator)
        if whole == 0 { return "\(sign)\(rem)/\(denominator)" }
        return "\(sign)\(whole) \(rem)/\(denominator)"
    }

    private static let vulgars: [String: String] = [
        "1/2": "\u{00BD}", "1/3": "\u{2153}", "2/3": "\u{2154}",
        "1/4": "\u{00BC}", "3/4": "\u{00BE}", "1/8": "\u{215B}",
        "3/8": "\u{215C}", "5/8": "\u{215D}", "7/8": "\u{215E}"
    ]

    /// EXACT, with "1½" where a glyph exists and `exactDescription` where none does. Still
    /// exact, so still not for a note built by interpolation — `kitchenRounded` calls this
    /// only after it has rounded.
    var exactVulgarDescription: String {
        guard denominator != 1 else { return "\(numerator)" }
        let sign = numerator < 0 ? "-" : ""
        let n = numerator.magnitude
        let whole = n / UInt(denominator)
        let rem = n % UInt(denominator)
        guard let glyph = Rational.vulgars["\(rem)/\(denominator)"] else {
            return exactDescription
        }
        return whole == 0 ? "\(sign)\(glyph)" : "\(sign)\(whole)\(glyph)"
    }
}

// MARK: - Codable, written by hand and not synthesized
//
// This matters because quantities arrive from HAND-AUTHORED JSON. The synthesized
// `init(from:)` for a struct with `let` properties assigns them directly, bypassing
// `init(_:_:)` — so a file containing `{"numerator": 1, "denominator": 0}` would decode to an
// unnormalized, un-reduced, zero-denominatored value that later traps inside `/` or
// `exactDescription`, in the kitchen, at the stove. A typo in a committed recipe file must
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
    ///
    /// Every arithmetic step is checked and a failure returns nil, which is the right
    /// outcome: `init(from:)` falls through to the keyed container and `RecipeLoader` records
    /// a `ContentDiagnostic` for a file it cannot decode. Review 03 finding 6 found this
    /// initializer trapping on `"-1 -9223372036854775808/3"` (unary minus) and on
    /// `"4611686018427387904 1/2"` (an unchecked multiply), from committed content.
    init?(string: String) {
        let t = string.trimmingCharacters(in: .whitespaces)
        if let i = Int(t) { self.init(i); return }

        let parts = t.split(separator: " ")
        if parts.count == 2, let whole = Int(parts[0]) {
            let frac = parts[1].split(separator: "/")
            guard frac.count == 2,
                  let n = Int(frac[0]),
                  let d = Int(frac[1]),
                  d != 0, d != .min, n != .min, whole != .min
            else { return nil }
            let (scaled, scaleOverflow) = whole.multipliedReportingOverflow(by: d)
            guard !scaleOverflow else { return nil }
            // `0 - n` rather than `-n`: subtraction reports, negation traps.
            var signed = n
            if whole < 0 {
                let negation = Int(0).subtractingReportingOverflow(n)
                guard !negation.overflow else { return nil }
                signed = negation.partialValue
            }
            let (total, sumOverflow) = scaled.addingReportingOverflow(signed)
            guard !sumOverflow, total != .min else { return nil }
            self.init(total, d)
            return
        }

        let frac = t.split(separator: "/")
        guard frac.count == 2,
              let n = Int(frac[0]),
              let d = Int(frac[1]),
              d != 0, d != .min, n != .min
        else { return nil }
        self.init(n, d)
    }
}
