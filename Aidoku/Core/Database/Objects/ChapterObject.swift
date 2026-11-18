//
//  ChapterObject.swift
//  Aidoku
//
//  Created by Skitty on 1/27/22.
//

import Foundation
import CoreData
import AidokuRunner

@objc(ChapterObject)
public class ChapterObject: NSManagedObject {
    var identifier: ChapterIdentifier {
        .init(sourceKey: sourceId, mangaKey: mangaId, chapterKey: id)
    }

    func load(
        from chapter: AidokuRunner.Chapter,
        mangaId: MangaIdentifier,
        sourceOrder: Int? = nil
    ) {
        // Core Data marks a chapter updated even when a setter receives its current value.
        if self.sourceId != mangaId.sourceKey { self.sourceId = mangaId.sourceKey }
        if self.mangaId != mangaId.mangaKey { self.mangaId = mangaId.mangaKey }
        if id != chapter.key { id = chapter.key }
        if title != chapter.title { title = chapter.title }
        let scanlator = chapter.scanlators.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") }
        if self.scanlator != scanlator { self.scanlator = scanlator }
        let url = chapter.url?.absoluteString
        if self.url != url { self.url = url }
        let lang = chapter.language ?? ""
        if self.lang != lang { self.lang = lang }
        let chapterNumber = chapter.chapterNumber.map(NSNumber.init(value:))
        if self.chapter != chapterNumber { self.chapter = chapterNumber }
        let volumeNumber = chapter.volumeNumber.map(NSNumber.init(value:))
        if volume != volumeNumber { volume = volumeNumber }
        if dateUploaded != chapter.dateUploaded { dateUploaded = chapter.dateUploaded }
        if thumbnail != chapter.thumbnail { thumbnail = chapter.thumbnail }
        if locked != chapter.locked { locked = chapter.locked }
        if let sourceOrder {
            let order = Int16(clamping: sourceOrder)
            if self.sourceOrder != order { self.sourceOrder = order }
        }
    }

    func toChapter() -> Chapter {
        Chapter(
            sourceId: sourceId,
            id: id,
            mangaId: mangaId,
            title: title,
            scanlator: scanlator,
            url: url,
            lang: lang,
            chapterNum: chapter == -1 ? nil : chapter?.floatValue,
            volumeNum: volume == -1 ? nil : volume?.floatValue,
            dateUploaded: dateUploaded,
            thumbnail: thumbnail,
            locked: locked,
            sourceOrder: Int(sourceOrder)
        )
    }

    func toNewChapter() -> AidokuRunner.Chapter {
        .init(
            key: id,
            title: title,
            chapterNumber: chapter == -1 ? nil : chapter?.floatValue,
            volumeNumber: volume == -1 ? nil : volume?.floatValue,
            dateUploaded: dateUploaded,
            scanlators: scanlator?.components(separatedBy: ", "),
            url: url.flatMap({ URL(string: $0) }),
            language: lang,
            thumbnail: thumbnail,
            locked: locked
        )
    }
}

extension ChapterObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ChapterObject> {
        NSFetchRequest<ChapterObject>(entityName: "Chapter")
    }

    @NSManaged public var sourceId: String
    @NSManaged public var mangaId: String
    @NSManaged public var id: String
    @NSManaged public var title: String?
    @NSManaged public var scanlator: String?
    @NSManaged public var url: String?
    @NSManaged public var lang: String
    @NSManaged public var chapter: NSNumber?
    @NSManaged public var volume: NSNumber?
    @NSManaged public var dateUploaded: Date?
    @NSManaged public var thumbnail: String?
    @NSManaged public var locked: Bool
    @NSManaged public var sourceOrder: Int16

    @NSManaged public var manga: MangaObject?
    @NSManaged public var history: HistoryObject?
    @NSManaged public var mangaUpdate: MangaUpdateObject?
    @NSManaged public var fileInfo: LocalFileInfoObject?
}

extension ChapterObject: Identifiable {

}
