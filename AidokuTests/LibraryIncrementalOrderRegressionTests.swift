import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct LibraryIncrementalOrderRegressionTests {
    @Test func oldestFirstReadMovesUpdatedItemToEnd() async {
        let savedFilters = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(savedFilters) }
        let model = LibraryViewModel()
        model.filters = []
        model.sortMethod = .lastRead
        model.sortAscending = true
        model.pinType = .none
        let a = MangaInfo(id: .init(sourceKey: "round2-ui", mangaKey: "oldest"), title: "A")
        let b = MangaInfo(id: .init(sourceKey: "round2-ui", mangaKey: "newer"), title: "B")
        model.manga = [a, b]
        await model.mangaRead(mangaId: a.id)
        #expect(model.manga.map(\.id) == [b.id, a.id])
    }
    @Test func readingDoesNotUnpinUnreadPolicyItem() async {
        let savedFilters = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(savedFilters) }
        let model = LibraryViewModel()
        model.filters = []
        model.sortMethod = .lastRead
        model.sortAscending = false
        model.pinType = .unread
        var a = MangaInfo(id: .init(sourceKey: "round2-ui", mangaKey: "still-unread"), title: "A")
        a.unread = 3
        model.pinnedManga = [a]
        await model.mangaRead(mangaId: a.id)
        #expect(model.pinnedManga.map(\.id) == [a.id])
        #expect(model.manga.isEmpty)
    }
    @Test func oldestFirstOpenedKeepsUnreadPinAndMovesToEnd() async {
        let savedFilters = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(savedFilters) }
        let model = LibraryViewModel()
        model.filters = []
        model.sortMethod = .lastOpened
        model.sortAscending = true
        model.pinType = .unread
        let a = MangaInfo(id: .init(sourceKey: "round2-ui", mangaKey: "first"), title: "A")
        let b = MangaInfo(id: .init(sourceKey: "round2-ui", mangaKey: "second"), title: "B")
        model.pinnedManga = [a, b]
        await model.mangaOpened(mangaId: a.id)
        #expect(model.pinnedManga.map(\.id) == [b.id, a.id])
        #expect(model.manga.isEmpty)
    }
    @Test func newestFirstUnpinnedReadStillMovesToFront() async {
        let savedFilters = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(savedFilters) }
        let model = LibraryViewModel()
        model.filters = []
        model.sortMethod = .lastRead
        model.sortAscending = false
        model.pinType = .none
        let a = MangaInfo(id: .init(sourceKey: "round2-ui", mangaKey: "first"), title: "A")
        let b = MangaInfo(id: .init(sourceKey: "round2-ui", mangaKey: "second"), title: "B")
        model.manga = [a, b]
        await model.mangaRead(mangaId: b.id)
        #expect(model.manga.map(\.id) == [b.id, a.id])
    }

    @Test(arguments: [false, true])
    func readingStillUnpinsUpdatedChapterPolicyItem(ascending: Bool) async {
        let savedFilters = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(savedFilters) }
        let model = LibraryViewModel()
        model.filters = []
        model.sortMethod = .lastRead
        model.sortAscending = ascending
        model.pinType = .updatedChapters
        let a = MangaInfo(id: .init(sourceKey: "round2-ui", mangaKey: "updated"), title: "A")
        let b = MangaInfo(id: .init(sourceKey: "round2-ui", mangaKey: "ordinary"), title: "B")
        model.pinnedManga = [a]
        model.manga = [b]
        // Mirrors historySet without an earlier openedManga notification (tracker import).
        await model.mangaRead(mangaId: a.id)
        #expect(model.pinnedManga.isEmpty)
        #expect(model.manga.map(\.id) == (ascending ? [b.id, a.id] : [a.id, b.id]))
    }

}
