import CoreGraphics
import Foundation

/// Fresh RF evidence is used independently of optional balloon contour handoff.
/// Only a proposed final-raster movement can be vetoed; all incumbent text survives.
@available(iOS 16.0, macOS 13.0, *)
enum NativeRetainedSourceRisk {
    struct Report {
        let gate: NativeFinalTextPaintAdmission.RetainedSourceRiskGate?
        let status: String
    }

    // Share the exact original decode without sharing the consumers' authority.
    // Keep either canonical decoded data or the consumers' array, not both.
    struct OriginalObservation {
        struct Identity {
            let width: Int
            let height: Int
            let source: String
            init(_ value: NativeRFDETRSourceImage) {
                width = value.width
                height = value.height
                source = value.identity
            }
        }
        private enum Storage {
            case decoded(Identity, NativeRFDETRSourceImage)
            case packed(Identity, [UInt8])
        }
        private let original: CGImage
        private var storage: Storage?

        init(_ original: CGImage) { self.original = original }

        mutating func identity() throws -> Identity {
            switch storage {
            case .packed(let identity, _): return identity
            case .decoded(let identity, _): return identity
            case nil:
                let value = try NativeRFDETRSourceImage.decode(original)
                let identity = Identity(value)
                storage = .decoded(identity, value)
                return identity
            }
        }

        mutating func pixels() throws -> (identity: Identity, rgb: [UInt8]) {
            let value: NativeRFDETRSourceImage
            let identity: Identity
            switch storage {
            case .packed(let identity, let rgb): return (identity, rgb)
            case .decoded(let known, let decoded): identity = known; value = decoded
            case nil:
                value = try NativeRFDETRSourceImage.decode(original)
                identity = Identity(value)
            }
            let rgb = [UInt8](value.rgb)
            storage = .packed(identity, rgb)
            return (identity, rgb)
        }

        mutating func finish() { storage = nil }
    }

    static func make(original: CGImage, erased: [UInt8],
                     evidence: NativeLiveSourceAppearance.RFEvidence?) -> Report {
        var observation = OriginalObservation(original)
        return make(original: &observation, erased: erased, evidence: evidence)
    }

    static func make(original: inout OriginalObservation, erased: [UInt8],
                     evidence: NativeLiveSourceAppearance.RFEvidence?) -> Report {
        guard let evidence else { return .init(gate: nil, status: "fresh-rf-unavailable; unchanged-gutter-policy") }
        func unknown(_ reason: String) -> Report {
            .init(gate: .init(evaluate: { _, _ in nil }), status: reason + "; preserve-incumbent")
        }
        guard evidence.modelWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
              let source = try? original.identity(),
              source.source == evidence.sourceIdentity,
              erased.count == source.width * source.height else { return unknown("invalid-source-mask-or-model-binding") }
        let regions = evidence.regions.filter {
            $0.classID == 0 && $0.confidence >= 0.25 || $0.classID == 1 && $0.confidence >= 0.20
        }
        guard !regions.isEmpty else { return unknown("no-accepted-text-or-sfx-masks") }
        let samplers = regions.compactMap(\.sourcePixelMask)
        let incomplete = samplers.count != regions.count
        guard samplers.allSatisfy({ $0.sourceIdentity == evidence.sourceIdentity &&
            $0.sourceWidth == source.width && $0.sourceHeight == source.height }) else { return unknown("invalid-rf-mask-source-binding") }
        guard let pixels = try? original.pixels() else { return unknown("invalid-source-mask-or-model-binding") }
        let rgb = pixels.rgb, width = source.width, height = source.height
        let radius = max(1, min(7, Int(ceil(Double(max(width, height)) / 648))))
        let identity = evidence.sourceIdentity
        let sampler: (Int, Int) -> Bool? = { x, y in
            guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
            if erased[y * width + x] > 0 { return false }
            var observed = false, unknown = incomplete
            for mask in samplers {
                switch mask.contains(sourceX: x, sourceY: y, sourceIdentity: identity) {
                case true?: observed = true
                case false?: break
                case nil: unknown = true
                }
            }
            if !observed { return unknown ? nil : false }
            return NativeSourceContrastSupport.contains(rgb: rgb, width: width, height: height,
                x: x, y: y, radius: radius, minimumContrast: 24)
        }
        let gate = NativeFinalTextPaintAdmission.RetainedSourceRiskGate { old, new in
            let decision = NativeRetainedLetteringRisk.evaluate(
                old: old.runs.map { .init(y: $0.y, left: $0.left, right: $0.right) },
                new: new.runs.map { .init(y: $0.y, left: $0.left, right: $0.right) },
                pageWidth: width, pageHeight: height, maximumSamples: 2_000_000, sampler: sampler)
            return decision.available ? decision.admit : nil
        }
        return .init(gate: gate, status: "fresh-source-rf-and-local-median-contrast; actual-erasure-excluded")
    }
}
