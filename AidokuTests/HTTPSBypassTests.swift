import Foundation
import Network
import Nuke
import Testing
import WebKit
@testable import Aidoku

@Suite(.serialized)
struct HTTPSBypassTests {
    @Test func splitsInsideSNIWithoutChangingTheHandshakeOrFollowingRecords() throws {
        let original = hello()
        let trailing = Data([20, 3, 3, 0, 1, 1])
        guard case .split(let first, let second) = TLSClientHello.inspect(original + trailing) else {
            Issue.record("Expected a fragmented ClientHello"); return
        }
        #expect(!first.contains(Data("reader.example.org".utf8)))
        #expect(!second.contains(Data("reader.example.org".utf8)))
        #expect(try payloads(first + second) == payloads(original + trailing))
        #expect(second.suffix(trailing.count) == trailing)
        #expect(first.count + second.count == original.count + trailing.count + 5)
    }

    @Test func waitsForEveryPossibleTCPBoundary() {
        let data = hello()
        for end in 0..<data.count {
            #expect(TLSClientHello.inspect(Data(data.prefix(end))) == .incomplete)
        }
    }

    @Test func clientHelloAlreadySpanningRecordsIsReassembledSafely() throws {
        let payload = try payloads(hello())
        let records = record(Data(payload.prefix(20))) + record(Data(payload.dropFirst(20)))
        guard case .split(let first, let second) = TLSClientHello.inspect(records) else {
            Issue.record("Expected a split after reassembling ClientHello records"); return
        }
        #expect(try payloads(first + second) == payload)
    }

    @Test func nonTLSMissingSNIAndInvalidLengthsPassThroughUnmodified() {
        #expect(TLSClientHello.inspect(Data("GET / HTTP/1.1\r\n".utf8)) == .passthrough)
        #expect(TLSClientHello.inspect(hello(name: nil)) == .passthrough)
        #expect(TLSClientHello.inspect(Data([22, 3, 3, 255, 255])) == .passthrough)
        #expect(TLSClientHello.inspect(Data(repeating: 22, count: TLSClientHello.maximumBytes + 1)) == .passthrough)
        var invalid = hello()
        invalid[5] = 2
        #expect(TLSClientHello.inspect(invalid) == .passthrough)
        // Each damaged length/direction byte must remain bounded and never trap.
        for index in 0..<hello().count {
            var malformed = hello(); malformed[index] = 255
            _ = TLSClientHello.inspect(malformed)
        }
    }

    @Test func startsOnLoopbackAndCanRestart() async throws {
        let proxy = HTTPSBypassProxy()
        defer { proxy.stop() }
        let first = try await proxy.start()
        guard case .hostPort(let host, let port) = first else { Issue.record("Expected loopback endpoint"); return }
        #expect(host == .ipv4(.loopback))
        #expect(port.rawValue > 0)
        #expect(try await proxy.start() == first)
        proxy.stop()
        let restarted = try await proxy.start()
        guard case .hostPort(let newHost, _) = restarted else { Issue.record("Expected restarted loopback endpoint"); return }
        #expect(newHost == .ipv4(.loopback))
    }

    @Test func bypassConfigurationIsExplicitAndNeverFallsBackDirectly() async throws {
        let network = SourceNetwork()
        let direct = try await network.configuration(.ephemeral, bypass: false)
        #expect(direct.proxyConfigurations.isEmpty)
        let bypass = try await network.configuration(.ephemeral, bypass: true)
        #expect(bypass.proxyConfigurations.count == 1)
        #expect(bypass.proxyConfigurations.first?.allowFailover == false)
        #expect(bypass.httpCookieStorage === direct.httpCookieStorage || bypass.httpCookieStorage != nil)
    }

