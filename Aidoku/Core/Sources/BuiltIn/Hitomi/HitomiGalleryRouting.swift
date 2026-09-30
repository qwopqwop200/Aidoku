import Foundation

struct HitomiGalleryID: Codable, Equatable, Sendable {
    let value: String

    init(value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else { value = String(try container.decode(UInt64.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Extract the published routing data without evaluating gg.js as executable code.
struct HitomiGGState: Sendable {
    enum Failure: Error { case malformedRouting, malformedGallery }
    let b: String
    let switchCases: Set<UInt32>
    let switchOffset: UInt32
    let defaultOffset: UInt32

    static func parse(_ body: String) throws -> HitomiGGState {
        guard body.utf8.count <= 1_000_000, let marker = body.range(of: "b: '"),
              let end = body[marker.upperBound...].firstIndex(of: "'") else { throw Failure.malformedRouting }
        let b = String(body[marker.upperBound..<end])
        // b is a CDN path, never a URL or JavaScript expression.
        let components = b.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, b.utf8.count <= 256,
              b.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 95, 47].contains($0) }) else { throw Failure.malformedRouting }
        let defaultOffset = matchInteger(body, pattern: #"var o = ([0-9]+)"#) ?? 0
        let switchOffset = matchInteger(body, pattern: #"(?<!var )o = ([0-9]+)\s*; break"#) ?? 1
        guard defaultOffset < UInt32.max, switchOffset < UInt32.max else { throw Failure.malformedRouting }
        let expression = try NSRegularExpression(pattern: #"case\s+([0-9]+)\s*:"#)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var cases = Set<UInt32>()
        for match in expression.matches(in: body, range: range) {
            guard let capture = Range(match.range(at: 1), in: body), let value = UInt32(body[capture]) else {
                throw Failure.malformedRouting
            }
            cases.insert(value)
        }
        return .init(b: b, switchCases: cases, switchOffset: switchOffset, defaultOffset: defaultOffset)
    }

    private static func matchInteger(_ body: String, pattern: String) -> UInt32? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)),
              let capture = Range(match.range(at: 1), in: body) else { return nil }
        return UInt32(body[capture])
    }

    static func imageID(hash: String) -> UInt32? {
        let bytes = Array(hash.utf8)
        guard (3...128).contains(bytes.count), bytes.allSatisfy({ (48...57).contains($0)
            || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        let suffix = [bytes[bytes.count - 1], bytes[bytes.count - 3], bytes[bytes.count - 2]]
        return UInt32(String(decoding: suffix, as: UTF8.self), radix: 16)
    }

    func imageURL(hash: String, extension ext: String) -> URL? {
        guard let id = Self.imageID(hash: hash), ["webp", "avif", "jpg", "jpeg", "png", "gif"].contains(ext) else { return nil }
        let offset = switchCases.contains(id) ? switchOffset : defaultOffset
        guard offset < UInt32.max else { return nil }
        let path = b.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "https://a\(offset + 1).gold-usergeneratedcontent.net/\(path)/\(id)/\(hash).\(ext)")
    }

    static func galleryJSON(_ body: String) throws -> Data {
        guard body.utf8.count <= 20_000_000, let marker = body.range(of: "galleryinfo = ") else { throw Failure.malformedGallery }
        var payload = body[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        while payload.last == ";" { payload.removeLast() }
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.first == "{", let data = payload.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw Failure.malformedGallery }
        return data
    }

    static func galleryID(url: String) -> Int64? {
        guard let parsed = URL(string: url), let host = parsed.host?.lowercased(),
              host == "hitomi.la" || host.hasSuffix(".hitomi.la") else { return nil }
        let path = parsed.path
        if let range = path.range(of: "/reader/") {
            let text = path[range.upperBound...].split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            return Int64(text).flatMap { $0 >= 0 ? $0 : nil }
        }
        if let range = path.range(of: "/g/") {
            let text = path[range.upperBound...].split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return Int64(text).flatMap { $0 >= 0 ? $0 : nil }
        }
        if path.hasSuffix(".html"), let dash = path.dropLast(5).lastIndex(of: "-") {
            let text = path[path.index(after: dash)..<path.index(path.endIndex, offsetBy: -5)]
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(text)
        }
        return nil
    }
}

enum HitomiGalleryRouting {
    static func galleryJSON(_ body: String) throws -> Data { try HitomiGGState.galleryJSON(body) }
    static func galleryID(url: String) -> Int64? { HitomiGGState.galleryID(url: url) }
}
