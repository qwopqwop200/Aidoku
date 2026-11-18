import CoreData
import Foundation
import SwiftUI
import Testing
@testable import Aidoku

@MainActor
struct CategoryOrderingTests {
    private func withContext(_ body: (NSManagedObjectContext) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: directory.appendingPathComponent("test.sqlite"))
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try body(context)
    }

    @Test func movingFilterGroupPreservesRegularCategoriesAndGroupData() throws {
        try withContext { context in
            let manager = CoreDataManager.shared
            let categoryA = try manager.createCategory(title: "A", context: context)
            let categoryB = try manager.createCategory(title: "B", context: context)
            let groupA = try manager.createCategory(title: "Group A", group: true, context: context)
            let groupB = try manager.createCategory(title: "Group B", group: true, context: context)
            let payload = Data("filter payload".utf8)
            groupA.data = payload as NSData
            try context.save()
            let groupID = groupA.objectID
            manager.moveCategory(title: "Group A", toPosition: 1, context: context)
            try context.save()
            #expect(manager.getCategoryTitles(context: context) == ["A", "B"])
            #expect(categoryA.sort == 0)
            #expect(categoryB.sort == 1)
            #expect(manager.getCategories(groupsOnly: true, context: context).compactMap(\.title) == ["Group B", "Group A"])
            #expect(groupB.sort == 0)
            context.reset()
            let reloaded = try #require(context.existingObject(with: groupID) as? CategoryObject)
            #expect(reloaded.data as? Data == payload)
            #expect(reloaded.sort == 1)
        }
    }

    @Test func sparseRestoredSortValuesMoveTheSelectedCategory() throws {
        try withContext { context in
            let manager = CoreDataManager.shared
            let categoryA = try manager.createCategory(title: "A", context: context)
            let categoryB = try manager.createCategory(title: "B", context: context)
            let group = try manager.createCategory(title: "Group", group: true, context: context)
            categoryA.sort = 7
            categoryB.sort = 12
            group.sort = 4
            try context.save()
            manager.moveCategory(title: "B", toPosition: 0, context: context)
            try context.save()
            context.reset()
            #expect(manager.getCategoryTitles(context: context) == ["B", "A"])
            #expect(manager.getCategory(title: "Group", context: context)?.sort == 4)
        }
    }

    @Test(arguments: [false, true])
    func multiRowDragKeepsVisibleOrderDuplicateRecordsAndUnlistedSlots(groups: Bool) throws {
        try withContext { context in
            let manager = CoreDataManager.shared
            for title in ["A", "B", "concurrent", "C", "D", "A"] {
                _ = try manager.createCategory(title: title, group: groups, context: context)
            }
            let other = try manager.createCategory(title: "other", group: !groups, context: context)
            other.sort = 42
            try context.save()

            var displayed = ["A", "B", "C", "D"]
            displayed.move(fromOffsets: [0, 1], toOffset: 4)
            #expect(try manager.saveCategoryOrder(displayed, groups: groups, context: context))
            let stored = manager.getCategories(context: context).filter { $0.group == groups }.compactMap(\.title)
            #expect(stored == ["C", "D", "concurrent", "A", "A", "B"])
            #expect(other.sort == 42)
            #expect(try manager.saveCategoryOrder(displayed, groups: groups, context: context))
            #expect(!context.hasChanges)
        }
    }

    @Test func invalidDestinationDoesNotModifyEitherList() throws {
        try withContext { context in
            let manager = CoreDataManager.shared
            _ = try manager.createCategory(title: "A", context: context)
            _ = try manager.createCategory(title: "Group", group: true, context: context)
            try context.save()
            manager.moveCategory(title: "A", toPosition: 1, context: context)
            #expect(!context.hasChanges)
            manager.moveCategory(title: "Group", toPosition: -1, context: context)
            #expect(!context.hasChanges)
        }
    }
}
