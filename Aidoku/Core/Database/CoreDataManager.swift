//
//  CoreDataManager.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/2/22.
//

import Combine
import CoreData

final class CoreDataManager: @unchecked Sendable {
    static let shared = CoreDataManager()

    static let containerID = Bundle.main
        .infoDictionary?["ICLOUD_CONTAINER_ID"] as? String ?? "iCloud.\(Bundle.main.bundleIdentifier!)"

    let container: NSPersistentCloudKitContainer

    @MainActor
    var context: NSManagedObjectContext {
        container.viewContext
    }

    // only accessed from init
    private var cancellables: Set<AnyCancellable> = []

    private let remoteHistoryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.aidoku.remote-history"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    // only accessed from remoteHistoryQueue
    private var lastHistoryToken: NSPersistentHistoryToken?
    private var didLoadHistoryToken = false
    private var lastHistoryPurge: Date?
    // Store options are applied when loading the persistent store. Keep history
    // retention aligned with that loaded configuration until the next launch.
    private let usesCloudKitMirroring: Bool

    private static let historyTokenUrl = FileManager.default.applicationSupportDirectory
        .appendingPathComponent("historyToken.data")
    /// How far back a cold start looks when no token has been stored yet.
    private static let historyColdStartWindow: TimeInterval = 24 * 60 * 60
    /// How much history to keep around while mirroring is running, which needs it to export.
    private static let historyRetention: TimeInterval = 7 * 24 * 60 * 60
    /// Purging on every remote change notification would run once per save, so throttle it.
    private static let historyPurgeInterval: TimeInterval = 60 * 60

    private static var shouldUseiCloud: Bool {
        AppSettings.general.icloudSync.get() && FileManager.default.ubiquityIdentityToken != nil
    }

    private init() {
        let usesCloudKitMirroring = Self.shouldUseiCloud
        self.usesCloudKitMirroring = usesCloudKitMirroring
        self.container = Self.createContainer(usesCloudKitMirroring: usesCloudKitMirroring)

        NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator
        )
        .sink { [weak self] _ in
            self?.storeRemoteChange()
        }
        .store(in: &cancellables)


    }

    static func createContainer(usesCloudKitMirroring: Bool) -> NSPersistentCloudKitContainer {
        let container = NSPersistentCloudKitContainer(name: "Aidoku")

        let storeDirectory = FileManager.default.applicationSupportDirectory

        let cloudDescription = NSPersistentStoreDescription(url: storeDirectory.appendingPathComponent("Aidoku.sqlite"))
        cloudDescription.configuration = "Cloud"
        cloudDescription.shouldMigrateStoreAutomatically = true
        cloudDescription.shouldInferMappingModelAutomatically = true

        cloudDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        cloudDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        let localDescription = NSPersistentStoreDescription(url: storeDirectory.appendingPathComponent("Local.sqlite"))
        localDescription.configuration = "Local"
        localDescription.shouldMigrateStoreAutomatically = true
        localDescription.shouldInferMappingModelAutomatically = true

        if usesCloudKitMirroring {
            cloudDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: CoreDataManager.containerID)
        } else {
            cloudDescription.cloudKitContainerOptions = nil
        }

        container.persistentStoreDescriptions = [
            cloudDescription,
            localDescription
        ]

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                LogManager.logger.error("Error loading persistent stores \(error), \(error.userInfo)")
            }
        }

//        do {
//            try container.initializeCloudKitSchema(options: [.printSchema])
//        } catch {
//            print("error initializing cloudkit schema:", error)
//        }

        return container
    }

    @MainActor
    func save() {
        do {
            try context.save()
        } catch {
            LogManager.logger.error("CoreDataManager.save: \(error.localizedDescription)")
        }
    }

