import SwiftUI
import SwiftData

/// THE LIST. What the Shop tab is for.
///
/// Four blocks, and `ShoppingListLine.block` decides which one a line is in — once, in the
/// model layer, so they are mutually exclusive and together hold every line. This screen only
/// renders that decision; it never asks the same question a second way:
///
/// 1. **Needs attention**, pinned at the top: the lines where the app is telling him it could
///    not finish the arithmetic, and the only lines with a fix he can apply.
/// 2. **The aisles**, in the walk order snapshotted onto each line at generation.
/// 3. **Already have**, collapsed. **Kept, never hidden** — a silently absent line is
///    indistinguishable from a bug, and he has to see the app's belief about his fridge before
///    he will trust it.
/// 4. **Staples**, collapsed: tracked present or absent, no quantity, because a list that
///    keeps asking for salt is a list you stop reading.
///
/// Checking a line off moves it into "In the cart" with a count, which is the one piece of
/// state this screen writes to the store — through `ShoppingListLine.setChecked`, so the tick
/// and its timestamp cannot disagree.
struct ShoppingListDetailView: View {
    let list: ShoppingList

    // Only what this screen itself writes. The services the BUILD needs are read by
    // `GenerateShoppingListSheet`, and the catalogue by `AddShoppingItemSheet`: an
    // `@Environment` lookup declared non-optional traps when the value is absent, so one
    // declared here and used nowhere is a crash this screen could take for a sheet's benefit.
    @Environment(\.modelContext) private var context
    @Environment(\.storeUnavailable) private var storeUnavailable
    /// The exception to the rule above, and the reason the rule is stated as "what this
    /// screen writes" rather than "no services": putting the shop away IS a write this
    /// screen makes. `InventoryLedger.receive(_:in:)` had no caller anywhere in the app --
    /// the whole trip-home path was written, commented and referenced in three other files'
    /// prose, and invoked by nothing. A checked-off list that never reaches the pantry makes
    /// the comparison on every future list wrong in the same direction, for ever.
    @Environment(InventoryLedger.self) private var ledger: InventoryLedger?

    @State private var isAdding = false
    @State private var isRebuilding = false
    /// Removal is behind this rather than on every row: he is holding a phone in a shop, and a
    /// destructive control under his thumb on all 23 rows is a line deleted by accident.
    @State private var isEditingLines = false
    @State private var showCart = true
    @State private var showCovered = false
    @State private var showStaples = false
    @State private var confirmArchive = false
    @State private var confirmReceive = false
    /// The ledger's own sentence, not one written here. `LedgerError.alreadyReceived` names
    /// the list, and a second wording of it is a second thing that can drift.
    @State private var receiveFailure: String? = nil

