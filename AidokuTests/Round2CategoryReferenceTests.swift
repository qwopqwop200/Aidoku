import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AIDOKU_ROUND2_CATEGORY_REFERENCES"] == "1"))
struct Round2CategoryReferenceTests {
    private func withFixture(_ body: (NSManagedObjectContext, String, String) throws -> Void) throws {
        let keys = [AppSettings.library.defaultCategory.key, AppSettings.library.currentCategory.key,
                    AppSettings.library.lockedCategories.key, AppSettings.library.excludedUpdateCategories.key]
        let defaults = UserDefaults.standard
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for key in keys { defaults.set(previous[key] ?? nil, forKey: key) } }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: directory.appendingPathComponent("test.sqlite"))
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let old = "round2-old-" + UUID().uuidString, new = "round2-new-" + UUID().uuidString
        _ = try CoreDataManager.shared.createCategory(title: old, context: context)
        _ = try CoreDataManager.shared.createCategory(title: "untouched", context: context)
        try context.save()
        AppSettings.library.defaultCategory.set(old)
        AppSettings.library.currentCategory.set(old)
        AppSettings.library.lockedCategories.set(["untouched", old])
        AppSettings.library.excludedUpdateCategories.set([old, "untouched"])
        try body(context, old, new)
    }

    @Test func renamePreservesReferencesOrderAndCategoryIdentity() throws {
        try withFixture { context, old, new in
            let manager = CoreDataManager.shared
            let id = try #require(manager.getCategory(title: old, context: context)).objectID
            #expect(try manager.renameCategoryAndSave(title: old, newTitle: new, context: context))
            context.reset()
            #expect(manager.getCategory(title: new, context: context)?.objectID == id)
            #expect(AppSettings.library.defaultCategory.get() == new)
            #expect(AppSettings.library.currentCategory.get() == new)
            #expect(AppSettings.library.lockedCategories.get() == ["untouched", new])
            #expect(AppSettings.library.excludedUpdateCategories.get() == [new, "untouched"])
            try manager.removeCategoryAndSave(title: new, context: context)
            context.reset()
            #expect(manager.getCategory(title: new, context: context) == nil)
            #expect(AppSettings.library.defaultCategory.get() == nil)
            #expect(AppSettings.library.currentCategory.get() == nil)
            #expect(AppSettings.library.lockedCategories.get() == ["untouched"])
            #expect(AppSettings.library.excludedUpdateCategories.get() == ["untouched"])
        }
    }

    @Test func failedRenameAndDeletePreserveAllSettingsAndPersistedCategory() throws {
        try withFixture { context, old, new in
            for remove in [false, true] {
                let invalid = CategoryObject(context: context)
                invalid.title = nil // actual CoreData mandatory-property validation failure
                do {
                    if remove { try CoreDataManager.shared.removeCategoryAndSave(title: old, context: context) }
                    else { _ = try CoreDataManager.shared.renameCategoryAndSave(title: old, newTitle: new, context: context) }
                    Issue.record("Invalid transaction unexpectedly saved")
                } catch { }
                context.reset()
                #expect(CoreDataManager.shared.getCategory(title: old, context: context) != nil)
                #expect(CoreDataManager.shared.getCategory(title: new, context: context) == nil)
                #expect(AppSettings.library.defaultCategory.get() == old)
                #expect(AppSettings.library.currentCategory.get() == old)
                #expect(AppSettings.library.lockedCategories.get() == ["untouched", old])
                #expect(AppSettings.library.excludedUpdateCategories.get() == [old, "untouched"])
            }
        }
    }
}
