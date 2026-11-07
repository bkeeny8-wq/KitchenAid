import SwiftUI

/// One `LineFlag`, as a small capsule. The text comes from `LineFlag.badge` and is never
/// written here: the flags are the app explaining its own arithmetic, and a second wording of
/// "needs weight per cup" is a second thing that can drift from the one the PDF prints.
///
/// Every scaling note has a flag and every flag has a badge, which is the point — a line
/// bought larger for Tuesday's leftovers must say so on the list, or the extra quantity is
/// unexplained in the aisle.
struct FlagBadge: View {
    let flag: LineFlag

    var body: some View {
        Text(flag.badge)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    /// Orange is reserved for the two states with something to do about them. Everything else
    /// is information, and colouring it all orange is how a list teaches him to ignore colour.
    private var tint: Color {
        switch flag {
        case .needsBridge, .unresolvedItem: return .orange
        case .parLevel, .expiringBeforeNeed, .expiredStockIgnored: return .purple
        default: return .secondary
        }
    }
}

/// The badges a line carries, in a stable order, wrapped so a line with four of them does not
/// push the quantity off the row.
struct FlagBadgeRow: View {
    let flags: Set<LineFlag>

    var body: some View {
        if !ordered.isEmpty {
            // `LineFlag.allCases` order rather than the set's, because a `Set` iterates in
            // hash order: without this the badges on one line reshuffle between launches.
            HStack(spacing: 5) {
                ForEach(ordered, id: \.self) { flag in
                    FlagBadge(flag: flag)
                }
            }
        }
    }

    /// `.assumedOnHand` and `.manual` return an empty badge from `LineFlag.badge`'s sibling in
    /// the PDF writer and say nothing a staple's own footer does not already say, so they are
    /// dropped here rather than rendered as an empty capsule.
    private var ordered: [LineFlag] {
        LineFlag.allCases.filter { flags.contains($0) && $0 != .assumedOnHand && $0 != .manual }
    }
}
