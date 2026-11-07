import XCTest
@testable import KitchenAid

/// The arithmetic the whole app rests on, and the only part of this codebase
/// whose defects are already documented rather than hypothetical.
///
/// Three rounds of review found two separate `Int.min` traps in `Rational`, and
/// each was accompanied by a comment asserting the trap was unreachable. Both
/// comments were wrong. So these tests exist to make the CURRENT comments
/// falsifiable: every documented behaviour below is asserted, including the
/// deliberate degradations, so that the next person to "simplify" one of them
/// finds out here rather than in a kitchen.
final class RationalTests: XCTestCase {

    // MARK: - Exactness, which is the reason this type exists at all

    /// The promise that rules out `Double`. 1/3 scaled by 3 must be exactly 1;
    /// 0.3333333333 × 3 is 0.9999999999, which formats as "1" only by luck and
    /// rounds wrong at other multiples.
    func testThirdTimesThreeIsExactlyOne() {
        XCTAssertEqual(Rational(1, 3) * Rational(3), .one)
        XCTAssertEqual(Rational(1, 3) + Rational(1, 3) + Rational(1, 3), .one)
    }

    /// The fixture's own case: 1 tsp + 1/4 tsp is 1 1/4 tsp, not 1.25.
    func testFixtureSaltAddition() {
        let total = Rational(1) + Rational(1, 4)
        XCTAssertEqual(total, Rational(5, 4))
        XCTAssertEqual(total.exactDescription, "1 1/4")
    }

    /// Attendance scaling: 2 full + 1 half + 2 guests is 4 1/2 portions against
    /// a recipe for 4, so ×1 1/8 exactly.
    func testAttendanceScaleFactorIsExact() {
        let portions = Rational(2) + Rational(1, 2) + Rational(2)
        XCTAssertEqual(portions, Rational(9, 2))
        let scale = portions / Rational(4)
        XCTAssertEqual(scale, Rational(9, 8))
        XCTAssertEqual(scale.exactDescription, "1 1/8")
        // And the fixture's 1/4 tsp of salt scaled by it.
        XCTAssertEqual(Rational(1, 4) * scale, Rational(9, 32))
    }

    func testReducesOnConstruction() {
        XCTAssertEqual(Rational(2, 4), Rational(1, 2))
        XCTAssertEqual(Rational(6, 3), Rational(2))
        XCTAssertEqual(Rational(0, 5), .zero)
    }

    func testSignIsNormalisedOntoTheNumerator() {
        XCTAssertEqual(Rational(1, -2), Rational(-1, 2))
        XCTAssertEqual(Rational(-1, -2), Rational(1, 2))
        XCTAssertTrue(Rational(1, -2).isNegative)
    }

    // MARK: - Int.min, found twice by review and fixed twice

    /// Review 01 found `abs(n)` trapping here; review 03 found
    /// `if d < 0 { n = -n }` still doing it. `Rational(Int.min, 2)` reduces to
    /// exactly -2^62, which fits, so it must be exact and must not trap.
    func testIntMinNumeratorDoesNotTrap() {
        let r = Rational(Int.min, 2)
        XCTAssertEqual(r.numerator, Int.min / 2)
        XCTAssertEqual(r.denominator, 1)
    }

    func testIntMinDenominatorDoesNotTrap() {
        let r = Rational(1, Int.min)
        XCTAssertTrue(r.isNegative || r.isZero)
    }

    /// The one documented degradation: a magnitude of 2^63 cannot be stored, so
    /// it becomes zero — wrong by an amount no recipe can express, and VISIBLE,
    /// rather than killing the app. A hand-authored recipe file can hold
    /// -9223372036854775808 as easily as any other integer, so this is a real
    /// input path.
    func testUnstorableMagnitudeDegradesToZeroRatherThanCrashing() {
        XCTAssertEqual(Rational(Int.min, 1), .zero)
    }

    /// Both strings review 03 found trapping, from committed content.
    func testStringInitRefusesRatherThanTraps() {
        XCTAssertNil(Rational(string: "-1 -9223372036854775808/3"))
        XCTAssertNil(Rational(string: "4611686018427387904 1/2"))
        XCTAssertNil(Rational(string: "1/0"))
        XCTAssertNil(Rational(string: "not a number"))
    }

    func testStringInitParsesWhatRecipesActuallyWrite() {
        XCTAssertEqual(Rational(string: "1 1/4"), Rational(5, 4))
        XCTAssertEqual(Rational(string: "1/2"), Rational(1, 2))
        XCTAssertEqual(Rational(string: "12"), Rational(12))
        XCTAssertEqual(Rational(string: " 3 "), Rational(3))
    }

