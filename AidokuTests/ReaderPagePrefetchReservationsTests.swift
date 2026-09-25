import Testing
@testable import Aidoku

struct ReaderPagePrefetchReservationsTests {
    @Test func cancelledPreparationRetriesOnlyUnsubmittedPages() {
        var scheduler = ReaderPagePrefetchReservations()
        let first = scheduler.reserve(count: 5, chapterKey: "next", sourceKey: "source")
        // Two requests reached Nuke; cancellation interrupted preparation of page 3.
        scheduler.finish(first, submitted: [0, 1])
        let retry = scheduler.reserve(count: 5, chapterKey: "next", sourceKey: "source")
        #expect(retry.indices == [2, 3, 4])
    }

    @Test func overlappingExpansionDoesNotDuplicateOrLoseWorkOnCancellation() {
        var scheduler = ReaderPagePrefetchReservations()
        let first = scheduler.reserve(count: 3, chapterKey: "next", sourceKey: "source")
        let expanded = scheduler.reserve(count: 5, chapterKey: "next", sourceKey: "source")
        #expect(expanded.indices == [3, 4])
        scheduler.finish(expanded, submitted: [3, 4])
        scheduler.finish(first, submitted: [])
        #expect(scheduler.reserve(count: 5, chapterKey: "next", sourceKey: "source").indices == [0, 1, 2])
    }

    @Test func resetWhilePreparingCannotReleaseNewGenerationReservation() {
        var scheduler = ReaderPagePrefetchReservations()
        let stale = scheduler.reserve(count: 3, chapterKey: "next", sourceKey: "source")
        scheduler.reset()
        let current = scheduler.reserve(count: 3, chapterKey: "next", sourceKey: "source")
        #expect(current.indices == [0, 1, 2])
        scheduler.finish(stale, submitted: [])
        #expect(scheduler.reserve(count: 3, chapterKey: "next", sourceKey: "source").indices.isEmpty)
    }

    @Test func sameChapterKeyInDifferentSourceIsIndependent() {
        var scheduler = ReaderPagePrefetchReservations()
        let first = scheduler.reserve(count: 2, chapterKey: "chapter-1", sourceKey: "a")
        scheduler.finish(first, submitted: [0, 1])
        #expect(scheduler.reserve(count: 2, chapterKey: "chapter-1", sourceKey: "b").indices == [0, 1])
    }

    @Test func completedPrefixStaysDeduplicatedAndNegativeCountIsEmpty() {
        var scheduler = ReaderPagePrefetchReservations()
        #expect(scheduler.reserve(count: -1, chapterKey: "next", sourceKey: "source").indices.isEmpty)
        let first = scheduler.reserve(count: 2, chapterKey: "next", sourceKey: "source")
        scheduler.finish(first, submitted: [0, 1])
        #expect(scheduler.reserve(count: 2, chapterKey: "next", sourceKey: "source").indices.isEmpty)
        #expect(scheduler.reserve(count: 4, chapterKey: "next", sourceKey: "source").indices == [2, 3])
    }
}
