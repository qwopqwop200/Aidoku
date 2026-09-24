import AidokuRunner
import CoreData
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Isolated audit simulator only. Real CoreData fixture/production controller;
/// programmatic UIKit actions, no source requests or covers, no external download.
@Suite(.serialized) @MainActor
struct Round2PopulatedLibraryTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("Round2UI/enabled").path)))
    func populatedLibrarySearchSortFilterLayoutAndSelection() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("Round2UI")
        let keys = [AppSettings.library.filtersData.key, AppSettings.library.sortOption.key,
                    AppSettings.library.sortAscending.key, AppSettings.library.currentCategory.key,
                    AppSettings.library.pinTitles.key, AppSettings.library.listView.key,
                    AppSettings.library.lockLibrary.key]
        let defaults = UserDefaults.standard
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        defer { for key in keys { if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        // Refuse non-isolated data rather than silently mix with or clear a user's library.
        try #require(CoreDataManager.shared.getLibraryManga(context: CoreDataManager.shared.context).isEmpty)
        try #require(!(await DownloadManager.shared.hasQueuedDownloads()))
        let source = "round2-ui-" + UUID().uuidString
        let count = 120
        let ids = (0..<count).map { MangaIdentifier(sourceKey: source, mangaKey: "item-\($0)") }
        try await CoreDataManager.shared.container.performBackgroundTask { context in
            for index in 0..<count {
                let manga = AidokuRunner.Manga(sourceKey: source, key: "item-\(index)",
                    title: String(format: "%03d", index) + (index.isMultiple(of: 5) ? " Needle" : " Title"),
                    authors: ["Fixture author"], status: index.isMultiple(of: 2) ? .completed : .ongoing)
                let chapter = AidokuRunner.Chapter(key: "chapter", chapterNumber: 1)
                CoreDataManager.shared.addToLibrary(manga: manga, chapters: [chapter], context: context)
            }
            try context.save()
        }
        try JSONSerialization.data(withJSONObject: ["source": source, "mangaKeys": ids.map(\.mangaKey), "cleanup": "Only remove these identifiers; never clear whole library"], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("fixture-manifest.json"), options: .atomic)
        AppSettings.library.lockLibrary.set(false)
        AppSettings.library.currentCategory.set(nil)
        AppSettings.library.pinTitles.set("none")
        AppSettings.library.filtersData.set(nil)
        AppSettings.library.sortOption.set(LibraryViewModel.SortMethod.alphabetical.rawValue)
        AppSettings.library.sortAscending.set(false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let library = LibraryViewController()
        let nav = UINavigationController(rootViewController: library)
        window.rootViewController = nav; window.makeKeyAndVisible()
        defer { window.isHidden = true; prior?.makeKey() }
        var rows: [[String: Any]] = []
        func checkpoint(_ name: String, start: Double, expectedCount: Int) async throws {
            library.updateDataSource()
            library.view.layoutIfNeeded()
            try await R2LibraryFrames().wait()
            #expect(library.dataSource.snapshot().numberOfItems == expectedCount)
            try #require(library.view.window === window)
            let snapshot = library.dataSource.snapshot().itemIdentifiers
            rows.append(["scenario": name, "msThroughDisplay": (CACurrentMediaTime() - start) * 1000,
                         "expectedCount": expectedCount, "actualCount": snapshot.count,
                         "orderedIDs": snapshot.map { $0.id.mangaKey }])
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try #require(screenshot.pngData()).write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
            try JSONSerialization.data(withJSONObject: ["source": source, "count": count, "scope": "Actual library DB/controller; programmatic actions; no cover/network; timings include two display callbacks, not tap automation", "rows": rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("populated-library.json"), options: .atomic)
        }
        let begin = CACurrentMediaTime()
        let deadline = Date().addingTimeInterval(30)
        while library.viewModel.manga.count != count, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(library.viewModel.manga.count == count)
        try await checkpoint("initial", start: begin, expectedCount: count)
        for iteration in 0..<3 {
            let start = CACurrentMediaTime()
            await library.viewModel.loadLibrary()
            try await checkpoint("reload-\(iteration)", start: start, expectedCount: count)
        }
        for ascending in [true, false] {
            let start = CACurrentMediaTime()
            await library.viewModel.setSort(method: .alphabetical, ascending: ascending)
            let titles = library.viewModel.manga.compactMap(\.title)
            #expect(titles == (ascending ? titles.sorted(by: >) : titles.sorted()))
            try await checkpoint("alphabetical-\(ascending)", start: start, expectedCount: count)
        }
        let search = try #require(library.navigationItem.searchController)
        for query in ["Needle", "", "missingfixturevalue", ""] {
            let start = CACurrentMediaTime()
            search.searchBar.text = query
            library.updateSearchResults(for: search)
            let expected = query.isEmpty ? count : (query == "Needle" ? count / 5 : 0)
            let until = Date().addingTimeInterval(5)
            while library.viewModel.manga.count != expected, Date() < until { try await Task.sleep(for: .milliseconds(10)) }
            try await checkpoint("search-\(rows.count)", start: start, expectedCount: expected)
        }
        for expected in [count / 2, count / 2, count] {
            let start = CACurrentMediaTime()
            await library.viewModel.toggleFilter(method: .completed)
            try await checkpoint("completed-filter-\(rows.count)", start: start, expectedCount: expected)
        }
        for list in [true, false] {
            let start = CACurrentMediaTime()
            library.usesListLayout = list
            library.collectionView.setCollectionViewLayout(library.makeCollectionViewLayout(), animated: false)
            library.collectionView.reloadData()
            try await checkpoint("layout-\(list)", start: start, expectedCount: count)
            let scrollStart = CACurrentMediaTime()
            library.collectionView.scrollToItem(at: IndexPath(item: count - 1, section: 0), at: .bottom, animated: false)
            try await checkpoint("scroll-end-\(list)", start: scrollStart, expectedCount: count)
        }
        library.setEditing(true, animated: false)
        library.selectAllItems()
        #expect(library.collectionView.indexPathsForSelectedItems?.count == count)
        library.deselectAllItems()
        #expect(library.collectionView.indexPathsForSelectedItems?.isEmpty != false)
        library.stopEditing()
        library.lock()
        #expect(library.dataSource.snapshot().numberOfItems == 0)
        library.unlock()
        try await checkpoint("unlocked-restored", start: CACurrentMediaTime(), expectedCount: count)
        // Remove only this run's fixture; a failed save throws and stops subsequent cleanup.
        try await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.removeFromLibrary(ids: ids, context: context)
            try context.save()
        }
    }
}

@MainActor private final class R2LibraryFrames: NSObject {
    private var link: CADisplayLink?
    private var pending: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var ticks = 0
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation; link = CADisplayLink(target: self, selector: #selector(tick)); link?.add(to: .main, forMode: .common)
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finish(error: FrameError.timeout)
            }
        }
    }
    @objc private func tick() { ticks += 1; if ticks == 2 { finish(error: nil) } }
    private func finish(error: Error?) {
        link?.invalidate(); link = nil; timeout?.cancel(); timeout = nil
        let continuation = pending; pending = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
    private enum FrameError: Error { case timeout }
}
