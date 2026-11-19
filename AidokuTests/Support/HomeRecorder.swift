import AidokuRunner
import Foundation

/// Thread-safe recorder for partial home results delivered by a source.
final class HomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Home] = []
    func record(_ home: Home) { lock.withLock { values.append(home) } }
    var snapshots: [Home] { lock.withLock { values } }
}
