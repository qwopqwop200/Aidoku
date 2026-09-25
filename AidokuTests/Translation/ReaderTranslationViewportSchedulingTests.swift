import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationViewportSchedulingTests {
    @Test(arguments: [false, true])
    func scrubbingAndChapterChangesDoNotRetainOutgoingVisibleWork(changesChapter: Bool) async throws {
        let suite = "AidokuTests.ViewportScheduling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = Aidoku.Page(sourceId: "viewport", chapterId: "old", index: 0)
        let view = UIImageView()
        let page = ReaderTranslationPage(imageView: view)
        page.sourcePage = source
        let gate = ViewportSchedulingGate()
        var started = false
        var cancellations = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            started = true
            await gate.wait()
            return []
        }, cancelProcessing: { cancellations += 1 }, availableMemory: { .max })
        defer { session.close() }
        session.update(items: [.init(source)], visible: [page], context: "old")
        session.enable(settings: ReaderTranslationSettings(defaults: defaults))
        try await waitUntil { started }
        let baseline = cancellations
        let destination = changesChapter ? Aidoku.Page(sourceId: "viewport", chapterId: "new", index: 0) : nil
        session.pauseForPageTurn(preservingRecognitionFor: destination, visiblePages: [page])
        #expect(cancellations > baseline)
        await gate.release()
    }

    @Test func anchorAdvanceKeepsStillVisibleTranslationInFlight() async throws {
        let suite = "AidokuTests.ViewportScheduling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let sources = (0..<3).map { Aidoku.Page(sourceId: "viewport", chapterId: "chapter", index: $0) }
        let views = sources.map { _ in UIImageView() }
        let pages = zip(sources, views).map { source, view in
            let page = ReaderTranslationPage(imageView: view)
            page.sourcePage = source
            return page
        }
        let gate = ViewportSchedulingGate()
        let cache = ReaderTranslationSessionCache()
        var calls: [Int] = []
        var cancellations = 0
        let session = ReaderTranslationSession(process: { page, _, _ in
            calls.append(page.index)
            if page.index == 0 { await gate.wait() }
            return []
        }, cancelProcessing: { cancellations += 1 }, availableMemory: { .max }, cache: cache)
        defer { session.close() }
        let items = sources.map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [pages[0], pages[1]], context: "viewport", currentPageIndex: 0)
        session.enable(settings: settings)
        try await waitUntil { calls == [0] }
        let baseline = cancellations
        session.pauseForPageTurn(preservingRecognitionFor: sources[1], visiblePages: [pages[0], pages[1]])
        session.update(items: items, visible: [pages[0], pages[1]], context: "viewport", currentPageIndex: 1,
                       processUncachedPages: false)
        #expect(cancellations == baseline)
        await gate.release()
        // Pausing admission still permits this useful page to finish, but must
        // not let the retained worker sweep onward during scroll debounce.
        try await waitUntil { cache.contains(sources[0].translationCacheKey) }
        #expect(calls == [0])
        session.update(items: items, visible: [pages[0], pages[1]], context: "viewport", currentPageIndex: 1)
        // The anchor changed, but both pages still occupy the viewport.
        #expect(cancellations == baseline)
        #expect(calls == [0])
        try await waitUntil { calls.count == 3 }
        #expect(calls == [0, 1, 2])
    }

    @Test func leavingViewportPreemptsOldTranslationAndRejectsLateCompletion() async throws {
        let suite = "AidokuTests.ViewportScheduling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = (0..<3).map { Aidoku.Page(sourceId: "viewport", chapterId: "chapter", index: $0) }
        let views = sources.map { _ in UIImageView() }
        let pages = zip(sources, views).map { source, view in
            let page = ReaderTranslationPage(imageView: view)
            page.sourcePage = source
            return page
        }
        let gate = ViewportSchedulingGate()
        let destinationGate = ViewportSchedulingGate()
        let cache = ReaderTranslationSessionCache()
        var calls: [Int] = []
        var cancellations = 0
        var oldRequestReturned = false
        let session = ReaderTranslationSession(process: { page, _, _ in
            calls.append(page.index)
            if page.index == 0 { await gate.wait(); oldRequestReturned = true }
            else { await destinationGate.wait() }
            return []
        }, cancelProcessing: { cancellations += 1 }, availableMemory: { .max }, cache: cache)
        defer { session.close() }
        let items = sources.map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [pages[0]], context: "viewport", currentPageIndex: 0)
        session.enable(settings: ReaderTranslationSettings(defaults: defaults))
        try await waitUntil { calls == [0] }
        let baseline = cancellations
        session.update(items: items, visible: [pages[2]], context: "viewport", currentPageIndex: 2)
        try await waitUntil { calls.count == 2 }
        #expect(cancellations > baseline)
        #expect(calls == [0, 2])
        await gate.release()
        // The cancelled old task must not publish its late result.
        try await waitUntil { oldRequestReturned }
        #expect(!cache.contains(sources[0].translationCacheKey))
        session.close()
        await destinationGate.release()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { throw ViewportSchedulingError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum ViewportSchedulingError: Error { case timeout }

private actor ViewportSchedulingGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
