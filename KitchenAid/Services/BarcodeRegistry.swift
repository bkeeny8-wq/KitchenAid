import Foundation
import Observation
import SwiftData

/// What a scanned number turned out to mean.
enum BarcodeScan {
    /// Not a product code this app will remember: the wrong number of digits, or no digits at
    /// all. Nothing is stored, and the screen says so rather than asking him to name a number
    /// it could not read.
    case unreadable(digits: String)
    /// Never seen. **This is the case the whole feature turns on: ASK.** His answer becomes
    /// the row, and every later scan of this number fills itself in.
    case unknown(digits: String)
    /// Known, and the item it names is still here. Fill the sheet in.
    case known(item: FoodItem, barcode: FoodItemBarcode)
    /// The number is remembered but the `FoodItem` it named has been deleted or merged away.
    /// Ask once more; `BarcodeRegistry.remember` overwrites this same row, so the number is
    /// never asked about twice running.
    case forgotten(barcode: FoodItemBarcode)

    /// The normalized digits, or the raw ones when they could not be normalized.
    var digits: String {
        switch self {
        case .unreadable(let value): return value
        case .unknown(let value): return value
        case .known(_, let barcode): return barcode.matchKey
        case .forgotten(let barcode): return barcode.matchKey
        }
    }

    var item: FoodItem? {
        if case .known(let found, _) = self { return found }
        return nil
    }

    /// Whether the screen has to put a question on screen.
    var needsAnswer: Bool {
        switch self {
        case .unknown, .forgotten: return true
        case .known, .unreadable: return false
        }
    }
}

/// The barcode half of "the kitchen becomes its own database".
///
/// A barcode is only a number (`CLAUDE.md`). Turning one into "heavy cream" needs a commercial
/// product database, which means a subscription and a network call this app does not have —
/// so this service does not look anything up. It reads and writes one table of numbers HE
/// named, and that is the entire design. **There is no lookup client here, no cached product
/// payload and no placeholder for either**, because a design that assumes a service exists is
/// a feature that never works, and adding a real one later is additive.
///
/// **It never sees an image.** The input is a `String` of digits that the camera layer already
/// read off a frame and threw away. There is no image parameter and nothing in the schema that
/// could hold one, which is the only enforcement a later call site cannot bypass.
///
/// ## Why this is not an extension on `FoodItemResolver`
///
/// The brief allowed either. `FoodItemResolver`'s four-step lookup order is a documented
/// contract — his row, then his aliases, then the catalogue, then a bare row — and the comment
/// on it says the order is load-bearing. A barcode is not a fifth step in that order: it is a
/// different key arriving from a different place, and bolting it on would blur the one piece
/// of this codebase whose ordering is explicitly called out as the thing that keeps the pantry
/// matching the right purchase.
///
/// So this is its own service, and it HOLDS a resolver instead, because minting a `FoodItem`
/// stays the resolver's job: "nothing else may call `context.insert(FoodItem(...))`" is what
/// substitutes for the `@Attribute(.unique)` CloudKit forbids, and a second creation site
/// would quietly undo it.
///
/// Not `@MainActor`, and holding no context: same reasoning as `FoodItemResolver`. Every
/// method that writes takes the context explicitly, so a caller on a background task cannot
/// write through someone else's.
@Observable
final class BarcodeRegistry {

    private let resolver: FoodItemResolver

    init(resolver: FoodItemResolver) {
        self.resolver = resolver
    }

    // MARK: - Reading

    /// The stored row for a number, or nil. Read-only — nothing is touched.
    func find(_ raw: String, in context: ModelContext) throws -> FoodItemBarcode? {
        let key = FoodItemBarcode.normalize(raw)
        guard !key.isEmpty else { return nil }
        return try context.fetch(FoodItemBarcode.descriptor(forMatchKey: key)).first
    }

