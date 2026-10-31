import Foundation

/// Every enum is `String`-raw-value-backed. On the SwiftData side it is stored as a
/// `…Raw: String` with a computed accessor that falls back to a default, so a value written
/// by a newer build on another device DEGRADES gracefully instead of failing to decode —
/// CFAL3's `Session.mode` convention. On the content side the same raw values are what a
/// recipe file writes.

enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case us, metric, agnostic
}

enum MealSlot: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A REAL slot, not a nicety. The fixture's step 1 is a 30-minute passive rest and its
    /// notes say the spinach can be made a day ahead, so "salt the steaks, uncovered in the
    /// fridge" has to land on Friday for Saturday's dinner. It sorts first because it is work
    /// done ahead of the day's meals.
    case prep
    case breakfast, brunch, lunch, snack, dinner, dessert, other

    var id: String { rawValue }

    var sortIndex: Int {
        switch self {
        case .prep: return 0
        case .breakfast: return 1
        case .brunch: return 2
        case .lunch: return 3
        case .snack: return 4
        case .dinner: return 5
        case .dessert: return 6
        case .other: return 7
        }
    }

    var title: String {
        switch self {
        case .prep: return "Prep ahead"
        case .breakfast: return "Breakfast"
        case .brunch: return "Brunch"
        case .lunch: return "Lunch"
        case .snack: return "Snack"
        case .dinner: return "Dinner"
        case .dessert: return "Dessert"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .prep: return "clock.badge.checkmark"
        case .breakfast: return "sunrise"
        case .brunch: return "sun.max"
        case .lunch: return "sun.min"
        case .snack: return "carrot"
        case .dinner: return "moon.stars"
        case .dessert: return "birthday.cake"
        case .other: return "fork.knife"
        }
    }

    /// What `GenerateShoppingListSheet` offers and what the default list build uses. `.prep`
    /// is excluded because its ingredients belong to the meal it prepares for, and including
    /// both would buy the steak twice.
    static let shoppableDefaults: Set<MealSlot> =
        [.breakfast, .brunch, .lunch, .snack, .dinner, .dessert, .other]
}

enum MealEntryKind: String, Codable, CaseIterable, Sendable {
    case recipe, leftovers, takeout, eatingOut, note

    var defaultTitle: String {
        switch self {
        case .recipe: return "Meal"
        case .leftovers: return "Leftovers"
        case .takeout: return "Takeout"
        case .eatingOut: return "Eating out"
        case .note: return "Note"
        }
    }

    var symbol: String {
        switch self {
        case .recipe: return "book.closed"
        case .leftovers: return "arrow.triangle.2.circlepath"
        case .takeout: return "bag"
        case .eatingOut: return "building.2"
        case .note: return "note.text"
        }
    }
}

enum AttendanceStatus: String, Codable, CaseIterable, Sendable {
    case attending, away, maybe, leftoversOnly

    /// One tap cycles in this order. Four taps for a four-person dinner, no sheet.
    var next: AttendanceStatus {
        switch self {
        case .attending: return .away
        case .away: return .maybe
        case .maybe: return .leftoversOnly
        case .leftoversOnly: return .attending
        }
    }
}

enum PlanStatus: String, Codable, CaseIterable, Sendable {
    case planned, cooked, skipped, moved
}

enum CourseKind: String, Codable, CaseIterable, Sendable {
    case appetizer, main, side, sauce, component, dessert, breakfast, drink, bake
}

enum Difficulty: String, Codable, CaseIterable, Sendable {
    case easy, medium, project
}

enum ComponentKind: String, Codable, CaseIterable, Sendable {
    case protein, base, side, sauce, garnish, finish, other
}

enum NoteKind: String, Codable, CaseIterable, Sendable {
    case makeAhead, keyStep, variation, timing, general
}

enum TagKind: String, Codable, CaseIterable, Sendable {
    case cuisine, method, occasion, general
}

/// Applied to the WHOLE-RECIPE scale, with a `.snappedToBatch` note. A per-line "fixed" rule
/// handles the bay leaf but cannot express "you cannot bake 3/4 of a cake" — that is a
/// recipe-level property.
enum BatchGranularity: String, Codable, CaseIterable, Sendable {
    case continuous, halfBatches, wholeBatches

    var step: Rational? {
        switch self {
        case .continuous: return nil
        case .halfBatches: return Rational(1, 2)
        case .wholeBatches: return Rational(1)
        }
    }
}

/// `.fixed` is how "1 bay leaf" and the oil for the pan survive a 3× batch without becoming
/// three bay leaves and a fistful of salt.
enum ScalingRule: String, Codable, CaseIterable, Sendable {
    case linear, fixed
}

enum SubRecipePolicy: String, Codable, CaseIterable, Sendable {
    case expandToIngredients, treatAsItem, assumeOnHand
}

enum StockTrackingMode: String, Codable, CaseIterable, Sendable {
    case tracked, staple, untracked
}

enum StorageKind: String, Codable, CaseIterable, Sendable {
    case pantry, fridge, freezer, spice, bar, other
}

enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case purchase, cookDepletion, waste, manualAdjustment, correction, inventoryCount, giftOut
}

enum ResolutionState: String, Codable, CaseIterable, Sendable {
    case applied
    /// Written with `hasDelta == false`. A cook depletion that needs a density the item does
    /// not carry is RECORDED, not skipped and not guessed, and lands in the "Unresolved
    /// depletions" inbox. A skipped depletion is an invisible overstatement of stock.
    case pendingBridge
    case voided
}

enum LineStatus: String, Codable, CaseIterable, Sendable {
    case needed, haveEnough, partiallyHave, needsBridge, unresolvedItem, manual, staple
}

enum LineSourceKind: String, Codable, CaseIterable, Sendable {
    case plannedMeal
    /// A staple reaches the list by a RULE when its rollup falls below par, rather than only
    /// when a Bool is flipped by hand.
    case parLevel
    case manual
}

enum PlanScope: String, Codable, CaseIterable, Sendable {
    case month, week, day, brief
}
