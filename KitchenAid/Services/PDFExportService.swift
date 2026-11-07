import CoreGraphics
import Foundation
import SwiftData
import SwiftUI

/// RENDERING A PDF HE CAN SHARE. One entry point, three jobs, one file per render.
///
/// **Sharing is `ShareLink`, and only `ShareLink`.** This service returns a `URL` in the
/// temporary directory and stops there: there is no mail API, no upload and no key, because
/// he chose share-sheet delivery. A view hands the returned URL to
/// `ShareLink(item: url)` — which is also why the file is written somewhere the share sheet
/// can read rather than being handed back as `Data`.
///
/// **The collaborators are PARAMETERS of `render`, not payloads of a `Job`.** That is the
/// choice between the two the review left open, and it is the one that keeps a job small
/// enough to queue, log and retry: a `Job` holds ids and values only, so it cannot become a
/// stale snapshot of the store taken at enqueue time, and a job whose recipe has been
/// removed from the bundle fails with `ExportError.recipeMissing` instead of printing a copy
/// nothing can reproduce. Every job needs at least two of the three — the recipe card needs
/// the loader AND the overlay to print the effective recipe with footnotes; the shopping
/// list and the week plan need the context to reach their rows, and the week plan needs the
/// loader on top of it, because a `makeAheadNote` lives in bundled content and not in any
/// row it could carry.
///
/// Not `@MainActor` as a type: `ImageRenderer` and `ModelContext.mainContext` are, so the
/// functions that touch them are, while the nested print views stay ordinary `View`s.
enum PDFExportService {

    // MARK: - Page geometry

    /// Points. A half inch of margin, which is what a home printer will not clip.
    static let margin: CGFloat = 36
    static let blockSpacing: CGFloat = 8

    /// Print black and a muted grey, spelled here rather than taken from the app's theme.
    /// An exported sheet is read on paper under a kitchen light, not on a calibrated screen,
    /// and a semantic colour would resolve against whatever colour scheme the renderer ran
    /// in — which is exactly the bug `Page.init` pins the scheme to avoid.
    static let ink = Color.black
    static let inkMuted = Color.black.opacity(0.55)
    static let hairline = Color.black.opacity(0.25)

    // MARK: - Failures

    /// Every way a render can fail, with a sentence he can act on.
    ///
    /// Export is the one feature whose output leaves the device, so a failure must explain
    /// itself: the alternative is a share sheet holding a zero-byte PDF, which is worse than
    /// an error because it looks like it worked.
    enum ExportError: LocalizedError {
        case contextUnavailable
        case temporaryDirectoryUnwritable
        case nothingToExport
        /// The `recipeID` on the job no longer resolves. The snapshot rides along so the
        /// message can name the dish even though the content is gone.
        case recipeMissing(id: String, titleSnapshot: String)
        case shoppingListMissing(id: UUID)
        case pageMeasurementFailed(page: String)

        var errorDescription: String? {
            switch self {
            case .contextUnavailable:
                return "Could not start a PDF document."
            case .temporaryDirectoryUnwritable:
                return "Could not write the file. There may be no space left."
            case .nothingToExport:
                return "There is nothing in this range to export."
            case .recipeMissing(_, let titleSnapshot):
                let name = titleSnapshot.isEmpty ? "A recipe" : titleSnapshot
                return "\(name) is no longer in the app, so it cannot be printed."
            case .shoppingListMissing:
                return "That shopping list is no longer in the app."
            case .pageMeasurementFailed(let page):
                return "Could not lay out the \(page) page."
            }
        }
    }

    // MARK: - What to print

    /// Ids and values, never rows and never a `Recipe`.
    ///
    /// `titleSnapshot` is carried on the recipe case because `MealRecipe` already holds one
    /// and it is the only thing that can name a dish whose file has been removed. Enum cases
    /// cannot have default arguments in Swift, so callers with nothing to snapshot pass "".
    enum Job {
        case recipe(recipeID: String, scale: Rational, titleSnapshot: String)
        case shoppingList(listID: UUID)
        case weekPlan(interval: DateInterval)
    }

    /// One page: its size and its content, type-erased.
    ///
    /// `AnyView` is normally a smell and here it is correct — these views are rendered ONCE
    /// into a PDF context and never diffed, so the identity `AnyView` costs the update
    /// algorithm is not in play, and what it buys is a heterogeneous page list. That is the
    /// only way one document holds a landscape week grid and two portrait pages, which the
    /// week plan requires: a writer generic over one page type has one `CGSize` and could not
    /// express it at all.
    struct Page: Identifiable {
        let id = UUID()
        let size: CGSize
        /// For `ExportError.pageMeasurementFailed` and for reading a render log.
        let name: String
        let content: AnyView

        init<V: View>(size: CGSize, name: String, @ViewBuilder content: () -> V) {
            self.size = size
            self.name = name
            // The colour scheme and the type size are PINNED. `ImageRenderer` renders in the
            // environment it is handed, so a phone in dark mode would otherwise produce white
            // text on a transparent page, and an accessibility type size would reflow a sheet
            // measured at the default size into something that overflows it.
            self.content = AnyView(
                content()
                    .environment(\.colorScheme, .light)
                    .environment(\.dynamicTypeSize, .large)
            )
        }

        static let portrait = CGSize(width: 612, height: 792)
        static let landscape = CGSize(width: 792, height: 612)
    }

    /// One measured, already-built section of a document.
    ///
    /// There is no `headHeight` and no `isContinuation` here, and that is deliberate:
    /// **pagination packs whole blocks and never slices one**, so a block is never continued
    /// and never needs its head re-emitted. What continues is the PAGE, and the page head
    /// says so. Slicing one tall rendered image at 792pt boundaries cuts text through the
    /// middle of a line, which is an invisible failure; a block too tall for a page gets a
    /// page of its own and overflows visibly, which he can see and fix.
    struct Block {
        let name: String
        let height: CGFloat
        let view: AnyView
    }

