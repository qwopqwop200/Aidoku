import AidokuRunner
import Testing
import UIKit
@testable import Aidoku

@MainActor struct ReaderNavigationLifetimeTests {
    @Test func replacingStackReleasesOriginalReader() async {
        weak var original: ReaderViewController?
        let replacement = UIViewController()
        let navigation = autoreleasepool {
            let reader = ReaderViewController(source: nil,
                manga: .init(sourceKey: "navigation-lifetime", key: "book", title: "Book"),
                chapter: .init(key: "chapter"))
            original = reader
            let navigation = ReaderNavigationController(readerViewController: reader)
            #expect(original != nil)
            navigation.setViewControllers([replacement], animated: false)
            return navigation
        }

        // UIKit may defer releasing the displaced stack. Drain local autoreleases
        // and allow pending main-actor work while keeping navigation alive below.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while original != nil, ContinuousClock.now < deadline {
            await Task.yield()
        }

        #expect(original == nil)
        #expect(navigation.viewControllers.count == 1)
        #expect(navigation.topViewController === replacement)
    }
}
