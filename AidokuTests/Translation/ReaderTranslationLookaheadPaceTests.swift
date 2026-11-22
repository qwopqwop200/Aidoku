import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationLookaheadPaceTests {
    private func pace(secondsPerPage: Double, secondsPerTranslation: Double) -> ReaderTranslationLookaheadPace {
        var pace = ReaderTranslationLookaheadPace()
        for page in 0...3 { pace.pageChanged(chapter: "c", index: page, now: Double(page) * secondsPerPage) }
        pace.pageTranslated(started: 0, now: secondsPerTranslation)
        return pace
    }

    @Test func withoutMeasurementsTheFixedCountApplies() {
        let pace = ReaderTranslationLookaheadPace()
        #expect(pace.count(base: 4, limit: nil, growth: 4) == 4)
        #expect(pace.count(base: 4, limit: 3, growth: 4) == 3)
        #expect(pace.count(base: 4, limit: 0, growth: 4) == 0)
    }

    @Test func fastReadersGetMorePagesWithinLimitAndMemory() {
        let fast = pace(secondsPerPage: 2, secondsPerTranslation: 10)
        #expect(fast.count(base: 4, limit: nil, growth: 4) == 6)
        #expect(fast.count(base: 4, limit: 5, growth: 4) == 5)
        #expect(fast.count(base: 4, limit: nil, growth: 1) == 5)
        #expect(fast.count(base: 1, limit: nil, growth: 0) == 1)
    }

    @Test func slowReadersGetFewerPagesButAtLeastTwo() {
        let slow = pace(secondsPerPage: 30, secondsPerTranslation: 5)
        #expect(slow.count(base: 4, limit: nil, growth: 4) == 2)
        #expect(slow.count(base: 1, limit: nil, growth: 0) == 1)
        #expect(slow.count(base: 4, limit: 0, growth: 4) == 0)
    }

    @Test func jumpsReversalsAndOtherChaptersAreNotReadingPace() {
        var pace = ReaderTranslationLookaheadPace()
        pace.pageChanged(chapter: "c", index: 0, now: 0)
        pace.pageChanged(chapter: "c", index: 10, now: 1)
        pace.pageChanged(chapter: "c", index: 9, now: 2)
        pace.pageChanged(chapter: "d", index: 10, now: 3)
        #expect(pace.secondsPerPage == nil)
        pace.pageChanged(chapter: "d", index: 12, now: 7)
        #expect(pace.secondsPerPage == 2)
    }

    @Test func parallelPagesStillStartEarlyEnoughForTheirLatency() {
        var pace = ReaderTranslationLookaheadPace()
        for page in 0...3 { pace.pageChanged(chapter: "c", index: page, now: Double(page) * 2) }
        // Pages overlap: one finishes every 2 s, but each takes 4.3 s from start to finish.
        for finish in stride(from: 4.3, through: 12.3, by: 2) { pace.pageTranslated(started: finish - 4.3, now: finish) }
        #expect((pace.secondsPerTranslation ?? 0) < 3)
        #expect(pace.count(base: 2, limit: nil, growth: 6) == 4)
    }

    @Test func parallelPagesCountByThroughput() {
        var pace = ReaderTranslationLookaheadPace()
        pace.pageTranslated(started: 0, now: 4)
        pace.pageTranslated(started: 0, now: 6)
        #expect(abs((pace.secondsPerTranslation ?? 0) - 3.4) < 1e-9)
    }
}