    /// A run of pages sharing a size and a heading. A job emits one or more: the week plan
    /// emits three, because its three pages are structurally different and two of them are a
    /// different orientation from the third.
    struct Document {
        let name: String
        let title: String
        let subtitle: String
        let size: CGSize
        let blocks: [Block]
    }

    // MARK: - The entry point

    /// Content plus overlay plus rows, laid out, measured, paginated and written. The URL is
    /// what `ShareLink` takes.
    @MainActor
    static func render(
        _ job: Job,
        loader: RecipeLoader,
        tweaks: TweakStore,
        context: ModelContext
    ) throws -> URL {
        let plan = try documents(for: job, loader: loader, tweaks: tweaks, context: context)

        var pages: [Page] = []
        for document in plan.documents {
            pages.append(contentsOf: try paginate(document))
        }
        // An empty page list is reported, never written. `CGContext.closePDF` on a document
        // with no pages produces a file the share sheet will happily offer and no reader can
        // open.
        guard !pages.isEmpty else { throw ExportError.nothingToExport }

        let url = try destination(named: plan.fileName)
        try write(pages: pages, to: url)
        return url
    }

    @MainActor
    private static func documents(
        for job: Job,
        loader: RecipeLoader,
        tweaks: TweakStore,
        context: ModelContext
    ) throws -> (fileName: String, documents: [Document]) {
        switch job {
        case .recipe(let recipeID, let scale, let titleSnapshot):
            return try recipePlan(
                recipeID: recipeID, scale: scale, titleSnapshot: titleSnapshot,
                loader: loader, tweaks: tweaks
            )
        case .shoppingList(let listID):
            return try shoppingPlan(listID: listID, context: context)
        case .weekPlan(let interval):
            return try weekPlanDocuments(interval: interval, loader: loader, context: context)
        }
    }

    // MARK: - The recipe card

    /// The EFFECTIVE recipe, scaled, with a footnote on every line he has tweaked.
    ///
    /// The sheet taped to a cupboard door should say what he actually does — so it prints the
    /// overlay, not the bundled text — while still admitting where it differs from the
    /// original, which is what the footnotes are for. A printed sheet that silently disagrees
    /// with the recipe file is the one artefact nobody can debug.
    @MainActor
    private static func recipePlan(
        recipeID: String,
        scale: Rational,
        titleSnapshot: String,
        loader: RecipeLoader,
        tweaks: TweakStore
    ) throws -> (fileName: String, documents: [Document]) {
        guard let resolved = tweaks.effectiveRecipe(id: recipeID) else {
            // The one writer of this case, and the reason the job carries an id rather than a
            // copy: a recipe removed from the bundle fails here, by name, instead of printing
            // whatever was cached when the job was made.
            throw ExportError.recipeMissing(id: recipeID, titleSnapshot: titleSnapshot)
        }

        let size = Page.portrait
        let width = size.width - margin * 2
        let effectiveScale = scale > .zero ? scale : .one

        // Footnote numbers are assigned in reading order over the components, so the markers
        // on the page count upwards the way he reads it.
        var markerByLineID: [String: String] = [:]
        var footnotes: [String] = []
        for component in resolved.components {
            for line in component.lines where resolved.isOverridden(lineID: line.lineID) {
                let original = resolved.originalLine(id: line.lineID)
                let asWritten = original?.cookDisplayText ?? ""
                let name = line.displayName.isEmpty ? line.lineID : line.displayName
                footnotes.append(
                    asWritten.isEmpty
                        ? "\(name) — your change; the recipe as written did not list it this way."
                        : "\(name) — as written: \(asWritten)"
                )
                markerByLineID[line.lineID] = "\(footnotes.count)"
            }
        }

        var blocks: [Block] = []

        blocks.append(try block("summary", width: width) {
            RecipeSummaryBlock(
                summary: resolved.summary,
                facts: recipeFacts(resolved, scale: effectiveScale),
                width: width
            )
        })

        for (index, component) in resolved.components.enumerated() {
            // The loader is used here and not only for the title: a component that IS another
            // bundled recipe carries no lines of its own, and a sheet that silently dropped a
            // third of the dish would be worse than one that names what is missing.
            var reference = ""
            if let sourceID = component.sourceRecipeID {
                let sourceTitle = loader.recipe(id: sourceID)?.title ?? ""
                reference = sourceTitle.isEmpty
                    ? "Uses recipe \(sourceID), which is not bundled."
                    : "Uses \(sourceTitle) × \((component.sourceScale * effectiveScale).humanDescription)"
            }
            let rows = component.lines.map {
                ingredientRow(for: $0, scale: effectiveScale, marker: markerByLineID[$0.lineID] ?? "")
            }
            blocks.append(try block("ingredients \(index + 1)", width: width) {
                ComponentBlock(
                    heading: component.title,
                    summary: component.summary,
                    reference: reference,
                    note: component.note,
                    rows: rows,
                    width: width
                )
            })
        }

        for table in resolved.recipe.tables {
            blocks.append(try block("table", width: width) {
                TableBlock(name: table.name, headers: table.headers, rows: table.rows, width: width)
            })
        }

        for (index, step) in resolved.steps.enumerated() {
            // One block per step, so pagination packs whole steps: a method cut between the
            // title and its body is the specific thing a cook cannot recover from.
            blocks.append(try block("method \(index + 1)", width: width) {
                StepBlock(
                    showHead: index == 0,
                    number: step.number > 0 ? step.number : index + 1,
                    title: step.title,
                    detail: step.body,
                    duration: step.durationText ?? "",
                    temperature: stepTemperature(step),
                    isEdited: resolved.isOverridden(stepID: step.stepID),
                    width: width
                )
            })
        }

        let noteRows = resolved.notes
            .filter { !$0.text.isEmpty }
            .map { LabelledRow(label: noteLabel($0.kind), text: $0.text) }
        if !noteRows.isEmpty {
            blocks.append(try block("notes", width: width) {
                LabelledBlock(heading: "Notes", rows: noteRows, width: width)
            })
        }

        if !resolved.userNotes.isEmpty {
            blocks.append(try block("your notes", width: width) {
                LabelledBlock(
                    heading: "Your notes",
                    rows: [LabelledRow(label: "", text: resolved.userNotes)],
                    width: width
                )
            })
        }

        if !footnotes.isEmpty {
            let rows = footnotes.enumerated().map { LabelledRow(label: "\($0.offset + 1)", text: $0.element) }
            blocks.append(try block("footnotes", width: width) {
                LabelledBlock(heading: "Your changes", rows: rows, width: width)
            })
        }

        let title = resolved.title.isEmpty ? titleSnapshot : resolved.title
        let document = Document(
            name: "recipe",
            title: title.isEmpty ? "Recipe" : title,
            subtitle: subtitleLine(resolved.subtitle),
            size: size,
            blocks: blocks
        )
        return (fileName: title, documents: [document])
    }

