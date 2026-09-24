import Foundation
import Network
import XCTest
@testable import Aidoku

final class KavitaRegistrationProgressRegressionTests: XCTestCase {
    func testRegistrationKeepsEstablishedBackwardProgressUntouched() async throws {
        try await verify(remote: 10, local: 5, expectedPosts: 0)
    }
    func testRegistrationKeepsEqualProgressUntouched() async throws {
        try await verify(remote: 5, local: 5, expectedPosts: 0)
    }
    func testRegistrationKeepsEstablishedForwardProgressUntouched() async throws {
        // Registration initializes absent progress; regular update performs later advancement.
        try await verify(remote: 2, local: 5, expectedPosts: 0)
    }
    func testRegistrationPreservesInitialProgressPayload() async throws {
        try await verify(remote: 0, local: 5, expectedPosts: 1)
    }
    private func verify(remote: Int, local: Float, expectedPosts: Int) async throws {
        let server = try await KavitaRegistrationServer(remote: remote, expectedPosts: expectedPosts)
        defer { server.stop() }
        let source = "round2-kavita-" + UUID().uuidString
        let bypassKey = SourceNetwork.enabledKey
        let originalBypass = UserDefaults.standard.object(forKey: bypassKey)
        UserDefaults.standard.set(false, forKey: bypassKey)
        UserDefaults.standard.set("http://127.0.0.1:\(server.port)/", forKey: "\(source).server")
        UserDefaults.standard.set("fixture", forKey: "\(source).token")
        defer {
            ["server", "token"].forEach { UserDefaults.standard.removeObject(forKey: "\(source).\($0)") }
            if let originalBypass { UserDefaults.standard.set(originalBypass, forKey: bypassKey) }
            else { UserDefaults.standard.removeObject(forKey: bypassKey) }
        }
        _ = try await KavitaTracker().register(trackId: source + "|42", highestChapterRead: local, earliestReadDate: nil)
        XCTAssertEqual(server.counts.snapshot().posts, expectedPosts)
        XCTAssertEqual(server.counts.snapshot().gets, 2, "Both real Kavita getState requests must reach the local fixture")
        XCTAssertEqual(server.counts.snapshot().invalid, 0)
    }
}

/// KavitaHelper creates custom URLSession instances, which do not use globally registered
/// URLProtocol classes. A bound loopback HTTP server exercises that unchanged path.
private final class KavitaRegistrationServer: @unchecked Sendable {
    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var posts = 0
        private var gets = 0
        private var invalid = 0
        func record(post: Bool, valid: Bool) {
            lock.lock(); defer { lock.unlock() }
            if post { posts += 1 } else { gets += 1 }
            if !valid { invalid += 1 }
        }
        func snapshot() -> (posts: Int, gets: Int, invalid: Int) {
            lock.lock(); defer { lock.unlock() }; return (posts, gets, invalid)
        }
    }
    let counts = Counts()
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }
    private let queue = DispatchQueue(label: "round2.kavita.registration.fixture")
    private var clients: [NWConnection] = []
    private let remote: Int
    private let expectedPosts: Int
    init(remote: Int, expectedPosts: Int) async throws {
        self.remote = remote; self.expectedPosts = expectedPosts
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.clients.append(connection)
            connection.start(queue: self.queue)
            self.read(connection, accumulated: Data())
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
    func stop() {
        queue.async { self.listener.cancel(); self.clients.forEach { $0.cancel() }; self.clients = [] }
    }
    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.count <= 16384, error == nil else { connection.cancel(); return }
            guard let divider = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done { connection.cancel() } else { self.read(connection, accumulated: buffer) }
                return
            }
            let header = String(decoding: buffer[..<divider.lowerBound], as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard length >= 0, length < 8192 else { connection.cancel(); return }
            guard buffer.count >= divider.upperBound + length else {
                if done { connection.cancel() } else { self.read(connection, accumulated: buffer) }
                return
            }
            let body = buffer[divider.upperBound..<(divider.upperBound + length)]
            let requestLine = lines[0].split(separator: " ").map(String.init)
            let method = requestLine.first ?? ""
            let path = requestLine.count > 1 ? requestLine[1] : ""
            let authorized = lines.contains { $0.lowercased() == "authorization: bearer fixture" }
            var valid = authorized
            var payload = "[]"
            var status = 200
            if method == "POST" {
                valid = valid && self.expectedPosts == 1 && path == "/api/Tachiyomi/mark-chapter-until-as-read?seriesId=42&chapterNumber=5.0" && Data(body) == Data("{}".utf8)
                payload = "true"
            } else if path == "/api/Tachiyomi/latest-chapter?seriesId=42" {
                payload = "{\"id\":1,\"number\":\"\(self.remote)\",\"title\":\"fixture\",\"createdUtc\":\"2026-01-01T00:00:00\",\"pages\":10,\"pagesRead\":10,\"lastReadingProgressUtc\":\"2026-01-01T00:00:00\",\"files\":[]}"
            } else { valid = valid && method == "GET" && path == "/api/Series/volumes?seriesId=42" }
            self.counts.record(post: method == "POST", valid: valid)
            if !valid { status = 422 }
            let response = "HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n" + payload
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
