// Native port of Aidoku-Community/sources multi.ehentai v2 (MIT OR Apache-2.0).
import AidokuRunner
import Foundation
import SwiftSoup

struct EHGalleryItem: Sendable {
    var url: String
    var title: String
    var altTitle = ""
    var cover = ""
    var category = ""
    var tags: [String] = []
    var language: String?

    func blocked(by blocklist: [String]) -> Bool {
        tags.contains { tag in
            let tag = tag.lowercased()
            return blocklist.contains { blocked in
                blocked.contains(":") ? tag == blocked : tag.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) == blocked
            }
        }
    }

    func manga(sourceKey: String, japanese: Bool, basic: Bool = false) -> AidokuRunner.Manga {
        let display = japanese && !altTitle.isEmpty ? altTitle : title.isEmpty ? altTitle : title
        var result = AidokuRunner.Manga(sourceKey: sourceKey, key: url, title: display, cover: cover.isEmpty ? nil : cover,
                           url: URL(string: url), status: .completed, contentRating: category == "non-h" ? .safe : .nsfw)
        guard !basic else { return result }
        func names(_ namespace: String) -> [String] {
            tags.compactMap { $0.hasPrefix(namespace + ":") ? String($0.dropFirst(namespace.count + 1)) : nil }
        }
        let artists = names("artist"), groups = names("group")
        let useArtist = !artists.isEmpty
        result.authors = useArtist ? artists : groups.isEmpty ? nil : groups
        result.tags = tags.filter {
            $0.hasPrefix("female:") || $0.hasPrefix("male:") || $0.hasPrefix("mixed:") || $0.hasPrefix(useArtist ? "group:" : "artist:")
        }.map { tag in
            let parts = tag.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return tag }
            return "\(parts[0] == "mixed" ? "x" : String(parts[0].prefix(1))):\(parts[1])"
        }
        if result.tags?.isEmpty == true { result.tags = nil }
        var description: [String] = []
        if let language { description.append("Language: \(language)") }
        if useArtist && !groups.isEmpty { description.append("Group: \(groups.joined(separator: ", "))") }
        for (namespace, label) in [("cosplay", "Cosplay"), ("parody", "Parody"), ("character", "Characters"), ("other", "Other"), ("location", "Location")] {
            let values = names(namespace).filter { namespace != "parody" || ($0 != "original" && $0 != "various") }
            if !values.isEmpty { description.append("\(label): \(values.joined(separator: ", "))") }
        }
        result.description = description.isEmpty ? nil : description.joined(separator: "  \n")
        result.updateStrategy = .never
        return result
    }
}

struct EHGallery: Sendable {
    var item: EHGalleryItem
    var uploader = ""
    var posted = ""
    var language = ""
    var translated = false
    var fileSize = ""
    var length = 0
    var favorites = 0
    var averageRating = 0.0
    var ratingCount = 0
    var visible = ""

    func manga(sourceKey: String, japanese: Bool) -> AidokuRunner.Manga {
        var result = item.manga(sourceKey: sourceKey, japanese: japanese)
        let artists = item.tags.filter { $0.hasPrefix("artist:") }.map { String($0.dropFirst(7)) }
        result.artists = artists.isEmpty ? nil : artists
        let webtoonKeywords = ["non-h", "webtoon", "3d", "comic", "western", "screenshots", "realporn", "artbook", "novel",
                               "variant set", "multipanel sequence"]
        let webtoon = item.category != "manga" && item.category != "doujinshi" || item.tags.contains { tag in
            tag.hasPrefix("other:") && webtoonKeywords.contains { tag.lowercased().contains($0) }
        }
        result.viewer = webtoon ? .webtoon : item.tags.contains("language:japanese") ? .rightToLeft : .leftToRight
        var description: [String] = []
        if !visible.isEmpty && visible.lowercased() != "yes" { description.append("Visible: \(visible)") }
        let groups = item.tags.filter { $0.hasPrefix("group:") }.map { String($0.dropFirst(6)) }
        if !artists.isEmpty && !groups.isEmpty { description.append("Group: \(groups.joined(separator: ", "))") }
        if length > 0 { description.append("Pages: \(length)") }
        if averageRating > 0 { description.append("Rating: \(String(format: "%.1f", averageRating)) (\(ratingCount) votes)") }
        if favorites > 0 { description.append("Favorites: \(favorites)") }
        for (namespace, label) in [("cosplay", "Cosplay"), ("parody", "Parody"), ("character", "Characters"), ("other", "Other"), ("location", "Location")] {
            let values = item.tags.filter { $0.hasPrefix(namespace + ":") }.map { String($0.dropFirst(namespace.count + 1)) }
                .filter { namespace != "parody" || ($0 != "original" && $0 != "various") }
            if !values.isEmpty { description.append("\(label): \(values.joined(separator: ", "))") }
        }
        if !fileSize.isEmpty { description.append("File Size: \(fileSize)") }
        if !uploader.isEmpty { description.append("Uploader: \(uploader)") }
        result.description = description.isEmpty ? nil : description.joined(separator: "  \n")
        return result
    }
}

