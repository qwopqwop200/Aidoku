import Foundation

/// One UI refresh at a time, with a trailing pass for events received during IO.
/// The revision prevents an older pass from repainting over a newer user action.
@MainActor
final class DownloadRefreshCoordinator {
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?

    func isCurrent(_ issued: UInt64) -> Bool { issued == revision }

    func refresh(_ operation: @escaping @MainActor (UInt64) async -> Void) async {
        revision &+= 1
        if let task {
            await task.value
            return
        }
        let work = Task {
            var issued: UInt64
            repeat {
                issued = revision
                await operation(issued)
            } while issued != revision && !Task.isCancelled
            task = nil
        }
        task = work
        await work.value
    }
}
