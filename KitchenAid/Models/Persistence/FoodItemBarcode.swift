import Foundation
import SwiftData

/// One barcode HE told the app about. A ROW, and the whole of what the kitchen knows about a
/// number.
///
/// A barcode is only a number. Turning `0012345678905` into "heavy cream" needs a commercial
/// product database, which means a subscription and a network call this app does not have
/// (`CLAUDE.md`). So nothing here looks anything up: the first scan of an item ASKS what it
/// is, that answer becomes this row, and every later scan of the same number fills itself in.
/// The kitchen becomes its own database. There is deliberately no product-payload field, no
/// "fetched at" date and no placeholder for a service — designing around a lookup that does
/// not exist is how a feature ships that never works, and adding one later is additive.
///
/// **No image is stored, here or anywhere.** This row holds digits and nothing else: there is
/// no `Data` property, no file path, no frame. A camera frame is read for its barcode and
/// discarded by whatever shows the camera; nothing in the schema can hold one, which is the
/// only enforcement that cannot be bypassed by a later call site. Photos are declined
/// everywhere in this app (`CLAUDE.md`), and a receipt is a photo of his bank balance.
///
/// ## Why this is not a `FoodItemAlias`
///
/// It is the same shape of thing — a string that resolves to an item — and this file copies
/// that file's conventions for the stored match key and the factory. It is still its own
/// table for two reasons:
///
/// 1. `NameNormalizer.matchKey` is a *word* normalizer. It does not fold a 12-digit UPC-A
///    onto its 13-digit EAN-13 twin, so the second scan of the same tin would ask again.
///    `normalize(_:)` below is the normalization these strings need.
/// 2. The alias table is HIS VOCABULARY, read back to him verbatim in the one-tap "same as…"
///    list. Thirty barcodes would bury it.
///
/// ## Why the owner is a stored key and not a relationship
///
/// `FoodItemAlias.item` is a real to-one whose `inverse:` is declared on `FoodItem.aliases`.
/// A barcode row cannot have that: adding `barcodes` to `FoodItem` was outside the brief this
/// file was written to, and a one-sided relationship is the one thing worse than a key —
/// `NSPersistentCloudKitContainer` rejects a relationship with no inverse outright, so it
/// would break the CloudKit-readiness rules `CLAUDE.md` calls non-negotiable, and Core Data
/// does not promise to enforce a delete rule without one, which is a dangling reference on a
/// device rather than a missing row.
///
/// So: `itemKey` holds the owner's `FoodItem.id.uuidString`, `""` means unattached, and
/// `itemNameSnapshot` keeps an orphan readable — the same pattern `InventoryTransaction` uses
/// for exactly the same reason. The consequences, both deliberate:
///
/// - Deleting a `FoodItem` leaves this row pointing at a key that resolves to nothing.
///   `BarcodeRegistry.scan` reports that as `.forgotten`, the screen asks once more, and the
///   answer overwrites this row. Nothing is lost and nothing dangles.
/// - `FoodItemResolver.merge` does not repoint these rows, because it cannot enumerate what
///   it cannot see. `BarcodeRegistry.repoint(from:to:in:)` does the job and is what a merge
///   should call; until it does, a merged-away item's barcodes read as `.forgotten` and he
///   rescans once.
@Model
final class FoodItemBarcode {
    var id: UUID = UUID()

    /// The digits as the scanner reported them, kept verbatim so a row he is looking at reads
    /// back as the number printed on the tin.
    var digits: String = ""

    /// `normalize(digits)` — zero-padded to GTIN-14. This is what a lookup arrives on and
    /// what a `#Predicate` can match. Stored rather than computed for the same reason
    /// `FoodItem.matchKey` is: a computed property cannot appear in a predicate.
    var matchKey: String = ""

    /// What the scanner called the symbology ("org.gs1.EAN-13", "org.gs1.UPC-A", …), as a
    /// free string because the list grows with iOS and this is provenance, not behaviour.
    /// Nothing branches on it: UPC-A and EAN-13 are the same number and `matchKey` is what
    /// unifies them.
    var symbology: String = ""

    /// The owning `FoodItem.id.uuidString`. `""` = attached to nothing. See the note above on
    /// why this is a key.
    var itemKey: String = ""

    /// So a row whose item was deleted is still readable and attributable rather than a bare
    /// number with no story.
    var itemNameSnapshot: String = ""

    var createdAt: Date = .now

    /// Last time this number was scanned. Sorts the "numbers this kitchen knows" list by what
    /// he actually buys.
    var lastScannedAt: Date = .now

    var scanCount: Int = 0

    init(
        id: UUID = UUID(),
        digits: String = "",
        matchKey: String = "",
        symbology: String = "",
        itemKey: String = "",
        itemNameSnapshot: String = "",
        createdAt: Date = .now,
        lastScannedAt: Date = .now,
        scanCount: Int = 0
    ) {
        self.id = id
        self.digits = digits
        self.matchKey = matchKey
        self.symbology = symbology
        self.itemKey = itemKey
        self.itemNameSnapshot = itemNameSnapshot
        self.createdAt = createdAt
        self.lastScannedAt = lastScannedAt
        self.scanCount = scanCount
    }
}