    @Test func switchChangesNewSourceAndImageSessionsWithoutReplacingCaches() async throws {
        let flag = Flag()
        let network = SourceNetwork(enabled: { flag.value })
        let direct = try await network.session()
        let directLoader = try await network.imageLoader()
        #expect(direct === URLSession.shared)
        flag.value = true
        let protected = try await network.session()
        let protectedLoader = try await network.imageLoader()
        #expect(protected.configuration.proxyConfigurations.count == 1)
        #expect(protectedLoader !== directLoader)
        #expect(try await network.session() === protected)
        flag.value = false
        #expect(try await network.session() === direct)
        #expect(try await network.imageLoader() === directLoader)
        flag.value = true
        #expect(try await network.imageLoader() === protectedLoader)
    }

    @Test func DNSAnswersAcceptOnlyLiteralAddressesOfTheDeclaredFamily() {
        let answers: [HTTPSDNSResolver.Answer] = [
            .init(type: 5, TTL: 20, data: "alias.example"),
            .init(type: 1, TTL: 20, data: "192.0.2.1"),
            .init(type: 1, TTL: 20, data: "192.0.2.1"),
            .init(type: 28, TTL: 20, data: "2001:db8::1"),
            .init(type: 1, TTL: 20, data: "not.an.ip"),
            .init(type: 28, TTL: 20, data: "192.0.2.2")
        ]
        #expect(HTTPSDNSResolver.validAddresses(answers) == ["192.0.2.1", "2001:db8::1"])
    }

    @Test func SOCKSRejectsUnauthenticatedMethodMismatchAndUnsupportedCommands() async throws {
        let proxy = HTTPSBypassProxy()
        defer { proxy.stop() }
        let endpoint = try await proxy.start()
        let first = try await Client(endpoint)
        defer { first.connection.cancel() }
        try await first.send(Data([5, 1, 2]))
        #expect(try await first.receive(2) == Data([5, 255]))
        let second = try await Client(endpoint)
        defer { second.connection.cancel() }
        // Greeting arrives one byte at a time.
        for byte: UInt8 in [5, 1, 0] { try await second.send(Data([byte])) }
        #expect(try await second.receive(2) == Data([5, 0]))
        try await second.send(Data([5, 3, 0, 1])) // UDP ASSOCIATE is not supported.
        let rejected = try await second.receive(10)
        #expect(rejected[1] != 0)
    }