    /// The scan path: find the number, resolve its item, and record that the scan happened.
    ///
    /// It writes (`noteScan`) because a scan IS the event the row counts, and a separate
    /// "record that" call is a call a screen forgets. Nothing is saved here; the context's own
    /// autosave or the caller's save does that, as everywhere else in this app.
    func scan(
        _ raw: String,
        symbology: String = "",
        at date: Date = .now,
        in context: ModelContext
    ) throws -> BarcodeScan {
        let key = FoodItemBarcode.normalize(raw)
        guard !key.isEmpty else {
            return .unreadable(digits: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let row = try context.fetch(FoodItemBarcode.descriptor(forMatchKey: key)).first else {
            return .unknown(digits: key)
        }

        // Provenance only, and only when it was missing: a number first entered by hand and
        // later scanned gains the symbology the scanner reported. Nothing branches on it.
        if row.symbology.isEmpty, !symbology.isEmpty { row.symbology = symbology }
        row.noteScan(at: date)

        // `self.` on purpose: a local binding and a method of the same name in one statement is
        // exactly the kind of resolution nothing here can ask a compiler about.
        guard let owner = try self.item(for: row, in: context) else {
            return .forgotten(barcode: row)
        }
        // The snapshot is refreshed here rather than only at write time, so a row he renamed
        // in the pantry reads back under its current name in the barcode list.
        row.itemNameSnapshot = owner.displayName
        return .known(item: owner, barcode: row)
    }

    /// The `FoodItem` a row points at, or nil when it points at nothing or at something gone.
    ///
    /// A fetch rather than a relationship traversal, for the reason recorded on
    /// `FoodItemBarcode`: the owner is a stored key because a relationship here could not have
    /// the inverse CloudKit requires. It is a `#Predicate` on an indexed stored `UUID` with a
    /// fetch limit of one — the same shape `ShoppingListStore` uses to turn a draft line's id
    /// back into a row — not a scan of the store.
    func item(for barcode: FoodItemBarcode, in context: ModelContext) throws -> FoodItem? {
        guard let id = barcode.itemID else { return nil }
        var descriptor = FetchDescriptor<FoodItem>(predicate: #Predicate<FoodItem> { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Every number filed against one item, oldest first.
    ///
    /// Several is normal: the store brand and the name brand of the same cream cheese are two
    /// barcodes and one `FoodItem`, and so are the 8 oz and the 16 oz tub.
    func barcodes(of item: FoodItem, in context: ModelContext) throws -> [FoodItemBarcode] {
        let rows = try context.fetch(FoodItemBarcode.descriptor(forItemKey: item.id.uuidString))
        return rows.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Remembering

    /// **"Once, then remembers", for barcodes.** His answer to "what is this?" becomes the row.
    ///
    /// Overwrites an existing row for the same number rather than adding a second, so three
    /// things all work through one call: the first answer, a correction, and the re-answer
    /// after a `.forgotten`. There is no uniqueness constraint to lean on — `@Attribute`
    /// uniqueness is forbidden here because CloudKit-backed stores reject it — so this method
    /// being the only writer is what keeps one number to one row.
    ///
    /// Returns nil only when the digits are unreadable, which is the one case where nothing
    /// should be stored at all.
    @discardableResult
    func remember(
        _ raw: String,
        symbology: String = "",
        as item: FoodItem,
        at date: Date = .now,
        in context: ModelContext
    ) throws -> FoodItemBarcode? {
        let key = FoodItemBarcode.normalize(raw)
        guard !key.isEmpty else { return nil }

        if let existing = try context.fetch(FoodItemBarcode.descriptor(forMatchKey: key)).first {
            existing.attach(to: item)
            if existing.symbology.isEmpty, !symbology.isEmpty { existing.symbology = symbology }
            existing.lastScannedAt = date
            return existing
        }

        guard let row = FoodItemBarcode.make(
            digits: raw, symbology: symbology, item: item, at: date
        ) else { return nil }
        context.insert(row)
        return row
    }

    /// The same answer given as a catalogue pick rather than an existing row: mint the
    /// `FoodItem` from the template first, through the resolver, which is the only thing
    /// allowed to create one.
    @discardableResult
    func remember(
        _ raw: String,
        symbology: String = "",
        asCatalogEntry entry: CatalogEntry,
        at date: Date = .now,
        in context: ModelContext
    ) throws -> (item: FoodItem, barcode: FoodItemBarcode)? {
        guard !FoodItemBarcode.normalize(raw).isEmpty else { return nil }
        let item = try resolver.findOrCreate(fromCatalog: entry, in: context)
        guard let row = try remember(
            raw, symbology: symbology, as: item, at: date, in: context
        ) else { return nil }
        return (item: item, barcode: row)
    }

    /// He scanned the wrong thing, or stopped buying it. Deletes the row; the next scan of that
    /// number asks again.
    func forget(_ barcode: FoodItemBarcode, in context: ModelContext) {
        context.delete(barcode)
    }

    /// Moves every number from one item to another, and returns how many moved.
    ///
    /// **This is what a merge should call, and nothing calls it yet.** `FoodItemResolver.merge`
    /// repoints lots, transactions and shopping lines by walking the relationship arrays that
    /// declare an inverse on `FoodItem`; a barcode row has no such array (see
    /// `FoodItemBarcode` for why it cannot), so the merge cannot see these rows and does not
    /// move them. Until it calls this, a merged-away item's barcodes resolve to nothing, read
    /// as `.forgotten`, and he answers once — which is a question, not lost data, and is why
    /// the key was chosen over a relationship with no inverse.
    @discardableResult
    func repoint(from loser: FoodItem, to survivor: FoodItem, in context: ModelContext) throws -> Int {
        guard loser.id != survivor.id else { return 0 }
        let rows = try context.fetch(FoodItemBarcode.descriptor(forItemKey: loser.id.uuidString))
        for row in rows { row.attach(to: survivor) }
        return rows.count
    }
}
