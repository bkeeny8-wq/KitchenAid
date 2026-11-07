import Foundation
import SwiftData

/// The roster's writes.
///
/// There is no `Household` model and there is not going to be one: the household IS the set
/// of `Eater` rows. A singleton created by a bootstrap-if-empty is a CloudKit liability —
/// two devices both bootstrap, and now there are two households with attendance split
/// across them.
///
/// **No count is hardcoded in here or anywhere near it.** Two are seeded because today it
/// is "mostly just me plus 1 adult", and every function below works the same for one person
/// and for nine.
enum HouseholdEditor {

    /// Appended to the end of the roster, with the next colour in the palette.
    ///
    /// `colorIndex` is taken from the count rather than from the highest index in use, so
    /// adding after a removal reuses a freed colour instead of marching off the end of the
    /// palette. `EaterPalette` wraps anyway, which is what makes an eleventh person a
    /// colour rather than a crash.
    @discardableResult
    static func add(
        name: String,
        shortName: String,
        isHalfPortion: Bool,
        roster: [Eater],
        in context: ModelContext
    ) -> Eater {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let eater = Eater()
        context.insert(eater)
        eater.name = trimmed
        eater.shortName = defaultShortName(for: trimmed, given: shortName)
        eater.colorIndex = roster.count
        eater.sortIndex = (roster.reduce(-1) { max($0, $1.sortIndex) }) + 1
        eater.setPortion(isHalfPortion ? Rational(1, 2) : .one)
        return eater
    }

    /// Two letters for the calendar chip. Taken from the name when he has not typed one,
    /// because a blank chip is unreadable and "Unnamed" in a picker reads as a bug rather
    /// than as an invitation.
    static func defaultShortName(for name: String, given shortName: String) -> String {
        let typed = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return String(typed.prefix(4)) }
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1))
        }
        return String(name.prefix(2))
    }

    /// Removing a person does NOT rewrite history.
    ///
    /// `MealAttendance.eater` is `.nullify`, so every attendance row they are on survives
    /// the delete, carrying `eaterNameSnapshot` and its own portion snapshot. A 2027 dinner
    /// still reads "3 eaters" after someone moves out, and `effectivePortion` still reports
    /// what that meal was cooked for. What DOES go is `attendanceDefaults`, which is
    /// `.cascade` and correct: "he is never home Thursdays" is a rule about a person who is
    /// no longer here.
    ///
    /// The honest wording of the confirmation is in `HouseholdView`, and it says both
    /// halves of this.
    static func remove(_ eater: Eater, in context: ModelContext) {
        context.delete(eater)
    }

    /// Away at college: keep every history row, drop out of the pickers. The alternative
    /// offered beside Remove, because it is what he usually means.
    static func setActive(_ eater: Eater, isActive: Bool) {
        eater.isActive = isActive
    }

    /// How many of this person's planned meals a removal would touch, counted from the
    /// relationship rather than guessed at, so the confirmation can name a number.
    static func plannedMealCount(for eater: Eater) -> Int {
        (eater.attendance ?? []).count
    }

    // MARK: - Attendance defaults

    @discardableResult
    static func addDefault(
        to eater: Eater,
        weekday: Int?,
        slot: MealSlot?,
        status: AttendanceStatus,
        in context: ModelContext
    ) -> AttendanceDefault {
        let rule = AttendanceDefault()
        context.insert(rule)
        rule.weekday = weekday
        // The two wildcards are spelled differently because the types differ: `nil` weekday
        // means every day, and an EMPTY slot string means every slot. A non-optional
        // property has to carry a default, which is what rules out `MealSlot?` here.
        rule.slotRaw = slot?.rawValue ?? ""
        rule.statusRaw = status.rawValue
        rule.eater = eater
        return rule
    }

    static func removeDefault(_ rule: AttendanceDefault, in context: ModelContext) {
        context.delete(rule)
    }

    /// Most specific first, so the list reads in the order `PlanEditor.defaultStatus`
    /// resolves them: "Thursdays, dinner" above "Thursdays" above "every meal".
    static func orderedDefaults(for eater: Eater) -> [AttendanceDefault] {
        (eater.attendanceDefaults ?? []).sorted { a, b in
            let sa = (a.weekday == nil ? 0 : 2) + (a.slotRaw.isEmpty ? 0 : 1)
            let sb = (b.weekday == nil ? 0 : 2) + (b.slotRaw.isEmpty ? 0 : 1)
            if sa != sb { return sa > sb }
            return (a.weekday ?? 0, a.slotRaw) < (b.weekday ?? 0, b.slotRaw)
        }
    }
}
