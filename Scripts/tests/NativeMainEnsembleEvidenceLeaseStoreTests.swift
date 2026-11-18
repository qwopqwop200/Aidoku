import CoreGraphics
import Foundation

// Standalone data carriers for unrelated builder/unowned/OCR-packet APIs.
// The evidence store, RGB decoder, RF adapter and lease are actual production
// implementations. No detector, renderer or provider is linked or run.
#if EVIDENCE_LEASE_STORE_STANDALONE
enum NativeMainAOTRemovalMaskBuilder {
    struct SourceProbability {
        let original: CGImage
        let width: Int
        let height: Int
        let values: [Float]
    }
}
enum NativeCausalUnownedInkLiveRecovery {
    struct AffiliatedMask { let runs: [Int] }
}
enum NativeMainEnsembleOCREvidence {
    enum Failure: Error { case budget }
    struct Packet {}
    final class Store {
        func register(_ packet: Packet, original: CGImage) throws {}
        func read(original: CGImage) throws -> Packet? { nil }
    }
}
#endif

@main enum NativeMainEnsembleEvidenceLeaseStoreTests {
    static func image(_ gray: UInt8) -> CGImage {
        let data = Data(repeating: gray, count: 16 * 16 * 3)
        return CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 48,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
    }

    static func main() throws {
        let store = NativeMainEnsembleEvidenceStore()
        let a = image(30), b = image(60), c = image(90), d = image(120)
        func put(_ source: CGImage) throws {
            try store.register(probability: .init(original: source, width: 2, height: 2, values: [0.1, 0.2, 0.3, 0.9]))
        }
        #if EVIDENCE_LEASE_PATCHED
        let leaseA = try store.lease(original: a)
        let leaseB = try store.lease(original: b)
        let leaseC = try store.lease(original: c)
        #endif
        try put(a); try put(b); try put(c)
        // B finishes ahead of A; the scheduler admits D. Resident B is still
        // newer than A in the registration LRU, although B is no longer active.
        #if EVIDENCE_LEASE_PATCHED
        leaseB.release()
        let leaseD = try store.lease(original: d)
        #endif
        try put(d)
        let found = try store.evidence(original: a).probability
        #if EVIDENCE_LEASE_PATCHED
        precondition(found?.values == [0.1, 0.2, 0.3, 0.9], "active DB lost")
        let completed = try store.evidence(original: b).probability
        precondition(completed == nil, "completed B should be evicted")
        let copyA = image(30)
        let rebound = try store.evidence(original: copyA).probability
        precondition(rebound?.original === copyA, "current CGImage rebinding must remain intact")
        let foreign = try store.evidence(original: image(31)).probability
        precondition(foreign == nil, "different same-size pixels cannot borrow DB")
        leaseA.release(); leaseC.release(); leaseD.release()
        print("{\"checks\":4,\"failed\":0,\"activeProbabilityRetained\":true,\"modelCalls\":0}")
        #else
        precondition(found == nil, "baseline no longer reproduces lifetime defect")
        print("{\"checks\":1,\"failed\":0,\"baselineActiveProbabilityLossReproduced\":true,\"modelCalls\":0}")
        #endif
    }
}
