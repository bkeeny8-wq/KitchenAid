import SwiftUI
import SwiftData

/// Two rows that mean one food, and what folding them together would do.
///
/// ## Why this screen is load-bearing rather than tidy
///
/// CLAUDE.md's first CloudKit rule is "no `@Attribute(.unique)` anywhere — de-duplicate
/// ingredients in code, not with a constraint". De-duplication in code IS
/// `FoodItemResolver.reconcile`, and that function had no caller anywhere in the tree, so
/// there was no de-duplication at all: duplicate `FoodItem` rows accumulated for ever and the
/// whole `MergeRecord` table had a writer nothing reached. It gets worse rather than better.
/// Two devices under CloudKit sync will each mint their own "heavy cream", and receipt
/// scanning mints rows in bulk from abbreviated tokens, which is exactly where
/// near-duplicates come from.
///
/// Not to be confused with `ReconcileReportView`, which compares a lot's cached amount
/// against the transactions it was summed from. That screen is about two NUMBERS for one
/// fact disagreeing; this one is about two ROWS being the same food.
///
/// ## Review, then confirm. Never automatic
///
/// A merge is destructive: it repoints lots, transactions and shopping lines onto the
/// survivor and then deletes the losers. `FoodItemResolver.duplicateGroups(among:)` exists
/// because `reconcile` could not answer "what would you do" without doing it, and the
/// alternative — merging and undoing to show a preview — would put the only untested code
/// path in the app between him and his ledger. So the group is named in full first: the
/// survivor, every loser, and what moves, counted.
///
/// Silently merging two foods he considers different is worse than leaving both, which is why
/// there is one tap per group, no "merge everything" button, and no merge on launch.
///
/// ## Reachable from Pantry → The ledger → Duplicate items
///
/// Two taps from the tab bar, and the row carries the count, so it reads "2 groups look like
/// the same food" the moment duplicates exist. That is also the answer to WHEN: putting a
/// receipt away ends on "Back to the pantry", which lands on that row. The other half of the
/// timing belongs in `ReceiptScanView`'s own finished stage, as a `NavigationLink` to here
/// beside "Scan another" — the moment the duplicates appear — and never as an automatic pass.
struct MergeDuplicatesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.storeUnavailable) private var storeUnavailable
    @Environment(IngredientCatalog.self) private var catalog

    /// Every `FoodItem` in the store, which is what the grouping needs: re-deriving from a
    /// filtered subset would invent duplicates that are not there.
    @Query private var items: [FoodItem]

    /// The audit trail, newest first. Until this screen, `MergeRecord` was a table with a
    /// writer and no reader at all.
    @Query(sort: \MergeRecord.mergedAt, order: .reverse) private var records: [MergeRecord]

    /// Held in `@State` rather than recomputed in `body`, for the same reason
    /// `ReconcileReportView` holds its rows: this is the one screen where a number must not
    /// change under him between reading it and tapping the button that acts on it. The commit
    /// re-derives and compares signatures, so a stale plan is refused rather than acted on.
    @State private var plan: [PlannedMerge] = []
    @State private var didCheck = false
    @State private var lastCheckedAt: Date?

    @State private var pending: DuplicateGroup?
    @State private var refusal: MergeRefusal?
    @State private var outcome: Outcome?

    /// How many earlier merges the history lists before it just says how many more there are.
    /// The same judgement `FoodItemDetailView` makes about the ledger: nothing prunes this
    /// table, by design.
    private static let historyWindow = 25

    var body: some View {
        List {
            if storeUnavailable { storeSection }
            if let outcome = outcome { outcomeSection(outcome) }

            if !didCheck {
                Section { ProgressView() }
            } else if plan.isEmpty {
                Section { nothingDuplicated }
            } else {
                ForEach(mergeable) { planned in
                    mergeableSection(planned)
                }
                refusedSection
            }

            historySection
            actions
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Duplicate items")
        .navigationBarTitleDisplayMode(.inline)
        // `onAppear` and not `task`: that closure is `@Sendable` and so not main-actor
        // isolated. The same call `ReconcileReportView` and `ReceiptScanView` make for the
        // same reason.
        //
        // Re-checking on every appearance, not just the first, and that matters here rather
        // than being tidiness: `MergeRefusal.wouldHideALevel` sends him to an item screen to
        // forget the alias that links two rows, and coming back has to show the group gone.
        .onAppear { check() }
        .alert(
            "Cannot merge them",
            isPresented: isShowingRefusal,
            presenting: refusal
        ) { _ in
            Button("OK") { refusal = nil }
        } message: { reason in
            // The refusal's own words, so this, the roster and the places screen all refuse
            // alike rather than three screens inventing three sentences.
            Text("\(reason.message) \(reason.suggestion).")
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: isConfirming,
            titleVisibility: .visible
        ) {
            if let group = pending {
                Button("Merge into \(group.survivorName)", role: .destructive) {
                    // `group` is already a value copy taken out of `pending`, so clearing the
                    // dialog's state first cannot change what gets merged.
                    pending = nil
                    commit(group)
                }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - What would merge

    @ViewBuilder
    private func mergeableSection(_ planned: PlannedMerge) -> some View {
        let group = planned.group
        Section {
            line("Keeps", group.survivorName, symbol: "checkmark.circle")
            line(
                group.absorbed.count == 1 ? "Deletes" : "Deletes these",
                names(group),
                symbol: "minus.circle"
            )
            // The sentence he is agreeing to. `movesPhrase` counts lots, transactions and
            // shopping lines the same way `merge` computes `MergeRecord.repointedCount`, so
            // the preview and the audit row cannot say different numbers about one merge.
            line("Moves", movesDetail(planned), symbol: "arrow.right.circle")
            if group.openShoppingLineCount > 0 {
                line("On an open list", openListDetail(group), symbol: "cart", tint: .orange)
            }
            line("Matched on", matchedDetail(group), symbol: "text.magnifyingglass")

            Button(role: .destructive) {
                pending = group
            } label: {
                Label("Merge into \(group.survivorName)", systemImage: "arrow.triangle.merge")
            }
            .frame(minHeight: 44)
            .disabled(storeUnavailable)
        } header: {
            Text("\(group.survivorName) \u{00B7} \(group.absorbed.count + 1) rows")
        } footer: {
            Text("The deleted names become aliases of the one you keep, so a shopping line or "
                 + "a receipt written the old way still finds it. Nothing in the ledger is "
                 + "deleted \u{2014} every row moves across. This cannot be undone.")
        }
    }

    /// The groups this app will not merge, with the refusal's own reason on each.
    ///
    /// Listed rather than hidden. A duplicate the app silently declines to touch is a
    /// duplicate he never learns about, and the way out of this one — forgetting the alias
    /// that links the two rows — is a swipe on the item screen he cannot find without being
    /// told it is there.
    @ViewBuilder
    private var refusedSection: some View {
        let refused = plan.filter { $0.group.refusal != nil }
        if !refused.isEmpty {
            Section {
                ForEach(refused) { planned in
                    if let reason = planned.group.refusal {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(planned.group.survivorName) and \(names(planned.group))")
                                .font(.subheadline.weight(.medium))
                            Text("\(reason.message) \(reason.suggestion).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)

                        // A WAY TO DO THE THING THE REFUSAL ASKS FOR, which this section did
                        // not have. `MergeRefusal.wouldHideALevel` suggests "Forget the alias
                        // that links them, on either item", and `MergeRefusal`'s own comment
                        // two lines above its declaration says "a refusal with no second
                        // button is a dead end". It was one: the sentence named an action and
                        // the screen offered no route to it.
                        //
                        // The route is each item's own screen, which now lists its learned
                        // aliases with swipe-to-forget. Both rows are offered, because the
                        // link can be on either one and only he knows which name is wrong.
                        ForEach(membersToVisit(planned.group)) { member in
                            NavigationLink {
                                FoodItemDetailView(item: member)
                            } label: {
                                Label(
                                    "Open \(member.displayName)",
                                    systemImage: "arrow.up.right.square"
                                )
                                .font(.caption)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
            } header: {
                Text("Left alone \u{00B7} \(refused.count)")
            } footer: {
                Text("These look like one food and are not being merged. The reason is on each "
                     + "one, and both rows stay exactly as they are.")
            }
        }
    }

    /// The live rows behind a refused group, survivor first, for the links above.
    ///
    /// Resolved from `items` by id rather than carried on `DuplicateGroup`, because that
    /// type is a VALUE the preview holds and putting `FoodItem` references on it would make
    /// a stale preview hold deleted objects -- which is the reason `mergeDuplicate` re-reads
    /// the group before it writes.
    private func membersToVisit(_ group: FoodItemResolver.DuplicateGroup) -> [FoodItem] {
        var out: [FoodItem] = []
        if let survivor = items.first(where: { $0.id == group.survivorID }) {
            out.append(survivor)
        }
        for absorbed in group.absorbed {
            if let row = items.first(where: { $0.id == absorbed.id }) { out.append(row) }
        }
        return out
    }

    private func line(
        _ title: String, _ detail: String, symbol: String, tint: Color = .secondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(detail).font(.subheadline)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }

    private func names(_ group: DuplicateGroup) -> String {
        group.absorbedNames.joined(separator: ", ")
    }

    /// "3 lots, 11 transactions, 1 shopping line", or "" when the duplicates carry nothing.
    ///
    /// Barcodes are counted and moved by this screen and not by `merge`: a barcode row's owner
    /// is a stored key rather than a relationship (see `FoodItemBarcode` on why it cannot be
    /// one), so the merge cannot enumerate them. `BarcodeRegistry.repoint(from:to:in:)` was
    /// written for exactly this and had no caller; without it a merged-away item's numbers
    /// read as `.forgotten` and he rescans. Counted here so the sentence covers everything
    /// that actually moves.
    private func movesPhrase(_ planned: PlannedMerge) -> String {
        var parts: [String] = []
        if !planned.group.movesSentence.isEmpty { parts.append(planned.group.movesSentence) }
        if planned.barcodeCount > 0 {
            parts.append(planned.barcodeCount == 1
                ? "1 barcode" : "\(planned.barcodeCount) barcodes")
        }
        return parts.joined(separator: ", ")
    }

    private func movesDetail(_ planned: PlannedMerge) -> String {
        let phrase = movesPhrase(planned)
        guard !phrase.isEmpty else {
            return "Nothing \u{2014} the duplicates carry no lots, no ledger rows and no "
                 + "shopping lines."
        }
        return "\(phrase) onto \(planned.group.survivorName)."
    }

    private func openListDetail(_ group: DuplicateGroup) -> String {
        let count = group.openShoppingLineCount
        if count == 1 {
            return "1 of those lines is on a shopping list you have not finished, and it moves "
                 + "to \(group.survivorName)."
        }
        return "\(count) of those lines are on shopping lists you have not finished, and they "
             + "move to \(group.survivorName)."
    }

    /// Why the app thinks these are one food. An empty `sharedKeys` is legitimate rather than
    /// a bug: grouping is transitive, so two rows can be one purchase because a third shares
    /// a key with each of them.
    private func matchedDetail(_ group: DuplicateGroup) -> String {
        guard !group.sharedKeys.isEmpty else {
            return "another row in this group, which each of these shares a name or an alias "
                 + "with."
        }
        return group.sharedKeys.joined(separator: ", ")
    }

    // MARK: - What happened

    /// Read back off the `MergeRecord` the merge wrote, not off the plan that preceded it. If
    /// those two ever disagree, the row is the one that is true, and this is where it shows.
    ///
    /// A VALUE, holding no `MergeRecord`: a model object in `@State` is a model object that
    /// can be deleted underneath the view. The same reasoning `LedgerDivergence` records for
    /// carrying ids instead of rows.
    private struct Outcome {
        var survivorName: String
        var absorbedNames: [String]
        var repointedCount: Int
        var barcodeCount: Int
        var at: Date
    }

    @ViewBuilder
    private func outcomeSection(_ outcome: Outcome) -> some View {
        let absorbed = outcome.absorbedNames.joined(separator: ", ")
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text("Merged " + absorbed + " into " + outcome.survivorName)
                    .font(.subheadline.weight(.medium))
                Text(outcomeDetail(outcome))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        } header: {
            Text("Done")
        } footer: {
            Text("The names above are now aliases of the item you kept, and the merge itself is "
                 + "a row in the list below that nothing deletes.")
        }
    }

    private func outcomeDetail(_ outcome: Outcome) -> String {
        var parts = [outcome.repointedCount == 1
            ? "1 record moved" : "\(outcome.repointedCount) records moved"]
        if outcome.barcodeCount > 0 {
            parts.append(outcome.barcodeCount == 1
                ? "1 barcode moved" : "\(outcome.barcodeCount) barcodes moved")
        }
        parts.append(PantryLevels.dayText(outcome.at))
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - The audit trail

    /// `MergeRecord`'s first reader. The table exists because a merge that happens silently is
    /// indistinguishable from data loss, and until this section there was nowhere in the app
    /// to find out that one had happened.
    @ViewBuilder
    private var historySection: some View {
        if !records.isEmpty {
            Section {
                ForEach(Array(records.prefix(Self.historyWindow))) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        // `summary` names the rows rather than counting them, because "merged
                        // Shallot into shallot" is a sentence he can check and "merged 1
                        // duplicate" is not.
                        Text(record.summary).font(.subheadline)
                        Text(historyDetail(record))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
                if records.count > Self.historyWindow {
                    Text("and \(records.count - Self.historyWindow) earlier")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Every merge so far \u{00B7} \(records.count)")
            } footer: {
                Text("Nothing deletes a row here, so \u{201C}where did Shallot go\u{201D} still "
                     + "has an answer in six months.")
            }
        }
    }

    private func historyDetail(_ record: MergeRecord) -> String {
        var parts = [PantryLevels.dayText(record.mergedAt)]
        parts.append(record.repointedCount == 1
            ? "1 record moved" : "\(record.repointedCount) records moved")
        if !record.note.isEmpty { parts.append(record.note) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Actions

    private var actions: some View {
        Section {
            Button {
                check()
            } label: {
                Label("Check again", systemImage: "arrow.clockwise")
            }
            .frame(minHeight: 44)
        } footer: {
            Text(actionsFooter)
        }
    }

    private var actionsFooter: String {
        let when = lastCheckedAt.map { "Checked \(PantryLevels.dayText($0)). " } ?? ""
        return when
            + "Nothing is merged until you tap a group and confirm it. The item that survives "
            + "is always the one created first, which is not a preference: two phones have to "
            + "pick the same one with no way to ask each other."
    }

    private var nothingDuplicated: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "checkmark.seal",
            headline: "Nothing looks duplicated",
            detail: "No two items share a name or one of the names you have taught the app. "
                  + "This is worth a look after a receipt, which mints items in bulk from "
                  + "abbreviated lines."
        )
    }

    /// The in-memory fallback store, in the refusal's own words. Merging into a store that
    /// will not be written would delete rows and lose the record saying it did, so every
    /// per-group button is disabled rather than offered and then refused.
    private var storeSection: some View {
        let reason = MergeRefusal(reason: .storeUnavailable)
        return Section {
            Text("\(reason.message) \(reason.suggestion).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Running it

    private var mergeable: [PlannedMerge] { plan.filter { $0.group.refusal == nil } }

    /// A previewed group plus its barcode count, which the resolver deliberately does not know
    /// about: `FoodItemBarcode` is `BarcodeRegistry`'s table, and
    /// `FoodItemResolver.duplicateGroups` takes no context so that it stays safe to call from
    /// a `body`.
    private struct PlannedMerge: Identifiable {
        var group: DuplicateGroup
        var barcodeCount: Int
        var id: UUID { group.id }
    }

    /// Clears the "Done" banner, because a fresh check is a fresh question: leaving the last
    /// merge's summary above a newly derived list reads as though it were part of it.
    private func check() {
        plan = FoodItemResolver.duplicateGroups(among: items).map { group in
            PlannedMerge(group: group, barcodeCount: barcodeCount(of: group))
        }
        outcome = nil
        lastCheckedAt = .now
        didCheck = true
    }

    private func barcodeCount(of group: DuplicateGroup) -> Int {
        var total = 0
        for absorbed in group.absorbed {
            let descriptor = FoodItemBarcode.descriptor(forItemKey: absorbed.id.uuidString)
            // `fetch` is `throws -> [FoodItemBarcode]`, so `try?` yields ONE optional and not
            // two. SE-0230 flattening is what produced blocking defect 5 in CODE_REVIEW_01,
            // and it is not worth being clever about twice.
            total += (try? context.fetch(descriptor))?.count ?? 0
        }
        return total
    }

    /// Re-derive, prove it is still the group he read, move the barcodes, then merge.
    ///
    /// The order is the whole point. The freshness check runs before anything is written,
    /// because a barcode repointed onto the wrong survivor is not something a later refusal
    /// can take back. `mergeDuplicate` then checks the signature again itself, which is
    /// deliberate duplication: it is the thing that deletes rows, and a guard at one call site
    /// is not a guard.
    ///
    /// **`check()` is NOT called afterwards, and that is not an oversight.** `items` is the
    /// array this render was given, so straight after a merge it still holds the rows that
    /// were just deleted, and re-deriving would read `createdAt` and `matchKey` off destroyed
    /// model objects. The plan is pruned by VALUE instead, which is exact: union-find groups
    /// are disjoint, and the only new key a merge creates is the loser's own name as an alias
    /// of the survivor — already inside the group — so merging one group cannot change the
    /// membership of another.
    private func commit(_ group: DuplicateGroup) {
        guard !storeUnavailable else {
            refusal = MergeRefusal(reason: .storeUnavailable, subjectName: group.survivorName)
            return
        }

        // Nothing has been written yet, so re-deriving here is safe and the plan can be
        // rebuilt in full.
        let fresh = FoodItemResolver.duplicateGroups(among: items)
        guard let live = fresh.first(where: { $0.signature == group.signature }) else {
            check()
            refusal = MergeRefusal(reason: .changedSinceCheck, subjectName: group.survivorName)
            return
        }
        // The group's OWN refusal if it has grown one since the check — a lot added to a
        // duplicate while this screen was open is enough — because that reason is more use to
        // him than "something changed".
        if let refused = live.refusal {
            check()
            refusal = refused
            return
        }

        let resolver = FoodItemResolver(catalog: catalog)
        let barcodes = repointBarcodes(for: live, using: resolver)

        do {
            let record = try resolver.mergeDuplicate(live, among: items, in: context)
            outcome = Outcome(
                survivorName: record.survivorName,
                absorbedNames: record.absorbedNames,
                repointedCount: record.repointedCount,
                barcodeCount: barcodes,
                at: record.mergedAt
            )
            plan = plan.filter { $0.id != live.id }
        } catch let reason as MergeRefusal {
            refusal = reason
        } catch {
            // `mergeDuplicate` saves, and a save that throws leaves the deletions sitting in
            // the context unwritten. Saying that, and sending him to "Check again", is more
            // use than a message that claims either outcome.
            refusal = MergeRefusal(reason: .couldNotSave, subjectName: group.survivorName)
        }
    }

    /// Barcodes move BEFORE the losers are deleted, because afterwards the only handle on a
    /// loser is a `FoodItem` that no longer exists, and `repoint` takes the row rather than
    /// its id.
    ///
    /// The residue of that order, stated rather than left to be found: if the merge then
    /// throws, the numbers are attached to the survivor while both rows still exist. That is
    /// not data loss — the survivor is the same food by the app's own grouping, and the next
    /// scan resolves to it — and the alternative is a barcode that reads as `.forgotten`
    /// because nothing could reach it after the delete.
    private func repointBarcodes(
        for group: DuplicateGroup, using resolver: FoodItemResolver
    ) -> Int {
        guard let survivor = items.first(where: { $0.id == group.survivorID }) else { return 0 }
        let registry = BarcodeRegistry(resolver: resolver)
        var moved = 0
        for absorbed in group.absorbed {
            guard let loser = items.first(where: { $0.id == absorbed.id }) else { continue }
            moved += (try? registry.repoint(from: loser, to: survivor, in: context)) ?? 0
        }
        return moved
    }

    // MARK: - Alert and dialog bindings

    private var isShowingRefusal: Binding<Bool> {
        Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var confirmTitle: String {
        guard let group = pending else { return "Merge these?" }
        return group.absorbed.count == 1
            ? "Merge \(names(group)) into \(group.survivorName)?"
            : "Merge \(group.absorbed.count) items into \(group.survivorName)?"
    }

    /// The confirmation says the whole thing rather than "are you sure". Three of the ten
    /// blocking defects in CODE_REVIEW_01 were decisions written up as done that he could not
    /// reach; the matching failure for a destructive action is a button whose sentence is not
    /// what it does.
    private var confirmMessage: String {
        guard let group = pending,
              let planned = plan.first(where: { $0.id == group.id })
        else { return "" }

        let phrase = movesPhrase(planned)
        var sentences = [
            "\(group.survivorName) is kept. \(names(group)) "
            + (group.absorbed.count == 1 ? "is deleted" : "are deleted")
            + (phrase.isEmpty
                ? ", and there is nothing to move: it carries no lots and no ledger rows."
                : ", and \(phrase) moves onto \(group.survivorName).")
        ]
        if group.openShoppingLineCount > 0 {
            sentences.append("That includes \(group.openShoppingLineCount) "
                + (group.openShoppingLineCount == 1 ? "line" : "lines")
                + " on a shopping list you have not finished.")
        }
        sentences.append("The deleted names become aliases, so nothing stops resolving. This "
                         + "cannot be undone.")
        return sentences.joined(separator: " ")
    }
}
