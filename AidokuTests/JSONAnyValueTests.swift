import Foundation
import Testing
@testable import Aidoku

@Suite struct JSONAnyValueTests {
    @Test func decimalsKeepDoublePrecision() throws {
        let text = "1.23456789012345"
        let value = try JSONDecoder().decode(JSONAnyValue.self, from: Data(text.utf8))
        #expect(value.doubleValue == Double(text))
        #expect(value.intValue == 1)
    }

    @Test func numbersOutsideIntegerRangeDoNotCrash() throws {
        for text in ["1e30", "-1e30", "9223372036854775808"] {
            let value = try JSONDecoder().decode(JSONAnyValue.self, from: Data(text.utf8))
            #expect(value.intValue == nil)
            #expect(value.doubleValue == Double(text))
        }
        #expect(JSONAnyValue.double(.infinity).intValue == nil)
        #expect(JSONAnyValue.double(.nan).intValue == nil)
    }

    @Test func nullRoundTrips() throws {
        let data = try JSONEncoder().encode(JSONAnyValue.null())
        #expect(String(decoding: data, as: UTF8.self) == "null")
        #expect(try JSONDecoder().decode(JSONAnyValue.self, from: data).type == .null)
    }
}
