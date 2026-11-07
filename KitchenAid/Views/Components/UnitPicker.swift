import SwiftUI

/// Choosing a unit, limited to the ones that mean anything for this
/// ingredient's dimension.
///
/// Volume, mass and count are not interconvertible without a density the app
/// refuses to guess (`MeasureDimension`), so offering tablespoons for a steak
/// is not merely noise — picking one would produce a quantity nothing can add
/// to anything else. The candidate list therefore comes from
/// `UnitCatalog.displayCandidates(for:system:)`, which also already excludes
/// `fl oz` and `gal`: 18 tsp of butter is legally 3 fl oz and that is not a
/// thing a cook says.
struct UnitPicker: View {
    let label: String
    let dimension: MeasureDimension
    /// For `.count` only. Each count noun is its own aggregation bucket, so
    /// "cloves" and "heads" are different units and the picker can only offer
    /// the one this line is counted in.
    let countNoun: String
    let system: UnitSystem
    @Binding var unit: KitchenUnit

    init(
        label: String = "Unit",
        dimension: MeasureDimension,
        countNoun: String = "",
        system: UnitSystem = .us,
        unit: Binding<KitchenUnit>
    ) {
        self.label = label
        self.dimension = dimension
        self.countNoun = countNoun
        self.system = system
        self._unit = unit
    }

    var body: some View {
        if dimension == .unmeasured {
            // "Pinch flaky salt" is a nil quantity and an unmeasured note, not
            // a unit — there is nothing here to pick, and a picker offering
            // one anyway invites him to create a quantity the model says does
            // not exist.
            HStack {
                Text(label)
                Spacer(minLength: 8)
                Text("No unit").foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        } else {
            Picker(selection: codeBinding) {
                ForEach(options) { option in
                    Text(UnitPicker.title(for: option)).tag(option.code)
                }
            } label: {
                Text(label)
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .accessibilityLabel(label)
            .accessibilityValue(UnitPicker.title(for: unit))
        }
    }

    private var dimensionKey: String {
        guard dimension == .count else { return dimension.rawValue }
        let noun = countNoun.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "count:\(noun.isEmpty ? UnitCatalog.each.code : noun)"
    }

    /// The current unit is prepended when the catalogue would not have offered
    /// it. A row can legitimately hold `fl oz` or a count noun this line is not
    /// counted in — written by the importer, or by a later build — and a
    /// `Picker` whose selection matches no tag renders blank, which reads as
    /// "no unit" for a row that has one.
    private var options: [KitchenUnit] {
        let candidates = UnitCatalog.displayCandidates(for: dimensionKey, system: system)
        if candidates.contains(unit) { return candidates }
        return [unit] + candidates
    }

    private var codeBinding: Binding<String> {
        Binding(
            get: { unit.code },
            set: { newCode in
                // Resolving against the options rather than through
                // `UnitCatalog.unit(code:fallbackDimension:)` keeps an unknown
                // code from being silently minted as a count noun here; the
                // picker can only ever offer what it listed.
                if let picked = options.first(where: { $0.code == newCode }) {
                    unit = picked
                }
            }
        )
    }

    /// `each` carries an EMPTY singular and plural on purpose, so that the
    /// fixture's "1 shallot" does not render as "1 each shallot". A picker row
    /// still needs a word, so it gets one here rather than in the catalogue.
    private static func title(for option: KitchenUnit) -> String {
        if !option.plural.isEmpty { return option.plural }
        return option.code == UnitCatalog.each.code ? "each" : option.code
    }
}
