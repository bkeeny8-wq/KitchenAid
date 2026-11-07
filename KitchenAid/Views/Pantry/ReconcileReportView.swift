import SwiftUI
import SwiftData

/// **The screen that justifies the ledger.**
///
/// A level is summed from an item's transactions; a lot carries a cached `remaining` so that
/// "do I have enough butter" does not re-sum a multi-year log on every render. Two numbers
/// for one fact can disagree, and this is where the disagreement becomes visible and
/// attributable instead of being something he only senses when the shopping list looks wrong.
///
/// Three scopes, and they are three different bugs with three different fixes, which is why
/// `LedgerDivergence.Scope` separates them rather than returning a `diverged` Bool:
///
/// 1. **A lot** whose cache differs from its own rows. Rebuilding the caches fixes it.
/// 2. **An item** whose lot caches, added up, differ from the sum of all its transactions.
/// 3. **Unassigned rows** — transactions whose lot was deleted. These are not an error on
///    their own: they are counted by `level` and are usually the explanation for the item row
///    sitting next to them. A rebuild does NOT clear them; filing them against a lot does.
struct ReconcileReportView: View {
    @Environment(\.modelContext) private var context
    @Environment(InventoryLedger.self) private var injectedLedger: InventoryLedger?

    /// Held in state rather than recomputed in `body`: the report walks every lot and every
    /// item, and it is the one screen where a number must not change under him between
    /// reading it and tapping the button that acts on it.
    @State private var rows: [LedgerDivergence] = []
    @State private var didRun = false
    @State private var lastRunAt: Date?

    @MainActor
    private var ledger: InventoryLedger {
        injectedLedger ?? InventoryLedger(container: context.container)
    }

    var body: some View {
        List {
            if !didRun {
                Section { ProgressView() }
            } else if rows.isEmpty {
                Section { agrees }
            } else {
                section(
                    title: "Lots",
                    detail: "The lot's cached amount against the rows filed against it.",
                    rows: rows.filter(isLotScope)
                )
                section(
                    title: "Items",
                    detail: "Every lot cache added up, against every transaction on the item.",
                    rows: rows.filter(isItemScope)
                )
                unassignedSection
            }
            actions
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Reconcile")
        .navigationBarTitleDisplayMode(.inline)
        // `onAppear` rather than `task`: that closure is `@Sendable` and so not main-actor
        // isolated, and the report is main-actor work. Re-running on every appearance is
        // wanted here — he comes back to this screen to see whether the repair took.
        .onAppear { run() }
    }

    // MARK: - Sections

    @MainActor
    @ViewBuilder
    private func section(title: String, detail: String, rows: [LedgerDivergence]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    divergenceRow(row)
                }
            } header: {
                Text("\(title) \u{00B7} \(rows.count)")
            } footer: {
                Text(detail)
            }
        }
    }

    @MainActor
    @ViewBuilder
    private var unassignedSection: some View {
        let unassigned = rows.filter(isUnassignedScope)
        if !unassigned.isEmpty {
            Section {
                ForEach(unassigned) { row in
                    if let item = itemFor(row) {
                        NavigationLink {
                            FoodItemDetailView(item: item)
                        } label: {
                            divergenceRow(row)
                        }
                    } else {
                        divergenceRow(row)
                    }
                }
            } header: {
                Text("Not filed against a lot \u{00B7} \(unassigned.count)")
            } footer: {
                Text("These rows count towards what you have \u{2014} nothing is missing. "
                     + "They have no lot, usually because a lot was deleted, so they are "
                     + "listed rather than left as a gap nothing explains. Rebuilding the "
                     + "caches will not change them.")
            }
        }
    }

    @MainActor
    private func divergenceRow(_ row: LedgerDivergence) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.itemName).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                if row.isDiverged {
                    Text(row.display(row.delta, system: ledger.unitSystem))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
            if !row.lotLabel.isEmpty {
                Text(row.lotLabel).font(.caption).foregroundStyle(.secondary)
            }
            // The sentence, not a Bool: "cache says 2 lb, ledger says 1 lb 14 oz, short by
            // 2 oz" is the difference between trusting the repair and reinstalling the app.
            Text(row.message(system: ledger.unitSystem))
                .font(.caption)
                .foregroundStyle(.secondary)
            if row.pendingBridgeCount > 0 {
                Text(row.pendingBridgeCount == 1
                     ? "1 row here has no amount yet."
                     : "\(row.pendingBridgeCount) rows here have no amount yet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var agrees: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "checkmark.seal",
            headline: "The ledger and the caches agree",
            detail: "Every lot's cached amount matches the rows it was summed from, and "
                  + "every item's total matches its transactions."
        )
    }

    // MARK: - Actions

    @MainActor
    @ViewBuilder
    private var actions: some View {
        Section {
            Button {
                run()
            } label: {
                Label("Check again", systemImage: "arrow.clockwise")
            }
            .frame(minHeight: 44)

            Button {
                // The ledger is the truth, so the repair direction is only ever
                // rows -> cache. There is deliberately no button that writes a cache figure
                // back into the ledger: that would be inventing a transaction.
                try? ledger.rebuildAllCaches(in: context)
                run()
            } label: {
                Label("Rebuild every cached amount", systemImage: "arrow.triangle.2.circlepath")
            }
            .frame(minHeight: 44)
        } header: {
            Text("Repair")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        let when = lastRunAt.map { "Checked \(PantryLevels.dayText($0)). " } ?? ""
        return when
            + "A rebuild re-sums every lot from its own rows. It never changes a "
            + "transaction: the ledger is what the caches are measured against, so the "
            + "repair only ever runs one way."
    }

    // MARK: - Running it

    @MainActor
    private func run() {
        rows = (try? ledger.reconcileReport(in: context)) ?? []
        lastRunAt = .now
        didRun = true
    }

    private func itemFor(_ row: LedgerDivergence) -> FoodItem? {
        guard case .unassignedLot(let itemID) = row.scope else { return nil }
        return PantryLevels.item(withID: itemID, in: context)
    }

    private func isLotScope(_ row: LedgerDivergence) -> Bool {
        if case .lot = row.scope { return true }
        return false
    }

    private func isItemScope(_ row: LedgerDivergence) -> Bool {
        if case .item = row.scope { return true }
        return false
    }

    private func isUnassignedScope(_ row: LedgerDivergence) -> Bool {
        if case .unassignedLot = row.scope { return true }
        return false
    }
}
