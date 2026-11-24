import CoreData

extension CoreDataManager {
    /// Batches only persisted SQLite counts. Retains the scalar path for unsaved
    /// changes/other store types, since grouped dictionary fetches omit pending changes.
    func unreadCounts(
        mangaIds: [MangaIdentifier], context: NSManagedObjectContext
    ) -> [MangaIdentifier: Int] {
        struct Group: Hashable {
            let source: String
            let language: String?
            let scanlators: [String]?
        }
        var groups: [Group: [MangaIdentifier]] = [:]
        // Read saved filters in batches instead of one fetch per library entry.
        var filters: [MangaIdentifier: ChapterFilters] = [:]
        if !context.hasChanges {
            for (source, ids) in Dictionary(grouping: Set(mangaIds), by: \.sourceKey) {
                for keys in ids.map(\.mangaKey).chunked(into: 500) {
                    let request = MangaObject.fetchRequest()
                    request.predicate = NSPredicate(format: "sourceId == %@ AND id IN %@", source, keys)
                    request.returnsObjectsAsFaults = false
                    let rows = (try? context.fetch(request)) ?? []
                    // Legacy duplicate rows keep the single-row lookup.
                    for (id, objects) in Dictionary(grouping: rows, by: \.identifier) where objects.count == 1 {
                        let object = objects[0]
                        filters[id] = ChapterFilters(
                            flags: Int(object.chapterFlags), language: object.langFilter, scanlators: object.scanlatorFilter
                        )
                    }
                }
            }
        }
        for id in mangaIds {
            // Preserve the existing first-object filter lookup, including legacy duplicate rows.
            let filter = filters[id] ?? getMangaChapterFilters(mangaId: id, context: context)
            let scanlators = filter.scanlators.flatMap { $0.isEmpty ? nil : $0.sorted() }
            groups[Group(source: id.sourceKey, language: filter.language, scanlators: scanlators), default: []].append(id)
        }
        var result: [MangaIdentifier: Int] = [:]
        // Only stores whose configuration contains Chapter affect the aggregate.
        let coordinator = context.persistentStoreCoordinator
        let stores = coordinator?.persistentStores.filter { store in
            coordinator?.managedObjectModel.entities(forConfigurationName: store.configurationName)?
                .contains(where: { $0.name == "Chapter" }) == true
        } ?? []
        let canGroup = !context.hasChanges && stores.count == 1 && stores.first?.type == NSSQLiteStoreType
        for (group, ids) in groups {
            func scalar(_ subset: ArraySlice<MangaIdentifier>) {
                for id in subset {
                    result[id] = unreadCount(mangaId: id, lang: group.language, scanlators: group.scanlators, context: context)
                }
            }
            for start in stride(from: 0, to: ids.count, by: 128) {
                let subset = ids[start..<min(start + 128, ids.count)]
                guard canGroup else { scalar(subset); continue }
                let request = NSFetchRequest<NSDictionary>(entityName: "Chapter")
                request.resultType = .dictionaryResultType
                request.affectedStores = stores
                var predicates = [NSPredicate(format: "sourceId == %@ AND mangaId IN %@ AND (history == nil OR history.completed == false) AND locked == false",
                    group.source, subset.map(\.mangaKey))]
                if let language = group.language { predicates.append(NSPredicate(format: "lang == %@", language)) }
                if let scanlators = group.scanlators {
                    predicates.append(NSPredicate(format: "(scanlator IN %@) OR (scanlator == nil AND %@ CONTAINS '')", scanlators, scanlators))
                }
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                let count = NSExpressionDescription()
                count.name = "unreadCount"
                // Chapter.id is nonoptional in the persistent model.
                count.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "id")])
                count.expressionResultType = .integer64AttributeType
                request.propertiesToFetch = ["mangaId", count]
                request.propertiesToGroupBy = ["mangaId"]
                do {
                    var batch: [MangaIdentifier: Int] = [:]
                    for row in try context.fetch(request) {
                        guard let key = row["mangaId"] as? String,
                              let number = row["unreadCount"] as? NSNumber,
                              let value = Int(exactly: number.int64Value) else { throw CocoaError(.coderReadCorrupt) }
                        batch[.init(sourceKey: group.source, mangaKey: key)] = value
                    }
                    for id in subset { result[id] = batch[id] ?? 0 }
                } catch {
                    // Fall back to scalar counts if the store cannot group or returns unexpected rows.
                    scalar(subset)
                }
            }
        }
        return result
    }
}
