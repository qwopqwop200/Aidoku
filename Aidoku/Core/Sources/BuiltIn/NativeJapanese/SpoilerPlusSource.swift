import AidokuRunner
import Foundation
import SwiftSoup
import UIKit

/// Port of ja.spoilerplus v1 and its WpComics template (MIT OR Apache-2.0).
actor SpoilerPlusSourceRunner: NativeSourceRunnerLifecycle {
    let sourceKey: String
    let partialMangaPublisher: AidokuRunner.SinglePublisher<AidokuRunner.Manga>? = .init()
    let features = AidokuRunner.SourceFeatures(processesPages: true, providesImageRequests: true, handlesDeepLinks: true)
    private let fetch: NativeSourceNetwork.Fetch
    private static let base = "https://spoilerplus.tv"
    private var images: [Int32: AidokuRunner.PlatformImage] = [:]
    private var nextImage: Int32 = 1
    private var mangaCache: (url: String, data: Data)?
    private var cacheGeneration: UInt64 = 0

    init(sourceKey: String = "ja.spoilerplus", fetch: NativeSourceNetwork.Fetch? = nil) {
        self.sourceKey = sourceKey
        self.fetch = fetch ?? NativeSourceNetwork.fetch(sourceKey: sourceKey)
    }
    func restart() async throws { try Task.checkCancellation(); invalidateCache() }
    func clearCache() async { invalidateCache() }
    private func invalidateCache() {
        cacheGeneration &+= 1
        images.removeAll()
        mangaCache = nil
    }
    private func body(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await fetch(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
    private func request(_ string: String) throws -> URLRequest {
        guard let url = URL(string: string) else { throw URLError(.badURL) }
        return URLRequest(url: url)
    }
    private func html(_ url: String, cache: Bool = false) async throws -> Document {
        try Task.checkCancellation()
        let data: Data
        if cache, let entry = mangaCache, entry.url == url { data = entry.data }
        else {
            let generation = cacheGeneration
            data = try await body(request(url))
            if cache, generation == cacheGeneration { mangaCache = (url, data) }
        }
        return try SwiftSoup.parse(String(decoding: data, as: UTF8.self), url)
    }
    static func key(_ href: String) -> String? {
        let path: String
        if href.hasPrefix(base + "/") { path = String(href.dropFirst(base.count)) }
        else if href.hasPrefix("/"), !href.hasPrefix("//") { path = href }
        else { return nil }
        return path.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 }
    }
    static func url(_ key: String) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        guard key.hasPrefix("/"), let path = key.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: base + path) else { throw URLError(.badURL) }
        return url
    }
    static func cleanTitle(_ title: String) -> String {
        for suffix in [" Raw Free", " Raw free", " raw free"] where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }
    private static func textWithNewlines(_ element: Element) throws -> String {
        let html = try element.html()
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        // SwiftSoup serializes empty HTML tags as <br />; WpComics receives <br>.
        // Both forms preserve explicit breaks while ordinary whitespace is normalized.
        let markedHTML = html
            .replacingOccurrences(of: "<br />", with: "{{ .LINEBREAK }}")
            .replacingOccurrences(of: "<br>", with: "{{ .LINEBREAK }}")
        let text = try SwiftSoup.parse("<div>\(markedHTML)</div>").select("div").first()?.text() ?? ""
        return text.replacingOccurrences(of: "{{ .LINEBREAK }}", with: "\n")
    }
    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        let url: URL
        if let query {
            var parts = URLComponents(string: Self.base)!
            parts.queryItems = [URLQueryItem(name: "s", value: query), URLQueryItem(name: "page", value: "\(page)")]
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let parsed = parts.url else { throw URLError(.badURL) }
            url = parsed
        } else {
            let sort = filters.compactMap { filter -> Int32? in if case .sort(let sort) = filter { sort.index } else { nil } }.first ?? 0
            url = try Self.url(sort == 1 ? "/ranking/\(page)/" : "/page/\(page)/")
        }
        let document = try await html(url.absoluteString)
        var entries: [AidokuRunner.Manga] = []
        for cell in try document.select("div.items > div.row > article.item > figure.clearfix") {
            guard let anchor = try cell.select("figcaption > h3 > a").first(), let key = Self.key(try anchor.attr("href")) else { continue }
            let title = Self.cleanTitle(try anchor.text())
            let cover = try cell.select("div.image > a > img").first()?.attr("abs:data-src")
            entries.append(AidokuRunner.Manga(sourceKey: sourceKey, key: key, title: title, cover: cover, url: try Self.url(key)))
        }
        return AidokuRunner.MangaPageResult(entries: entries, hasNextPage: try !document.select("li > a[rel=next]").isEmpty())
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        guard needsDetails || needsChapters else { return manga }
        let url = try Self.url(manga.key)
        let document = try await html(url.absoluteString, cache: true)
        var result = manga
        let title = Self.cleanTitle(try document.select("h1.title-detail").text())
        if needsDetails {
            result.title = title
            result.cover = try document.select("div.col-image > img").first()?.attr("abs:src")
            result.authors = try document.select("ul.list-info > li.author > p.col-xs-8").map { try $0.text() }.filter { $0 != "更新中" }
            result.description = try document.select("div.detail-content > p").map { try Self.textWithNewlines($0) }.joined(separator: "\n")
            let tags = try document.select("ul.list-info > li.kind p.col-xs-8 > a").map { try $0.text() }
            result.tags = tags
            let status = try document.select("ul.list-info > li.row.status:has(i.fa-rss) > p.col-xs-8").text()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.status = status == "連載中" ? .ongoing : ["完結", "完了"].contains(status) ? .completed : .unknown
            result.contentRating = tags.contains { $0 == "オトナ" || $0.contains("エロ") } ? .nsfw : tags.contains("Ecchi") ? .suggestive : .safe
            result.viewer = .rightToLeft
            result.url = url
            if needsChapters {
                try Task.checkCancellation()
                await partialMangaPublisher?.send(result, to: PartialResultSubscription.id)
            }
        }
        if needsChapters {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy年MM月dd日"; formatter.locale = Locale(identifier: "ja_JP")
            formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
            var chapters: [AidokuRunner.Chapter] = []
            for row in try document.select("div.list-chapter > nav > ul > li") {
                guard let anchor = try row.select("div.chapter > a").first(), let key = Self.key(try anchor.attr("href")) else { continue }
                let rawTitle = try anchor.text()
                let withoutTitle = rawTitle.replacingOccurrences(of: title, with: "")
                let numbers = String(withoutTitle.filter { $0.isASCII && ($0.isNumber || $0 == " " || $0 == "." || $0 == "+") })
                    .split(separator: " ").compactMap { Float($0) }.filter { $0 >= 0 }
                let volume = numbers.count > 1 && rawTitle.lowercased().contains("vol") ? numbers.first : nil
                let number = volume != nil ? numbers[1] : numbers.first
                let uploaded = formatter.date(from: try row.select("div.col-xs-4").text())
                chapters.append(AidokuRunner.Chapter(key: key, title: number == nil ? rawTitle : nil, chapterNumber: number ?? -1,
                                        volumeNumber: volume, dateUploaded: uploaded, url: try Self.url(key)))
            }
            result.chapters = chapters
        }
        return result
    }
    static func windowNumber(_ script: String, name: String, fractional: Bool) -> String? {
        guard let range = script.range(of: name), let equals = script[range.upperBound...].firstIndex(of: "=") else { return nil }
        let remainder = script[script.index(after: equals)...].drop(while: { $0.isWhitespace })
        let number = remainder.prefix { $0.isASCII && ($0.isNumber || (fractional && $0 == ".")) }
        return number.isEmpty ? nil : String(number)
    }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        let url = try Self.url(chapter.key)
        let document = try await html(url.absoluteString)
        var mangaID: String?
        var chapterNumber: String?
        for script in try document.select("script") {
            let data = try script.html()
            mangaID = Self.windowNumber(data, name: "window.MangaId", fractional: false) ?? mangaID
            chapterNumber = Self.windowNumber(data, name: "window.CNumber", fractional: true) ?? chapterNumber
            if mangaID != nil && chapterNumber != nil { break }
        }
        guard let mangaID, let id = Int64(mangaID), let chapterNumber, let number = Double(chapterNumber), number.isFinite else {
            throw URLError(.cannotParseResponse)
        }
        var request = try self.request(Self.base + "/api/v1/get/c")
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["m": id, "n": number])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        let data = try await body(request)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = payload["e"] as? [String], !paths.isEmpty else { throw URLError(.cannotParseResponse) }
        let key: String
        if let encoded = payload["c"] {
            guard let value = encoded as? String else { throw URLError(.cannotParseResponse) }
            key = value
        } else { key = "" }
        return try paths.map { path in
            guard let url = URL(string: "https://img-cdn.stackpathcdn.app" + path) else { throw URLError(.badURL) }
            return AidokuRunner.Page(content: .url(url: url, context: ["key": key]))
        }
    }
    func getImageRequest(url: String, context: AidokuRunner.PageContext?) throws -> URLRequest {
        var request = try self.request(url)
        request.setValue(context?["Referer"] ?? Self.base + "/", forHTTPHeaderField: "Referer")
        return request
    }
    func store<T: Sendable>(value: T) throws -> Int32 {
        guard let image = value as? AidokuRunner.PlatformImage, nextImage < Int32.max else { throw AidokuRunner.SourceError.deserializeError }
        let id = nextImage; nextImage += 1; images[id] = image
        return id
    }
    func remove(value: Int32) { images[value] = nil }
    func processPageImage(response: AidokuRunner.Response, context: AidokuRunner.PageContext?) throws -> AidokuRunner.PlatformImage? {
        try Task.checkCancellation()
        guard let image = images[response.image] else { throw AidokuRunner.SourceError.deserializeError }
        guard let key = context?["key"], !key.isEmpty else { return image }
        return try SpoilerPlusImageCodec.unscramble(image, key: key)
    }
    func handleDeepLink(url: String) throws -> AidokuRunner.DeepLinkResult? {
        // Shared-link tracking and reader fragments are URL metadata, not source identity.
        guard let parts = URLComponents(string: url), parts.host == "spoilerplus.tv", parts.scheme == "https",
              let key = Self.key(parts.percentEncodedPath) else { return nil }
        let segments = key.split(separator: "/")
        guard let series = segments.first, series.hasSuffix("-raw-free") else { return nil }
        let mangaKey = "/\(series)/"
        return AidokuRunner.DeepLinkResult(mangaKey: mangaKey, chapterKey: segments.count > 1 ? key.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash : nil)
    }
}

