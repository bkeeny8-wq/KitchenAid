import SwiftUI
import SwiftData

/// Everything that can be printed, in one place.
///
/// `PDFExportService` renders three jobs — a recipe card, a shopping list and a week plan —
/// and two of them have no other home: the recipe screen and the week screen are written and
/// finished, and bolting an export control onto either of them now would mean editing a file
/// that is done. So they are gathered here, reached from the Shop tab, which is where he
/// already goes to turn the plan into paper.
///
/// Every row is the same `PDFExportButton`: render, then the share sheet over a file that
/// exists. He chose the share sheet, so Print, Files, Mail and Messages are all one tap
/// further on and this app needs no mail API and no key for any of them.
struct ExportCenterView: View {
    @Environment(RecipeLoader.self) private var loader

    @Query(
        filter: #Predicate<ShoppingList> { $0.isArchived == false },
        sort: \ShoppingList.generatedAt,
        order: .reverse
    )
    private var liveLists: [ShoppingList]

    @State private var weekStart: Date = .now

    var body: some View {
        List {
            weekSection
            listSection
            recipeSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Print or share")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - The week plan

    @ViewBuilder
    private var weekSection: some View {
        Section {
            DatePicker("Week of", selection: $weekStart, displayedComponents: [.date])
            PDFExportButton(
                job: .weekPlan(interval: ShoppingListGeneration.range(from: weekStart, days: 7)),
                fileLabel: "the week plan",
                title: "Export the week plan"
            )
        } header: {
            Text("The week")
        } footer: {
            Text("Seven days from the date above: who is eating, what is planned, and the "
               + "make-ahead notes, which live in the recipe files rather than in the plan.")
        }
    }

    // MARK: - The shopping list

    @ViewBuilder
    private var listSection: some View {
        Section {
            if let list = liveLists.first {
                PDFExportButton(
                    job: .shoppingList(listID: list.id),
                    fileLabel: list.title.isEmpty ? "the shopping list" : list.title,
                    title: "Export \(list.title.isEmpty ? "the list" : list.title)"
                )
            } else {
                Text("No live list to print. Build one from the plan first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("The shopping list")
        }
    }

    // MARK: - A recipe card

    @ViewBuilder
    private var recipeSection: some View {
        Section {
            if loader.all.isEmpty {
                Text("No recipes loaded, so there is no card to print.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(loader.all) { recipe in
                    PDFExportButton(
                        // Scale 1: a card printed from here is the recipe as written. The
                        // meal plan's own scale belongs to a meal, and this list is not in
                        // one.
                        job: .recipe(recipeID: recipe.id, scale: .one, titleSnapshot: recipe.title),
                        fileLabel: recipe.title,
                        title: recipe.title
                    )
                }
            }
        } header: {
            Text("A recipe card")
        } footer: {
            Text("Prints what you actually do \u{2014} your tweaks applied \u{2014} with a "
               + "footnote wherever that differs from the original.")
        }
    }
}
