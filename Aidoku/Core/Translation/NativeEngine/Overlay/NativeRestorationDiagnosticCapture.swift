import CoreGraphics
import Foundation
import ImageIO

/// An immutable diagnostic snapshot of actual native patches. Encoding runs
/// only when the renderer requests diagnostics, at the caller's initial or final stage.
enum NativeRestorationDiagnosticCapture {
    struct Report {
        var records: [[String: Any]] = []
        var failures: [String] = []
    }

    static func capture(_ restoration: NativeTranslationRestoration.Result,
                        maximumPixels: Int = 16_000_000, maximumPatches: Int = 64) -> Report {
        var report = Report()
        guard maximumPixels >= 0, maximumPatches >= 0 else {
            report.failures.append("invalid-capture-budget")
            return report
        }
        var remaining = maximumPixels
        for (index, patch) in restoration.patches.enumerated() {
            let id = patch.itemID ?? "unowned"
            guard index < maximumPatches else {
                report.failures.append("patch-count-budget:\(id)")
                continue
            }
            guard [patch.rect.origin.x, patch.rect.origin.y, patch.rect.size.width, patch.rect.size.height].allSatisfy(\.isFinite),
                  patch.rect.size.width > 0, patch.rect.size.height > 0 else {
                report.failures.append("invalid-patch-frame:\(id)")
                continue
            }
            let image = patch.image
            let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
            guard !overflow, pixels > 0, pixels <= remaining else {
                report.failures.append("patch-pixel-budget:\(id)")
                continue
            }
            remaining -= pixels
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                report.failures.append("png-destination:\(id)")
                continue
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                report.failures.append("png-encoding:\(id)")
                continue
            }
            let appearance = patch.itemID.flatMap { restoration.appearances[$0] }
            let candidate = patch.candidate
            // Deferred repairs intentionally have no mutable candidate. Their
            // finalForcedErasure certificate is set only after the production
            // admission requires complete glyph erasure with no preserved ink.
            let acceptedFinalForced = patch.finalForcedErasure && appearance?.finalForcedErasure == true &&
                appearance?.erasureComplete == true && appearance?.sourceGlyphsVerified == true
            var record: [String: Any] = [
                "id": patch.itemID as Any? ?? NSNull(),
                "frame": [patch.rect.minX, patch.rect.minY, patch.rect.width, patch.rect.height],
                "width": image.width, "height": image.height,
                "png": "data:image/png;base64," + (data as Data).base64EncodedString(),
                "finalForcedErasure": patch.finalForcedErasure,
                "independentArtworkCover": patch.independentArtworkCover,
                "method": (candidate?.method ?? appearance?.restorationMethod) as Any? ?? NSNull(),
                "surfaceQuality": patch.surfaceQuality as Any? ?? NSNull(),
                "erasureComplete": candidate?.erasureComplete ?? appearance?.erasureComplete ?? false,
                "sourceGlyphsVerified": candidate?.sourceGlyphsVerified ?? appearance?.sourceGlyphsVerified ?? false,
                "sourceErasureVerified": candidate?.sourceErasureVerified ?? acceptedFinalForced,
                "sourceErasureProof": candidate != nil ? "candidate" : acceptedFinalForced ? "accepted-final-forced" : "unverified",
                "provisional": candidate?.provisional ?? appearance?.provisional ?? false,
                "candidateRevision": candidate?.revision as Any? ?? NSNull()
            ]
            if let safe = patch.layoutSafe {
                record["safePixels"] = safe.filter { $0 != 0 }.count
                record["safeBytes"] = safe.count
                if safe.count != pixels { report.failures.append("safe-size-mismatch:\(id)") }
            }
            if let candidate {
                record["sourceRemainingInk"] = candidate.sourceRemainingInk as Any? ?? NSNull()
                record["localRestorationProposal"] = candidate.localRestorationProposal
            }
            report.records.append(record)
        }
        return report
    }
}
