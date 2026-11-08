import SwiftUI
import SwiftData

/// Scanning barcodes into the pantry.
///
/// **A barcode is only a number.** Turning `0012345678905` into "heavy cream" needs a
/// commercial product database, which means a subscription and a network call this app does not
/// have (`CLAUDE.md`). So there is no lookup here, no cached product payload, and no
/// placeholder for either: the first scan of an item ASKS what it is, his answer becomes a
/// `FoodItemBarcode` row, and every later scan of that number fills itself in. The kitchen
/// becomes its own database, and this screen is where it gets filled in.
///
/// That shapes the whole layout. The question is not a detour from the happy path, it IS the
/// happy path the first time, so an unknown number opens its question immediately -- one
/// question, one tap -- rather than landing in a list of things to deal with later.
///
/// ## What it cannot do, said out loud
///
/// - **A number carries no size.** `FoodItemBarcode` stores digits and nothing else, so the
///   amount is the one thing a scan cannot fill in. A food counted in units gets one per
///   package, because that is what a package of it is; anything measured by weight or volume
///   starts empty and he sets it. Nothing is invented.
/// - **UPC-E is not expanded** and a price-embedded deli code differs per package, both
///   recorded on `FoodItemBarcode.normalize`. The honest consequence is a second question,
///   and the screen says so rather than filing a number it cannot trust.
///
/// ## No image, anywhere
///
/// The camera hands back a payload string (see the enforcement note on `ScanCamera`). This
/// screen holds digits, names and amounts. There is no frame to keep.
struct BarcodeScanView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(IngredientCatalog.self) private var catalog
    @Environment(\.storeUnavailable) private var storeUnavailable

    /// Optional, as everywhere: the App builds the ledger in its launch task because it is
    /// `@MainActor`, and a non-optional `@Environment` lookup traps while it is absent.
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    /// Built in `onAppear` because the catalogue arrives from the environment. Cheap -- it
    /// holds a resolver and no index -- but held rather than rebuilt per scan so that one
    /// screen is one registry.
    @State private var registry: BarcodeRegistry?

    @State private var rows: [BarcodeScanRow] = []
    @State private var isScanning = true
    @State private var trouble = ""
    @State private var answering: BarcodeScanRow?
    @State private var isTyping = false
    @State private var typed = ""

    /// Counted as it happens, because remembering a number happens on his answer and not on
    /// confirm -- see `adopt`.
    @State private var rememberedCount = 0

    @State private var summary: BarcodeSummary?

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        Group {
            if let summary = summary {
                finishedStage(summary)
            } else {
                scanningStage
            }
        }
        .navigationTitle("Scan a barcode")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $answering) { row in
            NavigationStack {
                BarcodeAnswerSheet(row: row) { answered in
                    adopt(answered)
                }
            }
        }
        .alert("Type the number", isPresented: $isTyping) {
            TextField("Digits", text: $typed)
                .keyboardType(.numberPad)
            Button("Add") { acceptTyped() }
            Button("Cancel", role: .cancel) { typed = "" }
        } message: {
            Text("The digits printed under the barcode. 8, 12, 13 or 14 of them \u{2014} "
                 + "anything else is not a product code and will not be remembered.")
        }
        // `onAppear` and not `task`: that closure is `@Sendable` and so not main-actor
        // isolated, and this reads an environment service.
        .onAppear {
            if registry == nil {
                registry = BarcodeRegistry(resolver: FoodItemResolver(catalog: catalog))
            }
        }
        .onDisappear { isScanning = false }
    }

    // MARK: - Scanning

    private var scanningStage: some View {
        VStack(spacing: 0) {
            ScanGate(
                subject: .barcode,
                manualTitle: "Type a number instead",
                onManual: { isTyping = true }
            ) {
                ZStack(alignment: .bottom) {
                    ScanCamera(
                        subject: .barcode,
                        // Paused while a question is on screen: a camera reading tins behind
                        // the sheet he is answering would queue up rows he never pointed it at.
                        isScanning: isScanning && answering == nil,
                        onBarcode: { digits, symbology in accept(digits, symbology: symbology) },
                        onTrouble: { message in trouble = message }
                    )
                    cameraBar
                }
            }
            // The camera gives up room once there is a list to read, and keeps the whole
            // screen while there is not -- which is also what gives `ScanGate`'s "this device
            // cannot scan" message somewhere to be read.
            .frame(maxHeight: rows.isEmpty ? .infinity : 300)
            if !rows.isEmpty {
                Divider()
                scannedList
            }
        }
    }

    private var cameraBar: some View {
        VStack(spacing: 8) {
            if !trouble.isEmpty {
                Text(trouble)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Text(rows.isEmpty
                 ? "Point at a barcode. The first scan of anything asks what it is."
                 : "Scanned: \(rows.count)")
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("Type a number") { isTyping = true }
                .font(.caption)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }

    @MainActor
    private var scannedList: some View {
        List {
            if storeUnavailable { storeWarning }
            Section {
                ForEach(rows) { row in
                    rowButton(row)
                }
            } header: {
                Text("Scanned")
            } footer: {
                Text("Tap one to change what it is or how much. A number is remembered the "
                     + "moment you answer it, whether or not the food goes in the pantry.")
            }
            confirmSection
        }
        .listStyle(.insetGrouped)
    }

    @MainActor
    private func rowButton(_ row: BarcodeScanRow) -> some View {
        Button {
            answering = row
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.digits)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                Text(row.headline)
                    .font(.body.weight(row.needsAnswer ? .semibold : .regular))
                    .foregroundStyle(row.needsAnswer ? Color.orange : .primary)
                Text(detail(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.headline), \(row.digits)")
        .swipeActions(edge: .trailing) {
            Button("Remove", role: .destructive) { remove(row) }
        }
    }

    @MainActor
    private func detail(_ row: BarcodeScanRow) -> String {
        if row.isUnreadable {
            return "Not a product code \u{2014} 8, 12, 13 or 14 digits only. Nothing was stored."
        }
        if row.isForgotten && row.needsAnswer {
            return row.rememberedName.isEmpty
                ? "This number was known, but what it named is gone. Tap to say again."
                : "Was \u{201C}\(row.rememberedName)\u{201D}, which is no longer in the pantry. "
                  + "Tap to say again."
        }
        if row.needsAnswer {
            return "Nothing can look this up. Tap to say what it is, once."
        }
        if row.answer.isStaple {
            return "A staple \u{2014} marked as in the house, with no amount kept."
        }
        guard row.amount > .zero else { return "No amount yet. Tap to set one." }
        let quantity = Quantity(amount: row.amount, unit: row.unit)
        let each = quantity.displayString(system: ledger.unitSystem)
        return row.packages > 1 ? "Adds \(each) \u{00D7} \(row.packages) packages"
                                : "Adds \(each)"
    }

    @MainActor
    @ViewBuilder
    private var confirmSection: some View {
        Section {
            Button {
                putAway()
            } label: {
                Text(putAwayTitle).frame(minHeight: 44)
            }
            .disabled(readyRows.isEmpty)
        } footer: {
            Text(confirmFooter)
        }
    }

    private var putAwayTitle: String {
        let count = readyRows.reduce(0) { $0 + max(1, $1.packages) }
        if count == 0 { return "Nothing to put away yet" }
        return count == 1 ? "Put 1 package away" : "Put \(count) packages away"
    }

    private var confirmFooter: String {
        var parts: [String] = []
        let unanswered = rows.filter { $0.needsAnswer && !$0.isUnreadable }.count
        let noAmount = rows.filter { $0.wantsAmount }.count
        if unanswered > 0 { parts.append("\(unanswered) still unanswered") }
        if noAmount > 0 { parts.append("\(noAmount) with no amount") }
        if rememberedCount > 0 {
            parts.append(rememberedCount == 1
                         ? "1 number remembered already"
                         : "\(rememberedCount) numbers remembered already")
        }
        if parts.isEmpty {
            return "Each package becomes its own lot, which is what a lot is \u{2014} two tins "
                 + "bought together can still go bad on different days."
        }
        return parts.joined(separator: ", ") + "."
    }

    private var storeWarning: some View {
        Section {
            Text("The database could not be opened, so anything put away now \u{2014} and any "
                 + "number remembered \u{2014} will be gone when the app closes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var readyRows: [BarcodeScanRow] { rows.filter { $0.isReady } }

    // MARK: - Taking a scan

    /// The scan path. `BarcodeRegistry.scan` is what decides which of the four cases this is,
    /// and it also records that the scan happened -- a scan IS the event the row counts.
    @MainActor
    private func accept(_ raw: String, symbology: String) {
        guard let registry = registry else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = FoodItemBarcode.normalize(trimmed)
        // Unreadable numbers are keyed by their raw text, so two different bad reads are two
        // rows rather than one that overwrites the other.
        let rowID = key.isEmpty ? "unreadable:\(trimmed)" : key

        // The same tin passing the camera twice is not two tins. He says how many with the
        // stepper in the sheet, because a camera that counts packages for him counts wrong --
        // and `BarcodeRegistry.scan` writes `noteScan`, so letting a re-read through would
        // also inflate how often he buys the thing.
        guard !rows.contains(where: { $0.id == rowID }) else { return }

        guard let scan = try? registry.scan(trimmed, symbology: symbology, in: context) else {
            trouble = "That number could not be read against the pantry."
            return
        }

        var row = BarcodeScanRow(id: rowID, digits: trimmed, symbology: symbology)
        switch scan {
        case .unreadable:
            row.isUnreadable = true
        case .unknown:
            break
        case .known(let item, _):
            row.answer = .item(item)
            row.rememberedName = item.displayName
            let (amount, unit) = BarcodeScanRow.startingQuantity(
                for: row.answer, catalog: catalog
            )
            row.amount = amount
            row.unit = unit
        case .forgotten(let barcode):
            row.isForgotten = true
            row.rememberedName = barcode.itemNameSnapshot
        }

        rows.append(row)
        // The question, immediately. This is the feature: one question, one tap, and never
        // again for this number.
        if row.needsAnswer && !row.isUnreadable { answering = row }
    }

    @MainActor
    private func acceptTyped() {
        let digits = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        typed = ""
        guard !digits.isEmpty else { return }
        // No symbology: nothing read it, so there is nothing to claim about how. `FoodItemBarcode`
        // fills that in if the same number is later scanned for real.
        accept(digits, symbology: "")
    }

    // MARK: - His answer

    /// **His answer IS the database.** Written here, the moment he gives it, rather than on
    /// confirm: whether this tin goes in the pantry today is a separate question from what the
    /// number means, and the promise is that the number is never asked about twice.
    ///
    /// `BarcodeRegistry.remember` overwrites the row for the same number instead of adding a
    /// second, so a first answer, a correction and a re-answer after `.forgotten` are all one
    /// call.
    @MainActor
    private func adopt(_ answered: BarcodeScanRow) {
        guard let index = rows.firstIndex(where: { $0.id == answered.id }) else { return }
        var row = answered

        if let registry = registry, !row.isUnreadable {
            switch row.answer {
            case .item(let item):
                if (try? registry.remember(
                    row.digits, symbology: row.symbology, as: item, in: context
                )) != nil {
                    rememberedCount += 1
                    row.isForgotten = false
                    row.rememberedName = item.displayName
                }
            case .entry(let entry):
                // `try?` on a method that already returns an optional: SE-0230 flattens it, so
                // this is one level of optional and not two. Getting that wrong was blocking
                // defect 5 in CODE_REVIEW_01, in this same pattern.
                if let pair = try? registry.remember(
                    row.digits, symbology: row.symbology, asCatalogEntry: entry, in: context
                ) {
                    rememberedCount += 1
                    row.isForgotten = false
                    // Collapsed to the row that now exists, so the rest of this screen deals in
                    // his `FoodItem` and not in a template it would have to mint again.
                    row.answer = .item(pair.item)
                    row.rememberedName = pair.item.displayName
                }
            case .unanswered, .skipped:
                break
            }
            // Saved rather than left to autosave: the number is the thing he will test by
            // scanning it again, and "it asked me twice" is the one bug this feature cannot
            // afford. `StockLotView` saves directly for the same reason.
            try? context.save()
        }

        rows[index] = row
    }

    private func remove(_ row: BarcodeScanRow) {
        rows.removeAll { $0.id == row.id }
    }

    // MARK: - Putting it away

    /// Writes through `PantryEditor.addLot`, the existing writer for "food arrived in the
    /// house": it inserts the lot, points it at its item and place, applies the `.purchase`
    /// row and recomputes the lot cache, in that order. Nothing here creates a lot a second
    /// way, and nothing posts a transaction with no lot -- a lot-less purchase row lands in
    /// `InventoryLedger.reconcileReport`'s `.unassignedLot` scope, which is the screen that
    /// exists to report exactly that as wrong.
    ///
    /// **One lot per package**, which is what a lot is for: two tins bought together have their
    /// own best-by dates and their own open/unopened state, and the level is summed from the
    /// transactions either way.
    ///
    /// No price. A barcode carries none, and inventing a zero would put a free tin of tomatoes
    /// in the one number he might one day total up.
    @MainActor
    private func putAway() {
        var tally = BarcodeSummary()
        tally.remembered = rememberedCount
        let now = Date.now

        for row in rows {
            guard let item = row.item else {
                if row.isUnreadable { tally.unreadable += 1 } else { tally.unanswered += 1 }
                continue
            }
            // A staple is present or absent with NO quantity (CLAUDE.md): one assignment, no
            // lot, exactly as `InventoryLedger.receive` does it for a staple off a list.
            guard item.tracksQuantity else {
                PantryEditor.setStaplePresent(item, isPresent: true, in: context)
                tally.staples += 1
                continue
            }
            guard row.amount > .zero, row.unit.baseFactor != .zero else {
                tally.noAmount += 1
                continue
            }
            let location = item.defaultLocation
            for _ in 0..<max(1, row.packages) {
                PantryEditor.addLot(
                    for: item,
                    quantity: Quantity(amount: row.amount, unit: row.unit),
                    location: location,
                    acquiredAt: now,
                    expiresAt: location?.suggestedExpiry(from: now),
                    label: "Scanned barcode",
                    using: ledger,
                    in: context
                )
            }
            tally.put += max(1, row.packages)
        }

        summary = tally
    }

    // MARK: - What happened

    private func finishedStage(_ summary: BarcodeSummary) -> some View {
        List {
            Section {
                ForEach(summary.lines, id: \.self) { line in
                    Text(line).font(.subheadline)
                }
            } header: {
                Text("Done")
            } footer: {
                Text("Every number you answered is remembered for next time, including the ones "
                     + "whose food you did not put away.")
            }
            Section {
                Button("Scan more") { scanMore() }
                    .frame(minHeight: 44)
                Button("Back to the pantry") { dismiss() }
                    .frame(minHeight: 44)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func scanMore() {
        rows.removeAll()
        rememberedCount = 0
        trouble = ""
        summary = nil
        isScanning = true
    }
}

// MARK: - One scanned number, as the list holds it

/// A number, what he said it is, and how much of it arrived.
///
/// `id` is the GTIN-14 key -- the same normalization `FoodItemBarcode` stores -- so UPC-A
/// `012345678905` and EAN-13 `0012345678905` are one row in this list, exactly as they are one
/// row in the store. An unreadable read is keyed by its raw text instead, because it has no key.
struct BarcodeScanRow: Identifiable {
    let id: String
    /// Verbatim as scanned or typed, which is what is printed on the tin he is holding.
    var digits: String
    var symbology: String = ""
    var answer: ScanAnswer = .unanswered
    /// What this number used to name, for a `.forgotten` row -- `FoodItemBarcode` keeps the
    /// snapshot so an orphaned number still reads as something rather than as a bare number.
    var rememberedName: String = ""
    var isUnreadable: Bool = false
    var isForgotten: Bool = false
    /// How many of this thing he scanned. A stepper and not a count of camera reads: the same
    /// tin drifting in and out of frame is not four tins.
    var packages: Int = 1
    var amount: Rational = .zero
    var unit: KitchenUnit = UnitCatalog.each

    var item: FoodItem? {
        if case .item(let item) = answer { return item }
        return nil
    }

    var needsAnswer: Bool { item == nil && !answer.isSkipped }

    /// Answered, measured, and not a staple: the state that still wants a tap.
    var wantsAmount: Bool {
        guard item != nil, !answer.isStaple else { return false }
        return amount <= .zero
    }

    var isReady: Bool {
        guard item != nil else { return false }
        return answer.isStaple || amount > .zero
    }

    var headline: String {
        if isUnreadable { return "Could not read that as a product code" }
        if let name = answer.name { return name }
        if answer.isSkipped { return "Left for later" }
        return "What is this?"
    }

    /// **A barcode carries no size**, so there are exactly two honest starting points:
    ///
    /// - A food counted in units -- a tin, a banana, a dozen eggs -- gets ONE, because one
    ///   scanned package is one of it.
    /// - Anything measured by weight or volume gets ZERO, and the row says "no amount yet".
    ///   The number cannot tell the app whether the tub is 8 oz or 16, `FoodItemBarcode` has
    ///   nowhere to remember that it was 8 last time, and a guess here is a lie in the one
    ///   place the pantry is supposed to be trustworthy.
    static func startingQuantity(
        for answer: ScanAnswer, catalog: IngredientCatalog
    ) -> (Rational, KitchenUnit) {
        let unit = answer.purchaseUnit(catalog: catalog) ?? UnitCatalog.each
        return (unit.isCount ? .one : .zero, unit)
    }
}

/// What the confirm actually did, counted rather than implied.
struct BarcodeSummary {
    var put = 0
    var staples = 0
    var remembered = 0
    var unanswered = 0
    var noAmount = 0
    var unreadable = 0

    var lines: [String] {
        var out: [String] = []
        if put > 0 {
            out.append(put == 1 ? "1 package put in the pantry"
                                : "\(put) packages put in the pantry")
        }
        if staples > 0 {
            out.append(staples == 1 ? "1 staple marked as in the house"
                                    : "\(staples) staples marked as in the house")
        }
        if remembered > 0 {
            out.append(remembered == 1
                       ? "1 number remembered \u{2014} it will fill itself in next time"
                       : "\(remembered) numbers remembered \u{2014} they will fill themselves in next time")
        }
        if noAmount > 0 {
            out.append(noAmount == 1
                       ? "1 had no amount, so nothing was added for it"
                       : "\(noAmount) had no amount, so nothing was added for them")
        }
        if unanswered > 0 {
            out.append(unanswered == 1 ? "1 left unanswered" : "\(unanswered) left unanswered")
        }
        if unreadable > 0 {
            out.append(unreadable == 1 ? "1 unreadable number, which was not stored"
                                       : "\(unreadable) unreadable numbers, which were not stored")
        }
        if out.isEmpty { out.append("Nothing was written.") }
        return out
    }
}
