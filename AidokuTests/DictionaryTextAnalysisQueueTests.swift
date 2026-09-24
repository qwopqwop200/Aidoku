import Testing
@testable import Aidoku

@Suite(.serialized)
struct DictionaryTextAnalysisQueueTests {
    @Test func cancelledWaiterLeavesQueueBeforeActiveOCRFinishes() async throws {
        guard #available(iOS 18.0, *) else { return }
        let queue = DictionaryTextAnalysisQueue()
        try await queue.waitForTurn()
        let waiting = Task {
            await queue.run { Issue.record("Cancelled queued OCR must not execute") }
        }
        for _ in 0..<100 where await queue.queuedCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await queue.queuedCount == 1)
        waiting.cancel()
        for _ in 0..<100 where await queue.queuedCount != 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        // The running OCR deliberately still owns its turn. Cancellation must
        // release the queued closure/image without waiting for that OCR.
        #expect(await queue.queuedCount == 0)
        await queue.finishTurn()
        await waiting.value
        try await queue.waitForTurn()
        await queue.finishTurn()
    }

    @Test func cancellingMiddleWaiterPreservesSurvivingFIFOAndSingleAdmission() async throws {
        guard #available(iOS 18.0, *) else { return }
        let queue = DictionaryTextAnalysisQueue()
        let recorder = QueueOrderRecorder()
        try await queue.waitForTurn()
        var tasks: [Task<Void, Never>] = []
        for index in 0..<3 {
            tasks.append(Task { await queue.run { await recorder.append(index) } })
            for _ in 0..<100 where await queue.queuedCount != index + 1 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await queue.queuedCount == index + 1)
        }
        tasks[1].cancel()
        for _ in 0..<100 where await queue.queuedCount != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.values.isEmpty)
        await queue.finishTurn()
        for task in tasks { await task.value }
        #expect(await recorder.values == [0, 2])
        #expect(await queue.queuedCount == 0)
    }
}

private actor QueueOrderRecorder {
    var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
