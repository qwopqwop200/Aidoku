import Foundation
import Dispatch

private final class MockFault: Error, @unchecked Sendable {}
private let parserFault = MockFault()

// Only the typed constructors are replaced. The actual production provider,
// lock, transaction/cancellation logic and eager resource API compile unchanged.
enum NativeOCRRawBoundaryGenerator {
    static let featureCount = 422
    struct Model: Sendable {
        let marker: UInt8
        init(data: Data, expectedFeatureNames: [String]) throws {
            guard data.first != 255 else { throw parserFault }
            precondition(expectedFeatureNames.count == 422)
            marker = data.first!
        }
    }
}
enum NativeOCRRawSourceAdmission {
    struct Model: Sendable {
        let marker: UInt8
        init(data: Data) throws {
            guard data.first != 255 else { throw parserFault }
            marker = data.first!
        }
    }
}
enum NativeOCRPreRecognitionFilter {
    struct Model: Sendable {
        let marker: UInt8
        init(data: Data, expectedFeatureNames: [String]) throws {
            guard data.first != 255 else { throw parserFault }
            precondition(expectedFeatureNames.count == 166)
            marker = data.first!
        }
    }
}
enum NativeOCRRawCanonicalGeometry {
    static var featureNames: [String] { (0..<422).map { "f\($0)" } }
}
enum NativeOCRPreRecognitionFeatures {
    static var featureNames: [String] { (0..<166).map { "p\($0)" } }
}

private typealias B = NativeOCRRawGeometryModelBundle