    @Test func halfClosedRequestsStillReceiveTheWholeResponse() async throws {
        let server = try await EOFServer()
        defer { server.stop() }
        let proxy = HTTPSBypassProxy()
        defer { proxy.stop() }
        let client = try await Client(proxy.start())
        defer { client.connection.cancel() }
        try await client.send(Data([5, 1, 0]))
        #expect(try await client.receive(2) == Data([5, 0]))
        let port = try #require(server.listener.port).rawValue
        try await client.send(Data([5, 1, 0, 1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255)]))
        #expect(try await client.receive(10)[1] == 0)
        let body = Data(repeating: 65, count: 100_000)
        try await client.send(body)
        try await client.finish()
        // The server deliberately waits for EOF before sending its response.
        #expect(try await client.receive(5) == Data("reply".utf8))
        #expect(server.received == body.count)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIDOKU_LIVE_BYPASS_TESTS"] == "1"))
    func liveTLSAndCertificateValidation() async throws {
        let network = SourceNetwork()
        for address in ["https://www.cloudflare.com", "https://www.apple.com"] {
            let result = try await network.test(url: #require(URL(string: address)))
            #expect((200..<400).contains(result.status))
            #expect(result.fragmented)
        }
        do {
            _ = try await network.test(url: #require(URL(string: "https://expired.badssl.com")))
            Issue.record("Expired server certificates must remain rejected")
        } catch {
            #expect([NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted].contains((error as NSError).code))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIDOKU_LIVE_BYPASS_TESTS"] == "1"))
    func liveImageDataLoaderStreamsThroughTheProxy() async throws {
        let network = SourceNetwork(enabled: { true })
        let loader = SourceImageDataLoader(network: network)
        let size = Counter()
        let request = URLRequest(url: try #require(URL(string: "https://www.cloudflare.com/favicon.ico")))
        var operation: (any Cancellable)?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation = loader.loadData(with: request, didReceiveData: { data, response in
                size.add(data.count)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
            }, completion: { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        operation?.cancel()
        #expect(size.value > 0)
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["AIDOKU_LIVE_BYPASS_TESTS"] == "1"))
    func liveWebKitUsesTheSameProxy() async throws {
        let proxy = HTTPSBypassProxy()
        defer { proxy.stop() }
        let endpoint = try await proxy.start()
        let store = WKWebsiteDataStore.nonPersistent()
        var config = ProxyConfiguration(socksv5Proxy: endpoint)
        config.allowFailover = false
        store.proxyConfigurations = [config]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let delegate = Navigation()
        view.navigationDelegate = delegate
        view.load(URLRequest(url: try #require(URL(string: "https://www.cloudflare.com/cdn-cgi/trace"))))
        let deadline = Date().addingTimeInterval(30)
        while !delegate.finished && delegate.error == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        if let error = delegate.error { throw error }
        #expect(delegate.finished)
        #expect(await proxy.fragmentCount() > 0)
        view.stopLoading()
    }

    private func hello(name: String? = "reader.example.org") -> Data {
        var extensions: [UInt8] = [0, 43, 0, 3, 2, 3, 4] // supported_versions before SNI
        if let name {
            let host = Array(name.utf8)
            let list = [UInt8(0)] + u16(host.count) + host
            let body = u16(list.count) + list
            extensions += [0, 0] + u16(body.count) + body
        }
        let body: [UInt8] = [3, 3] + Array(repeating: 0, count: 32) + [0, 0, 2, 0x13, 1, 1, 0] + u16(extensions.count) + extensions
        return record(Data([1, 0, UInt8(body.count >> 8), UInt8(body.count & 255)] + body))
    }

    private func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }
    private func record(_ body: Data) -> Data { Data([22, 3, 1] + u16(body.count)) + body }
    private func payloads(_ data: Data) throws -> Data {
        var cursor = 0
        var result = Data()
        while cursor < data.count {
            try #require(cursor + 5 <= data.count)
            let size = Int(data[cursor + 3]) * 256 + Int(data[cursor + 4])
            try #require(cursor + 5 + size <= data.count)
            result.append(data[(cursor + 5)..<(cursor + 5 + size)])
            cursor += 5 + size
        }
        return result
    }

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        init(_ endpoint: NWEndpoint) async throws {
            connection = NWConnection(to: endpoint, using: .tcp)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                        case .ready: connection.stateUpdateHandler = nil; continuation.resume()
                        case .failed(let error): connection.stateUpdateHandler = nil; continuation.resume(throwing: error)
                        default: break
                    }
                }
                connection.start(queue: .global())
            }
        }
        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
        func receive(_ count: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
                }
            }
        }
        func finish() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
    }

    private final class EOFServer: @unchecked Sendable {
        let listener: NWListener
        private let queue = DispatchQueue(label: "AidokuTests.EOFServer")
        private let size = Counter()
        private var clients: [NWConnection] = []
        var received: Int { size.value }
        init() async throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.clients.append(connection)
                connection.start(queue: self.queue)
                self.read(connection)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { [listener] state in
                    switch state {
                        case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                        case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                        default: break
                    }
                }
                listener.start(queue: queue)
            }
        }
        func stop() { queue.async { self.listener.cancel(); self.clients.forEach { $0.cancel() }; self.clients = [] } }
        private func read(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { self.size.add(data.count) }
                if error != nil { connection.cancel() } else if done {
                    connection.send(content: Data("reply".utf8), contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in })
                } else { self.read(connection) }
            }
        }
    }

    @MainActor private final class Navigation: NSObject, WKNavigationDelegate {
        var finished = false
        var error: Error?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add(_ value: Int) { lock.lock(); count += value; lock.unlock() }
    }
}