private extension String {
    var withLeadingSlash: String { "/" + self + "/" }
}

/// SpoilerPlus returns a hexadecimal XOR-encoded permutation of a square image grid.
enum SpoilerPlusImageCodec {
    static func order(_ key: String) throws -> [Int] {
        let chars = Array(key.utf8)
        guard !chars.isEmpty, chars.count <= 65536, chars.count.isMultiple(of: 2) else {
            throw URLError(.cannotDecodeContentData)
        }
        let xor = "spoilerplus.tv".utf8.reduce(UInt8(0), ^)
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let value = UInt8(String(decoding: chars[index...index + 1], as: UTF8.self), radix: 16) else {
                throw URLError(.cannotDecodeContentData)
            }
            bytes.append(value ^ xor)
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        let values = text.split(separator: ",").compactMap { Int($0) }
        let side = Int(Double(values.count).squareRoot())
        guard side > 0, values.count <= 4096, side * side == values.count,
              Set(values) == Set(0..<values.count) else { throw URLError(.cannotDecodeContentData) }
        return values
    }
    static func unscramble(_ image: AidokuRunner.PlatformImage, key: String) throws -> AidokuRunner.PlatformImage {
        let order = try order(key)
        guard let source = image.cgImage else { throw URLError(.cannotDecodeContentData) }
        let side = Int(Double(order.count).squareRoot())
        let width = CGFloat(source.width); let height = CGFloat(source.height)
        let unitWidth = width / CGFloat(side); let unitHeight = height / CGFloat(side)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bitmap = UIImage(cgImage: source)
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { renderer in
            for (index, position) in order.enumerated() {
                let sourceX = CGFloat(position % side) * unitWidth
                let sourceY = CGFloat(position / side) * unitHeight
                let destinationX = CGFloat(index % side) * unitWidth
                let destinationY = CGFloat(index / side) * unitHeight
                let destination = CGRect(x: destinationX, y: destinationY, width: unitWidth, height: unitHeight)
                // Clip the full bitmap instead of rounding each fractional source rectangle.
                renderer.cgContext.saveGState()
                renderer.cgContext.clip(to: destination)
                bitmap.draw(in: CGRect(x: destinationX - sourceX, y: destinationY - sourceY, width: width, height: height))
                renderer.cgContext.restoreGState()
            }
        }
    }
}
