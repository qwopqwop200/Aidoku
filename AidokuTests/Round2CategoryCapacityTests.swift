import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct Round2CategoryCapacityTests {
    @Test func appendingAfterMaximumRestoredSortPreservesExistingOrderAndPayload() throws {
        // Isolated SQLite; never writes the application's persistent store.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: directory.appendingPathComponent("test.sqlite"))
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let manager = CoreDataManager.shared
        let a = try manager.createCategory(title: "A", context: context)
        let b = try manager.createCategory(title: "B", context: context)
        let group = try manager.createCategory(title: "Group", group: true, context: context)
        a.sort = 7
        b.sort = Int16.max // This is permitted by backup validation and import.
        group.sort = 9
        group.data = Data("group-payload".utf8) as NSData
        try context.save()
        let ids = [a.objectID, b.objectID, group.objectID]
        _ = try manager.createCategory(title: "C", context: context)
        try context.save()
        context.reset()
        #expect(manager.getCategoryTitles(context: context) == ["A", "B", "C"])
        for id in ids { #expect(try context.existingObject(with: id).isDeleted == false) }
        let restoredGroup = try #require(context.existingObject(with: ids[2]) as? CategoryObject)
        #expect(restoredGroup.sort == 9)
        #expect(restoredGroup.data as? Data == Data("group-payload".utf8))
    }
    // Larger isolated-store scenario is opt-in so ordinary runs do not incur a
    // 65,536-row fixture. Root runs it alone on the dedicated audit simulator.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIDOKU_ROUND2_CATEGORY_CAPACITY"] == "1"))
    func saturatedSignedRankSpaceFailsWithoutMutatingExistingData() throws {
        let model = CoreDataManager.shared.container.managedObjectModel
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        for rank in Int(Int16.min)...Int(Int16.max) {
            let row = CategoryObject(context: context)
            row.title = "capacity-\(rank)"
            row.group = false
            row.sort = Int16(rank)
        }
        try context.save()
        let before = try context.fetch(CategoryObject.fetchRequest()).map { ($0.objectID, $0.sort, $0.title) }
        do {
            _ = try CoreDataManager.shared.createCategory(title: "cannot-fit", context: context)
            Issue.record("A saturated category group must return an explicit error")
        } catch {
            // The storage contract has no free signed rank remaining.
            #expect(error.localizedDescription.contains("capacity"))
        }
        #expect(!context.hasChanges)
        #expect(try context.count(for: CategoryObject.fetchRequest()) == 65_536)
        for (id, sort, title) in before {
            let row = try #require(context.existingObject(with: id) as? CategoryObject)
            #expect(row.sort == sort && row.title == title)
        }
        let manager = CoreDataManager.shared
        let lastTitle = "capacity-\(Int16.max)"
        manager.moveCategory(title: lastTitle, toPosition: 0, context: context)
        try context.save()
        let moved = manager.getCategoryTitles(context: context)
        let remaining = (Int(Int16.min)..<Int(Int16.max)).map { "capacity-\($0)" }
        #expect(moved.first == lastTitle)
        #expect(Array(moved.dropFirst()) == remaining)
        manager.removeCategory(title: lastTitle, context: context)
        try context.save()
        #expect(manager.getCategoryTitles(context: context) == remaining)
    }

}
