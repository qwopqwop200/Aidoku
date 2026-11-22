//
//  MangaInfo.swift
//  Aidoku
//
//  Created by Skitty on 8/7/22.
//

import Foundation

struct MangaInfo: Hashable, Sendable {
    let id: MangaIdentifier

    var coverUrl: URL?
    var title: String?
    var author: String?

    var url: URL?

    var unread: Int = 0
    var downloads: Int = 0

    // Badge counts stay out of identity so a count change updates the library cell in place instead of
    // a diffable delete+insert that rebuilds the cell and reloads its cover.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.coverUrl == rhs.coverUrl && lhs.title == rhs.title && lhs.author == rhs.author && lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func toManga() -> Manga {
        Manga(
            sourceId: id.sourceKey,
            id: id.mangaKey,
            title: title,
            author: author,
            coverUrl: coverUrl,
            url: url
        )
    }
}
