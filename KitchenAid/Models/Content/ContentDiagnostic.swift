import Foundation

/// What a loader reports instead of trapping. Bundled content is committed, reviewed and
/// read-only, so a malformed file is a build-time mistake — but it must not be a crash on
/// a phone in a kitchen. One bad file costs one recipe, and `StoreHealthView` says which.
struct ContentDiagnostic: Identifiable, Hashable, Sendable {

    enum Kind: String, Hashable, CaseIterable, Sendable {
        case decodeFailed
        case duplicateID
        case missingReference      // a subRecipeID or sourceRecipeID that resolves to nothing
        case emptyRecipe           // no components AND no steps
        case duplicateLineID       // two lines in one recipe share a lineID — overrides would collide
        case unknownAisle          // a catalogue aisle with no seeded StoreSection

        var title: String {
            switch self {
            case .decodeFailed: return "Could not be read"
            case .duplicateID: return "Duplicate id"
            case .missingReference: return "Missing reference"
            case .emptyRecipe: return "Nothing in it"
            case .duplicateLineID: return "Duplicate ingredient id"
            case .unknownAisle: return "Unknown aisle"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var fileName: String
    var detail: String

    init(id: UUID = UUID(), kind: Kind, fileName: String, detail: String = "") {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.detail = detail
    }
}

// MARK: - The one decoding helper every content type shares

/// Declared beside the diagnostics because it enforces the same rule they exist for:
/// **content degrades, it does not throw.**
///
/// `decodeIfPresent(SomeEnum.self, …)` returns nil only for an ABSENT key — a key that is
/// present with an unrecognised raw value throws `DecodingError.dataCorrupted`, which would
/// cost the whole recipe. That is exactly the case `KitchenAidEnums.swift`'s header says must
/// degrade: a value written by a newer build, or a kind hand-typed into a recipe file with a
/// typo, has to fall back to the default and leave the rest of the file readable.
extension KeyedDecodingContainer {
    func decodeRawValue<T>(_ type: T.Type, forKey key: Key, fallback: T) -> T
    where T: RawRepresentable, T.RawValue == String {
        // `contains` first, then a non-throwing decode: `try? decodeIfPresent` would hand
        // back a nested optional whose flattening is a language-version question, and there
        // is no compiler here to settle it (`CLAUDE.md`).
        guard contains(key),
              let raw = try? decode(String.self, forKey: key),
              let value = T(rawValue: raw)
        else { return fallback }
        return value
    }
}
