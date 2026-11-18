import Foundation

/// A zero-target render is not evidence that OCR or translation was complete.
/// Never fabricate a removal region to make an inference counter increase.
enum NativeAOTRemovalReadiness {
    enum Failure: Error {
        case translatedOwnersWithoutRemovalMask(Int)
        case invalidRetainedOwnerCount(Int)
        case eraseOnlyHasRetainedOwners(Int)
    }
    /// Chosen by the operational caller, never inferred from a role/LLM field.
    enum ErasureMode: String, Codable {
        case retainedText = "replace-retained-text"
        case eraseOnly = "explicit-erase-only"
    }
    enum RestorationInputAuthority: String, Codable {
        case aot = "aot-predicted-mask-restoration-replay"
        case sourcePassThrough = "source-pass-through-no-retained-text"
    }
    struct RestorationPlan {
        let retainedOwnerCount: Int
        let mode: ErasureMode
        let proposedHasRemovalPixels: Bool
        let preserveOriginal: Bool
        var appliedHasRemovalPixels: Bool { !preserveOriginal && proposedHasRemovalPixels }
        var audit: [String: Any] {
            ["restorationDisposition": preserveOriginal ? RestorationInputAuthority.sourcePassThrough.rawValue : "authorized-restoration",
             "retainedTranslationOwners": retainedOwnerCount, "erasureMode": mode.rawValue,
             "proposedHasRemovalPixels": proposedHasRemovalPixels,
             "appliedHasRemovalPixels": appliedHasRemovalPixels,
             "originalSourcePassThrough": preserveOriginal,
             "backendMayRun": !preserveOriginal, "callerRestorationMayBeReused": !preserveOriginal,
             "upstreamTranslationCompletenessVerified": false, "qualityAccepted": false]
        }
    }
    static func restorationPlan(retainedOwners: Int, hasRemovalPixels: Bool,
                                mode: ErasureMode = .retainedText) throws -> RestorationPlan {
        guard (0...4096).contains(retainedOwners) else { throw Failure.invalidRetainedOwnerCount(retainedOwners) }
        if mode == .eraseOnly {
            guard retainedOwners == 0 else { throw Failure.eraseOnlyHasRetainedOwners(retainedOwners) }
            return .init(retainedOwnerCount: 0, mode: mode, proposedHasRemovalPixels: hasRemovalPixels,
                         preserveOriginal: !hasRemovalPixels)
        }
        if retainedOwners == 0 {
            return .init(retainedOwnerCount: 0, mode: mode, proposedHasRemovalPixels: hasRemovalPixels,
                         preserveOriginal: true)
        }
        guard hasRemovalPixels else { throw Failure.translatedOwnersWithoutRemovalMask(retainedOwners) }
        return .init(retainedOwnerCount: retainedOwners, mode: mode,
                     proposedHasRemovalPixels: true, preserveOriginal: false)
    }
    /// The operational AOT/cached-restoration path lives inside this closure.
    /// A source-preservation decision never enters that path, even with a cache.
    static func resolve<Background>(_ plan: RestorationPlan, original: Background,
                                    restoration: () throws -> Background) rethrows -> Background {
        if plan.preserveOriginal { return original }
        return try restoration()
    }

    static func audit(activeOwners: Int, inputOwners: Int, observedOCR: Int?, hasRemovalPixels: Bool) throws -> [String: Any] {
        if activeOwners > 0, !hasRemovalPixels {
            throw Failure.translatedOwnersWithoutRemovalMask(activeOwners)
        }
        let status: String
        if activeOwners > 0 { status = "replacement-ready" }
        else if inputOwners > 0 { status = "source-only-input-no-active-translation" }
        else if let observedOCR, observedOCR > 0 { status = "ocr-present-layout-input-missing" }
        else if observedOCR == 0 { status = "observed-empty-ocr-not-confirmed-text-free" }
        else { status = "no-layout-input-ocr-unavailable" }
        return ["status": status, "activeTranslationOwners": activeOwners,
            "inputOwners": inputOwners, "observedOCRRegions": observedOCR as Any? ?? NSNull(),
            "hasRemovalPixels": hasRemovalPixels,
            "upstreamTranslationCompletenessVerified": false,
            "emptyMaskIsQualityPass": false,
            "preservationIntent": activeOwners == 0 ? "unverified; identical source/output is not sufficient evidence" : "not-applicable"]
    }
}
