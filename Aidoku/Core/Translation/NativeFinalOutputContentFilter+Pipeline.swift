import CoreGraphics
import Foundation

extension NativeFinalOutputContentFilter {
    // Admission identity is separate from the unchanged shared feature ABI.
    static let admissionPolicyVersion = usesLegacyAdmissionRules
        ? "combined-final4-postmerge-v2" : "combined-final3-postmerge3-v2-rf-effect"

    struct AuditRow: Codable, Sendable {
        let id: String  // Receipt only; never passed to the decision function.
        let body: [Int]
        let readings: [Int]
        let features: [Double]?
        let keep: Bool
        var detectorFeatures: [Double]? = nil
        var postMergeDecision: NativePostMergeSignalFilter.Decision? = nil
        // Input receipts only; geometry never enters this admission policy.
        var polygon: [[Double]]? = nil
        var confidence: Double? = nil
        var finalSignalKeep: Bool? = nil
        var auxiliaryEffectRejected: Bool? = nil
    }
    @TaskLocal static var observer: (@Sendable ([AuditRow]) -> Void)?

    static func applying(_ regions: [ReaderTranslationRegion], layout: NativeRFDETRLayoutResult,
                         auxiliaryLayout: NativeRFDETRLayoutResult? = nil) -> [ReaderTranslationRegion] {
        process(regions, layout: layout, filtering: true, auxiliaryLayout: auxiliaryLayout)
    }

    /// Refresh final-owner signals without rerunning admission or emitting filter audit rows.
    static func attachingEvidence(_ regions: [ReaderTranslationRegion], layout: NativeRFDETRLayoutResult) -> [ReaderTranslationRegion] {
        process(regions, layout: layout, filtering: false)
    }

    /// Use the auxiliary detector's admitted text/effect boxes, in original pixels.
    /// A competing text box vetoes rejection even when an effect box contains the owner.
    static func isIsolatedEffect(_ region: ReaderTranslationRegion, layout: NativeRFDETRLayoutResult) -> Bool {
        guard region.polygon.count >= 3, (0...1).contains(region.confidence),
              layout.sourceWidth > 0, layout.sourceHeight > 0 else { return false }
        var bounds = CGRect.null
        for point in region.polygon {
            guard point.x.isFinite, point.y.isFinite else { return false }
            let pixel = CGPoint(x: point.x * CGFloat(layout.sourceWidth), y: point.y * CGFloat(layout.sourceHeight))
            bounds = bounds.union(CGRect(origin: pixel, size: .zero))
        }
        let area = bounds.width * bounds.height
        guard area.isFinite, area > 0 else { return false }
        var hasEffect = false
        for primitive in layout.primitives where primitive.semanticClass == .text || primitive.semanticClass == .soundEffect {
            let overlap = bounds.intersection(primitive.sourceBounds)
            guard !overlap.isEmpty else { continue }
            let support = Double(primitive.confidence) * Double(overlap.width * overlap.height / area)
            if primitive.semanticClass == .text && support > 0.3 { return false }
            if primitive.semanticClass == .soundEffect && support >= 0.65 { hasEffect = true }
        }
        return hasEffect
    }

