import AidokuRunner
import CoreData
import SwiftUI
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct SourceBrowseSafetyTests {
    @Test func removingSourceSettingsPreservesSimilarlyNamedSources() {
        let key = "audit-source-" + UUID().uuidString
        let ownSetting = key + ".login.password"
        let siblingSetting = key + "-1.login.password"
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: ownSetting)
            defaults.removeObject(forKey: siblingSetting)
        }
        defaults.set("own", forKey: ownSetting)
        defaults.set("sibling", forKey: siblingSetting)

        SourceManager.shared.removeSettings(from: key)

        #expect(defaults.string(forKey: ownSetting) == nil)
        #expect(defaults.string(forKey: siblingSetting) == "sibling")
    }

    @Test func refreshingBrowseWithoutUpdatesOrExternalSectionsIsSafe() {
        let controller = EmptyBrowseProbe()
        controller.loadViewIfNeeded()
        controller.updateExternalSources()
        #expect(controller.tableView.numberOfSections == 0)
    }

    @Test func homeBookmarksMatchRequestedSourcesAcrossBatches() async throws {
        let manager = CoreDataManager.shared
        let context = manager.context
        let source = UUID().uuidString
        let other = UUID().uuidString
        func manga(_ source: String, _ key: String) -> AidokuRunner.Manga {
            .init(sourceKey: source, key: key, title: key)
        }
        let first = manga(source, "first")
        let last = manga(source, "last")
        let fromOther = manga(other, "other")
        let unrequested = manga(other, "matching-key")
        let stored = [first, last, fromOther, unrequested]
        defer {
            for book in stored { manager.removeManga(mangaId: book.identifier, context: context) }
            try? context.save()
        }
        for book in stored { manager.addToLibrary(manga: book, chapters: [], context: context) }
        try context.save()

        let links: [HomeComponent.Value.Link] = [
            .init(title: "URL", value: .url("https://example.com")),
            .init(title: "Label"), first.intoLink(), fromOther.intoLink(), first.intoLink()
        ]
        var entries = links.compactMap(\.manga)
        #expect(entries.map(\.key) == ["first", "other", "first"])
        entries += (0..<900).map { manga(source, "absent-\($0)") }
        entries += [last, manga(source, "matching-key")]
        let bookmarks = await manager.bookmarkedMangaKeys(for: entries)
        #expect(bookmarks == ["first", "last", "other"])
    }

    @Test func refreshedUpdatesRespectActiveQueryAndSurviveClearingIt() throws {
        let model = BrowseViewModel()
        model.installedSources = [.init(sourceId: "a", name: "Alpha", languages: ["en"], version: 1, contentRating: .safe)]
        model.pinnedSources = [.init(sourceId: "b", name: "Beta", languages: ["en"], version: 1, contentRating: .safe)]
        model.search(query: "ALP")
        let json = """
        [{"id":"b","name":"Beta","version":2},{"id":"a","name":"Alpha","version":2},{"id":"c","name":"Extra","version":2}]
        """
        model.unfilteredExternalSources = try JSONDecoder().decode([ExternalSourceInfo].self, from: Data(json.utf8))
        model.loadUpdates()
        #expect(model.updatesSources.map(\.sourceId) == ["a"])
        model.search(query: "bet")
        #expect(model.updatesSources.map(\.sourceId) == ["b"])
        model.search(query: nil)
        #expect(model.updatesSources.map(\.sourceId) == ["a", "b"])
    }

    @Test func emptyCarouselScrollDoesNotDivideByZero() {
        let carousel = CarouselCollectionView(frame: .zero, collectionViewFlowLayout: UICollectionViewFlowLayout())
        carousel.scrollViewDidScroll(carousel)
    }

    @Test func carouselMapsFirstRealPageAndWrapsLastSentinel() {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 100, height: 100)
        let carousel = CarouselCollectionView(frame: .zero, collectionViewFlowLayout: layout)
        let source = CarouselProbe()
        carousel.carouselDataSource = source
        carousel.fakeCurrentPage = 1
        carousel.scrollViewDidScroll(carousel)
        #expect(source.page == 0)
        carousel.fakeCurrentPage = 4
        carousel.scrollViewDidScroll(carousel)
        #expect(carousel.fakeCurrentPage == 1)
        #expect(source.page == 0)
    }

    @Test func emptyHomeListHasNonnegativeLayoutHeight() {
        let (_, height) = CollectionView.mangaListLayout(itemsPerPage: 0, totalItems: 0)
        #expect(height.isFinite && height >= 0)
    }
}

@MainActor private final class CarouselProbe: CarouselCollectionViewDataSource {
    let numberOfItems = 3
    var page: Int?
    func pageDidChange(_ page: Int) { self.page = page }
    func carouselCollectionView(_ carouselCollectionView: CarouselCollectionView, cellForItemAt index: Int,
                                fakeIndexPath: IndexPath) -> UICollectionViewCell { UICollectionViewCell() }
}

@MainActor private final class EmptyBrowseProbe: BrowseViewController {
    // Keep this snapshot regression independent of installed sources and network startup.
    override func configure() {}
    override func constrain() {}
    override func observe() {}
}
