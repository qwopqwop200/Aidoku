import Testing
import UIKit
@testable import Aidoku

@MainActor
struct LibraryCategoryHeaderLifetimeTests {
    @Test func populatedMenuDoesNotRetainReleasedHeader() {
        weak var releasedHeader: LibraryCategorySelectionHeader?
        autoreleasepool {
            let header = LibraryCategorySelectionHeader(frame: .zero)
            header.options = [.init(options: ["All", "Uncategorized"]), .init(title: "Categories", options: ["A", "B"])]
            header.setSelectedOption(IndexPath(row: 1, section: 1))
            header.lockedOptions = [IndexPath(row: 0, section: 1)]
            releasedHeader = header
        }
        #expect(releasedHeader == nil)
    }

    @Test func collectionLayoutDoesNotRetainItsController() {
        weak var releasedController: MangaCollectionViewController?
        autoreleasepool {
            let controller = MangaCollectionViewController()
            _ = controller.collectionView
            releasedController = controller
        }
        #expect(releasedController == nil)
    }

    @Test func selectionStillNotifiesDelegateExactlyOnce() {
        final class Delegate: LibraryCategorySelectionHeaderDelegate {
            var selections: [IndexPath] = []
            func optionSelected(_ indexPath: IndexPath) { selections.append(indexPath) }
        }
        let delegate = Delegate()
        let header = LibraryCategorySelectionHeader(frame: .zero)
        header.options = [.init(options: ["All", "Uncategorized"])]
        header.delegate = delegate
        let selected = IndexPath(row: 1, section: 0)
        header.setSelectedOption(selected)
        header.setSelectedOption(selected)
        #expect(delegate.selections == [selected])
    }
}
