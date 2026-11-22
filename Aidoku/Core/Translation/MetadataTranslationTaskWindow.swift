/// Bound suspended metadata child tasks as well as active provider requests.
enum MetadataTranslationTaskWindow {
    static let maximumTasks = 64

    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], fallback: (Input) -> Output,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        var output = inputs.map(fallback)
        await withTaskGroup(of: (Int, Output).self) { group in
            for (index, input) in inputs.enumerated() {
                if index >= maximumTasks, let finished = await group.next() { output[finished.0] = finished.1 }
                guard !Task.isCancelled else { break }
                group.addTask { (index, await operation(input)) }
            }
            for await (index, value) in group { output[index] = value }
        }
        return output
    }
}
