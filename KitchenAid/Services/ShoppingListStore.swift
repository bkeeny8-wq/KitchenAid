import Foundation
import Observation
import SwiftData

/// Turns a `ShoppingListBuilder.Draft` into rows, and owns everything he does to a list after
/// it exists: regenerating it without losing what he already checked off, dropping a meal from
/// it, and adding the paper towels that came from no recipe.
///
/// `@Observable` and **not** `@MainActor`: it holds no `ModelContainer` and no mutable state
/// beyond `lastDiff`, and every writing method takes its `ModelContext` explicitly — the same
/// reasoning as `FoodItemResolver`, and the reason a caller inside a background task cannot
/// accidentally write through somebody else's context.
///
/// It creates no `FoodItem`. That is `FoodItemResolver`'s sole job, and the discipline is what
/// substitutes for the `@Attribute(.unique)` CloudKit forbids — so `addManualLine` takes an
/// already-resolved item rather than minting one for a typed name.
@Observable
final class ShoppingListStore {

    /// What changed between the list he shopped and the one he is about to replace it with.
    ///
    /// Names and not ids, because this is read on a sheet: "3 new, 1 no longer needed, 2 changed
    /// quantity". Silently resurrecting a checked-off line is the bug the whole regenerate path
    /// exists to prevent, and a diff he can read is how he can tell it did not happen.
    struct Diff: Sendable {
        var added: [String] = []
        var removed: [String] = []
        var changed: [String] = []

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

