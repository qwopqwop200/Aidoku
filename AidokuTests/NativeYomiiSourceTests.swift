import AidokuRunner
import Foundation
import SwiftSoup
import Testing
@testable import Aidoku

struct NativeYomiiSourceTests {
    private static let listHTML = #"<ul id="free-genre-list"><li data-id="12"><span class="homelist-title"> Example </span><div class="homelist-thumb" style="background-image:url('https://cdn.test/cover.webp')"></div><div class="homelist-genre"><span>액션, 성인 (120화)</span></div></li></ul><a class="pg_next" href="?page=2">Next</a>"#

    @Test func recoveredListingSelectorsAndRating() throws {
        let document = try SwiftSoup.parse(Self.listHTML, "https://11toon.com")
        let cards = try YomiiSourceRunner.cards(document, sourceKey: "ko.yomii", completed: true)
        #expect(cards.count == 1)
        #expect(cards[0].key == "12")
        #expect(cards[0].title == "Example")
        #expect(cards[0].cover == "https://cdn.test/cover.webp")
        #expect(cards[0].tags == ["액션", "성인"])
        #expect(cards[0].contentRating == .suggestive)
        #expect(cards[0].status == .completed)
        #expect(cards[0].viewer == .rightToLeft)
        #expect(throws: YomiiSourceRunner.Failure.self) { try YomiiSourceRunner.listingItems("unknown") }
    }
}
