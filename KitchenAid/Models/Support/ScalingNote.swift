import Foundation

/// Surfaced as a BADGE on every affected shopping line, not swallowed.
///
/// A meal with nobody assigned must neither silently buy nothing nor silently buy for four,
/// and a snapped batch must say it snapped.
enum ScalingNote: String, Codable, CaseIterable, Sendable {
    case noAttendance
    case unknownYield
    case snappedToBatch
    case overridden
    case leftoversIncluded

    /// Stored on `ShoppingListSource` so a regenerate-in-place can re-derive the flags a
    /// contribution earned. Same shape as `LineFlag.encode`/`decode` -- pipe-delimited with
    /// leading and trailing pipes, so a `CONTAINS "|overridden|"` predicate cannot match
    /// `|notOverridden|`, and sorted so two equal sets produce one string.
    static func encode(_ notes: [ScalingNote]) -> String {
        guard !notes.isEmpty else { return "" }
        return "|" + Set(notes).map { $0.rawValue }.sorted().joined(separator: "|") + "|"
    }

    /// Back in `allCases` order rather than the blob's, so a badge row cannot reshuffle
    /// between launches.
    static func decode(_ blob: String) -> [ScalingNote] {
        let found = Set(blob.split(separator: "|").compactMap { ScalingNote(rawValue: String($0)) })
        return allCases.filter { found.contains($0) }
    }

    var badge: String {
        switch self {
        case .noAttendance: return "no eaters set"
        case .unknownYield: return "yield unknown"
        case .snappedToBatch: return "whole batch"
        case .overridden: return "scale overridden"
        case .leftoversIncluded: return "extra for leftovers"
        }
    }
}
