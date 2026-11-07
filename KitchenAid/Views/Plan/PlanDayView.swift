import SwiftUI
import SwiftData

/// One day, every slot.
///
/// The week shows only the slots that have something in them, which is right for scanning
/// seven days at once and wrong for filling a single day in — the slot he wants is the one
/// that is not there yet. So this screen lists every slot, empty ones included, each with
/// its own add button.
///
/// `.prep` sorts first and is labelled for what it is. "Salt the steaks, uncovered in the
/// fridge" belongs to the dinner it precedes, a day earlier, and a prep slot filed after
/// dinner would be read as a meal he forgot to cook.
struct PlanDayView: View {
    let date: Date

    @Query private var allMeals: [PlannedMeal]

    @State private var addingOn: PlanSheetDay?

    private var dayKey: Int { CalendarKey.dayKey(for: date) }

    var body: some View {
        List {
            ForEach(orderedSlots) { slot in
                slotSection(slot)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $addingOn) { day in
            NavigationStack {
                AddMealSheet(date: day.date, slot: pendingSlot)
            }
        }
    }

    /// Driven by `MealSlot.sortIndex`, not by the declaration order of the enum, because
    /// that index is also what the store sorts on. Two orderings of the same list is how
    /// the day screen and the week screen end up disagreeing.
    private var orderedSlots: [MealSlot] {
        MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Which slot the add button was tapped in. Held beside the sheet item rather than
    /// inside it so the one `PlanSheetDay` type stays about the day alone.
    @State private var pendingSlot: MealSlot = .dinner

    @ViewBuilder
    private func slotSection(_ slot: MealSlot) -> some View {
        let slotMeals = meals(in: slot)
        Section {
            ForEach(slotMeals) { meal in
                NavigationLink {
                    MealEditorView(meal: meal)
                } label: {
                    PlanMealRow(meal: meal)
                }
            }
            Button {
                pendingSlot = slot
                addingOn = PlanSheetDay(date: date)
            } label: {
                Label(
                    slotMeals.isEmpty ? "Add \(slot.title.lowercased())" : "Add another",
                    systemImage: "plus"
                )
                .font(.subheadline)
            }
            .frame(minHeight: 44)
        } header: {
            Label(slot.title, systemImage: slot.symbol)
        } footer: {
            if slot == .prep && slotMeals.isEmpty {
                Text("Work done a day ahead \u{2014} salting a steak, making a sauce. It "
                     + "sorts above the day's meals and its ingredients are bought with "
                     + "the meal it is for, not twice.")
            }
        }
    }

    private func meals(in slot: MealSlot) -> [PlannedMeal] {
        allMeals
            .filter { $0.dayKey == dayKey && $0.slotRaw == slot.rawValue }
            .sorted { ($0.orderInSlot, $0.createdAt) < ($1.orderInSlot, $1.createdAt) }
    }
}
