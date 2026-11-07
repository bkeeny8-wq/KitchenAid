import Foundation
import SwiftData

/// Every write the plan screens make, in one place.
///
/// `MealRecipe` and `MealAttendance` both name a `MealPlanService` in their comments that
/// was never written, and the services frozen for this build do not include one. An
/// `@Observable` service holding no state, only five functions over a `ModelContext`, would
/// be ceremony — so the writes live here as a namespace instead. The comments in the model
/// layer are right about the rules and wrong about the file name.
///
/// The rules this exists to keep in exactly one place:
///
/// - `date` and `dayKey` are written only through `PlannedMeal.setDate(_:)`, and the slot
///   pair only through `setSlot(_:)`. A view assigning `slotRaw` by hand leaves
///   `slotSortIndex` stale and the calendar silently mis-ordered, with nothing on screen to
///   say so.
/// - A NEW attendance row snapshots the roster as it reads now; an existing row is never
///   re-snapshotted. Changing someone to a half portion today must not restate what last
///   month's dinners were cooked for — see `MealAttendance.effectivePortion`.
/// - Attendance is seeded from `AttendanceDefault`, so steady state costs zero taps and
///   "who is eating" is only work on an exceptional night.
enum PlanEditor {

    // MARK: - Meals

    /// Creates the cell. Inserted BEFORE its attendance rows are built, so the children are
    /// attached to an object the context already owns.
    @discardableResult
    static func makeMeal(
        on date: Date,
        slot: MealSlot,
        kind: MealEntryKind = .recipe,
        title: String = "",
        roster: [Eater],
        in context: ModelContext
    ) -> PlannedMeal {
        let meal = PlannedMeal()
        context.insert(meal)
        meal.setDate(date)
        meal.setSlot(slot)
        meal.setKind(kind)
        meal.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        meal.orderInSlot = nextOrderInSlot(dayKey: meal.dayKey, slot: slot, in: context)
        applyAttendanceDefaults(to: meal, roster: roster, in: context)
        return meal
    }

    /// Position among the meals already in that slot that day.
    ///
    /// Filtered in Swift on `dayKey` EQUALITY rather than with a `#Predicate` date range:
    /// one off-by-one at the upper bound of a half-open range shows Wednesday's dinner on
    /// Tuesday, and an integer equality is not capable of that mistake. The store holds a
    /// few meals per week, so fetching and filtering costs nothing worth a macro.
    static func nextOrderInSlot(dayKey: Int, slot: MealSlot, in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<PlannedMeal>())) ?? []
        return all.filter { $0.dayKey == dayKey && $0.slotRaw == slot.rawValue }.count
    }

    /// `.cascade` on `mealRecipes` and `attendance` takes the dishes and the attendance rows
    /// with it, which is right: they describe this cell and nothing else. It does NOT reach
    /// a recipe — recipes are bundled content with no row to delete — nor an `Eater`.
    static func delete(_ meal: PlannedMeal, in context: ModelContext) {
        context.delete(meal)
    }

    // MARK: - Dishes

    /// `sortIndex` is passed in when several dishes are added at once, because the inverse
    /// relationship may not have refreshed between two inserts in the same run loop and two
    /// dishes at index 0 would then order arbitrarily.
    @discardableResult
    static func addDish(
        recipeID: String,
        title: String,
        to meal: PlannedMeal,
        sortIndex: Int? = nil,
        in context: ModelContext
    ) -> MealRecipe {
        let dish = MealRecipe()
        context.insert(dish)
        dish.recipeID = recipeID
        // Written once, when the dish is added, and never again: it is what keeps last
        // March's plan readable after a recipe leaves the bundle.
        dish.recipeTitleSnapshot = title
        dish.sortIndex = sortIndex ?? ((meal.mealRecipes ?? []).reduce(-1) { max($0, $1.sortIndex) } + 1)
        dish.meal = meal
        return dish
    }

    static func removeDish(_ dish: MealRecipe, in context: ModelContext) {
        context.delete(dish)
    }

    // MARK: - Attendance

    /// Called when the meal is created and at no other time.
    ///
    /// Deliberately not re-run when the editor opens: a person who joins the household in
    /// March must not appear at January's dinners. The editor offers them as an explicit
    /// "add to this meal" instead, which is a decision rather than a side effect.
    static func applyAttendanceDefaults(
        to meal: PlannedMeal,
        roster: [Eater],
        in context: ModelContext
    ) {
        let weekday = Calendar.current.component(.weekday, from: meal.date)
        for eater in roster where eater.isActive {
            let status = defaultStatus(for: eater, weekday: weekday, slot: meal.slot)
            add(eater, to: meal, status: status, in: context)
        }
    }

    /// The most specific enabled rule wins.
    ///
    /// "Thursdays, dinner" beats "Thursdays" beats "every meal", because the narrower rule
    /// is the one he wrote to carve an exception out of the broader one. Without an order
    /// here the answer depends on insertion order, which is to say on nothing.
    static func defaultStatus(
        for eater: Eater,
        weekday: Int,
        slot: MealSlot
    ) -> AttendanceStatus {
        let rules = (eater.attendanceDefaults ?? [])
            .filter { $0.applies(weekday: weekday, slot: slot) }
        var best: AttendanceDefault?
        var bestScore = -1
        for rule in rules {
            let score = (rule.weekday == nil ? 0 : 2) + (rule.slotRaw.isEmpty ? 0 : 1)
            if score > bestScore {
                bestScore = score
                best = rule
            }
        }
        return best?.status ?? .attending
    }

    @discardableResult
    static func add(
        _ eater: Eater,
        to meal: PlannedMeal,
        status: AttendanceStatus = .attending,
        in context: ModelContext
    ) -> MealAttendance {
        let row = MealAttendance()
        context.insert(row)
        // The one call that reads the live roster. Everything afterwards reads the snapshot
        // it just took.
        row.captureSnapshot(from: eater)
        row.setStatus(status)
        row.meal = meal
        return row
    }

    /// Taking someone off ONE meal. Not the same act as removing them from the household,
    /// which leaves every row standing.
    static func removeAttendance(_ row: MealAttendance, in context: ModelContext) {
        context.delete(row)
    }

    /// Active people with no row on this meal — what the editor offers to add.
    ///
    /// Matched on the `Eater` identity rather than on the name snapshot, so two people
    /// called Sam are two people.
    static func rosterMissing(from meal: PlannedMeal, roster: [Eater]) -> [Eater] {
        let present = Set((meal.attendance ?? []).compactMap { $0.eater?.id })
        return roster.filter { $0.isActive && !present.contains($0.id) }
    }
}
