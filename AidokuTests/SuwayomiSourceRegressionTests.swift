import AidokuRunner
import XCTest
@testable import Aidoku

final class SuwayomiSourceRegressionTests: XCTestCase {
    func testSimpleLoginUsesServerFieldNamesAndPreservesSpecialCharacters() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/login.html"))
        let request = SuwayomiHelper.simpleLoginRequest(url: url, username: "reader+one", password: "a+b &c=한글")
        let data = try XCTUnwrap(request.httpBody)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertFalse(body.contains("+"))
        var components = URLComponents()
        components.percentEncodedQuery = body.replacingOccurrences(of: "+", with: " ")
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.map(\.name), ["user", "pass"])
        XCTAssertEqual(items.map(\.value), ["reader+one", "a+b &c=한글"])
    }

    func testInvalidLoginPageIsNotAcceptedAsSuccessfulSession() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/login.html"))
        let denied = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "session=; Max-Age=0"]))
        let accepted = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 303, httpVersion: nil, headerFields: ["Location": "/"]))
        XCTAssertFalse(SuwayomiHelper.isSuccessfulSimpleLogin(denied))
        XCTAssertTrue(SuwayomiHelper.isSuccessfulSimpleLogin(accepted))
    }

    func testSuwayomiOnHiatusStatusIsPreserved() throws {
        let node = try JSONDecoder().decode(SuwayomiMangaNode.self, from: Data(#"{"id":1,"title":"Example","status":"ON_HIATUS"}"#.utf8))
        let manga = try XCTUnwrap(node.intoManga(sourceKey: "test", baseUrl: URL(string: "https://example.invalid")!))
        XCTAssertEqual(manga.status, .hiatus)
    }
}
