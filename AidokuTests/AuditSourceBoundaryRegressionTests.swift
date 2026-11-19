import XCTest
@testable import Aidoku

final class AuditSourceBoundaryRegressionTests: XCTestCase {
    func testOversizedCustomSourceStringLengthThrows() {
        let encoded = Data([1] + Array(repeating: UInt8(0xff), count: 9) + [0x01])
        XCTAssertThrowsError(try CustomSourceConfig(from: encoded))
    }

    func testNonfiniteSuwayomiDatesAreRejected() {
        XCTAssertNil(Date(suwayomiTimestamp: "nan"))
        XCTAssertNil(Date(suwayomiTimestamp: "inf"))
        XCTAssertEqual(Date(suwayomiTimestamp: "1000"), Date(timeIntervalSince1970: 1000))
    }

}
