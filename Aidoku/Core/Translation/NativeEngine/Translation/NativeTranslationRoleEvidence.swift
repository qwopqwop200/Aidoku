import CoreGraphics
import Foundation

enum NativeTranslationRoleEvidenceBuilder {
    static func make(region: ReaderTranslationRegion, imageIdentity: String,
                     layout: NativeRFDETRLayoutResult?, ownership: NativeRFDETRBalloonOwnership?)
        -> NativeTranslationRoleEvidence? {
        typealias Policy = TranslationBackgroundRolePolicy
        let rect = region.rect
        let bounds = [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
        let contour = region.balloonInterior.map {
            Policy.Contour(bounds: [Double($0.rect.minX), Double($0.rect.minY), Double($0.rect.width), Double($0.rect.height)],
                spans: $0.spans, verified: $0.contourVerified, modelEstimated: $0.modelEstimated)
        }
        var rf: Policy.RFSupport?
        if let layout {
            guard layout.imageIdentity == imageIdentity, layout.sourceWidth > 0, layout.sourceHeight > 0,
                  layout.primitives.count <= 1024, ownership.map({ $0.imageIdentity == imageIdentity }) ?? true else { return nil }
            let sourceBounds = CGRect(x: rect.minX * CGFloat(layout.sourceWidth), y: rect.minY * CGFloat(layout.sourceHeight),
                width: rect.width * CGFloat(layout.sourceWidth), height: rect.height * CGFloat(layout.sourceHeight))
            let resolution = ownership?.resolve(sourceBounds: sourceBounds, imageIdentity: imageIdentity)
            // Use native semanticClass, NOT the differently ordered exported canonical IDs.
            func best(_ category: NativeRFDETRLayoutClass, query: Int? = nil) -> (Double, Double)? {
                guard rect.width > 0, rect.height > 0 else { return nil }
                return layout.primitives.filter { $0.semanticClass == category && (query == nil || $0.queryID == query) }
                    .compactMap { primitive -> (Double, Double)? in
                        let intersection = rect.intersection(primitive.normalizedBounds)
                        guard !intersection.isNull, intersection.width > 0, intersection.height > 0,
                              primitive.confidence.isFinite else { return nil }
                        let coverage = min(1, Double(intersection.width * intersection.height / (rect.width * rect.height)))
                        return (Double(primitive.confidence), coverage)
                    }.max { a, b in a.0 * a.1 < b.0 * b.1 }
            }
            let balloon = best(.balloon, query: resolution?.queryID)
            let text = best(.text), sfx = best(.soundEffect)
            let ownerBounds = resolution.flatMap { owner in
                layout.primitives.first { $0.semanticClass == .balloon && $0.queryID == owner.queryID }
            }.map { $0.normalizedBounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
            rf = .init(imageIdentity: imageIdentity, maskOwnerQuery: resolution?.queryID,
                ownerResolution: resolution?.kind ?? "unresolved", balloonConfidence: balloon?.0,
                balloonBBoxCoverage: balloon?.1, textConfidence: text?.0, textBBoxCoverage: text?.1,
                sfxConfidence: sfx?.0, sfxBBoxCoverage: sfx?.1,
                balloonBounds: ownerBounds.flatMap { $0.isNull || $0.isEmpty ? nil :
                    [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] })
        } else if ownership != nil {
            return nil // Never detach an owner query from its actual model/source metadata.
        }
        return Policy.make(source: region.source, bounds: bounds, imageIdentity: imageIdentity, contour: contour, rf: rf)
    }
}
