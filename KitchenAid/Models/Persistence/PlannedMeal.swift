import Foundation
import SwiftData

/// One calendar cell.
///
/// There is no `MealPlan` container entity. A plan object would mean ceremony before you can
/// plan Tuesday, and a week boundary is a view concern that would then get baked into the
/// data. A date range is a query.
///
/// A meal may hold **several recipes** — Tuesday dinner is a main plus two sides, scaled
/// together for whoever is eating — or **none at all**, which is what takeout, eating out
/// and a bare note are. `mealRecipes` being empty is a legitimate, expected state and not a
/// half-filled row.
@Model
final class PlannedMeal {
    var id: UUID = UUID()

    var date: Date = Calendar.current.startOfDay(for: .now)

    /// yyyymmdd as an `Int` — the grouping, sorting and query key.
    ///
    /// A `#Predicate` on a `Date` range is correct until he plans a trip, crosses a timezone
    /// or hits a DST boundary, and then "Tuesday's dinner" renders on Monday night — which
    /// he reads as "the app moved my dinner". An integer day is unambiguous, sorts, indexes
    /// and costs four bytes. The real `Date` is kept for display and export. BOTH are
    /// written only by `setDate(_:calendar:)` so they cannot drift.
    var dayKey: Int = 0

    var slotRaw: String = MealSlot.dinner.rawValue

    /// Denormalized from the slot so a `SortDescriptor` can order breakfast before dinner.
    /// A `SortDescriptor` cannot reach a computed property, and sorting on `slotRaw` would
    /// put brunch before dinner alphabetically and prep last.
    var slotSortIndex: Int = MealSlot.dinner.sortIndex

    var orderInSlot: Int = 0

    /// `MealEntryKind`: recipe / leftovers / takeout / eatingOut / note.
    ///
    /// This is what lets a leftovers night contribute nothing to shopping WITHOUT being
    /// flagged skipped. With only an `isSkipped` flag, "do not shop for this" and "we
    /// skipped it" are the same bit, so Tuesday's planned leftovers render on the calendar
    /// as a skipped meal and the two states become permanently indistinguishable.
    var kindRaw: String = MealEntryKind.recipe.rawValue

    /// Used when the kind is not `.recipe`: "Thai takeout". A meal with dishes takes its
    /// title from them.
    var title: String = ""

    var notes: String = ""

    /// "Thanksgiving" — a label, not a container. An occasion entity would be a second
    /// grouping competing with the date for which one owns the meal.
    var occasion: String = ""

    /// `PlanStatus`: planned / cooked / skipped / moved.
    ///
    /// `.cooked` is excluded from shopping collection as well as `.skipped`, because cooking
    /// already depleted inventory and collecting it again shops twice for a meal already
    /// made.
    var statusRaw: String = PlanStatus.planned.rawValue

    /// A per-meal override that is NOT about the kind. "We are eating out but I still want
    /// the dessert ingredients" is rare; this is for it.
    var excludeFromShopping: Bool = false

    // MARK: Guests — COUNTED, NEVER NAMED
    //
    // `CLAUDE.md`: named people with a portion are `Eater` rows. A party is a number.
    // "Eight for dinner Saturday" is one stepper, and nobody permanently joins the roster —
    // which is what a one-off guest ROW would have done, showing up in every picker and
    // every PDF legend forever after one dinner.
    //
    // The portion is a single rational for the whole group, defaulting to full. A table of
    // eight adults and a table of eight including four children differ by one stepper, not
    // by eight rows.

    var guestCount: Int = 0
    var guestPortionNumerator: Int = 1
    var guestPortionDenominator: Int = 1

    /// Takeout, optional. Cents, because a currency in a `Double` is a rounding bug with a
    /// receipt attached.
    var costCents: Int? = nil

    var createdAt: Date = .now

