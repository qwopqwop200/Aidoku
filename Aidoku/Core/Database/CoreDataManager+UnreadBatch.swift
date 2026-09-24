import CoreData

extension CoreDataManager {
    /// Batches only persisted SQLite counts. Retains the scalar path for unsaved
    /// changes/other store types, since grouped dictionary fetches omit pending changes.
    func unreadCounts(mangaIds: [MangaIdentifier], context: NSManagedObjectContext) -> [MangaIdentifier: Int] {
        struct Group: Hashable {
            let source: String
            let language: String?
            let scanlators: [String]?
        }
        var groups: [Group: [MangaIdentifier]] = [:]
        for id in mangaIds {
            // Preserve the existing first-object filter lookup, including legacy duplicate rows.
            let filter = getMangaChapterFilters(mangaId: id, context: context)
            let scanlators = filter.scanlators.flatMap { $0.isEmpty ? nil : $0.sorted() }
            groups[Group(source: id.sourceKey, language: filter.language, scanlators: scanlators), default: []].append(id)
        }
        var result: [MangaIdentifier: Int] = [:]
        let stores = context.persistentStoreCoordinator?.persistentStores ?? []
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
                    let rows = try context.fetch(request)
                    var batch: [MangaIdentifier: Int] = [:]
                    var valid = true
                    for row in rows {
                        guard let key = row["mangaId"] as? String,
                              let number = row["unreadCount"] as? NSNumber,
                              let value = Int(exactly: number.int64Value) else { valid = false; break }
                        batch[.init(sourceKey: group.source, mangaKey: key)] = value
                    }
                    guard valid else { scalar(subset); continue }
                    for id in subset { result[id] = batch[id] ?? 0 }
                } catch {
                    // Preserve established scalar behavior if a store cannot execute grouping.
                    scalar(subset)
                }
            }
        }
        return result
    }
}
