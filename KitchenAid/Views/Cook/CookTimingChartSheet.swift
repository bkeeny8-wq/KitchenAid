import SwiftUI

/// THE WEIGHT CHART, as a thing you tap rather than a thing you read.
///
/// The roast turkey has no total time at all: it times at 13 minutes per pound
/// and prints eight rows of weight against total, covered and uncovered time,
/// because a 10 lb bird and a 24 lb bird share the recipe and nothing else. At
/// the oven, with a bird in his hands, the useful interaction is one tap on his
/// own row -- not reading a grid, and not doing the multiplication himself.
///
/// Tapping a row writes its FIRST cell into `selectedKey`, which is what makes
/// the fact line under the step read "Timing read for a 14 lb bird". That is the
/// whole output of this screen, and it is all of it: nothing here reads the plan,
/// resolves a weight or touches the store.
///
/// Where that key GOES is the caller's business and has two answers. Opened from
/// the library it is session state and nothing more. Opened on a planned dish,
/// `CookView` hands this sheet a binding that also writes the weight onto the
/// `MealRecipe` -- because the shopping list is built from the plan, and a bird
/// chosen only here could never reach it. This sheet cannot tell the two apart
/// and must not try: a screen that knew which it was would be the second place
/// deciding when a weight is worth storing.
///
/// The table is deliberately untyped in the content model -- nothing parses
/// "2 hr 10 min" into minutes or "10 lb" into a weight -- so nothing here
/// recomputes a row either. These are the document's own numbers, shown as the
/// document printed them, and the column headings come from the file rather than
/// being written in here, so a second recipe with a different table still reads
/// correctly instead of being labelled as a turkey.
///
/// Its own `NavigationStack`, for the reason given on `CookIngredientsSheet`:
/// `CookView` presents these bare.
struct CookTimingChartSheet: View {

    let table: RecipeTable
    let minutesPerPound: Rational?
    let ovenTempF: Int?

    /// The first column of the row he picked, e.g. "14 lb". Empty means he has
    /// not picked one, which is the state `CookView` tests to decide whether to
    /// show the fact line at all.
    @Binding var selectedKey: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if table.rows.isEmpty {
                    EmptyStateView(
                        kind: .nothingYet,
                        symbol: "tablecells",
                        headline: "No rows in this chart",
                        detail: "The recipe names a table but the import found no rows in "
                              + "it, so there is nothing to look up."
                    )
                } else {
                    list
                }
            }
            .navigationTitle(table.name.isEmpty ? "Cooking times" : table.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { chrome }
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            if ovenTempF != nil || minutesPerPound != nil {
                factsSection
            }
            if let row = selectedRow {
                selectedSection(row)
            }
            rowsSection
        }
        .listStyle(.insetGrouped)
    }

    @ToolbarContentBuilder
    private var chrome: some ToolbarContent {
        // Only once there is something to clear. A mis-tap must be undoable --
        // otherwise the fact line under every step claims a weight he never
        // meant, and there is no other way to take it back. On a planned dish
        // the caller's binding takes the stored weight with it, which is the
        // point: the plan must not keep claiming a bird this screen no longer
        // does.
        if !selectedKey.isEmpty {
            ToolbarItem(placement: .cancellationAction) {
                Button("Clear") { selectedKey = "" }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }

    // MARK: - What the recipe says around the table

    @ViewBuilder
    private var factsSection: some View {
        Section {
            if let oven = ovenTempF {
                LabeledContent("Oven", value: "\(oven)\u{00B0}F")
            }
            if let perPound = minutesPerPound {
                // `humanDescription`, never `exactDescription`: the rate is a
                // rational and 13/1 must read as "13".
                LabeledContent("Rate", value: "\(perPound.humanDescription) min per pound")
            }
        } footer: {
            Text("The rows below are the document's own arithmetic, not the app's.")
        }
    }

    // MARK: - The picked row, repeated

    /// Found through the table's own lookup rather than by comparing strings, so
    /// a key of "14" and a first cell of "14 lb" land on the same row.
    private var selectedRow: [String]? {
        guard !selectedKey.isEmpty else { return nil }
        return table.row(matchingFirstColumn: selectedKey)
    }

    /// The first cell of the picked row, which is what the tick marks are
    /// compared against. Resolved through the lookup for the same reason.
    private var selectedFirstCell: String {
        guard let row = selectedRow, let first = row.first else { return "" }
        return first.trimmingCharacters(in: .whitespaces)
    }

    /// Pinned at the top so the answer survives scrolling past it: on an eight
    /// row chart his row can be the last one, and the point of this screen is
    /// not to make him find it twice.
    @ViewBuilder
    private func selectedSection(_ row: [String]) -> some View {
        Section {
            ForEach(Array(table.labelled(row).enumerated()), id: \.offset) { index, pair in
                if index == 0 {
                    Text(pair.value)
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                } else {
                    // Spelled out as an HStack rather than a `LabeledContent`
                    // so the value can be set in cook-mode type: this is the
                    // number he reads from across the kitchen.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(pair.label.isEmpty ? "Time" : pair.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 10)
                        Text(pair.value)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            Text("Reading for \(selectedFirstCell)")
        }
    }

    // MARK: - The rows

    @ViewBuilder
    private var rowsSection: some View {
        Section {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                rowButton(row)
            }
        } header: {
            Text("Tap your \(weightLabel.lowercased())")
        }
    }

    /// The first column's heading from the file -- "Turkey weight" -- rather
    /// than the word "weight" written in here, because the next document to
    /// bring a table may not be weighing anything.
    private var weightLabel: String {
        let first = table.headers.first ?? ""
        return first.isEmpty ? "row" : first
    }

    private func rowButton(_ row: [String]) -> some View {
        let first = (row.first ?? "").trimmingCharacters(in: .whitespaces)
        let isSelected = !first.isEmpty && first == selectedFirstCell
        return Button {
            selectedKey = first
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    // Ragged rows are possible and not an error -- a document is
                    // not a spreadsheet -- so every cell is rendered against
                    // whatever header it has, and a cell past the last header
                    // shows its value alone rather than an empty label.
                    ForEach(Array(table.labelled(row).enumerated()), id: \.offset) { index, pair in
                        if index == 0 {
                            Text(pair.value)
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                        } else if pair.label.isEmpty {
                            Text(pair.value)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(pair.label)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 10)
                                Text(pair.value)
                                    .font(.subheadline.weight(.medium))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 56)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
