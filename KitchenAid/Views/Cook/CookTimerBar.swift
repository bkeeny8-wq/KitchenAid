import SwiftUI

/// The clock for ONE step, under the step it belongs to.
///
/// A step that has a duration gets a countdown; a step that has none gets
/// nothing at all. That second case is not a gap: the turkey's ten steps carry
/// no duration whatsoever because the recipe times by weight, and a bar reading
/// "0:00" under every one of them would be an invitation to start a timer the
/// document never asked for. See the chart sheet for how that recipe is timed.
///
/// **`TimelineView`, not `Timer.publish`.** Both can drive a second hand; they
/// differ in what has to be cleaned up. A publisher is a live subscription that
/// has to be cancelled, and the thing it is cancelled against is view lifetime,
/// which is exactly the bookkeeping that gets dropped -- a timer left running
/// behind a dismissed cook screen keeps a phone awake. A `TimelineView` holds no
/// subscription: the schedule only drives the view while the view exists, so
/// moving to the next step or leaving cook mode stops it with no `onDisappear`
/// to forget. The deadline lives in `endsAt` and the remaining time is
/// SUBTRACTED from it on each tick rather than counted down into state, so a
/// tick that arrives late or not at all cannot make the clock drift, and
/// nothing is mutated during a view update.
///
/// `CookView` applies `.id(step.stepID)` here, which is what resets a running
/// clock when he moves on rather than letting it follow him to the next step.
/// So this view owns no "which step am I for" state -- identity does it.
///
/// Every number read aloud goes through `CookClock.spoken`, because a clock face
/// read as "four oh five" is a time of day and not four minutes and five seconds.
struct CookTimerBar: View {

    let step: RecipeStep

    /// The deadline. Non-nil means the clock is running, and it is the only
    /// place the running time is kept.
    @State private var endsAt: Date? = nil

    /// The periodic schedule's anchor: the moment he started or resumed, which
    /// is in the past. Anchoring on `endsAt` instead would be asking for updates
    /// from a date that has not arrived yet.
    @State private var startedAt: Date? = nil

    /// Seconds left at the moment he paused. nil means "never started, or reset",
    /// which shows the step's full duration -- so no seeding pass is needed and
    /// there is no half-initialised state to get wrong.
    @State private var pausedRemaining: Int? = nil

    var body: some View {
        // `timerSeconds` takes the LONGER end of a range, so a timer never fires
        // early on the fixture's "7 to 8 min".
        if let total = step.timerSeconds, total > 0 {
            bar(total: total)
        }
    }

    @ViewBuilder
    private func bar(total: Int) -> some View {
        if let startedAt, let endsAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                face(
                    remaining: Self.secondsLeft(until: endsAt, now: context.date),
                    total: total,
                    isRunning: true
                )
            }
        } else {
            face(remaining: pausedRemaining ?? total, total: total, isRunning: false)
        }
    }

    // MARK: - The face

    /// Rounded UP, so a timer started at 30 minutes reads "30:00" for its first
    /// second instead of "29:59".
    private static func secondsLeft(until deadline: Date, now: Date) -> Int {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return Int(remaining.rounded(.up))
    }

    @ViewBuilder
    private func face(remaining: Int, total: Int, isRunning: Bool) -> some View {
        let isDone = isRunning && remaining == 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(CookClock.text(seconds: remaining))
                    // A text style and not a fixed point size: this is already
                    // the biggest thing on the screen and it still has to grow
                    // for someone who has turned Dynamic Type up.
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isDone ? Color.orange : tint)
                    .accessibilityLabel(
                        isDone ? "Time is up"
                               : "\(CookClock.spoken(seconds: remaining)) remaining"
                    )
                    .accessibilityAddTraits(isRunning ? .updatesFrequently : [])
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !sourceText.isEmpty {
                        Text(sourceText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if isDone {
                doneBand
            }

            HStack(spacing: 12) {
                if isDone {
                    control("Start it again", symbol: "arrow.counterclockwise", prominent: true) {
                        start(from: total)
                    }
                } else if isRunning {
                    control("Pause", symbol: "pause.fill", prominent: false) {
                        pause(at: remaining)
                    }
                } else {
                    control(startTitle, symbol: "play.fill", prominent: true) {
                        start(from: remaining)
                    }
                }
                // Only once it differs from where it began, and never beside
                // "Start it again", which already resets it: a button that
                // resets nothing, or two buttons for one outcome, is one more
                // thing to read on the screen that can least afford it.
                if !isDone, remaining != total || isRunning {
                    control("Reset", symbol: "gobackward", prominent: false) { reset() }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(isDone ? 0.18 : 0.10),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    /// Grey for a rest, orange for work. A rest is the one thing on this screen
    /// he is allowed to walk away from, and an orange clock on it reads as
    /// something to stand over -- the same decision `CookStepCard` makes for the
    /// badge above.
    private var tint: Color {
        step.readsAsPassiveRest ? Color.secondary : Color.orange
    }

    /// The authored label wins when the importer has written one. It does not
    /// write `timerLabel` for any of the eight bundled recipes today, so in
    /// practice this reads "Hands off" or "Timer".
    private var heading: String {
        if !step.timerLabel.isEmpty { return step.timerLabel }
        return step.readsAsPassiveRest ? "Hands off" : "Timer"
    }

    private var startTitle: String {
        if pausedRemaining != nil { return "Resume" }
        return step.readsAsPassiveRest ? "Start the rest" : "Start the timer"
    }

    /// Why the clock can disagree with the step text: the fixture's step 3 says
    /// "7 to 8 min" and this runs to 8, and a cook who read 7 would otherwise
    /// think the timer was wrong.
    private var sourceText: String {
        guard let duration = step.durationText else { return "" }
        if step.hasDurationRange { return "\(duration) \u{00B7} set to the longer end" }
        return duration
    }

    @ViewBuilder
    private var doneBand: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.fill")
                .font(.subheadline)
                .accessibilityHidden(true)
            Text(step.readsAsPassiveRest ? "That is the rest done" : "Time is up")
                .font(.headline)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
    }

    // MARK: - Controls

    /// 56 points, not 44. The guideline minimum is for a finger on a phone in
    /// your hand; this is a knuckle on a phone propped behind a pan.
    private func control(
        _ title: String,
        symbol: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.body.weight(.semibold))
            .frame(minHeight: 56)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.bordered)
        .tint(prominent ? Color.accentColor : Color.secondary)
    }

    // MARK: - Starting, pausing, resetting

    private func start(from remaining: Int) {
        let now = Date()
        startedAt = now
        endsAt = now.addingTimeInterval(TimeInterval(remaining))
        pausedRemaining = nil
    }

    /// The remaining time comes from the caller rather than being recomputed
    /// here: the timeline closure has just worked it out from `context.date`,
    /// and recomputing it against a second `Date()` would lose the fraction of a
    /// second between the two and silently shorten the step on every pause.
    private func pause(at remaining: Int) {
        pausedRemaining = remaining
        endsAt = nil
        startedAt = nil
    }

    private func reset() {
        endsAt = nil
        startedAt = nil
        pausedRemaining = nil
    }
}