    var body: some View {
        List {
            progressSection
            attentionSection
            aisleSections
            cartSection
            coveredSection
            staplesSection
            elsewhereSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(list.title.isEmpty ? "Shopping" : list.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isAdding) {
            AddShoppingItemSheet(list: list)
        }
        .sheet(isPresented: $isRebuilding) {
            GenerateShoppingListSheet(replacing: list)
        }
        .alert("Archive this list?", isPresented: $confirmArchive) {
            Button("Archive", role: .destructive) { archive() }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text("It stays under Past lists, with everything you checked off. Nothing is "
               + "deleted and the pantry is not changed.")
        }
        .alert("Put \(checkedCount) item\(checkedCount == 1 ? "" : "s") in the pantry?",
               isPresented: $confirmReceive) {
            Button("Put it away") { receive() }
            Button("Not yet", role: .cancel) { }
        } message: {
            Text("Only what you checked off. Each one becomes a lot with today's date, and "
               + "a staple is just marked present. Anything you walked past is left alone.")
        }
        .alert(
            "That did not go in",
            isPresented: Binding(
                get: { receiveFailure != nil },
                set: { if !$0 { receiveFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { receiveFailure = nil }
        } message: {
            Text(receiveFailure ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isAdding = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add an item to this list")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    isEditingLines.toggle()
                } label: {
                    Label(
                        isEditingLines ? "Done removing" : "Remove items",
                        systemImage: isEditingLines ? "checkmark" : "minus.circle"
                    )
                }
                Button {
                    isRebuilding = true
                } label: {
                    Label("Rebuild from the plan", systemImage: "arrow.triangle.2.circlepath")
                }
                // Export is NOT in here: it is a toolbar button of its own, because it is
                // the one feature whose output leaves the device and burying it two taps
                // down is how a share-sheet feature stops being used.
                Divider()
                Button {
                    confirmReceive = true
                } label: {
                    Label(
                        isReceived ? "Already put away" : "Put the shop away",
                        systemImage: isReceived ? "checkmark.circle" : "shippingbox"
                    )
                }
                .disabled(isReceived || checkedCount == 0)
                Divider()
                Button {
                    confirmArchive = true
                } label: {
                    Label("Archive this list", systemImage: "archivebox")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("List options")
        }
        ToolbarItem(placement: .topBarTrailing) {
            PDFExportButton(
                job: .shoppingList(listID: list.id),
                fileLabel: list.title.isEmpty ? "Shopping list" : list.title
            )
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(progressText)
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    if storeUnavailable {
                        Text("not saving")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                ProgressView(value: Double(checkedCount), total: Double(max(1, shoppableCount)))
                    .accessibilityLabel("Shopping progress")
                    .accessibilityValue(progressText)
                Text(provenanceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var progressText: String {
        guard shoppableCount > 0 else { return "Nothing to buy" }
        return "\(checkedCount) of \(shoppableCount) in the cart"
    }

    /// What produced these numbers, in one line, because the options are frozen onto the list
    /// and a list regenerated under different ones visibly differs from the one he shopped.
    private var provenanceText: String {
        var parts: [String] = [list.subtractInventory ? "pantry subtracted" : "pantry ignored"]
        if list.includeStaples { parts.append("staples included") }
        if list.includeOptionalLines { parts.append("optional lines included") }
        let count = list.coveredMeals.count
        parts.append(count == 1 ? "1 meal" : "\(count) meals")
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - The blocks

    /// Checked lines leave their aisle and gather in the cart, so what is left on screen is
    /// what is left to find. They are never deleted by checking: unchecking puts the line
    /// back where it was.
    private var attentionLines: [ShoppingListLine] {
        list.needsAttention.filter { !$0.isChecked }
    }

    private var cartLines: [ShoppingListLine] {
        list.orderedLines.filter { $0.isChecked }
    }

    /// Everything a cart can hold: the aisles plus the pinned lines. Covered lines and
    /// staples are excluded because there is nothing to put in a trolley for either.
    private var shoppableCount: Int {
        list.orderedLines.filter { $0.block == .aisle || $0.block == .needsAttention }.count
    }

    private var checkedCount: Int { cartLines.count }

    @ViewBuilder
    private var attentionSection: some View {
        if !attentionLines.isEmpty {
            Section {
                ForEach(attentionLines) { line in
                    row(line)
                }
            } header: {
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } footer: {
                // A bridge line is VISIBLE and explains itself rather than being silently
                // dropped or quietly rounded: 4 oz of butter by weight cannot answer a 2 tbsp
                // requirement by volume without knowing what a cup weighs. Tapping the line
                // is where that answer is given, once, forever.
                Text("These are on the list in full, because the app could not finish the "
                   + "arithmetic. Tap one to see what it needs.")
            }
        }
    }

    @ViewBuilder
    private var aisleSections: some View {
        ForEach(sections) { group in
            let unchecked = group.lines.filter { !$0.isChecked }
            if !unchecked.isEmpty {
                Section(group.name) {
                    ForEach(unchecked) { line in
                        row(line)
                    }
                }
            }
        }
    }

    /// A named type and not `ShoppingList.linesBySection`'s tuple, because Swift has no key
    /// path to a tuple element: `ForEach(_, id: \.sectionName)` over a tuple array does not
    /// compile, and `id: \.self` cannot work either since the payload is an array of model
    /// objects. The section name is the identity, which it already is — the model layer
    /// returns one group per distinct name.
    private struct AisleGroup: Identifiable {
        let name: String
        let lines: [ShoppingListLine]
        var id: String { name }
    }

    /// The walk order, which puts Frozen last — it is shipped in `ingredients.json` and
    /// snapshotted onto every line at generation, so reordering his aisles in March does not
    /// re-sort a list he shopped in November.
    private var sections: [AisleGroup] {
        list.linesBySection.map { AisleGroup(name: $0.sectionName, lines: $0.lines) }
    }

    @ViewBuilder
    private var cartSection: some View {
        if !cartLines.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showCart) {
                    ForEach(cartLines) { line in
                        row(line)
                    }
                } label: {
                    Label("In the cart (\(cartLines.count))", systemImage: "cart.fill")
                        .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder
    private var coveredSection: some View {
        let covered = list.coveredFooter
        if !covered.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showCovered) {
                    ForEach(covered) { line in
                        NavigationLink {
                            ShoppingLineDetailView(line: line)
                        } label: {
                            ShoppingLineRow(line: line)
                        }
                    }
                } label: {
                    Label("Already have (\(covered.count))", systemImage: "checkmark.seal")
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("Kept rather than removed. A line that vanishes is indistinguishable "
                   + "from a line the app got wrong.")
            }
        }
    }

    @ViewBuilder
    private var staplesSection: some View {
        let staples = list.staplesFooter
        if !staples.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showStaples) {
                    ForEach(staples) { line in
                        NavigationLink {
                            ShoppingLineDetailView(line: line)
                        } label: {
                            ShoppingLineRow(line: line)
                        }
                    }
                } label: {
                    Label("Staples, assumed on hand (\(staples.count))", systemImage: "shippingbox")
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("Salt, pepper, oils, vinegars and spices are tracked present or absent "
                   + "with no quantity. Say one is running low in the pantry and it joins the "
                   + "list proper.")
            }
        }
    }

    // MARK: - The rest of the tab

    /// Past lists and the other two things that can be printed, as rows at the foot of the
    /// list rather than as two more toolbar buttons.
    ///
    /// They are here and not in the menu above because a `NavigationLink` inside a toolbar
    /// `Menu` is a push that the menu has to dismiss first, and this is the one screen he uses
    /// one-handed in a shop. A row is a row.
    @ViewBuilder
    private var elsewhereSection: some View {
        Section {
            NavigationLink {
                ShoppingListArchiveView()
            } label: {
                Label("Past lists", systemImage: "archivebox")
                    .frame(minHeight: 44)
            }
            NavigationLink {
                ExportCenterView()
            } label: {
                Label("Print or share something else", systemImage: "printer")
                    .frame(minHeight: 44)
            }
        }
    }

    // MARK: - A row

    /// Checkbox, then the row as the label of a link into its provenance, then the removal
    /// control when he has asked for one. Three siblings and no nesting, so every tap lands
    /// where it looks like it will.
    @ViewBuilder
    private func row(_ line: ShoppingListLine) -> some View {
        HStack(alignment: .top, spacing: 4) {
            ShoppingLineCheckButton(line: line) { toggle(line) }
            NavigationLink {
                ShoppingLineDetailView(line: line)
            } label: {
                ShoppingLineRow(line: line)
            }
            if isEditingLines {
                Button(role: .destructive) {
                    remove(line)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(line.displayName) from this list")
            }
        }
    }

    // MARK: - Writes

    private func toggle(_ line: ShoppingListLine) {
        // `setChecked` is the only writer of the pair, so an unchecked line cannot keep a
        // stale timestamp that a later regenerate would read as a completed purchase.
        line.setChecked(!line.isChecked)
    }

    private func remove(_ line: ShoppingListLine) {
        // A generated line comes back on the next rebuild, which is the honest behaviour: the
        // plan still asks for it. A line he added by hand does not, and that is also honest.
        context.delete(line)
    }

    /// Posted ONCE per list, and the ledger is what enforces that rather than this screen:
    /// it refuses a list that already has `receivedTransactions` and names it in the error.
    /// A guard here as well would be a second owner of the rule, and the one that gets
    /// forgotten when a second caller appears.
    private func receive() {
        guard let ledger = ledger else {
            // Reachable in the window before the launch task runs, and on a device whose
            // store fell back to memory. Saying so beats a tap that does nothing.
            receiveFailure = "The pantry is still starting up. Try again in a moment."
            return
        }
        do {
            try ledger.receive(list, in: context)
        } catch let error as LedgerError {
            receiveFailure = error.message
        } catch {
            receiveFailure = error.localizedDescription
        }
    }

    private var isReceived: Bool { !(list.receivedTransactions ?? []).isEmpty }

    private func archive() {
        list.isArchived = true
        list.completedAt = .now
    }
}
