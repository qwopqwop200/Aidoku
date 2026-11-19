import CoreData
import Foundation
@testable import Aidoku

/// Isolated production-schema SQLite store; never writes the application's persistent store.
/// Pass `["Cloud", "Local"]` to mirror the production two-store configuration.
@MainActor final class TemporaryCoreDataStore {
    let directory: URL
    let coordinator: NSPersistentStoreCoordinator
    let context: NSManagedObjectContext

    init(configurations: [String?] = [nil]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        for configuration in configurations {
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: configuration,
                at: directory.appendingPathComponent((configuration ?? "fixture") + ".sqlite"))
        }
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }

    func close() {
        context.reset()
        for store in coordinator.persistentStores { try? coordinator.remove(store) }
        try? FileManager.default.removeItem(at: directory)
    }
}