    /// "Serves 6 · ×1 1/2 · 18 crostini · about 70 min". Built from the EFFECTIVE recipe, so
    /// a tweaked yield reads as tweaked.
    private static func recipeFacts(_ resolved: ResolvedRecipe, scale: Rational) -> [String] {
        var facts: [String] = []
        let servings = (resolved.servings * scale).humanDescription
        facts.append(resolved.recipe.servingsApproximate ? "Serves about \(servings)" : "Serves \(servings)")
        if scale != .one { facts.append("\u{00D7}\(scale.humanDescription) batch") }
        if let yieldLabel = resolved.scaledYieldLabel(at: scale) { facts.append(yieldLabel) }
        let prefix = resolved.timesAreApproximate ? "about " : ""
        if let total = resolved.totalMinutes { facts.append("\(prefix)\(total) min total") }
        if let active = resolved.activeMinutes { facts.append("\(prefix)\(active) min active") }
        if let oven = resolved.recipe.ovenTempF { facts.append("\(oven)\u{00B0}F") }
        if let perPound = resolved.recipe.minutesPerPound {
            facts.append("\(perPound.humanDescription) min per lb")
        }
        if !resolved.sourceName.isEmpty { facts.append(resolved.sourceName) }
        return facts
    }

    /// The scaled amount, the name and whatever qualifies it.
    ///
    /// `scalingRule == .fixed` is honoured here and not in the view: one bay leaf and the oil
    /// for the pan survive a 3× batch without becoming three bay leaves and a fistful of
    /// salt, and a printed sheet is the worst place to discover that it does not.
    private static func ingredientRow(
        for line: IngredientLine,
        scale: Rational,
        marker: String
    ) -> IngredientRow {
        let factor = line.scalingRule == .fixed ? Rational.one : scale
        var amount = line.unmeasuredNote
        if let quantity = line.quantity {
            let low = quantity.scaled(by: factor)
            if let high = line.amountMax,
               let unit = UnitCatalog.unit(code: line.unitCode, fallbackDimension: line.dimension) {
                // A RANGE STAYS A RANGE on the cook's sheet. The latitude is the point of
                // writing it as one — the shopping list is where the high end wins.
                let top = Quantity(amount: high * factor, unit: unit)
                amount = "\(low.amount.humanDescription) to \(top.displayString())"
            } else {
                amount = low.displayString()
            }
        }

        var name = line.displayName
        if !line.preparation.isEmpty {
            name = name.isEmpty ? line.preparation : "\(name), \(line.preparation)"
        }

        var qualifiers: [String] = []
        if line.isChoice, !line.choiceText.isEmpty { qualifiers.append("choice: \(line.choiceText)") }
        if line.isOptional { qualifiers.append("optional") }
        if line.isGarnish { qualifiers.append("garnish") }
        if let alt = line.altQuantity { qualifiers.append(alt.displayString()) }
        if !line.note.isEmpty { qualifiers.append(line.note) }
        if line.scalingRule == .fixed, scale != .one { qualifiers.append("not scaled") }

        return IngredientRow(
            amount: amount,
            name: name.isEmpty ? line.lineID : name,
            qualifier: qualifiers.joined(separator: " \u{00B7} "),
            marker: marker
        )
    }

