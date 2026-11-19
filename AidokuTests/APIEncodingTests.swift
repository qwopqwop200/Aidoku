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
}

@Suite struct FormEncodingTests {
    @Test func encodesReservedCharactersInsideFormValues() throws {
        let data = try #require(["token": "a+b&c=d /?日本語"].percentEncoded())
        #expect(String(decoding: data, as: UTF8.self) == "token=a%2Bb%26c%3Dd%20%2F%3F%E6%97%A5%E6%9C%AC%E8%AA%9E")
    }
}

@Suite struct JSONAnyValueTests {
    @Test func numbersOutsideIntegerRangeDoNotCrash() throws {
        for text in ["1e30", "-1e30", "9223372036854775808"] {
            let value = try JSONDecoder().decode(JSONAnyValue.self, from: Data(text.utf8))
            #expect(value.intValue == nil)
            #expect(value.doubleValue == Double(text))
        }
        #expect(JSONAnyValue.double(.infinity).intValue == nil)
        #expect(JSONAnyValue.double(.nan).intValue == nil)
    }
}
