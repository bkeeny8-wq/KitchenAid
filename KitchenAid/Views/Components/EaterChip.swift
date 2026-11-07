import SwiftUI
import SwiftData

/// One household member, as a chip.
///
/// The attendance grid is four taps for a four-person dinner and no sheet
/// (`MealAttendance.cycleStatus`), so the chip has to carry the whole state on
/// 44 points: who, whether they are eating, and whether they are a half
/// portion. The day cells show the same chip without an action.
///
/// It takes VALUES and not a row, because it is built from two different
/// things: a `MealAttendance` once the meal exists, and a bare `Eater` while
/// attendance is still being assembled. The convenience initializers below are
/// the only places that know which.
struct EaterChip: View {
    let initials: String
    let name: String
    let status: AttendanceStatus
    let isHalfPortion: Bool
    let colorIndex: Int
    let action: (() -> Void)?

    init(
        initials: String,
        name: String,
        status: AttendanceStatus = .attending,
        isHalfPortion: Bool = false,
        colorIndex: Int = 0,
        action: (() -> Void)? = nil
    ) {
        self.initials = initials
        self.name = name
        self.status = status
        self.isHalfPortion = isHalfPortion
        self.colorIndex = colorIndex
        self.action = action
    }

    /// Reads `effectivePortion`, not `eater?.portion`: changing someone to a
    /// half portion today must not restate what last month's dinners were
    /// cooked for, and the row's snapshot is what says so.
    init(attendance: MealAttendance, action: (() -> Void)? = nil) {
        self.initials = attendance.initials
        self.name = attendance.displayName
        self.status = attendance.status
        self.isHalfPortion = attendance.effectivePortion == Rational(1, 2)
        self.colorIndex = attendance.eater?.colorIndex ?? 0
        self.action = action
    }

    init(eater: Eater, status: AttendanceStatus = .attending, action: (() -> Void)? = nil) {
        self.initials = eater.initials
        self.name = eater.displayName
        self.status = status
        self.isHalfPortion = eater.isHalfPortion
        self.colorIndex = eater.colorIndex
        self.action = action
    }

    var body: some View {
        if let action = action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .accessibilityLabel(spokenState)
                .accessibilityHint("Changes whether they are eating")
        } else {
            chip
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenState)
        }
    }

    private var chip: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(shortInitials)
                .font(.caption.weight(.bold))
                .foregroundStyle(isEating ? Color.white : Color.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(isEating ? tint : Color.secondary.opacity(0.14)))
                .overlay {
                    Circle().strokeBorder(
                        tint.opacity(isEating ? 0.0 : 0.45), lineWidth: 1.5
                    )
                }
            badge
        }
        // 44 points even though the circle is 34: the grid is tapped repeatedly
        // and at speed, and a 34-point target is a mis-tap that silently
        // changes the wrong person's attendance.
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    /// Status wins over the half-portion mark. A half portion for someone who
    /// is not eating is not a fact worth 16 points, and showing both badges on
    /// one chip made the away mark unreadable.
    @ViewBuilder
    private var badge: some View {
        if let symbol = AttendanceStatusStyle.symbol(status) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.secondary))
        } else if isHalfPortion {
            Text("\u{00BD}")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(tint))
        }
    }

    private var isEating: Bool { AttendanceStatusStyle.consumesPortion(status) }

    private var tint: Color { EaterPalette.color(for: colorIndex) }

    private var shortInitials: String {
        let trimmed = initials.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(2))
    }

    private var spokenState: String {
        var spoken = "\(name), \(AttendanceStatusStyle.title(status))"
        if isHalfPortion && isEating { spoken += ", half portion" }
        return spoken
    }
}

/// Presentation for `AttendanceStatus`, deliberately NOT an extension on the
/// enum. The model layer is frozen and carries no display strings, and a second
/// workflow is writing beside this one — a `title` added to the enum from two
/// places is a redeclaration, which is a build error nothing here can catch.
enum AttendanceStatusStyle {
    static func title(_ status: AttendanceStatus) -> String {
        switch status {
        case .attending: return "eating"
        case .away: return "not eating"
        case .maybe: return "maybe"
        case .leftoversOnly: return "leftovers only"
        }
    }

    /// nil for `.attending`, which is the unmarked, ordinary case: a badge on
    /// every chip in the grid marks nothing.
    static func symbol(_ status: AttendanceStatus) -> String? {
        switch status {
        case .attending: return nil
        case .away: return "xmark"
        case .maybe: return "questionmark"
        case .leftoversOnly: return "arrow.uturn.down"
        }
    }

    /// Mirrors `MealAttendance.consumesPortion`. A `.maybe` deliberately does
    /// NOT count — buying for a maybe every week is how a plan drifts into
    /// over-buying — and the chip must look the same way the arithmetic
    /// behaves, or the grid and the shopping list disagree on screen.
    static func consumesPortion(_ status: AttendanceStatus) -> Bool {
        status == .attending || status == .leftoversOnly
    }
}

/// `Eater.colorIndex` is a stored `Int` with no palette beside it, so one lives
/// here. Indexes wrap rather than clamp: the roster is addable at will and an
/// eleventh person must get a colour, not the same colour as the tenth.
enum EaterPalette {
    static let colors: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown
    ]

    static func color(for index: Int) -> Color {
        guard !colors.isEmpty else { return .accentColor }
        let wrapped = ((index % colors.count) + colors.count) % colors.count
        return colors[wrapped]
    }
}
