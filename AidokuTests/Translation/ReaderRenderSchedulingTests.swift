import Testing
import UIKit
@testable import Aidoku

@MainActor
struct ReaderRenderSchedulingTests {
    @Test func visibleCompositePrecedesEarlierSpeculativeCompositeWithoutChangingPixels() async throws {
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let occupied = RenderSchedulingLatch()
        let visible = RenderSchedulingLatch()
        defer { Task { await occupied.release(); await visible.release() } }
        let blocker = Task { try await limiter.withPermit { await occupied.wait() } }
        defer { blocker.cancel() }
        try await waitUntil { await occupied.isWaiting }
        let (source, asset) = fixture()
        let speculative = Task {
            try await ReaderTranslationImageExporter.compositeLoadedImage(
                source, asset: asset, size: source.size, priority: .prefetch, limiter: limiter)
        }
        defer { speculative.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 1 }
        let foreground = Task {
            try await limiter.withPermit(priority: .foreground) { await visible.wait() }
        }
        defer { foreground.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 2 }
        await occupied.release()
        try await waitUntil { await visible.isWaiting }
        // The real speculative composite must still be queued while visible work owns the slot.
        #expect(await limiter.queuedRequestCount == 1)
        await visible.release()
        try await blocker.value
        try await foreground.value
        let result = try await speculative.value
        let expected = try ReaderTranslationImageExporter.composite(
            image: source, typography: asset.typography, layers: asset.layers,
            displayRect: asset.displayRect, size: source.size)
        #expect(result.pngData() == expected.pngData())
    }

    @Test func cancelledSpeculativeCompositeLeavesQueueBeforeTheSlotIsAvailable() async throws {
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let occupied = RenderSchedulingLatch()
        defer { Task { await occupied.release() } }
        let blocker = Task { try await limiter.withPermit { await occupied.wait() } }
        defer { blocker.cancel() }
        try await waitUntil { await occupied.isWaiting }
        let (source, asset) = fixture()
        let speculative = Task {
            try await ReaderTranslationImageExporter.compositeLoadedImage(
                source, asset: asset, size: source.size, priority: .prefetch, limiter: limiter)
        }
        try await waitUntil { await limiter.queuedRequestCount == 1 }
        speculative.cancel()
        do {
            _ = try await speculative.value
            Issue.record("Cancelled queued composite unexpectedly produced pixels")
        } catch is CancellationError {} catch { throw error }
        #expect(await limiter.queuedRequestCount == 0)
        await occupied.release()
        try await blocker.value
    }

    private func fixture() -> (UIImage, ReaderTranslationRenderAsset) {
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(bounds)
        }
        let typography = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.red.setFill()
            context.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
        }
        return (source, ReaderTranslationRenderAsset(typography: typography,
            layers: .init(masks: [], surfaces: [], paintBounds: []), displayRect: bounds,
            sourceSize: bounds.size, regions: [], sourceDigest: nil))
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw RenderSchedulingTimeout.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum RenderSchedulingTimeout: Error { case expired }

private actor RenderSchedulingLatch {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
