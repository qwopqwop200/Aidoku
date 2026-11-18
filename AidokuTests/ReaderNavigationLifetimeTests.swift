import AidokuRunner
import Testing
import UIKit
@testable import Aidoku

@MainActor struct ReaderNavigationLifetimeTests {
    @Test func adjacentChaptersUseRefreshedMetadataAndOnlyOneRowPerKey() {
        let current = AidokuRunner.Chapter(key: "current", title: "Updated", chapterNumber: 3, scanlators: ["Blue"])
        let stale = AidokuRunner.Chapter(key: "current", title: "Old", chapterNumber: 9, scanlators: ["Red"])
        let chapters: [AidokuRunner.Chapter] = [
            .init(key: "next", chapterNumber: 4), current, stale,
            .init(key: "alternate-release", chapterNumber: 3),
            .init(key: "red", chapterNumber: 2, scanlators: ["Red"]),
            .init(key: "blue", chapterNumber: 2, scanlators: ["Blue"])
        ]
        let reader = ReaderViewController(source: nil,
            manga: .init(sourceKey: "navigation", key: "book", title: "Book", chapters: chapters), chapter: stale)
        #expect(reader.chapter == current)
        #expect(reader.getNextChapter(after: stale)?.key == "next")
        #expect(reader.getPreviousChapter(before: stale)?.key == "blue")
        #expect(reader.getNextChapter(after: .init(key: "removed")) == nil)
    }

    @Test func metadataRefreshPreservesReaderNavigationAndExplicitChapterChangesStillLoad() {
        let opened = AidokuRunner.Chapter(key: "opened", chapterNumber: 1)
        var current = AidokuRunner.Chapter(key: "current", title: "Before", chapterNumber: 2)
        let next = AidokuRunner.Chapter(key: "next", chapterNumber: 3)
        let reader = ReaderViewController(source: nil,
            manga: .init(sourceKey: "navigation", key: "book", title: "Book", chapters: [current, opened]), chapter: opened)
        reader.setChapter(current)
        let pages = NavigationLoadProbe()
        reader.reader = pages
        current.title = "After"
        let refreshed = [next, current, opened]
        reader.updatePresentedChapter(opened, chapters: refreshed)
        #expect(reader.chapter == current)
        #expect(reader.getNextChapter()?.key == "next")
        #expect(pages.loadedKeys.isEmpty)
        var renamedOpening = opened
        renamedOpening.title = "Renamed opening"
        reader.updatePresentedChapter(renamedOpening, chapters: refreshed)
        #expect(reader.chapter == current)
        #expect(pages.loadedKeys.isEmpty)
        reader.updatePresentedChapter(next, chapters: refreshed)
        #expect(reader.chapter == next)
        #expect(pages.loadedKeys == ["next"])
    }

    @Test func replacingStackReleasesOriginalReader() async {
        weak var original: ReaderViewController?
        let replacement = UIViewController()
        let navigation = autoreleasepool {
            let reader = ReaderViewController(source: nil,
                manga: .init(sourceKey: "navigation-lifetime", key: "book", title: "Book"),
                chapter: .init(key: "chapter"))
            original = reader
            let navigation = ReaderNavigationController(readerViewController: reader)
            #expect(original != nil)
            navigation.setViewControllers([replacement], animated: false)
            return navigation
        }

        // UIKit may defer releasing the displaced stack. Drain local autoreleases
        // and allow pending main-actor work while keeping navigation alive below.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while original != nil, ContinuousClock.now < deadline {
            await Task.yield()
        }

        #expect(original == nil)
        #expect(navigation.viewControllers.count == 1)
        #expect(navigation.topViewController === replacement)
    }
}

@MainActor private final class NavigationLoadProbe: UIViewController, ReaderReaderDelegate {
    var readingMode: ReadingMode = .ltr
    weak var delegate: ReaderHoldingDelegate?
    var loadedKeys: [String] = []
    func moveLeft() {}
    func moveRight() {}
    func sliderMoved(value: CGFloat) {}
    func sliderStopped(value: CGFloat) {}
    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) { loadedKeys.append(chapter.key) }
}
