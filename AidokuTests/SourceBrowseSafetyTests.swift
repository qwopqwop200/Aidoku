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

    @Test func filterChildrenDoNotRetainTheirParent() {
        weak var weakParent: FilterCell?
        weak var weakStack: FilterStackView?
        autoreleasepool {
            let parent = FilterCell(filter: SelectFilter(name: "sort", options: ["a", "b"]), selectedFilters: SelectedFilters())
            weakParent = parent
            weakStack = parent.detailView
            #expect(parent.detailView?.cells.count == 2)
        }
        #expect(weakParent == nil)
        #expect(weakStack == nil)
    }

    @Test func headerMenuDoesNotRetainHeader() {
        weak var weakHeader: MangaListSelectionHeader?
        autoreleasepool {
            let header = MangaListSelectionHeader(frame: .zero)
            header.options = ["a", "b"]
            weakHeader = header
        }
        #expect(weakHeader == nil)
    }

    @Test func settingWithShortTitlesFallsBackToValue() {
        let controller = SettingSelectViewController(item: SettingItem(type: "select", values: ["a", "b"], titles: ["A"]))
        controller.loadViewIfNeeded()
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 0))
        #expect(cell.textLabel?.text == "b")
    }

    @Test func legacySettingsControlsReleaseControllerAndCells() {
        weak var weakController: SettingsTableViewController?
        weak var weakCell: UITableViewCell?
        autoreleasepool {
            let controller = SettingsTableViewController()
            weakController = controller
            let cell = controller.stepperCell(for: SettingItem(type: "stepper", key: "audit.stepper", requires: "audit.requires"))
            weakCell = cell
        }
        #expect(weakController == nil)
        #expect(weakCell == nil)
    }

    @Test func settingsSummaryWithShortTitlesFallsBackToValue() {
        let key = "audit.summary." + UUID().uuidString
        UserDefaults.standard.set("b", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let controller = SettingsTableViewController()
        controller.loadViewIfNeeded()
        let cell = controller.tableView(controller.tableView, cellForRowAt: .init(row: 0, section: 0),
                                        settingItem: SettingItem(type: "select", key: key, values: ["a", "b"], titles: ["A"]))
        #expect(cell.detailTextLabel?.text == "b")
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