enum EHentaiParser {
    static func text(_ element: Element?, _ selector: String) throws -> String {
        try element?.select(selector).first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static func attribute(_ element: Element?, _ selector: String, _ name: String) throws -> String {
        try element?.select(selector).first()?.attr(name) ?? ""
    }
    static func normalize(_ url: String) -> String {
        let base = String(url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return base.hasSuffix("/") ? base : base + "/"
    }
    static func galleryIDToken(_ string: String) -> (gid: String, token: String)? {
        guard let url = URL(string: string), ["e-hentai.org", "exhentai.org"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "g", !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              !parts[2].isEmpty else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
    static func quickIDToken(_ query: String) -> (gid: String, token: String)? {
        let parts = query.split(separator: query.contains("/") ? "/" : " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("/"), !token.contains("?"), !token.contains("#") else { return nil }
        return (String(parts[0]), token)
    }
    static func list(_ document: Document, toplist: Bool = false, limit: Int? = nil) throws -> (items: [EHGalleryItem], hasNext: Bool, lastGID: String?) {
        var items: [EHGalleryItem] = []
        let modes = toplist ? ["table.itg tr"] : ["table.itg.glte tr", "table.itg tr", "div.gl1t"]
        for mode in modes {
            for row in try document.select(mode).array() {
                if try row.select("th").first() != nil { continue }
                let extended = mode == "table.itg.glte tr", thumbnail = mode == "div.gl1t"
                let link: Element?
                if extended {
                    link = try row.select("td.gl1e a").first() ?? row.select("td.gl2e a").array().first(where: { (try? $0.attr("href").contains("/g/")) == true })
                } else if thumbnail { link = try row.select("a").first() }
                else { link = try row.select("td.glname a").first() ?? row.select("td.gl3e a").first() ?? (toplist ? row.select("td a").first() : nil) }
                guard let link else { continue }
                let raw = try link.attr("href")
                guard galleryIDToken(normalize(raw)) != nil else { continue }
                let glink = try (extended || thumbnail ? row : link).select(".glink").first()
                let title = try (glink?.text() ?? link.text()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let image = try row.select(extended || thumbnail ? "img" : ".glthumb img").first()
                let cover = try image?.attr("data-src").isEmpty == false ? image?.attr("data-src") ?? "" : image?.attr("src") ?? ""
                var tags: [String] = [], language: String?
                for tag in try row.select("div.gt, div.gtl").array() {
                    let value = try tag.attr("title")
                    if value.hasPrefix("language:") {
                        let name = String(value.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if name != "translated" && name != "rewrite" { language = name }
                    } else if !value.isEmpty { tags.append(value) }
                }
                items.append(EHGalleryItem(url: normalize(raw), title: title, altTitle: try glink?.attr("title") ?? "", cover: cover,
                                           category: try text(row, ".cn").lowercased(), tags: tags, language: language))
                if let limit, items.count >= limit { break }
            }
            if !items.isEmpty { break }
        }
        let hasNext: Bool
        if toplist { hasNext = try document.select("td.ptds").first().map { (Int(try $0.text()) ?? 0) < 199 } ?? false }
        else { hasNext = try document.select("a#dnext, a#unext[href]").first() != nil }
        return (items, hasNext, items.last.flatMap { galleryIDToken($0.url)?.gid })
    }
    static func detail(_ document: Document, url: String) throws -> EHGallery {
        var item = EHGalleryItem(url: normalize(url), title: try text(document, "#gn"))
        if item.title.isEmpty { item.title = "Gallery may have been removed" }
        item.altTitle = try text(document, "#gj")
        let style = try attribute(document, "#gd1 div", "style")
        if let start = style.firstIndex(of: "("), let end = style.lastIndex(of: ")"), start < end {
            item.cover = String(style[style.index(after: start)..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        }
        item.category = try text(document, "#gdc div").lowercased()
        var gallery = EHGallery(item: item)
        gallery.uploader = try text(document, "#gdn")
        for row in try document.select("#gdd tr").array() {
            let label = try text(row, ".gdt1").trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
            let value = try text(row, ".gdt2")
            switch label {
            case "posted": gallery.posted = value
            case "visible": gallery.visible = value
            case "language":
                gallery.translated = value.hasSuffix("TR")
                gallery.language = gallery.translated ? String(value.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines) : value
            case "file size": gallery.fileSize = value
            case "length": gallery.length = Int(value.replacingOccurrences(of: "pages", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            case "favorited": gallery.favorites = Int(value.replacingOccurrences(of: "times", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            default: break
            }
        }
        gallery.averageRating = Double(try text(document, "#rating_label").replacingOccurrences(of: "Average:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        gallery.ratingCount = Int(try text(document, "#rating_count")) ?? 0
        for row in try document.select("#taglist tr").array() {
            let namespace = try text(row, ".tc").trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            for div in try row.select("div").array() {
                let name = try div.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { gallery.item.tags.append("\(namespace):\(name)") }
            }
        }
        return gallery
    }
    static func viewer(_ url: String) -> (imgkey: String, gid: String, page: Int)? {
        guard let parsed = URL(string: url), ["e-hentai.org", "exhentai.org"].contains(parsed.host ?? "") else { return nil }
        let parts = parsed.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "s" else { return nil }
        let gidPage = parts[2].split(separator: "-", maxSplits: 1)
        guard gidPage.count == 2, UInt64(gidPage[0]) != nil, let page = Int(gidPage[1]), page > 0 else { return nil }
        return (String(parts[1]), String(gidPage[0]), page)
    }
    static func between(_ text: String, start: String, end: String) -> String? {
        guard let start = text.range(of: start), let end = text[start.upperBound...].range(of: end) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
    static func showkey(_ document: Document) throws -> String? {
        for script in try document.select("script").array() {
            if let key = between(try script.data(), start: "showkey=\"", end: "\"") { return key }
        }
        return nil
    }
    static func nl(_ document: Document) throws -> String? { between(try attribute(document, "#loadfail", "onclick"), start: "nl('", end: "')") }
    static func mpv(_ document: Document) throws -> (key: String, imageKeys: [String])? {
        for script in try document.select("script").array() {
            let text = try script.data()
            guard let key = between(text, start: "mpvkey = \"", end: "\"") ?? between(text, start: "mpvkey=\"", end: "\""),
                  let list = text.range(of: "imagelist"), let bracket = text[list.upperBound...].firstIndex(of: "[") else { continue }
            var depth = 0, quoted = false, escaped = false
            var end: String.Index?
            for index in text[bracket...].indices {
                let char = text[index]
                if quoted {
                    if escaped { escaped = false }
                    else if char == "\\" { escaped = true }
                    else if char == "\"" { quoted = false }
                } else if char == "\"" { quoted = true }
                else if char == "[" { depth += 1 }
                else if char == "]" { depth -= 1; if depth == 0 { end = text.index(after: index); break } }
            }
            guard let end, let data = String(text[bracket..<end]).data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let keys = values.compactMap { $0["k"] as? String }
            if !key.isEmpty && !keys.isEmpty { return (key, keys) }
        }
        return nil
    }
}