private final class Reader: @unchecked Sendable {
    let lock = NSLock()
    var counts: [B.File: Int] = [:]
    var failing: B.File?
    var corrupt: B.File?
    var cancelOnce = false
    let fault = MockFault()
    var gate: (DispatchSemaphore, DispatchSemaphore)?
    init(failing: B.File? = nil, corrupt: B.File? = nil) {
        self.failing = failing; self.corrupt = corrupt
    }
    func read(_ file: B.File) throws -> Data {
        lock.lock()
        counts[file, default: 0] += 1
        let shouldFail = file == failing
        let shouldCorrupt = file == corrupt
        let shouldCancel = cancelOnce
        cancelOnce = false
        let gate = file == .primary ? gate : nil
        lock.unlock()
        if let gate {
            gate.0.signal()
            precondition(gate.1.wait(timeout: .now() + 5) == .success)
        }
        if shouldCancel { throw CancellationError() }
        if shouldFail { throw fault }
        if shouldCorrupt { return Data([255]) }
        let marker: UInt8
        switch file {
        case .primary: marker = 1
        case .gate: marker = 2
        case .auxiliary: marker = 3
        case .preRecognition: marker = 4
        case .auxiliaryReference: marker = 5
        }
        return Data([marker])
    }
    func snapshot() -> [B.File: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}

private final class Flag: @unchecked Sendable {
    let lock = NSLock()
    var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func provider(_ reader: Reader) -> B.Provider {
    B.Provider(read: { try reader.read($0) })
}

private func assertPre(_ value: B.Resolved) {
    guard case .preRecognition(let model) = value else { preconditionFailure("pre only") }
    precondition(model.marker == 4)
}

private func assertFull(_ value: B.Resolved) {
    guard case .full(let models) = value else { preconditionFailure("full") }
    precondition(models.primary.marker == 1 && models.gate.marker == 2)
    precondition(models.auxiliary?.marker == 3 && models.preRecognition.marker == 4)
    precondition(models.auxiliaryReference.marker == 5)
}

@main
private enum Smoke {
    static func main() throws {
        var checks = 0
        // Construction and none mode do no reads or geometry feature assembly.
        do {
            let reader = Reader()
            let p = B.Provider(read: { try reader.read($0) }, geometryFeatureNames: {
                preconditionFailure("none/pre must not construct geometry feature names")
            })
            precondition(reader.snapshot().isEmpty)
            guard case .none = try p.acquire(.none, cancellationCheck: {}) else { preconditionFailure() }
            precondition(reader.snapshot().isEmpty)
            assertPre(try p.acquire(.preRecognitionOnly, cancellationCheck: {}))
            assertPre(try p.acquire(.preRecognitionOnly, cancellationCheck: {}))
            precondition(reader.snapshot() == [.preRecognition: 1]); checks += 1
        }
        // Warm reuse and pre->full transition parse each requested file once.
        do {
            let reader = Reader(); let p = provider(reader)
            assertPre(try p.acquire(.preRecognitionOnly, cancellationCheck: {}))
            assertFull(try p.acquire(.full, cancellationCheck: {}))
            assertFull(try p.acquire(.full, cancellationCheck: {}))
            precondition(reader.snapshot() == Dictionary(uniqueKeysWithValues: B.File.allCases.map { ($0, 1) }))
            checks += 1
        }
        // Concurrent mixed requests coalesce and never observe partial sets.
        do {
            let reader = Reader(); let p = provider(reader)
            DispatchQueue.concurrentPerform(iterations: 96) { index in
                do {
                    if index % 3 == 0 { assertFull(try p.acquire(.full, cancellationCheck: {})) }
                    else if index % 3 == 1 { assertPre(try p.acquire(.preRecognitionOnly, cancellationCheck: {})) }
                    else if case .none = try p.acquire(.none, cancellationCheck: {}) {} else { preconditionFailure() }
                } catch { preconditionFailure("concurrent acquisition: \(error)") }
            }
            precondition(reader.snapshot().values.allSatisfy { $0 == 1 } && reader.snapshot().count == 5)
            checks += 1
        }
        // Unused missing heads do not poison pre-only/none. Required errors retain identity.
        do {
            let reader = Reader(failing: .auxiliary); let p = provider(reader)
            assertPre(try p.acquire(.preRecognitionOnly, cancellationCheck: {}))
            for _ in 0..<2 {
                do { _ = try p.acquire(.full, cancellationCheck: {}); preconditionFailure() }
                catch let error as MockFault { precondition(error === reader.fault) }
            }
            assertPre(try p.acquire(.preRecognitionOnly, cancellationCheck: {}))
            precondition(reader.snapshot() == [.primary: 1, .gate: 1, .auxiliary: 1, .preRecognition: 1])
            checks += 1
        }
        // A failed full transaction publishes no successful partial model.
        do {
            let reader = Reader(failing: .auxiliaryReference); let p = provider(reader)
            do { _ = try p.acquire(.full, cancellationCheck: {}); preconditionFailure() }
            catch let error as MockFault { precondition(error === reader.fault) }
            assertPre(try p.acquire(.preRecognitionOnly, cancellationCheck: {}))
            precondition(reader.snapshot()[.preRecognition] == 2)
            checks += 1
        }
        // Strict parser failures are not replaced with synthetic missing-resource errors.
        do {
            let reader = Reader(corrupt: .preRecognition); let p = provider(reader)
            for _ in 0..<2 {
                do { _ = try p.acquire(.preRecognitionOnly, cancellationCheck: {}); preconditionFailure() }
                catch let error as MockFault { precondition(error === parserFault) }
            }
            precondition(reader.snapshot() == [.preRecognition: 1]); checks += 1
        }
        // Cancellation before IO and a cancelled read are never permanent failures.
        do {
            let reader = Reader(); let p = provider(reader)
            do { _ = try p.acquire(.full, cancellationCheck: { throw CancellationError() }); preconditionFailure() }
            catch is CancellationError {}
            precondition(reader.snapshot().isEmpty)
            reader.cancelOnce = true
            do { _ = try p.acquire(.preRecognitionOnly, cancellationCheck: {}); preconditionFailure() }
            catch is CancellationError {}
            assertPre(try p.acquire(.preRecognitionOnly, cancellationCheck: {}))
            precondition(reader.snapshot() == [.preRecognition: 2]); checks += 1
        }
        // Custom caller cancellation after decode/before commit also rolls back.
        do {
            let reader = Reader(); let p = provider(reader); let cancellation = MockFault()
            var calls = 0
            do {
                _ = try p.acquire(.preRecognitionOnly, cancellationCheck: {
                    calls += 1; if calls == 6 { throw cancellation }
                })
                preconditionFailure()
            } catch let error as MockFault { precondition(error === cancellation) }
            assertPre(try p.acquire(.preRecognitionOnly, cancellationCheck: {}))
            precondition(reader.snapshot() == [.preRecognition: 2]); checks += 1
        }
        // A request cancelled while waiting rechecks after the shared lock.
        do {
            let reader = Reader(); let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            reader.gate = (entered, release)
            let p = provider(reader), cancelled = Flag(), sawCancellation = Flag()
            let first = DispatchGroup(), second = DispatchGroup(), attempted = DispatchSemaphore(value: 0)
            first.enter()
            DispatchQueue.global().async {
                defer { first.leave() }
                do { assertFull(try p.acquire(.full, cancellationCheck: {})) }
                catch { preconditionFailure("first: \(error)") }
            }
            precondition(entered.wait(timeout: .now() + 5) == .success)
            second.enter()
            DispatchQueue.global().async {
                defer { second.leave() }
                do {
                    _ = try p.acquire(.preRecognitionOnly, cancellationCheck: {
                        attempted.signal(); if cancelled.get() { throw CancellationError() }
                    })
                    preconditionFailure("cancelled waiter succeeded")
                } catch is CancellationError { sawCancellation.set() }
                catch { preconditionFailure("waiter: \(error)") }
            }
            precondition(attempted.wait(timeout: .now() + 5) == .success)
            cancelled.set(); release.signal()
            precondition(first.wait(timeout: .now() + 5) == .success)
            precondition(second.wait(timeout: .now() + 5) == .success && sawCancellation.get())
            checks += 1
        }
        // Preserve explicit supplied Result identity; none does not demand it.
        do {
            let fault = MockFault(), p = B.Provider(supplied: .failure(fault))
            guard case .none = try p.acquire(.none, cancellationCheck: {}) else { preconditionFailure() }
            do { _ = try p.acquire(.full, cancellationCheck: {}); preconditionFailure() }
            catch let error as MockFault { precondition(error === fault) }
            let disabled = try B.load(request: .disabled)
            precondition(disabled == nil); checks += 1
        }
        print("PASS raw required-head provider: \(checks) groups;96 concurrent requests; mock reads only; zero model inference")
    }
}