    /// Tuesday is Sunday's ragù again.
    ///
    /// A leftovers meal contributes NOTHING to shopping and draws servings from its source;
    /// the source cooks extra via `MealRecipe.plannedLeftoverServings`.
    ///
    /// THE DOUBLE-COUNT RULE, decided: a separate leftovers meal draws down the source's
    /// `servingsCooked`. `.leftoversOnly` attendance AT THE SOURCE MEAL is the mutually
    /// exclusive alternative — for "he will take a plate to work", where there is no
    /// calendar entry to make. `PlannedMealEditorSheet` refuses both for the same person
    /// against the same source, because allowing both double-counts a portion and the
    /// calendar then cannot say "you are a portion short".
    ///
    /// The macro lives on `leftoverMeals` below. A self-relationship still names its
    /// inverse explicitly.
    var leftoversFrom: PlannedMeal? = nil

    /// `.nullify`: Tuesday's leftovers become an ordinary meal when Sunday's is deleted,
    /// not a second deletion he did not ask for.
    @Relationship(deleteRule: .nullify, inverse: \PlannedMeal.leftoversFrom)
    var leftoverMeals: [PlannedMeal]? = []

    @Relationship(deleteRule: .cascade, inverse: \MealRecipe.meal)
    var mealRecipes: [MealRecipe]? = []

    @Relationship(deleteRule: .cascade, inverse: \MealAttendance.meal)
    var attendance: [MealAttendance]? = []

    /// The live edges that make "drop Thursday's dinner from this list" and "jump to the
    /// meal that caused this line" into queries rather than a decode-every-blob scan. Both
    /// are `.nullify`: deleting a meal must leave the already-bought line and the
    /// already-recorded depletion alone, because those happened. The snapshots on the far
    /// rows preserve history; these edges preserve navigability. Both are needed.
    @Relationship(deleteRule: .nullify, inverse: \ShoppingListSource.plannedMeal)
    var shoppingSources: [ShoppingListSource]? = []

    @Relationship(deleteRule: .nullify, inverse: \InventoryTransaction.plannedMeal)
    var inventoryTransactions: [InventoryTransaction]? = []

    init(
        id: UUID = UUID(),
        date: Date = Calendar.current.startOfDay(for: .now),
        dayKey: Int = 0,
        slotRaw: String = MealSlot.dinner.rawValue,
        slotSortIndex: Int = MealSlot.dinner.sortIndex,
        orderInSlot: Int = 0,
        kindRaw: String = MealEntryKind.recipe.rawValue,
        title: String = "",
        notes: String = "",
        occasion: String = "",
        statusRaw: String = PlanStatus.planned.rawValue,
        excludeFromShopping: Bool = false,
        guestCount: Int = 0,
        guestPortionNumerator: Int = 1,
        guestPortionDenominator: Int = 1,
        costCents: Int? = nil,
        createdAt: Date = .now,
        leftoversFrom: PlannedMeal? = nil
    ) {
        self.id = id
        self.date = date
        self.dayKey = dayKey
        self.slotRaw = slotRaw
        self.slotSortIndex = slotSortIndex
        self.orderInSlot = orderInSlot
        self.kindRaw = kindRaw
        self.title = title
        self.notes = notes
        self.occasion = occasion
        self.statusRaw = statusRaw
        self.excludeFromShopping = excludeFromShopping
        self.guestCount = guestCount
        self.guestPortionNumerator = guestPortionNumerator
        self.guestPortionDenominator = guestPortionDenominator
        self.costCents = costCents
        self.createdAt = createdAt
        self.leftoversFrom = leftoversFrom
    }
}

// MARK: - Reading the cell

extension PlannedMeal {
    var slot: MealSlot { MealSlot(rawValue: slotRaw) ?? .dinner }
    var kind: MealEntryKind { MealEntryKind(rawValue: kindRaw) ?? .recipe }
    var status: PlanStatus { PlanStatus(rawValue: statusRaw) ?? .planned }