// MARK: - Normalization

extension FoodItemBarcode {

    /// Digits only, zero-padded to 14. **This is the chosen normalization, and it is GTIN-14.**
    ///
    /// EAN-13 and UPC-A are the same number with a leading zero: a tin that scans as
    /// `012345678905` on one reader and `0012345678905` on another is one product, and
    /// without this the second scan asks him what it is all over again. Padding both to
    /// `00012345678905` makes them one key. ITF-14 case codes already arrive 14 long and are
    /// unchanged; EAN-8 pads the same way.
    ///
    /// Everything that is not an ASCII digit is dropped first, because a scanner or a hand
    /// entry can hand back spaces and hyphens.
    ///
    /// A raw length that is not 8, 12, 13 or 14 returns `""`, which the registry treats as
    /// unreadable and never remembers. That guard is what stops a 4- or 5-digit produce PLU,
    /// or a partial read, from being filed as a product code and then auto-filling the wrong
    /// item for ever.
    ///
    /// Two limits worth knowing rather than discovering:
    ///
    /// - **UPC-E is not expanded.** The 8-digit compressed form of a UPC-A needs a
    ///   table-driven expansion, and an expansion written where no scanner exists to check it
    ///   against is a guess. An 8-digit code is stored and matched as itself, so the same
    ///   product scanned once as UPC-E and once as UPC-A asks twice. He answers twice; that
    ///   is the honest failure.
    /// - **A price-embedded store code** (the deli and butcher labels beginning 02x) encodes
    ///   the price, so every package is a different number and every one asks. Nothing here
    ///   can fix that without the lookup service this app does not have.
    static func normalize(_ raw: String) -> String {
        var digits = ""
        for character in raw where "0123456789".contains(character) {
            digits.append(character)
        }
        guard digits.count == 8 || digits.count == 12
                || digits.count == 13 || digits.count == 14
        else { return "" }
        return String(repeating: "0", count: 14 - digits.count) + digits
    }

    /// The only spelling that cannot leave `digits` and `matchKey` describing different
    /// numbers — the same reason `FoodItemAlias.make` exists. A divergence here is
    /// undetectable downstream: the predicate matches `matchKey` and the row he reads is
    /// `digits`.
    ///
    /// Returns nil for anything `normalize(_:)` refuses, so an unreadable number cannot be
    /// stored at all.
    static func make(
        digits raw: String,
        symbology: String = "",
        item: FoodItem? = nil,
        at date: Date = .now
    ) -> FoodItemBarcode? {
        let key = normalize(raw)
        guard !key.isEmpty else { return nil }
        let row = FoodItemBarcode(
            digits: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            matchKey: key,
            symbology: symbology,
            createdAt: date,
            lastScannedAt: date,
            scanCount: 1
        )
        if let item = item { row.attach(to: item) }
        return row
    }
}

// MARK: - Accessors and the writers that cannot leave a pair half-written

extension FoodItemBarcode {

    var itemID: UUID? { itemKey.isEmpty ? nil : UUID(uuidString: itemKey) }

    var isAttached: Bool { itemID != nil }

    var displayDigits: String { digits.isEmpty ? matchKey : digits }

    /// Both owner fields through one call. Writing `itemKey` without the snapshot leaves a row
    /// that cannot be read at all once its item is gone, which is the one state the snapshot
    /// exists to prevent — the same half-written-pair trap `FoodItem.setDensity` answers.
    func attach(to item: FoodItem) {
        itemKey = item.id.uuidString
        itemNameSnapshot = item.displayName
    }

    /// Clears the owner and keeps the snapshot, so the row still says what it used to mean.
    func detach() {
        itemKey = ""
    }

    /// Records that this number was just scanned. A scan IS the event this row is here to
    /// count, so it is written on the lookup path rather than by a separate call a caller can
    /// forget.
    func noteScan(at date: Date = .now) {
        lastScannedAt = date
        scanCount += 1
    }

    /// Step 1 and only step of a barcode lookup.
    static func descriptor(forMatchKey key: String) -> FetchDescriptor<FoodItemBarcode> {
        // Hoisted, and not for style: `#Predicate` translates its closure into a
        // `PredicateExpression` tree and has no representation for
        // `DefaultStringInterpolation`, so an interpolated operand fails to expand. The
        // general rule for this codebase is to build every predicate operand outside the
        // macro and capture it (`FoodItem.descriptor(forMatchKey:)`).
        let needle = key
        var descriptor = FetchDescriptor<FoodItemBarcode>(
            predicate: #Predicate<FoodItemBarcode> { $0.matchKey == needle }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Every number filed against one item — several is the normal case, not the exception:
    /// the store brand and the name brand of the same cream cheese are two barcodes and one
    /// `FoodItem`, and so are the 8 oz and 16 oz tubs.
    static func descriptor(forItemKey key: String) -> FetchDescriptor<FoodItemBarcode> {
        let needle = key
        return FetchDescriptor<FoodItemBarcode>(
            predicate: #Predicate<FoodItemBarcode> { $0.itemKey == needle }
        )
    }
}
