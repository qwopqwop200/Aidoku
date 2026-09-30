import AidokuRunner
import Foundation

/// Metadata transferred by galleries/{id}.js. No JavaScript evaluation is used.
struct HitomiGallery: Decodable, Sendable {
    struct Artist: Decodable, Sendable { let artist: String }
    struct Group: Decodable, Sendable { let group: String }
    struct Parody: Decodable, Sendable { let parody: String }
    struct Character: Decodable, Sendable { let character: String }
    struct Tag: Decodable, Sendable {
        let tag: String
        let female: String?
        let male: String?
    }
    struct File: Decodable, Sendable {
        let hash: String
        let haswebp: UInt8?
        let hasavif: UInt8?
        var isGIF: Bool { haswebp == 1 && (hasavif ?? 0) == 0 }
    }
    let id: String
    let title: String
    let japaneseTitle: String?
    let galleryURL: String
    let type: String
    let language: String?
    let date: String
    let files: [File]
    let artists: [Artist]?
    let groups: [Group]?
    let parodys: [Parody]?
    let characters: [Character]?
    let tags: [Tag]?

    enum CodingKeys: String, CodingKey {
        case id, title, type, language, date, files, artists, groups, parodys, characters, tags
        case japaneseTitle = "japanese_title"
        case galleryURL = "galleryurl"
    }

    func manga(sourceKey: String, japanese: Bool) -> AidokuRunner.Manga {
        let artistNames = artists?.map(\.artist) ?? []
        let authorNames = (groups?.map(\.group) ?? []) + artistNames
        let tagNames = tags?.map { $0.tag + ($0.female == "1" ? "♀" : $0.male == "1" ? "♂" : "") } ?? []
        let keywords = ["non-h", "webtoon", "3d", "comic", "western", "screenshots", "realporn", "artbook", "novel",
                        "variant set", "multipanel sequence"]
        let webtoon = tags?.contains { tag in keywords.contains { tag.tag.lowercased().contains($0) } } ?? false
        var parts: [String] = []
        if japanese, japaneseTitle != nil { parts.append("English title: \(title)") }
        if !japanese, let japaneseTitle { parts.append("Japanese title: \(japaneseTitle)") }
        parts += ["Type: \(type)", "Pages: \(files.count)"]
        if let parodys, !parodys.isEmpty { parts.append("Series: \(parodys.map(\.parody).joined(separator: ", "))") }
        if let characters, !characters.isEmpty { parts.append("Characters: \(characters.map(\.character).joined(separator: ", "))") }
        let preferredTitle: String
        if japanese, let japaneseTitle {
            preferredTitle = japaneseTitle
        } else if japanese, let separator = title.firstIndex(of: "|") {
            let after = title[title.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            preferredTitle = after.isEmpty ? title : after
        } else {
            preferredTitle = title
        }
        let cover: String
        if let hash = files.first?.hash, hash.count >= 3 {
            cover = "https://atn.gold-usergeneratedcontent.net/avifbigtn/\(hash.suffix(1))/\(hash.suffix(3).prefix(2))/\(hash).avif"
        } else {
            cover = ""
        }
        return AidokuRunner.Manga(
            sourceKey: sourceKey, key: id, title: preferredTitle, cover: cover,
            artists: artistNames.isEmpty ? nil : artistNames, authors: authorNames.isEmpty ? nil : authorNames,
            description: parts.joined(separator: "  \n"), url: URL(string: "https://hitomi.la\(galleryURL)"),
            tags: tagNames.isEmpty ? nil : tagNames, status: .completed, contentRating: .nsfw,
            viewer: type == "anime" ? .vertical : webtoon ? .webtoon : .rightToLeft, updateStrategy: .never
        )
    }
}
