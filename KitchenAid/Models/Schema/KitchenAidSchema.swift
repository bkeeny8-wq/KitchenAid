import Foundation
import SwiftData

/// The one place the store's shape is declared.
///
/// There is a single list of models and everything that opens a container uses it — the
/// app, the previews and the tests. A model missing from this array is not a compile
/// error: it simply has no table, and the first fetch or insert fails at runtime, on a
/// device, with Brandon's data in it. So the array is the thing to update first when a
/// model is added, and `KitchenAidSchemaV1.models.count` is asserted in the tests to make
/// a forgotten entry fail somewhere cheap instead.
enum KitchenAidSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            // The recipe tweak overlay. Recipes themselves are NOT here: they are
            // immutable bundled content in Models/Content, decoded from
            // Resources/Recipes/*.json. These three hold only what the user changed, keyed
            // by the content's own `recipeID`, `lineID` and `stepID`.
            RecipeTweak.self,
            IngredientOverride.self,
            StepOverride.self,

            // Household and the plan.
            Eater.self,
            AttendanceDefault.self,
            PlannedMeal.self,
            MealRecipe.self,
            MealAttendance.self,

            // The inventory ledger. Level is summed from InventoryTransaction, never from
            // StockLot — see InventoryTransaction for why that distinction is load-bearing.
            FoodItem.self,
            FoodItemAlias.self,
            StockLot.self,
            InventoryTransaction.self,
            StorageLocation.self,
            Store.self,
            StoreSection.self,
            MergeRecord.self,
            SeedRecord.self,

            // Shopping.
            ShoppingList.self,
            ShoppingListLine.self,
            ShoppingListLineSubtotal.self,
            ShoppingListSource.self
        ]
    }
}

/// Migration plan. There is one schema version, so there are no stages yet.
///
/// It exists now rather than when it is first needed because adding it later means
/// changing every `ModelContainer` call site at the same moment as writing the first
/// migration — which is the worst possible time to also be editing wiring. With it in
/// place from the start, a second version is one stage appended here.
enum KitchenAidMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KitchenAidSchemaV1.self]
    }

    static var stages: [MigrationStage] { [] }
}

extension Schema {
    /// The current schema, for anything building a container.
    static var kitchenAidCurrent: Schema {
        Schema(KitchenAidSchemaV1.models, version: KitchenAidSchemaV1.versionIdentifier)
    }
}
