import Testing
import UIKit
import UserNotifications
@testable import Aidoku

@MainActor struct NotificationDelegateTests {
    @Test func foregroundPresentationIsAnObjectiveCDelegateWitness() throws {
        let delegate = AppDelegate()
        let selector = NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")
        #expect(delegate.responds(to: selector))
        let method = try #require(class_getInstanceMethod(AppDelegate.self, selector))
        typealias Completion = @convention(block) (Int) -> Void
        typealias Implementation = @convention(c) (AnyObject, Selector, UNUserNotificationCenter, UNNotification?, Completion) -> Void
        let invoke = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        var received: [Int] = []
        let completion: Completion = { received.append($0) }
        // UNNotification has no public initializer. This delegate deliberately
        // does not inspect the notification, so exercise its actual ObjC entry
        // with nil for that unused argument and verify the delivered callback.
        invoke(delegate, selector, .current(), nil, completion)
        let expected: UNNotificationPresentationOptions = [.banner, .sound, .list]
        #expect(received == [Int(expected.rawValue)])
    }
}