//    func saveIfNeeded() {
//        if context.hasChanges {
//            save()
//        }
//    }

    func remove(_ objectID: NSManagedObjectID) {
        container.performBackgroundTask { context in
            let object = context.object(with: objectID)
            context.delete(object)
            try? context.save()
        }
    }

    /// Clear all objects from fetch request.
    @discardableResult
    func clear<T: NSManagedObject>(request: NSFetchRequest<T>, context: NSManagedObjectContext) -> Bool {
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: (request as? NSFetchRequest<NSFetchRequestResult>)!)
        do {
            _ = try context.execute(deleteRequest)
            return true
        } catch {
            LogManager.logger.error("CoreDataManager.clear: \(error.localizedDescription)")
            return false
        }
    }

    func queueClear<T: NSManagedObject>(request: NSFetchRequest<T>, context: NSManagedObjectContext) {
        let objects = (try? context.fetch(request)) ?? []
        for object in objects {
            context.delete(object)
        }
    }

    // TODO: clean this up
    func migrateChapterHistory(progress: (@Sendable (Float) -> Void)? = nil) async {
        LogManager.logger.info("Beginning chapter history migration for 0.6")

        await container.performBackgroundTask { context in
            let request = HistoryObject.fetchRequest()
            let historyObjects = (try? context.fetch(request)) ?? []
            let total = Float(historyObjects.count)
            var i: Float = 0
            var count = 0
            for historyObject in historyObjects {
                progress?(i / total)
                i += 1
                guard
                    historyObject.chapter == nil,
                    let chapterObject = self.getChapter(
                        chapterId: historyObject.identifier,
                        context: context
                    )
                else { continue }
                historyObject.chapter = chapterObject
                count += 1
            }
            try? context.save()

            LogManager.logger.info("Migrated \(count)/\(historyObjects.count) history objects")
        }
    }
}

extension CoreDataManager {
    func storeRemoteChange() {
        remoteHistoryQueue.addOperation { [weak self] in
            guard let self else { return }
            guard self.usesCloudKitMirroring else {
                self.purgeHistory(before: Date())
                return
            }
            let context = self.container.newBackgroundContext()
            context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
            context.performAndWait {
                let historyFetchRequest = NSPersistentHistoryTransaction.fetchRequest!
                let request: NSPersistentHistoryChangeRequest
                if let token = self.historyToken() {
                    request = .fetchHistory(after: token)
                } else {
                    request = .fetchHistory(after: Date().addingTimeInterval(-Self.historyColdStartWindow))
                }
                request.fetchRequest = historyFetchRequest
                guard let request = Self.scopedHistoryRequest(request, in: context) else { return }

                var result = (try? context.execute(request)) as? NSPersistentHistoryResult
                if result == nil && self.historyToken() != nil {
                    self.clearHistoryToken()
                    let fallback = NSPersistentHistoryChangeRequest.fetchHistory(
                        after: Date().addingTimeInterval(-Self.historyColdStartWindow)
                    )
                    fallback.fetchRequest = historyFetchRequest
                    guard let fallback = Self.scopedHistoryRequest(fallback, in: context) else { return }
                    result = (try? context.execute(fallback)) as? NSPersistentHistoryResult
                }
                guard
                    let transactions = result?.result as? [NSPersistentHistoryTransaction],
                    !transactions.isEmpty
                else { return }

                var newObjectIds = [NSManagedObjectID]()
                var shouldUpdateLibrary = false
                var shouldUpdateHistory = false
                let entityNames = [
                    CategoryObject.entity().name,
                    ChapterObject.entity().name,
                    HistoryObject.entity().name,
                    LibraryMangaObject.entity().name,
                    MangaObject.entity().name,
                    TrackObject.entity().name
                ]

                for
                    transaction in transactions
                    where transaction.changes != nil && transaction.author == "NSCloudKitMirroringDelegate.import"
                {
                    for
                        change in transaction.changes!
                        where entityNames.contains(change.changedObjectID.entity.name)
                    {
                        shouldUpdateLibrary = true
                        if change.changedObjectID.entity.name == HistoryObject.entity().name {
                            shouldUpdateHistory = true
                        }
                        if change.changeType == .insert {
                            newObjectIds.append(change.changedObjectID)
                        }
                    }
                }

                if !newObjectIds.isEmpty {
                    self.deduplicate(objectIds: newObjectIds)
                }

                self.setHistoryToken(transactions.last!.token)

                if shouldUpdateLibrary {
                    Task { @MainActor [shouldUpdateHistory] in
                        NotificationCenter.default.post(name: .updateLibrary, object: nil)
                        if shouldUpdateHistory {
                            NotificationCenter.default.post(name: .updateHistory, object: nil)
                        }
                    }
                }
            }
            self.purgeHistory(before: Date().addingTimeInterval(-Self.historyRetention))
        }
    }