    private static func stepTemperature(_ step: RecipeStep) -> String {
        var parts: [String] = []
        if let oven = step.ovenTemperatureF { parts.append("oven \(oven)\u{00B0}F") }
        if let internalTemp = step.targetInternalTemperatureF {
            parts.append("to \(internalTemp)\u{00B0}F inside")
        }
        if step.isPassiveRest { parts.append("hands off") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// `LineFlag.rawValue` is an identifier, and "expiringBeforeNeed" on a printed list is
    /// a word he has to decode. Only the flags that change what he does in the shop are
    /// printed; the rest are app-internal and say nothing useful on paper.
    private static func flagText(_ flag: LineFlag) -> String {
        switch flag {
        case .needsBridge: return "could not convert units"
        case .unresolvedItem: return "not in the catalogue"
        case .converted: return "converted"
        case .expiredStockIgnored: return "expired stock ignored"
        case .expiringBeforeNeed: return "on hand but expires first"
        case .tweaked: return "your tweak applied"
        case .noAttendance: return "no eaters set"
        case .unknownYield: return "yield unknown"
        case .snappedToBatch: return "whole batch"
        case .overridden: return "scale overridden"
        case .leftoversIncluded: return "extra for leftovers"
        case .parLevel: return "below par"
        case .assumedOnHand, .manual: return ""
        }
    }

    private static func noteLabel(_ kind: NoteKind) -> String {
        switch kind {
        case .makeAhead: return "Make ahead"
        case .keyStep: return "Key step"
        case .variation: return "Variation"
        case .timing: return "Timing"
        case .general: return ""
        }
    }

    private static func subtitleLine(_ subtitle: String) -> String {
        subtitle.isEmpty ? "KitchenAid" : "\(subtitle) \u{00B7} KitchenAid"
    }

    // MARK: - The shopping list

    /// The frozen list, in the order he walks the store.
    ///
    /// Nothing is recomputed: the blocks, the section order and the quantities all come off
    /// the stored rows, because a list printed in November has to read in March exactly as it
    /// read when he shopped it — which is the whole reason `ShoppingList` freezes its options
    /// and its snapshots in the first place.
    @MainActor
    private static func shoppingPlan(
        listID: UUID,
        context: ModelContext
    ) throws -> (fileName: String, documents: [Document]) {
        // Hoisted into a local: `#Predicate` builds an expression tree and cannot translate
        // string interpolation or a member access on a captured object.
        let needle = listID
        var descriptor = FetchDescriptor<ShoppingList>(
            predicate: #Predicate<ShoppingList> { $0.id == needle }
        )
        descriptor.fetchLimit = 1
        guard let list = try context.fetch(descriptor).first else {
            throw ExportError.shoppingListMissing(id: listID)
        }

        let size = Page.portrait
        let width = size.width - margin * 2
        let system = list.unitSystem

        // Each covered meal gets a number, and a line carries the numbers of the meals that
        // asked for it. That is the "why is this on my list" answer, and it costs one closing
        // block rather than a provenance line under every row.
        var numberByMealID: [UUID: Int] = [:]
        let meals = list.coveredMeals
        for (index, meal) in meals.enumerated() { numberByMealID[meal.id] = index + 1 }

        var blocks: [Block] = []

        let attention = list.needsAttention
        if !attention.isEmpty {
            blocks.append(try block("attention", width: width) {
                ShoppingBlock(
                    heading: "Needs attention",
                    footnote: "The app could not finish the arithmetic on these. Tap them in the app to fix it.",
                    rows: attention.map { shoppingRow($0, system: system, numbers: numberByMealID) },
                    showCheckbox: true,
                    width: width
                )
            })
        }

        for section in list.linesBySection {
            blocks.append(try block("aisle \(section.sectionName)", width: width) {
                ShoppingBlock(
                    heading: section.sectionName.isEmpty ? "Unsorted" : section.sectionName,
                    footnote: "",
                    rows: section.lines.map { shoppingRow($0, system: system, numbers: numberByMealID) },
                    showCheckbox: true,
                    width: width
                )
            })
        }

        let covered = list.coveredFooter
        if !covered.isEmpty {
            // KEPT, never omitted: he has to be able to see the app's belief about his fridge
            // before he will trust it, and a silently absent line is indistinguishable from a
            // bug.
            blocks.append(try block("covered", width: width) {
                ShoppingBlock(
                    heading: "Already have (\(covered.count))",
                    footnote: "",
                    rows: covered.map { shoppingRow($0, system: system, numbers: numberByMealID) },
                    showCheckbox: false,
                    width: width
                )
            })
        }

        let staples = list.staplesFooter
        if !staples.isEmpty {
            blocks.append(try block("staples", width: width) {
                ShoppingBlock(
                    heading: "Staples (assumed on hand)",
                    footnote: "Tracked present or absent, with no quantity.",
                    rows: staples.map { shoppingRow($0, system: system, numbers: numberByMealID) },
                    showCheckbox: false,
                    width: width
                )
            })
        }

        if !meals.isEmpty {
            let rows = meals.enumerated().map { pair in
                LabelledRow(
                    label: "\(pair.offset + 1)",
                    text: "\(dayText(pair.element.dayKey)) \(pair.element.slot.title) \u{00B7} \(pair.element.displayTitle)"
                )
            }
            blocks.append(try block("sources", width: width) {
                LabelledBlock(heading: "Meals this list covers", rows: rows, width: width)
            })
        }

        guard !blocks.isEmpty else { throw ExportError.nothingToExport }

        let title = list.title.isEmpty ? "Shopping list" : list.title
        var subtitleParts: [String] = ["KitchenAid"]
        if let store = list.store { subtitleParts.append(store.displayName) }
        subtitleParts.append("generated \(dayFormatter.string(from: list.generatedAt))")
        if !list.subtractInventory { subtitleParts.append("inventory not subtracted") }

        let document = Document(
            name: "shopping list",
            title: title,
            subtitle: subtitleParts.joined(separator: " \u{00B7} "),
            size: size,
            blocks: blocks
        )
        return (fileName: "shopping-\(title)", documents: [document])
    }

    private static func shoppingRow(
        _ line: ShoppingListLine,
        system: UnitSystem,
        numbers: [UUID: Int]
    ) -> ShoppingRow {
        let toBuy = line.toBuy.map { $0.displayString(system: system) }
        let have = line.have.map { $0.displayString(system: system) }

        var amount = toBuy.joined(separator: " + ")
        if amount.isEmpty { amount = line.unmeasuredNote }

        var qualifiers: [String] = []
        if !have.isEmpty { qualifiers.append("have \(have.joined(separator: " + "))") }
        if !line.noteToSelf.isEmpty { qualifiers.append(line.noteToSelf) }
        if line.isManual { qualifiers.append("added by hand") }
        for flag in line.flags.sorted(by: { $0.rawValue < $1.rawValue }) {
            let text = flagText(flag)
            if !text.isEmpty { qualifiers.append(text) }
        }

        var found: [Int] = []
        for source in line.orderedSources {
            guard let meal = source.plannedMeal, let number = numbers[meal.id] else { continue }
            if !found.contains(number) { found.append(number) }
        }

        return ShoppingRow(
            name: line.displayName.isEmpty ? "Unnamed item" : line.displayName,
            amount: amount,
            qualifier: qualifiers.joined(separator: " \u{00B7} "),
            marker: found.sorted().map { "\($0)" }.joined(separator: ",")
        )
    }

    // MARK: - The week plan: three structurally different pages

    /// A landscape grid, a portrait head count and a portrait prep-ahead page, in one file.
    ///
    /// Three documents and not one, because the three are different shapes AND different
    /// sizes — and because the head count is the page that gets texted to whoever is cooking,
    /// so it has to stand alone rather than being a column of a grid.
    @MainActor
    private static func weekPlanDocuments(
        interval: DateInterval,
        loader: RecipeLoader,
        context: ModelContext
    ) throws -> (fileName: String, documents: [Document]) {
        let keys = CalendarKey.dayKeys(from: interval.start, to: interval.end)
        guard let low = keys.first, let high = keys.last else { throw ExportError.nothingToExport }

        // `low` and `high` are plain captured locals, which is what `#Predicate` can
        // translate. The query is on `dayKey` and not on a `Date` range: a half-open
        // comparison got slightly wrong at the upper bound renders Wednesday's dinner on
        // Tuesday, and an integer equality is not capable of that mistake.
        let mealDescriptor = FetchDescriptor<PlannedMeal>(
            predicate: #Predicate<PlannedMeal> { $0.dayKey >= low && $0.dayKey <= high },
            sortBy: [
                SortDescriptor(\.dayKey, order: .forward),
                SortDescriptor(\.slotSortIndex, order: .forward),
                SortDescriptor(\.orderInSlot, order: .forward)
            ]
        )
        let meals = try context.fetch(mealDescriptor)

        let eaterDescriptor = FetchDescriptor<Eater>(
            sortBy: [
                SortDescriptor(\.sortIndex, order: .forward),
                SortDescriptor(\.name, order: .forward)
            ]
        )
        let eaters = try context.fetch(eaterDescriptor).filter { $0.isActive }

        guard !meals.isEmpty else { throw ExportError.nothingToExport }

        let range = rangeText(from: interval)
        let subtitle = "KitchenAid \u{00B7} \(range) \u{00B7} generated \(dayFormatter.string(from: .now))"
        var documents: [Document] = []

        // --- Page 1: the landscape grid -------------------------------------------------
        let gridSize = Page.landscape
        let gridWidth = gridSize.width - margin * 2
        var columns: [DayColumn] = []
        for key in keys {
            let dayMeals = meals.filter { $0.dayKey == key }
            columns.append(DayColumn(
                title: dayText(key),
                entries: dayMeals.map { meal in
                    GridEntry(
                        slot: meal.slot.title,
                        title: meal.displayTitle,
                        chips: meal.orderedAttendance.filter { $0.consumesPortion }.map { $0.initials },
                        guests: max(0, meal.guestCount),
                        symbol: meal.kind == .recipe ? "" : meal.kind.symbol
                    )
                }
            ))
        }
        var gridBlocks: [Block] = [
            try block("week grid", width: gridWidth) {
                WeekGridBlock(columns: columns, width: gridWidth)
            }
        ]
        if !eaters.isEmpty {
            // The legend is a block of the grid document rather than a page footer, so it
            // paginates with everything else instead of needing a reserved strip that an
            // eleven-person household would overflow.
            let rows = eaters.map { LabelledRow(label: $0.initials, text: $0.displayName) }
            gridBlocks.append(try block("legend", width: gridWidth) {
                LabelledBlock(heading: "Who is who", rows: rows, width: gridWidth)
            })
        }
        documents.append(Document(
            name: "week grid", title: range, subtitle: subtitle, size: gridSize, blocks: gridBlocks
        ))

        // --- Page 2: the head count -----------------------------------------------------
        let portraitWidth = Page.portrait.width - margin * 2
        var headBlocks: [Block] = []
        for key in keys {
            let dayMeals = meals.filter { $0.dayKey == key }
            guard !dayMeals.isEmpty else { continue }
            let rows = dayMeals.map { meal in
                HeadCountRow(
                    slot: meal.slot.title,
                    title: meal.displayTitle,
                    residents: meal.orderedAttendance.filter { $0.consumesPortion }.count,
                    guests: max(0, meal.guestCount),
                    // The PORTIONS total, which is not the head count: two adults and two
                    // half portions is three servings, and cooking four wastes food every
                    // time.
                    portions: meal.portionTotal.humanDescription
                )
            }
            headBlocks.append(try block("head count \(key)", width: portraitWidth) {
                HeadCountBlock(heading: dayText(key), rows: rows, width: portraitWidth)
            })
        }
        if !headBlocks.isEmpty {
            documents.append(Document(
                name: "head count", title: "Who is eating", subtitle: subtitle,
                size: Page.portrait, blocks: headBlocks
            ))
        }

        // --- Page 3: prep ahead ---------------------------------------------------------
        var prepBlocks: [Block] = []
        for key in keys {
            var rows: [LabelledRow] = []
            for meal in meals where meal.dayKey == key {
                if meal.slot == .prep {
                    let detail = meal.notes.isEmpty ? "Prep" : meal.notes
                    rows.append(LabelledRow(label: meal.displayTitle, text: detail))
                }
                for dish in meal.orderedMealRecipes {
                    // Make-ahead text lives in BUNDLED CONTENT, not on any row the job could
                    // carry. This is the clearest case for the loader being a parameter.
                    guard let recipe = loader.recipe(id: dish.recipeID) else { continue }
                    let name = dish.titleForDisplay(resolvedTitle: recipe.title)
                    var notes: [String] = []
                    if !recipe.makeAheadNote.isEmpty { notes.append(recipe.makeAheadNote) }
                    for note in recipe.makeAheadNotes where !note.text.isEmpty {
                        if !notes.contains(note.text) { notes.append(note.text) }
                    }
                    for note in notes { rows.append(LabelledRow(label: name, text: note)) }
                }
            }
            guard !rows.isEmpty else { continue }
            prepBlocks.append(try block("prep \(key)", width: portraitWidth) {
                LabelledBlock(heading: dayText(key), rows: rows, width: portraitWidth)
            })
        }
        if !prepBlocks.isEmpty {
            documents.append(Document(
                name: "prep ahead", title: "Prep ahead", subtitle: subtitle,
                size: Page.portrait, blocks: prepBlocks
            ))
        }

        return (fileName: "week-\(low)", documents: documents)
    }

    // MARK: - Measuring and packing

    /// Builds a block and measures it at the page's text width.
    @MainActor
    private static func block<V: View>(
        _ name: String,
        width: CGFloat,
        @ViewBuilder content: () -> V
    ) throws -> Block {
        let view = content()
        let height = try measuredHeight(of: view, width: width, name: name)
        return Block(name: name, height: height, view: AnyView(view))
    }

    /// `ImageRenderer`'s own measurement, which is the only one that agrees with what it will
    /// draw.
    ///
    /// A non-finite or non-positive height is thrown rather than clamped: that is what a lazy
    /// container inside a print view produces, and **no `List`, `ScrollView`, `LazyVStack` or
    /// `LazyVGrid` may appear in any view handed to `ImageRenderer`** — it renders only
    /// laid-out content, so anything lazy comes out empty or clipped with nothing to say so.
    @MainActor
    private static func measuredHeight<V: View>(
        of view: V,
        width: CGFloat,
        name: String
    ) throws -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: width, alignment: .leading))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        var measured: CGFloat = 0
        renderer.render { size, _ in
            measured = size.height
        }
        guard measured.isFinite, measured > 0 else {
            throw ExportError.pageMeasurementFailed(page: name)
        }
        return measured
    }

    /// Whole blocks into pages. A block taller than the budget gets a page of its own and
    /// stays whole.
    @MainActor
    private static func paginate(_ document: Document) throws -> [Page] {
        guard !document.blocks.isEmpty else { return [] }

        let width = document.size.width - margin * 2
        let headerHeight = try measuredHeight(
            of: SheetHeader(title: document.title, subtitle: document.subtitle, page: "1 of 9", width: width),
            width: width,
            name: document.name
        )
        let budget = document.size.height - margin * 2 - headerHeight - blockSpacing
        guard budget > 0 else { throw ExportError.pageMeasurementFailed(page: document.name) }

        var groups: [[Block]] = []
        var current: [Block] = []
        var used: CGFloat = 0
        for item in document.blocks {
            if !current.isEmpty, used + blockSpacing + item.height > budget {
                groups.append(current)
                current = []
                used = 0
            }
            current.append(item)
            used += blockSpacing + item.height
        }
        if !current.isEmpty { groups.append(current) }

        var pages: [Page] = []
        for (index, group) in groups.enumerated() {
            let label = groups.count > 1 ? "\(index + 1) of \(groups.count)" : ""
            // "(cont.)" on the PAGE head, because the page is what continued — no block was
            // ever split.
            let title = index == 0 ? document.title : "\(document.title) (cont.)"
            let views = group.map { $0.view }
            pages.append(Page(size: document.size, name: "\(document.name) \(index + 1)") {
                Sheet(
                    title: title,
                    subtitle: document.subtitle,
                    pageLabel: label,
                    size: document.size,
                    blocks: views
                )
            })
        }
        return pages
    }

    // MARK: - Writing the file

    @MainActor
    private static func destination(named name: String) throws -> URL {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
            .appendingPathComponent("KitchenAidExports", isDirectory: true)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.temporaryDirectoryUnwritable
        }
        let slug = NameNormalizer.slug(name)
        let file = (slug.isEmpty ? "kitchenaid" : slug) + ".pdf"
        let url = folder.appendingPathComponent(file)
        // Removed first. A stale file from an earlier failed render would otherwise be the
        // thing `ShareLink` offers if this render fails before its first page is drawn.
        try? manager.removeItem(at: url)
        return url
    }

    /// `CGContext` + `ImageRenderer.render`, with the media box set PER PAGE.
    ///
    /// The context's own `mediaBox` is only the default, and `beginPage(mediaBox:)` overrides
    /// it — which is what lets the landscape week grid and the two portrait pages share one
    /// document. The `CGContext` closure is also what keeps the text as VECTOR text:
    /// selectable, searchable and sharp when printed, where `renderer.uiImage` gives a
    /// rasterized page that looks blurry on paper.
    @MainActor
    static func write(pages: [Page], to url: URL) throws {
        guard let first = pages.first else { throw ExportError.nothingToExport }

        var box = CGRect(origin: .zero, size: first.size)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw ExportError.contextUnavailable }

        for page in pages {
            let pageBox = CGRect(origin: .zero, size: page.size)
            let renderer = ImageRenderer(content: page.content)
            renderer.proposedSize = ProposedViewSize(page.size)
            renderer.render { _, draw in
                withUnsafePointer(to: pageBox) { boxPointer in
                    pdf.beginPage(mediaBox: boxPointer)
                    draw(pdf)
                    pdf.endPage()
                }
            }
        }
        pdf.closePDF()
    }

    // MARK: - Dates

    /// One formatter, built once. `setLocalizedDateFormatFromTemplate` rather than a literal
    /// format, so the sheet reads the way his region writes a date.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()

    /// A `dayKey` back into something readable. The key is `yyyymmdd` in his own calendar, so
    /// it is turned back through `CalendarKey` rather than being treated as an instant.
    static func dayText(_ dayKey: Int) -> String {
        guard let date = CalendarKey.startOfDay(forKey: dayKey) else { return "\(dayKey)" }
        return dayFormatter.string(from: date)
    }

    static func rangeText(from interval: DateInterval) -> String {
        let start = dayFormatter.string(from: interval.start)
        let end = dayFormatter.string(from: interval.end)
        return start == end ? start : "\(start) \u{2013} \(end)"
    }
}

