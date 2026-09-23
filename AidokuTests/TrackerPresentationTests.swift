import Foundation
import Testing
@testable import Aidoku

@Suite struct TrackerPresentationTests {
    @Test func readingDateCapabilityMatchesImplementedTrackers() {
        #expect(TrackerInfo(supportedStatuses: [], scoreType: .tenPoint).supportsReadingDates)
        #expect(MyAnimeListTracker().getTrackerInfo().supportsReadingDates)
        #expect(MangaBakaTracker().getTrackerInfo().supportsReadingDates)
        #expect(!ShikimoriTracker().getTrackerInfo().supportsReadingDates)
        #expect(!BangumiTracker().getTrackerInfo().supportsReadingDates)
        #expect(!KavitaTracker().getTrackerInfo().supportsReadingDates)
        #expect(!KomgaTracker().getTrackerInfo().supportsReadingDates)
        #expect(!SuwayomiTracker().getTrackerInfo().supportsReadingDates)
    }

    @Test func sourceTrackersOnlyExposeSupportedProgressControls() {
        let defaults = TrackerInfo(supportedStatuses: [], scoreType: .tenPoint)
        #expect(defaults.supportsScores)
        let kavita = KavitaTracker().getTrackerInfo()
        let komga = KomgaTracker().getTrackerInfo()
        let suwayomi = SuwayomiTracker().getTrackerInfo()
        for info in [kavita, komga, suwayomi] {
            #expect(!info.supportsScores)
            #expect(info.supportedStatuses.isEmpty)
        }
    }

    @Test func perWorkProgressUnitOnlyEnablesItsWritableFields() {
        let defaults = TrackState()
        #expect(defaults.progressUnit.supportsChapters)
        #expect(defaults.progressUnit.supportsVolumes)
        let chapters = TrackState(progressUnit: .chapters)
        #expect(chapters.progressUnit.supportsChapters)
        #expect(!chapters.progressUnit.supportsVolumes)
        let volumes = TrackState(progressUnit: .volumes)
        #expect(!volumes.progressUnit.supportsChapters)
        #expect(volumes.progressUnit.supportsVolumes)
    }

    @Test func nonBookSubjectsNeverBecomeNovelOrOneShot() {
        let tracker = BangumiTracker()
        for type in [2, 3, 4, 6, 99] {
            for series in [nil, false, true] as [Bool?] {
                let subject = BangumiSubject(id: 1, type: type, platform: "漫画", series: series)
                #expect(tracker.getSubjectType(for: subject) == .unknown)
            }
        }
    }

    @Test func bookSubjectClassificationIsPreserved() {
        let tracker = BangumiTracker()
        #expect(tracker.getSubjectType(for: .init(id: 1, type: 1, series: false)) == .oneShot)
        #expect(tracker.getSubjectType(for: .init(id: 1, type: 1, platform: "漫画", series: true)) == .manga)
        #expect(tracker.getSubjectType(for: .init(id: 1, type: 1, platform: "小说", series: true)) == .novel)
        #expect(tracker.getSubjectType(for: .init(id: 1, type: 1)) == .manga)
    }

    @Test func shikimoriMetadataTimestampsAreNotReadingDates() async {
        let rate = ShikimoriUserRate(
            id: 1, targetId: 2, targetType: "Manga", status: "completed",
            chapters: 20, volumes: 3, score: 9,
            createdAt: "2026-09-01T12:00:00.000Z",
            updatedAt: "2026-09-23T12:00:00.000Z"
        )
        let state = await ShikimoriApi().makeState(from: rate)
        #expect(state.status == .completed)
        #expect(state.score == 9)
        #expect(state.lastReadChapter == 20)
        #expect(state.lastReadVolume == 3)
        #expect(state.startReadDate == nil)
        #expect(state.finishReadDate == nil)
    }
}
