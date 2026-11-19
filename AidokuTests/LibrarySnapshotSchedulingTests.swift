import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct LibrarySnapshotSchedulingTests {
    @Test func categoryChangeNeverPublishesAnObsoleteSnapshot() async throws {
        let oldCategory = AppSettings.library.currentCategory.get()
        defer { AppSettings.library.currentCategory.set(oldCategory) }
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        model.categories = ["A", "B"]
        model.currentCategory = "A"
        model.manga = [Self.row("displayed")]
        let first = Task { await model.loadLibrary() }
        try await RegressionTestWait.until { gate.requests.count == 1 }
        model.currentCategory = "B"
        var entered = false
        let second = Task { entered = true; await model.loadLibrary() }
        try await RegressionTestWait.until { entered }
        gate.finish(0, rows: [Self.row("obsolete-A")])
        try await RegressionTestWait.until { gate.requests.count == 2 }
        #expect(model.manga.map(\.id.mangaKey) == ["displayed"])
        #expect(gate.requests.map(\.category) == ["A", "B"])
        gate.finish(1, rows: [Self.row("current-B")])
        await first.value
        await second.value
        #expect(model.manga.map(\.id.mangaKey) == ["current-B"])
        #expect(gate.maximumActive == 1)
    }

    @Test func leavingLockedCategoryKeepsItsRowsHiddenUntilTheNewCategoryLoads() async throws {
        let oldCategory = AppSettings.library.currentCategory.get()
        let oldLock = AppSettings.library.lockLibrary.get()
        let oldLockedCategories = AppSettings.library.lockedCategories.get()
        defer {
            AppSettings.library.currentCategory.set(oldCategory)
            AppSettings.library.lockLibrary.set(oldLock)
            AppSettings.library.lockedCategories.set(oldLockedCategories)
        }
        AppSettings.library.lockLibrary.set(true)
        AppSettings.library.lockedCategories.set(["private"])
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        model.categories = ["private", "public"]
        model.currentCategory = "private"
        let controller = LibraryViewController(viewModel: model)
        let secret = Self.row("secret"), visible = Self.row("visible")
        let first = Task { await model.loadLibrary() }
        try await RegressionTestWait.until { gate.requests.count == 1 }
        gate.finish(0, rows: [secret])
        await first.value

        controller.lock()
        #expect(controller.dataSource.snapshot().itemIdentifiers.isEmpty)
        controller.unlock()
        #expect(controller.dataSource.snapshot().itemIdentifiers == [secret])
        controller.lock()
        controller.optionSelected(IndexPath(item: 1, section: 1))
        try await RegressionTestWait.until { gate.requests.count == 2 }
        #expect(gate.requests[1].category == "public")
        #expect(model.manga == [secret])
        #expect(controller.dataSource.snapshot().itemIdentifiers.isEmpty)
        controller.updateDataSource()
        #expect(controller.dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(controller.collectionView.refreshControl == nil)

        gate.finish(1, rows: [visible])
        try await RegressionTestWait.until { controller.dataSource.snapshot().itemIdentifiers == [visible] }
        #expect(controller.collectionView.isScrollEnabled)
    }

    @Test func removedPublicCategoryNeverAppliesLockedAllRowsDuringNotification() async throws {
        let oldCategory = AppSettings.library.currentCategory.get()
        let oldLock = AppSettings.library.lockLibrary.get()
        defer {
            AppSettings.library.currentCategory.set(oldCategory)
            AppSettings.library.lockLibrary.set(oldLock)
        }
        AppSettings.library.lockLibrary.set(true)
        let removed = "removed-\(UUID().uuidString)"
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        model.categories = [removed]
        model.currentCategory = removed
        let controller = LibraryViewController(viewModel: model)
        let recorder = LibrarySnapshotRecorder(collectionView: controller.collectionView) { _, _, _ in nil }
        controller.dataSource = recorder
        let visible = Self.row("public"), secret = Self.row("private")
        let first = Task { await model.loadLibrary() }
        try await RegressionTestWait.until { gate.requests.count == 1 }
        gate.finish(0, rows: [visible])
        await first.value
        controller.updateLockState()
        #expect(recorder.applied == [[visible]])
        controller.observe()
        NotificationCenter.default.post(name: .updateCategories, object: nil)
        try await RegressionTestWait.until { gate.requests.count == 2 }
        #expect(model.currentCategory == nil)
        #expect(model.locked)
        gate.finish(1, rows: [secret])
        try await RegressionTestWait.until { model.manga == [secret] && recorder.applied.last == [] }
        #expect(recorder.applied.allSatisfy { !$0.contains(secret) })
        controller.unlock()
        #expect(recorder.applied.last == [secret])
    }

    @Test func authenticationCannotUnlockAnotherSelectionOrAReturnToTheSameCategory() async throws {
        let saved = AppSettings.library.currentCategory.get()
        defer { AppSettings.library.currentCategory.set(saved) }
        let controller = LibraryViewController()
        let model = controller.viewModel
        model.currentCategory = "first"
        controller.lock()
        var approval: CheckedContinuation<Bool, Never>?
        let authentication = Task {
            await controller.attemptUnlock {
                await withCheckedContinuation { approval = $0 }
            }
        }
        try await RegressionTestWait.until { approval != nil }
        model.currentCategory = "other"
        model.currentCategory = "first"
        controller.lock()
        approval?.resume(returning: true)
        await authentication.value
        #expect(model.locked)
        await controller.attemptUnlock { true }
        #expect(!model.locked)
    }

    @Test func notificationBurstHasOneActiveLoadAndOneLatestFollowup() async throws {
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        let first = Task { await model.loadLibrary() }
        try await RegressionTestWait.until { gate.requests.count == 1 }
        var entered = 0
        let callers = (0..<100).map { _ in Task { entered += 1; await model.loadLibrary() } }
        try await RegressionTestWait.until { entered == 100 }
        gate.finish(0, rows: [Self.row("old")])
        try await RegressionTestWait.until { gate.requests.count == 2 }
        gate.finish(1, rows: [Self.row("latest")])
        await first.value
        for caller in callers { await caller.value }
        #expect(gate.requests.count == 2)
        #expect(gate.maximumActive == 1)
        #expect(model.manga.map(\.id.mangaKey) == ["latest"])
    }

    @Test func repeatedDisplayUpdatesApplyOnceAndKeepSearchAndBadgesCurrent() async {
        let controller = LibraryViewController()
        controller.unlock()
        let model = controller.viewModel
        let pinned = Self.row("pinned"), regular = Self.row("regular")
        model.pinnedManga = [pinned]
        model.manga = [regular]

        var applications = 0
        for _ in 0..<50 {
            if controller.updateDataSource() { applications += 1 }
        }
        #expect(applications == 1)
        #expect(controller.dataSource.snapshot().itemIdentifiers == [pinned, regular])

        await model.search(query: "regular")
        #expect(controller.updateDataSource())
        #expect(controller.dataSource.snapshot().itemIdentifiers == [regular])
        model.applyDownloadCounts([pinned.id: 7, regular.id: 3])
        #expect(controller.updateDataSource())
        #expect(controller.dataSource.snapshot().itemIdentifiers.map(\.downloads) == [3])
        await model.search(query: "")
        model.pinnedManga[0].unread = 5
        #expect(controller.updateDataSource())
        let restored = controller.dataSource.snapshot()
        #expect(restored.itemIdentifiers(inSection: .pinned).map(\.unread) == [5])
        #expect(restored.itemIdentifiers.map(\.downloads) == [7, 3])
    }

    @Test func lockedAndClearedSnapshotsCanRepublishTheCurrentRows() {
        let controller = LibraryViewController()
        controller.unlock()
        controller.viewModel.manga = [Self.row("before-lock")]
        #expect(controller.updateDataSource())
        #expect(controller.collectionView.isScrollEnabled)
        #expect(controller.collectionView.refreshControl != nil)

        controller.lock()
        #expect(controller.dataSource.snapshot().numberOfSections == 0)
        controller.viewModel.manga = [Self.row("while-locked")]
        #expect(!controller.updateDataSource())
        #expect(controller.dataSource.snapshot().numberOfItems == 0)
        #expect(!controller.collectionView.isScrollEnabled)
        #expect(controller.collectionView.refreshControl == nil)

        controller.unlock()
        #expect(controller.dataSource.snapshot().itemIdentifiers == controller.viewModel.manga)
        controller.clearDataSource()
        #expect(controller.dataSource.snapshot().numberOfSections == 0)
        #expect(controller.updateDataSource())
        #expect(controller.dataSource.snapshot().itemIdentifiers == controller.viewModel.manga)
        controller.collectionView.isScrollEnabled = false
        controller.collectionView.refreshControl = nil
        #expect(!controller.updateDataSource())
        #expect(controller.collectionView.isScrollEnabled)
        #expect(controller.collectionView.refreshControl != nil)
    }

    @Test func latestSearchAppliesToTheCompletedSnapshot() async throws {
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        let load = Task { await model.loadLibrary() }
        try await RegressionTestWait.until { gate.requests.count == 1 }
        await model.search(query: "match")
        gate.finish(0, rows: [Self.row("match"), Self.row("other")])
        await load.value
        #expect(model.manga.map(\.id.mangaKey) == ["match"])
    }

    @Test func sortChangeInvalidatesAnInFlightSnapshot() async throws {
        let oldOption = AppSettings.library.sortOption.get()
        let oldAscending = AppSettings.library.sortAscending.get()
        defer {
            AppSettings.library.sortOption.set(oldOption)
            AppSettings.library.sortAscending.set(oldAscending)
        }
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        model.sortMethod = .alphabetical
        model.sortAscending = false
        let first = Task { await model.loadLibrary() }
        try await RegressionTestWait.until { gate.requests.count == 1 }
        let sort = Task { await model.setSort(method: .unreadChapters, ascending: true) }
        try await RegressionTestWait.until { model.sortMethod == .unreadChapters }
        gate.finish(0, rows: [Self.row("obsolete-order")])
        try await RegressionTestWait.until { gate.requests.count == 2 }
        #expect(model.manga.isEmpty)
        #expect(gate.requests[1].sortMethod == .unreadChapters)
        #expect(gate.requests[1].sortAscending)
        gate.finish(1, rows: [Self.row("latest-order")])
        await first.value
        await sort.value
        #expect(model.manga.map(\.id.mangaKey) == ["latest-order"])
    }

    @Test(arguments: [false, true])
    func incrementalReadOrOpenInvalidatesPendingSnapshot(read: Bool) async throws {
        let saved = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(saved) }
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        model.filters = []
        model.pinType = .none
        model.sortMethod = read ? .lastRead : .lastOpened
        model.sortAscending = false
        let a = Self.row("A"), b = Self.row("B")
        model.manga = [a, b]
        let load = Task { await model.loadLibrary() }
        try await RegressionTestWait.until { gate.requests.count == 1 }
        if read { await model.mangaRead(mangaId: b.id) }
        else { await model.mangaOpened(mangaId: b.id) }
        #expect(model.manga.map(\.id) == [b.id, a.id])
        gate.finish(0, rows: [a, b])
        try await RegressionTestWait.until { gate.requests.count == 2 }
        #expect(model.manga.map(\.id) == [b.id, a.id])
        gate.finish(1, rows: [b, a])
        await load.value
        #expect(model.manga.map(\.id) == [b.id, a.id])
        #expect(gate.requests.count == 2)
        #expect(gate.maximumActive == 1)
    }

    @Test func visibleAndHiddenSearchRowsKeepIncrementalBadges() async {
        let model = LibraryViewModel()
        model.sortMethod = .alphabetical
        model.sortAscending = false
        let a = Self.row("alpha"), b = Self.row("bravo")
        model.manga = [a, b]
        await model.search(query: "alpha")
        model.applyDownloadCounts([a.id: 3, b.id: 5])
        #expect(model.manga.map(\.downloads) == [3])
        await model.search(query: "bravo")
        #expect(model.manga.map(\.downloads) == [5])
        await model.search(query: "")
        #expect(model.manga.map(\.id) == [a.id, b.id])
        #expect(model.manga.map(\.downloads) == [3, 5])
    }

    @Test(arguments: [false, true])
    func olderDownloadCountCannotOverwriteLaterCountOrFullRefresh(fullRefresh: Bool) async throws {
        let saved = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(saved) }
        var latest = Self.row("download")
        latest.downloads = 5
        let model = LibraryViewModel(snapshotLoader: { _ in .init(manga: [latest]) })
        model.filters = []
        model.manga = [Self.row("download")]
        let id = latest.id
        var pending: CheckedContinuation<Int, Never>?
        let first = Task {
            await model.fetchDownloadCounts(for: id) { _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        try await RegressionTestWait.until { pending != nil }
        if fullRefresh {
            await model.fetchDownloadCounts(for: nil)
        } else {
            await model.fetchDownloadCounts(for: id) { _ in 5 }
        }
        pending?.resume(returning: 1)
        await first.value
        #expect(model.manga == [latest])
    }

    @Test func chapterAndDownloadFiltersCanAdmitAnAbsentTitle() async {
        let saved = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(saved) }
        let row = Self.row("newly-matching")
        let model = LibraryViewModel(snapshotLoader: { _ in .init(manga: [row]) })
        model.filters = [.init(type: .hasUnread, exclude: false)]
        await model.fetchUnreads(for: row.id)
        #expect(model.manga == [row])
        model.manga = []
        model.filters = [.init(type: .downloaded, exclude: false)]
        await model.fetchDownloadCounts(for: row.id)
        #expect(model.manga == [row])
    }

    @Test func firstPageProgressCanIntroduceAStartedTitleWithoutReloadingForEveryPage() async {
        let saved = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(saved) }
        let row = Self.row("just-started")
        var loads = 0
        let model = LibraryViewModel(snapshotLoader: { _ in
            loads += 1
            return .init(manga: [row])
        })
        model.sortMethod = .alphabetical
        model.filters = [.init(type: .started, exclude: false)]
        let first = await model.mangaRead(mangaId: row.id)
        let second = await model.mangaRead(mangaId: row.id)
        #expect(first && !second)
        #expect(model.manga == [row])
        #expect(loads == 1)
    }

    private static func row(_ key: String) -> MangaInfo {
        MangaInfo(id: .init(sourceKey: "snapshot-fixture", mangaKey: key), title: key)
    }
}

