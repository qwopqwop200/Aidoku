import Testing
import UIKit
import UserNotifications
@testable import Aidoku

@MainActor struct NotificationDelegateTests {
    @Test(arguments: ["simple-id", "series/chapter", "a?query#fragment", "a%2Fb", "한글/作品 ?#"])
    func notificationMangaKeyRemainsOneDeepLinkComponent(key: String) throws {
        let url = try #require(AppDelegate.notificationURL(sourceId: "source.example", mangaId: key))
        // Same split-before-decoding contract used by AppDelegate.handleUrl.
        let components = url.percentEncodedPath.split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
        #expect(url.host == "source.example")
        #expect(components == [key])
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        if key == "simple-id" {
            #expect(url.absoluteString == "aidoku://source.example/simple-id")
        }
    }

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
