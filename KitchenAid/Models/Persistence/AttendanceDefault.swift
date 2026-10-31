import Foundation
import SwiftData

/// "He is never home Thursdays."
///
/// Applied when a `PlannedMeal` is created, so steady-state attendance costs ZERO taps and
/// "who is eating" only becomes work on an exceptional night. A plan he has to fill in
/// every week is a plan he stops filling in.
///
/// The two wildcards are spelled differently because the types differ, not by accident:
/// `weekday` is `Int?` and `nil` means every day, while `slotRaw` is a non-optional
/// `String` whose `""` means every slot — the CloudKit rule that every non-optional
/// property carries a default is what rules out an optional-free `MealSlot?` here.
@Model
final class AttendanceDefault {
    var id: UUID = UUID()

    /// `Calendar` weekday, 1 = Sunday. `nil` = every day.
    var weekday: Int? = nil

    /// `MealSlot` raw value. `""` = every slot.
    var slotRaw: String = ""

    /// The `AttendanceStatus` to apply. Stored raw with a defaulting accessor, so a value
    /// written by a newer build on another device degrades instead of failing to decode.
    var statusRaw: String = AttendanceStatus.attending.rawValue

    var isEnabled: Bool = true
    var note: String = ""

    /// Owner. The macro lives on `Eater.attendanceDefaults`, so the `inverse:` is declared
    /// on exactly one side.
    var eater: Eater? = nil

    init(
        id: UUID = UUID(),
        weekday: Int? = nil,
        slotRaw: String = "",
        statusRaw: String = AttendanceStatus.attending.rawValue,
        isEnabled: Bool = true,
        note: String = "",
        eater: Eater? = nil
    ) {
        self.id = id
        self.weekday = weekday
        self.slotRaw = slotRaw
        self.statusRaw = statusRaw
        self.isEnabled = isEnabled
        self.note = note
        self.eater = eater
    }
}

extension AttendanceDefault {
    var status: AttendanceStatus { AttendanceStatus(rawValue: statusRaw) ?? .attending }

    /// `nil` = every slot.
    var slot: MealSlot? {
        slotRaw.isEmpty ? nil : MealSlot(rawValue: slotRaw)
    }

    func applies(weekday day: Int, slot mealSlot: MealSlot) -> Bool {
        guard isEnabled else { return false }
        if let w = weekday, w != day { return false }
        if !slotRaw.isEmpty, slotRaw != mealSlot.rawValue { return false }
        return true
    }

    /// "Thursdays, dinner" — what `AttendanceDefaultsView` lists. Built here rather than in
    /// the view because the two wildcards are a property of this row's encoding.
    var ruleDescription: String {
        let dayPart: String
        if let w = weekday, w >= 1, w <= 7 {
            let symbols = Calendar.current.weekdaySymbols
            dayPart = w <= symbols.count ? symbols[w - 1] + "s" : "Every day"
        } else {
            dayPart = "Every day"
        }
        let slotPart = slot?.title ?? "every meal"
        return "\(dayPart), \(slotPart)"
    }
}
