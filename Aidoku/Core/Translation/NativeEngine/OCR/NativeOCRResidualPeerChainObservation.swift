import CoreGraphics
import Foundation

/// Page-local peer-only observer. No original SourceContext/measure callback/cache is retained.
@available(iOS 18.0, *)
final class NativeOCRResidualPeerChainObservation {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    let originals: [NativeCoreMLDetectionBox]
    let prepared: [NativeCoreMLDetectionBox]
    let groups: [Int: [Int]]
    let rows: [NativeOCRResidualSourceContext.Region]
    let layout: NativeRFDETRLayoutResult?
    let scopes: [NativeOCRSourceComponentMeasurements.Scope]
    let frameProvider: () -> NativeOCRRGBAFrame?
    private let byIndex: [Int: NativeOCRResidualSourceContext.Region]
    private let base: NativeOCRSourceComponentMeasurements.Context
    private var overrides: [Int: NativeOCRSourceComponentMeasurements.Context] = [:]
    private var probeCache: [String: Measurement] = [:]
    private(set) var initializedSourceOrder: [Int] = []
    private(set) var initialMeasurements: [Int: Measurement] = [:]

    init(originals: [NativeCoreMLDetectionBox], prepared: [NativeCoreMLDetectionBox], groups: [Int: [Int]],
         regions: [NativeOCRResidualSourceContext.Region], layout: NativeRFDETRLayoutResult?,
         scopes: [NativeOCRSourceComponentMeasurements.Scope], frameProvider: @escaping () -> NativeOCRRGBAFrame?) {
        self.originals = originals; self.prepared = prepared; self.groups = groups
        self.rows = regions; self.layout = layout; self.scopes = scopes; self.frameProvider = frameProvider
        self.byIndex = Dictionary(uniqueKeysWithValues: regions.map { ($0.index, $0) })
        self.base = NativeOCRSourceComponentMeasurements.Context(originals: originals, prepared: prepared,
            groups: groups, scopes: scopes, frameProvider: frameProvider)
        // Same ORIGINAL row order as baseline Bank; finish all fixed associations BEFORE any wider request.
        for row in regions {
            initialMeasurements[row.index] = observe(row.index, row.polygon)
            initializedSourceOrder.append(row.index)
        }
    }

    var cachedRequestCount: Int { probeCache.count }

    var context: NativeOCRResidualSourceContext {
        .init(originals: originals, prepared: prepared, groups: groups, regions: rows, layout: layout,
              frameProvider: frameProvider, measure: { [self] index, polygon in observe(index, polygon) })
    }

        func observe(_ index: Int, _ polygon: [CGPoint]) -> Measurement? {
            let key = String(index) + ":" + polygon.map { String(Double($0.x).bitPattern) + "," + String(Double($0.y).bitPattern) }.joined(separator: ";")
            if let cached = probeCache[key] { return cached }
            let sourceContext = overrides[index] ?? base
            guard let m = sourceContext.measure(index: index, polygon: polygon, hasInk: byIndex[index]?.hasInk ?? false) else { return nil }
            probeCache[key] = m
            if overrides[index] != nil { return m }
            // A wider probe cannot acquire a neighboring column's owner merely
            // because its sampling rectangle became larger.
            if m.kind == "independent", m.status == "measured", !m.associatedOwners.isEmpty {
                let fixed = base.associatedEvidence(m)
                overrides[index] = NativeOCRSourceComponentMeasurements.Context(originals: originals, prepared: prepared,
                    groups: groups, scopes: scopes, frameProvider: frameProvider, associationViews: [index: fixed])
            }
            guard m.status == "no-private-source" || m.status == "insufficient-private-cells" else { return m }
            let views = index >= prepared.count ?
                NativeOCRResidualIndependentColumns.sourceEvidence(index: index, polygon: polygon, originals: originals,
                    prepared: prepared, groups: groups) :
                NativeOCRResidualEvidence.sourceEvidence(index: index, polygon: polygon, originals: originals,
                    prepared: prepared, groups: groups)
            guard !views.isEmpty else { return m }
            let special = NativeOCRSourceComponentMeasurements.Context(originals: originals, prepared: prepared,
                groups: groups, scopes: scopes, frameProvider: frameProvider, supportViews: [index: views])
            guard let sampled = special.measure(index: index, polygon: polygon, hasInk: m.hasInk), sampled.status == "measured" else { return m }
            overrides[index] = special
            probeCache[key] = sampled
            return sampled
        }
}
