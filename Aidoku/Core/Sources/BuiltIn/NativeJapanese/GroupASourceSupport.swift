import AidokuRunner
import Foundation
import SwiftSoup

/// Shared mechanics only; each site keeps its upstream paths, selectors and IDs.
enum GroupASourceSupport {
    static func data(_ request: URLRequest, fetch: NativeSourceNetwork.Fetch) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await fetch(request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw SourceError.message("Source request failed")
        }
        try Task.checkCancellation()
        return data
    }

    static func html(_ url: URL, fetch: NativeSourceNetwork.Fetch) async throws -> Document {
        let data = try await data(URLRequest(url: url), fetch: fetch)
        guard let text = String(data: data, encoding: .utf8) else { throw SourceError.message("Invalid HTML") }
        return try SwiftSoup.parse(text, url.absoluteString)
    }

    static func url(_ base: String, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let resolved = URL(string: path, relativeTo: URL(string: base + "/"))?.absoluteURL,
              var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            throw SourceError.message("Invalid source URL")
        }
        if !query.isEmpty {
            parts.queryItems = query
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts.url else { throw SourceError.message("Invalid source URL") }
        return url
    }

    static func text(_ element: Element?, _ selector: String) -> String? {
        guard let value = try? element?.select(selector).first()?.text(), !value.isEmpty else { return nil }
        return value
    }

    static func attr(_ element: Element?, _ selector: String, _ name: String) -> String? {
        guard let value = try? element?.select(selector).first()?.attr(name), !value.isEmpty else { return nil }
        return value
    }

    static func number(_ value: String, japaneseOnly: Bool = false) -> Float? {
        let pattern = japaneseOnly ? #"第([0-9]+(?:\.[0-9]+)?)話"# : #"(?:第)?([0-9]+(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return Float(value[range])
    }

    static func rating(_ tags: [String]) -> AidokuRunner.ContentRating {
        let lower = tags.map { $0.lowercased() }
        let explicit = ["成人向け", "成年", "アダルト", "hentai", "adult", "smut"]
        let suggestive = ["ecchi", "mature", "巨乳", "エッチ"]
        if lower.contains(where: { tag in explicit.contains(where: { tag.contains($0) }) }) { return .nsfw }
        if lower.contains(where: { tag in suggestive.contains(where: { tag.contains($0) }) }) { return .suggestive }
        return .safe
    }

    static func imageRequest(_ value: String, base: String) throws -> URLRequest {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme) else { throw SourceError.message("Invalid image URL") }
        var request = URLRequest(url: url)
        request.setValue(base + "/", forHTTPHeaderField: "Referer")
        return request
    }
}
