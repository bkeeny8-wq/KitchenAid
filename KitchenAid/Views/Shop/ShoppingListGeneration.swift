import Foundation
import SwiftData

/// The view layer's glue for `ShoppingListBuilder`, which is pure: it takes three closures,
/// two fetched values and the catalogue's walk order, and reaches for no context of its own.
///
/// This is deliberately NOT a twelfth service. It owns no state, persists nothing and decides
/// nothing — every rule it needs already has exactly one owner (`ShoppingListBuilder` for the
/// arithmetic and the status ladder, `ShoppingListStore` for the rows, `InventoryLedger` for
/// what is on hand, `FoodItemResolver` for minting an item) and this type only hands them to
/// one another. It lives beside the screens that call it so nothing mistakes it for a rule.
///
/// `@MainActor` for a concrete reason, not out of caution: `TweakStore` and `InventoryLedger`
/// are both main-actor isolated, and the closures below call them. A non-`@Sendable` closure
/// inherits the isolation of the context it is formed in, so forming them here is what makes
/// those calls legal inside a builder that is itself non-isolated.
@MainActor
struct ShoppingListGeneration {
    let loader: RecipeLoader
    let catalog: IngredientCatalog
    let tweaks: TweakStore
    let ledger: InventoryLedger
    let context: ModelContext

    /// Monday-to-Sunday is not assumed: the range starts on the day he is standing in, which
    /// is how he shops. Seven days inclusive, so the end is +6 and not +7.
    nonisolated static func defaultRange(from date: Date = .now, days: Int = 7) -> DateInterval {
        range(from: date, days: days)
    }

    /// A whole number of days, start-of-day to end-of-day, because a shopping range is a set
    /// of days and never a set of instants: a range built from `.now` would drop a meal
    /// planned for this morning.
    ///
    /// `nonisolated` because the type is `@MainActor` and that reaches its static members
    /// too: a `@ViewBuilder` property computing a range for an export job is not isolated,
    /// and this touches nothing but a `Calendar`.
    nonisolated static func range(from date: Date, days: Int) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let span = max(1, days)
        let lastDay = calendar.date(byAdding: .day, value: span - 1, to: start) ?? start
        // One second short of midnight, so `dayKey(for: range.end)` is the last day itself
        // rather than the day after it.
        let end = (calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay)
            .addingTimeInterval(-1)
        return DateInterval(start: start, end: max(start, end))
    }

    // MARK: - The build

    /// Steps 1-9, nothing written. The same call backs the preview line on the generation
    /// sheet and the list that gets persisted, so what he is shown is what he gets.
    ///
    /// **This can insert `FoodItem` rows, including from a preview**, because `resolveItem`
    /// mints from a catalogue template and that is `FoodItemResolver`'s sole job. It is the
    /// honest trade: resolving without minting would preview numbers the real build does not
    /// produce (a minted row carries the template's density, which decides whether a line
    /// bridges), and a row minted from the shipped catalogue is vocabulary the pantry needs
    /// anyway — it holds no quantity, no dates and nothing he typed. The resolver de-duplicates
    /// on `matchKey`, so previewing five times mints once.
    func draft(options: ShoppingListBuilder.Options) -> ShoppingListBuilder.Draft {
        let resolver = FoodItemResolver(catalog: catalog)
        return ShoppingListBuilder.build(
            meals: meals(in: options.range),
            resolveRecipe: { id in tweaks.effectiveRecipe(id: id) },
            resolveItem: { catalogName, displayName in
                item(catalogName: catalogName, displayName: displayName, using: resolver)
            },
            inventoryLevel: { item, options in
                // `graceEnd` is `Options`' own derivation and is handed straight across: the
                // ledger is the only thing that can see a lot's date, which is why it returns
                // the flags as well as the numbers.
                ledger.level(
                    of: item,
                    includeExpired: options.countExpiredAsAvailable,
                    asOf: options.now,
                    graceEnd: options.graceEnd
                )
            },
            parLevelShortfalls: parLevelShortfalls(options: options),
            aisleOrder: catalog.aisleOrder,
            options: options
        )
    }

    // MARK: - The closures

    /// The catalogue name the importer matched wins over the display text, and a line that
    /// matches neither resolves to **nil on purpose**.
    ///
    /// `createIfMissing: false` is the load-bearing argument. The resolver consults the
    /// shipped catalogue before it honours that flag, so anything real still mints from its
    /// template; what it stops is a row for "Fat", "Stock", "Pan base" and "Vegetable bed" —
    /// the four column labels in the turkey and gravy documents that are not ingredients at
    /// all. Those lines reach the list as `.unresolvedItem`, pinned under "Needs attention"
    /// where he can see them, instead of quietly becoming four permanent pantry items.
    private func item(
        catalogName: String,
        displayName: String,
        using resolver: FoodItemResolver
    ) -> FoodItem? {
        if !catalogName.isEmpty, let entry = catalog.entry(named: catalogName) {
            return try? resolver.findOrCreate(fromCatalog: entry, in: context)
        }
        return try? resolver.findOrCreate(
            name: displayName, createIfMissing: false, in: context
        )
    }

    /// Days are matched by integer EQUALITY on `dayKey`, never by comparing `Date`s. A
    /// half-open date comparison is correct until he crosses a DST boundary, and then
    /// Tuesday's dinner is shopped for on Monday — the same reason `PlanWeekView` files
    /// meals the same way.
    private func meals(in range: DateInterval) -> [PlannedMeal] {
        let first = CalendarKey.dayKey(for: range.start)
        let last = CalendarKey.dayKey(for: range.end)
        let all = (try? context.fetch(FetchDescriptor<PlannedMeal>())) ?? []
        return all
            .filter { $0.dayKey >= first && $0.dayKey <= last }
            .sorted { ($0.dayKey, $0.slotSortIndex) < ($1.dayKey, $1.slotSortIndex) }
    }

    /// "You keep this stocked and you are short." Folded by the builder into the line the
    /// recipes already created rather than added as a second one.
    ///
    /// The shortfall is compared **within one `dimensionKey`**: a par level of 2 heads of
    /// garlic is not answered by 6 cloves on hand, because nothing converts a clove into a
    /// head and pretending otherwise is purchase-unit rounding, which is cut.
    private func parLevelShortfalls(
        options: ShoppingListBuilder.Options
    ) -> [(FoodItem, QuantitySubtotal)] {
        let items = (try? context.fetch(FetchDescriptor<FoodItem>())) ?? []
        var out: [(FoodItem, QuantitySubtotal)] = []
        for item in items {
            guard item.hasParLevel, let par = item.parLevel, par.base > .zero else { continue }
            let level = ledger.level(
                of: item,
                includeExpired: options.countExpiredAsAvailable,
                asOf: options.now,
                graceEnd: options.graceEnd
            )
            let onHand = level.subtotals
                .first { $0.dimensionKey == par.dimensionKey }?.base ?? .zero
            let shortfall = (par.base - onHand).clampedAtZero
            guard shortfall > .zero else { continue }
            out.append((
                item,
                QuantitySubtotal(
                    dimensionKey: par.dimensionKey,
                    base: shortfall,
                    preferredUnit: par.unit
                )
            ))
        }
        return out.sorted { ShoppingListLine.displayNamePrecedes($0.0.displayName, $1.0.displayName) }
    }
}
