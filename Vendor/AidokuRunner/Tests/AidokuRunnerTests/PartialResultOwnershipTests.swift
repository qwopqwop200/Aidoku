import Foundation
import Testing
@testable import AidokuRunner

struct PartialResultOwnershipTests {
    @Test func lateRemovalAndLatePartialCannotAffectReplacementSubscriber() async {
        let publisher = SinglePublisher<Int>()
        let first = Values(), second = Values()
        let a = await publisher.sink { first.append($0) }
        await publisher.send(1, to: a)
        let b = await publisher.sink { second.append($0) }
        await publisher.removeSink(token: a)
        await publisher.send(2, to: a)
        await publisher.send(3, to: b)
        #expect(first.snapshot == [1])
        #expect(second.snapshot == [3])
        await publisher.removeSink(token: b)
        await publisher.send(4, to: b)
        #expect(second.snapshot == [3])
    }

    @Test func requestOwnerSurvivesAsyncHopAfterSubscriberReplacement() async {
        let publisher = SinglePublisher<Int>()
        let values = Values()
        let a = await publisher.sink { _ in }
        let b = await publisher.sink { values.append($0) }
        await PartialResultSubscription.$id.withValue(a) {
            let owner = await SubscriptionHop().owner()
            #expect(owner == a)
            await publisher.send(1, to: owner)
        }
        await PartialResultSubscription.$id.withValue(b) {
            await publisher.send(2, to: await SubscriptionHop().owner())
        }
        #expect(values.snapshot == [2])
        #expect(PartialResultSubscription.id == nil)
    }
}
private actor SubscriptionHop { func owner() -> UUID? { PartialResultSubscription.id } }
private final class Values: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}
