import Foundation
import Observation
import SwiftData

/// One receipt line, read and resolved as far as it can be without asking him.
///
/// A struct rather than an enum of outcomes, because a screen needs all of it at once: what
/// the line said, what it probably means, how sure that is, and what to put in the quantity
/// field. The computed properties below are the decision, so no two screens can reach
/// different conclusions from the same row.
struct ReceiptResolution {

    /// What the line was read as. Always present, even for a line that is not an item.
    var reading: ReceiptTokenMatcher.Reading

    /// His kitchen already knows this token — his own `FoodItem`, or one of his aliases,
    /// which is what a receipt token he answered once becomes. No question to ask.
    var item: FoodItem? = nil

    /// The catalogue's answer. `candidates` is empty when nothing came close.
    var match: ReceiptTokenMatcher.Match

    /// The size printed on the line, resolved against whichever food this turned out to be —
    /// weight ounces for cream cheese, fluid ounces for milk, from the same `8Z`. nil when the
    /// line wrote no size, which is never the same thing as one.
    var size: Quantity? = nil

    var rejection: ReceiptTokenMatcher.Rejection? { reading.rejection }

    /// A line to skip, with a reason to show.
    var isItemLine: Bool { reading.isItemLine }

    /// The screen has to ask. Either nothing matched, or what matched is not clear enough to
    /// assume — and a confident wrong answer puts the wrong food in his pantry, which he finds
    /// out about in a supermarket.
    var needsAnswer: Bool { isItemLine && item == nil && !match.isConfident }

    /// What to pre-fill when no question is needed. nil whenever `needsAnswer` is true, so the
    /// two cannot both be acted on.
    var proposal: CatalogEntry? {
        guard isItemLine, item == nil, match.isConfident else { return nil }
        return match.best?.entry
    }

    /// What to show as the line's name before he has answered.
    var displayName: String {
        if let item = item { return item.displayName }
        if let entry = proposal { return entry.name }
        return reading.nameDisplay
    }
}

/// The receipt half of "the kitchen becomes its own database": read a line, resolve it against
/// what he already has, and remember his answer so the next receipt does not ask again.
///
/// It owns no logic of its own beyond the ORDER below, which is the whole point of the file.
/// `ReceiptTokenMatcher` does the string work and can be tested; `FoodItemResolver` owns rows
/// and aliases; this composes them. **No image, ever**: the input is text the recognizer
/// already produced from a frame nothing kept.
///
/// ## The lookup order, and why it is this way round
///
/// 1. **His own `FoodItem.matchKey`** — a `#Predicate`, limit 1.
/// 2. **His own aliases**, through `FoodItem.aliasBlob` — also a `#Predicate`. **This rung is
///    what makes the promise true.** A receipt token he resolved by hand became a
///    `FoodItemAlias` row (see `learn` below), its key went into the blob, and this is the
///    step that finds it. Without it, "once, then remembers" is a sentence in a design
///    document: the catalogue in step 3 knows nothing about `CRM CHS`, and never will,
///    because the catalogue is generated from a Python script and his receipts are not.
/// 3. **The catalogue, exactly** — `IngredientCatalog.entry(matching:)`, name then shipped
///    alias. Unambiguous by construction; the build script fails on a collision.
/// 4. **The catalogue, abbreviated** — the consonant-skeleton and subsequence work in
///    `ReceiptTokenMatcher`, which returns several candidates when it is genuinely torn.
///
/// An alias must never win over a canonical name, for the reason `FoodItemResolver` records on
/// its own version of this order: one row's synonym capturing another row's identity makes the
/// pantry match the wrong purchase with nothing on screen saying so. HIS rows win over the
/// catalogue because the catalogue is a template and his row is the thing in the house.
///
/// ## Why it does not just call `FoodItemResolver.findOrCreate`
///
/// Because that mints. `findOrCreate(name:createIfMissing: false, in:)` still inserts a
/// `FoodItem` when the name hits the catalogue — the `createIfMissing` guard sits after the
/// catalogue step, by design, since for an ingredient line minting is the right answer. For a
/// receipt it is not: a forty-line receipt would leave forty rows in his pantry before he had
/// agreed to any of them, and thirty-nine of them if he cancelled. So steps 1 and 2 use
/// `FoodItem`'s own descriptors directly and nothing is created until `learn` is called with
/// his answer.
@Observable
final class ReceiptIntake {

    private let resolver: FoodItemResolver
    private let matcher: ReceiptTokenMatcher

    /// `entries` is `IngredientCatalog.all` in the app and a hand-built array in the tests,
    /// which is the only reason the tests can run at all: the real catalogue needs a bundle.
    init(
        resolver: FoodItemResolver,
        entries: [CatalogEntry],
        exactLookup: ((String) -> CatalogEntry?)? = nil
    ) {
        self.resolver = resolver
        self.matcher = ReceiptTokenMatcher(entries: entries, exactLookup: exactLookup)
    }

