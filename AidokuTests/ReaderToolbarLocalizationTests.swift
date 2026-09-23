import Foundation
import Testing
import UIKit
@testable import Aidoku

@MainActor
struct ReaderToolbarLocalizationTests {
    @Test func previewUpdatesBothCountsWithoutCommittingProgress() throws {
        let toolbar = ReaderToolbarView()
        toolbar.totalPages = 349
        toolbar.currentPage = 15
        toolbar.displayPage(300)

        let position = try #require(toolbar.subviews.compactMap { $0 as? UILabel }.first { $0.textAlignment == .center })
        let remaining = try #require(toolbar.subviews.compactMap { $0 as? UILabel }.first { $0.textAlignment == .right })
        #expect(position.text == String(format: NSLocalizedString("PAGE_X_OF_X"), 300, 349))
        #expect(remaining.text == String(format: NSLocalizedString("%i_PAGES_LEFT"), 49))
        #expect(toolbar.currentPage == 15)
        #expect(toolbar.currentPageValue == 300)

        toolbar.updatePageLabels()
        #expect(position.text == String(format: NSLocalizedString("PAGE_X_OF_X"), 15, 349))
        #expect(remaining.text == String(format: NSLocalizedString("%i_PAGES_LEFT"), 334))
    }

    @Test func previewClampsAndHandlesLastPageAndUnavailableTotals() throws {
        let toolbar = ReaderToolbarView()
        toolbar.totalPages = 3
        toolbar.currentPage = 1
        let position = try #require(toolbar.subviews.compactMap { $0 as? UILabel }.first { $0.textAlignment == .center })
        let remaining = try #require(toolbar.subviews.compactMap { $0 as? UILabel }.first { $0.textAlignment == .right })

        toolbar.displayPage(2)
        #expect(remaining.text == NSLocalizedString("ONE_PAGE_LEFT"))
        toolbar.displayPage(Int.max)
        #expect(toolbar.currentPageValue == 3)
        #expect(position.text == String(format: NSLocalizedString("PAGE_X_OF_X"), 3, 3))
        #expect(remaining.text == nil)
        toolbar.displayPage(Int.min)
        #expect(toolbar.currentPageValue == 1)
        #expect(remaining.text == String(format: NSLocalizedString("%i_PAGES_LEFT"), 2))

        for total: Int? in [0, -1, nil] {
            toolbar.totalPages = total
            toolbar.displayPage(2)
            #expect(position.text == nil)
            #expect(remaining.text == nil)
            #expect(toolbar.currentPageValue == nil)
            #expect(toolbar.currentPage == 1)
        }
    }
}
