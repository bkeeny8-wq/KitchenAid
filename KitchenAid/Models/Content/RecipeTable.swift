import Foundation

/// A lookup table the recipe prints, kept as a table.
///
/// The roast turkey's timing is not a number, it is a chart: eight rows of
/// weight against total, covered and uncovered time, because a 10 lb bird and a
/// 24 lb bird share a recipe and nothing else. Flattened into prose it landed in
/// the body of the final step as "…10 lb 2 hr 10 min 1 hr 27 min 43 min 12 lb
/// 2 hr 36 min…", which is every number intact and none of them usable.
///
/// Deliberately untyped: `headers` and `rows` are strings, and nothing here
/// parses "2 hr 10 min" into minutes or "10 lb" into a weight. The app's job for
/// now is to show the cook the row they need, and a table it can render is worth
/// more than a schema that only fits the one table that exists. When a second
/// document brings a second table, that will say what the typed version should
/// be; guessing before then would be designing for one example.
struct RecipeTable: Codable, Hashable, Sendable, Identifiable {

    /// The heading the document gave it, e.g. "Cooking Times".
    var name: String = ""

    /// The first row, which labels the columns.
    var headers: [String] = []

    /// Every row after the first. Ragged rows are possible and not an error —
    /// a document is not a spreadsheet.
    var rows: [[String]] = []

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, headers, rows
    }

    init(name: String = "", headers: [String] = [], rows: [[String]] = []) {
        self.name = name
        self.headers = headers
        self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.headers = try c.decodeIfPresent([String].self, forKey: .headers) ?? []
        self.rows = try c.decodeIfPresent([[String]].self, forKey: .rows) ?? []
    }
}

extension RecipeTable {
    /// The row whose first cell best matches `key`, for "what does a 14 lb bird
    /// need?". Matched on the leading number so "14" finds "14 lb".
    func row(matchingFirstColumn key: String) -> [String]? {
        let wanted = key.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = rows.first(where: {
            ($0.first ?? "").trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }) {
            return exact
        }
        let digits = wanted.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty else { return nil }
        return rows.first { ($0.first ?? "").hasPrefix(digits) }
    }

    /// Header and cell paired up, so a view can render one row as labelled
    /// values without assuming how many columns there are.
    func labelled(_ row: [String]) -> [(label: String, value: String)] {
        row.enumerated().map { index, value in
            (label: index < headers.count ? headers[index] : "", value: value)
        }
    }
}
