import Foundation
import SwiftData

/// Which block of `ShoppingListDetailView` a line renders in. Derived, never stored:
/// `statusRaw`, `flagsBlob` and `isCovered` are all written once by the generator, and a
/// fourth stored field saying where the line goes is a fourth field that can disagree with
/// the other three.
enum ShoppingListBlock: Hashable, Sendable {
    case needsAttention
    case aisle
    case covered
    case staples
}

/// One line per `FoodItem` per list.
///
/// ONE line, with N subtotals inside it — the dimension is a key WITHIN the line and is never
/// part of the line's identity. Review 03 found the generator grouping by item AND dimension,
/// which split flour requested by the cup and by the gram into two separate lines and left
/// the volume-mass collapse with nothing to collapse: two lines cannot be added to each
/// other, only two subtotals on one line can.
///
/// All of requested / have / toBuy / purchase are kept. A fully-covered line is marked
/// `isCovered` and rendered collapsed under "Already have (6)" — never removed. A silently
/// absent line is indistinguishable from a bug, and he needs to see the app's belief about
/// his fridge before he will trust it.
@Model
final class ShoppingListLine {
    var id: UUID = UUID()

    /// Position within the section, written by the generator from
    /// `displayNamePrecedes`. Not a tiebreak of last resort: it is the order the preview
    /// sheet showed him, so the printed list cannot re-sort out from under it.
    var sortIndex: Int = 0

    /// Snapshots: a line must stay readable across a catalogue merge or an item delete, and a
    /// printed list must not re-sort when he reorders his aisles in March.
    var displayName: String = ""
    var sectionNameSnapshot: String = ""
    var sectionSortIndex: Int = 0

    /// `LineStatus`: needed / haveEnough / partiallyHave / needsBridge / unresolvedItem /
    /// manual / staple.
    ///
    /// ONE writer: the generator's first-match-wins ladder, once, at build time. Nothing in
    /// the model layer and no view reassigns it — `block` below reads it instead. Review 03
    /// found `.needsBridge` declared, filtered on by the pinned block, and then overwritten
    /// by an unconditional staple pass that ran after the ladder, so the one status with a
    /// user-facing fix was assigned by nobody that survived.
    var statusRaw: String = LineStatus.needed.rawValue

    /// `|`-delimited `LineFlag` raw values.
    ///
    /// A delimited blob under the §2.8 exception: a generated line is frozen and nothing
    /// appends to it, and `flagsBlob.contains("|needsBridge|")` is predicate-queryable, which
    /// a stored `[String]` is not.
    var flagsBlob: String = ""

    // MARK: The four fields he writes himself, in the store, after the list is built
    var isChecked: Bool = false
    var checkedAt: Date? = nil
    var noteToSelf: String = ""
    var priceCents: Int? = nil

    /// Paper towels. Always survives a regenerate.
    var isManual: Bool = false
    /// Fully covered by inventory. Shown collapsed, never hidden.
    var isCovered: Bool = false
    /// Collected unmeasured notes: "to taste", "Pinch". Rendered instead of a number, never
    /// as 0 and never aggregated into "2 pinches".
    var unmeasuredNote: String = ""

    /// Macro lives on `FoodItem.shoppingLines` (`.nullify`).
    var foodItem: FoodItem? = nil
    /// Macro lives on `StorageLocation.shoppingLines`.
    var destinationLocation: StorageLocation? = nil
    /// Owner. Macro lives on `ShoppingList.lines`.
    var list: ShoppingList? = nil

    /// N subtotals, one per (role, dimension).
    ///
    /// Flour legitimately requested by the cup, by the gram AND as "1 package" in the same
    /// week is THREE dimensions. A single `secondaryText` slot drops the third, and a line
    /// that is volume + mass + count has nowhere to put it. Rows also let the
    /// `conversionNote` ride with the SPECIFIC number that was converted, which a line-level
    /// string cannot.
    @Relationship(deleteRule: .cascade, inverse: \ShoppingListLineSubtotal.line)
    var subtotalRows: [ShoppingListLineSubtotal]? = []

    /// Why this line exists. He will ask.
    @Relationship(deleteRule: .cascade, inverse: \ShoppingListSource.line)
    var sources: [ShoppingListSource]? = []

