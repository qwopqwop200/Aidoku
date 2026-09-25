import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct DownloadHostAdmissionTests {
    private func input() throws -> Data {
        try #require(UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        }.pngData())
    }

    private var regions: [ReaderTranslationRegion] {
        [ReaderTranslationRegion(id: "host", rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.3),
                                 source: "Hello", translation: "번역")]
    }

    @Test func absentHostLeavesImagePermitFreeAndCancelsWithoutProcessing() async throws {
        let probe = DownloadHostProbe()
        let budget = TranslationImageWorkBudget(availableMemory: { .max })
        let data = try input()
        let download = Task {
            try await DownloadImageTranslator.translate(data, settings: ReaderTranslationSettings(),
                imageBudget: budget, environment: probe.environment) { _, _ in
                    probe.processCount += 1
                    return []
                }
        }
        defer { download.cancel() }
        try await waitUntil { probe.waitCount > 0 }
        let visible = Task { try await budget.withPermit { true } }
        defer { visible.cancel() }
        let acquired = DownloadHostFlag()
        let observer = Task { acquired.value = (try? await visible.value) == true }
        defer { observer.cancel() }
        try await waitUntil { acquired.value }
        #expect(probe.processCount == 0)
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }
    }

    @Test func activationLossAfterProcessingReleasesPixelsAndDoesNotRepeatProcessor() async throws {
        let probe = DownloadHostProbe()
        probe.host = UIView()
        let budget = TranslationImageWorkBudget(availableMemory: { .max })
        let data = try input()
        let prepared = regions
        let download = Task {
            try await DownloadImageTranslator.translate(data, settings: ReaderTranslationSettings(),
                imageBudget: budget, environment: probe.environment) { image, _ in
                    probe.processCount += 1
                    probe.sourceImage = image
                    probe.host = nil
                    return prepared
                }
        }
        defer { download.cancel() }
        try await waitUntil { probe.waitCount > 0 }
        // Only compact regions survive the readiness retry; source pixels leave
        // the admitted attempt before the next readiness wait begins.
        try await waitUntil { probe.sourceImage == nil }
        #expect(probe.processCount == 1)
        let visible = Task { try await budget.withPermit { true } }
        defer { visible.cancel() }
        #expect(try await visible.value)
        probe.host = UIView()
        let output = try await download.value
        #expect(UIImage(data: output)?.size == UIImage(data: data)?.size)
        #expect(probe.processCount == 1)
        #expect(probe.renderCount == 1)
    }

    @Test func activationLossWhileQueuedRechecksBeforeProcessor() async throws {
        let probe = DownloadHostProbe()
        probe.host = UIView()
        let budget = TranslationImageWorkBudget(availableMemory: { .max })
        let occupied = DownloadHostFlag()
        let owner = Task {
            try await budget.withPermit {
                await MainActor.run { occupied.value = true }
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { owner.cancel() }
        try await waitUntil { occupied.value }
        let data = try input()
        let download = Task {
            try await DownloadImageTranslator.translate(data, settings: ReaderTranslationSettings(),
                imageBudget: budget, environment: probe.environment) { _, _ in
                    probe.processCount += 1
                    return []
                }
        }
        defer { download.cancel() }
        try await waitUntil { probe.hostChecks > 0 }
        probe.host = nil
        owner.cancel()
        _ = try? await owner.value
        try await waitUntil { probe.waitCount > 0 }
        #expect(probe.processCount == 0)
        probe.host = UIView()
        #expect(try await download.value == data)
        #expect(probe.processCount == 1)
    }

    @Test func exporterActivationRaceKeepsPreparedRegions() async throws {
        let probe = DownloadHostProbe()
        probe.host = UIView()
        probe.failFirstRenderForActivationLoss = true
        let data = try input()
        let prepared = regions
        let download = Task {
            try await DownloadImageTranslator.translate(data, settings: ReaderTranslationSettings(),
                imageBudget: TranslationImageWorkBudget(availableMemory: { .max }),
                environment: probe.environment) { _, _ in
                    probe.processCount += 1
                    return prepared
                }
        }
        defer { download.cancel() }
        try await waitUntil { probe.waitCount > 0 }
        #expect(probe.processCount == 1)
        probe.host = UIView()
        _ = try await download.value
        #expect(probe.processCount == 1)
        #expect(probe.renderCount == 2)
    }

    /// Run unchanged against the frozen production baseline with only the same
    /// dependency seam. Controlled 300 ms host absence measures image admission,
    /// without provider latency, WebKit timing, or a model substitution.
    @Test func hostWaitLatencyProbe() async throws {
        let probe = DownloadHostProbe()
        let budget = TranslationImageWorkBudget(availableMemory: { .max })
        let data = try input()
        let download = Task {
            try await DownloadImageTranslator.translate(data, settings: ReaderTranslationSettings(),
                imageBudget: budget, environment: probe.environment) { _, _ in
                    probe.processCount += 1
                    return []
                }
        }
        defer { download.cancel() }
        try await waitUntil { probe.waitCount > 0 }
        let start = ContinuousClock.now
        let readiness = Task {
            try await Task.sleep(for: .milliseconds(300))
            probe.host = UIView()
        }
        defer { readiness.cancel() }
        let visible = try await budget.withPermit { ContinuousClock.now }
        let duration = start.duration(to: visible)
        let milliseconds = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        let beforeHost = probe.host == nil
        #expect(try await download.value == data)
        #expect(probe.processCount == 1)
        print("DOWNLOAD_HOST_ADMISSION visible_wait_ms=\(milliseconds) visible_before_host=\(beforeHost)")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor private final class DownloadHostFlag { var value = false }

@MainActor private final class DownloadHostProbe {
    var host: UIView?
    var hostChecks = 0
    var waitCount = 0
    var processCount = 0
    var renderCount = 0
    var failFirstRenderForActivationLoss = false
    weak var sourceImage: UIImage?

    var environment: DownloadImageTranslator.RenderEnvironment {
        .init(currentHost: {
            self.hostChecks += 1
            return self.host
        }, wait: {
            await self.recordWait()
            try await Task.sleep(for: .milliseconds(5))
        }, render: { image, _, _, _ in
            self.renderCount += 1
            if self.failFirstRenderForActivationLoss, self.renderCount == 1 {
                self.host = nil
                throw ReaderTranslationImageExporter.ExportError.unavailable
            }
            return image
        })
    }

    private func recordWait() { waitCount += 1 }
}
