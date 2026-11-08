import SwiftUI
import SwiftData

@main
struct KitchenAidApp: App {

    /// Bundled content, loaded once at launch. Recipes are read-only at
    /// runtime: they arrive as files in the app, not as rows the user types.
    @State private var loader = RecipeLoader()
    @State private var catalog = IngredientCatalog()

    /// Holds `lastDiff` across a regenerate, so the sheet that explains "3 new,
    /// 1 no longer needed" survives the sheet being dismissed and reopened.
    /// Plain `@Observable`, no actor isolation, so it is built here.
    @State private var shopping = ShoppingListStore()

    /// Both are `@MainActor`, so they cannot be built in `init()` — see
    /// `startServices()`. Optional until that runs, which is also how every
    /// view reads them: an `@Environment` lookup declared non-optional traps
    /// when the value is absent, and the window between first render and the
    /// launch task is real, if short.
    @State private var tweaks: TweakStore?
    @State private var ledger: InventoryLedger?

    /// True when the on-disk store could not be opened and the app is running
    /// against a temporary one, so the UI can say so instead of looking as if
    /// everything vanished.
    let container: ModelContainer
    let storeFailure: Error?

    init() {
        let schema = Schema.kitchenAidCurrent
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: UITestMode.isActive
        )
        do {
            container = try ModelContainer(for: schema, configurations: [config])
            storeFailure = nil
        } catch {
            // A migration the runtime declines to infer used to be a crash on
            // every launch in CFAL3, with the user's history locked inside a
            // store they could no longer even export. Fall back to an
            // in-memory container so the app opens and can explain itself; the
            // file on disk is left untouched and stays recoverable.
            storeFailure = error
            container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
    }

    /// Guarded here rather than inside the services, so that neither has to
    /// carry an `isLoaded` flag for the App's benefit. `.task` can run again
    /// when the scene reappears, and reloading eight files on every return from
    /// the background is waste nobody asked for.
    @State private var didLoadContent = false

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(loader)
                .environment(catalog)
                .environment(shopping)
                .environment(tweaks)
                .environment(ledger)
                .environment(\.storeUnavailable, storeFailure != nil)
                .task {
                    guard !didLoadContent else { return }
                    didLoadContent = true
                    await startServices()
                }
        }
        .modelContainer(container)
    }

    /// Content first, then the services that read it, then the one-time rows.
    ///
    /// The order is load-bearing twice over. `TweakStore` is handed the loader
    /// it will resolve recipe ids against, and `KitchenAidSeed` reads the aisle
    /// walk order out of the catalogue to build the store's sections — which is
    /// why the seed deliberately holds no copy of that list, and why it cannot
    /// run before `catalog.load()`.
    ///
    /// `@MainActor` rather than inline in `.task`, because that closure is
    /// `@Sendable` and so not main-actor isolated, and both services are. A
    /// method with the isolation stated is clearer than a `MainActor.run` block
    /// wrapped round the same four lines.
    @MainActor
    private func startServices() {
        loader.load()
        catalog.load()

        tweaks = TweakStore(container: container, loader: loader)
        ledger = InventoryLedger(container: container)

        // Repairs `FoodItem.aliasBlob` from the alias ROWS, which are the truth. A CloudKit
        // merge of two devices that each added an alias can leave the blob disagreeing with
        // them, and then the alias `#Predicate` stops finding a row that plainly has the
        // alias -- a lookup failure with no visible cause and nothing on screen to explain
        // it. Idempotent, cheap, and it rewrites only rows that actually differ.
        //
        // This is the half of the old `FoodItemResolver.reconcile` worth running unattended.
        // The other half merged duplicate items without being asked, which is exactly what
        // must not happen on a launch task: `MergeDuplicatesView` shows him a group and
        // waits. `try?` for the same reason as the seed below.
        try? FoodItemResolver(catalog: catalog).repairAliasIndex(in: container.mainContext)

        // `try?` on purpose: a failed seed must not stop the app from opening.
        // This runs on a device that may already be in the in-memory fallback
        // above, where a write failing is expected rather than exceptional, and
        // every screen it feeds has an empty state that says what is missing.
        // The seed is itself gated by a `SeedRecord` per key, so a run that
        // half-succeeded is retried on the next launch rather than doubled.
        try? KitchenAidSeed.applyIfNeeded(in: container.mainContext, catalog: catalog)
    }
}

// MARK: - Store availability

private struct StoreUnavailableKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the real store could not be opened and this run is in memory.
    /// A screen that lets the user write something should say so, because work
    /// done now will not survive the app closing.
    var storeUnavailable: Bool {
        get { self[StoreUnavailableKey.self] }
        set { self[StoreUnavailableKey.self] = newValue }
    }
}
