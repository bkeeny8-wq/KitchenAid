import SwiftUI

/// One line of the list, as he reads it standing in an aisle: the name, what to buy, and the
/// pantry comparison underneath it.
///
/// It draws the CONTENT only. The checkbox is `ShoppingLineCheckButton` beside it and the row
/// itself is the label of a `NavigationLink` into the provenance — "why is this 2 tbsp" — and
/// that split is deliberate: a button nested inside a navigation link is a target that
/// swallows one of the two taps, so the two live as siblings in one row where both stay
/// reachable and both are at least 44pt.
///
/// **Every number here is `displayString(system:)`**, the human rendering in the unit frozen
/// onto the row. Nothing on this screen may print `exactDescription`: the stored value is
/// exact so the arithmetic stays exact, but "23 1111/1135 tsp" is not a thing a cook reads.
struct ShoppingLineRow: View {
    let line: ShoppingListLine

    private var system: UnitSystem { line.list?.unitSystem ?? .us }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.displayName)
                    .font(.body)
                    .strikethrough(line.isChecked, color: .secondary)
                    .foregroundStyle(line.isChecked ? .secondary : .primary)
                Spacer(minLength: 6)
                Text(amountText)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(line.isChecked ? .secondary : .primary)
            }
            if !pantryText.isEmpty {
                Text(pantryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !line.noteToSelf.isEmpty {
                Label(line.noteToSelf, systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FlagBadgeRow(flags: line.flags)
        }
        .padding(.vertical, 2)
        .frame(minHeight: 44)
        // One swipe of VoiceOver reads the whole line: name, amount, and what the pantry
        // already has. Three separate elements for one row is three swipes to learn one fact.
        .accessibilityElement(children: .combine)
    }

    // MARK: - The numbers

    /// What to buy, which is not always a number.
    ///
    /// Four cases and each is a different fact: an amount, "to taste" for an unmeasured line
    /// that must never render as 0, "assumed on hand" for a staple carrying no quantity at
    /// all, and "all on hand" for a covered line whose summed requirement is still shown
    /// below.
    private var amountText: String {
        let rows = line.toBuy.map { $0.displayString(system: system) }.filter { !$0.isEmpty }
        if !rows.isEmpty { return rows.joined(separator: " + ") }
        if !line.unmeasuredNote.isEmpty { return line.unmeasuredNote }
        if line.status == .staple { return "assumed on hand" }
        if line.isCovered { return "all on hand" }
        return ""
    }

    /// "needs 2 cloves, 1 in the pantry" — the comparison, per dimension, in his words.
    ///
    /// It is built per `dimensionKey` and never across them, because a line legitimately holds
    /// several: garlic by the clove and by the head are separate subtotals on one line and
    /// adding them understates the garlic. A requirement with nothing on hand says "none in
    /// the pantry" rather than staying silent — the absence of a number and the number zero
    /// read the same way on a screen, and only one of them means "I checked".
    private var pantryText: String {
        guard line.status != .staple else {
            return "Tracked present or absent, so no quantity is kept."
        }
        let requested = line.requested
        guard !requested.isEmpty else { return "" }
        guard line.list?.subtractInventory ?? true else {
            let needs = requested.map { $0.displayString(system: system) }
                .joined(separator: " + ")
            return "needs \(needs); the pantry was not subtracted"
        }
        let have = line.have
        var parts: [String] = []
        for row in requested {
            let need = row.displayString(system: system)
            let onHand = have.first { $0.dimensionKey == row.dimensionKey }
            if let onHand = onHand, onHand.base > .zero {
                parts.append("needs \(need), \(onHand.displayString(system: system)) in the pantry")
            } else {
                parts.append("needs \(need), none in the pantry")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The one control he uses with a phone in one hand and a trolley in the other.
///
/// A sibling of the row rather than part of it (see `ShoppingLineRow`), and 44pt by
/// measurement rather than by whatever the glyph happens to be.
struct ShoppingLineCheckButton: View {
    let line: ShoppingListLine
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: line.isChecked ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(line.isChecked ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.isChecked ? "In the cart" : "Not in the cart")
        .accessibilityValue(line.displayName)
        .accessibilityHint(line.isChecked ? "Takes it back off the cart" : "Puts it in the cart")
    }
}
