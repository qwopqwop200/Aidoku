import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct PersistentHistoryStoreTests {
    @Test func historyFetchAndPurgeExcludeUntrackedStoreAndPreserveRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "AuditItem"
        entity.managedObjectClassName = "NSManagedObject"
        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        entity.properties = [name]
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let tracked = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil,
            at: directory.appendingPathComponent("Cloud.sqlite"),
            options: [NSPersistentHistoryTrackingKey: true]
        )
        let local = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil,
            at: directory.appendingPathComponent("Local.sqlite")
        )
        defer {
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        for (store, name) in [(tracked, "cloud"), (local, "local")] {
            let object = NSManagedObject(entity: entity, insertInto: context)
            object.setValue(name, forKey: "name")
            context.assign(object, to: store)
        }
        try context.save()

        // The same factory scopes both the first fetch and an expired-token fallback.
        for _ in 0..<2 {
            let request = try #require(CoreDataManager.scopedHistoryRequest(
                .fetchHistory(after: Date.distantPast), in: context
            ))
            #expect(request.affectedStores?.count == 1)
            #expect(request.affectedStores?.first === tracked)
            let result = try #require(try context.execute(request) as? NSPersistentHistoryResult)
            let transactions = try #require(result.result as? [NSPersistentHistoryTransaction])
            #expect(transactions.count == 1)
            #expect(transactions.first?.changes?.count == 1)
        }
        let purge = try #require(CoreDataManager.scopedHistoryRequest(
            .deleteHistory(before: Date.distantFuture), in: context
        ))
        #expect(purge.affectedStores?.first === tracked)
        try context.execute(purge)
        let afterPurge = try #require(CoreDataManager.scopedHistoryRequest(
            .fetchHistory(after: Date.distantPast), in: context
        ))
        let result = try #require(try context.execute(afterPurge) as? NSPersistentHistoryResult)
        #expect((result.result as? [NSPersistentHistoryTransaction])?.isEmpty == true)
        let request = NSFetchRequest<NSManagedObject>(entityName: "AuditItem")
        let rows = try context.fetch(request)
        #expect(Set(rows.compactMap { $0.value(forKey: "name") as? String }) == ["cloud", "local"])

        // No history-capable stores means no request, rather than an unscoped request.
        try coordinator.remove(tracked)
        #expect(CoreDataManager.scopedHistoryRequest(.fetchHistory(after: Date.distantPast), in: context) == nil)
    }
}
