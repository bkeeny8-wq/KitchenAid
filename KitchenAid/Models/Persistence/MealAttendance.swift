import Foundation
import SwiftData

/// Join: WHO is eating, and how much.
///
/// An explicit join rather than a bare many-to-many, because attendance CARRIES DATA: a
/// status and a portion override. Portions live on the EDGE, which is what makes "scale by
/// the number of eaters" correct for a table of two adults and a child, and makes
/// fractional servings fall out of the arithmetic instead of being special-cased.
///
/// There is no `guestName` here and no acknowledged-warning child. An unnamed head at a
/// party is `PlannedMeal.guestCount` — counted, never named — and dietary and allergy data
/// were declined, so there is no hook for them either. Every row here is a household
/// member, and `eater == nil` means exactly one thing: the person was removed from the
/// roster and `eaterNameSnapshot` is now the name.
@Model
final class MealAttendance {
    var id: UUID = UUID()

    /// `AttendanceStatus`: attending / away / maybe / leftoversOnly. One tap cycles it, so a
    /// four-person dinner is four taps and no sheet.
    var statusRaw: String = AttendanceStatus.attending.rawValue

    /// Exact integers. Both `nil` or both set; `setPortionOverride(_:)` is the only writer
    /// that cannot leave a numerator without its denominator. `nil` = use the snapshot.
    var portionOverrideNumerator: Int? = nil
    var portionOverrideDenominator: Int? = nil

    /// Denormalized on purpose. `Eater` deletion is `.nullify`, and a 2027 meal that says
    /// "3 eaters" must not become "0 eaters" because someone moved out. Integers and not a
    /// `Double`: this is an input to a scale, and the one place a scale is derived must not
    /// launder its operands through floating point.
    var portionSnapshotNumerator: Int = 1
    var portionSnapshotDenominator: Int = 1

    var eaterNameSnapshot: String = ""

    /// "no horseradish", "sauce on the side". A note on a plate, which is not a dietary
    /// restriction and does not warn about anything.
    var plateNote: String = ""

    /// The macro lives on `Eater.attendance` (`.nullify`), so the `inverse:` is declared
    /// there and not here.
    var eater: Eater? = nil

    /// Owner. The macro lives on `PlannedMeal.attendance` (`.cascade`).
    var meal: PlannedMeal? = nil

    init(
        id: UUID = UUID(),
        statusRaw: String = AttendanceStatus.attending.rawValue,
        portionOverrideNumerator: Int? = nil,
        portionOverrideDenominator: Int? = nil,
        portionSnapshotNumerator: Int = 1,
        portionSnapshotDenominator: Int = 1,
        eaterNameSnapshot: String = "",
        plateNote: String = "",
        eater: Eater? = nil,
        meal: PlannedMeal? = nil
    ) {
        self.id = id
        self.statusRaw = statusRaw
        self.portionOverrideNumerator = portionOverrideNumerator
        self.portionOverrideDenominator = portionOverrideDenominator
        self.portionSnapshotNumerator = portionSnapshotNumerator
        self.portionSnapshotDenominator = portionSnapshotDenominator
        self.eaterNameSnapshot = eaterNameSnapshot
        self.plateNote = plateNote
        self.eater = eater
        self.meal = meal
    }
}

extension MealAttendance {
    var status: AttendanceStatus { AttendanceStatus(rawValue: statusRaw) ?? .attending }

    /// The override if there is one, otherwise the snapshot taken when the row was written.
    ///
    /// It reads the SNAPSHOT and not `eater?.portion` deliberately: changing a person from a
    /// full portion to a half today must not rewrite what last month's dinners were cooked
    /// for. The live `Eater` is what a NEW row snapshots, not what an old row reports.
    var effectivePortion: Rational {
        if let n = portionOverrideNumerator, let d = portionOverrideDenominator, d != 0 {
            let r = Rational(n, d)
            if r > .zero { return r }
        }
        let snapshot = Rational(portionSnapshotNumerator, max(1, portionSnapshotDenominator))
        return snapshot > .zero ? snapshot : .one
    }

    var portionOverride: Rational? {
        guard let n = portionOverrideNumerator, let d = portionOverrideDenominator, d != 0
        else { return nil }
        let r = Rational(n, d)
        return r > .zero ? r : nil
    }

    var displayName: String {
        if let name = eater?.name, !name.isEmpty { return name }
        return eaterNameSnapshot.isEmpty ? "Removed" : eaterNameSnapshot
    }

    var initials: String { eater?.initials ?? String(displayName.prefix(2)) }

    /// True when the person this row is about is no longer on the roster. The row stays —
    /// history survives the person — and this is what lets the attendance grid show it as
    /// past rather than offering to edit it.
    var isOrphaned: Bool { eater == nil }

    /// `.attending` and `.leftoversOnly` both consume a portion of what is cooked; `.away`
    /// and `.maybe` do not. A `.maybe` is surfaced as a badge on the meal so he can decide,
    /// and is deliberately NOT counted — buying for a maybe every week is how a plan drifts
    /// into over-buying.
    var consumesPortion: Bool {
        status == .attending || status == .leftoversOnly
    }

    // MARK: Writing

    func setStatus(_ newStatus: AttendanceStatus) {
        statusRaw = newStatus.rawValue
    }

    /// One tap, cycling attending → away → maybe → leftoversOnly.
    func cycleStatus() {
        statusRaw = status.next.rawValue
    }

    /// Passing `nil` clears both halves, which is the whole reason this is a function.
    func setPortionOverride(_ newPortion: Rational?) {
        guard let newPortion = newPortion, newPortion > .zero else {
            portionOverrideNumerator = nil
            portionOverrideDenominator = nil
            return
        }
        portionOverrideNumerator = newPortion.numerator
        portionOverrideDenominator = newPortion.denominator
    }

    /// Taken at the moment the row is created, from the roster as it reads then. Called by
    /// `MealPlanService` when attendance is first set for a meal; calling it again on an old
    /// row would rewrite history, which is what `effectivePortion` reading the snapshot is
    /// there to prevent.
    func captureSnapshot(from eater: Eater) {
        self.eater = eater
        eaterNameSnapshot = eater.name
        let portion = eater.portion
        portionSnapshotNumerator = portion.numerator
        portionSnapshotDenominator = portion.denominator
    }
}
