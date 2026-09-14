import Foundation

actor SearchSuggestionService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct CachedResult {
        let entries: [SearchSuggestion]
        let date: Date
    }

    private struct CacheKey: Hashable {
        let url: URL
        let method: String
        let body: Data?
    }

    private let configuration: SearchSuggestionConfiguration
    private let transport: Transport
    private var cache: [CacheKey: CachedResult] = [:]

    init(configuration: SearchSuggestionConfiguration, transport: Transport? = nil) {
        self.configuration = configuration
        if let transport {
            self.transport = transport
        } else {
            let client = SearchSuggestionHTTPClient()
            self.transport = { try await client.data(for: $0) }
        }
    }

    func suggestions(for query: SearchSuggestionQuery) async throws -> [SearchSuggestion] {
        try Task.checkCancellation()
        guard let request = configuration.request(for: query), let url = request.url else { return [] }
        let key = CacheKey(url: url, method: request.httpMethod ?? "GET", body: request.httpBody)
        if let cached = cache[key], Date().timeIntervalSince(cached.date) < 300 { return cached.entries }
        try await SearchSuggestionRequestThrottle.shared.wait(
            for: url, milliseconds: configuration.minimumRequestIntervalMilliseconds ?? 0
        )
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 404 { return [] }
        if response.statusCode == 429 {
            let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            await SearchSuggestionRequestThrottle.shared.deferRequests(for: url, seconds: retry)
        }
        guard (200..<300).contains(response.statusCode), data.count <= 1_048_576 else {
            throw URLError(.badServerResponse)
        }
        let entries = try Self.decode(
            data, format: configuration.format,
            namespaceMappings: configuration.responseNamespaceMappings,
            hideCounts: configuration.hideCounts == true,
            objectFields: configuration.objectFields
        )
        if cache.count >= 64, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[key] = CachedResult(entries: entries, date: Date())
        return entries
    }

    static func decode(
        _ data: Data,
        format: SearchSuggestionConfiguration.Format,
        namespaceMappings: [String: String]? = nil,
        hideCounts: Bool = false,
        objectFields: SearchSuggestionConfiguration.ObjectFields? = nil
    ) throws -> [SearchSuggestion] {
        let entries: [SearchSuggestion]
        switch format {
        case .objects:
            if let fields = objectFields {
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw URLError(.cannotParseResponse)
                }
                entries = rows.compactMap { row in
                    guard let text = row[fields.text] as? String else { return nil }
                    return .init(
                        text: text,
                        namespace: fields.namespace.flatMap { row[$0] as? String },
                        count: fields.count.flatMap { row[$0] as? Int }
                    )
                }
            } else {
                entries = try JSONDecoder().decode([SearchSuggestion].self, from: data)
            }
        case .strings:
            entries = try JSONDecoder().decode([String].self, from: data).map { .init(text: $0) }
        case .tuples:
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
                throw URLError(.cannotParseResponse)
            }
            entries = rows.compactMap { row in
                guard let text = row.first as? String else { return nil }
                let count = row.count > 1 ? row[1] as? Int : nil
                let namespace = row.count > 2 ? row[2] as? String : nil
                return .init(text: text, namespace: namespace, count: count)
            }
        case .openSearch:
            guard let response = try JSONSerialization.jsonObject(with: data) as? [Any],
                  response.count > 1, let texts = response[1] as? [String]
            else { throw URLError(.cannotParseResponse) }
            entries = texts.map { .init(text: $0) }
        }
        var seen: Set<[String]> = []
        return Array(entries.map { entry in
            var entry = entry
            if let namespace = entry.namespace {
                entry.namespace = namespaceMappings?[namespace] ?? namespace
            }
            if hideCounts { entry.count = nil }
            return entry
        }.filter { entry in
            guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.text.count <= 200,
                  !entry.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  entry.namespace?.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) ?? true
            else { return false }
            return seen.insert([entry.namespace ?? "", entry.text]).inserted
        }.prefix(10))
    }
}

/// Keep source networking preferences while isolating suggestion cookies and cache.
actor SearchSuggestionHTTPClient {
    private var session: URLSession?
    private var bypass: Bool?

    deinit { session?.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let enabled = SourceNetwork.isEnabled
        if session == nil || bypass != enabled {
            let settings = URLSessionConfiguration.ephemeral
            settings.httpCookieStorage = nil
            settings.httpShouldSetCookies = false
            settings.urlCache = nil
            let config = try await SourceNetwork.shared.configuration(settings, bypass: enabled)
            // A second request may have created the session while configuration awaited.
            if session == nil || bypass != enabled {
                session?.finishTasksAndInvalidate()
                session = URLSession(configuration: config)
                bypass = enabled
            }
        }
        guard let session else { throw URLError(.unknown) }
        return try await session.data(for: request)
    }
}

/// Shared across search screens so reopening one cannot reset an API's rate limit.
actor SearchSuggestionRequestThrottle {
    static let shared = SearchSuggestionRequestThrottle()
    private var nextRequests: [URL: TimeInterval] = [:]

    func wait(for url: URL, milliseconds: Int) async throws {
        while let next = nextRequests[url], next > ProcessInfo.processInfo.systemUptime {
            try await Task.sleep(nanoseconds: UInt64(max(0, next - ProcessInfo.processInfo.systemUptime) * 1_000_000_000))
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        if nextRequests.count >= 64 {
            nextRequests = nextRequests.filter { $0.value > ProcessInfo.processInfo.systemUptime }
        }
        if milliseconds > 0 {
            nextRequests[url] = ProcessInfo.processInfo.systemUptime + Double(min(milliseconds, 60_000)) / 1000
        }
    }

    func deferRequests(for url: URL, seconds: Double) {
        let next = ProcessInfo.processInfo.systemUptime + max(1, min(seconds, 300))
        nextRequests[url] = max(nextRequests[url] ?? 0, next)
    }
}
