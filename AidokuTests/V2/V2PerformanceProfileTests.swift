import Foundation
import Testing
@testable import Aidoku

/// The build-time V2 performance profile (`AIDOKU_DEVELOPER_PERFORMANCE`).
struct V2PerformanceProfileTests {
    private let mib: UInt64 = 1_024 * 1_024
    private let gib: UInt64 = 1_024 * 1_024 * 1_024

    @Test func normalProfileKeepsShippedLimits() {
        let normal = V2PerformanceProfile.normal
        #expect(normal.minimumHeadroom == 1_280 * mib)
        #expect(normal.requiredHeadroom(decodedBytes: 1_000 * mib) == 3_512 * mib)
        #expect(normal.pageCacheMinimumBytes == V2PageMemoryCache.minimumBytes)
        #expect(normal.pageCacheMaximumBytes == V2PageMemoryCache.maximumBytes)
        #expect(normal.pageCacheSpareDivisor == 4)
        #expect(normal.frontSlots == 2 && normal.backSlots == 2)
        #expect(normal.lookaheadCount(automatic: 2) == 2)
        #expect(normal.providerConcurrency(setting: 16) == 3)
        for memory in [3 * gib, 6 * gib, 8 * gib, 12 * gib, 64 * gib] {
            for cores in [1, 6, 10] {
                #expect(V2PerformanceProfile.resolve(developer: false, physicalMemory: memory, processorCount: cores) == normal)
            }
        }
    }

    @Test func testHostsUseNormalProfile() {
        #expect(V2PerformanceProfile.current == .normal)
        #expect(TranslationImageWorkBudget.minimumHeadroom == 1_280 * mib)
    }

    @Test func developerProfileStaysNormalBelowSixGigabytes() {
        #expect(V2PerformanceProfile.resolve(developer: true, physicalMemory: 4 * gib, processorCount: 6) == .normal)
    }

    @Test func developerProfileScalesWithPhysicalMemory() {
        let six = V2PerformanceProfile.resolve(developer: true, physicalMemory: 6 * gib, processorCount: 6)
        #expect(six.minimumHeadroom == 896 * mib && six.decodeReserve == 384 * mib)
        #expect(six.pageCacheMinimumBytes == Int(64 * mib) && six.pageCacheMaximumBytes == Int(320 * mib))
        #expect(six.pageCacheSpareDivisor == 3)
        #expect(six.frontSlots == 3 && six.backSlots == 3)
        #expect(six.lookaheadCount(automatic: 1) == 2 && six.providerConcurrency(setting: 16) == 4)

        let eight = V2PerformanceProfile.resolve(developer: true, physicalMemory: 8 * gib, processorCount: 8)
        #expect(eight.minimumHeadroom == 768 * mib && eight.decodeReserve == 320 * mib)
        #expect(eight.pageCacheMaximumBytes == Int(512 * mib))
        #expect(eight.frontSlots == 3 && eight.backSlots == 4)
        #expect(eight.lookaheadCount(automatic: 2) == 4 && eight.providerConcurrency(setting: 16) == 6)

        let twelve = V2PerformanceProfile.resolve(developer: true, physicalMemory: 12 * gib, processorCount: 10)
        #expect(twelve.minimumHeadroom == 640 * mib && twelve.decodeReserve == 256 * mib)
        #expect(twelve.pageCacheMinimumBytes == Int(96 * mib) && twelve.pageCacheMaximumBytes == Int(768 * mib))
        #expect(twelve.pageCacheSpareDivisor == 2)
        #expect(twelve.frontSlots == 4 && twelve.backSlots == 4)
        #expect(twelve.lookaheadCount(automatic: 2) == 5 && twelve.providerConcurrency(setting: 16) == 8)
    }

    @Test func developerProfileClampsToCoresMemoryAndSettings() {
        // Few cores: never more slots than half the cores, never below normal.
        let slow = V2PerformanceProfile.resolve(developer: true, physicalMemory: 12 * gib, processorCount: 4)
        #expect(slow.frontSlots == 2 && slow.backSlots == 2)
        let six = V2PerformanceProfile.resolve(developer: true, physicalMemory: 12 * gib, processorCount: 6)
        #expect(six.frontSlots == 3 && six.backSlots == 3)
        // A "6 GB" iPhone reports about 5.5 GiB: the page cache stays within 1/16 of it.
        let reported = UInt64(5.5 * Double(gib))
        let phone = V2PerformanceProfile.resolve(developer: true, physicalMemory: reported, processorCount: 6)
        #expect(phone.pageCacheMaximumBytes == Int(320 * mib))
        #expect(UInt64(phone.pageCacheMaximumBytes) <= reported / 16)
        #expect(phone.minimumHeadroom >= V2PerformanceProfile.safetyMargin)
        // The user's lower provider setting still wins; zero is still one request.
        #expect(phone.providerConcurrency(setting: 2) == 2 && phone.providerConcurrency(setting: 0) == 1)
        #expect(phone.requiredHeadroom(decodedBytes: .max) == .max)
    }

    @Test func pageCacheBudgetFollowsProfile() {
        let twelve = V2PerformanceProfile.resolve(developer: true, physicalMemory: 12 * gib, processorCount: 10)
        #expect(V2PageMemoryCache.byteLimit(available: 0, current: 0, profile: twelve) == Int(96 * mib))
        #expect(V2PageMemoryCache.byteLimit(available: 8 * gib, current: 0, profile: twelve) == Int(768 * mib))
        // 1 GB spare above the 640 MB reserve, halved.
        #expect(V2PageMemoryCache.byteLimit(available: 1_664 * mib, current: 0, profile: twelve) == Int(512 * mib))
        // Normal: a quarter of the spare above 1.25 GB, 32-192 MB.
        #expect(V2PageMemoryCache.byteLimit(available: 1_792 * mib, current: 0) == Int(128 * mib))
        #expect(V2PageMemoryCache.byteLimit(available: 8 * gib, current: 0) == V2PageMemoryCache.maximumBytes)
    }
}
