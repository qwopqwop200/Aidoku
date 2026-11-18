import CryptoKit
import Foundation

/// REVIEW ONLY. Pure capability admission; no model, image or file lookup.
/// Caller holds the existing serial OCR gate, looks up CURRENT records inside
/// that gate, and retains the admitted immutable grid/lease through rendering.
enum NativeMainEnsembleDBCapability {
    struct Source: Codable, Hashable, Sendable {
        let canonicalIdentity: String
        let detectorInputIdentity: String
        let width: Int
        let height: Int
    }
    /// Values must come from the actual fixed producer, not old trace defaults.
    /// Package digest is the actual model store content digest, not its filename.
    struct Producer: Codable, Hashable, Sendable {
        let modelResource: String
        let modelPackageSHA256: String
        let backend: String
        let computeUnits: String
        let preprocessABI: String
        let preprocessSHA256: String
        let effectiveConfigurationSHA256: String // RAW input/output contract only
        let maximumSide: Int // actual canvas maximum, not requested consumer ceiling
        let canvasWidth: Int
        let canvasHeight: Int
        let resizedWidth: Int
        let resizedHeight: Int
    }
    struct Key: Codable, Hashable, Sendable {
        let source: Source
        let producer: Producer
    }
    struct Grid: Sendable {
        let sourceWidth: Int
        let sourceHeight: Int
        let resizedWidth: Int
        let resizedHeight: Int
        let regionX: Int
        let regionY: Int
        let regionWidth: Int
        let regionHeight: Int
        let width: Int
        let height: Int
        let values: [Float]
    }
    enum Origin: String, Codable, Sendable {
        case live, authenticatedReplay, freshCurrentDetector, legacyUnproven
    }
    struct Record: Sendable {
        let source: Source
        let producer: Producer?
        let grid: Grid
        let mapSHA256: String
        let origin: Origin
        // Audit only: downstream DB decoding cannot invalidate identical RAW grids.
        var consumerConfigurationSHA256: String? = nil
    }
    enum Failure: Error, Equatable {
        case missingRequiredCapability, legacyNotCurrent, sourceMismatch, producerMismatch
        case invalidSource, invalidProducer, invalidGeometry, partialOrPadded, upsampled
        case invalidValueCount, invalidProbability, digestMismatch, invalidOrigin
    }
    struct Resolution: Sendable {
        let record: Record
        let detectorCalls: Int
    }
    static func digest(_ values: [Float]) -> String {
        // Canonical little-endian Float32 bits, no rounding/clamping/quantization.
        var hash=SHA256()
#if _endian(little)
        // Apple targets already store the canonical bytes. Borrow the immutable
        // buffer instead of allocating UInt32 arrays and Data for every block.
        values.withUnsafeBytes { bytes in
            hash.update(bufferPointer: bytes)
        }
#else
        for start in stride(from:0,to:values.count,by:4096) {
            let words=values[start..<min(start+4096,values.count)].map { $0.bitPattern.littleEndian }
            words.withUnsafeBytes { hash.update(data:Data($0)) }
        }
#endif
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    private static func hashShape(_ value:String)->Bool {
        value.count==64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validate(_ record:Record, expected:Key) throws {
        try Task.checkCancellation()
        let s=expected.source,p=expected.producer,g=record.grid
        guard s.width>0,s.height>0,s.width<=16_384,s.height<=16_384,
              s.width<=16_777_216/s.height,
              hashShape(s.canonicalIdentity),hashShape(s.detectorInputIdentity) else { throw Failure.invalidSource }
        guard !p.modelResource.isEmpty,hashShape(p.modelPackageSHA256),!p.backend.isEmpty,
              !p.computeUnits.isEmpty,!p.preprocessABI.isEmpty,hashShape(p.preprocessSHA256),hashShape(p.effectiveConfigurationSHA256),
              (32...2000).contains(p.maximumSide),(32...2000).contains(p.canvasWidth),
              (32...2000).contains(p.canvasHeight),p.canvasWidth.isMultiple(of:32),
              p.canvasHeight.isMultiple(of:32),p.resizedWidth>0,p.resizedHeight>0,
              p.resizedWidth<=p.canvasWidth,p.resizedHeight<=p.canvasHeight else { throw Failure.invalidProducer }
        guard record.origin != .legacyUnproven,let observed=record.producer else { throw Failure.legacyNotCurrent }
        guard record.source==s else { throw Failure.sourceMismatch }
        guard observed==p else { throw Failure.producerMismatch }
        guard g.sourceWidth==s.width,g.sourceHeight==s.height,g.width>0,g.height>0,
              g.resizedWidth==p.resizedWidth,g.resizedHeight==p.resizedHeight,g.width<=2000,g.height<=2000,
              g.resizedWidth<=p.canvasWidth,g.resizedHeight<=p.canvasHeight else { throw Failure.invalidGeometry }
        guard g.regionX==0,g.regionY==0,g.regionWidth==g.resizedWidth,
              g.regionHeight==g.resizedHeight,g.width==g.resizedWidth,g.height==g.resizedHeight else { throw Failure.partialOrPadded }
        guard g.width<=s.width,g.height<=s.height else { throw Failure.upsampled }
        guard g.values.count==g.width*g.height else { throw Failure.invalidValueCount }
        for i in g.values.indices {
            if i & 4095 == 0 { try Task.checkCancellation() }
            guard g.values[i].isFinite,(0...1).contains(g.values[i]) else { throw Failure.invalidProbability }
        }
        guard hashShape(record.mapSHA256),digest(g.values)==record.mapSHA256 else { throw Failure.digestMismatch }
    }
    /// Serial-gate primitive, NOT a new actor or global observer. Legacy/mismatched
    /// resident entries are misses. A supplied replay must validate, never silently
    /// fall back after corruption. The fallback must capture actual detector output
    /// and report freshCurrentDetector; ignored/missing observer must throw upstream.
    static func resolve(expected:Key,resident:Record?,replay:Record?,allowOneCurrentDetector:Bool,
                        fallback:() async throws -> Record) async throws -> Resolution {
        try Task.checkCancellation()
        if let resident {
            do {
                try validate(resident,expected:expected)
                return .init(record:resident,detectorCalls:0)
            } catch is CancellationError { throw CancellationError() }
            catch { /* Not current evidence: never relabel it with expected. */ }
        }
        if let replay {
            guard replay.origin == .authenticatedReplay else { throw Failure.invalidOrigin }
            try validate(replay,expected:expected)
            return .init(record:replay,detectorCalls:0)
        }
        guard allowOneCurrentDetector else { throw Failure.missingRequiredCapability }
        try Task.checkCancellation()
        let actual=try await fallback() // exactly one call, no retry/alternate crop
        guard actual.origin == .freshCurrentDetector else { throw Failure.invalidOrigin }
        try validate(actual,expected:expected)
        try Task.checkCancellation()
        return .init(record:actual,detectorCalls:1)
    }
}
