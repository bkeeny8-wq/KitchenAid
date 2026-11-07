import SwiftUI
import SwiftData

/// "Add paper towels", and "add two more lemons".
///
/// Two paths on purpose, and they are not the same thing. Picking from the catalogue resolves
/// to a `FoodItem` through `FoodItemResolver` — the one creation site — so the line lands in
/// the right aisle with the right unit and the pantry can meet it later. A name he types is
/// added **without** minting an item: paper towels are not food, and a row in the food
/// vocabulary for every stray purchase is how the catalogue stops being worth picking from.
/// Such a line files itself under "Unsorted", which is where it belongs and where he will
/// still see it.
struct AddShoppingItemSheet: View {
    let list: ShoppingList

    @Environment(IngredientCatalog.self) private var catalog
    @Environment(ShoppingListStore.self) private var shopping
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var picked: CatalogEntry? = nil
    @State private var typedName: String = ""
    @State private var wantsAmount = false
    @State private var amount: Rational = .one
    @State private var unit: KitchenUnit = UnitCatalog.each
    @State private var isPicking = false

    var body: some View {
        NavigationStack {
            List {
                itemSection
                // `== false` rather than `let entry = picked, !entry.staple`: neither branch
                // reads the entry itself, and a bound name nothing uses is a warning.
                if picked?.staple == false {
                    amountSection
                }
                if picked?.staple == true {
                    Section {
                        Text("Staples are tracked present or absent, with no quantity. "
                           + "It will go on the list as a reminder to pick some up.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add to the list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(!canAdd)
                }
            }
            .sheet(isPresented: $isPicking) {
                NavigationStack {
                    CatalogPickerView(title: "Pick an ingredient") { entry in
                        picked = entry
                        typedName = ""
                        // The unit comes from the entry and is never typed. A count entry
                        // keeps its noun ("clove"), because the noun IS the aggregation
                        // bucket: a line counted in cloves cannot be added to one counted in
                        // heads, and the picker must not quietly offer the wrong one.
                        if let entryUnit = entry.defaultUnit { unit = entryUnit }
                        wantsAmount = false
                        amount = .one
                    }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var itemSection: some View {
        Section {
            Button {
                isPicking = true
            } label: {
                HStack {
                    Label(
                        picked?.name ?? "Pick from the catalogue",
                        systemImage: "text.magnifyingglass"
                    )
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
            .accessibilityLabel(
                picked == nil
                    ? "Pick an ingredient from the catalogue"
                    : "Chosen: \(picked?.name ?? "")"
            )

            if let entry = picked {
                LabeledContent("Aisle", value: entry.aisle.isEmpty ? "Unsorted" : entry.aisle)
                Button("Clear", role: .destructive) { picked = nil }
                    .frame(minHeight: 44)
            }
        } header: {
            Text("Ingredient")
        } footer: {
            Text("The aisle and the unit come from the catalogue entry, so the line sorts "
               + "into the right place without typing either.")
        }

        if picked == nil {
            Section {
                TextField("Paper towels", text: $typedName)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Something else, by name")
            } header: {
                Text("Or something that is not food")
            } footer: {
                Text("Added by name only, with no pantry item behind it, under Unsorted.")
            }
        }
    }

    @ViewBuilder
    private var amountSection: some View {
        Section {
            Toggle("Give it an amount", isOn: $wantsAmount)
                .frame(minHeight: 44)
            if wantsAmount {
                QuantityField(label: "Amount", value: $amount, unitName: unit.name(for: amount))
                UnitPicker(
                    dimension: unit.dimension,
                    countNoun: unit.isCount ? unit.code : "",
                    system: list.unitSystem,
                    unit: $unit
                )
            }
        } header: {
            Text("How much")
        } footer: {
            Text("Optional. Without one the line is a reminder, which is all \u{201C}grab "
               + "more butter\u{201D} needs to be.")
        }
    }

    // MARK: - Adding

    private var canAdd: Bool {
        picked != nil || !typedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        let resolver = FoodItemResolver(catalog: catalog)
        var item: FoodItem? = nil
        var name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)

        if let entry = picked {
            // `try?` and not `try!`: the resolver fetches, and a store that could not be
            // opened is a real state this app runs in (see the launch fallback). A nil item
            // still adds the line by name, which is strictly better than refusing to add it.
            item = try? resolver.findOrCreate(fromCatalog: entry, in: context)
            name = entry.name
        }

        // A staple never carries a quantity, anywhere in the app.
        let isStaple = picked?.staple ?? false
        let quantity: Quantity? = (wantsAmount && !isStaple)
            ? Quantity(amount: amount, unit: unit)
            : nil

        shopping.addManualLine(name, item: item, quantity: quantity, to: list, in: context)
        dismiss()
    }
}
