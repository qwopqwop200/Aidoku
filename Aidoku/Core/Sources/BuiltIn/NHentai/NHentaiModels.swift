import AidokuRunner
import Foundation

// Swift port of Aidoku-Community/sources multi.nhentai v17 (MIT OR Apache-2.0).
struct NHentaiTag: Decodable, Sendable {
    let name: String
    let count: Int
    let type: String
}

struct NHentaiImage: Decodable, Sendable {
    let path: String
}

struct NHentaiTitle: Decodable, Sendable {
    let english: String
    let japanese: String?
    let pretty: String
}

struct NHentaiGallery: Decodable, Sendable {
    let id: Int32
    let title: NHentaiTitle
    let cover: NHentaiImage
    let uploadDate: Int64
    let tags: [NHentaiTag]
    let numPages: Int
    let numFavorites: Int
    let pages: [NHentaiImage]

    func manga(sourceKey: String, japanese: Bool) -> AidokuRunner.Manga {
        func names(_ type: String) -> [String] {
            // Preserve server order for equal counts, matching Rust's stable sort.
            tags.enumerated().filter { $0.element.type == type }
                .sorted { lhs, rhs in
                    lhs.element.count == rhs.element.count ? lhs.offset < rhs.offset : lhs.element.count > rhs.element.count
                }.map { $0.element.name }
        }
        let genres = names("tag")
        let artists = names("artist")
        let parodies = names("parody").filter { $0 != "original" && $0 != "various" }
        let characters = names("character")
        var description = ["#\(id)"]
        if !parodies.isEmpty { description.append("Parodies: " + parodies.joined(separator: ", ")) }
        if !characters.isEmpty { description.append("Characters: " + characters.joined(separator: ", ")) }
        description.append("Pages: \(numPages)")
        if numFavorites > 0 { description.append("Favorited by: \(numFavorites)") }
        return AidokuRunner.Manga(
            sourceKey: sourceKey, key: String(id),
            title: japanese ? title.japanese.flatMap { $0.isEmpty ? nil : $0 } ?? title.english : title.english,
            cover: NHentaiImageURL.make(cover.path, cover: true), artists: artists, authors: names("group") + artists,
            description: description.joined(separator: "  \n"), url: URL(string: "https://nhentai.net/g/\(id)"),
            tags: genres, status: .completed, contentRating: .nsfw,
            viewer: genres.contains("webtoon") ? .webtoon : .rightToLeft, updateStrategy: .never
        )
    }
}

struct NHentaiGalleryListItem: Decodable, Sendable {
    let id: Int32
    let thumbnail: String
    let englishTitle: String
    let japaneseTitle: String?

    func manga(sourceKey: String, japanese: Bool) -> AidokuRunner.Manga {
        let title: String
        if japanese { title = japaneseTitle.flatMap { $0.isEmpty ? nil : $0 } ?? englishTitle }
        else if !englishTitle.isEmpty { title = englishTitle }
        else { title = japaneseTitle ?? "#\(id)" }
        return AidokuRunner.Manga(
            sourceKey: sourceKey, key: String(id), title: title,
            cover: NHentaiImageURL.make(thumbnail, cover: true), url: URL(string: "https://nhentai.net/g/\(id)"),
            status: .completed, contentRating: .nsfw, viewer: .rightToLeft, updateStrategy: .never
        )
    }
}

struct NHentaiSearchResponse: Decodable, Sendable {
    let result: [NHentaiGalleryListItem]
    let numPages: Int
}

enum NHentaiImageURL {
    static func make(_ path: String, cover: Bool) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        let host = cover ? "https://t.nhentai.net" : "https://i.nhentai.net"
        return host + (path.hasPrefix("/") ? "" : "/") + path
    }
}
