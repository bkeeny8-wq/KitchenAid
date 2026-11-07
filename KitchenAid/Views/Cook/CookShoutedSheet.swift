import SwiftUI

/// THE SHOUTS, before the first step.
///
/// `DO. NOT. SALT.` and `DO NOT USE SALTED BUTTER.` are the whole point of the
/// roast turkey: it, its butter and its gravy are all deliberately unsalted so
/// the cook salts once at the end. `CookView` shows this sheet once per visit,
/// before he has read step 1, because a shout is the kind of instruction that is
/// useless after the fact -- knowing the butter had to be unsalted does not help
/// once it is on the bird. The orange band it pins above every step afterwards
/// is one line each; this is where the full text lives.
///
/// The text is rendered VERBATIM. It is not sentence-cased, not re-wrapped and
/// not softened: the document shouted it, the importer was dropping both lines
/// entirely at one point, and deciding on his behalf that the capitals were
/// shouting rather than meaning is an editorial judgement this screen has no
/// business making.
///
/// Its own `NavigationStack`, for the reason given on `CookIngredientsSheet`:
/// `CookView` presents these bare.
struct CookShoutedSheet: View {

    let notes: [RecipeNote]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if notes.isEmpty {
                        EmptyStateView(
                            kind: .nothingYet,
                            symbol: "checkmark.seal",
                            headline: "Nothing to watch out for",
                            detail: "This recipe has no all-caps warnings in it."
                        )
                    } else {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            card(note)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Before you start")
            .navigationBarTitleDisplayMode(.inline)
            // The dismiss is a full-width button at the bottom and NOT a Done in
            // the navigation bar. The top-right corner of a sheet is the hardest
            // target on a phone held in one hand, and this is the one sheet he
            // will be dismissing with a knuckle before he has washed his hands.
            .safeAreaInset(edge: .bottom) { dismissBar }
        }
    }

    private func card(_ note: RecipeNote) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(note.text)
                .font(.title2.weight(.bold))
                // Long shouts wrap. Without this a three-word line gets a
                // scroll view's full width and the fourth word is truncated.
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var dismissBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                dismiss()
            } label: {
                Text(notes.isEmpty ? "Close" : "Got it")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}
