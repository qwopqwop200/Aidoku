import Testing
@testable import Aidoku

@MainActor struct ReaderPageControllerStoreTests {
    @Test func lazyIdentityAndSplitInsertionPreserveControllers() throws {
        let store = ReaderPageControllerStore()
        var made = 0
        for _ in 0..<1000 {
            store.appendDeferred {
                made += 1
                return ReaderPageViewController(type: .info(.next), delegate: nil)
            }
        }
        #expect(made == 0)
        let end = store[999]
        #expect(store[999] === end)
        #expect(made == 1)
        #expect(store.firstIndex(of: end) == 999)
        #expect(store.materialized.count == 1)
        let inserted = ReaderPageViewController(type: .info(.previous), delegate: nil)
        store.insert(contentsOf: [inserted], at: 500)
        #expect(store.firstIndex(of: end) == 1000)
        #expect(store.firstIndex(of: inserted) == 500)
        #expect(store[1000] === end)
        #expect(made == 1)
        _ = store[499]
        #expect(made == 2)
        #expect(store.materialized.map { $0.0 } == [499, 500, 1000])
    }
}
