import Foundation

/// The app's tabs.
///
/// Five, and the count is written once here so nothing can claim six. The spec
/// said "6 tabs" in two places while listing four, which is the kind of
/// disagreement that survives three reviews because nobody counts.
///
/// `Today` is first because Brandon chose it: what is planned for today with a
/// Cook button, falling back to recent recipes when the plan is empty. Not the
/// library, not the week.
enum AppTab: String, CaseIterable, Identifiable {
    case today
    case recipes
    case plan
    case shop
    case pantry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .recipes: return "Recipes"
        case .plan: return "Plan"
        case .shop: return "Shop"
        case .pantry: return "Pantry"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "sun.horizon"
        case .recipes: return "book.closed"
        case .plan: return "calendar"
        case .shop: return "cart"
        case .pantry: return "archivebox"
        }
    }

    /// A stable string for UI tests to address the tab by, so a test does not
    /// break when a label is reworded.
    var identifier: String { "tab.\(rawValue)" }
}
