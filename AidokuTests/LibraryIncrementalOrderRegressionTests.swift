import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct LibraryIncrementalOrderRegressionTests {
    @Test func fuzzySearchPreservesGraphemesAndRowOrder() async {
        let model = LibraryViewModel()
        let first = MangaInfo(id: .init(sourceKey: "test", mangaKey: "a"), title: "👩🏽‍💻 Café")
        let partial = MangaInfo(id: .init(sourceKey: "test", mangaKey: "b"), title: "👩 Café")
        let last = MangaInfo(id: .init(sourceKey: "test", mangaKey: "c"), author: "👩🏽‍💻 Cafe\u{301}")
        model.manga = [first, partial, last]
        await model.search(query: "👩🏽‍💻É")
        #expect(model.manga.map(\.id) == [first.id, last.id])
    }

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

    @Test(arguments: [false, true])
    func batchReadKeepsSectionAndTieOrderAcrossSearch(ascending: Bool) async {
        let savedFilters = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(savedFilters) }
        var loads = 0
        let model = LibraryViewModel(snapshotLoader: { _ in
            loads += 1
            return nil
        })
        model.filters = []
        model.sortMethod = .lastRead
        model.sortAscending = ascending
        model.pinType = .updatedChapters
        let rows = (0..<6).map { index in
            MangaInfo(id: .init(sourceKey: "batch-history-fixture", mangaKey: "row-\(index)"), title: "Row \(index)", unread: 4)
        }
        model.pinnedManga = Array(rows[0..<3])
        model.manga = Array(rows[3..<6])
        await model.search(query: "Row 5")
        await model.updateHistory(for: [rows[2].id, rows[0].id, rows[5].id, rows[3].id], read: true)
        #expect(model.pinnedManga.isEmpty)
        #expect(model.manga.map(\.unread) == [0])
        await model.search(query: "")
        let pinnedOrder = ascending ? [1, 0, 2] : [0, 2, 1]
        let regularOrder = ascending ? [4, 3, 5] : [3, 5, 4]
        #expect(model.pinnedManga.map(\.id) == pinnedOrder.map { rows[$0].id })
        #expect(model.manga.map(\.id) == regularOrder.map { rows[$0].id })
        #expect(model.pinnedManga.map(\.unread) == (ascending ? [4, 0, 0] : [0, 0, 4]))
        #expect(model.manga.map(\.unread) == model.pinnedManga.map(\.unread))
        #expect(loads == 0)
    }

    @Test func historyCanIntroducePreviouslyFilteredRows() async {
        let savedFilters = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(savedFilters) }
        let hidden = MangaInfo(id: .init(sourceKey: "batch-history-fixture", mangaKey: "hidden"))
        var loads = 0
        let model = LibraryViewModel(snapshotLoader: { _ in
            loads += 1
            return .init(manga: [hidden])
        })
        model.filters = [.init(type: .started, exclude: false)]
        model.pinType = .none
        await model.updateHistory(for: [hidden.id], read: true)
        #expect(loads == 1)
        #expect(model.manga == [hidden])
    }

    @Test func enteringViewportUsesCurrentBadgesForPrefetchedGridAndListCells() async {
        let controller = LibraryViewController()
        let row = MangaInfo(id: .init(sourceKey: "badge-fixture", mangaKey: "row"), unread: 3, downloads: 2)
        var snapshot = NSDiffableDataSourceSnapshot<OldMangaCollectionViewController.Section, MangaInfo>()
        snapshot.appendSections([.regular])
        snapshot.appendItems([row], toSection: .regular)
        await controller.dataSource.apply(snapshot, animatingDifferences: false)
        let path = IndexPath(item: 0, section: 0)
        let grid = MangaGridCell(frame: .zero)
        let list = MangaListCell(frame: .zero)
        controller.viewModel.badgeType = [.unread]
        controller.collectionView(controller.collectionView, willDisplay: grid, forItemAt: path)
        #expect(grid.badgeNumber == 3 && grid.badgeNumber2 == 0)
        controller.viewModel.badgeType = [.downloaded]
        controller.collectionView(controller.collectionView, willDisplay: grid, forItemAt: path)
        controller.collectionView(controller.collectionView, willDisplay: list, forItemAt: path)
        #expect(grid.badgeNumber == 0 && grid.badgeNumber2 == 2)
        #expect(list.badgeNumber == 0 && list.badgeNumber2 == 2)
        #expect(grid.preparationTask == nil)
    }
}
