import Foundation
import Nuke
import Testing

@MainActor
struct NukeImageCacheLifetimeTests {
    @Test func releasingImageCacheUnregistersItsBackgroundObserver() async throws {
        var cache: Nuke.ImageCache? = Nuke.ImageCache(costLimit: 1_000, countLimit: 10)
        weak var releasedCache = cache
        weak var implementation: AnyObject?
        weak var observer: AnyObject?
        let deadline = Date().addingTimeInterval(3)
        while observer == nil {
            // Observe private lifetime without exposing a package testing API.
            // Neither Mirror nor its child values survive this autorelease pool.
            autoreleasepool {
                if let cache,
                   let impl = Mirror(reflecting: cache).children.first(where: { $0.label == "impl" })?.value {
                    implementation = impl as AnyObject
                    if let stored = Mirror(reflecting: impl).children.first(where: { $0.label == "notificationObserver" }),
                       let token = Mirror(reflecting: stored.value).children.first?.value {
                        observer = token as AnyObject
                    }
                }
            }
            if observer != nil { break }
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
        autoreleasepool { cache = nil }
        while observer != nil || implementation != nil || releasedCache != nil {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(releasedCache == nil)
        #expect(implementation == nil)
        #expect(observer == nil)
    }
}
