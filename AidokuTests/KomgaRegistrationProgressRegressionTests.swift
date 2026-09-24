import Foundation
import XCTest
@testable import Aidoku

/// Replay-only regression: no real tracker account/network, unique defaults restored.
final class KomgaRegistrationProgressRegressionTests: XCTestCase {
    func testRegistrationDoesNotMoveRemoteChapterProgressBackwards() async throws {
        try await verify(useChapters: true, remote: 10, local: 5, expectedUpdate: nil)
    }
    func testRegistrationDoesNotMoveRemoteVolumeProgressBackwards() async throws {
        try await verify(useChapters: false, remote: 10, local: 5, expectedUpdate: nil)
    }
    func testRegistrationLeavesEqualProgressUntouched() async throws {
        for chapters in [true, false] {
            try await verify(useChapters: chapters, remote: 5, local: 5, expectedUpdate: nil)
        }
    }
    func testRegistrationPreservesValidForwardUpdatePayload() async throws {
        for chapters in [true, false] {
            try await verify(useChapters: chapters, remote: 2, local: 5, expectedUpdate: 5)
        }
    }

    private func verify(useChapters: Bool, remote: Int, local: Float, expectedUpdate: Int?) async throws {
        XCTAssertTrue(URLProtocol.registerClass(KomgaRegistrationReplay.self))
        defer { URLProtocol.unregisterClass(KomgaRegistrationReplay.self) }
        let source = "round2-komga-" + UUID().uuidString
        KomgaRegistrationReplay.counts.reset()
        let keys = ["server", "login.username", "login.password", "useChapters"]
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: "\(source).\($0)") } }
        // Encode response state in the path; a locked counter verifies PUT presence.
        let expected = expectedUpdate.map(String.init) ?? "none"
        UserDefaults.standard.set("https://komga-registration-round2.invalid/\(remote)/\(expected)/", forKey: "\(source).server")
        UserDefaults.standard.set("fixture", forKey: "\(source).login.username")
        UserDefaults.standard.set("fixture", forKey: "\(source).login.password")
        UserDefaults.standard.set(useChapters, forKey: "\(source).useChapters")
        // Unexpected PUT receives HTTP409 so the production API throws and this test fails.
        _ = try await KomgaTracker().register(trackId: source + "|1", highestChapterRead: local, earliestReadDate: nil)
        XCTAssertEqual(KomgaRegistrationReplay.counts.value(), expectedUpdate == nil ? 0 : 1)
    }
}

private final class KomgaRegistrationReplay: URLProtocol {
    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var puts = 0
        func reset() { lock.lock(); defer { lock.unlock() }; puts = 0 }
        func increment() { lock.lock(); defer { lock.unlock() }; puts += 1 }
        func value() -> Int { lock.lock(); defer { lock.unlock() }; return puts }
    }
    static let counts = Counts()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "komga-registration-round2.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count >= 2 else { return }
        var status = 200
        let data: Data
        if request.httpMethod == "PUT" {
            Self.counts.increment()
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            if path[1] == "none" { status = 409 }
            else if body != Data("{\"lastBookNumberSortRead\":\(path[1])}".utf8) { status = 422 }
            data = Data()
        } else {
            data = Data("{\"lastReadContinuousNumberSort\":\(path[0]),\"maxNumberSort\":20}".utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
