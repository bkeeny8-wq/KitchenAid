import SwiftUI

/// A reusable empty state: symbol, headline, one line of explanation, and an
/// optional action.
///
/// The `kind` is the whole reason this is a type rather than a `VStack` copied
/// four times. "Nothing here yet" and "something went wrong" look identical if
/// you only vary the words, and they are not the same message: the first is the
/// app working correctly on an empty store, the second is the one worth acting
/// on. An unreadable recipe file rendered in the same grey as an empty shopping
/// list is a defect he never sees.
///
/// It is NOT `UnbuiltFeatureView` (in `RootTabView`), which says a feature does
/// not exist yet. That distinction is worth keeping: an empty state on a screen
/// that was never built implies a working screen with no data in it.
struct EmptyStateView: View {
    enum Kind {
        /// The store is empty and that is fine. Nothing to fix.
        case nothingYet
        /// Something failed. Tinted, because it is the one worth a tap.
        case somethingWrong
    }

    let kind: Kind
    let symbol: String
    let headline: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        kind: Kind = .nothingYet,
        symbol: String,
        headline: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.symbol = symbol
        self.headline = headline
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(tint)
                // The symbol repeats the headline; it is decoration, and
                // announcing it is noise in front of the text that matters.
                .accessibilityHidden(true)
            Text(headline)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var tint: Color {
        switch kind {
        case .nothingYet: return .secondary
        case .somethingWrong: return .orange
        }
    }
}
