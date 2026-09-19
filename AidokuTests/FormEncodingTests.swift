import Foundation
import Testing
@testable import Aidoku

@Suite struct FormEncodingTests {
    @Test func encodesReservedCharactersInsideFormValues() throws {
        let data = try #require(["token": "a+b&c=d /?日本語"].percentEncoded())
        #expect(String(decoding: data, as: UTF8.self) == "token=a%2Bb%26c%3Dd%20%2F%3F%E6%97%A5%E6%9C%AC%E8%AA%9E")
    }
    @Test func encodesKeysAndRetainsUnreservedCharacters() throws {
        let data = try #require(["a&b": "AZaz09-._~"].percentEncoded())
        #expect(String(decoding: data, as: UTF8.self) == "a%26b=AZaz09-._~")
    }
}