    var orderedMealRecipes: [MealRecipe] {
        (mealRecipes ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Roster order first, then name. An `Eater` that has been removed sorts last rather
    /// than first: `Int.max` for a missing row keeps the people still in the household at
    /// the top of the attendance grid.
    var orderedAttendance: [MealAttendance] {
        (attendance ?? []).sorted {
            ($0.eater?.sortIndex ?? Int.max, $0.displayName)
                < ($1.eater?.sortIndex ?? Int.max, $1.displayName)
        }
    }

    var hasDishes: Bool { !(mealRecipes ?? []).isEmpty }

    /// The single predicate the shopping builder filters on.
    ///
    /// `.leftovers`, `.takeout`, `.eatingOut` and `.note` contribute nothing BY KIND, not by
    /// being marked skipped. `.cooked` is excluded because it already depleted.
    var contributesToShopping: Bool {
        kind == .recipe
            && !excludeFromShopping
            && status != .skipped
            && status != .cooked
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let names = orderedMealRecipes.map(\.displayTitle).filter { !$0.isEmpty }
        if !names.isEmpty { return names.joined(separator: " + ") }
        return kind == .recipe ? "Untitled meal" : kind.defaultTitle
    }

    /// Total cooked across the meal's dishes — what a leftovers child draws down.
    var servingsCookedTotal: Int {
        orderedMealRecipes.reduce(0) { $0 + ($1.servingsCooked ?? 0) }
    }
}

// MARK: - Portions
//
// This is where fractional scaling comes from, and why none of it touches `Double`.
// Two full portions, one half and two guests is 2 + 1/2 + 2 = 9/2 portions; against a
// recipe that serves 4 that is a scale of 9/8, and the shopping list then wants 9/8 of
// 1/3 cup, exactly. A head count cannot express any of that, and a `Double` sum of thirds
// is only recovered by an approximation that happens to snap.

extension PlannedMeal {
    var guestPortion: Rational {
        let r = Rational(guestPortionNumerator, max(1, guestPortionDenominator))
        return r > .zero ? r : .one
    }

    /// Household portions only. `.attending` and `.leftoversOnly` consume; `.away` and
    /// `.maybe` do not — see `MealAttendance.consumesPortion`.
    var householdPortions: Rational {
        orderedAttendance
            .filter { $0.consumesPortion }
            .reduce(Rational.zero) { $0 + $1.effectivePortion }
    }

    /// Guests are counted, so this is one multiplication rather than a sum over rows.
    var guestPortions: Rational {
        guard guestCount > 0 else { return .zero }
        return Rational(guestCount) * guestPortion
    }

    /// What this meal is being cooked for, before any per-dish leftover extra.
    ///
    /// `.zero` is a real answer and not an error: a meal with nobody assigned must neither
    /// silently buy nothing nor silently buy for four. `MealScaling` turns it into a
    /// `.noAttendance` note and the per-device default diner count, visibly.
    var portionTotal: Rational {
        householdPortions + guestPortions
    }

    /// The head count, for a label. It is NOT what anything scales by — "4 eaters" meaning
    /// two adults and two half portions is 3 servings, and the two numbers are different on
    /// purpose.
    var eaterCount: Int {
        orderedAttendance.filter { $0.consumesPortion }.count + max(0, guestCount)
    }
}

// MARK: - Writing the cell

extension PlannedMeal {
    /// The ONLY place `date` and `dayKey` are written, so they cannot disagree. Every move,
    /// duplicate and week-copy goes through here.
    func setDate(_ newDate: Date, calendar: Calendar = .current) {
        date = calendar.startOfDay(for: newDate)
        dayKey = CalendarKey.dayKey(for: date, in: calendar)
    }

    /// Likewise the only place the slot pair is written: `slotSortIndex` exists solely to be
    /// sorted on, and a view that sets `slotRaw` alone leaves the calendar ordering stale
    /// with nothing on screen to say so.
    func setSlot(_ newSlot: MealSlot) {
        slotRaw = newSlot.rawValue
        slotSortIndex = newSlot.sortIndex
    }

    func setKind(_ newKind: MealEntryKind) {
        kindRaw = newKind.rawValue
    }

    func setStatus(_ newStatus: PlanStatus) {
        statusRaw = newStatus.rawValue
    }

    func setGuests(count: Int, portion: Rational = .one) {
        guestCount = max(0, count)
        guard portion > .zero else { return }
        guestPortionNumerator = portion.numerator
        guestPortionDenominator = portion.denominator
    }
}
