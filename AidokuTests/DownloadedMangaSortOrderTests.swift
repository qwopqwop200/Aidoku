import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct DownloadedMangaSortOrderTests {
    @Test func toggleSortsChapterTitlesNumericallyAndPersistsDirection() {
        let key = "Flag.downloadChapterSortAscending"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let info = DownloadedMangaInfo(sourceId: "test.sort." + UUID().uuidString, mangaId: "book", title: "Sort",
            totalSize: 0, chapterCount: 120, isInLibrary: false)
        // Coprime permutation: every number is unique, and numeric order differs
        // from lexicographic order ("Chapter 10" sorts after "Chapter 9").
        let chapters = (1...120).map { index in
            let value = (index * 37) % 120 + 1
            return DownloadedChapterInfo(chapterId: "Chapter \(value)", title: "Chapter \(value)", size: 0)
        }
        let expected = (1...120).map { "Chapter \($0)" }
        let vm = DownloadedMangaView.ViewModel(manga: info)
        for ascending in [true, false, true] {
            vm.sortAscending = !ascending
            vm.chapters = chapters
            vm.toggleSortOrder()
            #expect(vm.sortAscending == ascending)
            #expect(AppSettings.flags.downloadChapterSortAscending.get() == ascending)
            #expect(vm.chapters.map(\.chapterId) == (ascending ? expected : expected.reversed()))
        }
    }
}
