import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeMinimalOwnerPreparationTests {
    private typealias Factory = NativeSourceInputFactory

    private func fixture() throws -> (NativeRFDETRSourceImage, NativePixelRFEvidence, [[String: Any]]) {
        let width = 192, height = 128
        let page = try NativeRFDETRSourceImage(width: width, height: height,
            rgb: Data((0..<(width * height * 3)).map { UInt8(($0 / 3) % width) }))
        let logits = [Float](repeating: 0, count: 162 * 162)
        let queries = (0..<300).map { q in
            NativeRFDETRClassEvidence(queryID: q, logits: [0, 1, -1, 1, 0], probabilities: [],
                normalizedBounds: .zero, sourceBounds: .zero,
                mask: .init(queryID: q, sourceWidth: width, sourceHeight: height, logits: logits))
        }
        let rf = try NativePixelRFEvidence(result: .init(imageIdentity: page.identity, sourceWidth: width,
            sourceHeight: height, primitives: [], maskQueriesOmittedByBudget: 0, preprocessingMilliseconds: 0,
            modelMilliseconds: 0, decodeMilliseconds: 0, computeUnits: "fixture", fromCache: false, classEvidence: queries))
        let items: [[String: Any]] = (0..<4).map { i in
            ["text": "target", "sourceOriginalText": "source", "sourceBounds": [0.1 + Double(i) * 0.15, 0.2, 0.13, 0.3]]
        }
        return (page, rf, items)
    }

    private func observed(_ input: NativeMinimalSourceSegmentation.Input) -> Factory.MinimalObservation {
        let mask = (0..<(input.width * input.height)).map { input.rgb[$0 * 3] > 16 ? UInt8(255) : 0 }
        return .init(segmentation: .init(mask: mask, primary: nil, nativeSeed: nil, audit: [:]),
              fullRFSHA256: String(input.fullRF.count), coarseRFSHA256: String(input.coarseRF.count),
              rfModelWeightsSHA256: input.rfModelWeightsSHA256)
    }

    @Test func defaultCallbackOrderAndPairedOwnerIndicesMatch() throws {
        let (page, rf, active) = try fixture()
        let items = [["keptLettering": true] as [String: Any], active[0], ["text": ""], active[1], active[2], active[3]]
        var seen: [UInt8] = []
        let serial = try Factory.makeMinimal(source: page, items: items, sourceEvidence: [:], rf: rf) { input in
            seen.append(input.rgb[0])
            return observed(input)
        }
        let paired = try Factory.makeMinimal(source: page, items: items, sourceEvidence: [:], rf: rf,
            observationMode: .sourcePreparation, observe: observed)
        #expect(serial.map { $0.rgb[0] } == seen)
        #expect(paired.map(\.itemIndex) == [1, 3, 4, 5])
        #expect(paired.map(\.rgb) == serial.map(\.rgb))
        #expect(paired.map(\.crop) == serial.map(\.crop))
        #expect(paired.map(\.observation.segmentation.mask) == serial.map(\.observation.segmentation.mask))
    }

    @Test func earlierObservationErrorPrecedesLaterMalformedGeometry() throws {
        enum Failure: Error { case firstObservation }
        let (page, rf, active) = try fixture()
        let laterBad: [String: Any] = ["text": "target", "sourceBounds": [0.1, 0.2, 0.0, 0.3]]
        for mode in [NativeSourceOwnerMeasurements.Mode.serial, .sourcePreparation] {
            #expect(throws: Failure.firstObservation) {
                try Factory.makeMinimal(source: page, items: [active[0], laterBad], sourceEvidence: [:],
                    rf: rf, observationMode: mode) { _ in throw Failure.firstObservation }
            }
        }
    }

    private final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        func enter() {
            lock.lock()
            count += 1
            lock.unlock()
            entered.signal()
            _ = resume.wait(timeout: .now() + 3)
        }
        func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 3) == .success }
        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @Test func cancellationJoinsAdmittedOwnersAndDiscardsThePage() async {
        let gate = Gate()
        let pageTask = Task.detached {
            let (page, rf, active) = try fixture()
            return try Factory.makeMinimal(source: page, items: active, sourceEvidence: [:], rf: rf,
                observationMode: .sourcePreparation) { input in
                    gate.enter()
                    return observed(input)
                }.count
        }
        let started = await Task.detached { gate.waitUntilEntered() }.value
        pageTask.cancel()
        gate.resume.signal()
        gate.resume.signal()
        #expect(started)
        guard case .failure(let error) = await pageTask.result else {
            Issue.record("Cancelled source preparation published a page")
            return
        }
        #expect(error is CancellationError)
        #expect((1...2).contains(gate.calls))
    }
}
