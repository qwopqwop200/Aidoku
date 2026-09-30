import XCTest
@testable import Aidoku

final class AuditSourceBoundaryRegressionTests: XCTestCase {
    func testDuplicateMarkersAfterEmojiUseUTF16Ranges() {
        let prefix = String(repeating: "👩‍👩‍👧‍👦", count: 20)
        XCTAssertEqual(LocalFileNameParser.parseMangaVolume(from: prefix + " Vol 4 ch 2 - vol 6 omakes.cbz"), "4")
        XCTAssertEqual(LocalFileNameParser.parseMangaChapter(from: prefix + " ch 2 - ch 6 extras.cbz"), "2")
    }

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