@MainActor
private final class LibrarySnapshotGate {
    var requests: [LibraryViewModel.LoadRequest] = []
    private var waiters: [Int: CheckedContinuation<LibraryViewModel.Snapshot?, Never>] = [:]
    private(set) var maximumActive = 0

    func load(_ request: LibraryViewModel.LoadRequest) async -> LibraryViewModel.Snapshot? {
        let index = requests.count
        requests.append(request)
        return await withCheckedContinuation { continuation in
            waiters[index] = continuation
            maximumActive = max(maximumActive, waiters.count)
        }
    }

    func finish(_ index: Int, rows: [MangaInfo]) {
        waiters.removeValue(forKey: index)?.resume(returning: .init(manga: rows))
    }
}

@MainActor
private final class LibrarySnapshotRecorder: UICollectionViewDiffableDataSource<OldMangaCollectionViewController.Section, MangaInfo> {
    var applied: [[MangaInfo]] = []

    override func apply(_ snapshot: NSDiffableDataSourceSnapshot<OldMangaCollectionViewController.Section, MangaInfo>,
                        animatingDifferences: Bool = true, completion: (() -> Void)? = nil) {
        applied.append(snapshot.itemIdentifiers)
        super.apply(snapshot, animatingDifferences: animatingDifferences, completion: completion)
    }
}
