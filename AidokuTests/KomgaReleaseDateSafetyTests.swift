import Foundation
import Testing
@testable import Aidoku

struct KomgaReleaseDateSafetyTests {
    @Test(arguments: [Int.min, Int.max], [false, true])
    func extremeRemoteYearThrowsInsteadOfCrashing(year: Int, excluded: Bool) {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(KomgaSearchCondition.releaseDate(year, exclude: excluded))
        }
    }

    @Test(arguments: [1900, 2000, 2024], [false, true])
    func normalYearsPreserveExactPayload(year: Int, excluded: Bool) throws {
        // Independently form the established wire structure from Calendar boundaries.
        // Use the same calendar/time zone as production; no new Gregorian assumption.
        let calendar = Calendar.current
        let start = try #require(calendar.date(from: DateComponents(year: year, month: 1, day: 1)))
        let next = try #require(calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)))
        let end = try #require(calendar.date(byAdding: .day, value: -1, to: next))
        let previousEnd = try #require(calendar.date(byAdding: .day, value: -1, to: start))
        struct Boundary: Encodable {
            struct Value: Encodable {
                let `operator`: String
                let dateTime: Date?
            }
            let releaseDate: Value
            init(_ operation: String, _ date: Date? = nil) {
                releaseDate = .init(operator: operation, dateTime: date)
            }
        }
        let expected = excluded
            ? ["anyOf": [Boundary("after", end), Boundary("before", start), Boundary("isNull")]]
            : ["allOf": [Boundary("after", previousEnd), Boundary("before", next)]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        #expect(try encoder.encode(KomgaSearchCondition.releaseDate(year, exclude: excluded)) == encoder.encode(expected))
    }

    @Test(arguments: [false, true])
    func unspecifiedYearPreservesNullPredicate(excluded: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let actual = try encoder.encode(KomgaSearchCondition.releaseDate(nil, exclude: excluded))
        let expected = try encoder.encode(["releaseDate": ["operator": excluded ? "isNull" : "isNotNull"]])
        #expect(actual == expected)
    }
}
