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

}
