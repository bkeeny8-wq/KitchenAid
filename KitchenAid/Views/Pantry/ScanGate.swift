import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Everything that has to be true before a camera is worth showing, and the right sentence for
/// each way it is not.
///
/// Both scanning flows wrap themselves in this, so neither has its own copy of the permission
/// ladder. The states are `ScanReadiness`'s, and the reason they are not collapsed into one
/// "cannot scan" message is that the next step differs every time: a denied camera needs
/// Settings, an unasked one needs the ask, an unsupported device needs the truth, and a busy
/// camera needs another go. `CLAUDE.md` keeps the honest placeholder where it is still true,
/// and "this iPad has no scanner" is still true.
///
/// `EmptyStateView`'s two kinds carry the distinction: `.nothingYet` for a device that simply
/// cannot (nothing is broken, nothing to fix), `.somethingWrong` for the cases with a fix.
struct ScanGate<Content: View>: View {

    let subject: ScanSubject

    /// The way through when the camera is not available at all. Only the barcode flow has one
    /// -- typing twelve digits is a real alternative to scanning them, and `FoodItemBarcode`
    /// already expects hand-entered numbers (its `symbology` is filled in later by the first
    /// real scan). There is deliberately no equivalent for a receipt: nobody types a receipt.
    let manualTitle: String?
    let onManual: (() -> Void)?

    private let content: () -> Content

    init(
        subject: ScanSubject,
        manualTitle: String? = nil,
        onManual: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.subject = subject
        self.manualTitle = manualTitle
        self.onManual = onManual
        self.content = content
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Starts as `.undecided` and is probed on appear. Not computed: `probe()` reads the
    /// authorization status and two VisionKit statics, and a computed property would re-read
    /// them on every body evaluation while the camera is on screen.
    @State private var readiness: ScanReadiness = .undecided
    @State private var isAsking = false

    var body: some View {
        Group {
            switch readiness {
            case .ready:
                content()
            case .undecided:
                askState
            case .denied:
                deniedState
            case .restricted:
                restrictedState
            case .cameraBusy:
                busyState
            case .unsupportedDevice:
                unsupportedState
            }
        }
        .onAppear { readiness = ScanReadiness.probe() }
        // He leaves for Settings, switches the camera on, and comes back. Without this the
        // screen still says it was denied, and the only way out is to leave and return --
        // which reads as the permission not having worked.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { readiness = ScanReadiness.probe() }
        }
    }

    // MARK: - The ask

    private var askState: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                kind: .nothingYet,
                symbol: subject == .barcode ? "barcode.viewfinder" : "doc.text.viewfinder",
                headline: "This needs the camera",
                detail: detailForAsk,
                actionTitle: isAsking ? "Asking\u{2026}" : "Allow the camera",
                action: { ask() }
            )
            manualRoute
        }
        .frame(maxHeight: .infinity)
    }

    private var detailForAsk: String {
        switch subject {
        case .receiptText:
            return "The receipt is read on this device and nothing is sent anywhere. No "
                 + "picture is kept \u{2014} the text comes off the frame and the frame goes."
        case .barcode:
            return "The number is read on this device. No picture is kept, and nothing is "
                 + "looked up on the internet: a barcode means whatever you say it means."
        }
    }

    private func ask() {
        guard !isAsking else { return }
        isAsking = true
        AVCaptureDevice.requestAccess(for: .video) { granted in
            // The completion arrives on an arbitrary queue, and these two are `@State`. The
            // hop is what keeps a SwiftUI write on the main actor; re-probing rather than
            // trusting `granted` also catches the case where permission is given and the
            // camera is then unavailable for a different reason.
            Task { @MainActor in
                isAsking = false
                readiness = granted ? ScanReadiness.probe() : .denied
            }
        }
    }

    // MARK: - The four ways it cannot

    private var deniedState: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                kind: .somethingWrong,
                symbol: "video.slash",
                headline: "The camera is turned off for this app",
                // The app cannot ask again once it has been refused -- iOS only shows that
                // prompt once -- so a button that re-asks would do nothing, which is worse
                // than a sentence saying where the switch is.
                detail: "iOS only asks once, so this has to be switched back on in Settings "
                      + "\u{2014} Privacy, then Camera, then KitchenAid. Nothing else in the "
                      + "app needs it.",
                actionTitle: "Open Settings",
                action: { openSettings() }
            )
            manualRoute
        }
        .frame(maxHeight: .infinity)
    }

    private var restrictedState: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                kind: .somethingWrong,
                symbol: "lock.shield",
                headline: "The camera is restricted on this device",
                // No Settings button: a Screen Time or profile restriction is not something
                // the camera pane can turn back on, and sending him there would be a dead end.
                detail: "Something outside this app is blocking it \u{2014} Screen Time, or a "
                      + "configuration profile. KitchenAid cannot turn that back on."
            )
            manualRoute
        }
        .frame(maxHeight: .infinity)
    }

    private var busyState: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                kind: .somethingWrong,
                symbol: "camera.badge.ellipsis",
                headline: "The camera is not free right now",
                detail: "Another app or a call has it. Close that and try again.",
                actionTitle: "Try again",
                action: { readiness = ScanReadiness.probe() }
            )
            manualRoute
        }
        .frame(maxHeight: .infinity)
    }

    private var unsupportedState: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                kind: .nothingYet,
                symbol: "iphone.slash",
                headline: "This device cannot scan",
                // `.nothingYet` and not `.somethingWrong`: nothing is broken. It is also the
                // state the simulator is always in, which is worth knowing before anyone
                // reports the screen as empty.
                detail: "Live scanning needs a camera and the hardware behind it, which this "
                      + "device does not have \u{2014} the simulator never does either. "
                      + "Everything else in the pantry works the same."
            )
            manualRoute
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var manualRoute: some View {
        if let title = manualTitle, let onManual = onManual {
            Button(title) { onManual() }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
