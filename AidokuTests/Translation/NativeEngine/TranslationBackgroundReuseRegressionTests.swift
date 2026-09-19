import XCTest
@testable import Aidoku

final class TranslationBackgroundReuseRegressionTests: XCTestCase {
    func testBackgroundFilterChangeInvalidatesVisibleReuse() throws {
        let configuration = RemoteTranslationConfiguration.openAI(model: "test")
        var request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", sourceText: "文字")
        let before = try XCTUnwrap(NativeTranslationReuseIdentity.identitiesBySegmentID(configuration: configuration, request: request).values.first)
        request.filtersBackground = true
        let after = try XCTUnwrap(NativeTranslationReuseIdentity.identitiesBySegmentID(configuration: configuration, request: request).values.first)
        XCTAssertFalse(before.canRemainVisibleWhileRefreshing(expected: after))
        XCTAssertFalse(before.hasSameTranslationConfiguration(as: after))
        XCTAssertTrue(after.hasSameTranslationConfiguration(as: after))
    }
}
