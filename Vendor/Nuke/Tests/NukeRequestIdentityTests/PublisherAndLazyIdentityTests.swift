import Combine
import Foundation
import Testing
@testable import Nuke
@testable import NukeUI

struct PublisherAndLazyIdentityTests {
    @Test func repeatedDemandEmitsOnlyOneMemoryResultAndCompletion() {
        let pipeline = ImagePipeline { $0.imageCache = ImageCache() }
        let request = ImageRequest(url: URL(string: "https://safety.invalid/demand")!)
        pipeline.cache[request] = ImageContainer(image: PlatformImage())
        let subscriber = SafetySubscriber()
        pipeline.imagePublisher(with: request).subscribe(subscriber)
        subscriber.subscription?.request(.max(1))
        subscriber.subscription?.request(.max(1))
        #expect(subscriber.values == 1)
        #expect(subscriber.completions == 1)
    }

    @Test func cancellationBeforeDemandPreventsDelivery() {
        let pipeline = ImagePipeline { $0.imageCache = ImageCache() }
        let request = ImageRequest(url: URL(string: "https://safety.invalid/cancel-before-demand")!)
        pipeline.cache[request] = ImageContainer(image: PlatformImage())
        let subscriber = SafetySubscriber()
        pipeline.imagePublisher(with: request).subscribe(subscriber)
        subscriber.subscription?.cancel()
        subscriber.subscription?.request(.max(1))
        #expect(subscriber.values == 0)
        #expect(subscriber.completions == 0)
    }

    @Test func cancellationDuringDeliverySuppressesCompletion() {
        let pipeline = ImagePipeline { $0.imageCache = ImageCache() }
        let request = ImageRequest(url: URL(string: "https://safety.invalid/reentrant-cancel")!)
        pipeline.cache[request] = ImageContainer(image: PlatformImage())
        let subscriber = SafetySubscriber(cancelOnValue: true)
        pipeline.imagePublisher(with: request).subscribe(subscriber)
        subscriber.subscription?.request(.max(1))
        #expect(subscriber.values == 1)
        #expect(subscriber.completions == 0)
    }

    @Test func cancellationReleasesReentrantSubscriberOutsideStateLock() throws {
        let pipeline = ImagePipeline { $0.imageCache = nil }
        let request = ImageRequest(url: URL(string: "https://safety.invalid/deinit-cancel")!)
        var subscriber: ReentrantDeinitSubscriber? = ReentrantDeinitSubscriber()
        weak var releasedSubscriber = subscriber
        pipeline.imagePublisher(with: request).subscribe(try #require(subscriber))
        let subscription = try #require(subscriber?.subscription)
        subscriber = nil
        #expect(releasedSubscriber != nil)
        subscription.cancel()
        #expect(releasedSubscriber == nil)
    }

    @Test func lazyImageIdentityIncludesScaleAndThumbnail() {
        let request = ImageRequest(url: URL(string: "https://safety.invalid/lazy-identity")!)
        let original = LazyImageContext(request: request)
        #expect(original == LazyImageContext(request: request))
        var changed = request
        changed.scale = 2
        #expect(original != LazyImageContext(request: changed))
        changed = request
        changed.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: 128)
        #expect(original != LazyImageContext(request: changed))
        let thumbnail = LazyImageContext(request: changed)
        changed.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: 256)
        #expect(thumbnail != LazyImageContext(request: changed))
    }
}

private final class ReentrantDeinitSubscriber: Subscriber, @unchecked Sendable {
    typealias Input = ImageResponse
    typealias Failure = ImagePipeline.Error
    var subscription: (any Subscription)?
    func receive(subscription: any Subscription) { self.subscription = subscription }
    func receive(_ input: ImageResponse) -> Subscribers.Demand { .none }
    func receive(completion: Subscribers.Completion<ImagePipeline.Error>) {}
    deinit { subscription?.cancel() }
}

private final class SafetySubscriber: Subscriber, @unchecked Sendable {
    typealias Input = ImageResponse
    typealias Failure = ImagePipeline.Error
    private let lock = NSLock()
    private var receivedSubscription: (any Subscription)?
    private var valueCount = 0
    private var completionCount = 0
    private let cancelOnValue: Bool
    init(cancelOnValue: Bool = false) { self.cancelOnValue = cancelOnValue }
    var subscription: (any Subscription)? { lock.withLock { receivedSubscription } }
    var values: Int { lock.withLock { valueCount } }
    var completions: Int { lock.withLock { completionCount } }
    func receive(subscription: any Subscription) { lock.withLock { receivedSubscription = subscription } }
    func receive(_ input: ImageResponse) -> Subscribers.Demand {
        lock.withLock { valueCount += 1 }
        if cancelOnValue { subscription?.cancel() }
        return .none
    }
    func receive(completion: Subscribers.Completion<ImagePipeline.Error>) { lock.withLock { completionCount += 1 } }
}
