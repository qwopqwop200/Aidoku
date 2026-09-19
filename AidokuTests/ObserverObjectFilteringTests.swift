import Testing
import UIKit
@testable import Aidoku

@MainActor
struct ObserverObjectFilteringTests {
    @Test func viewControllerFiltersRequestedObject() {
        let controller = BaseObservingViewController()
        let name = Notification.Name(UUID().uuidString)
        let expected = NSObject()
        var filtered = 0
        var all = 0
        controller.addObserver(forName: name, object: expected) { _ in filtered += 1 }
        controller.addObserver(forName: name.rawValue) { _ in all += 1 }
        NotificationCenter.default.post(name: name, object: NSObject())
        NotificationCenter.default.post(name: name, object: expected)
        NotificationCenter.default.post(name: name, object: nil)
        #expect(filtered == 1)
        #expect(all == 3)
    }

    @Test func cellNodeFiltersRequestedObject() {
        let node = BaseObservingCellNode()
        let name = Notification.Name(UUID().uuidString)
        let expected = NSObject()
        var filtered = 0
        var all = 0
        node.addObserver(forName: name.rawValue, object: expected) { _ in filtered += 1 }
        node.addObserver(forName: name) { _ in all += 1 }
        NotificationCenter.default.post(name: name, object: NSObject())
        NotificationCenter.default.post(name: name, object: expected)
        NotificationCenter.default.post(name: name, object: nil)
        #expect(filtered == 1)
        #expect(all == 3)
    }
}
