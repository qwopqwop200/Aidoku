import Foundation
import Testing
@testable import Aidoku

struct TranslationPromotionSourceTests {
    @Test func composedPriorityObservesPromotionAfterCreation() {
        let consumer = TranslationRequestPromotion()
        let shared = TranslationRequestPromotion(foregroundSource: { consumer.isForeground })
        #expect(!shared.isForeground)
        #expect(TranslationRequestPriority.promotable(shared).schedulingRank == 1)
        consumer.promote()
        #expect(shared.isForeground)
        #expect(TranslationRequestPriority.promotable(shared).schedulingRank == 0)
    }

    @Test func explicitPromotionStaysForegroundAfterSourceDemandDisappears() {
        let demand = PromotionSourceDemand()
        let shared = TranslationRequestPromotion(foregroundSource: { demand.value })
        demand.value = true
        #expect(shared.isForeground)
        demand.value = false
        #expect(!shared.isForeground)
        shared.promote()
        demand.value = true
        demand.value = false
        #expect(shared.isForeground)
    }

    @Test func sourceCallbackCanPromoteWithoutHoldingPromotionLock() {
        let reference = WeakPromotionSourceReference()
        let shared = TranslationRequestPromotion(foregroundSource: {
            reference.value?.promote()
            return true
        })
        reference.value = shared
        #expect(shared.isForeground)
        #expect(shared.isForeground)
    }
}

private final class PromotionSourceDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var demand = false
    var value: Bool {
        get { lock.withLock { demand } }
        set { lock.withLock { demand = newValue } }
    }
}

private final class WeakPromotionSourceReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var promotion: TranslationRequestPromotion?
    var value: TranslationRequestPromotion? {
        get { lock.withLock { promotion } }
        set { lock.withLock { promotion = newValue } }
    }
}
