import Foundation
import Network

/// Bounded, TTL-aware DNS-over-HTTPS resolution with IP bootstrap addresses.
/// It does not inherit the source proxy or fall back to unencrypted public DNS.
actor HTTPSDNSResolver {
    static let shared = HTTPSDNSResolver()
    struct Answer: Decodable, Sendable {
        let type: Int
        let TTL: Int
        let data: String
    }
    struct Response: Decodable, Sendable {
        let Status: Int
        let TC: Bool?
        let Answer: [HTTPSDNSResolver.Answer]?
    }
    private struct Entry {
        let addresses: [String]
        let expires: Date
        var accessed: Date
    }
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.httpMaximumConnectionsPerHost = 6
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<Entry, Error>] = [:]

    func addresses(for host: String) async throws -> [String] {
        try Task.checkCancellation()
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if var entry = entries[host], entry.expires > Date() {
            entry.accessed = Date(); entries[host] = entry
            return entry.addresses
        }
        if let task = pending[host] { return try await task.value.addresses }
        let task = Task { () throws -> Entry in
            async let ipv4 = try? query(host: host, type: "A")
            async let ipv6 = try? query(host: host, type: "AAAA")
            let responses = await [ipv4, ipv6].compactMap { $0 }
            let answers = responses.flatMap { $0.Answer ?? [] }
            let addresses = Self.validAddresses(answers)
            guard !addresses.isEmpty else { throw URLError(.cannotFindHost) }
            let ttl = max(0, min(3_600, answers.map(\.TTL).min() ?? 0))
            return Entry(addresses: addresses, expires: Date().addingTimeInterval(TimeInterval(ttl)), accessed: Date())
        }
        pending[host] = task
        defer { pending[host] = nil }
        let entry = try await task.value
        if entries.count >= 512, let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key { entries[oldest] = nil }
        entries[host] = entry
        try Task.checkCancellation()
        return entry.addresses
    }

    static func validAddresses(_ answers: [Answer]) -> [String] {
        var seen: Set<String> = []
        return answers.compactMap { answer in
            let valid = (answer.type == 1 && IPv4Address(answer.data) != nil) || (answer.type == 28 && IPv6Address(answer.data) != nil)
            return valid && seen.insert(answer.data).inserted ? answer.data : nil
        }
    }

    private func query(host: String, type: String) async throws -> Response {
        var failure: Error = URLError(.cannotFindHost)
        for server in ["1.1.1.1", "1.0.0.1"] {
            try Task.checkCancellation()
            var components = URLComponents()
            components.scheme = "https"; components.host = server; components.path = "/dns-query"
            components.queryItems = [.init(name: "name", value: host), .init(name: "type", value: type)]
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      response.expectedContentLength <= 65_536 else { throw URLError(.badServerResponse) }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                let result = try JSONDecoder().decode(Response.self, from: data)
                guard result.Status == 0, result.TC != true else { throw URLError(.cannotFindHost) }
                return result
            } catch is CancellationError { throw CancellationError() } catch { failure = error }
        }
        throw failure
    }
}