    init(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        displayName: String = "",
        sectionNameSnapshot: String = "",
        sectionSortIndex: Int = 0,
        statusRaw: String = LineStatus.needed.rawValue,
        flagsBlob: String = "",
        isChecked: Bool = false,
        checkedAt: Date? = nil,
        noteToSelf: String = "",
        priceCents: Int? = nil,
        isManual: Bool = false,
        isCovered: Bool = false,
        unmeasuredNote: String = "",
        foodItem: FoodItem? = nil,
        destinationLocation: StorageLocation? = nil,
        list: ShoppingList? = nil
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.displayName = displayName
        self.sectionNameSnapshot = sectionNameSnapshot
        self.sectionSortIndex = sectionSortIndex
        self.statusRaw = statusRaw
        self.flagsBlob = flagsBlob
        self.isChecked = isChecked
        self.checkedAt = checkedAt
        self.noteToSelf = noteToSelf
        self.priceCents = priceCents
        self.isManual = isManual
        self.isCovered = isCovered
        self.unmeasuredNote = unmeasuredNote
        self.foodItem = foodItem
        self.destinationLocation = destinationLocation
        self.list = list
    }
}

// MARK: - Reading the line

extension ShoppingListLine {
    var status: LineStatus { LineStatus(rawValue: statusRaw) ?? .needed }
    var flags: Set<LineFlag> { LineFlag.decode(flagsBlob) }

    /// The ONE definition of within-section order, used by the generator to write
    /// `sortIndex` and by `ShoppingList.orderedLines` to re-sort a stored list.
    ///
    /// `localizedStandardCompare` is the Finder's comparison: case- and diacritic-insensitive
    /// and numerically aware, so "Parmesan" sorts beside "butter" rather than ahead of it and
    /// "2% milk" sorts before "10% cream". Raw `String <` compares Unicode scalars, which is
    /// what review 03 caught the list falling back to.
    static func displayNamePrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    /// Where this line renders — decided here and nowhere else, so the four blocks are
    /// mutually exclusive and together hold every line.
    ///
    /// The precedence is the decision review 03 asked for, and it is deliberate:
    ///
    /// 1. A line the app could not finish is pinned first, EVEN IF it is a staple and even
    ///    if inventory covered it. `all-purpose flour` ships `staple: true` in the shipped
    ///    catalogue, so an unconditional staple diversion sends the one line carrying a
    ///    missing density — the line whose "1 cup = ___ g" tap is the fix — into a collapsed
    ///    footer, on real data. Both the status and the flag are consulted because the
    ///    generator records the condition in both and either one alone has been the one that
    ///    went missing.
    /// 2. Staples next, because "assumed on hand" is a stronger statement than "you have
    ///    enough": staples carry no quantity at all (`CLAUDE.md`), so a covered staple
    ///    belongs under Staples, not under "Already have" as though a number had been
    ///    subtracted.
    /// 3. Then covered, then the aisle he walks.
    var block: ShoppingListBlock {
        if status == .needsBridge || status == .unresolvedItem { return .needsAttention }
        if flags.contains(.needsBridge) || flags.contains(.unresolvedItem) { return .needsAttention }
        if status == .staple { return .staples }
        if isCovered { return .covered }
        return .aisle
    }
}

// MARK: - The four numbers

extension ShoppingListLine {
    /// The relationship is named `subtotalRows` and this is `rows(for:)`, so there is no
    /// `subtotals` property shadowing a `subtotals(_:)` method — the panel had both, which
    /// reads ambiguously at every call site even where it compiles.
    func rows(for role: SubtotalRole) -> [ShoppingListLineSubtotal] {
        (subtotalRows ?? [])
            .filter { $0.role == role }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    var requested: [ShoppingListLineSubtotal] { rows(for: .requested) }
    var have: [ShoppingListLineSubtotal] { rows(for: .have) }
    var toBuy: [ShoppingListLineSubtotal] { rows(for: .toBuy) }
    /// What actually enters the ledger on the trip home. In v1 it is a copy of `toBuy`;
    /// it is its own stored role so purchase-unit rounding could arrive one day as a writer
    /// rather than as a migration (deferred — see `CLAUDE.md`).
    var purchase: [ShoppingListLineSubtotal] { rows(for: .purchase) }

    var orderedSources: [ShoppingListSource] {
        (sources ?? []).sorted { ($0.mealDayKey, $0.sortIndex) < ($1.mealDayKey, $1.sortIndex) }
    }
}

// MARK: - The one thing a view may write

extension ShoppingListLine {
    /// `isChecked` and `checkedAt` are written only here, so a checked line always carries
    /// the instant it was checked and "uncheck" cannot leave a stale timestamp behind that a
    /// later regenerate would read as a completed purchase.
    func setChecked(_ checked: Bool, at date: Date = .now) {
        isChecked = checked
        checkedAt = checked ? date : nil
    }
}
