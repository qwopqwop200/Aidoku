import XCTest
import Wasm3
@testable import Aidoku

final class AuditSourceBoundaryRegressionTests: XCTestCase {
    func testLegacyNetworkChunksDoNotRepeatEarlierBytes() {
        let response = WasmResponseObject(data: Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(response.readData(count: 2), Data([1, 2]))
        XCTAssertEqual(response.readData(count: 2), Data([3, 4]))
        XCTAssertNil(response.readData(count: 2))
        XCTAssertEqual(response.bytesRead, 4)
        XCTAssertEqual(response.readData(count: 1), Data([5]))
        XCTAssertNil(response.readData(count: 1))
    }

    func testDuplicateMarkersAfterEmojiUseUTF16Ranges() {
        let prefix = String(repeating: "👩‍👩‍👧‍👦", count: 20)
        XCTAssertEqual(LocalFileNameParser.parseMangaVolume(from: prefix + " Vol 4 ch 2 - vol 6 omakes.cbz"), "4")
        XCTAssertEqual(LocalFileNameParser.parseMangaChapter(from: prefix + " ch 2 - ch 6 extras.cbz"), "2")
    }

    func testOversizedCustomSourceStringLengthThrows() {
        let encoded = Data([1] + Array(repeating: UInt8(0xff), count: 9) + [0x01])
        XCTAssertThrowsError(try CustomSourceConfig(from: encoded))
    }

    func testNonfiniteSuwayomiDatesAreRejected() {
        XCTAssertNil(Date(suwayomiTimestamp: "nan"))
        XCTAssertNil(Date(suwayomiTimestamp: "inf"))
        XCTAssertEqual(Date(suwayomiTimestamp: "1000"), Date(timeIntervalSince1970: 1000))
    }

    @MainActor
    func testConcurrentLegacyRequestsWaitForOneInitialization() async throws {
        let (source, directory) = try legacyInitializationFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await source.getImageRequest(url: "") }
            }
            try await group.waitForAll()
        }
        let count: Int32 = try source.globalStore.vm.findFunction(name: "count").call()
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testLegacyInitializationTrapPropagatesToRequests() async throws {
        let (source, directory) = try legacyInitializationFixture(traps: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await source.getImageRequest(url: "")
            XCTFail("A failed initializer must prevent source requests")
        } catch {
            // The initializer's unreachable instruction is a real wasm execution failure.
        }
    }

    @MainActor
    func testLegacyOptionalInitializerAndCompletedTaskReleaseSource() async throws {
        var (source, directory): (Source?, URL) = try legacyInitializationFixture(omitsInitializer: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var releasedSource = source
        _ = try await source?.getImageRequest(url: "")
        source = nil
        for _ in 0..<20 where releasedSource != nil { await Task.yield() }
        XCTAssertNil(releasedSource)
    }

    private func legacyInitializationFixture(traps: Bool = false, omitsInitializer: Bool = false) throws -> (Source, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = #"{"info":{"id":"audit.initialization","lang":"en","name":"Audit","version":1}}"#
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("source.json"))
        var bytes: [UInt8] = [0, 97, 115, 109, 1, 0, 0, 0]
        func section(_ id: UInt8, _ payload: [UInt8]) { bytes += [id, UInt8(payload.count)] + payload }
        section(1, [2, 0x60, 0, 0, 0x60, 0, 1, 0x7f])
        section(3, [2, 0, 1])
        section(6, [1, 0x7f, 1, 0x41, 0, 0x0b])
        let countExport: [UInt8] = [5] + Array("count".utf8) + [0, 1]
        section(7, omitsInitializer ? [1] + countExport : [2, 10] + Array("initialize".utf8) + [0, 0] + countExport)
        let initializer: [UInt8] = traps ? [0, 0, 0x0b] : [0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x0b]
        section(10, [2, UInt8(initializer.count)] + initializer + [4, 0, 0x23, 0, 0x0b])
        try Data(bytes).write(to: directory.appendingPathComponent("main.wasm"))
        return (try Source(from: directory), directory)
    }

}
