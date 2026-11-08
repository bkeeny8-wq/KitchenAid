import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.storeUnavailable) private var storeUnavailable
    @Environment(RecipeLoader.self) private var loader
    /// Optional, like every other lookup of it: the App injects it in the launch task.
    @Environment(TweakStore.self) private var tweaks: TweakStore?

    /// Lapsed tweaks, counted once rather than on every body evaluation.
    ///
    /// `TweakStore.lapseReport()` fetches every tweak and re-resolves every recipe it
    /// names, which is the right cost for a screen you open and the wrong one for a
    /// banner that is on screen the whole time the app is. `.task(id:)` below recomputes
    /// it when the number of tweak rows changes, and a LAPSE itself can only appear when
    /// the bundled content changes -- which, recipes being compiled-in files, means a new
    /// build and therefore a fresh launch.
    @State private var lapsedCount = 0

    /// Read only to drive the recount above. A `@Query` SwiftData never reads is a query
    /// it never subscribes to, so this must stay used.
    @Query private var tweakRows: [RecipeTweak]

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
        .task(id: tweakRows.count) { recountLapses() }
    }

    @MainActor
    private func recountLapses() {
        // A `.missing` report counts as ONE whether or not it carries individual lapses:
        // the whole recipe file is gone, `DiagnosticsView` renders it as a single row
        // ("handled WHOLE -- one row, no list of lines"), and counting its empty `lapses`
        // array as zero would leave the banner down on the worst case of the three.
        lapsedCount = (tweaks?.lapseReport() ?? []).reduce(0) { total, report in
            total + (report.status == .missing ? 1 : report.lapses.count)
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
            PlanWeekView()
        case .shop:
            ShopView()
        case .pantry:
            PantryView()
        }
    }

    private var warnedCount: Int {
        loader.allIncludingArchived.reduce(0) { $0 + ($1.warnings.isEmpty ? 0 : 1) }
    }

    private var bannerTitle: String {
        let broken = loader.diagnostics.count
        if broken > 0 && warnedCount > 0 {
            return "\(broken) recipe file\(broken == 1 ? "" : "s") unreadable, "
                 + "\(warnedCount) with warnings"
        }
        if broken > 0 {
            return broken == 1 ? "1 recipe file could not be read"
                               : "\(broken) recipe files could not be read"
        }
        if warnedCount > 0 {
            return warnedCount == 1 ? "1 recipe has a warning"
                                    : "\(warnedCount) recipes have warnings"
        }
        // The third kind, and the only one that is about HIM rather than about a file:
        // his own tweak no longer matches the recipe it was made against.
        return lapsedCount == 1 ? "1 of your tweaks no longer fits its recipe"
                                : "\(lapsedCount) of your tweaks no longer fit their recipes"
    }

    /// Two things the user must not have to discover for themselves: that this
    /// run is not saving anything, and that something is wrong with a recipe.
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
            // Two different things, one banner, because to the person holding
            // the phone they are the same question: is anything wrong with my
            // recipes? A diagnostic means a file could not be used at all; a
            // warning means it loaded but the importer could not work something
            // out, which surfaces later as a quantity that will not scale.
            // `lapsedCount` is in this condition because `DiagnosticsView` is
            // constructed HERE and nowhere else, so this gate is the only way to reach
            // the lapsed-tweak section on it -- and a lapse opens neither of the other
            // two conditions. It resolved by luck until now: 6 of the 8 bundled recipes
            // still carry importer warnings, so the banner happened to be up. Clearing
            // those is active work, and a re-import is the very event that BOTH clears a
            // warning and causes a lapse, so the luck would have run out in the one
            // moment the screen was needed. `RecipeDetailView`'s lapse notice also tells
            // him to reach it "from the orange banner at the top of any tab", which would
            // have become a false instruction.
            if loader.hasDiagnostics || warnedCount > 0 || lapsedCount > 0 {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    BannerView(
                        symbol: "doc.badge.exclamationmark",
                        tint: .orange,
                        title: bannerTitle,
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
