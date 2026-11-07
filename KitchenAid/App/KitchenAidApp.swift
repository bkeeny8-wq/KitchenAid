import SwiftUI
import SwiftData

@main
struct KitchenAidApp: App {

    /// Bundled content, loaded once at launch. Recipes are read-only at
    /// runtime: they arrive as files in the app, not as rows the user types.
    @State private var loader = RecipeLoader()
    @State private var catalog = IngredientCatalog()

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
                .environment(\.storeUnavailable, storeFailure != nil)
                .task {
                    guard !didLoadContent else { return }
                    didLoadContent = true
                    loader.load()
                    catalog.load()
                }
        }
        .modelContainer(container)
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
