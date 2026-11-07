import SwiftUI
import SwiftData

/// The places food sits: pantry, fridge, freezer, spice rack, bar, garage fridge.
///
/// A model rather than an enum, which is why this screen exists at all — "Garage fridge"
/// arrives without a build. The kind behind each one is only what the app guesses an icon and
/// a default shelf life from; the NAME is what he reads.
struct StorageLocationsView: View {
    @Environment(\.modelContext) private var context

    @Query private var locations: [StorageLocation]

    @State private var isAdding = false
    @State private var editing: StorageLocation?
    @State private var refusal: DeleteRefusal?
    @State private var pendingDeletion: StorageLocation?

    var body: some View {
        List {
            if ordered.isEmpty {
                Section { nothing }
            } else {
                Section {
                    ForEach(ordered) { place in
                        Button {
                            editing = place
                        } label: {
                            row(place)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                attemptDelete(place)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("A shelf life here pre-fills the best-by on anything new you put "
                         + "away, which you can always change on the lot.")
                }
            }

            Section {
                Button {
                    isAdding = true
                } label: {
                    Label("Add a place", systemImage: "plus")
                }
                .frame(minHeight: 44)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                StorageLocationSheet(location: nil, existing: locations)
            }
        }
        .sheet(item: $editing) { place in
            NavigationStack {
                StorageLocationSheet(location: place, existing: locations)
            }
        }
        .alert(
            "Cannot delete it",
            isPresented: isShowingRefusal,
            presenting: refusal
        ) { _ in
            Button("OK") { refusal = nil }
        } message: { reason in
            // The refusal's own words, so this, the roster and the default store all refuse
            // alike rather than three screens inventing three sentences.
            Text("\(reason.message) \(reason.suggestion).")
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            if let place = pendingDeletion {
                Button("Delete \(place.displayName)", role: .destructive) {
                    PantryEditor.delete(place, in: context)
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            }
        } message: {
            Text(deletionMessage)
        }
    }

    private var ordered: [StorageLocation] { PantryLevels.ordered(locations) }

    private func row(_ place: StorageLocation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: place.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.displayName)
                Text(detail(place)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(place.displayName), \(detail(place))")
    }

    private func detail(_ place: StorageLocation) -> String {
        let lots = place.orderedLots.count
        var parts = [lots == 1 ? "1 lot" : "\(lots) lots"]
        if let days = place.defaultShelfLifeDays {
            parts.append("best-by \(days) days out")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var nothing: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "cabinet",
            headline: "No places yet",
            detail: "Add the fridge, the freezer and the pantry and new lots can be filed "
                  + "where they actually are. Anything already added without a place still "
                  + "counts.",
            actionTitle: "Add a place",
            action: { isAdding = true }
        )
    }

    // MARK: - Deleting

    /// The last one is refused in `DeleteRefusal`'s own words. A location WITH lots is
    /// allowed: `StorageLocation.lots` is `.nullify`, so the lots survive and move to the
    /// "No location" group — the level never changes — and the message says so rather than
    /// letting him find out.
    private func attemptDelete(_ place: StorageLocation) {
        switch PantryEditor.canDelete(place, of: locations) {
        case .success:
            pendingDeletion = place
        case .failure(let reason):
            refusal = reason
        }
    }

    private var isShowingRefusal: Binding<Bool> {
        Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var deletionTitle: String {
        guard let place = pendingDeletion else { return "Delete this place?" }
        return "Delete \(place.displayName)?"
    }

    private var deletionMessage: String {
        guard let place = pendingDeletion else { return "" }
        let lots = place.orderedLots.count
        if lots == 0 {
            return "Nothing is filed here."
        }
        let word = lots == 1 ? "lot" : "lots"
        return "Its \(lots) \(word) are kept and nothing you have changes amount \u{2014} "
             + "they move to \u{201C}No location\u{201D} in the pantry until you file them "
             + "somewhere else."
    }
}

/// Adding or renaming a place.
///
/// The kind is a picker rather than inferred from the name, because it decides the icon and
/// the suggested shelf life and a "beer fridge" is a fridge. Choosing a kind re-suggests both,
/// and never overwrites a number he has already set.
struct StorageLocationSheet: View {
    let location: StorageLocation?
    let existing: [StorageLocation]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var kind: StorageKind = .pantry
    @State private var hasShelfLife = false
    @State private var shelfLifeDays = 7
    @State private var didSeed = false

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. Garage fridge", text: $name)
                    .frame(minHeight: 44)
                Picker("Kind", selection: $kind) {
                    ForEach(StorageKind.allCases, id: \.self) { option in
                        Label(
                            StorageLocationSheet.title(for: option),
                            systemImage: StorageLocationSheet.symbol(for: option)
                        )
                        .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
            } header: {
                Text("What to call it")
            } footer: {
                Text("The kind sets the icon and suggests a shelf life. The name is what you "
                     + "read everywhere else.")
            }

            Section {
                Toggle("Suggest a best-by", isOn: $hasShelfLife)
                    .frame(minHeight: 44)
                if hasShelfLife {
                    Stepper(value: $shelfLifeDays, in: 1...3650) {
                        Text("\(shelfLifeDays) days")
                            .monospacedDigit()
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("Days until best-by")
                    .accessibilityValue("\(shelfLifeDays) days")
                }
            } footer: {
                Text("Day-granular on purpose: a shelf life measured to the second is false "
                     + "precision on a date you read as \u{201C}around the 14th\u{201D}.")
            }
        }
        .navigationTitle(location == nil ? "Add a place" : "Edit place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: kind) { _, newKind in
            guard !hasShelfLife, let suggested = StorageLocationSheet.shelfLife(for: newKind) else {
                return
            }
            shelfLifeDays = suggested
            hasShelfLife = true
        }
        .onAppear(perform: seedOnce)
    }

    private func seedOnce() {
        guard !didSeed else { return }
        didSeed = true
        guard let location = location else { return }
        name = location.name
        kind = location.kind
        if let days = location.defaultShelfLifeDays {
            hasShelfLife = true
            shelfLifeDays = days
        }
    }

    private func save() {
        let days = hasShelfLife ? shelfLifeDays : nil
        let symbol = StorageLocationSheet.symbol(for: kind)
        if let location = location {
            PantryEditor.update(
                location,
                name: name,
                kind: kind,
                symbolName: symbol,
                shelfLifeDays: days,
                in: context
            )
        } else {
            PantryEditor.addLocation(
                name: name,
                kind: kind,
                symbolName: symbol,
                shelfLifeDays: days,
                existing: existing,
                in: context
            )
        }
        dismiss()
    }

    // MARK: - What a kind looks like
    //
    // The three tables below are the seed's own, read off `KitchenAidSeed.seedLocations`
    // rather than invented, so a hand-added fridge looks and behaves like the seeded one.
    // `StorageKind` itself carries no title or symbol, and it is a frozen Support type, so
    // they live here rather than as an extension a second screen could disagree with.

    static func title(for kind: StorageKind) -> String {
        switch kind {
        case .pantry: return "Pantry"
        case .fridge: return "Fridge"
        case .freezer: return "Freezer"
        case .spice: return "Spice rack"
        case .bar: return "Bar"
        case .other: return "Somewhere else"
        }
    }

    static func symbol(for kind: StorageKind) -> String {
        switch kind {
        case .pantry: return "cabinet"
        case .fridge: return "refrigerator"
        case .freezer: return "snowflake"
        case .spice: return "leaf"
        case .bar: return "wineglass"
        case .other: return "shippingbox"
        }
    }

    static func shelfLife(for kind: StorageKind) -> Int? {
        switch kind {
        case .fridge: return 7
        case .freezer: return 90
        case .pantry, .spice, .bar, .other: return nil
        }
    }
}
