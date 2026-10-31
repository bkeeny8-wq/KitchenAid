import Foundation

enum LineFlag: String, Codable, CaseIterable, Sendable {
    case needsBridge        // volume vs mass with no density; nothing assumed on hand
    case unresolvedItem     // matched no FoodItem and no catalogue entry
    case assumedOnHand      // a staple, diverted to the footer
    case converted          // the density bridge fired; see the conversionNote
    case expiredStockIgnored
    case expiringBeforeNeed // excluded by expiringGraceDays
    case tweaked            // an IngredientOverride changed this requirement
    case noAttendance
    case unknownYield
    case snappedToBatch
    case overridden
    /// Present because `ScalingNote` has it, and every scaling note is "surfaced as a BADGE
    /// on every affected shopping line, not swallowed". Without this case `from(_:)` mapped
    /// it to nil and the extra quantity bought for Tuesday's leftovers appeared on the list
    /// with nothing explaining it.
    case leftoversIncluded
    case parLevel
    case manual

    /// `|a|b|` so `flagsBlob.contains("|needsBridge|")` works in a `#Predicate`.
    static func encode(_ flags: Set<LineFlag>) -> String {
        guard !flags.isEmpty else { return "" }
        return "|" + flags.map { $0.rawValue }.sorted().joined(separator: "|") + "|"
    }

    static func decode(_ blob: String) -> Set<LineFlag> {
        Set(blob.split(separator: "|").compactMap { LineFlag(rawValue: String($0)) })
    }

    /// Total over `ScalingNote`: every note has a flag, so nothing is swallowed.
    static func from(_ notes: [ScalingNote]) -> Set<LineFlag> {
        var flags: Set<LineFlag> = []
        for note in notes {
            switch note {
            case .noAttendance: flags.insert(.noAttendance)
            case .unknownYield: flags.insert(.unknownYield)
            case .snappedToBatch: flags.insert(.snappedToBatch)
            case .overridden: flags.insert(.overridden)
            case .leftoversIncluded: flags.insert(.leftoversIncluded)
            }
        }
        return flags
    }

    /// The badge text `FlagBadge` renders.
    var badge: String {
        switch self {
        case .needsBridge: return "needs weight per cup"
        case .unresolvedItem: return "not matched"
        case .assumedOnHand: return "assumed on hand"
        case .converted: return "converted"
        case .expiredStockIgnored: return "expired stock ignored"
        case .expiringBeforeNeed: return "expires before you need it"
        case .tweaked: return "your tweak"
        case .noAttendance: return "no eaters set"
        case .unknownYield: return "yield unknown"
        case .snappedToBatch: return "whole batch"
        case .overridden: return "scale overridden"
        case .leftoversIncluded: return "extra for leftovers"
        case .parLevel: return "below par"
        case .manual: return "added by hand"
        }
    }
}
