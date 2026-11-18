import Foundation
import Testing
@testable import Aidoku

struct HTTPSDNSResolverTests {
    @Test func lastDisconnectStopsStalledURLSessionTransfers() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StalledDNSProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let resolver = HTTPSDNSResolver(session: session)
        let host = UUID().uuidString.lowercased() + ".example"
        let lookup = Task { try await resolver.addresses(for: host) }
        try await waitUntil { StalledDNSProtocol.observation.started(host) == 2 }
        lookup.cancel()
        await #expect(throws: CancellationError.self) { try await lookup.value }
        try await waitUntil { StalledDNSProtocol.observation.stopped(host) == 2 }
    }

    @Test func disconnectReleasesOnlyItsOwnWaiter() async throws {
        let server = SuspendedQueries()
        let resolver = HTTPSDNSResolver(query: { await server.query(host: $0, type: $1) })
        let first = Task { try await resolver.addresses(for: "DNS.Example.") }
        let survivor = Task { try await resolver.addresses(for: "dns.example") }
        try await waitUntil { await resolver.waitingConnectionCount == 2 }
        try await waitUntil { await server.started == 2 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await server.cancelled == 0)
        await server.finish(generation: 1)
        #expect(try await survivor.value == ["192.0.2.1", "2001:db8::1"])
        #expect(try await resolver.addresses(for: "dns.example") == ["192.0.2.1", "2001:db8::1"])
        #expect(await server.started == 2)
    }

    @Test func lastDisconnectCancelsBothQueriesAndLateAnswersCannotReplaceFreshLookup() async throws {
        let server = SuspendedQueries()
        let resolver = HTTPSDNSResolver(query: { await server.query(host: $0, type: $1) })
        let abandoned = Task { try await resolver.addresses(for: "dns.example") }
        try await waitUntil { await server.started == 2 }
        abandoned.cancel()
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        try await waitUntil { await server.cancelled == 2 }

        let fresh = Task { try await resolver.addresses(for: "dns.example") }
        try await waitUntil { await server.started == 4 }
        await server.finish(generation: 1)
        await server.finish(generation: 2)
        #expect(try await fresh.value == ["192.0.2.2", "2001:db8::2"])
        #expect(try await resolver.addresses(for: "dns.example") == ["192.0.2.2", "2001:db8::2"])
        #expect(await server.started == 4)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }

    private actor SuspendedQueries {
        private var calls: [String: Int] = [:]
        private var pending: [Int: [String: CheckedContinuation<HTTPSDNSResolver.Response, Never>]] = [:]
        var started: Int { calls.values.reduce(0, +) }
        private(set) var cancelled = 0

        func query(host: String, type: String) async -> HTTPSDNSResolver.Response {
            #expect(host == "dns.example")
            let generation = calls[type, default: 0] + 1
            calls[type] = generation
            // Model a transport that delivers a buffered reply even after cancellation.
            return await withTaskCancellationHandler {
                await withCheckedContinuation { pending[generation, default: [:]][type] = $0 }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }

        private func recordCancellation() { cancelled += 1 }

        func finish(generation: Int) {
            for (type, continuation) in pending.removeValue(forKey: generation) ?? [:] {
                let ipv4 = type == "A"
                let answer = HTTPSDNSResolver.Answer(type: ipv4 ? 1 : 28, TTL: 60,
                                                     data: ipv4 ? "192.0.2.\(generation)" : "2001:db8::\(generation)")
                continuation.resume(returning: .init(Status: 0, TC: false, Answer: [answer]))
            }
        }
    }
}

private final class StalledDNSProtocol: URLProtocol, @unchecked Sendable {
    final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [String: Int] = [:]
        private var stops: [String: Int] = [:]
        func start(_ host: String) { lock.withLock { starts[host, default: 0] += 1 } }
        func stop(_ host: String) { lock.withLock { stops[host, default: 0] += 1 } }
        func started(_ host: String) -> Int { lock.withLock { starts[host, default: 0] } }
        func stopped(_ host: String) -> Int { lock.withLock { stops[host, default: 0] } }
    }
    static let observation = Observation()
    private var host: String {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first(where: { $0.name == "name" })?.value ?? ""
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "65536"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 32768))
        Self.observation.start(host)
    }
    override func stopLoading() { Self.observation.stop(host) }
}
