import Testing
import AidokuRunner
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationSessionTests {
    @Test func realSourceAdapterPagesPrepareNeighborsWithoutAnyPageTurn() async throws {
        let fixture = SessionFixture()
        let pages = (0..<8).map { index in
            AidokuRunner.Page(content: .url(url: URL(string: "https://example.invalid/page-\(index).png")!, context: nil),
                              hasDescription: false, description: nil)
                .toOld(sourceId: "test", chapterId: "chapter", language: nil)
        }
        // This is how the actual source adapter constructs pages; the legacy index is always zero.
        #expect(pages.allSatisfy { $0.index == 0 })
        let owner = UnindexedChapterOwner(pages: pages, current: 3)
        #expect(owner.translationCurrentPageIndex == 3)
        var prepared: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            prepared.append(pages.firstIndex { $0.imageURL == page.imageURL }!)
            return [Self.region]
        })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session, readSettings: { fixture.settings }, setEnabled: { _ in })
        coordinator.install()
        coordinator.resume()
        defer { coordinator.close() }
        try await waitUntil { prepared.count == 8 }
        #expect(prepared == [3, 4, 2, 5, 1, 6, 0, 7])
        #expect(session.state == .on)
        #expect(owner.translationVisiblePages.first?.hasCompletedTranslation(settings: fixture.settings) == true)
        // Ordering must not invalidate already persisted page identities.
        #expect(ReaderTranslationSession.chapterItems(pages).map(\.key) == pages.map(\.translationCacheKey))
    }

    @Test func partialResultsAreNotCachedAsCompleteAndLateProgressCannotRestoreAnOverlay() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        let imageView = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: imageView)
        visible.sourcePage = Self.page(0)
        var calls = 0
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, progress in
            calls += 1
            var pending = Self.region
            pending.translation = nil
            try await progress?([pending])
            #expect(imageView.subviews.isEmpty)
            try await progress?([Self.region])
            await gate.wait()
            var final = Self.region
            final.translation = "완료"
            try await progress?([final])
            return [final]
        })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [visible], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { await gate.started }
        #expect(visible.regions.first?.translation == "안녕")
        #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
        session.disable()
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(imageView.subviews.isEmpty)
        #expect(visible.regions.first?.translation == "안녕")
        session.enable(settings: fixture.settings)
        try await waitUntil { visible.hasCompletedTranslation(settings: fixture.settings) }
        #expect(calls == 2)
        #expect(visible.regions.first?.translation == "완료")
    }

    @Test func visiblePagePreemptsOffscreenWorkAndRejectsItsLateResult() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        let firstImage = UIImageView(image: Self.image())
        let secondImage = UIImageView(image: Self.image())
        let first = ReaderTranslationPage(imageView: firstImage)
        let second = ReaderTranslationPage(imageView: secondImage)
        first.sourcePage = Self.page(0)
        second.sourcePage = Self.page(1)
        var indices: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, progress in
            indices.append(page.index)
            if indices.count == 1 {
                try await progress?([Self.region])
                await gate.wait()
                var stale = Self.region
                stale.translation = "늦은 응답"
                try await progress?([stale])
                return [stale]
            }
            return [Self.region]
        })
        defer { session.close() }
        let items = [Self.page(0), Self.page(1)].map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [first], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { await gate.started }
        session.update(items: items, visible: [second], context: "chapter")
        try await waitUntil { second.hasCompletedTranslation(settings: fixture.settings) }
        #expect(Array(indices.prefix(2)) == [0, 1])
        #expect(firstImage.subviews.isEmpty)
        #expect(second.regions.first?.translation == "안녕")
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        session.update(items: items, visible: [first], context: "chapter")
        #expect(first.hasCompletedTranslation(settings: fixture.settings))
        #expect(first.regions.first?.translation == "안녕")
        #expect(indices == [0, 1, 0])
    }

    @Test func probeGatesActivationThenPreparesTheWholeChapterWithSavedEffort() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        var settings = fixture.settings
        settings.reasoningEffort = .high
        var indices: [Int] = []
        var efforts: [OpenAIReasoningEffort] = []
        let session = ReaderTranslationSession(validate: { _ in await gate.wait() }, process: { page, settings, _ in
            indices.append(page.index)
            efforts.append(settings.reasoningEffort)
            return [Self.region]
        })
        defer { session.close() }
        let pages = (0..<8).map { Self.page($0) }
        let imageView = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: imageView)
        visible.sourcePage = pages[2]
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [visible], context: "chapter")
        session.enable(settings: settings)
        try await waitUntil { await gate.started }
        #expect(session.state == .checking)
        #expect(indices.isEmpty)
        await gate.release()
        try await waitUntil { indices.count == 8 }
        #expect(session.state == .on)
        #expect(indices == [2, 3, 1, 4, 0, 5, 6, 7])
        #expect(efforts.allSatisfy { $0 == .high })
        #expect(visible.regions.first?.translation == "안녕")
        session.disable()
        #expect(imageView.subviews.allSatisfy { $0.isHidden })
        session.enable(settings: settings)
        try await waitUntil { session.state == .on }
        #expect(indices.count == 8)
        #expect(imageView.subviews.contains { !$0.isHidden })
    }

    @Test func cancellationRejectsLateProbeAndLateTranslation() async throws {
        for cancelDuringProbe in [true, false] {
            let gate = SessionGate()
            let fixture = SessionFixture()
            var calls = 0
            var cancellations = 0
            let session = ReaderTranslationSession(validate: { _ in
                if cancelDuringProbe { await gate.wait() }
            }, process: { _, _, _ in
                calls += 1
                await gate.wait()
                return [Self.region]
            }, cancelProcessing: { cancellations += 1 })
            let imageView = UIImageView(image: Self.image())
            let visible = ReaderTranslationPage(imageView: imageView)
            visible.sourcePage = Self.page(0)
            session.update(items: [Self.page(0), Self.page(1)].map(ReaderTranslationSession.Item.init), visible: [visible], context: "chapter")
            session.enable(settings: fixture.settings)
            try await waitUntil { await gate.started }
            session.close()
            await gate.release()
            try await Task.sleep(nanoseconds: 20_000_000)
            #expect(session.state == .off)
            #expect(calls == (cancelDuringProbe ? 0 : 1))
            #expect(cancellations > 0)
            #expect(visible.regions.isEmpty)
            #expect(imageView.subviews.isEmpty)
        }
    }

    @Test func nextChapterCancelsOldWorkAndNewReaderHasIndependentCache() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        var finished: [String] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            if page.chapterId == "old" { await gate.wait() }
            finished.append(page.chapterId)
            return [Self.region]
        })
        defer { session.close() }
        session.update(items: [.init(Self.page(0, chapter: "old"))], visible: [], context: "old")
        session.enable(settings: fixture.settings)
        try await waitUntil { await gate.started }
        session.update(items: [.init(Self.page(0, chapter: "new")), .init(Self.page(1, chapter: "new"))], visible: [], context: "new")
        try await waitUntil { finished.count == 2 }
        #expect(finished == ["new", "new"])
        await gate.release()
        session.close()
        var newCalls = 0
        let newSession = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in newCalls += 1; return [Self.region] })
        defer { newSession.close() }
        newSession.update(items: [.init(Self.page(0, chapter: "new"))], visible: [], context: "new")
        newSession.enable(settings: fixture.settings)
        try await waitUntil { newCalls == 1 }
    }

    @Test func failedProbeOrAPIStopsWorkButBrokenImagesAreSkipped() async throws {
        let fixture = SessionFixture()
        for failureAtProbe in [true, false] {
            var calls = 0
            var errors = 0
            let session = ReaderTranslationSession(validate: { _ in
                if failureAtProbe { throw RemoteTranslationError.missingCredential }
            }, process: { page, _, _ in
                calls += 1
                if page.index == 0 { throw URLError(.cannotDecodeContentData) }
                throw RemoteTranslationError.httpStatus(401, requestID: nil)
            })
            defer { session.close() }
            session.onFailure = { _ in errors += 1 }
            session.update(items: (0..<4).map { .init(Self.page($0)) }, visible: [], context: "chapter")
            session.enable(settings: fixture.settings)
            try await waitUntil { errors == 1 }
            #expect(session.state == .off)
            #expect(calls == (failureAtProbe ? 0 : 2))
        }
    }

    @Test(arguments: [true, false])
    func failuresPreserveAutomaticPreferenceAndUserCanStillDisable(failureAtProbe: Bool) async throws {
        let fixture = SessionFixture()
        fixture.defaults.set(true, forKey: ReaderTranslationSettings.keyPrefix + "automatic")
        var shouldFail = true
        var failures = 0
        let session = ReaderTranslationSession(validate: { _ in
            if shouldFail && failureAtProbe { throw URLError(.timedOut) }
        }, process: { _, _, _ in
            if shouldFail { throw RemoteTranslationError.httpStatus(500, requestID: nil) }
            return []
        })
        let owner = SessionToolbarOwner()
        let coordinator = ReaderTranslationCoordinator(
            owner: owner, session: session, readSettings: { fixture.settings },
            setEnabled: { fixture.defaults.set($0, forKey: ReaderTranslationSettings.keyPrefix + "automatic") }
        )
        coordinator.install()
        let handleFailure = session.onFailure
        session.onFailure = { error in handleFailure?(error); failures += 1 }
        defer { coordinator.close() }
        session.update(items: [.init(Self.page(0))], visible: [], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { failures == 1 }
        #expect(session.state == .off)
        #expect(fixture.settings.automaticallyTranslate)
        shouldFail = false
        session.enable(settings: fixture.settings)
        try await waitUntil { session.state == .on }
        coordinator.toggle()
        #expect(!fixture.settings.automaticallyTranslate)
        #expect(session.state == .off)
    }

    @Test func displayChangesReuseResultsButLanguageChangeRetranslates() async throws {
        let fixture = SessionFixture()
        var settings = fixture.settings
        var calls = 0
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in calls += 1; return [Self.region] })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [], context: "chapter")
        session.enable(settings: settings)
        try await waitUntil { calls == 1 }
        settings.overlay.opacity = 0.6
        session.enable(settings: settings)
        #expect(calls == 1)
        settings.targetLanguage = "ja"
        session.enable(settings: settings)
        try await waitUntil { calls == 2 }
    }

    @Test func readerHasOneOnOffButtonAndNoMenu() async throws {
        let owner = SessionToolbarOwner()
        owner.navigationItem.title = "Chapter 1"
        owner.navigationItem.leftBarButtonItems = [
            UIBarButtonItem(systemItem: .close), UIBarButtonItem(image: UIImage(systemName: "list.bullet"))
        ]
        owner.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "safari")), UIBarButtonItem(image: UIImage(systemName: "textformat.size"))
        ]
        let fixture = SessionFixture()
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in [] })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session, readSettings: { fixture.settings }, setEnabled: { _ in })
        coordinator.install()
        defer { coordinator.close() }
        let buttons = try #require(owner.navigationItem.rightBarButtonItems)
        #expect(buttons.count == 3)
        #expect(buttons.allSatisfy { $0.title == nil && $0.image != nil && $0.menu == nil })
        if #available(iOS 26.0, *) { #expect(buttons.allSatisfy { $0.sharesBackground }) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: owner)
        navigation.navigationBar.tintColor = .white
        window.rootViewController = navigation
        window.overrideUserInterfaceStyle = .dark
        owner.view.backgroundColor = .black
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        session.enable(settings: fixture.settings)
        try await waitUntil { session.state == .on }
        #expect(buttons.last?.accessibilityValue == "ON")
        let directory = URL.documentsDirectory.appendingPathComponent("TranslationValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in ["on", "off"] {
            if state == "off" { coordinator.toggle() }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(image.pngData()).write(to: directory.appendingPathComponent("reader-translation-\(state).png"))
        }
        #expect(buttons.last?.accessibilityValue == "OFF")
    }

    @Test func leavingPagesReleasesOverlaysAndReturningReusesTranslation() async throws {
        let fixture = SessionFixture()
        let firstImage = UIImageView(image: Self.image())
        let secondImage = UIImageView(image: Self.image())
        let first = ReaderTranslationPage(imageView: firstImage)
        let second = ReaderTranslationPage(imageView: secondImage)
        first.sourcePage = Self.page(0)
        second.sourcePage = Self.page(1)
        var calls = 0
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in calls += 1; return [Self.region] })
        defer { session.close() }
        let items = [Self.page(0), Self.page(1)].map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [first], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls == 2 && !firstImage.subviews.isEmpty }
        session.update(items: items, visible: [second], context: "chapter")
        #expect(firstImage.subviews.isEmpty)
        #expect(!secondImage.subviews.isEmpty)
        first.applySettings(fixture.settings)
        #expect(firstImage.subviews.isEmpty)
        session.update(items: items, visible: [first], context: "chapter")
        #expect(!firstImage.subviews.isEmpty)
        #expect(secondImage.subviews.isEmpty)
        #expect(calls == 2)
        session.disable()
        #expect(firstImage.subviews.isEmpty && secondImage.subviews.isEmpty)
    }

    @Test func emptyTranslationDoesNotAllocateAnOverlay() {
        let fixture = SessionFixture()
        let imageView = UIImageView(image: Self.image())
        let page = ReaderTranslationPage(imageView: imageView)
        page.displayPrepared([], settings: fixture.settings)
        #expect(page.hasCompletedTranslation(settings: fixture.settings))
        #expect(imageView.subviews.isEmpty)
        page.showCompletedTranslation(settings: fixture.settings)
        #expect(imageView.subviews.isEmpty)
    }

    @Test func temporaryCacheRoundTripsAndSplitPagesMapBoxes() throws {
        let cache = ReaderTranslationSessionCache()
        try cache.store([Self.region], for: "key")
        let restored = try #require(cache.regions(for: "key")?.first)
        #expect(restored.source == Self.region.source)
        #expect(restored.translation == Self.region.translation)
        #expect(restored.rect == Self.region.rect)
        let left = try #require(restored.cropped(to: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        #expect(left.rect.minX == 0.2)
        #expect(abs(left.rect.width - 0.4) < 0.000001)
        #expect(restored.cropped(to: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)) == nil)
        cache.clear()
        #expect(!cache.contains("key"))
        #expect(cache.regions(for: "key") == nil)
    }

    @Test func hiddenPreloaderRunsRealOCRForUnvisitedImageWithoutOverlay() async throws {
        let fixture = SessionFixture()
        let preloader = ReaderTranslationPreloader(translator: { regions, _, _ in
            regions.map { var region = $0; region.translation = "미리 번역"; return region }
        })
        let result = try await preloader.translate(Self.page(0), settings: fixture.settings)
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0.translation == "미리 번역" })
        preloader.cancel()
        await ReaderOCRService.shared.purge()
    }

    static var region: ReaderTranslationRegion {
        .init(id: "line", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), source: "Hello", translation: "안녕")
    }
    static func page(_ index: Int, chapter: String = "chapter") -> Aidoku.Page {
        Aidoku.Page(sourceId: "unit-test", chapterId: chapter, index: index, image: image())
    }
    static func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            ("HELLO WORLD" as NSString).draw(at: CGPoint(x: 50, y: 90),
                                             withAttributes: [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black])
        }
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await condition()) {
            if Date() > deadline { throw SessionTestError.timeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum SessionTestError: Error { case timeout }
@MainActor private final class SessionToolbarOwner: UIViewController, ReaderTranslationOwner {
    let translationUpcomingPages: [Aidoku.Page] = []
    let translationVisiblePages: [ReaderTranslationPage] = []
    let translationChapterKey = "chapter"
}
@MainActor private final class SessionFixture {
    let suite = "AidokuTests.Session.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    var settings: ReaderTranslationSettings { ReaderTranslationSettings(defaults: defaults) }
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}
private actor SessionGate {
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor private final class UnindexedChapterOwner: UIViewController, ReaderTranslationOwner {
    let translationUpcomingPages: [Aidoku.Page]
    let translationChapterKey = "chapter"
    private let imageView = UIImageView(image: ReaderTranslationSessionTests.image())
    let page: ReaderTranslationPage
    var translationVisiblePages: [ReaderTranslationPage] { [page] }

    init(pages: [Aidoku.Page], current: Int) {
        translationUpcomingPages = pages
        page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = pages[current]
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
