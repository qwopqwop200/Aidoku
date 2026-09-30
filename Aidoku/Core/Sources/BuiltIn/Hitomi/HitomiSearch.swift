import CryptoKit
import Foundation

/// Hitomi's binary indexes are read directly; no source VM or JavaScript engine is involved.
actor HitomiSearch {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Failure: Error { case malformedIndex, invalidPage, invalidRange, resourceLimit, invalidVersion, missingTerm }

    static let baseURL = "https://ltn.gold-usergeneratedcontent.net"
    static let pageSize = 25
    static let maximumBytes = 100_000_000
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var savedVersion: (value: String, date: Date)?
    private var nodes: [(version: String, address: UInt64, node: Node)] = []
    private var cacheGeneration: UInt64 = 0

    init(fetch: @escaping Fetch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch
        self.now = now
    }

    func clearCache() {
        cacheGeneration &+= 1
        savedVersion = nil
        nodes.removeAll(keepingCapacity: false)
    }

    static func request(url: URL, range: ClosedRange<UInt64>? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("https://hitomi.la/", forHTTPHeaderField: "Referer")
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        return request
    }

    static func decodeNozomi(_ data: Data) -> [Int64] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - bytes.count % 4, by: 4).map { offset in
            let high = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            let low = UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            return Int64(high | low)
        }
    }

    static func nozomiURL(query: String, language: String) -> URL? {
        let query = query.replacingOccurrences(of: "_", with: " ")
        guard let colon = query.firstIndex(of: ":") else { return nil }
        let namespace = query[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = query[query.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        let name: String
        switch namespace {
        case "language": prefix = ""; name = "index-\(tag).nozomi"
        case "female", "male": prefix = "tag/"; name = "\(query)-\(language).nozomi"
        case "artist", "group", "series", "character", "tag", "type":
            prefix = "\(namespace)/"; name = "\(tag)-\(language).nozomi"
        default: return nil
        }
        // Encode user terms as path text; #, ? and / must not alter the request route.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%/")
        guard let suffix = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let encoded = prefix + suffix
        return URL(string: "\(baseURL)/\(encoded)")
    }

    func nozomiPage(url: URL, page: Int) async throws -> (ids: [Int64], hasNext: Bool) {
        guard page > 0 else { throw Failure.invalidPage }
        let (offset, overflow) = UInt64(page - 1).multipliedReportingOverflow(by: UInt64(Self.pageSize * 4))
        let (end, endOverflow) = offset.addingReportingOverflow(UInt64(Self.pageSize * 4 - 1))
        guard !overflow, !endOverflow else { throw Failure.invalidPage }
        let data = try await rangeData(url: url, range: offset...end, allowEnd: true)
        let ids = Self.decodeNozomi(data)
        return (ids, ids.count == Self.pageSize)
    }

    func allNozomi(url: URL) async throws -> [Int64] {
        try Task.checkCancellation()
        let (data, response) = try await fetch(Self.request(url: url))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= Self.maximumBytes else { throw Failure.resourceLimit }
        return Self.decodeNozomi(data)
    }

    func plainText(_ term: String) async throws -> [Int64] {
        let normalized = term.replacingOccurrences(of: "_", with: " ").lowercased()
        let key = Array(SHA256.hash(data: Data(normalized.utf8)).prefix(4))
        let version = try await indexVersion()
        var address: UInt64 = 0
        var visited = Set<UInt64>()
        // A corrupt index must not cause infinite recursion or unbounded network traffic.
        for _ in 0..<64 {
            try Task.checkCancellation()
            guard visited.insert(address).inserted else { throw Failure.malformedIndex }
            let node = try await node(version: version, address: address)
            if node.keys.isEmpty { throw Failure.missingTerm }
            var index = node.keys.count
            var found = false
            for (offset, candidate) in node.keys.enumerated() {
                let comparison = Self.compareKeys(key, candidate)
                if comparison <= 0 { index = offset; found = comparison == 0; break }
            }
            if found {
                guard index < node.values.count else { throw Failure.malformedIndex }
                let value = node.values[index]
                guard value.length > 0, value.length <= Self.maximumBytes else { throw Failure.resourceLimit }
                let (end, overflow) = value.offset.addingReportingOverflow(UInt64(value.length - 1))
                guard !overflow else { throw Failure.invalidRange }
                let url = URL(string: "\(Self.baseURL)/galleriesindex/galleries.\(version).data")!
                let data = try await rangeData(url: url, range: value.offset...end)
                return try Self.decodeGalleryIDs(data)
            }
            guard node.addresses.contains(where: { $0 != 0 }), index < node.addresses.count,
                  node.addresses[index] != 0 else { throw Failure.missingTerm }
            address = node.addresses[index]
        }
        throw Failure.resourceLimit
    }

    private func indexVersion() async throws -> String {
        let date = now()
        if let savedVersion, (0..<60).contains(date.timeIntervalSince(savedVersion.date)) { return savedVersion.value }
        savedVersion = nil
        nodes.removeAll(keepingCapacity: true)
        let generation = cacheGeneration
        let url = URL(string: "\(Self.baseURL)/galleriesindex/version?_=0")!
        let (data, response) = try await fetch(Self.request(url: url))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 128,
              let raw = String(data: data, encoding: .utf8) else { throw Failure.invalidVersion }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.invalidVersion }
        if generation == cacheGeneration { savedVersion = (version, now()) }
        return version
    }

    private func node(version: String, address: UInt64) async throws -> Node {
        if let cached = nodes.first(where: { $0.version == version && $0.address == address }) { return cached.node }
        let generation = cacheGeneration
        let (end, overflow) = address.addingReportingOverflow(463)
        guard !overflow else { throw Failure.invalidRange }
        let url = URL(string: "\(Self.baseURL)/galleriesindex/galleries.\(version).index")!
        let data = try await rangeData(url: url, range: address...end, allowEnd: true)
        let result = try Self.decodeNode(data)
        // Actor reentrancy may have refreshed the version while this request was in flight.
        if generation == cacheGeneration, savedVersion?.value == version {
            if nodes.count >= 64 { nodes.removeFirst() }
            nodes.append((version, address, result))
        }
        return result
    }

    private func rangeData(url: URL, range: ClosedRange<UInt64>, allowEnd: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await fetch(Self.request(url: url, range: range))
        try Task.checkCancellation()
        return try Self.extractRange(data, response: response, range: range, allowEnd: allowEnd)
    }

    static func extractRange(_ data: Data, response: URLResponse, range: ClosedRange<UInt64>, allowEnd: Bool = false) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard data.count <= maximumBytes else { throw Failure.resourceLimit }
        if http.statusCode == 416, allowEnd {
            guard let header = http.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes */"),
                  let total = UInt64(header.dropFirst(8)), range.lowerBound >= total else { throw Failure.invalidRange }
            return Data()
        }
        if http.statusCode == 200 {
            // Some mirrors ignore Range. Slice the full response rather than misreading its first bytes.
            guard range.lowerBound < UInt64(data.count) else {
                if allowEnd { return Data() }
                throw Failure.invalidRange
            }
            let start = Int(range.lowerBound)
            let last = min(range.upperBound, UInt64(data.count - 1))
            let slice = data.subdata(in: start..<(Int(last) + 1))
            guard allowEnd || UInt64(slice.count) == range.upperBound - range.lowerBound + 1 else { throw Failure.invalidRange }
            return slice
        }
        guard http.statusCode == 206, let header = http.value(forHTTPHeaderField: "Content-Range"),
              header.hasPrefix("bytes ") else { throw Failure.invalidRange }
        let bounds = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { throw Failure.invalidRange }
        let offsets = bounds[0].split(separator: "-", omittingEmptySubsequences: false)
        guard offsets.count == 2, let first = UInt64(offsets[0]), let last = UInt64(offsets[1]),
              first == range.lowerBound, last >= first, last <= range.upperBound,
              last - first < UInt64(maximumBytes), UInt64(data.count) == last - first + 1 else { throw Failure.invalidRange }
        if bounds[1] != "*" {
            guard let total = UInt64(bounds[1]), last < total else { throw Failure.invalidRange }
            if last < range.upperBound && (!allowEnd || last != total - 1) { throw Failure.invalidRange }
        } else if last < range.upperBound { throw Failure.invalidRange }
        return data
    }

    struct Node {
        struct Value { let offset: UInt64; let length: Int }
        let keys: [[UInt8]]
        let values: [Value]
        let addresses: [UInt64]
    }

    static func decodeNode(_ data: Data) throws -> Node {
        guard data.count <= 464 else { throw Failure.malformedIndex }
        var reader = BinaryReader(bytes: Array(data))
        let keyCount = try reader.u32()
        guard keyCount <= 16 else { throw Failure.malformedIndex }
        var keys: [[UInt8]] = []
        for _ in 0..<keyCount {
            let size = Int(try reader.u32())
            guard (1...32).contains(size) else { throw Failure.malformedIndex }
            keys.append(try reader.take(size))
        }
        let valueCount = try reader.u32()
        guard valueCount == keyCount else { throw Failure.malformedIndex }
        var values: [Node.Value] = []
        for _ in 0..<valueCount { values.append(.init(offset: try reader.u64(), length: Int(try reader.u32()))) }
        var addresses: [UInt64] = []
        for _ in 0..<17 { addresses.append(try reader.u64()) }
        return Node(keys: keys, values: values, addresses: addresses)
    }

    static func decodeGalleryIDs(_ data: Data) throws -> [Int64] {
        guard data.count >= 4, data.count <= maximumBytes else { throw Failure.malformedIndex }
        var reader = BinaryReader(bytes: Array(data.prefix(4)))
        let count = Int(try reader.u32())
        guard count == (data.count - 4) / 4, (data.count - 4) % 4 == 0 else { throw Failure.malformedIndex }
        return decodeNozomi(Data(data.dropFirst(4)))
    }

    private static func compareKeys(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        for (left, right) in zip(lhs, rhs) where left != right { return left < right ? -1 : 1 }
        return 0 // Match the source index's prefix comparison.
    }

    private struct BinaryReader {
        let bytes: [UInt8]
        var position = 0
        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count <= bytes.count - position else { throw Failure.malformedIndex }
            defer { position += count }
            return Array(bytes[position..<(position + count)])
        }
        mutating func u32() throws -> UInt32 { try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        mutating func u64() throws -> UInt64 { try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    }

    static func language(code: String?) -> String {
        let languages = [
            "en": "english", "id": "indonesian", "jv": "javanese", "ca": "catalan", "ceb": "cebuano",
            "cs": "czech", "da": "danish", "de": "german", "et": "estonian", "es": "spanish", "eo": "esperanto",
            "fr": "french", "it": "italian", "hi": "hindi", "hu": "hungarian", "pl": "polish", "pt": "portuguese",
            "vi": "vietnamese", "tr": "turkish", "ru": "russian", "uk": "ukrainian", "ar": "arabic", "ko": "korean",
            "zh": "chinese", "ja": "japanese"
        ]
        return code.flatMap { languages[$0] } ?? "all"
    }
}