    /// The app's spelling. A factory rather than a `convenience init`, for the reason
    /// `FoodItemAlias.make` gives: nothing here can compile a macro-annotated class to find out
    /// how the macro treats a second initializer.
    ///
    /// The matcher's index is built once, here, over about 1,300 names and aliases. **Hold the
    /// result for the length of a scan** — rebuilding it per line is forty times the work for
    /// no gain.
    static func make(resolver: FoodItemResolver, catalog: IngredientCatalog) -> ReceiptIntake {
        ReceiptIntake(
            resolver: resolver,
            entries: catalog.all,
            exactLookup: { name in catalog.entry(matching: name) }
        )
    }

    // MARK: - Reading

    func read(_ line: String) -> ReceiptTokenMatcher.Reading {
        ReceiptTokenMatcher.read(line)
    }

    /// A whole recognized receipt, one reading per line, in the order they were printed.
    ///
    /// Order is kept including the rejected lines, because a `2 @ 3.50` reading only means
    /// anything next to the line above it, and throwing the rejects away here would take that
    /// possibility off the table for good.
    func read(receiptText text: String) -> [ReceiptTokenMatcher.Reading] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ReceiptTokenMatcher.read(String($0)) }
    }

    // MARK: - Resolving

    func resolve(_ reading: ReceiptTokenMatcher.Reading, in context: ModelContext) throws -> ReceiptResolution {
        guard reading.isItemLine, !reading.nameKey.isEmpty else {
            return ReceiptResolution(reading: reading, match: ReceiptTokenMatcher.Match(reading: reading))
        }

        // 1 and 2: his kitchen first. Both are `#Predicate` fetches with a limit of one, which
        // is the entire reason `matchKey` and `aliasBlob` are stored rather than computed.
        if let hit = try context.fetch(FoodItem.descriptor(forMatchKey: reading.nameKey)).first {
            return ReceiptResolution(
                reading: reading,
                item: hit,
                match: ReceiptTokenMatcher.Match(reading: reading),
                size: reading.size(preferring: hit.preferredDimension)
            )
        }
        if let hit = try context.fetch(FoodItem.descriptor(forAliasKey: reading.nameKey)).first {
            return ReceiptResolution(
                reading: reading,
                item: hit,
                match: ReceiptTokenMatcher.Match(reading: reading),
                size: reading.size(preferring: hit.preferredDimension)
            )
        }

        // 3 and 4: the catalogue, exactly and then abbreviated.
        let match = ReceiptTokenMatcher.Match(
            reading: reading,
            candidates: matcher.candidates(for: reading)
        )
        return ReceiptResolution(reading: reading, match: match, size: match.best?.size)
    }

    /// Read and resolve a whole receipt in one pass, in printed order.
    func resolve(receiptText text: String, in context: ModelContext) throws -> [ReceiptResolution] {
        var out: [ReceiptResolution] = []
        for reading in read(receiptText: text) {
            out.append(try resolve(reading, in: context))
        }
        return out
    }

    // MARK: - "Once, then remembers"

    /// **The mechanism, and it already existed.** A receipt token he resolved by hand becomes a
    /// `FoodItemAlias` on the item, so the next receipt matches it at step 2 with no question.
    ///
    /// `FoodItemResolver.addAlias(_:to:in:)` is that writer, and before this file its only
    /// caller was the "same as…" button on an unresolved shopping line. There is deliberately
    /// no second remembering mechanism here — no table of receipt tokens, no learned-spellings
    /// store. A second one would be a second thing that can disagree about what `CRM CHS`
    /// means, and the alias table already merges correctly under CloudKit (rows, not a stored
    /// array) and already survives a merge of two items.
    ///
    /// The stored text is `nameDisplay` — the receipt's own words, `CRM CHS`, in the case it
    /// printed them — because `FoodItemAlias.text` is read back to him verbatim in that list,
    /// and "your receipt calls this CRM CHS" is a sentence that explains itself.
    ///
    /// Returns whether anything was actually learned. The guards repeat `addAlias`'s own,
    /// which returns nothing, so that a screen can say "remembered" truthfully instead of
    /// hopefully.
    @discardableResult
    func learn(
        _ reading: ReceiptTokenMatcher.Reading,
        as item: FoodItem,
        in context: ModelContext
    ) -> Bool {
        let token = reading.nameDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        let key = NameNormalizer.matchKey(token)
        // Nothing to remember when the receipt already writes the item's own name: the token
        // resolves at step 1 for ever, and an alias equal to the identity is a row that can
        // only confuse the merge pass.
        guard !key.isEmpty, key != item.matchKey else { return false }
        guard !item.orderedAliases.contains(where: { $0.matchKey == key }) else { return false }
        resolver.addAlias(token, to: item, in: context)
        return true
    }

    /// His answer given as a catalogue pick: mint the row through the resolver — the only thing
    /// allowed to create a `FoodItem` — and then remember the token against it.
    @discardableResult
    func learn(
        _ reading: ReceiptTokenMatcher.Reading,
        asCatalogEntry entry: CatalogEntry,
        in context: ModelContext
    ) throws -> FoodItem {
        let item = try resolver.findOrCreate(fromCatalog: entry, in: context)
        learn(reading, as: item, in: context)
        return item
    }
}
