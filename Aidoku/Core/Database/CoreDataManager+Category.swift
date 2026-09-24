//
//  CoreDataManager+Category.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/11/22.
//

import CoreData

extension CoreDataManager {
    // These synchronous helpers run on their context queue. Keep fetch, save,
    // and preference migration together; never hold this lock across await.
    private static let categoryReferenceLock = NSLock()

    /// Commit the database rename before migrating settings that refer to its title.
    func renameCategoryAndSave(title: String, newTitle: String, context: NSManagedObjectContext) throws -> Bool {
        Self.categoryReferenceLock.lock()
        defer { Self.categoryReferenceLock.unlock() }
        guard renameCategory(title: title, newTitle: newTitle, context: context) else { return false }
        do { try context.save() } catch { context.rollback(); throw error }
        Self.updateCategoryReferences(from: title, to: newTitle)
        return true
    }

    func removeCategoryAndSave(title: String, context: NSManagedObjectContext) throws {
        Self.categoryReferenceLock.lock()
        defer { Self.categoryReferenceLock.unlock() }
        removeCategory(title: title, context: context)
        do { try context.save() } catch { context.rollback(); throw error }
        Self.updateCategoryReferences(from: title, to: nil)
    }

    func updateFilterGroupAndSave(title: String, newTitle: String, data: Data, context: NSManagedObjectContext) throws {
        Self.categoryReferenceLock.lock()
        defer { Self.categoryReferenceLock.unlock() }
        let request = CategoryObject.fetchRequest()
        request.predicate = NSPredicate(format: "title == %@", title)
        request.fetchLimit = 1
        guard let category = try context.fetch(request).first else { throw CocoaError(.validationMissingMandatoryProperty) }
        category.title = newTitle.isEmpty ? title : newTitle
        category.data = data as NSObject
        do { try context.save() } catch { context.rollback(); throw error }
        if category.title != title { Self.updateCategoryReferences(from: title, to: category.title) }
    }

    private static func updateCategoryReferences(from title: String, to newTitle: String?) {
        let settings = AppSettings.library
        if settings.defaultCategory.get() == title { settings.defaultCategory.set(newTitle) }
        if settings.currentCategory.get() == title { settings.currentCategory.set(newTitle) }
        for key in [settings.lockedCategories, settings.excludedUpdateCategories] {
            let old = key.get()
            guard old.contains(title) else { continue }
            key.set(old.compactMap { $0 == title ? newTitle : $0 })
        }
    }

    /// Remove all category objects.
    func clearCategories(context: NSManagedObjectContext) {
        clear(request: CategoryObject.fetchRequest(), context: context)
    }