    /// An overflow-checked operator must treat an `Int.min` partial value AS an
    /// overflow. It can produce exactly `Int.min` without reporting one —
    /// (-2^62) × 2 — and handing that onward was how the trap was reached in
    /// the first place.
    func testOverflowOperatorsReportRatherThanReturnIntMin() {
        let huge = Rational(Int.max / 2)
        let (_, overflowed) = Rational.multipliedReportingOverflow(huge, huge)
        XCTAssertTrue(overflowed)
        let (_, addOverflowed) = Rational.addingReportingOverflow(
            Rational(Int.max), Rational(Int.max))
        XCTAssertTrue(addOverflowed)
    }

    // MARK: - Display: rounded for people, exact for storage

    /// The bug a by-hand trace of the butter case found: a conversion note read
    /// "23 1111/1135 tsp". Correct, and useless to a cook. `humanDescription`
    /// is what every label and note must use.
    func testHumanDescriptionNeverPrintsAnAbsurdFraction() {
        let awful = Rational(27216, 1135)
        let human = awful.humanDescription
        XCTAssertFalse(human.contains("1135"), "human form leaked the exact denominator: \(human)")
        // It still says roughly 24.
        XCTAssertTrue(human.contains("24") || human.contains("23"), human)
        // And it marks itself as approximate.
        XCTAssertTrue(human.hasPrefix("\u{2248}"), human)
    }

    /// The exact form is still available, and still exact. It is for storage and
    /// round-tripping, never for a label.
    func testExactDescriptionStaysExact() {
        XCTAssertEqual(Rational(27216, 1135).exactDescription, "23 1111/1135")
        XCTAssertEqual(Rational(3, 4).exactDescription, "3/4")
        XCTAssertEqual(Rational(5, 4).exactDescription, "1 1/4")
        XCTAssertEqual(Rational(2).exactDescription, "2")
        XCTAssertEqual(Rational(-3, 4).exactDescription, "-3/4")
    }

    /// A kitchen fraction is exact and unmarked; anything else is marked.
    func testKitchenRoundingMarksOnlyWhatItChanged() {
        let half = Rational(1, 2).kitchenRounded()
        XCTAssertFalse(half.isApproximate)
        let third = Rational(1, 3).kitchenRounded()
        XCTAssertFalse(third.isApproximate)
        let odd = Rational(1, 7).kitchenRounded()
        XCTAssertTrue(odd.isApproximate)
    }

    // MARK: - The pieces the shopping algorithm leans on

    /// Clamped on BOTH sides of the inventory subtraction. A lot holding a
    /// negative volume must not produce a negative have-subtotal, because
    /// `requested - (-2 tbsp)` silently inflates the purchase.
    func testClampedAtZero() {
        XCTAssertEqual(Rational(-3, 4).clampedAtZero, .zero)
        XCTAssertEqual(Rational(3, 4).clampedAtZero, Rational(3, 4))
    }

    func testCeilingInt() {
        XCTAssertEqual(Rational(5, 4).ceilingInt, 2)
        XCTAssertEqual(Rational(2).ceilingInt, 2)
        XCTAssertEqual(Rational(1, 100).ceilingInt, 1)
        XCTAssertEqual(Rational(-5, 4).ceilingInt, -1)
    }

    /// Batch granularity: you cannot bake 1.4 loaves.
    func testCeilingToMultiple() {
        XCTAssertEqual(Rational(7, 5).ceiling(toMultipleOf: Rational(1, 2)), Rational(3, 2))
        XCTAssertEqual(Rational(2).ceiling(toMultipleOf: Rational(1, 2)), Rational(2))
        // A non-positive step is a no-op rather than a divide-by-zero.
        XCTAssertEqual(Rational(7, 5).ceiling(toMultipleOf: .zero), Rational(7, 5))
    }

    func testComparison() {
        XCTAssertTrue(Rational(1, 3) < Rational(1, 2))
        XCTAssertTrue(Rational(-1, 2) < .zero)
        XCTAssertFalse(Rational(1, 2) < Rational(2, 4))
    }

    // MARK: - Codable, because recipe files are hand-edited

    func testCodableRoundTrip() throws {
        for value in [Rational(5, 4), .zero, Rational(-3, 7), Rational(12)] {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(Rational.self, from: data), value)
        }
    }

    /// A zero denominator in a committed file must degrade, not crash: the
    /// loader turns a failed decode into a diagnostic and keeps the other
    /// recipes loaded.
    func testDecodingAZeroDenominatorDoesNotCrash() {
        let json = Data(#"{"numerator":1,"denominator":0}"#.utf8)
        XCTAssertNoThrow({ _ = try? JSONDecoder().decode(Rational.self, from: json) }())
    }
}
