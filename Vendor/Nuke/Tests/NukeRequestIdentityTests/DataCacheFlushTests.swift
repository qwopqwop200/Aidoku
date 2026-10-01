import Foundation
import Testing
@testable import Nuke

struct DataCacheFlushTests {
    @Test func flushingOneKeyPreservesWritesFollowingRemoveAll() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = try DataCache(path: directory)
        cache.flushInterval = .seconds(60)
        defer { cache.removeAll(); cache.flush(); try? FileManager.default.removeItem(at: directory) }

        cache.storeData(Data("old".utf8), for: "old")
        cache.flush()
        cache.removeAll()
        let first = Data("first-new-bytes".utf8)
        let second = Data("second-new-bytes".utf8)
        cache.storeData(first, for: "first")
        cache.storeData(second, for: "second")

        cache.flush(for: "first")
        #expect(cache.cachedData(for: "first") == first)
        #expect(cache.cachedData(for: "second") == second)
        #expect(cache.cachedData(for: "old") == nil)
        cache.flush()
        #expect(try Data(contentsOf: #require(cache.url(for: "first"))) == first)
        #expect(try Data(contentsOf: #require(cache.url(for: "second"))) == second)
        #expect(cache.cachedData(for: "old") == nil)
    }
}
