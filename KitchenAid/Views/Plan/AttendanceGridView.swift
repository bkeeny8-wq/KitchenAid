import SwiftUI
import SwiftData

/// Who is eating this meal, and how much of it.
///
/// A four-person dinner is four taps and no sheet: each chip cycles
/// attending → away → maybe → leftovers-only through `MealAttendance.cycleStatus()`. The
/// portions and the resulting scale are computed by `PlannedMeal.portionTotal` and rendered
/// by `PortionSummary` — nothing here sums a portion.
///
/// Three things it will not do, each a decision rather than an omission:
///
/// - **No dietary or allergy data.** Brandon was offered it and declined. `plateNote` is
///   "sauce on the side" — a note on a plate, which warns about nothing.
/// - **Guests are counted, never named.** One number and one portion size, because the
///   point of a guest count is a party you do not want to type a roster for.
/// - **No head count is hardcoded.** The grid is whatever the roster is: right for one
///   person and right for nine.
///
/// It renders several `Section`s and must be placed inside a `List` or `Form`.
struct AttendanceGridView: View {
    let meal: PlannedMeal
    let roster: [Eater]

    @Environment(\.modelContext) private var context

    private static let columns = [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 8)]

    var body: some View {
        Group {
            Section {
                if meal.orderedAttendance.isEmpty {
                    Text("Nobody is down for this meal yet. Add whoever is eating and the "
                         + "amounts follow from it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 8) {
                        ForEach(meal.orderedAttendance) { row in
                            chip(row)
                        }
                    }
                    .padding(.vertical, 4)
                }

                ForEach(missing) { eater in
                    Button {
                        PlanEditor.add(eater, to: meal, in: context)
                    } label: {
                        Label("Add \(eater.displayName)", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                    .frame(minHeight: 44)
                }

                PortionSummary(meal: meal)
                    .padding(.vertical, 2)
            } header: {
                Text("Who is eating")
            } footer: {
                Text("Tap a face to change whether they are eating. A maybe is shown but "
                     + "deliberately not counted \u{2014} buying for a maybe every week is "
                     + "how a plan drifts into over-buying.")
            }

            Section {
                Stepper(value: guestCount, in: 0...40) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(guestLabel)
                        Text("Counted, not named")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityValue(guestLabel)

                if meal.guestCount > 0 {
                    Picker("Each guest eats", selection: guestsAreHalf) {
                        Text("A full portion").tag(false)
                        Text("A half portion").tag(true)
                    }
                }
            } header: {
                Text("Guests")
            }

            if !consuming.isEmpty {
                Section {
                    ForEach(consuming) { row in
                        plateRow(row)
                    }
                } header: {
                    Text("Portions and plates")
                } footer: {
                    Text("A portion set here applies to this meal only. The household's own "
                         + "full-or-half setting is in Household.")
                }
            }
        }
    }

    // MARK: - Chips

    /// An orphaned row gets no action.
    ///
    /// `eater == nil` means the person was removed from the roster, and the row survives
    /// carrying the name and the portion it was cooked for — history survives the person.
    /// Offering to edit it would invite rewriting what a past dinner was made for, which is
    /// the one thing `effectivePortion` reading its snapshot exists to prevent.
    @ViewBuilder
    private func chip(_ row: MealAttendance) -> some View {
        if row.isOrphaned {
            EaterChip(attendance: row)
        } else {
            EaterChip(attendance: row) { row.cycleStatus() }
                .contextMenu {
                    Button("Take off this meal", systemImage: "person.badge.minus") {
                        PlanEditor.removeAttendance(row, in: context)
                    }
                }
        }
    }

    private var missing: [Eater] {
        PlanEditor.rosterMissing(from: meal, roster: roster)
    }

    private var consuming: [MealAttendance] {
        meal.orderedAttendance.filter { $0.consumesPortion && !$0.isOrphaned }
    }

    // MARK: - One plate

    @ViewBuilder
    private func plateRow(_ row: MealAttendance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.displayName).font(.subheadline.weight(.medium))
            if let exotic = unexpectedPortion(row) {
                // Neither full nor half, so it was written by a future build or another
                // device. Shown as it is rather than rounded into one of two values, with
                // the way back offered explicitly.
                HStack {
                    Text("This meal: \(exotic.humanDescription) of a portion")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Use household") {
                        row.setPortionOverride(nil)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                }
            } else {
                Picker("Portion", selection: portionChoice(row)) {
                    Text("Household setting").tag(0)
                    Text("Full").tag(1)
                    Text("Half").tag(2)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("\(row.displayName) portion")
            }
            TextField("Note on the plate, e.g. sauce on the side", text: plateNote(row))
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    /// nil when the override is absent, a full portion or a half — the three states the
    /// segmented control can express.
    private func unexpectedPortion(_ row: MealAttendance) -> Rational? {
        guard let override = row.portionOverride else { return nil }
        if override == .one || override == Rational(1, 2) { return nil }
        return override
    }

    // MARK: - Bindings
    //
    // Every setter goes through the model's own writer. `setGuests`, `setPortionOverride`
    // and `setStatus` each exist because two stored integers assigned one at a time
    // eventually drift apart, and a numerator with no denominator is the state they were
    // written to make impossible.

    private var guestCount: Binding<Int> {
        Binding(
            get: { meal.guestCount },
            set: { meal.setGuests(count: $0, portion: meal.guestPortion) }
        )
    }

    private var guestsAreHalf: Binding<Bool> {
        Binding(
            get: { meal.guestPortion == Rational(1, 2) },
            set: { meal.setGuests(count: meal.guestCount, portion: $0 ? Rational(1, 2) : .one) }
        )
    }

    private func portionChoice(_ row: MealAttendance) -> Binding<Int> {
        Binding(
            get: {
                guard let override = row.portionOverride else { return 0 }
                return override == Rational(1, 2) ? 2 : 1
            },
            set: { choice in
                switch choice {
                case 1: row.setPortionOverride(.one)
                case 2: row.setPortionOverride(Rational(1, 2))
                default: row.setPortionOverride(nil)
                }
            }
        )
    }

    private func plateNote(_ row: MealAttendance) -> Binding<String> {
        Binding(get: { row.plateNote }, set: { row.plateNote = $0 })
    }

    private var guestLabel: String {
        let n = meal.guestCount
        if n == 0 { return "No guests" }
        return n == 1 ? "1 guest" : "\(n) guests"
    }
}
