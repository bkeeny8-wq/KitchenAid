import Foundation
import SwiftData

/// A household member.
///
/// `CLAUDE.md`: **named people with a full or half portion.** No allergy data, no dietary
/// data, no restrictions relationship — he was offered those and declined. Rows are addable
/// and removable, two are seeded, and **no count is hardcoded anywhere**: nothing in this
/// file or the ones beside it knows that today the household is two. Anonymous heads at a
/// party are `PlannedMeal.guestCount`, counted and never named.
///
/// THERE IS NO `Household` MODEL. The household *is* the set of `Eater` rows. A singleton
/// created by a bootstrap-if-empty is a CloudKit liability: two devices both bootstrap, and
/// now there are two households with two rosters and attendance split across them.
@Model
final class Eater {
    var id: UUID = UUID()
    var name: String = ""

    /// "Bk" — the calendar chip and the PDF legend.
    var shortName: String = ""

    var colorIndex: Int = 0
    var symbolName: String = "person.fill"

    /// Away at college: keep every history row, hide from the pickers.
    var isActive: Bool = true

    /// Portion weight as EXACT INTEGERS, never a `Double`.
    ///
    /// `CLAUDE.md` says full or half, and `HouseholdView` offers exactly those two — but the
    /// STORAGE is a rational pair rather than a `Bool`, for one reason: a `Bool` cannot later
    /// become 3/2 for a teenager without a type-change migration, and a rational pair can.
    /// Three stored thirds as `Double`s sum to 0.9999999 and are only recovered by an
    /// approximation that happens to snap; integers make the question disappear.
    ///
    /// This is what scales a recipe — not a head count. "4 eaters" meaning two adults and
    /// two half portions is 3 servings, and cooking 4 wastes food every time.
    var portionNumerator: Int = 1
    var portionDenominator: Int = 1

    var notes: String = ""
    var sortIndex: Int = 0
    var createdAt: Date = .now

    @Relationship(deleteRule: .cascade, inverse: \AttendanceDefault.eater)
    var attendanceDefaults: [AttendanceDefault]? = []

    /// `.nullify`, not `.cascade`: removing a person must not rewrite what the household
    /// ate. The attendance row survives, carrying `eaterNameSnapshot` and its own portion
    /// snapshot, so a 2027 meal still reads "3 eaters" after someone moves out.
    @Relationship(deleteRule: .nullify, inverse: \MealAttendance.eater)
    var attendance: [MealAttendance]? = []

    init(
        id: UUID = UUID(),
        name: String = "",
        shortName: String = "",
        colorIndex: Int = 0,
        symbolName: String = "person.fill",
        isActive: Bool = true,
        portionNumerator: Int = 1,
        portionDenominator: Int = 1,
        notes: String = "",
        sortIndex: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.colorIndex = colorIndex
        self.symbolName = symbolName
        self.isActive = isActive
        self.portionNumerator = portionNumerator
        self.portionDenominator = portionDenominator
        self.notes = notes
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

extension Eater {
    /// Guarded on both ends. A zero or negative pair is a row written by a bug or by a
    /// future build, and a zero portion silently removes the person from every scale
    /// instead of showing up as a wrong number; a full portion is the visible fallback.
    var portion: Rational {
        let r = Rational(portionNumerator, max(1, portionDenominator))
        return r > .zero ? r : .one
    }

    /// What `HouseholdView` toggles. Anything else was set by a future build and is shown
    /// as it is, rather than being rounded into one of two values.
    var isHalfPortion: Bool { portion == Rational(1, 2) }

    var initials: String {
        shortName.isEmpty ? String(name.prefix(2)) : shortName
    }

    var displayName: String {
        name.isEmpty ? "Unnamed" : name
    }

    /// Writing the pair through one call keeps the two integers from drifting apart the way
    /// a view assigning them one at a time eventually lets them.
    func setPortion(_ newPortion: Rational) {
        guard newPortion > .zero else { return }
        portionNumerator = newPortion.numerator
        portionDenominator = newPortion.denominator
    }
}