    private func purgeHistory(before date: Date) {
        let now = Date()
        if let lastHistoryPurge, now.timeIntervalSince(lastHistoryPurge) < Self.historyPurgeInterval {
            return
        }
        let context = container.newBackgroundContext()
        context.performAndWait {
            do {
                guard let request = Self.scopedHistoryRequest(
                    .deleteHistory(before: date), in: context
                ) else { return }
                try context.execute(request)
                lastHistoryPurge = now
            } catch {
                LogManager.logger.error("purgeHistory: \(error.localizedDescription)")
            }
        }
    }

    /// Use the loaded stores' options, not descriptions that can change after loading.
    /// Local.sqlite intentionally does not record persistent history.
    static func scopedHistoryRequest(
        _ request: NSPersistentHistoryChangeRequest,
        in context: NSManagedObjectContext
    ) -> NSPersistentHistoryChangeRequest? {
        let stores = context.persistentStoreCoordinator?.persistentStores.filter {
            ($0.options?[NSPersistentHistoryTrackingKey] as? NSNumber)?.boolValue == true
        } ?? []
        guard !stores.isEmpty else { return nil }
        request.affectedStores = stores
        return request
    }

    private func historyToken() -> NSPersistentHistoryToken? {
        if !didLoadHistoryToken {
            didLoadHistoryToken = true
            if let data = try? Data(contentsOf: Self.historyTokenUrl) {
                lastHistoryToken = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NSPersistentHistoryToken.self,
                    from: data
                )
            }
        }
        return lastHistoryToken
    }

    private func clearHistoryToken() {
        didLoadHistoryToken = true
        lastHistoryToken = nil
        Self.historyTokenUrl.removeItem()
    }

    private func setHistoryToken(_ token: NSPersistentHistoryToken) {
        didLoadHistoryToken = true
        lastHistoryToken = token
        guard
            let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        try? data.write(to: Self.historyTokenUrl, options: .atomic)
    }

    func deduplicate(objectIds: [NSManagedObjectID]) {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        // Work in batches, saving and resetting in between.
        for batch in objectIds.chunked(into: 500) {
            context.performAndWait {
                for objectId in batch {
                    deduplicate(objectId: objectId, context: context)
                }
                do {
                    try context.save()
                } catch {
                    LogManager.logger.error("deduplicate: \(error.localizedDescription)")
                }
                context.reset()
            }
        }
    }

    func deduplicate(objectId: NSManagedObjectID, context: NSManagedObjectContext) {
        guard let object = try? context.existingObject(with: objectId) else { return }

        let request: NSFetchRequest<NSFetchRequestResult>?

        if let object = object as? MangaObject {
            request = MangaObject.fetchRequest()
            request?.predicate = NSPredicate(format: "sourceId == %@ AND id == %@", object.sourceId, object.id)
        } else if let object = object as? CategoryObject {
            request = CategoryObject.fetchRequest()
            request?.predicate = NSPredicate(format: "title == %@", object.title ?? "")
        } else if let object = object as? ChapterObject {
            request = ChapterObject.fetchRequest()
            request?.predicate = NSPredicate(
                format: "sourceId == %@ AND mangaId == %@ AND id == %@",
                object.sourceId, object.mangaId, object.id
            )
        } else if let object = object as? HistoryObject {
            request = HistoryObject.fetchRequest()
            request?.predicate = NSPredicate(
                format: "sourceId == %@ AND mangaId == %@ AND chapterId == %@",
                object.sourceId, object.mangaId, object.chapterId
            )
        } else if let object = object as? LibraryMangaObject {
            request = LibraryMangaObject.fetchRequest()
            request?.predicate = NSPredicate(
                format: "manga.sourceId == %@ AND manga.id == %@",
                object.manga?.sourceId ?? "", object.manga?.id ?? ""
            )
        } else if let object = object as? TrackObject {
            request = TrackObject.fetchRequest()
            request?.predicate = NSPredicate(format: "id == %@ AND trackerId == %@ AND sourceId == %@ AND mangaId == %@",
                object.id ?? "", object.trackerId ?? "", object.sourceId ?? "", object.mangaId ?? "")
        } else {
            request = nil
        }

        guard let request = request else { return }

        guard let rows = try? context.fetch(request) as? [NSManagedObject], rows.count > 1 else { return }
        let objects = rows.sorted { lhs, rhs in
            if let left = lhs as? HistoryObject, let right = rhs as? HistoryObject {
                return (left.dateRead ?? .distantPast) > (right.dateRead ?? .distantPast)
            }
            return lhs.objectID.uriRepresentation().absoluteString < rhs.objectID.uriRepresentation().absoluteString
        }
        guard let keeper = objects.first else { return }
        for duplicate in objects.dropFirst() {
            Self.mergeDuplicateRelationships(from: duplicate, into: keeper)
            context.delete(duplicate)
        }
    }

    /// Move inverse relationships before deletion so cascade rules cannot erase unique children.
    nonisolated static func mergeDuplicateRelationships(from duplicate: NSManagedObject, into keeper: NSManagedObject) {
        if let old = duplicate as? HistoryObject, let kept = keeper as? HistoryObject,
           (old.dateRead ?? .distantPast) > (kept.dateRead ?? .distantPast) {
            kept.dateRead = old.dateRead
            kept.progress = old.progress
            kept.completed = old.completed
            kept.total = old.total
            kept.scrollPosition = old.scrollPosition
        }
        for (name, attribute) in duplicate.entity.attributesByName where !(attribute is NSDerivedAttributeDescription) {
            if let incoming = duplicate.value(forKey: name) {
                if keeper.value(forKey: name) == nil {
                    keeper.setValue(incoming, forKey: name)
                } else if let date = incoming as? Date, let current = keeper.value(forKey: name) as? Date,
                          duplicate is LibraryMangaObject {
                    keeper.setValue(name == "dateAdded" ? min(date, current) : max(date, current), forKey: name)
                }
            }
        }
        for (name, relationship) in duplicate.entity.relationshipsByName {
            if relationship.isToMany {
                if relationship.isOrdered {
                    let values = duplicate.mutableOrderedSetValue(forKey: name).array
                    keeper.mutableOrderedSetValue(forKey: name).addObjects(from: values)
                    duplicate.mutableOrderedSetValue(forKey: name).removeAllObjects()
                } else {
                    let values = duplicate.mutableSetValue(forKey: name).allObjects
                    keeper.mutableSetValue(forKey: name).addObjects(from: values)
                    duplicate.mutableSetValue(forKey: name).removeAllObjects()
                }
            } else if let child = duplicate.value(forKey: name) as? NSManagedObject {
                if let existing = keeper.value(forKey: name) as? NSManagedObject, existing != child {
                    // Both parents may already own duplicate children. Merge their
                    // unique descendants before removing the duplicate cascade edge.
                    let sameHistory = (child as? HistoryObject).flatMap { history in
                        (existing as? HistoryObject).map { $0.identifier == history.identifier }
                    } ?? false
                    if relationship.deleteRule == .cascadeDeleteRule || sameHistory {
                        mergeDuplicateRelationships(from: child, into: existing)
                        duplicate.setValue(nil, forKey: name)
                        duplicate.managedObjectContext?.delete(child)
                    }
                } else {
                    keeper.setValue(child, forKey: name)
                    duplicate.setValue(nil, forKey: name)
                }
            }
        }
    }

}
