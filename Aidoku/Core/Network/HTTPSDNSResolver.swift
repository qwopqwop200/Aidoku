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
    private struct Pending {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<[String], Error>]
    }
    typealias Query = @Sendable (String, String) async throws -> Response
    private let query: Query
    private var entries: [String: Entry] = [:]
    private var pending: [String: Pending] = [:]
    init(session: URLSession) {
        query = { try await Self.query(host: $0, type: $1, session: session) }
    }

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.httpMaximumConnectionsPerHost = 6
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        self.init(session: URLSession(configuration: config))
    }

    func addresses(for host: String) async throws -> [String] {
        try Task.checkCancellation()
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if var entry = entries[host], entry.expires > Date() {
            entry.accessed = Date(); entries[host] = entry
            return entry.addresses
        }
        let id = UUID()
        let addresses: [String] = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if pending[host] != nil {
                    pending[host]?.waiters[id] = continuation
                } else {
                    let task = Task { await resolve(host: host, id: id) }
                    pending[host] = Pending(id: id, task: task, waiters: [id: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancel(host: host, waiter: id) }
        }
        try Task.checkCancellation()
        return addresses
    }

    private func cancel(host: String, waiter: UUID) {
        guard let continuation = pending[host]?.waiters.removeValue(forKey: waiter) else { return }
        if pending[host]?.waiters.isEmpty == true { pending.removeValue(forKey: host)?.task.cancel() }
        continuation.resume(throwing: CancellationError())
    }

    private func resolve(host: String, id: UUID) async {
        guard !Task.isCancelled else { return }
        async let ipv4 = try? query(host, "A")
        async let ipv6 = try? query(host, "AAAA")
        let answers = await [ipv4, ipv6].compactMap { $0 }.flatMap { $0.Answer ?? [] }
        // A disconnected tunnel can be replaced while its transport is unwinding.
        guard pending[host]?.id == id, let lookup = pending.removeValue(forKey: host) else { return }
        let addresses = Self.validAddresses(answers)
        guard !addresses.isEmpty else {
            for waiter in lookup.waiters.values { waiter.resume(throwing: URLError(.cannotFindHost)) }
            return
        }
        let ttl = max(0, min(3_600, answers.map(\.TTL).min() ?? 0))
        let now = Date()
        if entries.count >= 512, let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key { entries[oldest] = nil }
        entries[host] = Entry(addresses: addresses, expires: now.addingTimeInterval(TimeInterval(ttl)), accessed: now)
        for waiter in lookup.waiters.values { waiter.resume(returning: addresses) }
    }

    static func validAddresses(_ answers: [Answer]) -> [String] {
        var seen: Set<String> = []
        return answers.compactMap { answer in
            let valid = (answer.type == 1 && IPv4Address(answer.data) != nil) || (answer.type == 28 && IPv6Address(answer.data) != nil)
            return valid && seen.insert(answer.data).inserted ? answer.data : nil
        }
    }

    private static func query(host: String, type: String, session: URLSession) async throws -> Response {
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
                let transfer = bytes.task
                defer { transfer.cancel() }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      response.expectedContentLength <= 65_536 else { throw URLError(.badServerResponse) }
                let data = try await withTaskCancellationHandler {
                    var data = Data()
                    for try await byte in bytes {
                        guard data.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
                        data.append(byte)
                    }
                    try Task.checkCancellation()
                    return data
                } onCancel: { transfer.cancel() }
                let result = try JSONDecoder().decode(Response.self, from: data)
                guard result.Status == 0, result.TC != true else { throw URLError(.cannotFindHost) }
                return result
            } catch is CancellationError { throw CancellationError() } catch { failure = error }
        }
        throw failure
    }
}
