import Foundation
import Testing
@testable import Aidoku

@Suite struct FixedAPIDateFormatTests {
    @Test(arguments: ["th_TH", "ar_SA", "en_US@calendar=buddhist"])
    func trackerDatesUseGregorianYearsAndASCIIDigits(localeIdentifier: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12)))
        let ambient = DateFormatter()
        ambient.locale = Locale(identifier: localeIdentifier)
        ambient.dateFormat = "yyyy-MM-dd"
        // These settings reproduce the device-dependent output that the API must never receive.
        #expect(ambient.string(from: date) != "2026-09-23")

        let formatter = DateFormatter(fixedAPIFormat: "yyyy-MM-dd")
        #expect(formatter.calendar.identifier == .gregorian)
        #expect(formatter.locale.identifier == "en_US_POSIX")
        #expect(formatter.string(from: date) == "2026-09-23")
        #expect(date.dateString(format: "yyyy-MM-dd") == "2026-09-23")

        let parsed = try #require("2026-09-23".date(format: "yyyy-MM-dd"))
        #expect(calendar.dateComponents([.year, .month, .day], from: parsed)
            == DateComponents(year: 2026, month: 9, day: 23))
    }

    @Test func dateOnlyRetainsLocalMidnightAndTimestampHonorsOffset() throws {
        let parsed = try #require("2026-09-23".date(format: "yyyy-MM-dd"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        #expect(calendar.component(.hour, from: parsed) == 0)
        #expect(calendar.component(.minute, from: parsed) == 0)

        let timestamp = try #require("2026-09-23T21:00:00+09:00".date(format: "yyyy-MM-dd'T'HH:mm:ssZZZZZ"))
        #expect(ISO8601DateFormatter().string(from: timestamp) == "2026-09-23T12:00:00Z")
    }
}