// MARK: - The rows the print views render
//
// Value types, built in the functions above and handed to the views already resolved. The
// views reach no loader, no overlay and no `ModelContext`: a print view that fetches is a
// print view whose output depends on when it was measured, and every block here is measured
// once and drawn again later.

extension PDFExportService {

    struct IngredientRow {
        let amount: String
        let name: String
        let qualifier: String
        /// A footnote number, or "" for a line he has not tweaked.
        let marker: String
    }

    struct ShoppingRow {
        let name: String
        let amount: String
        let qualifier: String
        /// Which covered meals asked for this, as "1,3".
        let marker: String
    }

    struct LabelledRow {
        let label: String
        let text: String
    }

    struct HeadCountRow {
        let slot: String
        let title: String
        let residents: Int
        let guests: Int
        let portions: String
    }

    struct GridEntry {
        let slot: String
        let title: String
        let chips: [String]
        let guests: Int
        /// An SF Symbol for a non-recipe entry (takeout, leftovers), or "".
        let symbol: String
    }

    struct DayColumn {
        let title: String
        let entries: [GridEntry]
    }
}

// MARK: - The print views
//
// Plain `VStack`/`HStack` only. See `measuredHeight` for why nothing lazy may appear here.

extension PDFExportService {

    struct Sheet: View {
        let title: String
        let subtitle: String
        let pageLabel: String
        let size: CGSize
        let blocks: [AnyView]

