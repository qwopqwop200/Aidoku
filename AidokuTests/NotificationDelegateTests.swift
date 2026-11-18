import AidokuRunner
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

    @Test func notificationLinkAwaitsInstalledSourceBeforeOpeningManga() async throws {
        let delegate = RoutingDelegate()
        let key = "series/한글"
        let url = try #require(AppDelegate.notificationURL(sourceId: "local", mangaId: key))
        var lookedUp: [String] = []
        await delegate.handleSourceURL(url) { host in
            lookedUp.append(host)
            await Task.yield()
            return .local()
        }
        #expect(lookedUp == ["local"])
        let controller = try #require(delegate.navigationController?.topViewController as? MangaViewController)
        #expect(controller.manga.key == key)
        #expect(controller.manga.sourceKey == "local")
    }

    @Test func launchCleanupDeletesOnlySessionsPresentAtLaunch() async throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("ReaderSessions", isDirectory: true)
        let old = root.appendingPathComponent("old", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data([1]).write(to: old.appendingPathComponent("page.png"))
        let shared = fixture.appendingPathComponent("SharedImageSessions")
        let outside = fixture.appendingPathComponent("other", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("keep")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([2]).write(to: outsideFile)
        try fm.createSymbolicLink(at: shared, withDestinationURL: outside)

        let cleanup = try #require(AppDelegate.removePreviousReaderSessions(in: [root, shared]))
        let current = root.appendingPathComponent("new")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        await cleanup.value
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: current.path))
        #expect(!fm.fileExists(atPath: shared.path))
        #expect(try Data(contentsOf: outsideFile) == Data([2]))
    }
}

@MainActor private final class RoutingDelegate: AppDelegate {
    private let navigation = UINavigationController(rootViewController: UIViewController())
    override var navigationController: UINavigationController? { navigation }
}
