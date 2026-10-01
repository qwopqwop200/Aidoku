#if os(iOS) || os(tvOS) || os(visionOS)
import Foundation
import Testing
@testable import Nuke

struct CacheObserverLifetimeTests {
    @Test @MainActor
    func cacheReleasesItsBackgroundNotificationRegistration() async throws {
        var cache: Cache<String, Int>? = Cache(costLimit: 1_000, countLimit: 10)
        weak var releasedCache = cache
        weak var observer: AnyObject?
        let deadline = Date().addingTimeInterval(3)
        while observer == nil {
            // Inspect the actual private registration without adding a production
            // testing hook or retaining the token beyond this autorelease pool.
            autoreleasepool {
                if let cache,
                   let stored = Mirror(reflecting: cache).children.first(where: { $0.label == "notificationObserver" }),
                   let token = Mirror(reflecting: stored.value).children.first?.value {
                    observer = token as AnyObject
                }
            }
            if observer != nil { break }
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
        autoreleasepool { cache = nil }
        while observer != nil || releasedCache != nil {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(releasedCache == nil)
        #expect(observer == nil)
    }
}
#endif
