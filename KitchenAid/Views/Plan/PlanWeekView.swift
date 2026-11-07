import SwiftUI
import SwiftData

/// The week. What the Plan tab opens on.
///
/// There is no `MealPlan` row and no week entity — a week is a view concern, and baking one
/// into the data would make the boundary a migration. So this screen holds an anchor date,
/// derives seven days from it, and files every meal under `CalendarKey.dayKey`.
///
/// **Days are matched by integer EQUALITY, never by a date range.** A half-open `Date`
/// comparison is correct until he crosses a timezone or a DST boundary, and then Tuesday's
/// dinner renders on Monday night, which reads as "the app moved my dinner".
struct PlanWeekView: View {
    @Environment(\.modelContext) private var context

    /// Bare, and filtered in Swift, exactly as `TodayView` does it. The store holds a few
    /// meals a week; a dynamic `#Predicate` over a rebuilt key set every time he taps the
    /// chevron would be more machinery than the data justifies.
    @Query private var allMeals: [PlannedMeal]
    @Query private var allEaters: [Eater]

    @State private var anchor: Date = .now
    @State private var addingOn: PlanSheetDay?

    private var week: PlanWeek { PlanWeek(containing: anchor) }

    var body: some View {
        List {
            if isWeekEmpty {
                Section { emptyWeek }
            }
            ForEach(week.days, id: \.self) { day in
                daySection(day)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { weekBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addingOn = PlanSheetDay(date: startOfToday())
                } label: {
                    Image(systemName: "plus")
                }
                // An icon-only button says nothing to VoiceOver without this.
                .accessibilityLabel("Plan a meal")
            }
        }
        .sheet(item: $addingOn) { day in
            NavigationStack {
                AddMealSheet(date: day.date)
            }
        }
    }

    // MARK: - The week bar

    /// Prev / next / this week. Three 44-point targets, each labelled, because they are the
    /// controls he uses most on this screen and a chevron with no label is unreachable.
    private var weekBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    step(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Previous week")

                VStack(spacing: 1) {
                    Text(week.title)
                        .font(.subheadline.weight(.semibold))
                    Text(mealCountLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)

                Button {
                    step(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next week")
            }
            .padding(.horizontal, 8)

            thisWeekButton
            Divider()
        }
        .background(.bar)
    }

    @ViewBuilder
    private var thisWeekButton: some View {
        if !week.contains(Date()) {
            Button("Back to this week") {
                anchor = Date()
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func step(by weeks: Int) {
        let calendar = Calendar.current
        if let moved = calendar.date(byAdding: .weekOfYear, value: weeks, to: anchor) {
            anchor = moved
        }
    }

    private var mealCountLabel: String {
        let n = week.days.reduce(0) { $0 + meals(on: $1).count }
        return n == 1 ? "1 meal planned" : "\(n) meals planned"
    }

    // MARK: - A day

    @ViewBuilder
    private func daySection(_ day: Date) -> some View {
        let dayMeals = meals(on: day)
        Section {
            ForEach(dayMeals) { meal in
                NavigationLink {
                    MealEditorView(meal: meal)
                } label: {
                    PlanMealRow(meal: meal)
                }
            }
            // Only on days that already have something. An empty week is seven "Add a
            // meal" buttons and no information, which is why the empty state above
            // carries the invitation instead.
            if !dayMeals.isEmpty {
                Button {
                    addingOn = PlanSheetDay(date: day)
                } label: {
                    Label("Add a meal", systemImage: "plus")
                        .font(.subheadline)
                }
                .frame(minHeight: 44)
            }
        } header: {
            dayHeader(day, count: dayMeals.count)
        }
    }

    private func dayHeader(_ day: Date, count: Int) -> some View {
        HStack(spacing: 6) {
            NavigationLink {
                PlanDayView(date: day)
            } label: {
                HStack(spacing: 4) {
                    Text(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                    if isToday(day) {
                        Text("TODAY")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Color.accentColor)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
            }
            .accessibilityLabel(
                "\(day.formatted(.dateTime.weekday(.wide).day().month(.wide))), "
                + (count == 1 ? "1 meal" : "\(count) meals")
            )
            Spacer(minLength: 0)
        }
    }

    // MARK: - Reading the store

    /// `dayKey` equality, then the slot's own sort index so `.prep` comes first — "salt the
    /// steaks the day before" belongs ahead of the day's meals, and sorting on `slotRaw`
    /// would put brunch before dinner alphabetically and prep last.
    private func meals(on day: Date) -> [PlannedMeal] {
        let key = CalendarKey.dayKey(for: day)
        return allMeals
            .filter { $0.dayKey == key }
            .sorted {
                ($0.slotSortIndex, $0.orderInSlot, $0.createdAt)
                    < ($1.slotSortIndex, $1.orderInSlot, $1.createdAt)
            }
    }

    private var isWeekEmpty: Bool {
        week.days.allSatisfy { meals(on: $0).isEmpty }
    }

    private func isToday(_ day: Date) -> Bool {
        CalendarKey.dayKey(for: day) == CalendarKey.dayKey(for: Date())
    }

    private func startOfToday() -> Date {
        // The day he is looking at, when he is looking at this week; otherwise the first
        // day of the week on screen. Opening the sheet on a date that is not visible is
        // how a meal lands in the wrong week.
        week.contains(Date()) ? Date() : (week.days.first ?? Date())
    }

    /// An empty week is the normal state of a new install, so it has to look deliberate
    /// rather than broken. `.nothingYet` and not `.somethingWrong`: nothing is wrong.
    private var emptyWeek: some View {
        EmptyStateView(
            kind: .nothingYet,
            symbol: "calendar",
            headline: "Nothing planned this week",
            detail: "Add a meal to a day and pick the recipes for it. Who is eating comes "
                  + "from the household, so the amounts follow on their own.",
            actionTitle: "Plan a meal",
            action: { addingOn = PlanSheetDay(date: startOfToday()) }
        )
    }
}

/// Seven days from an anchor, in the user's own calendar.
///
/// Built by walking the calendar a day at a time rather than by arithmetic, because
/// `20261031 + 1` is `20261032`, which is not a date. Month ends and leap days are exactly
/// where a plan week is most likely to be wrong.
struct PlanWeek {
    let days: [Date]

    init(containing date: Date, calendar: Calendar = .current) {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
        var built: [Date] = []
        for offset in 0..<7 {
            if let day = calendar.date(byAdding: .day, value: offset, to: start) {
                built.append(calendar.startOfDay(for: day))
            }
        }
        days = built.isEmpty ? [calendar.startOfDay(for: date)] : built
    }

    /// "27 Oct – 2 Nov". Both ends are spelled out, because a week that crosses a month or
    /// a year is the one he is most likely to be looking at when the label matters.
    var title: String {
        guard let first = days.first, let last = days.last else { return "" }
        let a = first.formatted(.dateTime.day().month(.abbreviated))
        let b = last.formatted(.dateTime.day().month(.abbreviated))
        return "\(a) \u{2013} \(b)"
    }

    func contains(_ date: Date) -> Bool {
        let key = CalendarKey.dayKey(for: date)
        return days.contains { CalendarKey.dayKey(for: $0) == key }
    }
}

/// `Date` is `Identifiable` nowhere in the SDK, and `.sheet(item:)` needs an id. Scoped to
/// this file's use of a date as "which day is the add sheet open on", and deliberately not
/// a conformance on `Date` itself: a public extension making every date in the app
/// identifiable by its own value is the kind of thing that collides with another file.
struct PlanSheetDay: Identifiable, Hashable {
    let date: Date
    var id: Int { CalendarKey.dayKey(for: date) }
}
