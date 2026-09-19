//
//  BackupHistory.swift
//  Aidoku
//
//  Created by Skitty on 2/26/22.
//

import CoreData

struct BackupHistory: Codable, Hashable {
    var dateRead: Date
    var sourceId: String
    var chapterId: String
    var mangaId: String
    var progress: Int?
    var total: Int?
    var scrollPosition: Double?
    var completed: Bool

    init(historyObject: HistoryObject) {
        dateRead = historyObject.dateRead ?? Date.distantPast
        sourceId = historyObject.sourceId
        chapterId = historyObject.chapterId
        mangaId = historyObject.mangaId
        progress = Int(historyObject.progress)
        total = Int(historyObject.total)
        scrollPosition = historyObject.scrollPosition?.doubleValue
        completed = historyObject.completed
    }

    func toObject(context: NSManagedObjectContext, existing: HistoryObject? = nil) -> HistoryObject {
        let obj = existing ?? HistoryObject(context: context)
        obj.dateRead = dateRead
        obj.sourceId = sourceId
        obj.chapterId = chapterId
        obj.mangaId = mangaId
        obj.progress = Int16(progress ?? -1)
        obj.total = Int16(total ?? 0)
        obj.scrollPosition = scrollPosition.map(NSNumber.init(value:))
        obj.completed = completed
        return obj
    }
}
