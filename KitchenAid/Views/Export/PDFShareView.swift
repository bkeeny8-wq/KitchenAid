import SwiftUI

/// The share sheet's doorstep: the file that was just written, and the one control that hands
/// it to iOS.
///
/// It names the file and its size before he shares it, which is the cheap half of the promise
/// that a failure explains itself: a 2 KB "week plan" is visibly not a week plan, and he can
/// see that here rather than in somebody's inbox.
struct PDFShareView: View {
    let url: URL
    var fileLabel: String = "PDF"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(sizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ShareLink(item: url) {
                    Text("Share")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens the iOS share sheet for this PDF")
                Text("Printing, Files, Mail and Messages are all in the share sheet. The file "
                   + "is temporary: share it now, or export again later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle(fileLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Rounded to whole kilobytes and spelled by hand rather than through a formatter: this is
    /// a sanity check on a file, not a figure anybody adds up.
    private var sizeText: String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attributes?[.size] as? Int, bytes > 0 else {
            return "PDF"
        }
        if bytes < 1_024 { return "PDF \u{00B7} \(bytes) bytes" }
        return "PDF \u{00B7} \(bytes / 1_024) KB"
    }
}
