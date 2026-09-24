import Testing
import UIKit
@testable import Aidoku

/// Tests the reader's completed-only presentation contract independently of
/// stream parsing: the processor deliberately publishes both OCR and partial text.
@Suite(.serialized) @MainActor
struct ReaderTranslationCompletedOnlyRegressionTests {
    @Test func pendingProgressKeepsSourceUntilFinalTranslationCommits() async throws {
        let fixture = try CompletedOnlyFixture()
        defer { fixture.close() }
        var published = false
        var release = false
        var unfinished = fixture.region
        unfinished.translation = nil
        let ocr = unfinished
        let session = ReaderTranslationSession(process: { _, _, progress in
            try await progress?([ocr])
            for index in 0..<20 {
                var partial = fixture.region
                partial.translation = "중간 \(index)"
                try await progress?([partial])
            }
            published = true
            while !release { try await Task.sleep(for: .milliseconds(5)) }
            return [fixture.region]
        }, availableMemory: { .max })
        defer { session.close() }
        session.update(items: [.init(fixture.source)], visible: [fixture.page], context: "completed-only")
        session.enable(settings: fixture.settings)
        try await wait { published }
        // Allow the former coalesced provisional render to run, if present.
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.imageView.image === fixture.original)
        expectNoPendingPresentation(in: fixture.imageView)
        #expect(fixture.page.regions.isEmpty)
        #expect(!fixture.page.isShowingProvisionalTranslation)
        #expect(!fixture.page.canExportTranslation)
        #expect(!fixture.page.hasCompletedTranslation(settings: fixture.settings))
        release = true
        try await wait { fixture.page.hasCompletedTranslation(settings: fixture.settings) }
        #expect(fixture.page.regions == [fixture.region])
        #expect(fixture.page.canExportTranslation)
        #expect(!fixture.page.isShowingProvisionalTranslation)
        let overlay = try #require(fixture.imageView.subviews.first as? ReaderTranslationOverlayView)
        try await wait { overlay.lastDiagnostic?.outcome == .committed }
        #expect(!overlay.isHidden)
    }

    @Test(arguments: [false, true])
    func failureOrCancellationNeverExposesPendingText(fails: Bool) async throws {
        let fixture = try CompletedOnlyFixture()
        defer { fixture.close() }
        var published = false
        var release = false
        var failed = false
        var lateProgress: ReaderTranslationService.Progress?
        let session = ReaderTranslationSession(process: { _, _, progress in
            lateProgress = progress
            try await progress?([fixture.region])
            published = true
            while !release { try await Task.sleep(for: .milliseconds(5)) }
            throw RemoteTranslationError.refused
        }, availableMemory: { .max })
        session.onFailure = { _ in failed = true }
        defer { session.close() }
        session.update(items: [.init(fixture.source)], visible: [fixture.page], context: "completed-only-failure")
        session.enable(settings: fixture.settings)
        try await wait { published }
        try await Task.sleep(for: .milliseconds(300))
        expectNoPendingPresentation(in: fixture.imageView)
        #expect(!fixture.page.isShowingProvisionalTranslation)
        if fails {
            release = true
            try await wait { failed }
        } else {
            session.disable()
        }
        try? await lateProgress?([fixture.region])
        session.refreshVisiblePages([fixture.page])
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.imageView.image === fixture.original)
        #expect(fixture.imageView.subviews.isEmpty)
        #expect(fixture.page.regions.isEmpty)
        #expect(!fixture.page.canExportTranslation)
        #expect(!fixture.page.hasCompletedTranslation(settings: fixture.settings))
    }

    private func expectNoPendingPresentation(in imageView: UIImageView) {
        // Navigation may prepare one empty document, but neither OCR nor partial
        // translations may paint before the completed-result commit.
        #expect(imageView.subviews.count <= 1)
        for view in imageView.subviews {
            let overlay = view as? ReaderTranslationOverlayView
            #expect(overlay != nil)
            #expect(view.isHidden)
            #expect(overlay?.webView.isHidden == true)
            #expect(overlay?.lastDiagnostic?.outcome != .committed)
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor private final class CompletedOnlyFixture {
    let original: UIImage
    let imageView: UIImageView
    let source: Page
    let page: ReaderTranslationPage
    let settings: ReaderTranslationSettings
    let window: UIWindow
    let suite = "AidokuTests.CompletedOnly." + UUID().uuidString
    // Binary-exact fractions isolate presentation policy from bbox round-trip rounding.
    let region = ReaderTranslationRegion(id: "first", rect: CGRect(x: 0.125, y: 0.125, width: 0.625, height: 0.25),
                                         source: "Hello world", translation: "안녕 세계")

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        settings = ReaderTranslationSettings(defaults: defaults)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        original = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            ("Hello world" as NSString).draw(at: CGPoint(x: 30, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        imageView = UIImageView(image: original)
        imageView.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        source = Page(sourceId: "completed-only", chapterId: suite, index: 0, image: original)
        page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = source
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(imageView)
        window.makeKeyAndVisible()
    }

    func close() { window.isHidden = true }

    deinit {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
