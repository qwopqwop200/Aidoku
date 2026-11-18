import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct ReadingInsightsTests {
    @Test func streakIncludesUnlinkedDaysAndTotalsUseTheSessionEndMonth() throws {
        let manager = CoreDataManager.shared
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: manager.container.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: "/dev/null"))
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let calendar = Calendar.current
        let newYear = try #require(calendar.dateInterval(of: .year, for: Date())?.start)
        let previousDay = try #require(calendar.date(byAdding: .day, value: -1, to: newYear))
        let earlierDay = try #require(calendar.date(byAdding: .day, value: -2, to: newYear))
        let history = HistoryObject(context: context)
        history.sourceId = "insights"
        history.mangaId = "series"
        history.chapterId = "chapter"

        func addSession(ending end: Date, pages: Int16, history: HistoryObject?) {
            let session = ReadingSessionObject(context: context)
            session.endDate = end
            session.startDate = end.addingTimeInterval(-3600)
            session.pagesRead = pages
            session.history = history
        }
        addSession(ending: earlierDay, pages: 7, history: history)
        addSession(ending: previousDay, pages: 30, history: nil)
        addSession(ending: newYear, pages: 8, history: history)
        addSession(ending: newYear.addingTimeInterval(60), pages: 9, history: history)
        try context.save()

        let stats = manager.getBasicStats(context: context, now: newYear)
        #expect(stats.currentStreak == 3 && stats.longestStreak == 3)
        #expect(stats.pagesTotal == 24 && stats.pagesYear == 17 && stats.pagesMonth == 17)
        #expect(stats.hoursTotal == 3 && stats.hoursYear == 2 && stats.hoursMonth == 2)
        #expect(stats.seriesTotal == 1 && stats.seriesYear == 1 && stats.seriesMonth == 1)
    }
}