    private static func process(_ regions: [ReaderTranslationRegion], layout: NativeRFDETRLayoutResult,
                                filtering: Bool, auxiliaryLayout: NativeRFDETRLayoutResult? = nil) -> [ReaderTranslationRegion] {
        let primitives = layout.primitives.map { p in
            F.RFPrimitive(
                x: Double(p.sourceBounds.minX), y: Double(p.sourceBounds.minY),
                width: Double(p.sourceBounds.width), height: Double(p.sourceBounds.height),
                confidence: Double(p.confidence), semanticClass: p.semanticClass.rawValue,
                mask: p.mask.flatMap {
                    F.RFMask(
                        sourceWidth: $0.sourceWidth, sourceHeight: $0.sourceHeight,
                        side: NativeRFDETRLayoutResource.maskSide, logits: $0.logits)
                }, queryID: p.queryID)
        }
        let queries = layout.classEvidence.map { q in
            NativeOCRPremergeSpatialEvidence.Query(
                x: Double(q.sourceBounds.minX), y: Double(q.sourceBounds.minY),
                width: Double(q.sourceBounds.width), height: Double(q.sourceBounds.height),
                probabilities: q.probabilities.map(Double.init), queryID: q.queryID)
        }
        let context = Context(width: layout.sourceWidth, height: layout.sourceHeight, primitives: primitives, queries: queries)
        var cached: [ObjectIdentifier: [[Double]?]] = [:]
        var audit: [AuditRow] = []
        let recordsAudit = filtering && observer != nil
        let retained = regions.compactMap { region -> ReaderTranslationRegion? in
            var features: [Double]?
            var detectorFeatures: [Double]?
            let membership = region.acceptedSource.membership
            if let context, let m = membership, !m.hasUntrackedInputs, !m.body.isEmpty,
                m.table.width == layout.sourceWidth, m.table.height == layout.sourceHeight,
                m.body.allSatisfy(m.table.packets.indices.contains)
            {
                let key = ObjectIdentifier(m.table)
                if cached[key] == nil {
                    cached[key] = m.table.packets.map { packet in
                        context.semantic(packet.polygon.map { .init(x: Double($0.x), y: Double($0.y)) })
                    }
                }
                let body = m.body.sorted()
                detectorFeatures = NativePostLLMContentReclassifier.detectorFeatures(
                    bodySignals: body.map { m.table.packets[$0].detectorSignals })
                let semantic = body.compactMap { cached[key]![$0] }
                if semantic.count == body.count {
                    let output = region.polygon.map {
                        F.Point(
                            x: Double($0.x) * Double(layout.sourceWidth),
                            y: Double($0.y) * Double(layout.sourceHeight))
                    }
                    // A singleton owner may be the exact same source quad as its
                    // sole packet. Reuse only identical coordinates in vertex order.
                    let exactSingletonBodyPolygon: [F.Point]? = body.count == 1
                        ? m.table.packets[body[0]].polygon.map { .init(x: Double($0.x), y: Double($0.y)) } : nil
                    features = extract(
                        output: output, confidence: region.confidence,
                        bodyConfidence: body.map { m.table.packets[$0].score }, bodySemantic: semantic, context: context,
                        exactSingletonBodyPolygon: exactSingletonBodyPolygon)
                }
            }
            if filtering {
                let postMergeDecision = NativePostMergeSignalFilter.decide(
                    NativePostMergeSignalFilter.extract(features: features, detectorFeatures: detectorFeatures))
                let finalSignalKeep = keep(features, policy: defaultPolicy, detectorFeatures: detectorFeatures)
                let admitted = finalSignalKeep && postMergeDecision.keep
                let isolatedEffect = admitted && !usesLegacyAdmissionRules &&
                    (auxiliaryLayout.map { isIsolatedEffect(region, layout: $0) } ?? false)
                let retained = admitted && !isolatedEffect
                if recordsAudit {
                    audit.append(
                        .init(
                            id: region.id, body: membership?.body.sorted() ?? [],
                            readings: membership?.readings.sorted() ?? [], features: features, keep: retained,
                            detectorFeatures: detectorFeatures, postMergeDecision: postMergeDecision,
                            polygon: region.polygon.map { [Double($0.x), Double($0.y)] },
                            confidence: region.confidence, finalSignalKeep: finalSignalKeep, auxiliaryEffectRejected: isolatedEffect))
                }
                guard retained else { return nil }
            }
            var region = region
            region.postLLMContentEvidence = NativePostLLMContentReclassifier.Evidence(features: features, detectorFeatures: detectorFeatures)
            return region
        }
        if filtering { observer?(audit) }
        return retained
    }
}
