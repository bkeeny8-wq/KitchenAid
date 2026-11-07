import SwiftUI
import SwiftData

/// Export, anywhere it is offered. One control, one job, one rendered file.
///
/// **Sharing is `ShareLink` and only `ShareLink`**, because he chose the share sheet: there is
/// no mail API, no upload and no key anywhere in this app. `PDFExportService.render` writes a
/// file into the temporary directory and returns its URL, which is exactly what `ShareLink`
/// takes.
///
/// So this is a button and then a sheet, rather than a `ShareLink` on its own, and that is not
/// an accident of structure: a `ShareLink` needs its item **at construction**, so offering one
/// up front means either rendering a PDF nobody asked for every time this screen draws, or
/// handing the share sheet a URL that is not a file yet. One tap to render, then the share
/// sheet over something that demonstrably exists.
///
/// A failure explains itself and shares nothing. The alternative — the share sheet holding a
/// zero-byte PDF — is worse than an error, because it looks like it worked.
struct PDFExportButton: View {
    let job: PDFExportService.Job
    /// What to call the thing in the button's accessibility label, e.g. "Nov 3-9".
    var fileLabel: String = "PDF"
    /// Set for a full-width row in a `List`; left nil for the icon-only toolbar button. Both
    /// carry the same accessibility label, so the icon is never the only thing naming it.
    var title: String? = nil

    @Environment(RecipeLoader.self) private var loader
    @Environment(TweakStore.self) private var tweaks: TweakStore?
    @Environment(\.modelContext) private var context

    @State private var rendered: URL? = nil
    @State private var failure: String? = nil
    @State private var isSharing = false
    @State private var isFailing = false

    var body: some View {
        Button {
            render()
        } label: {
            if let title = title {
                Label(title, systemImage: "square.and.arrow.up")
                    .frame(minHeight: 44)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityLabel("Export \(fileLabel) as a PDF")
        .accessibilityHint("Renders a PDF and opens the share sheet")
        .sheet(isPresented: $isSharing) {
            if let url = rendered {
                PDFShareView(url: url, fileLabel: fileLabel)
            }
        }
        .alert("Could not make the PDF", isPresented: $isFailing) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(failure ?? "Something went wrong and the file was not written.")
        }
    }

    /// Synchronous on purpose. `PDFExportService.render` is a main-actor function that
    /// measures and writes every page in one pass, and wrapping it in a `Task` would not make
    /// it faster — it would move the same work off the frame that is already committed to
    /// waiting for it, and hand back a sheet with nothing in it. Eight recipes and a week grid
    /// is three pages.
    @MainActor
    private func render() {
        do {
            // `TweakStore` holds no state of its own, so standing one up when the environment
            // has none is cheap and cannot disagree with an injected one -- the same fallback
            // `CookView` uses. It matters here: the recipe card prints the EFFECTIVE recipe,
            // so without the overlay the sheet taped to the cupboard door would print the
            // bundled text and silently disagree with what he actually does.
            let store = tweaks ?? TweakStore(container: context.container, loader: loader)
            rendered = try PDFExportService.render(
                job, loader: loader, tweaks: store, context: context
            )
            failure = nil
            isSharing = true
        } catch {
            // `ExportError` is a `LocalizedError` with a sentence per case, so this is his
            // message and not a type name: "That shopping list is no longer in the app."
            rendered = nil
            failure = error.localizedDescription
            isFailing = true
        }
    }
}