        var body: some View {
            let width = size.width - PDFExportService.margin * 2
            return VStack(alignment: .leading, spacing: PDFExportService.blockSpacing) {
                SheetHeader(title: title, subtitle: subtitle, page: pageLabel, width: width)
                ForEach(blocks.indices, id: \.self) { index in
                    blocks[index]
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
            .padding(PDFExportService.margin)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
        }
    }

    struct SheetHeader: View {
        let title: String
        let subtitle: String
        let page: String
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Serif, matching the app's voice.
                    Text(title)
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundColor(PDFExportService.ink)
                    Spacer(minLength: 4)
                    if !page.isEmpty {
                        Text(page)
                            .font(.system(size: 9))
                            .foregroundColor(PDFExportService.inkMuted)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(PDFExportService.inkMuted)
                }
                Rectangle()
                    .fill(PDFExportService.hairline)
                    .frame(height: 0.7)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct BlockHead: View {
        let text: String
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundColor(PDFExportService.ink)
                Rectangle()
                    .fill(PDFExportService.hairline)
                    .frame(height: 0.5)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct RecipeSummaryBlock: View {
        let summary: String
        let facts: [String]
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundColor(PDFExportService.ink)
                }
                if !facts.isEmpty {
                    Text(facts.joined(separator: "  \u{00B7}  "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(PDFExportService.inkMuted)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct ComponentBlock: View {
        let heading: String
        let summary: String
        let reference: String
        let note: String
        let rows: [IngredientRow]
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                if !heading.isEmpty {
                    BlockHead(text: heading, width: width)
                }
                if !summary.isEmpty {
                    Text(summary).font(.system(size: 10)).foregroundColor(PDFExportService.ink)
                }
                if !reference.isEmpty {
                    Text(reference).font(.system(size: 10)).foregroundColor(PDFExportService.inkMuted)
                }
                ForEach(rows.indices, id: \.self) { index in
                    IngredientRowView(row: rows[index], width: width)
                }
                if !note.isEmpty {
                    Text(note).font(.system(size: 9)).foregroundColor(PDFExportService.inkMuted)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct IngredientRowView: View {
        let row: IngredientRow
        let width: CGFloat

        var body: some View {
            HStack(alignment: .top, spacing: 6) {
                // Quantities right-aligned in a monospaced face, so a column of them reads as
                // a column.
                Text(row.amount)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(PDFExportService.ink)
                    .frame(width: 92, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .top, spacing: 2) {
                        Text(row.name)
                            .font(.system(size: 10))
                            .foregroundColor(PDFExportService.ink)
                        if !row.marker.isEmpty {
                            Text(row.marker)
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundColor(PDFExportService.inkMuted)
                        }
                    }
                    if !row.qualifier.isEmpty {
                        Text(row.qualifier)
                            .font(.system(size: 8))
                            .foregroundColor(PDFExportService.inkMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct StepBlock: View {
        let showHead: Bool
        let number: Int
        let title: String
        let detail: String
        let duration: String
        let temperature: String
        let isEdited: Bool
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                if showHead {
                    BlockHead(text: "Method", width: width)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text("\(number).")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(PDFExportService.ink)
                        .frame(width: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if !title.isEmpty {
                                Text(title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(PDFExportService.ink)
                            }
                            if !duration.isEmpty {
                                Text(duration)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(PDFExportService.inkMuted)
                            }
                            if isEdited {
                                Text("edited")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundColor(PDFExportService.inkMuted)
                            }
                        }
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundColor(PDFExportService.ink)
                        }
                        if !temperature.isEmpty {
                            Text(temperature)
                                .font(.system(size: 8))
                                .foregroundColor(PDFExportService.inkMuted)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct TableBlock: View {
        let name: String
        let headers: [String]
        let rows: [[String]]
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                BlockHead(text: name.isEmpty ? "Table" : name, width: width)
                if !headers.isEmpty {
                    TableRowView(cells: headers, isHead: true, width: width)
                }
                ForEach(rows.indices, id: \.self) { index in
                    TableRowView(cells: rows[index], isHead: false, width: width)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct TableRowView: View {
        let cells: [String]
        let isHead: Bool
        let width: CGFloat

        var body: some View {
            // Even columns over however many cells the row has: a document is not a
            // spreadsheet and a ragged row is not an error, so the width is divided rather
            // than assumed.
            let columns = max(1, cells.count)
            return HStack(alignment: .top, spacing: 4) {
                ForEach(cells.indices, id: \.self) { index in
                    Text(cells[index])
                        .font(.system(size: 9, weight: isHead ? .semibold : .regular,
                                      design: .monospaced))
                        .foregroundColor(isHead ? PDFExportService.ink : PDFExportService.inkMuted)
                        .frame(width: (width - 4 * CGFloat(columns - 1)) / CGFloat(columns),
                               alignment: .leading)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct LabelledBlock: View {
        let heading: String
        let rows: [LabelledRow]
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                if !heading.isEmpty {
                    BlockHead(text: heading, width: width)
                }
                ForEach(rows.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        if !rows[index].label.isEmpty {
                            Text(rows[index].label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(PDFExportService.inkMuted)
                                .frame(width: 96, alignment: .leading)
                        }
                        Text(rows[index].text)
                            .font(.system(size: 10))
                            .foregroundColor(PDFExportService.ink)
                        Spacer(minLength: 0)
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct ShoppingBlock: View {
        let heading: String
        let footnote: String
        let rows: [ShoppingRow]
        let showCheckbox: Bool
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                BlockHead(text: heading, width: width)
                ForEach(rows.indices, id: \.self) { index in
                    ShoppingRowView(row: rows[index], showCheckbox: showCheckbox, width: width)
                }
                if !footnote.isEmpty {
                    Text(footnote)
                        .font(.system(size: 8))
                        .foregroundColor(PDFExportService.inkMuted)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct ShoppingRowView: View {
        let row: ShoppingRow
        let showCheckbox: Bool
        let width: CGFloat

        var body: some View {
            HStack(alignment: .top, spacing: 6) {
                // A STROKED BOX, drawn as a shape. An emoji checkbox renders at whatever size
                // and colour the font decides, which on paper is a grey blob.
                if showCheckbox {
                    RoundedRectangle(cornerRadius: 1.5)
                        .stroke(PDFExportService.ink, lineWidth: 0.7)
                        .frame(width: 9, height: 9)
                        .padding(.top, 1.5)
                } else {
                    Color.clear.frame(width: 9, height: 9)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .top, spacing: 2) {
                        Text(row.name)
                            .font(.system(size: 10))
                            .foregroundColor(PDFExportService.ink)
                        if !row.marker.isEmpty {
                            Text(row.marker)
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundColor(PDFExportService.inkMuted)
                        }
                    }
                    if !row.qualifier.isEmpty {
                        Text(row.qualifier)
                            .font(.system(size: 8))
                            .foregroundColor(PDFExportService.inkMuted)
                    }
                }
                Spacer(minLength: 0)
                Text(row.amount)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(PDFExportService.ink)
                    .frame(width: 110, alignment: .trailing)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct HeadCountBlock: View {
        let heading: String
        let rows: [HeadCountRow]
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                BlockHead(text: heading, width: width)
                ForEach(rows.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Text(rows[index].slot)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(PDFExportService.inkMuted)
                            .frame(width: 76, alignment: .leading)
                        Text(rows[index].title)
                            .font(.system(size: 10))
                            .foregroundColor(PDFExportService.ink)
                        Spacer(minLength: 0)
                        Text("\(rows[index].residents)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(PDFExportService.ink)
                            .frame(width: 56, alignment: .trailing)
                        Text(rows[index].guests > 0 ? "\(rows[index].guests)" : "\u{2013}")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(PDFExportService.ink)
                            .frame(width: 48, alignment: .trailing)
                        Text(rows[index].portions)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(PDFExportService.ink)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .frame(width: width, alignment: .leading)
                }
                HStack(alignment: .top, spacing: 6) {
                    Spacer(minLength: 0)
                    Text("household")
                        .font(.system(size: 7))
                        .foregroundColor(PDFExportService.inkMuted)
                        .frame(width: 56, alignment: .trailing)
                    Text("guests")
                        .font(.system(size: 7))
                        .foregroundColor(PDFExportService.inkMuted)
                        .frame(width: 48, alignment: .trailing)
                    Text("portions")
                        .font(.system(size: 7))
                        .foregroundColor(PDFExportService.inkMuted)
                        .frame(width: 56, alignment: .trailing)
                }
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct WeekGridBlock: View {
        let columns: [DayColumn]
        let width: CGFloat

        var body: some View {
            // Seven fixed columns in an `HStack`, not a `Grid`: the column width is known
            // from the page width, and a fixed division is what keeps every day the same
            // width whether it holds one meal or four.
            let count = max(1, columns.count)
            let columnWidth = (width - 4 * CGFloat(count - 1)) / CGFloat(count)
            return HStack(alignment: .top, spacing: 4) {
                ForEach(columns.indices, id: \.self) { index in
                    DayColumnView(column: columns[index], width: columnWidth)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct DayColumnView: View {
        let column: DayColumn
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(column.title)
                    .font(.system(size: 9, weight: .semibold, design: .serif))
                    .foregroundColor(PDFExportService.ink)
                Rectangle()
                    .fill(PDFExportService.hairline)
                    .frame(height: 0.5)
                ForEach(column.entries.indices, id: \.self) { index in
                    GridEntryView(entry: column.entries[index], width: width)
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    struct GridEntryView: View {
        let entry: GridEntry
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(entry.slot)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(PDFExportService.inkMuted)
                    if !entry.symbol.isEmpty {
                        Image(systemName: entry.symbol)
                            .font(.system(size: 7))
                            .foregroundColor(PDFExportService.inkMuted)
                    }
                }
                Text(entry.title)
                    .font(.system(size: 9))
                    .foregroundColor(PDFExportService.ink)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    ForEach(entry.chips.indices, id: \.self) { index in
                        Text(entry.chips[index])
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(PDFExportService.ink)
                    }
                    if entry.guests > 0 {
                        // Guests are COUNTED, never named (`CLAUDE.md`), so the grid shows a
                        // badge and not a chip per head.
                        Text("+\(entry.guests)")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(PDFExportService.inkMuted)
                    }
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }
}
