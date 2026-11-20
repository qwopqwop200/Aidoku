import AidokuRunner
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderWebtoonLifecycleTests {
    @Test func malformedChapterNumbersDoNotCrashTransitionLabels() {
        let view = ReaderInfoPageView(type: .next)
        #expect(view.chapterDifference(higherChapterNumber: 12.5, lowerChapterNumber: 9.2) == 3)
        for number in [Float.infinity, -.infinity, .nan, .greatestFiniteMagnitude] {
            #expect(view.chapterDifference(higherChapterNumber: number, lowerChapterNumber: 1) == 0)
            #expect(view.chapterDifference(higherChapterNumber: 1, lowerChapterNumber: number) == 0)
        }
    }

    @Test func navigationBeforeChapterHasLoadedIsSafe() {
        let controller = ReaderPagedViewController(source: nil,
            manga: AidokuRunner.Manga(sourceKey: "test", key: "manga", title: "Test"),
            temporaryPageStore: ReaderTemporaryPageStore())
        controller.move(toPage: 1, animated: false)
    }
}
