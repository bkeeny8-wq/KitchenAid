import Foundation

/// UI tests need a known starting state on every run.
///
/// Under this flag the app keeps its store in memory and reads preferences from
/// a throwaway suite, so a test never inherits a previous run's data and never
/// touches the real device's.
///
/// Lifted from CFAL3, including the bug its comments record: `defaults` is a
/// `static let` and not a computed property, because as a computed property it
/// wiped the suite on EVERY access and anything written between two reads was
/// silently thrown away.
enum UITestMode {
    static let launchArgument = "-uitesting"

    /// Keeps the throwaway suite from being wiped on launch, so a test can
    /// relaunch the app and check that something was actually remembered.
    /// Without it there is no way to tell a preference that persisted from one
    /// that was simply re-derived.
    static let preserveDefaultsArgument = "-uitesting-preserve-defaults"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    private static var preservesDefaults: Bool {
        ProcessInfo.processInfo.arguments.contains(preserveDefaultsArgument)
    }

    private static let suiteName = "com.brandonkeeny.KitchenAid.uitests"

    /// `let`, not `var`, and the distinction is load-bearing — see the type's
    /// note. Everything that persists anything must read it from here rather
    /// than reach for `.standard`, or it survives across launches and one test
    /// inherits the last one's state.
    static let defaults: UserDefaults = {
        guard isActive, let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        if !preservesDefaults {
            suite.removePersistentDomain(forName: suiteName)
        }
        return suite
    }()
}
