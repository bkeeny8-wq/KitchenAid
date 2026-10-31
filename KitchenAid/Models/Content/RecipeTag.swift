import Foundation

/// A tag, as CONTENT.
///
/// In the design panel this was a `@Model` with a many-to-many edge to `Recipe`, which is
/// also where its first blocking defect lived — `inverse:` declared on both sides, which
/// SwiftData rejects. With recipes bundled, a tag is just a word the recipe file carries, the
/// library's filter chips come from `RecipeLoader.allTags`, and renaming a tag is a
/// find-and-replace in the repo rather than a write. There is no many-to-many left in this
/// schema at all.
struct RecipeTag: Codable, Hashable, Sendable, Identifiable {
    var name: String = ""
    var kind: TagKind = .general
    var id: String { "\(kind.rawValue):\(name.lowercased())" }

    enum CodingKeys: String, CodingKey { case name, kind }

    init(from decoder: Decoder) throws {
        // A tag may be written either as a bare string — "weeknight" — or as an object. The
        // bare form is what a human types in a JSON file, and refusing it would make every
        // recipe file noisier for no gain.
        if let single = try? decoder.singleValueContainer(),
           let name = try? single.decode(String.self) {
            self.name = name
            self.kind = .general
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.kind = c.decodeRawValue(TagKind.self, forKey: .kind, fallback: .general)
    }

    init(name: String, kind: TagKind = .general) {
        self.name = name
        self.kind = kind
    }
}
