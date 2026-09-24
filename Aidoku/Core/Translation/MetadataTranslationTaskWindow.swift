/// Bound suspended metadata child tasks as well as active provider requests.
/// This does not change provider admission/priority or truncate the input.
enum MetadataTranslationTaskWindow {
    static let maximumTasks = 64

    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], fallback: (Input) -> Output,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        var output = inputs.map(fallback)
        await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            while next < min(maximumTasks, inputs.count), !Task.isCancelled {
                let index = next
                group.addTask { (index, await operation(inputs[index])) }
                next += 1
            }
            for await (index, value) in group {
                output[index] = value
                guard !Task.isCancelled, next < inputs.count else { continue }
                let index = next
                group.addTask { (index, await operation(inputs[index])) }
                next += 1
            }
        }
        return output
    }
}
