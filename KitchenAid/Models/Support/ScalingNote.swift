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
