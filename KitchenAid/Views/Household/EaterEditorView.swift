import SwiftUI
import SwiftData

/// One household member.
///
/// Edited in place, no Save button: the roster is two rows deep and a cancel would have to
/// unwind a relationship change by hand.
///
/// The portion control offers exactly **full or half**, which is what Brandon asked for.
/// The storage underneath is a rational pair rather than a `Bool` for one reason, and it is
/// worth not undoing: a `Bool` cannot become 3/2 for a teenager without a type-change
/// migration, and a pair can. A value that is neither is shown as it is rather than rounded
/// into one of the two buttons.
///
/// There is no dietary or allergy section. He was offered it and said no, and this file
/// deliberately leaves no hook for one.
struct EaterEditorView: View {
    let eater: Eater

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var isAddingRule = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: nameBinding)
                TextField("Short name", text: shortNameBinding)
            } header: {
                Text("Name")
            } footer: {
                Text("The short name is what fits on a calendar chip: \u{201C}\(eater.initials)\u{201D}.")
            }

            Section {
                if let exotic = unexpectedPortion {
                    HStack {
                        Text("\(exotic.humanDescription) of a portion")
                        Spacer(minLength: 8)
                        Button("Use a full portion") {
                            eater.setPortion(.one)
                        }
                        .frame(minHeight: 44)
                    }
                } else {
                    Picker("Portion", selection: halfPortionBinding) {
                        Text("Full portion").tag(false)
                        Text("Half portion").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("How much they eat")
            } footer: {
                Text("Changing this does not restate meals already planned. Those keep the "
                     + "portion they were planned with, so last month's dinners still read "
                     + "the way they were cooked.")
            }

            Section {
                colorPicker
            } header: {
                Text("Colour")
            }

            Section {
                Toggle("Include on new meals", isOn: activeBinding)
            } header: {
                Text("Availability")
            } footer: {
                Text("Turned off, they stay out of the pickers and every meal they are "
                     + "already on is untouched.")
            }

            rulesSection
        }
        .navigationTitle(eater.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingRule) {
            NavigationStack {
                AddAttendanceRuleSheet(eater: eater)
            }
        }
    }

    // MARK: - Colour

    /// Buttons rather than a `Picker`, because the choice is a colour and a menu of colour
    /// names is not the same control. Indexes come from the palette so an eleventh person
    /// gets a colour — `EaterPalette` wraps rather than clamping.
    private var colorPicker: some View {
        HStack(spacing: 4) {
            ForEach(Array(EaterPalette.colors.indices), id: \.self) { index in
                Button {
                    eater.colorIndex = index
                } label: {
                    ZStack {
                        Circle()
                            .fill(EaterPalette.color(for: index))
                            .frame(width: 28, height: 28)
                        if eater.colorIndex == index {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.white)
                        }
                    }
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(index + 1)")
                .accessibilityAddTraits(eater.colorIndex == index ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Standing rules

    /// `AttendanceDefault`: "he is never home Thursdays", applied when a meal is created so
    /// steady-state attendance costs zero taps. A plan he has to fill in every week is a
    /// plan he stops filling in.
    @ViewBuilder
    private var rulesSection: some View {
        Section {
            let rules = HouseholdEditor.orderedDefaults(for: eater)
            if rules.isEmpty {
                Text("No rules. They are counted in on every new meal.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.ruleDescription).font(.subheadline.weight(.medium))
                        Text(AttendanceStatusStyle.title(rule.status).capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            HouseholdEditor.removeDefault(rule, in: context)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            Button {
                isAddingRule = true
            } label: {
                Label("Add a rule", systemImage: "plus")
            }
            .frame(minHeight: 44)
        } header: {
            Text("Standing rules")
        } footer: {
            Text("Applied when a meal is created, so a usual week needs no taps. The most "
                 + "specific rule wins: a Thursday-dinner rule beats a Thursday rule, "
                 + "which beats an every-meal rule. Changing a rule does not alter meals "
                 + "already on the calendar.")
        }
    }

    // MARK: - Bindings

    private var nameBinding: Binding<String> {
        Binding(get: { eater.name }, set: { eater.name = $0 })
    }

    private var shortNameBinding: Binding<String> {
        Binding(get: { eater.shortName }, set: { eater.shortName = $0 })
    }

    private var activeBinding: Binding<Bool> {
        Binding(get: { eater.isActive }, set: { eater.isActive = $0 })
    }

    /// Writes through `setPortion`, the one writer of the integer pair: a view assigning
    /// the numerator and the denominator one at a time is how they drift apart.
    private var halfPortionBinding: Binding<Bool> {
        Binding(
            get: { eater.isHalfPortion },
            set: { eater.setPortion($0 ? Rational(1, 2) : .one) }
        )
    }

    private var unexpectedPortion: Rational? {
        if eater.portion == .one || eater.isHalfPortion { return nil }
        return eater.portion
    }
}

/// "Never home Thursdays." One weekday or every day, one slot or every slot, one status.
struct AddAttendanceRuleSheet: View {
    let eater: Eater

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// 0 means every day; 1...7 are `Calendar`'s own weekdays, 1 = Sunday.
    @State private var weekday = 0
    /// Empty means every slot, matching `AttendanceDefault.slotRaw`'s own wildcard.
    @State private var slotRaw = ""
    @State private var status: AttendanceStatus = .away

    var body: some View {
        Form {
            Section {
                Picker("Day", selection: $weekday) {
                    Text("Every day").tag(0)
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { pair in
                        Text(pair.element + "s").tag(pair.offset + 1)
                    }
                }
                Picker("Meal", selection: $slotRaw) {
                    Text("Every meal").tag("")
                    ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                        Text(slot.title).tag(slot.rawValue)
                    }
                }
            } header: {
                Text("When")
            }

            Section {
                Picker("Then they are", selection: $status) {
                    ForEach(AttendanceStatus.allCases, id: \.self) { value in
                        Text(AttendanceStatusStyle.title(value).capitalized).tag(value)
                    }
                }
            } header: {
                Text("What to assume")
            } footer: {
                Text("A maybe is shown on the meal and deliberately not counted in the "
                     + "amounts.")
            }
        }
        .navigationTitle("Add a rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    HouseholdEditor.addDefault(
                        to: eater,
                        weekday: weekday == 0 ? nil : weekday,
                        slot: slotRaw.isEmpty ? nil : MealSlot(rawValue: slotRaw),
                        status: status,
                        in: context
                    )
                    dismiss()
                }
            }
        }
    }

    /// `Calendar`'s own symbols, so the list is in the user's locale and its indexes line
    /// up with the `weekday` component `AttendanceDefault.applies(weekday:slot:)` is given.
    private var weekdaySymbols: [String] {
        Calendar.current.weekdaySymbols
    }
}