    /// Get category object with title.
    func getCategory(title: String, context: NSManagedObjectContext) -> CategoryObject? {
        let request = CategoryObject.fetchRequest()
        request.predicate = NSPredicate(format: "title == %@", title)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// Get all category objects.
    func getCategories(sorted: Bool = true, groupsOnly: Bool = false, context: NSManagedObjectContext) -> [CategoryObject] {
        let request = CategoryObject.fetchRequest()
        if groupsOnly {
            request.predicate = NSPredicate(format: "group == %@", NSNumber(value: true))
        }
        if sorted {
            request.sortDescriptors = [
                NSSortDescriptor(key: "group", ascending: true), // put filter groups on the bottom, if they're included
                NSSortDescriptor(key: "sort", ascending: true)
            ]
        }
        let objects = try? context.fetch(request)
        return objects ?? []
    }

    /// Get category objects for a library manga.
    func getCategories(mangaId: MangaIdentifier, context: NSManagedObjectContext) -> [CategoryObject] {
        let libraryObject = getLibraryManga(mangaId: mangaId, context: context)
        return (libraryObject?.categories?.allObjects as? [CategoryObject]) ?? []
    }

    @MainActor
    func getCategoryTitles(sorted: Bool = true, excludeFilterGroups: Bool = true) -> [String] {
        getCategoryTitles(sorted: sorted, excludeFilterGroups: excludeFilterGroups, context: context)
    }

    func getCategoryTitles(
        sorted: Bool = true,
        excludeFilterGroups: Bool = true,
        context: NSManagedObjectContext
    ) -> [String] {
        getCategories(sorted: sorted, context: context)
            .filter { excludeFilterGroups ? !$0.group : true }
            .compactMap { $0.title }
    }

    func getFilterGroups(context: NSManagedObjectContext) -> [FilterGroup] {
        let decoder = JSONDecoder()
        return CoreDataManager.shared.getCategories(groupsOnly: true, context: context)
            .compactMap { (object: CategoryObject) -> FilterGroup? in
                guard
                    let title = object.title,
                    let data = object.data as? Data,
                    let filters = try? decoder.decode([LibraryFilter].self, from: data)
                else {
                    return nil
                }
                return FilterGroup(title: title, filters: filters)
            }
    }

    /// Check if category exists.
    func hasCategory(title: String, context: NSManagedObjectContext) -> Bool {
        let request = CategoryObject.fetchRequest()
        request.predicate = NSPredicate(format: "title == %@", title)
        request.fetchLimit = 1
        return (try? context.count(for: request)) ?? 0 > 0
    }

    enum CategoryCapacityError: LocalizedError {
        case exhausted
        var errorDescription: String? { "The category list has reached its storage capacity." }
    }

    /// Create a category object. A saturated group fails before any mutation.
    @discardableResult
    func createCategory(title: String, group: Bool = false, context: NSManagedObjectContext) throws -> CategoryObject {
        let request = CategoryObject.fetchRequest()
        request.predicate = NSPredicate(format: "group == %@", NSNumber(value: group))
        request.sortDescriptors = [NSSortDescriptor(key: "sort", ascending: false)]
        request.fetchLimit = 1
        let lastCategoryIndex = try context.fetch(request).first?.sort ?? -1
        let nextSort: Int16
        if lastCategoryIndex == Int16.max {
            // Backup imports may contain sparse ranks at the signed maximum.
            // Renumber only this group, retaining its existing presentation order.
            request.fetchLimit = 0
            request.sortDescriptors = [NSSortDescriptor(key: "sort", ascending: true)]
            let categories = try context.fetch(request)
            let capacity = Int(Int16.max) - Int(Int16.min) + 1
            guard categories.count < capacity else { throw CategoryCapacityError.exhausted }
            let base = categories.count <= Int(Int16.max) ? 0 : Int(Int16.min)
            for (index, category) in categories.enumerated() {
                category.sort = Int16(base + index)
            }
            nextSort = Int16(base + categories.count)
        } else {
            nextSort = lastCategoryIndex + 1
        }
        let categoryObject = CategoryObject(context: context)
        categoryObject.title = title
        categoryObject.sort = nextSort
        categoryObject.group = group
        return categoryObject
    }

    /// Removes a category with the given title.
    func removeCategory(title: String, context: NSManagedObjectContext) {
        if let object = self.getCategory(title: title, context: context) {
            context.delete(object)
        }
        // update sort fields
        let categories = getCategories(sorted: true, context: context)
        if categories.count <= 65_536 {
            Self.normalizeCategoryRanks(categories)
        } else {
            // Normal categories and filter groups have independent rank spaces.
            for group in [false, true] {
                let rows = categories.filter { $0.group == group }
                if rows.count <= 65_536 { Self.normalizeCategoryRanks(rows) }
                // An already overfull imported group retains its old ranks;
                // removing an entry does not require changing its order.
            }
        }
    }

    private static func normalizeCategoryRanks(_ categories: [CategoryObject]) {
        let base = categories.count <= Int(Int16.max) + 1 ? 0 : Int(Int16.min)
        for (index, category) in categories.enumerated() {
            let rank = Int16(base + index)
            if category.sort != rank { category.sort = rank }
        }
    }

    /// Sets a new title for a category object with the given title.
    func renameCategory(title: String, newTitle: String, context: NSManagedObjectContext) -> Bool {
        guard
            !hasCategory(title: newTitle, context: context),
            let object = getCategory(title: title, context: context)
        else {
            return false
        }
        object.title = newTitle
        return true
    }

    /// Moves a cateogry to a new position.
    func moveCategory(
        title: String,
        toPosition: Int,
        context: NSManagedObjectContext
    ) {

        guard let categoryObject = getCategory(title: title, context: context) else {
            return
        }

        // Each settings list uses its own positions. Stored sort values may
        // contain gaps after a restore, so identify the row rather than treating
        // its sort value as an index into all categories and filter groups.
        var categories = getCategories(sorted: true, context: context)
            .filter { $0.group == categoryObject.group }
        guard let fromPosition = categories.firstIndex(of: categoryObject) else { return }

        // ensure move is valid
        guard
            categories.count <= 65_536,
            fromPosition != toPosition,
            fromPosition >= 0, fromPosition < categories.count,
            toPosition >= 0, toPosition < categories.count
        else {
            return
        }

        let movedCategory = categories.remove(at: fromPosition)
        categories.insert(movedCategory, at: toPosition)

        // update sort values to match new order
        Self.normalizeCategoryRanks(categories)
    }

    /// Add categories to library manga.
    func addCategoriesToManga(mangaId: MangaIdentifier, categories: [String], context: NSManagedObjectContext) {
        guard let libraryObject = getLibraryManga(mangaId: mangaId, context: context) else { return }
        for category in categories {
            guard let categoryObject = getCategory(title: category, context: context) else { continue }
            libraryObject.addToCategories(categoryObject)
        }
    }

    func addCategoriesToManga(mangaId: MangaIdentifier, categories: [String]) async {
        await container.performBackgroundTask { context in
            self.addCategoriesToManga(mangaId: mangaId, categories: categories, context: context)
            do {
                try context.save()
            } catch {
                LogManager.logger.error("CoreDataManager.addCategoriesToManga: \(error.localizedDescription)")
            }
        }
    }

    /// Remove categories from library manga.
    func removeCategoriesFromManga(mangaId: MangaIdentifier, categories: [String]) async {
        await container.performBackgroundTask { context in
            guard let libraryObject = self.getLibraryManga(mangaId: mangaId, context: context) else { return }
            for category in categories {
                guard let categoryObject = self.getCategory(title: category, context: context) else { continue }
                libraryObject.removeFromCategories(categoryObject)
            }
            do {
                try context.save()
            } catch {
                LogManager.logger.error("CoreDataManager.removeCategoriesFromManga: \(error.localizedDescription)")
            }
        }
    }

    func setMangaCategories(mangaId: MangaIdentifier, categories: [String]) async {
        await container.performBackgroundTask { context in
            guard let libraryObject = self.getLibraryManga(
                mangaId: mangaId,
                context: context
            ) else { return }
            libraryObject.categories = NSSet(array: categories.compactMap {
                self.getCategory(title: $0, context: context)
            })
            do {
                try context.save()
            } catch {
                LogManager.logger.error("CoreDataManager.setMangaCategories: \(error.localizedDescription)")
            }
        }
    }
}
