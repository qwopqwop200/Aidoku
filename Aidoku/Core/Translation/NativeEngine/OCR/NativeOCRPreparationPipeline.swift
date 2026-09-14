import Foundation

/// One current window and one lookahead window. Preparation overlaps serial
/// inference without allowing an unbounded queue of image tensors. Both phases
/// are children of the caller: failure/cancellation joins outstanding work.
enum NativeOCRPreparationPipeline {
    static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        prepare: @escaping @Sendable (Input) async throws -> Output,
        consume: (Output) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let first = inputs.first else { return }
        try await withThrowingTaskGroup(of: Output.self) { group in
            group.addTask { try Task.checkCancellation(); return try await prepare(first) }
            var next = 1
            while let prepared = try await group.next() {
                try Task.checkCancellation()
                if next < inputs.count {
                    let input = inputs[next]
                    next += 1
                    group.addTask { try Task.checkCancellation(); return try await prepare(input) }
                }
                try await consume(prepared)
                try Task.checkCancellation()
            }
        }
    }
}
