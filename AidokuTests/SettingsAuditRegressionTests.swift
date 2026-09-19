import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct SettingsAuditRegressionTests {
    private func manga() -> DownloadedMangaInfo {
        .init(sourceId: "audit", mangaId: "metadata", totalSize: 100, chapterCount: 1, pageCount: 24, isInLibrary: false)
    }

    @Test func libraryStatusUpdateRetainsDownloadedPageCount() {
        let model = DownloadedMangaView.ViewModel(manga: manga())
        model.updateMangaLibraryStatus(to: true)
        #expect(model.manga.isInLibrary)
        #expect(model.manga.pageCount == 24)
    }

    @Test func chapterRepairRefreshesFailureAndTitleWithoutSizeChange() {
        let model = DownloadedMangaView.ViewModel(manga: manga())
        model.chapters = [.init(chapterId: "chapter", title: "Old", size: 100, failed: true)]
        model.updateChaptersSelectively(newChapters: [.init(chapterId: "chapter", title: "Repaired", size: 100, failed: false)])
        #expect(model.chapters.first?.failed == false)
        #expect(model.chapters.first?.title == "Repaired")
    }

    @Test func logAppendPreservesPrefixesAndExistingText() throws {
        let controller = LogViewController()
        controller.loadViewIfNeeded()
        controller.logEntry(entry: .init(date: Date(), type: .info, message: "first"))
        controller.logEntry(entry: .init(date: Date(), type: .error, message: "second"))
        let textView = try #require(controller.view.subviews.compactMap { $0 as? UITextView }.first)
        #expect(textView.text == "[INFO] first\n[ERROR] second\n")
    }

    @Test func disappearingLogViewerReleasesController() async {
        weak var released: LogViewController?
        do {
            let controller = LogViewController()
            released = controller
            controller.loadViewIfNeeded()
            controller.viewWillAppear(false)
            await Task.yield()
            controller.viewDidDisappear(false)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(released == nil)
    }
    @Test func progressCanResetBeforePreviousOperationFinishes() throws {
        let progress = CircularProgressView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        progress.draw(progress.bounds)
        progress.setProgress(value: 0.6, withAnimation: false)
        let shape = try #require(progress.layer.sublayers?.last as? CAShapeLayer)
        #expect(abs(shape.strokeEnd - 0.6) < 0.001)
        progress.setProgress(value: 0, withAnimation: false)
        #expect(shape.strokeEnd == 0)
    }

    @Test func unsetBooleanObserverUsesItsDeclaredDefault() {
        let key = "audit.boolean.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let observer = UserDefaultsBool(key: key, defaultValue: true)
        #expect(observer.value)
        observer.value = false
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
    }

    @Test func repeatedNoClipUsesOneClassAndDoesNotRecurse() {
        let first = UIView()
        first.clipsToBounds = true
        first.forceNoClip()
        let initialClass = object_getClass(first)
        first.forceNoClip()
        first.clipsToBounds = true
        #expect(!first.clipsToBounds)
        #expect(object_getClass(first) === initialClass)
        let second = UIView()
        second.forceNoClip()
        #expect(object_getClass(second) === initialClass)
        second.clipsToBounds = true
        #expect(!second.clipsToBounds)
    }

}