        var sentence: String {
            guard !isEmpty else { return "Nothing changed." }
            var parts: [String] = []
            if !added.isEmpty { parts.append("\(added.count) new") }
            if !removed.isEmpty { parts.append("\(removed.count) no longer needed") }
            if !changed.isEmpty { parts.append("\(changed.count) changed quantity") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// The last diff computed, for the sheet to render after a regenerate.
    var lastDiff: Diff? = nil

    init() {}

    // MARK: - Step 10: persist

    /// Writes the list, its lines, their subtotal rows and their source rows, and **freezes the
    /// options the draft was built with** onto the list.
    ///
    /// The options come from `draft.options` rather than from a second parameter, so the frozen
    /// record cannot describe a build that did not happen. That matters because a regenerate
    /// under a different unit system or a different default diner count produces different
    /// numbers, and "which options produced this list" is the only way the diff sheet can
    /// explain why.
    ///
    /// `existing` is the list being replaced. It is **never mutated** — he may already have
    /// shopped off it — and is read only for the store it belongs to and for the check-state
    /// carried across. "Merge into the current list" is an explicit action, not a side effect.
    func materialize(
        draft: ShoppingListBuilder.Draft,
        into context: ModelContext,
        existing: ShoppingList? = nil
    ) -> ShoppingList {
        let options = draft.options
        let list = ShoppingList(
            title: Self.title(for: options.range),
            generatedAt: options.now,
            rangeStart: options.range.start,
            rangeEnd: options.range.end,
            rangeStartDayKey: CalendarKey.dayKey(for: options.range.start),
            rangeEndDayKey: CalendarKey.dayKey(for: options.range.end),
            subtractInventory: options.subtractInventory,
            countExpiredAsAvailable: options.countExpiredAsAvailable,
            expiringGraceDays: options.expiringGraceDays,
            includeStaples: options.includeStaples,
            includeOptionalLines: options.includeOptionalLines,
            maxExpansionDepth: options.maxExpansionDepth,
            unitSystemRaw: options.unitSystem.rawValue,
            defaultDinerCount: options.defaultDinerCount,
            slotsBlob: Self.blob(from: options.slots.map { $0.rawValue }),
            expandedLineIDBlob: Self.blob(from: Array(options.expandedLineIDs)),
            store: existing?.store
        )
        context.insert(list)

        // Step 11's half of the work, gathered BEFORE anything is written: what he had already
        // done to the list being replaced, keyed the way the builder keys a line.
        var carryOver: [ShoppingListBuilder.ItemIdentity: ShoppingListLine] = [:]
        var manualLines: [ShoppingListLine] = []
        if let existing = existing {
            for line in existing.orderedLines {
                if line.isManual {
                    manualLines.append(line)
                    continue
                }
                carryOver[Self.identity(of: line)] = line
            }
        }

        for draftLine in draft.lines {
            let line = insert(draftLine, into: list, in: context)
            if let previous = carryOver[draftLine.identity] {
                apply(previous, to: line, requestedKeys: Set(draftLine.requested.map { $0.dimensionKey }))
            }
        }

        // Paper towels are in no recipe and must survive every regenerate. They are COPIED
        // rather than moved, because the previous list is not ours to edit.
        for manual in manualLines {
            copyManual(manual, into: list, in: context)
        }

        return list
    }

    /// The previous list is left **exactly** as it was and a NEW list is written, which is also
    /// why this returns the new one: he may already have shopped off the old one, and whether to
    /// archive it is his decision and not a side effect of regenerating.
    ///
    /// The diff is stored on `lastDiff` and returned, so the caller can show "3 new, 1 no longer
    /// needed, 2 changed quantity" rather than silently swapping a list he was halfway through.
    ///
    /// The draft is the caller's to build: the builder needs meals, three closures and the
    /// catalogue's walk order, none of which this service holds — which is the same reason this
    /// takes no `Options`. `draft.options` carries them.
    func regenerate(
        _ list: ShoppingList,
        from draft: ShoppingListBuilder.Draft,
        in context: ModelContext
    ) -> (list: ShoppingList, diff: Diff) {
        let computed = diff(draft, against: list)
        lastDiff = computed
        let fresh = materialize(draft: draft, into: context, existing: list)
        return (fresh, computed)
    }

    // MARK: - The diff sheet

    /// Compares a draft against a stored list WITHOUT writing anything, so the sheet can be
    /// shown before he commits to replacing what he is holding.
    ///
    /// "Changed quantity" is judged on the `toBuy` rows and on their EXACT base values, not on
    /// the rendered text: two lines reading "1 cup" can differ by a teaspoon, and a diff that
    /// compares strings would call that unchanged and then hand him a different number in the
    /// aisle.
    func diff(_ draft: ShoppingListBuilder.Draft, against list: ShoppingList) -> Diff {
        var result = Diff()

        var before: [ShoppingListBuilder.ItemIdentity: ShoppingListLine] = [:]
        for line in list.orderedLines where !line.isManual {
            before[Self.identity(of: line)] = line
        }

        var seen: Set<ShoppingListBuilder.ItemIdentity> = []
        for draftLine in draft.lines {
            seen.insert(draftLine.identity)
            guard let old = before[draftLine.identity] else {
                result.added.append(draftLine.displayName)
                continue
            }
            if Self.basesByDimension(old.toBuy) != Self.basesByDimension(draftLine.toBuy) {
                result.changed.append(draftLine.displayName)
            }
        }
        for (identity, line) in before where !seen.contains(identity) {
            result.removed.append(line.displayName)
        }

        result.added.sort { ShoppingListLine.displayNamePrecedes($0, $1) }
        result.removed.sort { ShoppingListLine.displayNamePrecedes($0, $1) }
        result.changed.sort { ShoppingListLine.displayNamePrecedes($0, $1) }
        return result
    }

    // MARK: - Paper towels

    /// A line no recipe caused. `item` is already resolved, or nil for something the catalogue
    /// has never heard of — this service does not create a `FoodItem`, and a typed name that
    /// should become one goes through `FoodItemResolver` at the call site.
    ///
    /// It is written at the END of its section rather than re-sorted into it: he just typed it
    /// and he is looking at the list, so the line belongs where his eye already is.
    @discardableResult
    func addManualLine(
        _ name: String,
        item: FoodItem? = nil,
        quantity: Quantity? = nil,
        to list: ShoppingList,
        in context: ModelContext
    ) -> ShoppingListLine {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = item?.displayName ?? (trimmed.isEmpty ? "Item" : trimmed)
        let section = item?.defaultSection
        let line = ShoppingListLine(
            sortIndex: Self.nextSortIndex(inSectionNamed: section?.displayName ?? ShoppingListBuilder.unsortedSectionName, of: list),
            displayName: displayName,
            sectionNameSnapshot: section?.displayName ?? ShoppingListBuilder.unsortedSectionName,
            sectionSortIndex: section?.sortIndex ?? ShoppingListBuilder.unsortedSectionSortIndex,
            statusRaw: LineStatus.manual.rawValue,
            flagsBlob: LineFlag.encode([.manual]),
            isManual: true,
            foodItem: item,
            list: list
        )
        context.insert(line)

        if let quantity = quantity {
            let subtotal = QuantitySubtotal(
                dimensionKey: quantity.dimensionKey,
                base: quantity.base,
                preferredUnit: quantity.unit
            )
            // Three roles and not four: nothing was subtracted for a line he typed, so it has
            // no `have` row. `purchase` is written because that is what
            // `InventoryLedger.receive` posts on the trip home — without it the paper towels
            // he checked off come home into nothing.
            for role in [SubtotalRole.requested, .toBuy, .purchase] {
                write([subtotal], role: role, onto: line, in: context)
            }
        }

        let source = ShoppingListSource(
            kindRaw: LineSourceKind.manual.rawValue,
            mealTitle: "Added by hand",
            scaledText: quantity?.displayString(system: list.unitSystem) ?? "",
            line: line
        )
        context.insert(source)
        return line
    }

    // MARK: - Dropping a meal

    /// "Drop Thursday's dinner from this list", through the live
    /// `ShoppingListSource.plannedMeal` edges — which is why those edges exist beside the
    /// snapshot strings.
    ///
    /// Every line keeps its `have` rows and is re-subtracted from the contributions that
    /// SURVIVE, which is exactly what `ShoppingListSource.contributionBase` is stored for: a
    /// line's requirement is the sum of its sources, so removing a source is arithmetic and not
    /// a rebuild. The status is then recomputed through `ShoppingListBuilder.status` — the one
    /// ladder — rather than through a second copy of it here.
    ///
    /// A line left with no source at all is deleted. A manual line never is: he put it there.
    func drop(meal: PlannedMeal, from list: ShoppingList, in context: ModelContext) {
        let mealID = meal.id
        for line in list.orderedLines {
            let sources = line.orderedSources
            let doomed = sources.filter { $0.plannedMeal?.id == mealID }
            guard !doomed.isEmpty else { continue }

            for source in doomed { context.delete(source) }
            let survivors = sources.filter { $0.plannedMeal?.id != mealID }

            // Nothing gives a manual line a meal source, so this is unreachable today — and it
            // is written anyway, because if it ever is reached his numbers are not ours to
            // recompute and the ladder below would overwrite `.manual`.
            if line.isManual { continue }

            if survivors.isEmpty {
                context.delete(line)
                continue
            }
            recompute(line, from: survivors, in: context)
        }
    }

    /// Re-sums a line from the sources it has left, re-subtracts what the stored `have` rows
    /// say, and rewrites `requested` / `toBuy` / `purchase`.
    ///
    /// The two facts the ladder needs that are not arithmetic — is it unmatched, and is it a
    /// diverted staple — are derived from the ITEM and the list's FROZEN options, through the
    /// builder's own `isStapleDiverted`. Reading the stored status back instead loses the
    /// diversion whenever the status was something that outranks it: a staple pinned for a
    /// bridge would come back as an ordinary needed line once the bridge cleared.
    private func recompute(
        _ line: ShoppingListLine,
        from survivors: [ShoppingListSource],
        in context: ModelContext
    ) {
        let system = line.list?.unitSystem ?? .us
        var contributions: [QuantityMath.Contribution] = []
        for source in survivors {
            guard let base = source.contributionBase,
                  let quantity = Self.quantity(
                      inBaseUnitOf: source.contributionDimensionKey, base: base
                  )
            else { continue }
            contributions.append(QuantityMath.Contribution(quantity: quantity))
        }

        let item = line.foodItem
        let requested = QuantityMath.sum(contributions, using: item, system: system)
        let have = line.have.compactMap { $0.asSubtotal }
        let result = QuantityMath.subtract(
            requested: requested, have: have, item: item, system: system
        )

        var flags = line.flags
        flags.formUnion(result.flags)
        let nothingLeftToBuy = !requested.isEmpty && result.toBuy.isEmpty
        if nothingLeftToBuy { flags.remove(.needsBridge) }

        var toBuy = result.toBuy
        let newStatus = ShoppingListBuilder.status(
            isUnresolved: item == nil || flags.contains(.unresolvedItem),
            needsBridge: flags.contains(.needsBridge),
            isStapleDiverted: ShoppingListBuilder.isStapleDiverted(
                item: item,
                hasParShortfall: survivors.contains { $0.kind == .parLevel },
                includeStaples: line.list?.includeStaples ?? false
            ),
            nothingLeftToBuy: nothingLeftToBuy,
            didReduce: result.didReduce
        )
        if newStatus == .staple { toBuy = [] }

        line.statusRaw = newStatus.rawValue
        line.flagsBlob = LineFlag.encode(flags)
        line.isCovered = newStatus == .haveEnough

        // The `have` rows are kept as they were — nothing about his fridge changed — and the
        // other three roles are rewritten wholesale. Replacing rather than editing is why the
        // dimension set can shrink: dropping the only meal that asked for flour by the gram
        // must leave no stale mass row behind.
        for row in line.rows(for: .requested) { context.delete(row) }
        for row in line.rows(for: .toBuy) { context.delete(row) }
        for row in line.rows(for: .purchase) { context.delete(row) }
        write(requested, role: .requested, onto: line, in: context)
        write(toBuy, role: .toBuy, onto: line, in: context)
        write(toBuy, role: .purchase, onto: line, in: context)
    }

    // MARK: - Writing rows

    private func insert(
        _ draftLine: ShoppingListBuilder.DraftLine,
        into list: ShoppingList,
        in context: ModelContext
    ) -> ShoppingListLine {
        let line = ShoppingListLine(
            sortIndex: draftLine.sortIndex,
            displayName: draftLine.displayName,
            sectionNameSnapshot: draftLine.sectionName,
            sectionSortIndex: draftLine.sectionSortIndex,
            statusRaw: draftLine.status.rawValue,
            flagsBlob: LineFlag.encode(draftLine.flags),
            isCovered: draftLine.isCovered,
            unmeasuredNote: draftLine.unmeasuredNote,
            // The draft carries an id and not the object, because the builder is pure. The
            // caller's `resolveItem` closure already minted or found the row, so this is a
            // lookup in the context it was minted in and never a second creation site.
            foodItem: Self.item(withID: draftLine.foodItemID, in: context),
            list: list
        )
        context.insert(line)

        write(draftLine.requested, role: .requested, onto: line, in: context)
        write(draftLine.have, role: .have, onto: line, in: context)
        write(draftLine.toBuy, role: .toBuy, onto: line, in: context)
        write(draftLine.purchase, role: .purchase, onto: line, in: context)

        for (index, draftSource) in draftLine.sources.enumerated() {
            let source = ShoppingListSource(
                sortIndex: index,
                kindRaw: draftSource.kind.rawValue,
                mealDayKey: draftSource.mealDayKey,
                mealSlotRaw: draftSource.mealSlotRaw,
                mealTitle: draftSource.mealTitle,
                recipeTitle: draftSource.recipeTitle,
                componentPath: draftSource.componentPath,
                originalText: draftSource.originalText,
                scaledText: draftSource.scaledText,
                scaleDescription: draftSource.scaleDescription,
                hasContribution: draftSource.contribution != nil,
                contributionDimensionKey: draftSource.contribution?.dimensionKey ?? "",
                contributionBaseNumerator: draftSource.contribution?.base.numerator ?? 0,
                contributionBaseDenominator: draftSource.contribution?.base.denominator ?? 1,
                recipeID: draftSource.recipeID,
                lineID: draftSource.lineID,
                plannedMeal: Self.meal(withID: draftSource.mealID, in: context),
                line: line
            )
            context.insert(source)
        }
        return line
    }

    private func write(
        _ subtotals: [QuantitySubtotal],
        role: SubtotalRole,
        onto line: ShoppingListLine,
        in context: ModelContext
    ) {
        for (index, subtotal) in subtotals.enumerated() {
            // `from(_:role:sortIndex:)` is the only thing that splits an exact `Rational` into
            // the two stored integers: doing it by hand once per role is four chances to store
            // 0/1 and ship a line that asks for nothing.
            let row = ShoppingListLineSubtotal.from(subtotal, role: role, sortIndex: index)
            // Inserted BEFORE the edge is set, so the row is already managed when the inverse
            // on `ShoppingListLine.subtotalRows` is populated.
            context.insert(row)
            row.line = line
        }
    }

    /// Carries across everything he wrote himself, and nothing the builder computed.
    ///
    /// The check-state moves only when the line is asking for the same dimensions it was asking
    /// for before. A line he checked off at "1 cup" that now also wants 200 g is a different
    /// requirement, and carrying the tick across would hide the new number behind a line he
    /// believes he has already bought.
    private func apply(
        _ previous: ShoppingListLine,
        to line: ShoppingListLine,
        requestedKeys: Set<String>
    ) {
        line.noteToSelf = previous.noteToSelf
        line.priceCents = previous.priceCents
        line.destinationLocation = previous.destinationLocation

        let previousKeys = Set(previous.requested.map { $0.dimensionKey })
        guard previousKeys == requestedKeys else { return }
        line.setChecked(previous.isChecked, at: previous.checkedAt ?? .now)
    }

    private func copyManual(
        _ manual: ShoppingListLine,
        into list: ShoppingList,
        in context: ModelContext
    ) {
        let line = ShoppingListLine(
            sortIndex: manual.sortIndex,
            displayName: manual.displayName,
            sectionNameSnapshot: manual.sectionNameSnapshot,
            sectionSortIndex: manual.sectionSortIndex,
            statusRaw: manual.statusRaw,
            flagsBlob: manual.flagsBlob,
            isChecked: manual.isChecked,
            checkedAt: manual.checkedAt,
            noteToSelf: manual.noteToSelf,
            priceCents: manual.priceCents,
            isManual: true,
            unmeasuredNote: manual.unmeasuredNote,
            foodItem: manual.foodItem,
            destinationLocation: manual.destinationLocation,
            list: list
        )
        context.insert(line)

        for role in SubtotalRole.allCases {
            let rows = manual.rows(for: role).compactMap { $0.asSubtotal }
            write(rows, role: role, onto: line, in: context)
        }
        let source = ShoppingListSource(
            kindRaw: LineSourceKind.manual.rawValue,
            mealTitle: "Added by hand",
            line: line
        )
        context.insert(source)
    }

    // MARK: - Helpers

    /// The stored mirror of `ShoppingListBuilder.identity(for:displayName:)`. It delegates, so
    /// there is one rule and not two: a line that derives a different key than the builder did
    /// loses its check-state on every regenerate, silently.
    private static func identity(of line: ShoppingListLine) -> ShoppingListBuilder.ItemIdentity {
        ShoppingListBuilder.identity(for: line.foodItem, displayName: line.displayName)
    }

    private static func basesByDimension(
        _ rows: [ShoppingListLineSubtotal]
    ) -> [String: Rational] {
        var out: [String: Rational] = [:]
        for row in rows { out[row.dimensionKey] = row.base }
        return out
    }

    private static func basesByDimension(_ rows: [QuantitySubtotal]) -> [String: Rational] {
        var out: [String: Rational] = [:]
        for row in rows { out[row.dimensionKey] = row.base }
        return out
    }

    private static func nextSortIndex(
        inSectionNamed name: String, of list: ShoppingList
    ) -> Int {
        let peers = list.orderedLines.filter { $0.sectionNameSnapshot == name }
        return (peers.map { $0.sortIndex }.max() ?? -1) + 1
    }

    /// "count:clove" -> "clove". Empty for volume and mass, where `countUnit` is not the answer.
    private static func countNoun(in dimensionKey: String) -> String {
        let prefix = MeasureDimension.count.rawValue + ":"
        guard dimensionKey.hasPrefix(prefix) else { return "" }
        return String(dimensionKey.dropFirst(prefix.count))
    }

    /// A stored `(dimensionKey, base)` pair back into a `Quantity`, in the dimension's BASE unit
    /// — tsp, g, or the count noun itself — all three of which have a base factor of 1, so the
    /// amount is the base and nothing is divided back out.
    ///
    /// This is the inverse of what `ShoppingListSource` stores, and it exists so that dropping a
    /// meal re-sums the surviving contributions through `QuantityMath` rather than through
    /// arithmetic written a second time here.
    private static func quantity(inBaseUnitOf dimensionKey: String, base: Rational) -> Quantity? {
        if dimensionKey == MeasureDimension.volume.rawValue {
            return Quantity(amount: base, unit: UnitCatalog.teaspoon)
        }
        if dimensionKey == MeasureDimension.mass.rawValue {
            return Quantity(amount: base, unit: UnitCatalog.gram)
        }
        let noun = countNoun(in: dimensionKey)
        guard !noun.isEmpty else { return nil }
        return Quantity(amount: base, unit: UnitCatalog.countUnit(noun: noun))
    }

    /// `id` is carried on the draft instead of the object, because the builder is pure and a
    /// `FoodItem` is a row. A nil result is a line that will render by its snapshotted name,
    /// which is what those snapshots are for.
    private static func item(withID id: UUID?, in context: ModelContext) -> FoodItem? {
        guard let id = id else { return nil }
        var descriptor = FetchDescriptor<FoodItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func meal(withID id: UUID?, in context: ModelContext) -> PlannedMeal? {
        guard let id = id else { return nil }
        var descriptor = FetchDescriptor<PlannedMeal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// `|a|b|` so a `#Predicate` can match a whole token. The §2.8 exception: written once here
    /// and never appended to afterwards.
    private static func blob(from values: [String]) -> String {
        let kept = values.filter { !$0.isEmpty }.sorted()
        guard !kept.isEmpty else { return "" }
        return "|" + kept.joined(separator: "|") + "|"
    }

    /// "Nov 3-9". A `DateFormatter` with an explicit format rather than a style, because the
    /// title is a stored snapshot: a list titled in November must still read "Nov 3-9" if he
    /// changes his region settings in March.
    private static func title(for range: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        let start = formatter.string(from: range.start)
        let end = formatter.string(from: range.end)
        return start == end ? start : "\(start)\u{2013}\(end)"
    }
}
