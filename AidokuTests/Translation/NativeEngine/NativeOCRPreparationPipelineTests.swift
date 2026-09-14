import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativeOCRPreparationPipelineTests {
    @Test func overlapsExactlyOneWindowAndPreservesConsumptionOrder() async throws {
        let probe = OCRPreparationProbe()
        let gate = OCRPreparationGate()
        let task = Task {
            try await NativeOCRPreparationPipeline.run(Array(0..<5), prepare: { value in
                probe.prepared(value)
                return value
            }, consume: { value in
                probe.consumed(value)
                if value == 0 { try await gate.wait() }
            })
        }
        do {
            try await eventually { probe.preparedValues.count == 2 && probe.consumedValues == [0] }
            #expect(probe.preparedValues == [0, 1])
            await gate.open()
            try await task.value
            #expect(probe.preparedValues == Array(0..<5))
            #expect(probe.consumedValues == Array(0..<5))
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test func inferenceFailureCancelsAndJoinsLookahead() async throws {
        let probe = OCRPreparationProbe()
        let task = Task {
            try await NativeOCRPreparationPipeline.run([0, 1, 2], prepare: { value in
                probe.prepared(value)
                if value == 1 {
                    defer { probe.finishedLookahead() }
                    try await Task.sleep(for: .seconds(30))
                }
                return value
            }, consume: { _ in
                try await eventually { probe.preparedValues == [0, 1] }
                throw PreparationTestError.inference
            })
        }
        await #expect(throws: PreparationTestError.inference) { try await task.value }
        #expect(probe.lookaheadFinished)
        #expect(probe.preparedValues == [0, 1])
    }

    @Test func preparationFailureNeverPublishesTheFailedOrFollowingWindow() async throws {
        let probe = OCRPreparationProbe()
        await #expect(throws: PreparationTestError.preparation) {
            try await NativeOCRPreparationPipeline.run([0, 1, 2], prepare: { value in
                probe.prepared(value)
                if value == 1 { throw PreparationTestError.preparation }
                return value
            }, consume: { probe.consumed($0) })
        }
        #expect(probe.preparedValues == [0, 1])
        #expect(probe.consumedValues == [0])
    }

    @Test func parentCancellationStopsBothPhasesAndReturnsNoLateResults() async throws {
        let probe = OCRPreparationProbe()
        let task = Task {
            try await NativeOCRPreparationPipeline.run([0, 1, 2], prepare: { value in
                probe.prepared(value)
                if value == 1 {
                    defer { probe.finishedLookahead() }
                    try await Task.sleep(for: .seconds(30))
                }
                return value
            }, consume: { value in
                probe.consumed(value)
                try await Task.sleep(for: .seconds(30))
            })
        }
        do { try await eventually { probe.preparedValues == [0, 1] } } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.lookaheadFinished)
        #expect(probe.consumedValues == [0])
    }

    @Test func emptyInputDoesNoWorkAndSingleWindowIsConsumedOnce() async throws {
        let probe = OCRPreparationProbe()
        for input in [[], [42]] {
            try await NativeOCRPreparationPipeline.run(input, prepare: { value in
                probe.prepared(value)
                return value
            }, consume: { probe.consumed($0) })
        }
        #expect(probe.preparedValues == [42])
        #expect(probe.consumedValues == [42])
        #expect(NativeCoreMLRecognizer.maximumPreparedWindowRegionCount * 2 == NativeCoreMLRecognizer.maximumPreparedRegionCount)
        #expect(NativeCoreMLRecognizer.maximumPreparedTensorBytes == 9_216_000)
    }
}

private enum PreparationTestError: Error { case inference, preparation, timeout }

private func eventually(_ predicate: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw PreparationTestError.timeout }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private actor OCRPreparationGate {
    private var isOpen = false
    func open() { isOpen = true }
    func wait() async throws {
        while !isOpen { try await Task.sleep(for: .milliseconds(1)) }
    }
}

private final class OCRPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var preparedStorage: [Int] = []
    private var consumedStorage: [Int] = []
    private var finished = false
    var preparedValues: [Int] { lock.withLock { preparedStorage } }
    var consumedValues: [Int] { lock.withLock { consumedStorage } }
    var lookaheadFinished: Bool { lock.withLock { finished } }
    func prepared(_ value: Int) { lock.withLock { preparedStorage.append(value) } }
    func consumed(_ value: Int) { lock.withLock { consumedStorage.append(value) } }
    func finishedLookahead() { lock.withLock { finished = true } }
}
