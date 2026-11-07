import SwiftUI
import SwiftData

/// The household: named people, each a full or a half portion, addable and removable.
///
/// **Nothing here knows how many people there are.** Two are seeded because today it is
/// "mostly just me plus 1 adult", and the screen is the same screen for one person and for
/// nine. Anonymous heads at a party are not here at all — they are
/// `PlannedMeal.guestCount`, counted and never named.
///
/// **No dietary or allergy data.** Brandon was offered per-person restrictions and warnings
/// and declined them, so there is no field, no section and no hook for one.
struct HouseholdView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.storeUnavailable) private var storeUnavailable

    @Query private var allEaters: [Eater]

    @State private var isAddingPerson = false
    @State private var pendingRemoval: Eater?

    var body: some View {
        List {
            if storeUnavailable {
                Section {
                    Text("The database could not be opened, so anyone added now will be "
                         + "gone when the app closes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if active.isEmpty && inactive.isEmpty {
                Section { emptyRoster }
            }

            if !active.isEmpty {
                Section {
                    ForEach(active) { eater in
                        row(eater)
                    }
                } header: {
                    Text("Eating here")
                } footer: {
                    Text(portionsFooter)
                }
            }

            if !inactive.isEmpty {
                Section {
                    ForEach(inactive) { eater in
                        row(eater)
                    }
                } header: {
                    Text("Not eating here at the moment")
                } footer: {
                    Text("Kept out of the pickers. Every meal they were on still reads the "
                         + "same.")
                }
            }

            Section {
                Button {
                    isAddingPerson = true
                } label: {
                    Label("Add someone", systemImage: "person.badge.plus")
                }
                .frame(minHeight: 44)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Household")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $isAddingPerson) {
            NavigationStack {
                AddPersonSheet(roster: ordered)
            }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            if let eater = pendingRemoval {
                Button("Remove \(eater.displayName)", role: .destructive) {
                    HouseholdEditor.remove(eater, in: context)
                    pendingRemoval = nil
                }
                // Offered beside the destructive choice because it is usually what he
                // means: away at college keeps every history row and only drops out of
                // the pickers.
                Button("Just stop including them") {
                    HouseholdEditor.setActive(eater, isActive: false)
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            }
        } message: {
            Text(removalMessage)
        }
    }

    // MARK: - Rows

    private func row(_ eater: Eater) -> some View {
        NavigationLink {
            EaterEditorView(eater: eater)
        } label: {
            HStack(spacing: 12) {
                EaterChip(eater: eater)
                VStack(alignment: .leading, spacing: 2) {
                    Text(eater.displayName).font(.body.weight(.medium))
                    Text(portionText(eater))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingRemoval = eater
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// "Half portion", or the exact fraction when it is neither.
    ///
    /// The editor offers exactly full and half, which is what Brandon asked for, but the
    /// storage is a rational pair — so a 3/2 written by a later build is shown as 3/2
    /// rather than rounded into one of two values. `humanDescription`, never
    /// `exactDescription`: that is how a label came to read "23 1111/1135 tsp".
    private func portionText(_ eater: Eater) -> String {
        var parts: [String] = []
        if eater.portion == .one {
            parts.append("Full portion")
        } else if eater.isHalfPortion {
            parts.append("Half portion")
        } else {
            parts.append("\(eater.portion.humanDescription) of a portion")
        }
        let rules = HouseholdEditor.orderedDefaults(for: eater).filter { $0.isEnabled }
        if !rules.isEmpty {
            parts.append(rules.count == 1 ? "1 standing rule" : "\(rules.count) standing rules")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Reading the roster

    private var ordered: [Eater] {
        allEaters.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    private var active: [Eater] { ordered.filter { $0.isActive } }
    private var inactive: [Eater] { ordered.filter { !$0.isActive } }

    /// The point of the line is that a head count is not a portion count: four people, two
    /// of them on half portions, is three portions and cooking four wastes food every time.
    private var portionsFooter: String {
        let people = active.count
        let portions = active.reduce(Rational.zero) { $0 + $1.portion }
        let peopleWord = people == 1 ? "person" : "people"
        let portionWord = portions == .one ? "portion" : "portions"
        return "\(people) \(peopleWord), \(portions.humanDescription) \(portionWord) "
            + "between them. Recipes scale by the portions, not the heads."
    }

    /// The store is seeded with two, so this is only reached if he removes everybody. It
    /// says what that means rather than looking broken.
    private var emptyRoster: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "person.2",
            headline: "Nobody in the household",
            detail: "Meals will scale for guests alone until someone is here. Add yourself "
                  + "and whoever else eats.",
            actionTitle: "Add someone",
            action: { isAddingPerson = true }
        )
    }

    // MARK: - Removal

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    private var removalTitle: String {
        guard let eater = pendingRemoval else { return "Remove from the household?" }
        return "Remove \(eater.displayName) from the household?"
    }

    /// Honest about what survives, because the delete rules mean two different things and
    /// the wrong guess is the one he cannot undo.
    ///
    /// `MealAttendance.eater` is `.nullify`: every meal they are on keeps its row, its name
    /// snapshot and the portion it was cooked for, so the plan does not quietly restate
    /// itself. `Eater.attendanceDefaults` is `.cascade`: their standing rules go, which is
    /// right — "never home Thursdays" is about a person who is no longer here.
    private var removalMessage: String {
        guard let eater = pendingRemoval else { return "" }
        let meals = HouseholdEditor.plannedMealCount(for: eater)
        let rules = (eater.attendanceDefaults ?? []).count

        var sentences: [String] = []
        if meals == 0 {
            sentences.append("They are not on any meal.")
        } else {
            let mealWord = meals == 1 ? "meal" : "meals"
            sentences.append(
                "The \(meals) \(mealWord) they are on keep them, by name, and still show "
                + "the portions they were planned for. Nothing already planned changes "
                + "amount."
            )
        }
        if rules > 0 {
            let ruleWord = rules == 1 ? "standing rule" : "standing rules"
            sentences.append("Their \(rules) \(ruleWord) are deleted.")
        }
        sentences.append(
            "They stop appearing on new meals. If they are only away for a while, stop "
            + "including them instead and nothing is deleted at all."
        )
        return sentences.joined(separator: " ")
    }
}

/// Adding a person. A sheet with a draft rather than an inserted blank row, because an
/// `Eater` with an empty name renders as "Unnamed" in every picker and on every chip, and
/// that reads as a bug rather than as an invitation.
struct AddPersonSheet: View {
    let roster: [Eater]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var shortName = ""
    @State private var isHalfPortion = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField(shortNamePrompt, text: $shortName)
            } header: {
                Text("Who")
            } footer: {
                Text("The short name is what fits on a calendar chip. Left empty, it is "
                     + "taken from the name.")
            }

            Section {
                Picker("Portion", selection: $isHalfPortion) {
                    Text("Full portion").tag(false)
                    Text("Half portion").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("How much they eat")
            } footer: {
                Text("This is what scales a recipe. A half portion counts as half when the "
                     + "amounts are worked out, which a head count cannot express.")
            }
        }
        .navigationTitle("Add someone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    HouseholdEditor.add(
                        name: name,
                        shortName: shortName,
                        isHalfPortion: isHalfPortion,
                        roster: roster,
                        in: context
                    )
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var shortNamePrompt: String {
        let derived = HouseholdEditor.defaultShortName(for: name, given: "")
        return derived.isEmpty ? "Short name" : "Short name, e.g. \(derived)"
    }
}
