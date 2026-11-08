import SwiftUI
import SwiftData

/// Scanning a receipt into the pantry, which Brandon asked for after seeing the design.
///
/// His words on why it is hard: receipt text is abbreviated. `GV CRM CHS 8Z` is Great Value
/// cream cheese, 8 oz, and no amount of string comparison gets there without the catalogue and
/// its aliases. So the matching lives in `ReceiptTokenMatcher` and `ReceiptIntake`, which are
/// tested; this screen is the part that cannot be: a camera, a list he checks, and one writer.
///
/// ## Nothing is written until he says so
///
/// The scan produces a REVIEW LIST, never a bulk insert. That is not timidity about the
/// matcher's accuracy -- it is that a confident wrong answer puts the wrong food in his pantry
/// and he finds out in a supermarket. `ReceiptIntake.resolve` is deliberately built to create
/// nothing (its own comment explains why: a forty-line receipt would otherwise leave forty
/// rows behind, and thirty-nine if he cancelled), so this screen is the only thing that can
/// turn a line into stock, and only on a tap.
///
/// ## Once, then remembers
///
/// Answering a line by hand calls `ReceiptIntake.learn`, which writes the receipt's own words
/// as a `FoodItemAlias` on the item. The next receipt resolves that token at step 2 with no
/// question. That is the whole mechanism and there is no second one: a table of learned
/// receipt tokens would be a second thing that can disagree about what `CRM CHS` means.
///
/// It happens on **confirm**, not on the tap that answers a row, and that is a deliberate
/// difference from `BarcodeScanView`, which remembers a number the moment he names it. A
/// barcode answer is a standalone fact about a number; a receipt row is one line of a basket
/// he is still reading, and half of answering a receipt is noticing that the line above was
/// wrong. So the receipt keeps one rule -- nothing is written until he confirms -- and that
/// includes the vocabulary.
///
/// ## No image, anywhere
///
/// The camera hands back text (see the enforcement note on `ScanCamera`). This screen holds
/// `[UUID: ScannedLine]` -- strings and a sort position -- and writes `FoodItem`s, lots and
/// transactions. There is no frame to keep and nothing here could keep one.
struct ReceiptScanView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(IngredientCatalog.self) private var catalog
    @Environment(\.storeUnavailable) private var storeUnavailable

    /// Optional, for the reason every other lookup of it is: the App builds it in its launch
    /// task because it is `@MainActor`, and a non-optional `@Environment` lookup traps while
    /// the value is absent. Same shape as `PantryView` and `AddStockSheet`.
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    private enum Stage: Equatable {
        case scanning
        case reviewing
        case finished
    }

    @State private var stage: Stage = .scanning
    @State private var isScanning = true

    /// Keyed by VisionKit's tracking id, so a block of text that sharpens as he steadies the
    /// phone replaces its earlier reading rather than adding a second line.
    @State private var lines: [UUID: ScannedLine] = [:]
    @State private var trouble = ""

    /// Held for the length of the scan, not built per line. Its index is about 1,300 names and
    /// aliases, and `ReceiptIntake.make`'s own comment says building it per line is forty
    /// times the work for nothing. nil until `onAppear`, because the catalogue arrives from the
    /// environment and is not available in `init`.
    @State private var intake: ReceiptIntake?

    @State private var drafts: [ReceiptLineDraft] = []
    @State private var answering: ReceiptLineDraft?
    @State private var summary = ReceiptSummary()

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        Group {
            switch stage {
            case .scanning:
                scanningStage
            case .reviewing:
                reviewStage
            case .finished:
                finishedStage
            }
        }
        .navigationTitle("Scan a receipt")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $answering) { draft in
            NavigationStack {
                ReceiptLineAnswerSheet(draft: draft) { answered in
                    adopt(answered)
                }
            }
        }
        // `onAppear` and not `task`: the closure `task` takes is `@Sendable` and so is not
        // main-actor isolated, and this reads an environment service. The same call this
        // codebase's other screens make for the same reason.
        .onAppear {
            if intake == nil {
                intake = ReceiptIntake.make(
                    resolver: FoodItemResolver(catalog: catalog), catalog: catalog
                )
            }
        }
        // The camera goes off when the screen goes away. `ScanCamera.dismantleUIViewController`
        // is the backstop for a stack torn down underneath this; this is the ordinary case.
        .onDisappear { isScanning = false }
    }

    // MARK: - Scanning

    private var scanningStage: some View {
        ScanGate(subject: .receiptText) {
            ZStack(alignment: .bottom) {
                ScanCamera(
                    subject: .receiptText,
                    isScanning: isScanning,
                    onText: { id, text, position in adopt(id, text, position) },
                    onTrouble: { message in trouble = message }
                )
                .ignoresSafeArea(edges: .bottom)
                scanBar
            }
        }
    }

    /// `@MainActor`: it calls `review()`, which is main-actor isolated, from a closure
    /// that is not `@Sendable` and so inherits this property's isolation. Same shape and
    /// same reasoning as `BarcodeScanView.scanningStage`.
    @MainActor
    private var scanBar: some View {
        VStack(spacing: 10) {
            if !trouble.isEmpty {
                Text(trouble)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Text(lineCountText)
                .font(.subheadline.weight(.medium))
            Text("Hold the whole receipt in frame. Nothing is kept until you check the list.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Start over") { lines.removeAll() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(lines.isEmpty)
                Button("Read the list") { review() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(lines.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }

    private var lineCountText: String {
        let count = lines.count
        if count == 0 { return "No text read yet" }
        return count == 1 ? "1 line read" : "\(count) lines read"
    }

    private func adopt(_ id: UUID, _ text: String, _ position: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines[id] = ScannedLine(id: id, text: trimmed, verticalPosition: position)
    }

    /// The lines in the order they are printed, which is the order he will check them against
    /// the paper. The recognizer reports what it sees when it sees it, so the sort is what
    /// makes the list readable; `ReceiptIntake.read(receiptText:)` splits on newlines and keeps
    /// rejects in place, so a `2 @ 3.50` line stays under the line it belongs to.
    private var assembledText: String {
        lines.values
            .sorted { $0.verticalPosition < $1.verticalPosition }
            .map { $0.text }
            .joined(separator: "\n")
    }

    @MainActor
    private func review() {
        isScanning = false
        guard let intake = intake else { return }
        let resolutions = (try? intake.resolve(receiptText: assembledText, in: context)) ?? []
        drafts = resolutions.map { ReceiptLineDraft.make($0, catalog: catalog) }
        stage = .reviewing
    }

    // MARK: - The review list

    @MainActor
    private var reviewStage: some View {
        List {
            if storeUnavailable { storeWarning }
            if itemDrafts.isEmpty {
                Section { nothingUsable }
            } else {
                Section {
                    ForEach(itemDrafts) { draft in
                        itemRow(draft)
                    }
                } header: {
                    Text("What the receipt says")
                } footer: {
                    Text("Tap a line to change what it is, set an amount, or skip it. "
                         + "Answering one teaches it \u{2014} the next receipt will not ask.")
                }
            }
            skippedSection
            confirmSection
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rescan") { rescan() }
            }
        }
    }

    @MainActor
    private func itemRow(_ draft: ReceiptLineDraft) -> some View {
        Button {
            answering = draft
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                // The receipt's own words first, because the question he is answering is
                // "is that what this line said", and it has to be checkable against the paper.
                Text(draft.printedLine)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(draft.headline)
                        .font(.body.weight(draft.needsAnswer ? .semibold : .regular))
                        .foregroundStyle(draft.needsAnswer ? Color.orange : .primary)
                    Spacer(minLength: 8)
                    if let price = draft.priceText {
                        Text(price)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(amountDetail(draft))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(draft.printedLine), \(draft.headline)")
        .accessibilityHint("Change what this is, or skip it")
        .swipeActions(edge: .trailing) {
            if draft.answer.isSkipped {
                Button("Keep") { include(draft) }
            } else {
                Button("Skip") { skip(draft) }
                    .tint(.secondary)
            }
        }
    }

    /// What will actually be added, in his units. A zero amount says so in words rather than
    /// printing "0 oz", because a receipt that printed no size is not a receipt that printed
    /// nothing -- see `ReceiptLineDraft.make`.
    @MainActor
    private func amountDetail(_ draft: ReceiptLineDraft) -> String {
        if draft.answer.isSkipped { return "Skipped. Nothing will be added." }
        if draft.needsAnswer {
            let count = draft.resolution.match.candidates.count
            if count == 0 { return "Nothing in the catalogue came close. Tap to pick it." }
            return count == 1 ? "One possible match. Tap to check it."
                              : "\(count) possible matches. Tap to pick one."
        }
        if draft.isStapleAnswer {
            return "A staple \u{2014} marked as in the house, with no amount kept."
        }
        guard draft.amount > .zero else {
            return "No amount printed on the receipt. Tap to set one."
        }
        return "Adds \(Quantity(amount: draft.amount, unit: draft.unit).displayString(system: ledger.unitSystem))"
    }

    /// The lines the reader threw out, with the reason it threw each one out.
    ///
    /// Collapsed, and kept rather than hidden: a totals line being read as a totals line is the
    /// difference between a reader that is working and one that missed half the receipt. The
    /// labels are `ReceiptTokenMatcher.Rejection`'s own.
    @ViewBuilder
    private var skippedSection: some View {
        let rejected = drafts.filter { !$0.isItemLine }
        if !rejected.isEmpty {
            Section {
                DisclosureGroup("\(rejected.count) line\(rejected.count == 1 ? "" : "s") not an item") {
                    ForEach(rejected) { draft in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(draft.printedLine)
                                .font(.caption)
                                .monospaced()
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(draft.resolution.rejection?.label ?? "Skipped")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Totals, payment lines, the store's address and anything with no words in "
                     + "it. Listed so a reader that missed half the receipt does not look like "
                     + "one that read it.")
            }
        }
    }

    @MainActor
    @ViewBuilder
    private var confirmSection: some View {
        Section {
            Button {
                putAway()
            } label: {
                Text(putAwayTitle)
                    .frame(minHeight: 44)
            }
            .disabled(readyDrafts.isEmpty)
        } footer: {
            Text(confirmFooter)
        }
    }

    private var putAwayTitle: String {
        let count = readyDrafts.count
        if count == 0 { return "Nothing to put away yet" }
        return count == 1 ? "Put 1 item away" : "Put \(count) items away"
    }

    private var confirmFooter: String {
        var parts: [String] = []
        let unanswered = itemDrafts.filter { $0.needsAnswer }.count
        let noAmount = itemDrafts.filter { $0.wantsAmount }.count
        let skipped = itemDrafts.filter { $0.answer.isSkipped }.count
        if unanswered > 0 {
            parts.append("\(unanswered) still need\(unanswered == 1 ? "s" : "") an answer")
        }
        if noAmount > 0 {
            parts.append("\(noAmount) need\(noAmount == 1 ? "s" : "") an amount")
        }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if parts.isEmpty {
            return "Each one becomes a lot in the pantry, with the receipt's price on its "
                 + "purchase row."
        }
        return parts.joined(separator: ", ") + ". Those are left alone \u{2014} nothing is "
             + "guessed, and you can come back to them by scanning again."
    }

    private var nothingUsable: some View {
        EmptyStateView(
            kind: .somethingWrong,
            symbol: "doc.questionmark",
            headline: "Nothing on that looked like an item",
            detail: "Every line read as a total, a payment or something with no words in it. "
                  + "More light and the whole receipt flat in frame usually fixes it.",
            actionTitle: "Scan again",
            action: { rescan() }
        )
    }

    private var storeWarning: some View {
        Section {
            Text("The database could not be opened, so anything put away now will be gone "
                 + "when the app closes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Reading the drafts

    private var itemDrafts: [ReceiptLineDraft] {
        drafts.filter { $0.isItemLine }
    }

    /// Answered, not skipped, and with something to write: an amount, or a staple's presence.
    private var readyDrafts: [ReceiptLineDraft] {
        itemDrafts.filter { $0.isReady }
    }

    // MARK: - Editing a draft

    private func adopt(_ answered: ReceiptLineDraft) {
        guard let index = drafts.firstIndex(where: { $0.id == answered.id }) else { return }
        drafts[index] = answered
    }

    private func skip(_ draft: ReceiptLineDraft) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        drafts[index].answer = .skipped
    }

    /// Back to whatever the matcher had concluded before he skipped it, rather than to
    /// "unanswered": undoing a skip should not throw away a confident match he never disputed.
    private func include(_ draft: ReceiptLineDraft) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        drafts[index] = ReceiptLineDraft.make(draft.resolution, catalog: catalog, id: draft.id)
    }

    private func rescan() {
        lines.removeAll()
        drafts.removeAll()
        trouble = ""
        summary = ReceiptSummary()
        isScanning = true
        stage = .scanning
    }

    // MARK: - Writing it

    /// The one writer on this screen, and it writes through `PantryEditor`.
    ///
    /// **A deliberate departure from the wiring note that came with this task**, which said to
    /// post `InventoryLedger.apply(kind: .purchase, ...)` directly. That call takes an optional
    /// lot, and a purchase row filed against no lot lands in `reconcileReport`'s
    /// `.unassignedLot` scope -- every receipt line would show up on the reconcile screen as a
    /// transaction held by no lot, which is exactly the state that screen exists to report as
    /// wrong. `PantryEditor.addLot` is the writer for "food arrived in the house": it inserts
    /// the lot, points it at its item and place, THEN applies the purchase row, and recomputes
    /// the lot's cache. It is the same order `InventoryLedger.receive` uses for a finished
    /// shopping list, which is the same event as this one.
    @MainActor
    private func putAway() {
        // `intake` unwrapped once, up front. `try? intake?.learn(...)` would be an optional
        // chain under a `try?`, and SE-0230 flattening is the exact shape that produced
        // blocking defect 5 in CODE_REVIEW_01 -- not worth being clever about twice.
        guard let intake = intake else { return }

        var tally = ReceiptSummary()
        for draft in drafts where draft.isItemLine {
            switch draft.answer {
            case .unanswered:
                tally.needingAnswer += 1
            case .skipped:
                tally.skipped += 1
            case .item(let item):
                // LEARNED ONLY IF HE CHOSE IT. `learn` writes a permanent `FoodItemAlias`,
                // and a match he never disputed is not a fact he taught the app -- see
                // `ReceiptLineDraft.wasAnsweredByHand` for what that cost. `learn` also
                // returns false when there is nothing to learn, so the count stays honest.
                if draft.wasAnsweredByHand,
                   intake.learn(draft.reading, as: item, in: context) {
                    tally.remembered += 1
                }
                write(draft, to: item, into: &tally)
            case .entry(let entry):
                // The mint, and the only one on this screen: `learn(_:asCatalogEntry:)` goes
                // through `FoodItemResolver`, which is the one thing in the app allowed to
                // create a `FoodItem` -- what stands in for the `@Attribute(.unique)` CloudKit
                // forbids.
                guard let item = try? intake.learn(
                    draft.reading, asCatalogEntry: entry, in: context,
                    // The MINT always happens -- a catalogue entry has to become a row
                    // before stock can go on it. What is gated is the ALIAS: only a token
                    // he placed by hand is worth remembering, because a confident match
                    // already resolves through the catalogue every time.
                    rememberingToken: draft.wasAnsweredByHand
                ) else {
                    tally.failed += 1
                    continue
                }
                if draft.wasAnsweredByHand { tally.remembered += 1 }
                write(draft, to: item, into: &tally)
            }
        }

        summary = tally
        stage = .finished
    }

    @MainActor
    private func write(_ draft: ReceiptLineDraft, to item: FoodItem, into tally: inout ReceiptSummary) {
        // A staple is present or absent with NO quantity (CLAUDE.md), so buying one answers
        // `isRunningLow` and creates no lot. The same single assignment `InventoryLedger.receive`
        // makes for a staple checked off a finished list.
        guard item.tracksQuantity else {
            PantryEditor.setStaplePresent(item, isPresent: true, in: context)
            tally.staples += 1
            return
        }
        guard draft.amount > .zero, draft.unit.baseFactor != .zero else {
            // Learned, but nothing added: the receipt printed no size and he set none.
            // Counted and reported rather than written as a zero, which would be a lot that
            // claims the house has none of something it has some of.
            tally.noAmount += 1
            return
        }
        let now = Date.now
        let location = item.defaultLocation
        PantryEditor.addLot(
            for: item,
            quantity: Quantity(amount: draft.amount, unit: draft.unit),
            location: location,
            acquiredAt: now,
            expiresAt: location?.suggestedExpiry(from: now),
            label: "Scanned receipt",
            priceCents: draft.reading.priceCents,
            using: ledger,
            in: context
        )
        tally.put += 1
    }

    // MARK: - What happened

    private var finishedStage: some View {
        List {
            Section {
                ForEach(summary.lines, id: \.self) { line in
                    Text(line).font(.subheadline)
                }
            } header: {
                Text("Done")
            } footer: {
                Text("Every amount above is a lot in the pantry with a purchase row behind it, "
                     + "so \u{201C}why does it think I have three pounds of butter\u{201D} has "
                     + "an answer.")
            }
            Section {
                Button("Scan another") { rescan() }
                    .frame(minHeight: 44)
                Button("Back to the pantry") { dismiss() }
                    .frame(minHeight: 44)
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - One line of the receipt, as the review list holds it

/// A receipt line plus his answer to it.
///
/// `ReceiptResolution` is what the services concluded and is never edited; everything he
/// changes lives beside it. Keeping them apart is what lets "undo the skip" put the line back
/// to the matcher's own conclusion instead of to a blank.
struct ReceiptLineDraft: Identifiable {
    let id: UUID
    let resolution: ReceiptResolution
    var answer: ScanAnswer
    var amount: Rational
    var unit: KitchenUnit
    /// True only when HE picked this answer in the sheet.
    ///
    /// It gates `learn`, and that is the whole reason it exists. A confident match is one
    /// the matcher decided not to ask about -- and on confirm, every `.entry` answer used
    /// to be learned as a permanent `FoodItemAlias`. So one confident-and-wrong match
    /// ("CHS" -> chives) became an alias on the wrong food, after which
    /// `ReceiptIntake.resolve` answered that token from HIS OWN ALIASES at step 2 for ever
    /// and could never reach the catalogue for it again. Self-reinforcing, and with no
    /// screen in the app that could delete an alias, unrecoverable short of deleting the
    /// `FoodItem`.
    ///
    /// A confident match does not need an alias anyway: it already resolves through the
    /// shipped catalogue on every receipt. Only a token the catalogue CANNOT place is
    /// worth remembering, and that is exactly the one he had to answer by hand.
    ///
    /// Default false, set in `ReceiptLineAnswerSheet.save`, so a draft built by `make`
    /// from `resolution.proposal` is never counted as his.
    var wasAnsweredByHand: Bool = false

    var reading: ReceiptTokenMatcher.Reading { resolution.reading }
    var isItemLine: Bool { resolution.isItemLine }

    /// The receipt's own characters, which is what he checks the row against.
    var printedLine: String {
        let raw = reading.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? reading.nameDisplay : raw
    }

    var needsAnswer: Bool {
        if case .unanswered = answer { return true }
        return false
    }

    var isStapleAnswer: Bool { answer.isStaple }

    /// A tracked food he has answered for, with no amount yet. The one state that still wants
    /// a tap before it can be put away.
    var wantsAmount: Bool {
        guard !needsAnswer, !answer.isSkipped, !isStapleAnswer else { return false }
        return amount <= .zero
    }

    var isReady: Bool {
        guard !needsAnswer, !answer.isSkipped else { return false }
        return isStapleAnswer || amount > .zero
    }

    var headline: String {
        if answer.isSkipped { return reading.nameDisplay }
        if let name = answer.name { return name }
        return "What is \u{201C}\(reading.nameDisplay)\u{201D}?"
    }

    var priceText: String? {
        guard let cents = reading.priceCents else { return nil }
        return PantryEditor.priceText(cents)
    }

    /// The matcher's conclusion, turned into a starting point.
    ///
    /// `id` is passed in when a draft is being rebuilt (undoing a skip), so the row keeps its
    /// identity and the list does not animate it out and back in.
    static func make(
        _ resolution: ReceiptResolution,
        catalog: IngredientCatalog,
        id: UUID = UUID()
    ) -> ReceiptLineDraft {
        let answer: ScanAnswer
        if let item = resolution.item {
            answer = .item(item)
        } else if let entry = resolution.proposal {
            answer = .entry(entry)
        } else {
            answer = .unanswered
        }
        let (amount, unit) = startingQuantity(
            for: answer, reading: resolution.reading, catalog: catalog
        )
        return ReceiptLineDraft(
            id: id, resolution: resolution, answer: answer, amount: amount, unit: unit,
            // NOT his: this answer came from the matcher, confident or not.
            wasAnsweredByHand: false
        )
    }

    /// **Never an invented quantity.** The rules, in order, and the only ones:
    ///
    /// 1. The size the receipt printed, already resolved against the food it turned out to be
    ///    -- `8Z` is weight ounces on cream cheese and fluid ounces on milk, which is
    ///    `UnitCatalog.unit(code:fallbackDimension:)`'s job and happens in `ReceiptIntake`.
    /// 2. A printed multiplier: `2 @ 3.50` is two of them, and that is read, not guessed.
    /// 3. For a food counted in units -- bananas, eggs, a tin -- ONE, because a receipt line
    ///    with no multiplier is one of the thing. This is the only inference here, it is
    ///    visible on the row as the amount that will be added, and a count is the one dimension
    ///    where it cannot be a different number of a different unit.
    /// 4. Otherwise ZERO, which the row reads as "no amount printed" and which cannot be put
    ///    away until he sets one. A package whose weight the receipt did not print is not a
    ///    package of one pound.
    /// Takes the READING rather than the resolution, so the answer sheet can re-run the same
    /// rule when he picks a different candidate -- and it has to: `8Z` is eight weight ounces
    /// against cream cheese and eight fluid ounces against milk, so changing the answer changes
    /// what the printed size means. `Reading.size(preferring:)` is what resolves that, and this
    /// is the only place in the UI that decides a starting amount.
    static func startingQuantity(
        for answer: ScanAnswer,
        reading: ReceiptTokenMatcher.Reading,
        catalog: IngredientCatalog
    ) -> (Rational, KitchenUnit) {
        if let size = reading.size(preferring: answer.dimension), size.amount > .zero {
            return (size.amount, size.unit)
        }
        let unit = answer.purchaseUnit(catalog: catalog) ?? UnitCatalog.each
        if let multiplier = reading.multiplier, multiplier > 0 {
            return (Rational(multiplier), unit)
        }
        if unit.isCount { return (.one, unit) }
        return (.zero, unit)
    }
}

/// What the confirm actually did, counted rather than implied.
struct ReceiptSummary {
    var put = 0
    var staples = 0
    var remembered = 0
    var needingAnswer = 0
    var skipped = 0
    var noAmount = 0
    /// A catalogue pick whose `FoodItem` could not be minted -- a thrown fetch. Counted
    /// separately because "nothing happened to this line" and "this line failed" are different
    /// sentences, and silently folding the second into the first is how a write that did not
    /// happen gets reported as one that did.
    var failed = 0

    /// One sentence per thing that happened, and nothing for the things that did not.
    var lines: [String] {
        var out: [String] = []
        if put > 0 {
            out.append(put == 1 ? "1 item put in the pantry" : "\(put) items put in the pantry")
        }
        if staples > 0 {
            out.append(staples == 1 ? "1 staple marked as in the house"
                                    : "\(staples) staples marked as in the house")
        }
        if remembered > 0 {
            out.append(remembered == 1
                       ? "1 new name remembered \u{2014} that line will not ask again"
                       : "\(remembered) new names remembered \u{2014} those lines will not ask again")
        }
        if noAmount > 0 {
            out.append(noAmount == 1
                       ? "1 line had no amount, so nothing was added for it"
                       : "\(noAmount) lines had no amount, so nothing was added for them")
        }
        if needingAnswer > 0 {
            out.append(needingAnswer == 1 ? "1 line left unanswered"
                                          : "\(needingAnswer) lines left unanswered")
        }
        if skipped > 0 {
            out.append(skipped == 1 ? "1 line skipped" : "\(skipped) lines skipped")
        }
        if failed > 0 {
            out.append(failed == 1 ? "1 line could not be saved"
                                   : "\(failed) lines could not be saved")
        }
        if out.isEmpty { out.append("Nothing was written.") }
        return out
    }
}
