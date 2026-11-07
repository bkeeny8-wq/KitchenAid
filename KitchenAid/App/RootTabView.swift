import SwiftUI

struct RootTabView: View {
    @Environment(\.storeUnavailable) private var storeUnavailable
    @Environment(RecipeLoader.self) private var loader

    @State private var selection: AppTab = .today

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    screen(for: tab)
                        .safeAreaInset(edge: .top, spacing: 0) { banners }
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.symbol)
                }
                .accessibilityIdentifier(tab.identifier)
                .tag(tab)
            }
        }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .today:
            TodayView()
        case .recipes:
            RecipeListView()
        case .plan:
            UnbuiltFeatureView(
                title: "Plan",
                detail: "The calendar, who is eating each meal, and the scaling that "
                      + "follows from it. The data model for all of it is written; the "
                      + "screens are not."
            )
        case .shop:
            UnbuiltFeatureView(
                title: "Shop",
                detail: "A list built from the week's plan, merged across recipes, with "
                      + "what you already have subtracted. The arithmetic exists and is "
                      + "under test; this screen does not."
            )
        case .pantry:
            UnbuiltFeatureView(
                title: "Pantry",
                detail: "What the house has, as lots with dates and a transaction for "
                      + "every change. The ledger is written; this screen is not."
            )
        }
    }

    /// Two things the user must not have to discover for themselves: that this
    /// run is not saving anything, and that a recipe file could not be read.
    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if storeUnavailable {
                BannerView(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "Not saving",
                    detail: "The database could not be opened, so this run is in memory "
                          + "only. Your existing data is untouched."
                )
            }
            if loader.hasDiagnostics {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    BannerView(
                        symbol: "doc.badge.exclamationmark",
                        tint: .orange,
                        title: loader.diagnostics.count == 1
                            ? "1 recipe file has a problem"
                            : "\(loader.diagnostics.count) recipe files have problems",
                        detail: "Tap to see which, and what is wrong with them."
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct BannerView: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12))
    }
}

/// An honest placeholder.
///
/// It says what the tab will do and that it is not built, rather than showing an
/// empty state that implies a working feature with no data in it. The difference
/// matters when the person reading it is the one who will ask why their meal
/// plan is empty.
struct UnbuiltFeatureView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hammer")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Not built yet")
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }
}
