import Foundation
import CoreGraphics

/// Optional source-only geometry. Ownership and legacy selection are unchanged.
@available(iOS 18.0, *)
enum NativeOCRResidualPrivatePCANative {
    static func sameQuad(_ polygon: [CGPoint], _ incoming: [CGPoint]) -> Bool {
        for reversed in [false, true] {
            let quad = reversed ? Array(polygon.reversed()) : polygon
            for shift in 0..<4 {
                if (0..<4).allSatisfy({ index in
                    let a = quad[(index + shift) % 4], b = incoming[index]
                    return hypot(a.x - b.x, a.y - b.y) <= 1e-8
                }) { return true }
            }
        }
        return false
    }
    struct Evaluation {
        let candidate: NativeOCRResidualCandidate
        let accepted: Bool
        let reason: String
    }
    static func evaluate(_ m: NativeOCRSourceComponentMeasurements.Measurement,
                         observation: NativeOCRPrivateObservation.Retained,
                         inherited: [CGPoint], originalGuard: [CGPoint], visible: [CGPoint],
                         protectedCaps: [CGPoint], frame: NativeOCRRGBAFrame) -> Evaluation? {
        // Eligible source components outside raw ingress remain protected when already visible in the old crop.
        let completeVisible = NativeOCRCompleteVisibleGeometry.support(m, inherited: inherited)
        let caps = protectedCaps + completeVisible
        guard let candidate = NativeOCRResidualPrivatePCAEnvelopeFringe.candidates(m,
            privateMoments: observation.moments, inherited: inherited, originalGuard: originalGuard,
            visibleForeground: visible, protectedCaps: caps).first else { return nil }
        func rejected(_ reason: String) -> Evaluation { .init(candidate: candidate, accepted: false, reason: reason) }
        let points = inherited + candidate.polygon
        guard points.count == 8, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return rejected("private-pca-invalid-local-observation")
        }
        let x0 = points.map(\.x).min()!, x1 = points.map(\.x).max()!
        let y0 = points.map(\.y).min()!, y1 = points.map(\.y).max()!
        let padX = max(1, (x1-x0)*0.15), padY = max(1, (y1-y0)*0.15)
        let left = Int(max(0, min(CGFloat(frame.width), floor(x0-padX))))
        let right = Int(max(0, min(CGFloat(frame.width), ceil(x1+padX))))
        let top = Int(max(0, min(CGFloat(frame.height), floor(y0-padY))))
        let bottom = Int(max(0, min(CGFloat(frame.height), ceil(y1+padY))))
        let width = right-left, height = bottom-top
        guard width > 0, height > 0, width <= 2_000_000 / height else {
            return rejected("private-pca-local-RGB-budget")
        }
        var bytes = [UInt8](); bytes.reserveCapacity(width*height*4)
        for y in top..<bottom {
            let start = y*frame.bytesPerRow+left*4
            bytes.append(contentsOf: frame.bytes[start..<(start+width*4)])
        }
        let local = NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA(bytes: bytes,
            width: width, height: height, bytesPerRow: width*4, origin: .init(x: left, y: top))
        let result = NativeOCRResidualPrivatePCATurningStroke.observe(m, privateObservation: observation,
            inherited: inherited, originalGuard: originalGuard, visibleForeground: visible,
            protectedCaps: caps, rgba: local, sourceFrameSize: .init(width: frame.width, height: frame.height))
        guard let offer = result.offer else { return rejected("private-pca-" + result.reason) }
        return .init(candidate: offer, accepted: true, reason: "source-only-native-admission-pending")
    }
    /// Fresh full-support and two original-pixel vetoes for the smaller normal fringe.
    static func evaluateFootprint(_ m: NativeOCRSourceComponentMeasurements.Measurement,
                                  observation: NativeOCRPrivateObservation.Retained,
                                  pca: NativeOCRResidualCandidate, inherited: [CGPoint],
                                  mandatory: [CGPoint],
                                  footprints: [NativeOCRDensePrivateFootprintGuard.Footprint],
                                  frame: NativeOCRRGBAFrame) -> Evaluation? {
        guard let polygon = SourcePixelNormalFootprint.polygon(pca: pca.polygon,
            inherited: inherited, pad: 0) else { return nil }
        let support = pca.supportPoints + mandatory
        let candidate = NativeOCRResidualCandidate(
            key: "private-pca-normal-footprint-v1-pad000-retain-current-along",
            polygon: polygon, supportPoints: support)
        func rejected(_ reason: String) -> Evaluation { .init(candidate: candidate, accepted: false, reason: reason) }
        guard !footprints.isEmpty, observation.missingPrivateRGBPixels == 0,
              !support.isEmpty, support.allSatisfy({
                  NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 1e-6)
              }) else { return rejected("normal-footprint-incomplete-support") }
        guard polygon.allSatisfy({ $0.x >= 0 && $0.y >= 0 &&
            $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height) }) else {
            return rejected("normal-footprint-source-frame-invalid")
        }
        let points = inherited + polygon
        guard points.count == 8, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return rejected("normal-footprint-invalid-local-observation")
        }
        let x0 = points.map(\.x).min()!, x1 = points.map(\.x).max()!
        let y0 = points.map(\.y).min()!, y1 = points.map(\.y).max()!
        let padX = max(1, (x1-x0)*0.15), padY = max(1, (y1-y0)*0.15)
        let left = Int(max(0, min(CGFloat(frame.width), floor(x0-padX))))
        let right = Int(max(0, min(CGFloat(frame.width), ceil(x1+padX))))
        let top = Int(max(0, min(CGFloat(frame.height), floor(y0-padY))))
        let bottom = Int(max(0, min(CGFloat(frame.height), ceil(y1+padY))))
        let width = right-left, height = bottom-top
        guard width > 0, height > 0, width <= 2_000_000 / height else {
            return rejected("normal-footprint-local-RGB-budget")
        }
        var bytes = [UInt8](); bytes.reserveCapacity(width*height*4)
        for y in top..<bottom {
            let start = y*frame.bytesPerRow+left*4
            bytes.append(contentsOf: frame.bytes[start..<(start+width*4)])
        }
        let local = NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA(bytes: bytes,
            width: width, height: height, bytesPerRow: width*4, origin: .init(x: left, y: top))
        let normalSpan = inherited.map { m.project($0).x }
        let whole = NativeOCRResidualTurningStrokeGuardHistogram.assess(old: inherited, new: polygon,
            rgba: local, authenticatedPalettes: observation.palettes,
            privateRGBSampleCount: observation.privateRGBSamples, frameOrigin: m.origin,
            normal: m.normal, along: m.along, sourceWidth: m.rect.width,
            inheritedNormalBounds: normalSpan.min()!...normalSpan.max()!)
        guard whole.decision == "no-entire-closed-component-loss-observed" else {
            return rejected("normal-footprint-whole-RGB-" + whole.decision)
        }
        let dense = NativeOCRDensePrivateFootprintGuard.assess(old: inherited, proposed: polygon,
            rgba: .init(bytes: bytes, width: width, height: height, stride: width*4,
                        origin: .init(x: left, y: top)), footprints: footprints,
            origin: m.origin, normal: m.normal, along: m.along, sourceWidth: m.rect.width)
        guard dense.decision == "no-substantial-source-relative-loss-observed" else {
            return rejected("normal-footprint-dense-RGB-" + dense.decision)
        }
        return .init(candidate: candidate, accepted: true, reason: "source-only-menu-native-admission-pending")
    }
}


/// Source-only prototype; caller must freshly admit support, pixels and graph.
enum SourcePixelNormalFootprint {
    static func polygon(pca: [CGPoint], inherited: [CGPoint], pad: CGFloat) -> [CGPoint]? {
        guard pca.count == 4, inherited.count == 4, pad.isFinite, pad >= 0, pad <= 4,
              (pca + inherited).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { .init(x:a.x-b.x,y:a.y-b.y) }
        func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x*b.x+a.y*b.y }
        func unit(_ p: CGPoint) -> CGPoint? {
            let length = hypot(p.x,p.y)
            guard length.isFinite, length > 1e-9 else { return nil }
            return .init(x:p.x/length,y:p.y/length)
        }
        let ne = sub(pca[1],pca[0]), ae = sub(pca[3],pca[0])
        let oldA = sub(inherited[1],inherited[0]), oldB = sub(inherited[3],inherited[0])
        guard let normal = unit(ne), let along = unit(ae),
              var oldAxis = unit(hypot(oldA.x,oldA.y) >= hypot(oldB.x,oldB.y) ? oldA : oldB) else { return nil }
        var cosine = dot(along,oldAxis)
        if cosine < 0 { oldAxis = .init(x:-oldAxis.x,y:-oldAxis.y); cosine = -cosine }
        let closure = sub(pca[2],.init(x:pca[1].x+pca[3].x-pca[0].x,y:pca[1].y+pca[3].y-pca[0].y))
        guard abs(dot(normal,along)) <= 1e-6, hypot(closure.x,closure.y) <= 1e-6, cosine > 0.5 else { return nil }
        let origin = pca[0], delta = 1-pad
        let x0 = delta, x1 = hypot(ne.x,ne.y)-delta
        var y0: CGFloat = 0, y1 = hypot(ae.x,ae.y)
        guard x1 > x0 else { return nil }
        func restore(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            .init(x:origin.x+x*normal.x+y*along.x,y:origin.y+x*normal.y+y*along.y)
        }
        func span(_ points:[CGPoint]) -> (CGFloat,CGFloat) {
            let values = points.map { dot(sub($0,origin),oldAxis) }
            return (values.min()!,values.max()!)
        }
        let oldSpan = span(inherited)
        let newSpan = span([restore(x0,y0),restore(x1,y0),restore(x1,y1),restore(x0,y1)])
        y0 -= max(0,newSpan.0-oldSpan.0)/cosine
        y1 += max(0,oldSpan.1-newSpan.1)/cosine
        let result = [restore(x0,y0),restore(x1,y0),restore(x1,y1),restore(x0,y1)]
        return result.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) ? result : nil
    }
}


/// DEFAULT OFF. Geometry offers only. Does NOT bypass Bank.safe or admit ownership/erasure.
@available(iOS 18.0, *)
enum NativeOCRCurrentAxisStrongPrimaryCapsKeep {
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    enum NormalMode { case unionCurrent, supportOnly }
    struct Configuration {
        let key: String
        let fraction: Double
        let normalMode: NormalMode
        let normalPad: CGFloat
        let alongPixels: CGFloat
        let alongWidthFraction: CGFloat
    }
    static let minimalCurrentTwo: [Configuration] = [
        .init(key: "strong-primary-twoaxis-v1-f25-capskeep-union-n0p0-px0", fraction: 0.25,
              normalMode: .unionCurrent, normalPad: 0, alongPixels: 0, alongWidthFraction: 0),
        .init(key: "strong-primary-twoaxis-v1-f25-capskeep-minimal-n1p0-px2", fraction: 0.25,
              normalMode: .supportOnly, normalPad: 1, alongPixels: 2, alongWidthFraction: 0)
    ]
    struct Member { let measurement: M; let originalGuard: [CGPoint]; let protectedCaps: [CGPoint] }
    struct TypedSupport {
        var owned: [CGPoint] = []
        var realGuards: [CGPoint] = []
        var privateFootprint: [CGPoint] = []
        var caps: [CGPoint] = []
        var qualifiedUnowned: [CGPoint] = []
        var legacyVisible: [CGPoint] = []
        var excludedUnownedIndices: [Int: [Int]] = [:]
        var mandatory: [CGPoint] { owned + realGuards + privateFootprint + caps + qualifiedUnowned }
    }
    struct Offer { let candidate: NativeOCRResidualCandidate; let support: TypedSupport }
    static func observe(_ members: [Member], inherited: [CGPoint], fraction: Double) -> TypedSupport? {
        guard [0.25, 0.5, 0.75].contains(fraction), inherited.count == 4 else { return nil }
        var out = TypedSupport()
        for member in members {
            let m = member.measurement
            guard m.status == "measured", m.privateSamples >= 4, !m.privateHull.isEmpty,
                  m.rect.width > 0 else { return nil }
            func overlap(_ c: NativeOCRSourceComponentMeasurements.Component) -> CGFloat {
                max(0, min(c.bounds.maxX, m.rect.maxX) - max(c.bounds.minX, m.rect.minX))
            }
            let weak = m.components.filter { c in
                c.pixels > 0 && c.insidePixels >= 2 &&
                Double(c.ownedPixels) >= max(2, min(8, Double(c.pixels) * 0.04)) &&
                overlap(c) >= min(c.bounds.width, m.rect.width) * 0.4
            }
            let strong = weak.filter { Double($0.ownedPixels) / Double($0.pixels) >= fraction }
            out.realGuards += m.guardPoints + member.originalGuard
            out.privateFootprint += m.privateHull.map(m.restore)
            out.caps += member.protectedCaps
            for (index, c) in m.components.enumerated() {
                let eligible = c.foreignPixels == 0 && c.insidePixels >= 2 &&
                    overlap(c) >= min(c.bounds.width, m.rect.width) * 0.4
                let legacy = eligible && weak.contains {
                    NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0.colour) <= 40
                }
                if legacy { out.legacyVisible += NativeOCRSourceComponentBounds.clip(c.hull.map(m.restore), to: m.polygon) }
                // ALL owned includes tiny/mixed/foreign-overlap components; never qualified away.
                if c.ownedPixels > 0 { out.owned += c.hull.map(m.restore); continue }
                let retained = eligible && strong.contains {
                    NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0.colour) <= 40
                }
                if retained { out.qualifiedUnowned += NativeOCRSourceComponentBounds.clip(c.hull.map(m.restore), to: inherited) }
                else { out.excludedUnownedIndices[m.index, default: []].append(index) }
            }
        }
        guard !out.mandatory.isEmpty, out.mandatory.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return out
    }
    static func offers(root: M, inherited: [CGPoint], members: [Member], consumedIndices: [Int],
                       associationKey: String?, sourceFrameSize: CGSize,
                       configurations: [Configuration] = minimalCurrentTwo) -> [Offer] {
        let ids = members.map { $0.measurement.index }
        guard inherited.count == 4, root.status == "measured", root.rect.width > 0,
              Set(ids).count == ids.count, Set(consumedIndices).count == consumedIndices.count,
              !consumedIndices.contains(root.index), Set(ids) == Set([root.index] + consumedIndices),
              sourceFrameSize.width > 0, sourceFrameSize.height > 0 else { return [] }
        let a = CGPoint(x: inherited[1].x - inherited[0].x, y: inherited[1].y - inherited[0].y)
        let b = CGPoint(x: inherited[3].x - inherited[0].x, y: inherited[3].y - inherited[0].y)
        let e = hypot(a.x, a.y) >= hypot(b.x, b.y) ? a : b
        let length = hypot(e.x, e.y)
        guard length.isFinite, length > 1e-9 else { return [] }
        let along = CGPoint(x: e.x / length, y: e.y / length)
        let normal = CGPoint(x: along.y, y: -along.x)
        let origin = CGPoint(x: inherited.map(\.x).reduce(0,+)/4, y: inherited.map(\.y).reduce(0,+)/4)
        func project(_ p: CGPoint) -> CGPoint {
            let x = p.x-origin.x, y = p.y-origin.y
            return .init(x: x*normal.x+y*normal.y, y: x*along.x+y*along.y)
        }
        func restore(_ p: CGPoint) -> CGPoint {
            .init(x: origin.x+p.x*normal.x+p.y*along.x, y: origin.y+p.x*normal.y+p.y*along.y)
        }
        let old = inherited.map(project)
        guard old.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        var result: [Offer] = []
        for config in configurations {
            guard config.normalPad.isFinite, config.normalPad >= 0, config.alongPixels.isFinite,
                  config.alongPixels >= 0, config.alongWidthFraction.isFinite, config.alongWidthFraction >= 0,
                  let typed = observe(members, inherited: inherited, fraction: config.fraction) else { continue }
            let support = typed.mandatory.map(project)
            var x0 = support.map(\.x).min()!, x1 = support.map(\.x).max()!
            if config.normalMode == .unionCurrent { x0 = min(x0,old.map(\.x).min()!); x1 = max(x1,old.map(\.x).max()!) }
            x0 -= config.normalPad; x1 += config.normalPad
            let pad = config.alongPixels + config.alongWidthFraction * root.rect.width
            let y0 = support.map(\.y).min()! - pad, y1 = support.map(\.y).max()! + pad
            guard x1 > x0, y1 > y0 else { continue }
            let quad = [CGPoint(x:x0,y:y0),.init(x:x1,y:y0),.init(x:x1,y:y1),.init(x:x0,y:y1)].map(restore)
            guard quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                $0.x <= sourceFrameSize.width && $0.y <= sourceFrameSize.height }) else { continue }
            var candidate = NativeOCRResidualCandidate(key: config.key, polygon: quad,
                consumedIndices: consumedIndices, supportPoints: typed.mandatory)
            candidate.associationKey = associationKey
            result.append(.init(candidate: candidate, support: typed))
        }
        return result
    }
}

// Isolated GT-v1-rebased fixed gate. NO GT or IDs in runtime.
// Call only with native-admitted source-only capskeep candidates; retain ENTIRE actual340 otherwise.
// Full-corpus admission remains pending. Geometry must inherit exact graph/association/support.
enum NativeOCRCurrentAxisSupportRouting {
    static func preferredKey(source22: [Double], rf8: [Double], admittedKeys: Set<String>) -> String? {
        guard source22.count == 22, rf8.count == 8,
              source22.allSatisfy({ $0.isFinite }), rf8.allSatisfy({ $0.isFinite }) else { return nil }
        var v = source22 + rf8
        for i in 16..<30 {
            let scaled = v[i] * 100000000.0
            guard scaled.isFinite else { return nil }
            v[i] = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
        }
        if admittedKeys.contains("strong-primary-twoaxis-v1-f25-capskeep-minimal-n1p0-px2"), (v[8] == 0) && (v[2] >= 0.8 && v[2] < 1.05) && (v[7] <= 0.025774111512728015) && (v[1] > 8.8699637308584798) { return "strong-primary-twoaxis-v1-f25-capskeep-minimal-n1p0-px2" }
        if admittedKeys.contains("strong-primary-twoaxis-v1-f25-capskeep-union-n0p0-px0"), (v[8] == 0) && (v[2] >= 0.8 && v[2] < 1.05) && (v[2] <= 0.81481481481481477) && (v[29] <= -0.0095584619999999794) { return "strong-primary-twoaxis-v1-f25-capskeep-union-n0p0-px0" }
        if admittedKeys.contains("strong-primary-twoaxis-v1-f25-capskeep-union-n0p0-px0"), (v[8] == 0) && (v[2] < 0.8) && (v[19] > 0.20174906200000001) && (v[18] <= 0.100035495) { return "strong-primary-twoaxis-v1-f25-capskeep-union-n0p0-px0" }
        return nil
    }
}


@available(iOS 18.0, *)
extension NativeOCRResidualPrivatePCANative {
    /// Fresh source-support and both original-pixel guards; no prior rectangle retention.
    static func evaluateStrongPrimary(_ m: NativeOCRSourceComponentMeasurements.Measurement,
        observation: NativeOCRPrivateObservation.Retained, candidate: NativeOCRResidualCandidate,
        inherited: [CGPoint], footprints: [NativeOCRDensePrivateFootprintGuard.Footprint],
        frame: NativeOCRRGBAFrame) -> Evaluation {
        let polygon = candidate.polygon
        let support = candidate.supportPoints
        func rejected(_ reason: String) -> Evaluation { .init(candidate: candidate, accepted: false, reason: reason) }
        guard !footprints.isEmpty, observation.missingPrivateRGBPixels == 0,
              !support.isEmpty, support.allSatisfy({
                  NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 1e-6)
              }) else { return rejected("strong-primary-twoaxis-incomplete-support") }
        guard polygon.allSatisfy({ $0.x >= 0 && $0.y >= 0 &&
            $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height) }) else {
            return rejected("strong-primary-twoaxis-source-frame-invalid")
        }
        let points = inherited + polygon
        guard points.count == 8, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return rejected("strong-primary-twoaxis-invalid-local-observation")
        }
        let x0 = points.map(\.x).min()!, x1 = points.map(\.x).max()!
        let y0 = points.map(\.y).min()!, y1 = points.map(\.y).max()!
        let padX = max(1, (x1-x0)*0.15), padY = max(1, (y1-y0)*0.15)
        let left = Int(max(0, min(CGFloat(frame.width), floor(x0-padX))))
        let right = Int(max(0, min(CGFloat(frame.width), ceil(x1+padX))))
        let top = Int(max(0, min(CGFloat(frame.height), floor(y0-padY))))
        let bottom = Int(max(0, min(CGFloat(frame.height), ceil(y1+padY))))
        let width = right-left, height = bottom-top
        guard width > 0, height > 0, width <= 2_000_000 / height else {
            return rejected("strong-primary-twoaxis-local-RGB-budget")
        }
        var bytes = [UInt8](); bytes.reserveCapacity(width*height*4)
        for y in top..<bottom {
            let start = y*frame.bytesPerRow+left*4
            bytes.append(contentsOf: frame.bytes[start..<(start+width*4)])
        }
        let local = NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA(bytes: bytes,
            width: width, height: height, bytesPerRow: width*4, origin: .init(x: left, y: top))
        let normalSpan = inherited.map { m.project($0).x }
        let whole = NativeOCRResidualTurningStrokeGuardHistogram.assess(old: inherited, new: polygon,
            rgba: local, authenticatedPalettes: observation.palettes,
            privateRGBSampleCount: observation.privateRGBSamples, frameOrigin: m.origin,
            normal: m.normal, along: m.along, sourceWidth: m.rect.width,
            inheritedNormalBounds: normalSpan.min()!...normalSpan.max()!)
        guard whole.decision == "no-entire-closed-component-loss-observed" else {
            return rejected("strong-primary-twoaxis-whole-RGB-" + whole.decision)
        }
        let dense = NativeOCRDensePrivateFootprintGuard.assess(old: inherited, proposed: polygon,
            rgba: .init(bytes: bytes, width: width, height: height, stride: width*4,
                        origin: .init(x: left, y: top)), footprints: footprints,
            origin: m.origin, normal: m.normal, along: m.along, sourceWidth: m.rect.width)
        guard dense.decision == "no-substantial-source-relative-loss-observed" else {
            return rejected("strong-primary-twoaxis-dense-RGB-" + dense.decision)
        }
        return .init(candidate: candidate, accepted: true, reason: "source-only-menu-native-admission-pending")
    }
}


/// Additive geometry only. The caller supplies an already freshly native-admitted seed.
/// No acceptance/ownership is created here; original safe, semantic and full child caps still apply.
@available(iOS 18.0, *)
enum NativeOCRPriorEnclosingSeed {
    private static let keys: [String: String] = [
        "support-margin-v1-n15-a20": "prior-envelope-v1-n15-a20",
        "support-margin-v1-n15-a15": "prior-envelope-v1-n15-a15",
        "support-margin-v1-n15-a10": "prior-envelope-v1-n15-a10",
        "support-margin-v1-n20-a15": "prior-envelope-v1-n20-a15",
        "support-margin-v1-n20-a10": "prior-envelope-v1-n20-a10",
        "support-margin-v1-n25-a20": "prior-envelope-v1-n25-a20"
    ]
    static func enclose(seed: NativeOCRResidualCandidate, inherited: [CGPoint],
                        consumedIndices: [Int], associationKey: String?,
                        mandatory: [CGPoint], frameSize: CGSize) -> NativeOCRResidualCandidate? {
        guard let key = keys[seed.key], seed.consumedIndices.isEmpty,
              validQuad(seed.polygon), validQuad(inherited),
              frameSize.width.isFinite, frameSize.height.isFinite,
              frameSize.width > 0, frameSize.height > 0,
              (seed.supportPoints + mandatory).allSatisfy(finite) else { return nil }
        let origin = seed.polygon[0]
        let edge = subtract(seed.polygon[1], origin), length = hypot(edge.x, edge.y)
        guard length.isFinite, length > 0 else { return nil }
        let u = CGPoint(x: edge.x / length, y: edge.y / length)
        let v = CGPoint(x: -u.y, y: u.x)
        let points = seed.polygon + inherited
        let projected = points.map { point -> CGPoint in
            let p = subtract(point, origin)
            return .init(x: dot(p, u), y: dot(p, v))
        }
        guard projected.allSatisfy(finite) else { return nil }
        var x0 = projected.map(\.x).min()!, x1 = projected.map(\.x).max()!
        var y0 = projected.map(\.y).min()!, y1 = projected.map(\.y).max()!
        guard x1 > x0, y1 > y0 else { return nil }
        func polygon() -> [CGPoint] {
            [CGPoint(x:x0,y:y0), .init(x:x1,y:y0), .init(x:x1,y:y1), .init(x:x0,y:y1)].map {
                .init(x: origin.x + $0.x*u.x + $0.y*v.x,
                      y: origin.y + $0.x*u.y + $0.y*v.y)
            }
        }
        var quad = polygon()
        // Strictly outward representational repair only, never a physical pixel tolerance.
        // Needed when translated world-coordinate rounding would otherwise shave a vertex.
        let worldULP = points.flatMap { [abs($0.x).ulp, abs($0.y).ulp] }.max()!
        let localULP = projected.flatMap { [abs($0.x).ulp, abs($0.y).ulp] }.max()!
        var repair = max(worldULP, localULP) * 8
        guard repair.isFinite else { return nil }
        for _ in 0..<4 {
            if points.allSatisfy({ containsStrict(quad, $0) }) { break }
            x0 -= repair; x1 += repair; y0 -= repair; y1 += repair
            quad = polygon(); repair *= 2
        }
        guard validQuad(quad), points.allSatisfy({ containsStrict(quad, $0) }),
              quad.allSatisfy({ $0.x >= 0 && $0.y >= 0 &&
                  $0.x <= frameSize.width && $0.y <= frameSize.height }) else { return nil }
        return .init(key: key, polygon: quad, consumedIndices: consumedIndices,
                     supportPoints: seed.supportPoints + mandatory + inherited,
                     associationKey: associationKey)
    }
    private static func finite(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }
    private static func subtract(_ a: CGPoint, _ b: CGPoint) -> CGPoint { .init(x:a.x-b.x,y:a.y-b.y) }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x*b.x+a.y*b.y }
    private static func cross(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x*b.y-a.y*b.x }
    private static func validQuad(_ q: [CGPoint]) -> Bool {
        guard q.count == 4, q.allSatisfy(finite) else { return false }
        let turns = (0..<4).map { cross(subtract(q[($0+1)%4],q[$0]), subtract(q[($0+2)%4],q[($0+1)%4])) }
        guard turns.allSatisfy({ $0.isFinite }),
              turns.allSatisfy({ $0 > 0 }) || turns.allSatisfy({ $0 < 0 }) else { return false }
        // Translate before area arithmetic: no catastrophic world-coordinate shoelace cancellation.
        let area2 = cross(subtract(q[1],q[0]),subtract(q[2],q[0])) +
                    cross(subtract(q[2],q[0]),subtract(q[3],q[0]))
        return area2.isFinite && abs(area2) > 0
    }
    private static func containsStrict(_ q: [CGPoint], _ point: CGPoint) -> Bool {
        guard q.count == 4 else { return false }
        let values = (0..<4).map { cross(subtract(q[($0+1)%4],q[$0]),subtract(point,q[$0])) }
        return values.allSatisfy({ $0.isFinite && $0 >= 0 }) || values.allSatisfy({ $0.isFinite && $0 <= 0 })
    }
}


/// Fixed source-only suffix30...41. No GT, page/owner IDs, Measurement or world-coordinate feature.
@available(iOS 18.0, *)
enum NativeOCRPriorEnvelopeGeometryFeatures {
    static let names = [
        "envelopeNormalSpanRatio", "envelopeAlongSpanRatio", "envelopeTrueAreaRatio",
        "seedNormalSpanRatio", "seedAlongSpanRatio", "leftExpansionPriorWidths",
        "rightExpansionPriorWidths", "headExpansionPriorWidths", "tailExpansionPriorWidths",
        "seedNormalCenterShiftPriorWidths", "seedAlongCenterShiftPriorLengths", "seedPriorMajorAxisMisalignment"
    ]
    static func raw(prior: [CGPoint], seed: [CGPoint], envelope: [CGPoint]) -> [Double]? {
        guard prior.count == 4, seed.count == 4, envelope.count == 4,
              (prior + seed + envelope).allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let along = major(prior), let seedAlong = major(seed) else { return nil }
        // Stable arithmetic centroid, mathematically the mean of the four prior vertices.
        let p0 = prior[0]
        let origin = CGPoint(x:p0.x + ((prior[1].x-p0.x)+(prior[2].x-p0.x)+(prior[3].x-p0.x))/4,
                             y:p0.y + ((prior[1].y-p0.y)+(prior[2].y-p0.y)+(prior[3].y-p0.y))/4)
        let normal = CGPoint(x:along.y, y:-along.x)
        func bounds(_ q:[CGPoint]) -> [Double]? {
            let p=q.map { point -> CGPoint in
                let x=point.x-origin.x, y=point.y-origin.y
                return .init(x:x*normal.x+y*normal.y,y:x*along.x+y*along.y)
            }
            guard p.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {return nil}
            return [Double(p.map(\.x).min()!),Double(p.map(\.x).max()!),Double(p.map(\.y).min()!),Double(p.map(\.y).max()!)]
        }
        guard let o=bounds(prior),let s=bounds(seed),let n=bounds(envelope) else {return nil}
        let ow=o[1]-o[0],ol=o[3]-o[2],oa=area(prior),na=area(envelope)
        guard ow.isFinite,ol.isFinite,oa.isFinite,na.isFinite,ow>0,ol>0,oa>0 else {return nil}
        let alignment=Double(seedAlong.x*along.x+seedAlong.y*along.y)
        let result=[(n[1]-n[0])/ow,(n[3]-n[2])/ol,na/oa,
                    (s[1]-s[0])/ow,(s[3]-s[2])/ol,
                    (o[0]-n[0])/ow,(n[1]-o[1])/ow,(o[2]-n[2])/ow,(n[3]-o[3])/ow,
                    ((s[0]+s[1])-(o[0]+o[1]))/(2*ow),((s[2]+s[3])-(o[2]+o[3]))/(2*ol),
                    1-abs(alignment)]
        return result.count==12 && result.allSatisfy({$0.isFinite}) ? result:nil
    }
    static func routing(prior:[CGPoint],seed:[CGPoint],envelope:[CGPoint])->[Double]? {
        guard let values=raw(prior:prior,seed:seed,envelope:envelope) else{return nil}
        return quantize(values)
    }
    static func quantize(_ values:[Double])->[Double]? {
        guard values.count==12 else{return nil}
        var result:[Double]=[]
        for value in values {
            let scaled=value*100_000_000
            guard value.isFinite,scaled.isFinite else{return nil}
            let q=scaled.rounded(.toNearestOrAwayFromZero)/100_000_000
            guard q.isFinite else{return nil}
            result.append(q==0 ? 0:q)
        }
        return result
    }
    private static func major(_ q:[CGPoint])->CGPoint? {
        let a=CGPoint(x:q[1].x-q[0].x,y:q[1].y-q[0].y),b=CGPoint(x:q[3].x-q[0].x,y:q[3].y-q[0].y)
        let al=hypot(a.x,a.y),bl=hypot(b.x,b.y),e=al>=bl ? a:b,length=max(al,bl)
        guard length.isFinite,length>0 else{return nil}
        return .init(x:e.x/length,y:e.y/length)
    }
    private static func area(_ q:[CGPoint])->Double {
        let o=q[0]
        var twice:Double=0
        for i in 0..<4 {
            let a=q[i],b=q[(i+1)%4]
            twice += Double((a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x))
        }
        return abs(twice)/2
    }
}

import Foundation
import CoreGraphics
import CryptoKit

/// PROPOSAL ONLY. Audit payload builder, never admission, selection or erasure.
/// No environment access, file writes, global state or measurement calls.
@available(iOS 18.0, *)
enum NativeOCRPrivateObservationAudit {
    struct Identity {
        let requestTag: String // Opaque output correlation only; never policy input.
        let sourceSHA256: String // Supplied by authenticated host input, not guessed here.
        let binarySHA256: String
        let observationSourceSHA256: String
    }
    struct Request {
        let identity: Identity
        let sourceIndex: Int // Audit correlation only, never geometry/admission input.
        let inherited: [CGPoint]
        let proposed: [CGPoint]
    }
    struct Input {
        let identity: Identity
        let measurement: NativeOCRSourceComponentMeasurements.Measurement
        let inherited: [CGPoint]
        let proposed: [CGPoint]
        let memberIndices: [Int] // Actual root Context.groups[index] ?? [index].
        let hasContextOverride: Bool
        let terminalCaps: [CGPoint] // Actual bank caps; read-only diagnostic.
        let frame: NativeOCRRGBAFrame
    }
    /// One instance per explicit bounded host audit job; never shared across workers.
    final class Session {
        let enabled: Bool
        private var attempts = 0
        private var pixels = 0
        init(enabled: Bool = false) { self.enabled = enabled }

        /// Flag OFF never invokes load, touches frame/m/context or changes counters.
        /// Caller must also keep Session creation inside its explicit export-only flag.
        func capture(load: () -> Input?) -> [String: Any]? {
            guard enabled else { return nil }
            guard attempts < 6 else { return nil }
            attempts += 1
            guard let input = load() else {
                return ["schema": "native-private-observation-terminal-audit-v1",
                        "status": "unavailable-authenticated-root-input"]
            }
            let m = input.measurement
            guard input.inherited.count == 4, input.proposed.count == 4, m.polygon.count == 4,
                  (input.inherited + input.proposed + m.polygon + m.privateHull +
                    [m.origin, m.normal, m.along]).allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  m.rect.width.isFinite, m.privateHull.count <= 16_384 else {
                return ["schema": "native-private-observation-terminal-audit-v1",
                        "status": "unavailable-private-hull-budget"]
            }
            func pair(_ p: CGPoint) -> [Double] { [Double(p.x), Double(p.y)] }
            var payload: [String: Any] = [
                "schema": "native-private-observation-terminal-audit-v1",
                "status": "unavailable", "requestTag": input.identity.requestTag,
                "sourceSHA256": input.identity.sourceSHA256,
                "binarySHA256": input.identity.binarySHA256,
                "observationSourceSHA256": input.identity.observationSourceSHA256,
                "sourceIndex": m.index, "measurementStatus": m.status,
                "measurementPolygon": m.polygon.map(pair),
                "inheritedPolygon": input.inherited.map(pair),
                "proposedPolygon": input.proposed.map(pair),
                "origin": pair(m.origin), "normal": pair(m.normal), "along": pair(m.along),
                "sourceWidth": Double(m.rect.width),
                "associatedOwners": m.associatedOwners, "provisionalOwners": m.provisionalOwners,
                "memberIndices": input.memberIndices, "hasContextOverride": input.hasContextOverride,
                "privateSamples": m.privateSamples,
                "privatePointSetSHA256": NSNull(),
                "privatePointSetStatus": "not-retained; no reconstruction from hull or original detector RLE",
                "ownershipMutated": false, "auditIsAdmission": false
            ]
            func unavailable(_ reason: String) -> [String: Any] {
                payload["unavailableReason"] = reason
                return payload
            }
            func validSHA(_ s: String) -> Bool {
                s.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
            guard validSHA(input.identity.sourceSHA256), validSHA(input.identity.binarySHA256),
                  validSHA(input.identity.observationSourceSHA256) else {
                return unavailable("missing-authenticated-host-hashes")
            }
            guard m.status == "measured", let retained = m.privateObservation else {
                return unavailable("actual-root-privateObservation-not-retained")
            }
            guard [retained.moments.meanX, retained.moments.meanY, retained.moments.xx,
                   retained.moments.xy, retained.moments.yy].allSatisfy({ $0.isFinite }),
                  retained.palettes.count <= 16,
                  retained.palettes.allSatisfy({ $0.rgb.count == 3 }) else {
                return unavailable("invalid-or-over-budget-retained-palette")
            }
            // Directly copy PRODUCTION8 medians. No bins32, resampling or substitutions.
            payload["privateRGBSamples"] = retained.privateRGBSamples
            payload["missingPrivateRGBPixels"] = retained.missingPrivateRGBPixels
            payload["production8Palettes"] = retained.palettes.map {
                ["rgb": $0.rgb, "sourceSeedBinCount": $0.sourceSeedBinCount, "bin": $0.bin] as [String: Any]
            }
            payload["moments"] = ["count": retained.moments.count,
                "meanX": retained.moments.meanX, "meanY": retained.moments.meanY,
                "xx": retained.moments.xx, "xy": retained.moments.xy, "yy": retained.moments.yy]
            payload["privateHull"] = m.privateHull.map(pair)
            guard let footprint = retained.footprint else {
                return unavailable("actual-root-footprint-not-retained; do-not-substitute-original-RLE")
            }
            let allPoints = input.inherited + input.proposed
            guard input.inherited.count == 4, input.proposed.count == 4,
                  allPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  m.privateHull.count <= 16_384, retained.palettes.count <= 16,
                  footprint.width > 0, footprint.height > 0,
                  footprint.width <= Int.max / footprint.height,
                  footprint.scaleX.isFinite, footprint.scaleY.isFinite,
                  footprint.scaleX > 0, footprint.scaleY > 0,
                  footprint.cells.count <= 262_144,
                  footprint.cells.allSatisfy({ $0 >= 0 && $0 < footprint.width * footprint.height }) else {
                return unavailable("invalid-or-over-budget-observation")
            }
            let frame = input.frame
            guard allPoints.allSatisfy({ $0.x >= 0 && $0.y >= 0 &&
                $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height) }) else {
                return unavailable("pair-outside-authenticated-frame")
            }
            let x0 = allPoints.map(\.x).min()!, x1 = allPoints.map(\.x).max()!
            let y0 = allPoints.map(\.y).min()!, y1 = allPoints.map(\.y).max()!
            // Exactly union bbox +/-15%, outward integer pixel rounding only.
            let left = Int(max(0, floor(x0 - (x1 - x0) * 0.15)))
            let right = Int(min(CGFloat(frame.width), ceil(x1 + (x1 - x0) * 0.15)))
            let top = Int(max(0, floor(y0 - (y1 - y0) * 0.15)))
            let bottom = Int(min(CGFloat(frame.height), ceil(y1 + (y1 - y0) * 0.15)))
            let width = right - left, height = bottom - top
            guard width > 0, height > 0, (width < frame.width || height < frame.height),
                  width <= 600_000 / height,
                  width * height <= 2_000_000 - pixels else {
                return unavailable("bbox-local-or-session-pixel-budget")
            }
            let cells = footprint.cells.sorted()
            func u64(_ n: UInt64, into data: inout Data) {
                var value = n.littleEndian
                Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            func digest(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
            var encoded = Data()
            u64(UInt64(footprint.width), into: &encoded); u64(UInt64(footprint.height), into: &encoded)
            u64(Double(footprint.scaleX).bitPattern, into: &encoded)
            u64(Double(footprint.scaleY).bitPattern, into: &encoded)
            for cell in cells { u64(UInt64(cell), into: &encoded) }
            // Export only original cells whose source rectangles intersect this local crop.
            let localCells = cells.filter { cell in
                let x = CGFloat(cell % footprint.width) * footprint.scaleX
                let y = CGFloat(cell / footprint.width) * footprint.scaleY
                return x < CGFloat(right) && x + footprint.scaleX > CGFloat(left) &&
                    y < CGFloat(bottom) && y + footprint.scaleY > CGFloat(top)
            }
            var runs: [[Int]] = []
            for cell in localCells {
                let x = cell % footprint.width, y = cell / footprint.width
                if let last = runs.last, last[0] == y && last[1] + last[2] == x {
                    runs[runs.count - 1][2] += 1
                } else { runs.append([y, x, 1]) }
            }
            var rgba = Data(); rgba.reserveCapacity(width * height * 4)
            for y in top..<bottom {
                let start = y * frame.bytesPerRow + left * 4
                rgba.append(contentsOf: frame.bytes[start..<(start + width * 4)])
            }
            // Bounded read-only attribution evidence in the already approved local crop.
            // Counts describe each complete measured component, not its clipped hull pixels.
            let roi: [CGPoint] = [.init(x: left, y: top), .init(x: right, y: top),
                .init(x: right, y: bottom), .init(x: left, y: bottom)]
            if m.components.count <= 512 && m.components.reduce(0, { $0 + $1.hull.count }) <= 16_384 {
                var localVertexCount = 0
                let localComponents: [[String: Any]] = m.components.enumerated().compactMap { ordinal, component in
                    let hull = NativeOCRSourceComponentBounds.clip(component.hull.map(m.restore), to: roi)
                    guard !hull.isEmpty else { return nil }
                    localVertexCount += hull.count
                    return ["componentOrdinal": ordinal, "colour": [component.colour.x, component.colour.y, component.colour.z],
                        "pixels": component.pixels, "ownedPixels": component.ownedPixels,
                        "foreignPixels": component.foreignPixels, "insidePixels": component.insidePixels,
                        "projectedBounds": [Double(component.bounds.minX), Double(component.bounds.minY),
                            Double(component.bounds.maxX), Double(component.bounds.maxY)],
                        "clippedWorldHull": hull.map(pair),
                        "countScope": "actual complete measured component; hull clipped to local ROI; not a pixel ownership mask"]
                }
                if localVertexCount <= 16_384 {
                    payload["sourceComponents"] = localComponents
                    payload["sourceComponentStatus"] = "actual-bounded-local-clipped-hulls"
                } else {
                    payload["sourceComponentStatus"] = "unavailable-clipped-vertex-budget; no substitution"
                }
            } else {
                payload["sourceComponentStatus"] = "unavailable-component-budget; no substitution"
            }
            let visible = NativeOCRSourceComponentMeasurements.convexHull(
                NativeOCRSourceComponentBounds.visibleForeground(m))
            if visible.count <= 16_384 {
                payload["visibleForegroundClippedHull"] = NativeOCRSourceComponentBounds.clip(visible, to: roi).map(pair)
            }
            payload["terminalCapsCount"] = input.terminalCaps.count
            if input.terminalCaps.count <= 16_384 {
                payload["terminalCapsInLocalROI"] = input.terminalCaps.filter {
                    $0.x >= CGFloat(left) && $0.x <= CGFloat(right) &&
                    $0.y >= CGFloat(top) && $0.y <= CGFloat(bottom)
                }.map(pair)
            }
            pixels += width * height
            payload["status"] = "actual-retained-palette-and-local-footprint"
            payload["footprint"] = ["width": footprint.width, "height": footprint.height,
                "scaleX": Double(footprint.scaleX), "scaleY": Double(footprint.scaleY),
                "totalCellCount": cells.count, "fullCellSetSHA256": digest(encoded),
                "hashSchema": "u64le(width,height,Float64scaleXbits,Float64scaleYbits,sortedCells...)",
                "localCellCount": localCells.count, "localRunsYXCount": runs,
                "scope": "exact-root-cells-clipped-to-local-crop; no hull fill"]
            payload["localRGBA"] = ["origin": [left, top], "width": width, "height": height,
                "bytesPerRow": width * 4, "sha256": digest(rgba), "base64": rgba.base64EncodedString(),
                "bounds": [left, top, right, bottom], "paddingFraction": 0.15]
            return payload
        }
    }
}


// Source-body proposal357: only explicitly requested audit-prefix generation.
import Foundation
import CoreGraphics

/// Additional, read-only terminal-loss veto. No-veto grants no admission or erasure.
/// Palette observations and pixel closure must refer to the same original source.
@available(iOS 18.0, *)
enum NativeOCRAlignedGradientTerminalGuard {
    typealias LocalRGBA = NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA
    typealias Palette = NativeOCRResidualTurningStrokeGuardHistogram.Palette
    struct Witness: Codable {
        let foreground: [Int]
        let background: [Int]
        let contrast: Double
        let terminalBounds: [Double]
        let terminalPixels: Int
        let oldIncluded: Int
        let newIncluded: Int
        let oldCore: Int
        let newCore: Int
        let lostCore: Int
        let oldCoreLossFraction: Double
        let lost2x2: Int
        let terminalMinorVariance: Double
        let bodyBounds: [Double]
        let retainedAuthenticBodyPixels: Int
        let bodyRGBMin: [Int]
        let bodyRGBMax: [Int]
        let normalOverlap: Double
        let alongGap: Double
        let reason: String
    }
    struct Result: Codable {
        let decision: String
        let witnesses: [Witness]
        let examinedPairs: Int
        let authenticatedBodies: Int
        let bodyMask: [UInt8]?
        let terminalMask: [UInt8]?
        let noVetoIsNotAdmission: Bool
        let ownershipMutated: Bool
    }
    private struct Component {
        var pixels: [Int]
        var open: Bool
        var bounds: [Double]
        var n0: Double
        var n1: Double
        var a0: Double
        var a1: Double
        var oldCount: Int
        var newCount: Int
        var oldCore: Int
        var newCore: Int
        var privateRetained: Int
        var minorVariance: Double
    }
    static func assess(
        old: [CGPoint], new: [CGPoint], rgba: LocalRGBA,
        authenticatedPalettes: [Palette], frameOrigin: CGPoint,
        normal: CGPoint, along: CGPoint, sourceWidth: Double,
        isPrivatePixel: (Int, Int) -> Bool, includeMasks: Bool = false
    ) -> Result {
        func result(_ decision: String, _ witnesses: [Witness] = [], _ pairs: Int = 0,
                    _ bodies: Int = 0, _ bm: [UInt8]? = nil, _ tm: [UInt8]? = nil) -> Result {
            .init(decision: decision, witnesses: witnesses, examinedPairs: pairs,
                  authenticatedBodies: bodies, bodyMask: bm, terminalMask: tm,
                  noVetoIsNotAdmission: true, ownershipMutated: false)
        }
        let w = rgba.width, h = rgba.height, stride = rgba.bytesPerRow
        let finite = old + new + [rgba.origin, frameOrigin, normal, along]
        guard w > 0, h > 0, w <= 600_000 / h, w <= Int.max / 4,
              stride >= w * 4, h <= Int.max / stride, rgba.bytes.count >= h * stride,
              old.count == 4, new.count == 4, sourceWidth.isFinite, sourceWidth > 0,
              finite.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              abs(hypot(normal.x, normal.y) - 1) < 0.01,
              abs(hypot(along.x, along.y) - 1) < 0.01,
              abs(normal.x * along.x + normal.y * along.y) < 0.01 else {
            return result("uncertain-invalid-source-input")
        }
        guard old.allSatisfy({ $0.x >= rgba.origin.x && $0.y >= rgba.origin.y &&
            $0.x <= rgba.origin.x + Double(w) && $0.y <= rgba.origin.y + Double(h) }) else {
            return result("uncertain-inherited-source-not-observed")
        }
        func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
            var positive = false, negative = false
            for i in 0..<q.count {
                let a = q[i], b = q[(i + 1) % q.count]
                let c = (b.x-a.x)*(p.y-a.y) - (b.y-a.y)*(p.x-a.x)
                if c > 1e-7 { positive = true }; if c < -1e-7 { negative = true }
            }
            return !positive || !negative
        }
        func distance(_ q: [CGPoint], _ p: CGPoint) -> Double {
            if contains(q, p) { return 0 }
            var value = Double.infinity
            for i in 0..<q.count {
                let a = q[i], b = q[(i+1)%q.count], dx = b.x-a.x, dy = b.y-a.y
                let length = dx*dx + dy*dy
                let t = length > 0 ? max(0, min(1, ((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
                value = min(value, hypot(p.x-a.x-t*dx, p.y-a.y-t*dy))
            }
            return value
        }
        let count = w*h
        var rgb = [[Double]](repeating: [], count: count)
        var opaque = [Bool](repeating: false, count: count)
        var oldInside = opaque, newInside = opaque, privateRetained = opaque
        var np = [Double](repeating: 0, count: count), ap = np, outside = np
        for p in 0..<count {
            let x = p%w, y = p/w, offset = y*stride+x*4
            opaque[p] = rgba.bytes[offset+3] == 255
            rgb[p] = (0..<3).map { Double(rgba.bytes[offset+$0]) }
            let point = CGPoint(x: rgba.origin.x+Double(x)+0.5, y: rgba.origin.y+Double(y)+0.5)
            oldInside[p] = contains(old, point); newInside[p] = contains(new, point)
            let dx = point.x-frameOrigin.x, dy = point.y-frameOrigin.y
            np[p] = dx*normal.x+dy*normal.y; ap[p] = dx*along.x+dy*along.y
            outside[p] = oldInside[p] && !newInside[p] ? distance(new, point) : 0
            privateRetained[p] = opaque[p] && oldInside[p] && newInside[p] &&
                isPrivatePixel(Int(floor(point.x+1e-7)), Int(floor(point.y+1e-7)))
        }
        var palettes = authenticatedPalettes.filter {
            $0.rgb.count == 3 && $0.sourceSeedBinCount >= 3 && $0.rgb.allSatisfy({ (0...255).contains($0) })
        }
        // Retained8 bins can contain only background when a tiny gradient stem
        // spreads its real colours over many bins. Re-observe endpoint colours
        // ONLY on original, private, old+new-retained source-contrast pixels.
        // Binning learns palette anchors; CC segmentation below remains a RGB ray.
        var edge = [Bool](repeating: false, count: count)
        if w >= 3 && h >= 3 {
            for y in 1..<(h-1) { for x in 1..<(w-1) {
                let p = y*w+x
                for c in 0..<3 {
                    let a=rgb[p-w-1][c],b=rgb[p-w][c],d=rgb[p-w+1][c]
                    let e=rgb[p-1][c],f=rgb[p+1][c]
                    let g=rgb[p+w-1][c],h=rgb[p+w][c],j=rgb[p+w+1][c]
                    if max(abs(-a+d-2*e+2*f-g+j),abs(-a-2*b-d+g+2*h+j)) > 144 {
                        edge[p] = true; break
                    }
                }
            }}
        }
        var endpointBins: [Int: [Int]] = [:]
        for p in 0..<count where privateRetained[p] {
            let x=p%w,y=p/w
            let nearEdge = (max(0,y-1)...min(h-1,y+1)).contains { yy in
                (max(0,x-1)...min(w-1,x+1)).contains { xx in edge[yy*w+xx] }
            }
            guard nearEdge else { continue }
            let code = Int(rgb[p][0])/32*64+Int(rgb[p][1])/32*8+Int(rgb[p][2])/32
            endpointBins[code,default:[]].append(p)
        }
        let endpointOrder = endpointBins.keys.sorted {
            endpointBins[$0]!.count == endpointBins[$1]!.count ? $0 < $1 : endpointBins[$0]!.count > endpointBins[$1]!.count
        }
        for code in endpointOrder.prefix(16) {
            let pixels=endpointBins[code]!
            guard pixels.count >= 3 else { continue }
            let colour = (0..<3).map { c -> Int in
                let sorted=pixels.map { rgb[$0][c] }.sorted(), middle=sorted.count/2
                let median=sorted.count%2==0 ? (sorted[middle-1]+sorted[middle])/2 : sorted[middle]
                return Int(median.rounded(.toNearestOrEven))
            }
            if !palettes.contains(where: { $0.rgb == colour }) {
                palettes.append(.init(rgb:colour,sourceSeedBinCount:pixels.count,bin:code))
            }
        }
        var pairs: [(Int, Int, Double, Int)] = []
        for i in palettes.indices { for j in palettes.indices where i != j {
            let d = zip(palettes[i].rgb, palettes[j].rgb).map { Double($0-$1) }
            let contrast = sqrt(d.reduce(0) { $0+$1*$1 })
            if contrast >= 64 { pairs.append((i,j,contrast,min(palettes[i].sourceSeedBinCount,palettes[j].sourceSeedBinCount))) }
        }}
        pairs.sort { $0.3 == $1.3 ? ($0.2 == $1.2 ? ($0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0) : $0.2 > $1.2) : $0.3 > $1.3 }
        var examined = 0, bodyCount = 0
        var bodyMask = [UInt8](repeating: 0, count: includeMasks ? count : 0)
        var terminalMask = bodyMask
        for pair in pairs.prefix(32) {
            let foreground = palettes[pair.0].rgb, background = palettes[pair.1].rgb
            // Do not promote an intermediate AA shade into a body endpoint when
            // a stronger authenticated endpoint explains the same colour ray.
            // This only removes candidate colour pairs; pixel tolerance stays0.1.
            let intermediate = palettes.indices.contains { k in
                guard k != pair.0 && k != pair.1,
                      palettes[k].sourceSeedBinCount >= palettes[pair.0].sourceSeedBinCount else { return false }
                let ray = (0..<3).map { Double(palettes[k].rgb[$0]-background[$0]) }
                let length2 = ray.reduce(0) { $0+$1*$1 }, length = sqrt(length2)
                guard length > pair.2*1.15 else { return false }
                let t = (0..<3).reduce(0.0) { $0+Double(foreground[$1]-background[$1])*ray[$1] }/length2
                guard t >= 0.2 && t <= 0.95 else { return false }
                let error = (0..<3).map { abs(Double(foreground[$0]-background[$0])-t*ray[$0]) }.max()!
                return error <= max(16,length*0.15)
            }
            if intermediate { continue }
            examined += 1
            let delta = zip(foreground,background).map { Double($0-$1) }
            let squared = pair.2*pair.2, tolerance = max(12, pair.2*0.1)
            // A line-compatible AA shard is not an authenticated body endpoint.
            // Require actual retained private pixels near the foreground endpoint.
            let endpointTolerance = max(16, pair.2*0.05)
            var mask = [Bool](repeating: false, count: count), core = mask
            for p in 0..<count where opaque[p] {
                var t = 0.0
                for c in 0..<3 { t += (rgb[p][c]-Double(background[c]))*delta[c] }
                t /= squared
                guard t >= 0.25 && t <= 1.6 else { continue }
                var residual = 0.0
                for c in 0..<3 { residual = max(residual, abs(rgb[p][c]-Double(background[c])-t*delta[c])) }
                if residual <= tolerance { mask[p] = true; core[p] = t >= 0.45 }
            }
            var seen = [Bool](repeating: false, count: count), components: [Component] = []
            for seed in 0..<count where mask[seed] && !seen[seed] {
                var queue = [seed], cursor = 0, open = false, x0 = w, y0 = h, x1 = 0, y1 = 0
                var n0 = Double.infinity, n1 = -Double.infinity, a0 = n0, a1 = n1
                var oc = 0, nc = 0, ocore = 0, ncore = 0, pr = 0
                seen[seed] = true
                while cursor < queue.count {
                    let p = queue[cursor]; cursor += 1; let x = p%w, y = p/w
                    x0 = min(x0,x); x1 = max(x1,x); y0 = min(y0,y); y1 = max(y1,y)
                    open = open || x == 0 || y == 0 || x == w-1 || y == h-1
                    n0 = min(n0,np[p]); n1 = max(n1,np[p]); a0 = min(a0,ap[p]); a1 = max(a1,ap[p])
                    if oldInside[p] { oc += 1; if core[p] { ocore += 1 } }
                    if newInside[p] { nc += 1; if core[p] { ncore += 1 } }
                    if privateRetained[p] && core[p] {
                        let error = (0..<3).map { abs(rgb[p][$0]-Double(foreground[$0])) }.max()!
                        if error <= endpointTolerance { pr += 1 }
                    }
                    for yy in max(0,y-1)...min(h-1,y+1) { for xx in max(0,x-1)...min(w-1,x+1) {
                        let next = yy*w+xx
                        if mask[next] && !seen[next] { seen[next] = true; queue.append(next) }
                    }}
                }
                let meanN = queue.reduce(0.0) { $0+np[$1] }/Double(queue.count)
                let meanA = queue.reduce(0.0) { $0+ap[$1] }/Double(queue.count)
                var xx = 0.0, xy = 0.0, yy = 0.0
                for p in queue { let n=np[p]-meanN, a=ap[p]-meanA; xx += n*n; xy += n*a; yy += a*a }
                let denominator = Double(queue.count); xx /= denominator; xy /= denominator; yy /= denominator
                let minor = max(0,(xx+yy-hypot(xx-yy,2*xy))/2)
                components.append(.init(pixels:queue,open:open,
                    bounds:[rgba.origin.x+Double(x0),rgba.origin.y+Double(y0),rgba.origin.x+Double(x1+1),rgba.origin.y+Double(y1+1)],
                    n0:n0,n1:n1,a0:a0,a1:a1,oldCount:oc,newCount:nc,oldCore:ocore,newCore:ncore,
                    privateRetained:pr,minorVariance:minor))
            }
            let bodies = components.filter { !$0.open && $0.privateRetained >= 4 &&
                $0.n1-$0.n0+1 <= 1.7*sourceWidth && $0.a1-$0.a0+1 <= 2.2*sourceWidth }
            bodyCount += bodies.count
            if includeMasks { for body in bodies { for p in body.pixels { bodyMask[p] = 255 } } }
            guard !bodies.isEmpty else { continue }
            for terminal in components where !terminal.open && terminal.oldCore >= 4 &&
                terminal.n1-terminal.n0+1 <= max(4,0.8*sourceWidth) &&
                terminal.a1-terminal.a0+1 <= max(4,0.8*sourceWidth) && terminal.minorVariance >= 0.15 {
                let terminalFill = Double(terminal.pixels.count)/((terminal.bounds[2]-terminal.bounds[0])*(terminal.bounds[3]-terminal.bounds[1]))
                let fullCore = Set(terminal.pixels.filter { core[$0] })
                let solidCore = fullCore.contains { p in
                    p%w < w-1 && p/w < h-1 && fullCore.contains(p+1) && fullCore.contains(p+w) && fullCore.contains(p+w+1)
                }
                guard terminalFill >= 0.35, solidCore else { continue }
                let lostCore = terminal.pixels.filter { core[$0] && oldInside[$0] && !newInside[$0] }.count
                let fraction = Double(lostCore)/Double(terminal.oldCore)
                var lost2x2 = 0
                let membership = Set(terminal.pixels.filter { oldInside[$0] && !newInside[$0] && outside[$0] > 1+1e-7 })
                for p in membership where p%w < w-1 && p/w < h-1 {
                    if membership.contains(p+1) && membership.contains(p+w) && membership.contains(p+w+1) { lost2x2 += 1 }
                }
                let wholeLoss = terminal.newCount == 0 && terminal.oldCount >= 4 && lost2x2 > 0
                let partialLoss = lostCore >= 2 && fraction >= 0.15
                guard wholeLoss || partialLoss else { continue }
                for body in bodies {
                    let overlap = max(0,min(terminal.n1,body.n1)-max(terminal.n0,body.n0)+1)
                    let minimumWidth = min(terminal.n1-terminal.n0+1,body.n1-body.n0+1)
                    let centerOffset = abs((terminal.n0+terminal.n1-body.n0-body.n1)/2)
                    let gap = max(0,terminal.a0-body.a1-1,body.a0-terminal.a1-1)
                    let outsideBody = (terminal.a0+terminal.a1)/2 < body.a0 || (terminal.a0+terminal.a1)/2 > body.a1
                    guard outsideBody, overlap >= 0.4*minimumWidth,
                          centerOffset <= max(1,sourceWidth*0.35), gap <= 1.5*sourceWidth else { continue }
                    let actual = body.pixels.filter { privateRetained[$0] && core[$0] }
                    var low = [255,255,255], high = [0,0,0]
                    for p in actual { for c in 0..<3 { low[c] = min(low[c],Int(rgb[p][c])); high[c] = max(high[c],Int(rgb[p][c])) } }
                    if includeMasks { for p in terminal.pixels { terminalMask[p] = 255 } }
                    let witness = Witness(foreground:foreground,background:background,contrast:pair.2,
                        terminalBounds:terminal.bounds,terminalPixels:terminal.pixels.count,
                        oldIncluded:terminal.oldCount,newIncluded:terminal.newCount,
                        oldCore:terminal.oldCore,newCore:terminal.newCore,lostCore:lostCore,
                        oldCoreLossFraction:fraction,lost2x2:lost2x2,terminalMinorVariance:terminal.minorVariance,
                        bodyBounds:body.bounds,retainedAuthenticBodyPixels:body.privateRetained,
                        bodyRGBMin:low,bodyRGBMax:high,normalOverlap:overlap,alongGap:gap,
                        reason:wholeLoss ? "whole-qualified-aligned-gradient-terminal-lost" : "partial-qualified-terminal-core-loss")
                    return result("reject",[witness],examined,bodyCount,includeMasks ? bodyMask:nil,includeMasks ? terminalMask:nil)
                }
            }
        }
        return result("no-qualified-terminal-loss-observed",[],examined,bodyCount,
                      includeMasks ? bodyMask:nil,includeMasks ? terminalMask:nil)
    }
}


import Foundation
import CoreGraphics

/// DEFAULT OFF proposal: read-only source contrast evidence, never pixel ownership,
/// complete glyph inventory, geometry admission, terminal completeness or erasure.
@available(iOS 18.0, *)
enum NativeOCRSourceAuthenticatedBodyEvidence {
    struct FrameSize: Equatable { let width: Int; let height: Int }
    struct Window {
        let frameSize: FrameSize
        let left: Int
        let top: Int
        let width: Int
        let height: Int
        fileprivate let sourceQuads: [[CGPoint]]
        fileprivate init(frameSize: FrameSize, left: Int, top: Int, width: Int, height: Int,
                         sourceQuads: [[CGPoint]]) {
            self.frameSize=frameSize;self.left=left;self.top=top;self.width=width;self.height=height
            self.sourceQuads=sourceQuads
        }
        /// Root/child priors (or an exact old/proposed query pair) define one shared local ROI.
        /// Pure metadata preflight: no frame provider or source pixel access.
        static func make(sourceQuads: [[CGPoint]], frameSize: FrameSize) -> Window? {
            guard frameSize.width>0,frameSize.height>0,sourceQuads.count>0,sourceQuads.count<=64,
                  sourceQuads.allSatisfy(validQuad) else {return nil}
            let points=sourceQuads.flatMap{$0}
            guard points.allSatisfy({$0.x>=0 && $0.y>=0 && $0.x<=CGFloat(frameSize.width) && $0.y<=CGFloat(frameSize.height)}) else{return nil}
            let x0=points.map(\.x).min()!,x1=points.map(\.x).max()!,y0=points.map(\.y).min()!,y1=points.map(\.y).max()!
            let left=Int(max(0,floor(x0-(x1-x0)*0.15))),right=Int(min(CGFloat(frameSize.width),ceil(x1+(x1-x0)*0.15)))
            let top=Int(max(0,floor(y0-(y1-y0)*0.15))),bottom=Int(min(CGFloat(frameSize.height),ceil(y1+(y1-y0)*0.15)))
            let width=right-left,height=bottom-top
            guard width>0,height>0,(width<frameSize.width || height<frameSize.height),width<=600_000/height else{return nil}
            return .init(frameSize:frameSize,left:left,top:top,width:width,height:height,sourceQuads:sourceQuads)
        }
    }
    struct Prepared {
        let inherited: [CGPoint]
        let window: Window
        let sourceOrigin: CGPoint
        let normal: CGPoint
        let along: CGPoint
        let sourceWidth: Double
        let actualPalettes: [NativeOCRResidualTurningStrokeGuardHistogram.Palette]
        let actualFullFootprint: NativeOCRDensePrivateFootprintGuard.Footprint
        fileprivate init(m: NativeOCRSourceComponentMeasurements.Measurement,
                         observation: NativeOCRPrivateObservation.Retained,
                         footprint: NativeOCRDensePrivateFootprintGuard.Footprint,
                         inherited: [CGPoint],window: Window) {
            self.inherited=inherited;self.window=window;self.sourceOrigin=m.origin;self.normal=m.normal
            self.along=m.along;self.sourceWidth=m.rect.width;self.actualPalettes=observation.palettes
            self.actualFullFootprint=footprint
        }
    }
    struct Preparation { let status: String; let prepared: Prepared? }
    struct SourceWindow {
        let window: Window
        let rgba: NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA
        fileprivate init(window: Window,rgba: NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA) {
            self.window=window;self.rgba=rgba
        }
    }
    struct Evidence {
        let prepared: Prepared
        let source: SourceWindow
        let sourceAuthenticatedContrastBodyMask: [UInt8]
        let nativeBodyCountAcrossPairs: Int
        let nativeExaminedPalettePairs: Int
        let uniqueMaskPixels: Int
        let pixelOwnershipTruth = false
        let completeGlyphInventory = false
        let completeTerminalMask = false
        let grantsAdmission = false
        let ownershipChanged = false
        var sourceLocalRGBA: NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA { source.rgba }
        var actualPalettes: [NativeOCRResidualTurningStrokeGuardHistogram.Palette] { prepared.actualPalettes }
        var actualFullFootprint: NativeOCRDensePrivateFootprintGuard.Footprint { prepared.actualFullFootprint }
        func isPrivatePixel(_ x: Int,_ y: Int) -> Bool {
            actualFullFootprint.contains(.init(x:x,y:y))
        }
        /// Same original RGB, actual palette and ORIGINAL full footprint; no frame call.
        /// Nil or no-veto is not permission: caller retains inherited on uncertainty.
        func terminalObservation(proposed: [CGPoint],includeMasks: Bool=false) -> NativeOCRAlignedGradientTerminalGuard.Result? {
            guard validQuad(proposed),proposed.allSatisfy({$0.x>=0 && $0.y>=0 &&
                $0.x<=CGFloat(source.window.frameSize.width) && $0.y<=CGFloat(source.window.frameSize.height)}) else{return nil}
            return NativeOCRAlignedGradientTerminalGuard.assess(old:prepared.inherited,new:proposed,
                rgba:source.rgba,authenticatedPalettes:actualPalettes,frameOrigin:prepared.sourceOrigin,
                normal:prepared.normal,along:prepared.along,sourceWidth:prepared.sourceWidth,
                isPrivatePixel:isPrivatePixel,includeMasks:includeMasks)
        }
    }
    struct Result { let status: String; let evidence: Evidence? }

    /// OFF, missing observation/full footprint, malformed/overbudget ROI: ZERO frame calls.
    static func prepare(_ m: NativeOCRSourceComponentMeasurements.Measurement,inherited: [CGPoint],
                        frameSize: FrameSize,enabled: Bool=false,sharedWindow: Window?=nil) -> Preparation {
        guard enabled else{return .init(status:"disabled",prepared:nil)}
        guard m.status=="measured",validQuad(inherited),m.rect.width.isFinite,m.rect.width>0,
              [m.origin,m.normal,m.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              let p=m.privateObservation,p.missingPrivateRGBPixels==0,p.privateRGBSamples>0,
              p.moments.count==m.privateSamples,p.palettes.count<=16,
              p.palettes.allSatisfy({$0.rgb.count==3 && $0.rgb.allSatisfy{(0...255).contains($0)}}),
              let f=p.footprint,f.width>0,f.height>0,f.width<=Int.max/f.height,
              f.scaleX.isFinite,f.scaleY.isFinite,f.scaleX>0,f.scaleY>0,!f.cells.isEmpty,
              frameSize.width>0,frameSize.height>0,
              abs(CGFloat(f.width)*f.scaleX-CGFloat(frameSize.width))<=1e-6,
              abs(CGFloat(f.height)*f.scaleY-CGFloat(frameSize.height))<=1e-6 else {
            return .init(status:"unavailable-actual-private-observation-or-full-footprint",prepared:nil)
        }
        guard let window=sharedWindow ?? Window.make(sourceQuads:[inherited],frameSize:frameSize),
              window.frameSize==frameSize,window.sourceQuads.contains(where:{$0==inherited}) else {
            return .init(status:"unavailable-local-ROI-budget-or-inherited-query",prepared:nil)
        }
        return .init(status:"prepared-explicit-source-read",prepared:.init(m:m,observation:p,footprint:f,inherited:inherited,window:window))
    }
    /// Share THIS immutable RGB window across separately prepared root/child evidence.
    static func read(_ prepared: Prepared,frameProvider: () -> NativeOCRRGBAFrame?) -> SourceWindow? {
        let w=prepared.window
        guard let frame=frameProvider(),frame.width==w.frameSize.width,frame.height==w.frameSize.height else{return nil}
        var bytes=[UInt8]();bytes.reserveCapacity(w.width*w.height*4)
        for y in w.top..<(w.top+w.height) {
            let offset=y*frame.bytesPerRow+w.left*4
            bytes.append(contentsOf:frame.bytes[offset..<(offset+w.width*4)])
        }
        return .init(window:w,rgba:.init(bytes:bytes,width:w.width,height:w.height,bytesPerRow:w.width*4,origin:.init(x:w.left,y:w.top)))
    }
    /// EXPLICIT observation: old==new still reads and invokes GG includeMasks:true.
    /// Existing v3 adapter enclosure skip is intentionally not called here.
    static func observe(_ prepared: Prepared,source: SourceWindow) -> Result {
        let a=prepared.window,b=source.window
        guard a.frameSize==b.frameSize,a.left==b.left,a.top==b.top,a.width==b.width,a.height==b.height else {
            return .init(status:"unavailable-shared-window-mismatch",evidence:nil)
        }
        let f=prepared.actualFullFootprint
        let native=NativeOCRAlignedGradientTerminalGuard.assess(old:prepared.inherited,new:prepared.inherited,
            rgba:source.rgba,authenticatedPalettes:prepared.actualPalettes,frameOrigin:prepared.sourceOrigin,
            normal:prepared.normal,along:prepared.along,sourceWidth:prepared.sourceWidth,
            isPrivatePixel:{x,y in f.contains(.init(x:x,y:y))},includeMasks:true)
        guard native.decision=="no-qualified-terminal-loss-observed",native.witnesses.isEmpty,
              let mask=native.bodyMask,mask.count==a.width*a.height else {
            return .init(status:"unavailable-native-body-observation",evidence:nil)
        }
        let evidence=Evidence(prepared:prepared,source:source,sourceAuthenticatedContrastBodyMask:mask,
            nativeBodyCountAcrossPairs:native.authenticatedBodies,nativeExaminedPalettePairs:native.examinedPairs,
            uniqueMaskPixels:mask.filter{$0 != 0}.count)
        return .init(status:evidence.uniqueMaskPixels>0 ? "observed-source-contrast-body":"observed-empty-body-mask-abstain-producer",evidence:evidence)
    }
    static func make(_ m: NativeOCRSourceComponentMeasurements.Measurement,inherited: [CGPoint],
                     frameSize: FrameSize,enabled: Bool=false,sharedWindow: Window?=nil,
                     frameProvider: () -> NativeOCRRGBAFrame?) -> Result {
        let p=prepare(m,inherited:inherited,frameSize:frameSize,enabled:enabled,sharedWindow:sharedWindow)
        guard let prepared=p.prepared else{return .init(status:p.status,evidence:nil)}
        guard let source=read(prepared,frameProvider:frameProvider) else {
            return .init(status:"unavailable-original-source-frame",evidence:nil)
        }
        return observe(prepared,source:source)
    }
    private static func validQuad(_ q: [CGPoint]) -> Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        var area:CGFloat=0,turns:[CGFloat]=[]
        for i in 0..<4 {let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4];area+=a.x*b.y-b.x*a.y
            turns.append((b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x))}
        return abs(area)>1e-7 && (turns.allSatisfy{$0>0} || turns.allSatisfy{$0<0})
    }
}


import Foundation
import CoreGraphics

/// Exact source-continuation-support354 measure() port. Read-only role hypothesis.
/// No owner mutation, erasure rights, source identity, GT or candidate admission.
enum NativeOCRSourceComponentContinuation {
    struct Component {
        let ordinal: Int
        let colour: SIMD3<Int>
        let pixels: Int
        let ownedPixels: Int
        let foreignPixels: Int
        let insidePixels: Int
        let projectedBounds: CGRect
        let worldHull: [CGPoint] // Actual native hull, already clipped to approved local ROI.
    }
    struct Input {
        let actualComponentsAvailable: Bool
        let components: [Component]
        let sampleStep: CGFloat // Pass REAL m.step; do not derive/reconstruct in runtime adapter.
        let sourceWidth: CGFloat // Pass REAL m.rect.width.
        let inherited: [CGPoint]
    }
    struct Support {
        let componentOrdinal: Int
        let role: String
        let nativeOwnedPixels: Int
        let nativeForeignPixels: Int
        let clippedVisibleWorldHull: [CGPoint]
        let sourceColour: SIMD3<Int>
        let fill: Double
    }
    struct Result {
        let status: String
        let sampleStep: CGFloat?
        let inferredGlyphScale: CGFloat?
        let seedCount: Int
        let support: [Support]
        var supportPoints: [CGPoint] { support.flatMap(\.clippedVisibleWorldHull) }
        var componentOrdinals: [Int] { support.map(\.componentOrdinal) }
    }
    private struct Row {
        let c: Component
        let n0: CGFloat, n1: CGFloat, a0: CGFloat, a1: CGFloat
        let width: CGFloat, height: CGFloat
        let fill: Double
        let hull: [CGPoint]
    }
    static func measure(_ input: Input) -> Result {
        func unavailable(_ status: String) -> Result {
            .init(status: status, sampleStep: nil, inferredGlyphScale: nil, seedCount: 0, support: [])
        }
        guard input.actualComponentsAvailable else { return unavailable("unavailable-actual-components") }
        // Valid real m and audit descriptors satisfy these structural preconditions.
        // Invalid caller data abstains; no approximation/truncation of actual components.
        guard input.sampleStep > 0, input.sampleStep.isFinite, input.sourceWidth > 0,
              input.sourceWidth.isFinite, input.inherited.count == 4,
              input.inherited.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return unavailable("unavailable-invalid-native-input")
        }
        let step = input.sampleStep, width = input.sourceWidth
        var rows: [Row] = []
        for c in input.components {
            let n0 = c.projectedBounds.minX, n1 = c.projectedBounds.maxX
            let a0 = c.projectedBounds.minY, a1 = c.projectedBounds.maxY
            let w = n1 - n0, h = a1 - a0
            if w <= 0 || h <= 0 || c.foreignPixels != 0 || c.insidePixels < 2 { continue }
            let hull = clip(c.worldHull, to: input.inherited)
            if hull.count < 3 { continue }
            rows.append(.init(c: c, n0: n0, n1: n1, a0: a0, a1: a1, width: w, height: h,
                              fill: Double(c.pixels) * Double(step) * Double(step) / Double(w * h), hull: hull))
        }
        let seeds = rows.filter { $0.c.ownedPixels >= 4 }
        guard !seeds.isEmpty else { return unavailable("unavailable-private-component-seed") }
        let weightedInput: [(CGFloat, Int)] = seeds.map { (max($0.width, $0.height), $0.c.ownedPixels) }
        let weighted: [(CGFloat, Int)] = weightedInput.sorted {
            $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
        }
        let halfway = Double(weighted.reduce(0) { $0 + $1.1 }) / 2
        var total = 0, scale = width
        for (size, weight) in weighted {
            total += weight
            if Double(total) >= halfway { scale = size; break }
        }
        scale = max(2 * step, min(1.3 * width, max(0.2 * width, scale)))
        var reached = Set(seeds.map { $0.c.ordinal })
        var reasons = Dictionary(uniqueKeysWithValues: reached.map { ($0, "actual-private-component-seed") })
        var changed = true
        while changed {
            changed = false
            // Reference snapshots anchors once per pass; newly reached rows wait for next pass.
            let anchors = rows.filter { reached.contains($0.c.ordinal) }
            for row in rows {
                let ordinal = row.c.ordinal
                if reached.contains(ordinal) || row.fill < 0.15 { continue }
                if row.width > 1.7 * scale || row.height > 2.2 * scale { continue }
                for body in anchors {
                    let a = row.c.colour, b = body.c.colour
                    if max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) > 40 { continue }
                    let overlap = max(0, min(row.n1, body.n1) - max(row.n0, body.n0))
                    // Bounds centers, deliberately NOT native component.center.
                    let center = abs((row.n0 + row.n1 - body.n0 - body.n1) / 2)
                    let gap = max(0, row.a0 - body.a1, body.a0 - row.a1)
                    if overlap < 0.4 * min(row.width, body.width) || center > 0.35 * scale { continue }
                    let fullGlyph = row.height >= 0.3 * scale &&
                        min(row.width, row.height) >= max(2 * step, 0.1 * scale) && gap <= scale
                    let alongOverlap = max(0, min(row.a1, body.a1) - max(row.a0, body.a0))
                    let closePart = max(row.width, row.height) >= 0.3 * scale && gap <= 0.15 * scale &&
                        alongOverlap <= 0.5 * min(row.height, body.height)
                    if fullGlyph || closePart {
                        reached.insert(ordinal)
                        reasons[ordinal] = fullGlyph ? "aligned-glyph-continuation" : "close-body-fragment"
                        changed = true; break
                    }
                }
            }
        }
        let support = rows.filter { reached.contains($0.c.ordinal) }.map { row in
            Support(componentOrdinal: row.c.ordinal, role: reasons[row.c.ordinal]!,
                    nativeOwnedPixels: row.c.ownedPixels, nativeForeignPixels: row.c.foreignPixels,
                    clippedVisibleWorldHull: row.hull, sourceColour: row.c.colour, fill: row.fill)
        }
        return .init(status: "source-role-hypothesis-not-admission", sampleStep: step,
                     inferredGlyphScale: scale, seedCount: seeds.count, support: support)
    }
    private static func clip(_ points: [CGPoint], to old: [CGPoint]) -> [CGPoint] {
        let area = (0..<4).reduce(CGFloat(0)) { sum, i in
            sum + old[i].x * old[(i + 1) % 4].y - old[(i + 1) % 4].x * old[i].y
        }
        let sign: CGFloat = area >= 0 ? 1 : -1
        var output = points
        for i in 0..<4 {
            let a = old[i], b = old[(i + 1) % 4]
            func distance(_ p: CGPoint) -> CGFloat {
                sign * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x))
            }
            let source = output; output = []
            guard var previous = source.last else { break }
            var pd = distance(previous)
            for current in source {
                let cd = distance(current)
                if (cd >= 0) != (pd >= 0) {
                    let t = pd / (pd - cd)
                    output.append(.init(x: previous.x + t * (current.x - previous.x),
                                        y: previous.y + t * (current.y - previous.y)))
                }
                if cd >= 0 { output.append(current) }
                previous = current; pd = cd
            }
        }
        return output
    }
}


import Foundation
import CoreGraphics

/// Geometry only. The caller authenticates evidence and supplies ALL root/child private
/// support, actual caps, and qualified continuation/outline points. A body mask is
/// evidence over executed native palette pairs, never ownership or complete-glyph truth.
/// No graph, selection, admission, source identity, model or GT access lives here.
enum NativeOCRSourceBodyEnvelope {
    struct SourceFrame {
        let origin: CGPoint
        let normal: CGPoint
        let along: CGPoint
        let width: Double
    }
    struct BodyMask {
        let bytes: [UInt8] // Tight row-major native mask: exactly 0 or 255.
        let width: Int
        let height: Int
        let origin: CGPoint
        let authenticated: Bool
        let completeOverExecutedNativePairs: Bool
    }
    struct GeometryOffer {
        let key: String
        let paddingFraction: Double
        let polygon: [CGPoint]
        let bodyMaskPixelCount: Int
    }
    struct Abstention {
        let paddingFraction: Double
        let reason: String
    }
    struct Output {
        let offers: [GeometryOffer]
        let abstentions: [Abstention]
    }
    static let fixedPaddingFractions: [Double] = [0, 0.05, 0.1]

    static func geometryOffers(sourceFrame f: SourceFrame, sourceImageSize: CGSize,
        observedLocalROI: CGRect, oldCurrentPrior: [CGPoint],
        mandatoryWorldPoints: [CGPoint]?, authenticatedBodyMask: BodyMask?) -> Output {
        func abstainAll(_ reason: String) -> Output {
            Output(offers: [], abstentions: fixedPaddingFractions.map {
                Abstention(paddingFraction: $0, reason: reason)
            })
        }
        guard let mandatory = mandatoryWorldPoints, mandatory.count >= 3,
              let mask = authenticatedBodyMask,
              mask.authenticated, mask.completeOverExecutedNativePairs else {
            return abstainAll("missing_or_incomplete_authenticated_evidence")
        }
        func finite(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }
        guard finite(f.origin), finite(f.normal), finite(f.along),
              f.width.isFinite, f.width > 0,
              oldCurrentPrior.count == 4, oldCurrentPrior.allSatisfy(finite),
              mandatory.allSatisfy(finite),
              abs(hypot(Double(f.normal.x), Double(f.normal.y)) - 1) < 1e-7,
              abs(hypot(Double(f.along.x), Double(f.along.y)) - 1) < 1e-7,
              abs(Double(f.normal.x * f.along.x + f.normal.y * f.along.y)) < 1e-7 else {
            return abstainAll("invalid_incoming_frame_or_mandatory_support")
        }
        guard sourceImageSize.width.isFinite, sourceImageSize.height.isFinite,
              sourceImageSize.width > 0, sourceImageSize.height > 0,
              finite(observedLocalROI.origin),
              observedLocalROI.width.isFinite, observedLocalROI.height.isFinite,
              observedLocalROI.width > 0, observedLocalROI.height > 0,
              mask.width > 0, mask.height > 0, mask.width <= Int.max / mask.height,
              mask.bytes.count == mask.width * mask.height,
              mask.origin == observedLocalROI.origin,
              Double(mask.width) == Double(observedLocalROI.width),
              Double(mask.height) == Double(observedLocalROI.height),
              mask.bytes.allSatisfy({ $0 == 0 || $0 == 255 }) else {
            return abstainAll("invalid_source_ROI_or_native_body_mask")
        }
        var n0 = Double.infinity, n1 = -Double.infinity
        var a0 = Double.infinity, a1 = -Double.infinity
        func include(_ p: CGPoint) {
            let x = Double(p.x - f.origin.x), y = Double(p.y - f.origin.y)
            let n = x * Double(f.normal.x) + y * Double(f.normal.y)
            let a = x * Double(f.along.x) + y * Double(f.along.y)
            n0 = min(n0, n); n1 = max(n1, n)
            a0 = min(a0, a); a1 = max(a1, a)
        }
        mandatory.forEach(include)
        var bodyPixelCount = 0
        // Run endpoints enclose every full pixel CELL, not only pixel centres.
        for y in 0..<mask.height {
            var x = 0
            while x < mask.width {
                if mask.bytes[y * mask.width + x] == 0 { x += 1; continue }
                let start = x
                while x < mask.width && mask.bytes[y * mask.width + x] == 255 { x += 1 }
                bodyPixelCount += x - start
                let left = Double(mask.origin.x) + Double(start)
                let right = Double(mask.origin.x) + Double(x)
                let top = Double(mask.origin.y) + Double(y)
                include(CGPoint(x: left, y: top)); include(CGPoint(x: right, y: top))
                include(CGPoint(x: right, y: top + 1)); include(CGPoint(x: left, y: top + 1))
            }
        }
        guard bodyPixelCount > 0, [n0, n1, a0, a1].allSatisfy({ $0.isFinite }),
              n1 > n0, a1 > a0 else { return abstainAll("empty_or_degenerate_source_body") }
        func restore(_ n: Double, _ a: Double) -> CGPoint {
            CGPoint(x: Double(f.origin.x) + n * Double(f.normal.x) + a * Double(f.along.x),
                    y: Double(f.origin.y) + n * Double(f.normal.y) + a * Double(f.along.y))
        }
        var offers: [GeometryOffer] = [], abstentions: [Abstention] = []
        for (index, pad) in fixedPaddingFractions.enumerated() {
            let d = pad * f.width
            let q = [restore(n0 - d, a0 - d), restore(n1 + d, a0 - d),
                     restore(n1 + d, a1 + d), restore(n0 - d, a1 + d)]
            guard q.allSatisfy({ finite($0) && $0.x >= -1e-8 && $0.y >= -1e-8 &&
                $0.x <= sourceImageSize.width + 1e-8 && $0.y <= sourceImageSize.height + 1e-8 }) else {
                abstentions.append(Abstention(paddingFraction: pad, reason: "candidate_outside_source_image_abstain_not_clip")); continue
            }
            guard q.allSatisfy({ $0.x >= observedLocalROI.minX - 1e-8 &&
                $0.y >= observedLocalROI.minY - 1e-8 &&
                $0.x <= observedLocalROI.maxX + 1e-8 && $0.y <= observedLocalROI.maxY + 1e-8 }) else {
                abstentions.append(Abstention(paddingFraction: pad, reason: "candidate_beyond_authenticated_RGB_crop")); continue
            }
            offers.append(GeometryOffer(key: "private-core-auth-body-v1-incoming-pad" + ["0", "05", "10"][index],
                paddingFraction: pad, polygon: q, bodyMaskPixelCount: bodyPixelCount))
        }
        return Output(offers: offers, abstentions: abstentions)
    }

    /// Geometry containment predicate for mandatory-support veto fixtures/callers.
    /// This predicate is not admission or an assertion that support is complete.
    static func containsMandatory(_ polygon: [CGPoint], points: [CGPoint]) -> Bool {
        guard polygon.count == 4, !points.isEmpty,
              (polygon + points).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let scale = (polygon + points).reduce(1.0) { max($0, max(abs(Double($1.x)), abs(Double($1.y)))) }
        let tolerance = 64 * Double.ulpOfOne * scale
        var positive = true, negative = true
        for i in 0..<4 {
            let o = polygon[i], e = polygon[(i + 1) % 4]
            let dx = Double(e.x - o.x), dy = Double(e.y - o.y), length = hypot(dx, dy)
            guard length.isFinite, length > 0 else { return false }
            for p in points {
                let distance = (dx * Double(p.y - o.y) - dy * Double(p.x - o.x)) / length
                positive = positive && distance >= -tolerance
                negative = negative && distance <= tolerance
            }
        }
        return positive || negative
    }
}


import Foundation
import CoreGraphics

/// Pure resolver/selection plumbing. The caller supplies the immutable OLD-menu snapshot.
/// Exact351 selector must be captured before adding source-body candidates; never bind to
/// preferredWithSourceBodies or to a future dispatcher that calls this resolver again.
@available(iOS 18.0, *)
enum NativeOCRCurrentPrior351 {
    enum Origin: String { case preferred351, bankEncoded351, incoming }
    struct Resolution {
        let candidate: NativeOCRResidualCandidate?
        let polygon: [CGPoint]
        let consumedIndices: [Int]
        let inheritedAssociationKey: String?
        let origin: Origin
    }
    static func resolve(oldCandidates: [NativeOCRResidualCandidate], features: [Double],
        incoming: [CGPoint],
        oldPreferred351: ([NativeOCRResidualCandidate], [Double], [CGPoint]) -> NativeOCRResidualCandidate?,
        encoded351: ([Double]) -> String?) -> Resolution {
        let preferred = oldPreferred351(oldCandidates, features, incoming)
        return resolveAfterOldPreferred(preferred, oldCandidates: oldCandidates,
            features: features, incoming: incoming, encoded351: encoded351)
    }
    static func resolveAfterOldPreferred(_ preferred: NativeOCRResidualCandidate?,
        oldCandidates: [NativeOCRResidualCandidate], features: [Double], incoming: [CGPoint],
        encoded351: ([Double]) -> String?) -> Resolution {
        if let preferred { return resolution(preferred, origin: .preferred351) }
        if let encoded = encoded351(features) {
            let ranked = encoded.components(separatedBy: " >> ")
            if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                for key in ranked {
                    // Native Bank uses first matching candidate; do not skip to duplicate key2.
                    guard let candidate = oldCandidates.first(where: { $0.key == key }) else { continue }
                    if ranked.count > 1 {
                        guard candidate.consumedIndices.isEmpty else { continue }
                        if sameQuadBank351(candidate.polygon, incoming) { continue }
                    }
                    // Single-key fallbacks intentionally may consume peers or be no-op.
                    return resolution(candidate, origin: .bankEncoded351)
                }
            }
        }
        return .init(candidate: nil, polygon: incoming, consumedIndices: [],
                     inheritedAssociationKey: nil, origin: .incoming)
    }
    private static func resolution(_ candidate: NativeOCRResidualCandidate, origin: Origin) -> Resolution {
        .init(candidate: candidate, polygon: candidate.polygon, consumedIndices: candidate.consumedIndices,
              inheritedAssociationKey: candidate.associationKey ?? candidate.key, origin: origin)
    }
    static func sameQuadBank351(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        guard a.count == 4, b.count == 4 else { return false }
        for reversed in [false, true] {
            let q = reversed ? Array(a.reversed()) : a
            for shift in 0..<4 {
                if (0..<4).allSatisfy({ i in
                    hypot(q[(i + shift) % 4].x - b[i].x, q[(i + shift) % 4].y - b[i].y) <= 1e-8
                }) { return true }
            }
        }
        return false
    }
    /// API plumbing only: defaultOFF and rejected-body return OLD optional exactly.
    /// Caller Bank then retains its original encoded fallback/coordinator unchanged.
    static func preferredWithSourceBodies(oldCandidates: [NativeOCRResidualCandidate],
        features: [Double], incoming: [CGPoint], enabled: Bool,
        oldPreferred351: ([NativeOCRResidualCandidate], [Double], [CGPoint]) -> NativeOCRResidualCandidate?,
        encoded351: ([Double]) -> String?,
        selectBody: (Resolution) -> NativeOCRResidualCandidate?,
        validateBody: (NativeOCRResidualCandidate, Resolution) -> Bool) -> NativeOCRResidualCandidate? {
        let oldPreferred = oldPreferred351(oldCandidates, features, incoming)
        guard enabled else { return oldPreferred }
        let prior = resolveAfterOldPreferred(oldPreferred, oldCandidates: oldCandidates,
            features: features, incoming: incoming, encoded351: encoded351)
        guard let body = selectBody(prior),
              body.consumedIndices == prior.consumedIndices,
              body.associationKey == prior.inheritedAssociationKey,
              validateBody(body, prior) else { return oldPreferred }
        return body
    }
}


import Foundation
import CoreGraphics

/// Consumes AUTHENTIC role-separated evidence; does not measure/create ownership or
/// decide legacy visibleForeground may be removed. Unknown != empty. Caller must use
/// Bank.measurements (including existing Context overrides), not recreate base Context.
@available(iOS 18.0, *)
enum NativeOCRSourceBodySupportContract {
    struct SourceEvidence {
        let index: Int
        let actualMeasurementAvailable: Bool
        let qualifiedObservationComplete: Bool
        let guardPoints: [CGPoint]?
        let actualCaps: [CGPoint]?
        let originalOwnedSupport: [CGPoint]?
        let qualifiedBodyFootprint: [CGPoint]?
    }
    struct Bundle {
        let residualChildren: [Int]
        let associationKey: String?
        let sourceIndices: [Int]
        let mandatoryWorldPoints: [CGPoint]
    }
    static func gather(parentIndex: Int, prior: NativeOCRCurrentPrior351.Resolution,
        evidence: (Int) -> SourceEvidence?) -> Bundle? {
        let children = prior.consumedIndices
        guard !children.contains(parentIndex), Set(children).count == children.count else { return nil }
        var points = prior.candidate?.supportPoints ?? []
        let indices = [parentIndex] + children
        for index in indices {
            guard let e = evidence(index), e.index == index, e.actualMeasurementAvailable,
                  e.qualifiedObservationComplete, let guards = e.guardPoints,
                  let caps = e.actualCaps, let owned = e.originalOwnedSupport,
                  let body = e.qualifiedBodyFootprint else { return nil }
            // Explicit arrays may be empty if authentically measured empty; unavailable
            // arrays must be nil. Aggregate still needs genuine support, not made-up zero.
            points += guards + caps + owned + body
        }
        guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return .init(residualChildren: children, associationKey: prior.inheritedAssociationKey,
                     sourceIndices: indices, mandatoryWorldPoints: points)
    }
    static func preserves(_ candidate: NativeOCRResidualCandidate, bundle: Bundle,
        containsMandatoryPoint: ([CGPoint], CGPoint) -> Bool) -> Bool {
        guard candidate.consumedIndices == bundle.residualChildren,
              candidate.associationKey == bundle.associationKey,
              candidate.polygon.count == 4,
              candidate.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        return bundle.mandatoryWorldPoints.allSatisfy { containsMandatoryPoint(candidate.polygon, $0) }
    }
}


import Foundation
import CoreGraphics

// Isolated integration proposal ONLY; does not replace or rename old351 H methods.
// Bank must snapshot old351Candidates after ALL old producers and BEFORE body generation.
@available(iOS 18.0, *)
extension NativeOCRCurrentPrior351 {
    static func resolveFromOld351API(oldCandidates: [NativeOCRResidualCandidate],
        features: [Double], incoming: [CGPoint], rfScopes: [NativeOCRResidualRFTextFeatures.Scope],
        geometryFeatures: [String: [Double]]) -> Resolution {
        resolve(oldCandidates: oldCandidates, features: features, incoming: incoming,
            oldPreferred351: { candidates, values, originalIncoming in
                NativeOCRResidualPrioritySelection.preferredWithGeometry(candidates,
                    features: values, incoming: originalIncoming, rfScopes: rfScopes,
                    geometryFeatures: geometryFeatures)
            }, encoded351: NativeOCRResidualCandidateBank.selectedKey)
    }
}
@available(iOS 18.0, *)
extension NativeOCRResidualPrioritySelection {
    static func preferredWithSourceBodies(_ admittedCandidates: [NativeOCRResidualCandidate],
        old351Candidates: [NativeOCRResidualCandidate], features: [Double], incoming: [CGPoint],
        rfScopes: [NativeOCRResidualRFTextFeatures.Scope], geometryFeatures: [String: [Double]],
        bodySelectionEnabled: Bool = false,
        preferredBodyKey: (NativeOCRCurrentPrior351.Resolution) -> String? = { _ in nil },
        validateBody: (NativeOCRResidualCandidate, NativeOCRCurrentPrior351.Resolution) -> Bool = { _, _ in false }) -> NativeOCRResidualCandidate? {
        NativeOCRCurrentPrior351.preferredWithSourceBodies(oldCandidates: old351Candidates,
            features: features, incoming: incoming, enabled: bodySelectionEnabled,
            oldPreferred351: { candidates, values, originalIncoming in
                // This must remain the OLD351 API, NEVER preferredWithSourceBodies.
                preferredWithGeometry(candidates, features: values, incoming: originalIncoming,
                    rfScopes: rfScopes, geometryFeatures: geometryFeatures)
            }, encoded351: NativeOCRResidualCandidateBank.selectedKey,
            selectBody: { prior in
                guard let key = preferredBodyKey(prior) else { return nil }
                return admittedCandidates.first { $0.key == key }
            }, validateBody: validateBody)
    }
}


/// Export-only native source-body family. RGB evidence is not ownership or admission.
/// All residual children retain their actual measurement context and original caps.
@available(iOS 18.0, *)
enum NativeOCRSourceBodyCandidate357 {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    typealias Body = NativeOCRSourceAuthenticatedBodyEvidence
    struct Output {
        let candidates: [NativeOCRResidualCandidate]
        let records: [[String: Any]]
    }
    static func generate(parent: Measurement, prior: NativeOCRCurrentPrior351.Resolution,
        measurements: [Int: Measurement], frameSize: Body.FrameSize,
        capsForSource: (Measurement) -> [CGPoint]?, originalOwnedSupport: (Int) -> [CGPoint],
        frameProvider: () -> NativeOCRRGBAFrame?, accepts: (Int, [CGPoint]) -> Bool) -> Output {
        func unavailable(_ reason: String) -> Output {
            .init(candidates: [], records: [["key": "source-body-cc-v3-observation",
                "accepted": false, "rejection": reason]])
        }
        let indices = [parent.index] + prior.consumedIndices
        guard Set(indices).count == indices.count, indices.count <= 64 else {
            return unavailable("invalid-prior-source-graph")
        }
        var sources: [Measurement] = [], inherited: [[CGPoint]] = []
        for index in indices {
            guard let m = measurements[index], m.status == "measured" else {
                return unavailable("missing-actual-root-or-child-measurement")
            }
            sources.append(m)
            inherited.append(index == parent.index ? prior.polygon : m.polygon)
        }
        guard let window = Body.Window.make(sourceQuads: inherited, frameSize: frameSize) else {
            return unavailable("source-local-RGB-window-unavailable")
        }
        var prepared: [Body.Prepared] = []
        for (m, old) in zip(sources, inherited) {
            guard let p = Body.prepare(m, inherited: old, frameSize: frameSize,
                enabled: true, sharedWindow: window).prepared else {
                return unavailable("source-private-evidence-unavailable")
            }
            prepared.append(p)
        }
        guard let first = prepared.first, let pixels = Body.read(first, frameProvider: frameProvider) else {
            return unavailable("original-source-RGB-unavailable")
        }
        var evidence: [Body.Evidence] = [], roles: [Int: NativeOCRSourceBodySupportContract.SourceEvidence] = [:]
        for i in sources.indices {
            let m = sources[i]
            guard let body = Body.observe(prepared[i], source: pixels).evidence,
                  body.uniqueMaskPixels > 0, let caps = capsForSource(m), m.privateHull.count >= 3 else {
                return unavailable("missing-authenticated-body-or-caps")
            }
            let components = m.components.enumerated().map { ordinal, c in
                NativeOCRSourceComponentContinuation.Component(ordinal: ordinal, colour: c.colour,
                    pixels: c.pixels, ownedPixels: c.ownedPixels, foreignPixels: c.foreignPixels,
                    insidePixels: c.insidePixels, projectedBounds: c.bounds, worldHull: c.hull.map(m.restore))
            }
            let continuation = NativeOCRSourceComponentContinuation.measure(.init(
                actualComponentsAvailable: m.status == "measured", components: components,
                sampleStep: m.step, sourceWidth: m.rect.width, inherited: inherited[i]))
            guard continuation.seedCount > 0 else { return unavailable("missing-qualified-component-seed") }
            roles[m.index] = .init(index: m.index, actualMeasurementAvailable: true,
                qualifiedObservationComplete: true, guardPoints: m.guardPoints, actualCaps: caps,
                originalOwnedSupport: originalOwnedSupport(m.index),
                qualifiedBodyFootprint: m.privateHull.map(m.restore) + continuation.supportPoints)
            evidence.append(body)
        }
        guard let bundle = NativeOCRSourceBodySupportContract.gather(parentIndex: parent.index,
            prior: prior, evidence: { roles[$0] }) else { return unavailable("incomplete-root-child-support-bundle") }
        let rgba = evidence[0].sourceLocalRGBA
        var union = [UInt8](repeating: 0, count: rgba.width * rgba.height)
        for body in evidence {
            guard body.sourceAuthenticatedContrastBodyMask.count == union.count else {
                return unavailable("inconsistent-shared-mask-window")
            }
            for i in union.indices where body.sourceAuthenticatedContrastBodyMask[i] != 0 { union[i] = 255 }
        }
        let mask = NativeOCRSourceBodyEnvelope.BodyMask(bytes: union, width: rgba.width, height: rgba.height,
            origin: rgba.origin, authenticated: true, completeOverExecutedNativePairs: true)
        let roi = CGRect(x: rgba.origin.x, y: rgba.origin.y, width: CGFloat(rgba.width), height: CGFloat(rgba.height))
        var frames: [(String, NativeOCRSourceBodyEnvelope.SourceFrame)] = [
            ("incoming", .init(origin: parent.origin, normal: parent.normal, along: parent.along, width: parent.rect.width))]
        if prior.polygon.count == 4 {
            let q = prior.polygon
            let e1 = CGPoint(x: q[1].x - q[0].x, y: q[1].y - q[0].y)
            let e2 = CGPoint(x: q[3].x - q[0].x, y: q[3].y - q[0].y)
            let edge = hypot(e1.x, e1.y) >= hypot(e2.x, e2.y) ? e1 : e2
            let length = hypot(edge.x, edge.y)
            if length > 0 {
                let a = CGPoint(x: edge.x / length, y: edge.y / length)
                let origin = CGPoint(x: q.reduce(0) { $0 + $1.x } / 4, y: q.reduce(0) { $0 + $1.y } / 4)
                frames.append(("current-prior", .init(origin: origin,
                    normal: .init(x: a.y, y: -a.x), along: a, width: parent.rect.width)))
            }
        }
        var candidates: [NativeOCRResidualCandidate] = [], records: [[String: Any]] = []
        for (mode, frame) in frames {
            let offers = NativeOCRSourceBodyEnvelope.geometryOffers(sourceFrame: frame,
                sourceImageSize: .init(width: frameSize.width, height: frameSize.height), observedLocalROI: roi,
                oldCurrentPrior: prior.polygon, mandatoryWorldPoints: bundle.mandatoryWorldPoints,
                authenticatedBodyMask: mask)
            for offer in offers.offers {
                let suffix = offer.paddingFraction == 0 ? "0" : offer.paddingFraction == 0.05 ? "05" : "10"
                let q = correspondence(offer.polygon, to: prior.polygon)
                let candidate = NativeOCRResidualCandidate(key: "source-body-cc-v3-" + mode + "-pad" + suffix,
                    polygon: q, consumedIndices: bundle.residualChildren,
                    supportPoints: bundle.mandatoryWorldPoints, associationKey: bundle.associationKey)
                var reason: String?
                if !NativeOCRSourceBodySupportContract.preserves(candidate, bundle: bundle,
                    containsMandatoryPoint: { polygon, point in
                        NativeOCRSourceBodyEnvelope.containsMandatory(polygon, points: [point])
                    }) { reason = "root-child-support-or-graph" }
                if reason == nil && !sources.allSatisfy({ accepts($0.index, q) }) { reason = "root-child-semantic-admission" }
                var terminalDecisions: [String] = []
                if reason == nil {
                    for body in evidence {
                        guard let terminal = body.terminalObservation(proposed: q) else {
                            reason = "missing-actual-terminal-observation"; break
                        }
                        terminalDecisions.append(terminal.decision)
                        if terminal.decision != "no-qualified-terminal-loss-observed" || !terminal.witnesses.isEmpty {
                            reason = "actual-source-terminal-loss"; break
                        }
                        // No-veto with no authenticated body is uncertainty, not proof
                        // that contraction preserves the member's original glyphs.
                        let enclosesIngress = NativeOCRSourceBodyEnvelope.containsMandatory(
                            q, points: body.prepared.inherited)
                        if !enclosesIngress && (terminal.examinedPairs == 0 || terminal.authenticatedBodies == 0) {
                            reason = "uncertain-source-terminal-body-evidence"; break
                        }
                        // A consumed member may have recovered real terminals in the
                        // current merged prior beyond its own ingress rectangle. Use
                        // THAT prior too, with THIS member's actual palette/footprint.
                        if !NativeOCRCurrentPrior351.sameQuadBank351(body.prepared.inherited, prior.polygon) {
                            let mergedTerminal = NativeOCRAlignedGradientTerminalGuard.assess(
                                old: prior.polygon, new: q, rgba: body.sourceLocalRGBA,
                                authenticatedPalettes: body.actualPalettes,
                                frameOrigin: body.prepared.sourceOrigin,
                                normal: body.prepared.normal, along: body.prepared.along,
                                sourceWidth: body.prepared.sourceWidth,
                                isPrivatePixel: { x, y in body.isPrivatePixel(x, y) })
                            terminalDecisions.append(mergedTerminal.decision)
                            if mergedTerminal.decision != "no-qualified-terminal-loss-observed" ||
                                !mergedTerminal.witnesses.isEmpty {
                                reason = "actual-merged-prior-member-terminal-loss"; break
                            }
                            let enclosesPrior = NativeOCRSourceBodyEnvelope.containsMandatory(q, points: prior.polygon)
                            if !enclosesPrior && (mergedTerminal.examinedPairs == 0 || mergedTerminal.authenticatedBodies == 0) {
                                reason = "uncertain-merged-prior-terminal-body-evidence"; break
                            }
                        }
                    }
                }
                let polygonJSON = q.map { ["x": Double($0.x), "y": Double($0.y)] }
                let inheritedJSON = prior.polygon.map { ["x": Double($0.x), "y": Double($0.y)] }
                let record: [String: Any] = ["key": candidate.key,
                    "polygon": polygonJSON,
                    "consumedIndices": candidate.consumedIndices, "accepted": reason == nil,
                    "rejection": reason as Any? ?? NSNull(),
                    "inheritedPriorKey": prior.candidate?.key as Any? ?? NSNull(),
                    "inheritedAssociationKey": bundle.associationKey as Any? ?? NSNull(),
                    "inheritedPriorPolygon": inheritedJSON,
                    "actualSourceCount": sources.count, "mandatorySupportPoints": bundle.mandatoryWorldPoints.count,
                    "bodyMaskPixelCount": offer.bodyMaskPixelCount, "terminalDecisions": terminalDecisions]
                records.append(record)
                if reason == nil { candidates.append(candidate) }
            }
        }
        return .init(candidates: candidates, records: records)
    }
    /// Preserve OCR corner correspondence without horizontal/vertical special cases.
    private static func correspondence(_ polygon: [CGPoint], to prior: [CGPoint]) -> [CGPoint] {
        guard polygon.count == 4, prior.count == 4 else { return polygon }
        var best = polygon, score = CGFloat.infinity
        for reversed in [false, true] {
            let p = reversed ? Array(polygon.reversed()) : polygon
            for shift in 0..<4 {
                let q = (0..<4).map { p[($0 + shift) % 4] }
                let distance = (0..<4).reduce(CGFloat(0)) { sum, i in
                    let dx = q[i].x - prior[i].x, dy = q[i].y - prior[i].y
                    return sum + dx * dx + dy * dy
                }
                if distance < score { score = distance; best = q }
            }
        }
        return best
    }
}

/// Source-private normal bounds, with the CURRENT prior's complete along span retained.
/// Raw contrast-body unions and all same-palette CC hulls are NOT ownership truth.
/// Private points/caps/old explicit support remain mandatory; three actual RGB vetoes
/// and every source's semantic gate are evaluated separately before menu admission.
@available(iOS 18.0, *)
enum NativeOCRSourceNormalSupport363 {
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    typealias Body = NativeOCRSourceAuthenticatedBodyEvidence
    struct Output {
        let candidates: [NativeOCRResidualCandidate]
        let records: [[String: Any]]
    }
    private struct Frame {
        let origin: CGPoint
        let normal: CGPoint
        let along: CGPoint
        func project(_ p: CGPoint) -> CGPoint {
            let x = p.x - origin.x, y = p.y - origin.y
            return .init(x: x * normal.x + y * normal.y, y: x * along.x + y * along.y)
        }
        func restore(_ n: CGFloat, _ a: CGFloat) -> CGPoint {
            .init(x: origin.x + n * normal.x + a * along.x, y: origin.y + n * normal.y + a * along.y)
        }
    }
    static func generate(parent: M, prior: NativeOCRCurrentPrior351.Resolution,
        measurements: [Int: M], frameSize: Body.FrameSize,
        capsForSource: (M) -> [CGPoint]?, originalOwnedSupport: (Int) -> [CGPoint],
        allowsGeometry: ((NativeOCRResidualCandidate) -> Bool)? = nil,
        frameProvider: () -> NativeOCRRGBAFrame?, accepts: (Int, [CGPoint]) -> Bool) -> Output {
        func unavailable(_ reason: String) -> Output {
            .init(candidates: [], records: [["key": "source-normal-private-v1-observation",
                "accepted": false, "rejection": reason]])
        }
        let indices = [parent.index] + prior.consumedIndices
        guard prior.polygon.count == 4, Set(indices).count == indices.count, indices.count <= 64,
              parent.rect.width.isFinite, parent.rect.width > 0 else { return unavailable("invalid-prior-source-graph") }
        var sources: [M] = [], mandatory = prior.candidate?.supportPoints ?? []
        var privateCount = 0, guardCount = 0, capsCount = 0, originalCount = 0
        for index in indices {
            guard let m = measurements[index], m.status == "measured", m.privateHull.count >= 3,
                  let caps = capsForSource(m) else { return unavailable("missing-actual-private-source-or-caps") }
            let owned = originalOwnedSupport(index), points = m.privateHull.map(m.restore)
            mandatory += m.guardPoints + caps + owned + points
            privateCount += points.count; guardCount += m.guardPoints.count
            capsCount += caps.count; originalCount += owned.count
            sources.append(m)
        }
        guard !mandatory.isEmpty, (mandatory + prior.polygon).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return unavailable("invalid-mandatory-or-prior-points")
        }
        let old = prior.polygon
        let e1 = CGPoint(x: old[1].x - old[0].x, y: old[1].y - old[0].y)
        let e2 = CGPoint(x: old[3].x - old[0].x, y: old[3].y - old[0].y)
        let edge = hypot(e1.x, e1.y) >= hypot(e2.x, e2.y) ? e1 : e2, length = hypot(edge.x, edge.y)
        guard length > 0, length.isFinite else { return unavailable("degenerate-current-prior") }
        let along = CGPoint(x: edge.x / length, y: edge.y / length)
        let origin = CGPoint(x: old.reduce(0) { $0 + $1.x } / 4, y: old.reduce(0) { $0 + $1.y } / 4)
        let f = Frame(origin: origin, normal: .init(x: along.y, y: -along.x), along: along)
        let projected = mandatory.map(f.project), oldProjected = old.map(f.project)
        let n0 = projected.map(\.x).min()!, n1 = projected.map(\.x).max()!
        let a0 = min(projected.map(\.y).min()!, oldProjected.map(\.y).min()!)
        let a1 = max(projected.map(\.y).max()!, oldProjected.map(\.y).max()!)
        guard n1 > n0, a1 > a0 else { return unavailable("degenerate-private-normal-envelope") }
        let paddings: [(String, CGFloat)] = [("000", 0), ("025", 0.025), ("050", 0.05), ("075", 0.075),
            ("100", 0.1), ("150", 0.15), ("200", 0.2), ("300", 0.3)]
        var offers: [(String, [CGPoint])] = [], records: [[String: Any]] = []
        for (suffix, fraction) in paddings {
            let key = "source-normal-private-v1-current-pad" + suffix, d = fraction * parent.rect.width
            let q = align([f.restore(n0 - d, a0), f.restore(n1 + d, a0),
                           f.restore(n1 + d, a1), f.restore(n0 - d, a1)], to: old)
            guard q.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                $0.x <= CGFloat(frameSize.width) && $0.y <= CGFloat(frameSize.height) }) else {
                records.append(["key": key, "accepted": false, "rejection": "candidate-outside-source-frame"])
                continue
            }
            offers.append((key, q))
        }
        // Policy predicates read only source22 and these actual quads/support points.
        // A geometry preflight grants NO admission. Keep the FULL eight-offer window
        // below so filtering never changes RGB, CC closure or palette observations.
        let queryOffers = offers.filter { key, q in
            guard let allowsGeometry else { return true }
            return allowsGeometry(.init(key: key, polygon: q, consumedIndices: prior.consumedIndices,
                supportPoints: mandatory, associationKey: prior.inheritedAssociationKey))
        }
        guard !queryOffers.isEmpty else { return unavailable("policy-geometry-abstain-no-source-read") }
        guard !offers.isEmpty, let window = Body.Window.make(sourceQuads: [old] + offers.map(\.1), frameSize: frameSize) else {
            return unavailable("source-local-union-RGB-window-unavailable")
        }
        var preparations: [Body.Prepared] = []
        for m in sources {
            // ALL members compare against the actual merged prior, with OWN native
            // palette, footprint, sourceWidth and basis. No ingress-only child check.
            guard let p = Body.prepare(m, inherited: old, frameSize: frameSize,
                enabled: true, sharedWindow: window).prepared else {
                return unavailable("unavailable-actual-private-RGB-footprint")
            }
            preparations.append(p)
        }
        guard let first = preparations.first, let pixels = Body.read(first, frameProvider: frameProvider) else {
            return unavailable("unavailable-original-source-RGB")
        }
        let rgba = pixels.rgba
        let denseRGBA = NativeOCRDensePrivateFootprintGuard.RGBA(bytes: rgba.bytes,
            width: rgba.width, height: rgba.height, stride: rgba.bytesPerRow, origin: rgba.origin)
        var candidates: [NativeOCRResidualCandidate] = []
        for (key, q) in queryOffers {
            var reason: String?, pixelChecks: [[String: Any]] = []
            if !NativeOCRSourceBodyEnvelope.containsMandatory(q, points: mandatory) { reason = "mandatory-private-source-support" }
            if reason == nil && !sources.allSatisfy({ accepts($0.index, q) }) { reason = "root-child-semantic-admission" }
            if reason == nil {
                for i in sources.indices {
                    let m = sources[i], p = preparations[i]
                    guard let observation = m.privateObservation else { reason = "missing-actual-private-observation"; break }
                    let normal = old.map { m.project($0).x }
                    let whole = NativeOCRResidualTurningStrokeGuardHistogram.assess(old: old, new: q,
                        rgba: rgba, authenticatedPalettes: p.actualPalettes,
                        privateRGBSampleCount: observation.privateRGBSamples,
                        frameOrigin: m.origin, normal: m.normal, along: m.along, sourceWidth: m.rect.width,
                        inheritedNormalBounds: normal.min()!...normal.max()!)
                    if whole.decision != "no-entire-closed-component-loss-observed" {
                        reason = "whole-source-RGB-" + whole.decision
                        pixelChecks.append(["sourceOrdinal": i, "whole": whole.decision]); break
                    }
                    let dense = NativeOCRDensePrivateFootprintGuard.assess(old: old, proposed: q,
                        rgba: denseRGBA, footprints: [p.actualFullFootprint],
                        origin: m.origin, normal: m.normal, along: m.along, sourceWidth: m.rect.width)
                    if dense.decision != "no-substantial-source-relative-loss-observed" {
                        reason = "dense-source-RGB-" + dense.decision
                        pixelChecks.append(["sourceOrdinal": i, "whole": whole.decision, "dense": dense.decision]); break
                    }
                    let terminal = NativeOCRAlignedGradientTerminalGuard.assess(old: old, new: q,
                        rgba: rgba, authenticatedPalettes: p.actualPalettes,
                        frameOrigin: p.sourceOrigin, normal: p.normal, along: p.along, sourceWidth: p.sourceWidth,
                        isPrivatePixel: { x, y in p.actualFullFootprint.contains(.init(x: x, y: y)) })
                    pixelChecks.append(["sourceOrdinal": i, "whole": whole.decision, "dense": dense.decision,
                        "terminal": terminal.decision, "terminalPairs": terminal.examinedPairs,
                        "terminalBodies": terminal.authenticatedBodies])
                    if terminal.decision != "no-qualified-terminal-loss-observed" || !terminal.witnesses.isEmpty {
                        reason = "actual-current-prior-terminal-loss"; break
                    }
                    if !NativeOCRSourceBodyEnvelope.containsMandatory(q, points: old) &&
                        (terminal.examinedPairs == 0 || terminal.authenticatedBodies == 0) {
                        reason = "uncertain-current-prior-body-evidence"; break
                    }
                }
            }
            let candidate = NativeOCRResidualCandidate(key: key, polygon: q,
                consumedIndices: prior.consumedIndices, supportPoints: mandatory,
                associationKey: prior.inheritedAssociationKey)
            let polygonJSON = q.map { ["x": Double($0.x), "y": Double($0.y)] }
            let priorJSON = old.map { ["x": Double($0.x), "y": Double($0.y)] }
            let hullJSON = NativeOCRSourceComponentMeasurements.convexHull(mandatory).map { [Double($0.x), Double($0.y)] }
            let record: [String: Any] = ["key": key, "polygon": polygonJSON, "accepted": reason == nil,
                "rejection": reason as Any? ?? NSNull(), "consumedIndices": prior.consumedIndices,
                "inheritedAssociationKey": prior.inheritedAssociationKey as Any? ?? NSNull(),
                "inheritedPriorPolygon": priorJSON, "inheritedPriorKey": prior.candidate?.key as Any? ?? NSNull(),
                "mandatoryHull": hullJSON, "mandatorySupportPoints": mandatory.count,
                "actualPrivateHullPoints": privateCount, "actualGuardPoints": guardCount,
                "actualCaps": capsCount, "originalGuardPoints": originalCount,
                "inheritedExplicitSupportPoints": prior.candidate?.supportPoints.count ?? 0,
                "sourceCount": sources.count, "pixelChecks": pixelChecks, "priorAlongSpanRetained": true]
            records.append(record)
            if reason == nil { candidates.append(candidate) }
        }
        return .init(candidates: candidates, records: records)
    }
    private static func align(_ polygon: [CGPoint], to prior: [CGPoint]) -> [CGPoint] {
        var best = polygon, distance = CGFloat.infinity
        for reversed in [false, true] {
            let q = reversed ? Array(polygon.reversed()) : polygon
            for shift in 0..<4 {
                let trial = (0..<4).map { q[($0 + shift) % 4] }
                let d = (0..<4).reduce(CGFloat(0)) { sum, i in
                    let x = trial[i].x - prior[i].x, y = trial[i].y - prior[i].y
                    return sum + x * x + y * y
                }
                if d < distance { best = trial; distance = d }
            }
        }
        return best
    }
}


import CoreGraphics
import Foundation

/// Live original-pixel proposal factory. Exported geometry and admission are distinct.
/// No ownership mutation; no model calls; no IDs/GT/hash-based routing.
@available(iOS 18.0, *)
enum NativeOCRSourceLocalJoint369 {
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    typealias Body = NativeOCRSourceAuthenticatedBodyEvidence
    typealias Footprint = NativeOCRDensePrivateFootprintGuard.Footprint
    typealias RGBA = NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA
    static let family = "source-local-joint369"
    struct PeerEvidence {
        let probeROI: CGRect
        let frameSize: Body.FrameSize
        let peers: [Peer]
        let knownForeignCells: [Footprint]
        let uncertainCells: [Footprint]
        let diagnostics: [String: Any]
    }
    struct Peer {
        let sourceIndex: Int // provenance/graph join only, never a geometry condition
        let polygon: [CGPoint]
        let measurement: M?
        let missingLocalEvidence: Bool
    }
    struct Scope {
        let rect: CGRect
        let semanticClass: Int
        let confidence: Double
    }
    struct LiveObservation {
        let window: Body.Window
        let rgba: RGBA
        let sources: [M]
        let bodies: [Body.Evidence]
        let mandatory: [CGPoint]
        let peerBodies: [Int: Body.Evidence]
        let scopes: [Scope]
    }
    struct Output {
        let candidates: [NativeOCRResidualCandidate] // admitted producer candidates only
        let records: [[String: Any]]                 // ALL plausible geometries, including blocked ones
        var nominalMenu384: [NativeOCRSourceLocalJoint369Ranker.Candidate] = []
        var nominalRoles384 = NativeOCRSourceLocalJoint369Ranker.RoleSummary(
            pixelsByRole: [:], componentCount: 0, openComponents: 0)
    }
    struct Component {
        let pixels: [Int]
        let bounds: CGRect // projected actual pixel-cell envelope, never filled
        let privateCount: Int
        let bodyContact: Int
        let paletteOrdinal: Int
        let open: Bool
        var role = "unqualified"
    }
    struct Offer { let key: String; let polygon: [CGPoint]; let normalMode: String; let alongMode: String }

    /// Search bounds are budgets, NOT candidate padding. Candidate coordinates below
    /// come only from observed attached RGB pixels and actual guards/caps/support.
    static func probe(prior: [CGPoint], sourceWidth: CGFloat, frameSize: Body.FrameSize) ->
        (quad: [CGPoint], window: Body.Window)? {
        guard let f = basis(prior), sourceWidth.isFinite, sourceWidth >= 3 else { return nil }
        let p = prior.map(f.project), n0 = p.map(\.x).min()!, n1 = p.map(\.x).max()!
        let a0 = p.map(\.y).min()!, a1 = p.map(\.y).max()!
        let q = [f.restore(n0 - sourceWidth, a0 - sourceWidth), f.restore(n1 + sourceWidth, a0 - sourceWidth),
                 f.restore(n1 + sourceWidth, a1 + sourceWidth), f.restore(n0 - sourceWidth, a1 + sourceWidth)]
        // Clip SEARCH rectangle to the image only. No clipped candidate is emitted.
        let bounded = q.map { CGPoint(x: max(0, min(CGFloat(frameSize.width), $0.x)),
                                     y: max(0, min(CGFloat(frameSize.height), $0.y))) }
        guard valid(bounded), let window = Body.Window.make(sourceQuads: [prior, bounded], frameSize: frameSize) else { return nil }
        return (bounded, window)
    }

    /// Optional standalone capture; parent can instead construct LiveObservation from
    /// ONE combined session used by agent4/agent3. No per-candidate source reads.
    static func captureLive(currentPrior: NativeOCRCurrentPrior351.Resolution,
                            actualGraph: NativeOCRSourceLocalJoint369Capture.FinalGraph,
                            measurement: M, originalFrame: NativeOCRRGBAFrame,
                            localPeerEvidence: PeerEvidence, measurements: [Int: M],
                            capsForSource: (M) -> [CGPoint]?, originalOwnedSupport: (Int) -> [CGPoint],
                            scopes: [Scope], sharedWindow: Body.Window? = nil) -> LiveObservation? {
        let prior = currentPrior, size = localPeerEvidence.frameSize
        guard originalFrame.width == size.width, originalFrame.height == size.height,
              actualGraph.prior(measurement.index)?.polygon == prior.polygon,
              let search = probe(prior: prior.polygon, sourceWidth: measurement.rect.width, frameSize: size) else { return nil }
        let window = sharedWindow ?? search.window
        let roi = CGRect(x: CGFloat(window.left), y: CGFloat(window.top), width: CGFloat(window.width), height: CGFloat(window.height))
        guard localPeerEvidence.probeROI.contains(roi), window.width * window.height <= 600_000 else { return nil }
        var preparations: [Body.Prepared] = [], sources: [M] = [], mandatory = prior.candidate?.supportPoints ?? []
        for index in [measurement.index] + prior.consumedIndices {
            guard let m = measurements[index], m.status == "measured", let caps = capsForSource(m),
                  let p = Body.prepare(m, inherited: prior.polygon, frameSize: size,
                                       enabled: true, sharedWindow: window).prepared else { return nil }
            preparations.append(p); sources.append(m)
            mandatory += caps + originalOwnedSupport(index) + m.guardPoints + m.privateHull.map(m.restore)
        }
        guard !preparations.isEmpty, preparations.count <= 64,
              window.width * window.height <= 3_000_000 / preparations.count,
              let source = Body.read(preparations[0], frameProvider: { originalFrame }) else { return nil }
        var bodies: [Body.Evidence] = []
        for p in preparations {
            guard let body = Body.observe(p, source: source).evidence else { return nil }
            bodies.append(body)
        }
        var peerBodies: [Int: Body.Evidence] = [:]
        // This uses the SAME source window; root search quad is an observation query,
        // not a reassignment of the peer's private pixels to the root.
        var cost = preparations.count * window.width * window.height
        for peer in localPeerEvidence.peers {
            guard let m = peer.measurement, m.status == "measured",
                  cost + window.width * window.height <= 3_000_000 else { continue }
            cost += window.width * window.height
            guard let p = Body.prepare(m, inherited: search.quad, frameSize: size,
                                       enabled: true, sharedWindow: window).prepared,
                  let body = Body.observe(p, source: source).evidence else { continue }
            peerBodies[peer.sourceIndex] = body
        }
        return .init(window: window, rgba: source.rgba, sources: sources, bodies: bodies,
                     mandatory: mandatory, peerBodies: peerBodies, scopes: scopes)
    }

    /// Shared-session factory requested by parent: frame metadata is checked here;
    /// RGB and masks are borrowed from liveObservation and never copied/read again.
    static func generateFromLive(currentPrior: NativeOCRCurrentPrior351.Resolution,
                                 actualGraph: NativeOCRSourceLocalJoint369Capture.FinalGraph,
                                 measurement: M, originalFrame: NativeOCRRGBAFrame,
                                 localPeerEvidence: PeerEvidence, liveObservation: LiveObservation,
                                 componentDiagnostics371: NativeOCRComponentDiagnostics371.Mode = .summary,
                                 protectObservedContrast380: Bool = false,
                                 preserveEndpoints380: Bool = true,
                                 accepts: (Int, [CGPoint]) -> Bool) -> Output {
        let prior = currentPrior, live = liveObservation, rgba = live.rgba
        func failure(_ reason: String) -> Output {
            .init(candidates: [], records: [["family": family, "key": family + "-observation",
                "geometryProposed": false, "admitted": false, "hardRejections": [reason], "softRejections": []]])
        }
        guard actualGraph.prior(measurement.index)?.polygon == prior.polygon,
              actualGraph.prior(measurement.index)?.consumedIndices == prior.consumedIndices,
              originalFrame.width == localPeerEvidence.frameSize.width,
              originalFrame.height == localPeerEvidence.frameSize.height,
              live.sources.map(\.index) == [measurement.index] + prior.consumedIndices,
              live.bodies.count == live.sources.count, let f = basis(prior.polygon),
              rgba.width > 2, rgba.height > 2, rgba.width <= 600_000 / rgba.height,
              rgba.bytesPerRow >= rgba.width * 4, rgba.bytes.count >= rgba.bytesPerRow * rgba.height,
              !live.bodies.isEmpty else { return failure("inconsistent-actual368-live-session") }
        let localROI = CGRect(x: rgba.origin.x, y: rgba.origin.y, width: CGFloat(rgba.width), height: CGFloat(rgba.height))
        guard localPeerEvidence.probeROI.contains(localROI),
              live.bodies.allSatisfy({ $0.sourceAuthenticatedContrastBodyMask.count == rgba.width * rgba.height &&
                  $0.sourceLocalRGBA.origin == rgba.origin && $0.sourceLocalRGBA.width == rgba.width &&
                  $0.sourceLocalRGBA.height == rgba.height && $0.prepared.inherited == prior.polygon }) else {
            return failure("live-window-or-prior-mismatch")
        }
        var authenticated = [UInt8](repeating: 0, count: rgba.width * rgba.height)
        for body in live.bodies { for i in authenticated.indices where body.sourceAuthenticatedContrastBodyMask[i] != 0 {
            authenticated[i] = 1
        }}
        func isPrivate(_ p: CGPoint) -> Bool { live.bodies.contains { $0.actualFullFootprint.contains(p) } }
        let components = sourceComponents(rgba: rgba, bodies: authenticated, palettes: live.bodies.flatMap(\.actualPalettes),
                                          isPrivate: isPrivate, basis: f, sourceWidth: measurement.rect.width,
                                          scopes: live.scopes, prior: prior.polygon)
        let qualified = components.filter { $0.role != "unqualified" && !$0.open }
        // Keep native contrast-body pixels as a source-authenticated support set even
        // when a palette CC joins background and cannot be qualified as an outline.
        var selected = Set<Int>()
        for i in authenticated.indices where authenticated[i] != 0 { selected.insert(i) }
        for c in qualified { selected.formUnion(c.pixels) }
        guard !selected.isEmpty else { return failure("no-source-attached-pixel-support") }
        var support: [CGPoint] = [], n0 = CGFloat.infinity, n1 = -CGFloat.infinity, a0 = CGFloat.infinity, a1 = -CGFloat.infinity
        let rn = (abs(f.normal.x) + abs(f.normal.y)) * 0.5, ra = (abs(f.along.x) + abs(f.along.y)) * 0.5
        for i in selected {
            let p = f.project(.init(x: rgba.origin.x + CGFloat(i % rgba.width) + 0.5,
                                   y: rgba.origin.y + CGFloat(i / rgba.width) + 0.5))
            n0 = min(n0, p.x - rn); n1 = max(n1, p.x + rn); a0 = min(a0, p.y - ra); a1 = max(a1, p.y + ra)
        }
        support = live.mandatory
        for point in support {
            guard point.x.isFinite, point.y.isFinite else { return failure("invalid-actual-support") }
            let p = f.project(point); n0 = min(n0, p.x); n1 = max(n1, p.x); a0 = min(a0, p.y); a1 = max(a1, p.y)
        }
        let old = prior.polygon.map(f.project), on0 = old.map(\.x).min()!, on1 = old.map(\.x).max()!
        let oa0 = old.map(\.y).min()!, oa1 = old.map(\.y).max()!
        let normals: [(String, CGFloat, CGFloat)] = [("keep",on0,on1),("low",min(on0,n0),on1),
            ("high",on0,max(on1,n1)),("both",min(on0,n0),max(on1,n1))]
        let alongs: [(String, CGFloat, CGFloat)] = [("keep",oa0,oa1),("head",a0,oa1),("tail",oa0,a1),("body",a0,a1)]
        var offers: [Offer] = []
        for (nm,l,r) in normals { for (am,t,b) in alongs where r > l && b > t {
            let q = align([f.restore(l,t),f.restore(r,t),f.restore(r,b),f.restore(l,b)], to: prior.polygon)
            if same(q, prior.polygon) || offers.contains(where: { same($0.polygon,q) }) { continue }
            offers.append(.init(key: family + "-normal-" + nm + "-along-" + am,
                                polygon: q, normalMode: nm, alongMode: am))
        }}
        // Opt-in source-only experiment. The prior is an observation boundary,
        // never a foreground mask. Observe once per live root and reuse for all offers.
        let contrast380 = protectObservedContrast380 && preserveEndpoints380 ? NativeOCRContrastSupport380.observe(
            old: prior.polygon, rgba: rgba, bodyMask: authenticated, sourceWidth: measurement.rect.width) : nil
        var contrastRepairs380: [String: NativeOCRContrastSupport380.Proposal] = [:]
        var contrastLoss380 = Set<String>()
        if let observation = contrast380 {
            for core in offers {
                for repair in NativeOCRContrastSupport380.proposals(core: core.polygon, observation: observation) {
                    contrastLoss380.insert(core.key)
                    let key = core.key + "-contrast380-" + repair.suffix
                    contrastRepairs380[key] = repair
                    // Re-enter every real root/member and peer gate below. A repair
                    // receipt alone never admits newly covered corner pixels.
                    offers.append(.init(key: key, polygon: repair.polygon,
                                        normalMode: core.normalMode, alongMode: core.alongMode))
                }
            }
        }
        let denseRGBA = NativeOCRDensePrivateFootprintGuard.RGBA(bytes: rgba.bytes, width: rgba.width,
            height: rgba.height, stride: rgba.bytesPerRow, origin: rgba.origin)
        let terminalCache369 = NativeOCRLocalJointGGCache387(bodies: live.bodies)
        var candidates: [NativeOCRResidualCandidate] = [], records: [[String: Any]] = []
        var nominalMenu384: [NativeOCRSourceLocalJoint369Ranker.Candidate] = []
        for offer in offers {
            let q = offer.polygon
            var hard: [String] = [], soft: [String] = [], peerReceipts: [[String: Any]] = [], checks: [[String: Any]] = []
            if protectObservedContrast380 && preserveEndpoints380 && contrast380 == nil {
                soft.append("original-contrast-observation-unavailable")
            }
            if let repair = contrastRepairs380[offer.key] { hard += repair.hard }
            if !valid(q) || !q.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= CGFloat(originalFrame.width) &&
                $0.y <= CGFloat(originalFrame.height) }) { hard.append("outside-image-or-invalid-geometry") }
            if !q.allSatisfy({ localROI.insetBy(dx: 1, dy: 1).contains($0) }) { soft.append("proposal-reaches-live-observation-edge") }
            if !live.mandatory.allSatisfy({ contains(q,$0) }) { hard.append("lost-actual-cap-guard-or-explicit-support") }
            if !live.sources.allSatisfy({ accepts($0.index,q) }) { hard.append("existing-root-member-semantic-reject") }
            let cellConflict = acquiredCells(q, old: prior.polygon, footprints: localPeerEvidence.knownForeignCells)
            if cellConflict > 0 { hard.append("acquired-actual-external-owner-cells") }
            let uncertain = acquiredCells(q, old: prior.polygon, footprints: localPeerEvidence.uncertainCells)
            if uncertain > 0 { soft.append("acquired-ambiguous-or-competing-DB-cells") }
            for peer in localPeerEvidence.peers {
                let delta = intersectionArea(q,peer.polygon) - intersectionArea(prior.polygon,peer.polygon)
                guard delta > 1e-6 else { continue }
                let acquiredPeerContrast382 = protectObservedContrast380 &&
                    NativeOCRContrastSupport380.acquiresCoherentPeerContrast382(
                        old: prior.polygon, proposed: q, peer: peer.polygon, rgba: rgba)
                if acquiredPeerContrast382 { soft.append("acquired-original-contrast-in-actual-peer-region") }
                var acquiredMaskPixels = 0
                if let body = live.peerBodies[peer.sourceIndex], body.sourceLocalRGBA.origin == rgba.origin,
                   body.sourceLocalRGBA.width == rgba.width, body.sourceLocalRGBA.height == rgba.height,
                   body.sourceAuthenticatedContrastBodyMask.count == authenticated.count {
                    for i in authenticated.indices where body.sourceAuthenticatedContrastBodyMask[i] != 0 {
                        let p = CGPoint(x: rgba.origin.x + CGFloat(i % rgba.width) + 0.5,
                                        y: rgba.origin.y + CGFloat(i / rgba.width) + 0.5)
                        if contains(q,p) && !contains(prior.polygon,p) { acquiredMaskPixels += 1 }
                    }
                    if acquiredMaskPixels > 0 { soft.append("acquired-peer-authenticated-contrast-body") }
                } else if peer.missingLocalEvidence || peer.measurement?.privateObservation == nil {
                    soft.append("relevant-peer-local-physical-evidence-unavailable")
                }
                // Quad overlap is diagnostic only, never a physical loss or hard veto.
                peerReceipts.append(["peerSourceIndex":peer.sourceIndex,"newQuadIntersectionArea":Double(delta),
                    "acquiredObservedContrastBodyPixels":acquiredMaskPixels,"quadOverlapAloneVeto":false,
                    "peerMaskAvailable":live.peerBodies[peer.sourceIndex] != nil,
                    "acquiredCoherentPeerRegionContrast382":acquiredPeerContrast382,
                    "peerRegionContrastIsOwnershipClaim":false])
            }
            let enclosesIngress = prior.polygon.allSatisfy { contains(q,$0) }
            if hard.isEmpty && enclosesIngress {
                checks.append(["proof":"whole-actual368-prior-enclosure","lossChecksSkippedBecauseNoPriorPixelCanBeRemoved":true])
            } else if hard.isEmpty {
                for (ordinal, body) in live.bodies.enumerated() {
                    let m = live.sources[ordinal], p = body.prepared
                    let oldNormal = prior.polygon.map { m.project($0).x }
                    let whole = NativeOCRResidualTurningStrokeGuardHistogram.assess(old:prior.polygon,new:q,
                        rgba:rgba,authenticatedPalettes:p.actualPalettes,privateRGBSampleCount:m.privateObservation?.privateRGBSamples ?? 0,
                        frameOrigin:m.origin,normal:m.normal,along:m.along,sourceWidth:m.rect.width,
                        inheritedNormalBounds:oldNormal.min()!...oldNormal.max()!)
                    let dense = NativeOCRDensePrivateFootprintGuard.assess(old:prior.polygon,proposed:q,rgba:denseRGBA,
                        footprints:[p.actualFullFootprint],origin:m.origin,normal:m.normal,along:m.along,sourceWidth:m.rect.width)
                    let terminal = terminalCache369.terminalObservation(memberOrdinal: ordinal, proposed: q)
                    checks.append(["sourceOrdinal":ordinal,"whole":whole.decision,"dense":dense.decision,
                        "terminal":terminal?.decision as Any? ?? NSNull(),"terminalPairs":terminal?.examinedPairs ?? 0])
                    if whole.decision == "reject" { hard.append("whole-source-reject") }
                    else if whole.decision != "no-entire-closed-component-loss-observed" { soft.append("whole-source-uncertain") }
                    if dense.decision == "reject" { hard.append("dense-source-reject") }
                    else if dense.decision != "no-substantial-source-relative-loss-observed" { soft.append("dense-source-uncertain") }
                    if terminal?.decision == "reject" || terminal?.witnesses.isEmpty == false { hard.append("actual-terminal-loss") }
                    else if terminal?.decision != "no-qualified-terminal-loss-observed" { soft.append("terminal-observation-unavailable") }
                }
            }
            let original369Admitted = hard.isEmpty && soft.allSatisfy {
                $0 == "acquired-original-contrast-in-actual-peer-region"
            }
            // Nomination parity is evaluated using the original guards. A nomination
            // grants no admission; final core or repaired geometry must pass ALL gates.
            if contrastLoss380.contains(offer.key) { hard.append("newly-excluded-observed-prior-contrast") }
            let admitted = hard.isEmpty && soft.isEmpty
            if original369Admitted && contrastRepairs380[offer.key] == nil {
                nominalMenu384.append(.init(key: offer.key, polygon: q,
                    normalMode: offer.normalMode, alongMode: offer.alongMode,
                    qualifiedComponentCount: qualified.count, observedSupportPixels: selected.count,
                    minimumTerminalPairs: checks.compactMap { $0["terminalPairs"] as? Int }.min() ?? 0,
                    priorEnclosureReceipt: checks.contains { $0["lossChecksSkippedBecauseNoPriorPixelCanBeRemoved"] as? Bool == true },
                    peerReceiptCount: peerReceipts.count))
            }
            let candidate = NativeOCRResidualCandidate(key:offer.key,polygon:q,consumedIndices:prior.consumedIndices,
                                                       supportPoints:support,associationKey:prior.inheritedAssociationKey)
            if admitted { candidates.append(candidate) }
            records.append(["family":family,"key":offer.key,"geometryProposed":true,"admitted":admitted,"accepted":admitted,
                "polygon":q.map { [Double($0.x),Double($0.y)] },"normalMode":offer.normalMode,"alongMode":offer.alongMode,
                "hardRejections":hard,"softRejections":soft,"actualForeignCellAcquisitions":cellConflict,
                "uncertainCellAcquisitions":uncertain,"peerReceipts":peerReceipts,"pixelChecks":checks,
                "original369AdmittedForNominationOnly":original369Admitted,
                "contrastSupport380Enabled":protectObservedContrast380,
                "contrastSupport380Receipt":contrastRepairs380[offer.key]?.receipt as Any? ?? NSNull(),
                "contrastRepairReranNativePeerGates":contrastRepairs380[offer.key] != nil,
                "qualifiedComponentCount":qualified.count,"observedSupportPixels":selected.count,
                "current368Polygon":prior.polygon.map { [Double($0.x),Double($0.y)] },
                "consumedIndices":prior.consumedIndices,"associationKey":prior.inheritedAssociationKey as Any? ?? NSNull(),
                "ownershipMutated":false,"automaticSelection":false])
        }
        var componentRecord: [String: Any] = ["family": family, "key": family + "-component-observation",
            "geometryProposed": false, "localPeerEvidence": localPeerEvidence.diagnostics,
            "sharedSourceWindow": true, "candidateCount": offers.count]
        let componentFields = NativeOCRComponentDiagnostics371.encode(components, mode: componentDiagnostics371) { c in
            NativeOCRComponentDiagnostics371.Row(pixels: c.pixels.count, privatePixels: c.privateCount,
                bodyContactPixels: c.bodyContact, paletteOrdinal: c.paletteOrdinal, roiContact: c.open, role: c.role,
                normalLow: Double(c.bounds.minX), alongLow: Double(c.bounds.minY),
                normalHigh: Double(c.bounds.maxX), alongHigh: Double(c.bounds.maxY))
        }
        componentRecord.merge(componentFields) { _, new in new }
        records.append(componentRecord)
        var rolePixels384: [String: Int] = [:]
        for component in components { rolePixels384[component.role, default: 0] += component.pixels.count }
        return .init(candidates:candidates, records:records, nominalMenu384:nominalMenu384,
            nominalRoles384: .init(pixelsByRole:rolePixels384, componentCount:components.count,
                                  openComponents:components.filter(\.open).count))
    }
    static func sourceComponents(rgba: RGBA, bodies: [UInt8],
                                 palettes: [NativeOCRResidualTurningStrokeGuardHistogram.Palette],
                                 isPrivate: (CGPoint) -> Bool, basis: Basis, sourceWidth: CGFloat,
                                 scopes: [Scope], prior: [CGPoint]) -> [Component] {
        let w = rgba.width, h = rgba.height, count = w * h
        var unique: [NativeOCRResidualTurningStrokeGuardHistogram.Palette] = []
        for p in palettes.sorted(by: { $0.sourceSeedBinCount > $1.sourceSeedBinCount }) where
            p.rgb.count == 3 && !unique.contains(where: { $0.rgb == p.rgb }) {
            unique.append(p)
            if unique.count == 16 { break }
        }
        var result: [Component] = []
        let rn = (abs(basis.normal.x) + abs(basis.normal.y)) * 0.5
        let ra = (abs(basis.along.x) + abs(basis.along.y)) * 0.5
        for (paletteOrdinal,palette) in unique.enumerated() {
            var eligible = [Bool](repeating:false,count:count), seen = eligible
            for y in 0..<h { for x in 0..<w {
                let offset = y * rgba.bytesPerRow + x * 4
                eligible[y*w+x] = rgba.bytes[offset+3] == 255 && (0..<3).allSatisfy {
                    abs(Int(rgba.bytes[offset+$0])-palette.rgb[$0]) <= 32
                }
            }}
            for seed in 0..<count where eligible[seed] && !seen[seed] {
                var pixels = [seed], cursor = 0, open = false, privateCount = 0, oldCount = 0, contact = 0
                var n0 = CGFloat.infinity, n1 = -CGFloat.infinity, a0 = CGFloat.infinity, a1 = -CGFloat.infinity
                seen[seed] = true
                while cursor < pixels.count {
                    let i = pixels[cursor]; cursor += 1; let x = i%w, y = i/w
                    let world = CGPoint(x:rgba.origin.x+CGFloat(x)+0.5,y:rgba.origin.y+CGFloat(y)+0.5), p = basis.project(world)
                    n0=min(n0,p.x-rn);n1=max(n1,p.x+rn);a0=min(a0,p.y-ra);a1=max(a1,p.y+ra)
                    if isPrivate(world) { privateCount += 1 }
                    if contains(prior,world) { oldCount += 1 }
                    open = open || x == 0 || y == 0 || x == w-1 || y == h-1
                    var touches = false
                    for yy in max(0,y-1)...min(h-1,y+1) { for xx in max(0,x-1)...min(w-1,x+1) {
                        let next=yy*w+xx
                        if bodies[next] != 0 { touches = true }
                        if eligible[next] && !seen[next] { seen[next]=true;pixels.append(next) }
                    }}
                    if touches { contact += 1 }
                }
                var c = Component(pixels:pixels,bounds:.init(x:n0,y:a0,width:n1-n0,height:a1-a0),
                                  privateCount:privateCount,bodyContact:contact,paletteOrdinal:paletteOrdinal,open:open)
                let scaleOK = c.bounds.width <= 2.5*sourceWidth && c.bounds.height <= 3*sourceWidth && pixels.count >= 2
                if !open && scaleOK {
                    if privateCount >= 2 && oldCount >= 2 { c.role="actual-private-attached-complete-RGB-component" }
                    else if contact >= 2 && enclosesBody(pixels:pixels,bodies:bodies,width:w,height:h) {
                        c.role="closed-source-body-outline-topology"
                    }
                }
                result.append(c)
            }
        }
        let anchors=result.filter { $0.role != "unqualified" }
        let sizes=anchors.map { max($0.bounds.width,$0.bounds.height) }.sorted()
        let glyphScale=max(sourceWidth*0.35,sizes.isEmpty ? sourceWidth : sizes[sizes.count/2])
        for i in result.indices where result[i].role == "unqualified" && !result[i].open {
            let c=result[i]
            guard c.bounds.width<=glyphScale*1.8,c.bounds.height<=glyphScale*1.8 else { continue }
            if anchors.contains(where:{ anchor in
                guard anchor.paletteOrdinal==c.paletteOrdinal,
                      abs(anchor.bounds.midX-c.bounds.midX)<=glyphScale*0.6 else {return false}
                let gap=max(0,max(c.bounds.minY-anchor.bounds.maxY,anchor.bounds.minY-c.bounds.maxY))
                guard gap<=glyphScale*0.8 else{return false}
                let cw=basis.restore(c.bounds.midX,c.bounds.midY),aw=basis.restore(anchor.bounds.midX,anchor.bounds.midY)
                return scopes.contains { ($0.semanticClass==0 || $0.semanticClass==1) && $0.confidence>=0.5 &&
                    $0.rect.contains(cw) && $0.rect.contains(aw) }
            }) { result[i].role="one-hop-same-palette-RF-text-sequence-support" }
        }
        return result
    }
    /// Flood only the observed complement to test ring topology; no foreground pixels
    /// or ownership are created by this operation, and no hull is rasterized.
    static func enclosesBody(pixels:[Int],bodies:[UInt8],width:Int,height:Int)->Bool {
        let shell=Set(pixels),xs=pixels.map{$0%width},ys=pixels.map{$0/width}
        guard let x0=xs.min(),let x1=xs.max(),let y0=ys.min(),let y1=ys.max(),x1-x0>=2,y1-y0>=2 else{return false}
        var exterior=Set<Int>(),queue:[Int]=[]
        func add(_ p:Int){if !shell.contains(p) && exterior.insert(p).inserted{queue.append(p)}}
        for x in x0...x1{add(y0*width+x);add(y1*width+x)}
        for y in y0...y1{add(y*width+x0);add(y*width+x1)}
        var cursor=0
        while cursor<queue.count{
            let p=queue[cursor];cursor+=1;let x=p%width,y=p/width
            if x>x0{add(p-1)};if x<x1{add(p+1)};if y>y0{add(p-width)};if y<y1{add(p+width)}
        }
        for y in (y0+1)..<y1{for x in (x0+1)..<x1{
            let p=y*width+x
            if bodies[p] != 0 && !shell.contains(p) && !exterior.contains(p){return true}
        }}
        return false
    }
    static func acquiredCells(_ q:[CGPoint],old:[CGPoint],footprints:[Footprint])->Int{
        let rect=bounds(q);var count=0
        for f in footprints{
            guard f.width>0,f.height>0,f.scaleX>0,f.scaleY>0 else{continue}
            for cell in f.cells{
                let x=CGFloat(cell%f.width)*f.scaleX,y=CGFloat(cell/f.width)*f.scaleY
                let r=CGRect(x:x,y:y,width:f.scaleX,height:f.scaleY)
                guard r.intersects(rect) else{continue}
                let p=[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),
                       CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)]
                if intersectionArea(q,p)>intersectionArea(old,p)+1e-6{count+=1}
            }
        }
        return count
    }
    static func bounds(_ q:[CGPoint])->CGRect{
        guard !q.isEmpty else{return .null}
        let x0=q.map(\.x).min()!,y0=q.map(\.y).min()!
        return .init(x:x0,y:y0,width:q.map(\.x).max()!-x0,height:q.map(\.y).max()!-y0)
    }
    static func same(_ a:[CGPoint],_ b:[CGPoint])->Bool{
        a.count==b.count && zip(a,b).allSatisfy{hypot($0.x-$1.x,$0.y-$1.y)<1e-6}
    }
    struct Basis {
        let origin: CGPoint
        let normal: CGPoint
        let along: CGPoint
        func project(_ p: CGPoint) -> CGPoint {
            let d = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
            return .init(x: d.x * normal.x + d.y * normal.y, y: d.x * along.x + d.y * along.y)
        }
        func restore(_ n: CGFloat, _ a: CGFloat) -> CGPoint {
            .init(x: origin.x + n * normal.x + a * along.x,
                  y: origin.y + n * normal.y + a * along.y)
        }
    }
    static func basis(_ q: [CGPoint]) -> Basis? {
        guard valid(q) else { return nil }
        let e1 = CGPoint(x: q[1].x - q[0].x, y: q[1].y - q[0].y)
        let e2 = CGPoint(x: q[3].x - q[0].x, y: q[3].y - q[0].y)
        let e = hypot(e1.x, e1.y) >= hypot(e2.x, e2.y) ? e1 : e2
        let length = hypot(e.x, e.y)
        guard length.isFinite, length > 0 else { return nil }
        let a = CGPoint(x: e.x / length, y: e.y / length)
        let originX = q.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(4)
        let originY = q.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(4)
        let origin = CGPoint(x: originX, y: originY)
        let normal = CGPoint(x: a.y, y: -a.x)
        return Basis(origin: origin, normal: normal, along: a)
    }
    static func valid(_ q: [CGPoint]) -> Bool {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let cross = (0..<4).map { i -> CGFloat in
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return cross.allSatisfy { $0 > 1e-8 } || cross.allSatisfy { $0 < -1e-8 }
    }
    static func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
        guard p.x.isFinite, p.y.isFinite else { return false }
        var positive = true, negative = true
        for i in 0..<q.count {
            let a = q[i], b = q[(i + 1) % q.count]
            let c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            positive = positive && c >= -1e-7; negative = negative && c <= 1e-7
        }
        return positive || negative
    }
    static func align(_ q: [CGPoint], to prior: [CGPoint]) -> [CGPoint] {
        var best = q, score = CGFloat.infinity
        for reverse in [false, true] {
            let a = reverse ? Array(q.reversed()) : q
            for shift in 0..<4 {
                let trial = (0..<4).map { a[($0 + shift) % 4] }
                let distance = (0..<4).reduce(CGFloat(0)) { sum, i in
                    sum + pow(trial[i].x - prior[i].x, 2) + pow(trial[i].y - prior[i].y, 2)
                }
                if distance < score { best = trial; score = distance }
            }
        }
        return best
    }
    static func intersectionArea(_ subject: [CGPoint], _ clip: [CGPoint]) -> CGFloat {
        func area(_ points: [CGPoint]) -> CGFloat {
            guard points.count >= 3 else { return 0 }
            return (0..<points.count).reduce(CGFloat(0)) { s, i in
                s + points[i].x * points[(i + 1) % points.count].y - points[(i + 1) % points.count].x * points[i].y
            } / 2
        }
        var output = subject
        let sign: CGFloat = area(clip) >= 0 ? 1 : -1
        for i in clip.indices {
            let a = clip[i], b = clip[(i + 1) % clip.count]
            func side(_ p: CGPoint) -> CGFloat { sign * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) }
            let input = output; output = []
            guard var previous = input.last else { return 0 }
            for point in input {
                let ds = side(previous), de = side(point)
                if (ds >= 0) != (de >= 0) {
                    let t = ds / (ds - de)
                    output.append(.init(x: previous.x + t * (point.x - previous.x), y: previous.y + t * (point.y - previous.y)))
                }
                if de >= 0 { output.append(point) }
                previous = point
            }
        }
        return abs(area(output))
    }
}


import CoreGraphics
import Foundation

@available(iOS 18.0, *)
enum NativeOCRSourceLocalJoint369Capture {
    typealias Expansion = NativeOCRSourceLocalJoint369
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    typealias Footprint = NativeOCRDensePrivateFootprintGuard.Footprint

    struct ExportConfiguration {
        var enabled = false
        var families: [String] = [NativeOCRSourceLocalJoint369.family]
        var maximumRoots = 256
        var componentDiagnostics371: NativeOCRComponentDiagnostics371.Mode = .summary
        var necessarySourceGate371 = false
        var requestsContrast380: Bool { enabled && families.contains("source-contrast-support380") }
        var requestsJoint369: Bool { enabled && (families.contains(NativeOCRSourceLocalJoint369.family) || requestsContrast380) }
        var requestsNonexclusive374: Bool { enabled && families.contains("nonexclusive-lane369") }
        // DEFAULT OFF; intentionally NOT part of requestsThisFamily (legacy runtime routing stays ON).
        var requestsOrientation394: Bool { enabled && families.contains("source-axis-orientation394") }
        var requestsBoundaryPrior399: Bool { enabled && families.contains("source-boundary-prior399") }
        var requestsBoundaryPrior397: Bool { enabled && (families.contains("source-boundary-prior397") || requestsBoundaryPrior399) }
        var requestsBoundaryOrientation397: Bool { enabled && families.contains("source-boundary-orientation397") }
        var requestsBoundary397: Bool { requestsBoundaryPrior397 || requestsBoundaryOrientation397 }
        // Experimental425 is opt-in only; default families and enabled remain unchanged.
        // DEFAULT OFF;426 adds a source-positive fallback only after424 is unresolved.
        var requestsSourceUtility435All8: Bool { enabled && families.contains("source-utility435-all8-select") }
        var requestsSourceUtility435: Bool { enabled && (families.contains("source-utility435-direct-mean-select") || requestsSourceUtility435All8) }
        var requestsSourceCost433FeasibleSelect: Bool { enabled && (families.contains("source-cost433-feasible-deep-select") || requestsSourceUtility435) }
        var requestsSourceCost430DeepSelect: Bool { enabled && (families.contains("source-cost430-deep-select") || requestsSourceCost433FeasibleSelect) }
        var requestsPositiveLoss426: Bool { enabled && (families.contains("source-cost426-positive-loss-select") || requestsSourceCost430DeepSelect) }
        var requestsSourceCost427MixedSelect: Bool { enabled && (families.contains("source-cost427-mixed-select") || families.contains("source-cost426-positive-loss-select") || requestsBoundaryLevelsMixed427Select) }
        var requestsBoundaryLevelsMixed427Select: Bool { enabled && families.contains("source-cost427-independent-levels-mixed-select") }
        var requestsBoundaryLevelsCostSelect: Bool { enabled && (families.contains("source-cost-independent-levels-select") || requestsBoundaryLevelsMixed427Select) }
        var requestsBoundaryLevels425: Bool { enabled && (families.contains("source-repair402-independent-levels-qualified425") || requestsBoundaryLevelsCostSelect) }
        var requestsBoundaryLevels: Bool { enabled && (families.contains("source-repair402-independent-levels-qualified409") || requestsBoundaryLevels425) }
        var boundaryLevelsControl: NativeOCRIndependentBoundaryLevels.Control {
            if families.contains("boundary-level-control-scalar-old") { return .scalarOld }
            if families.contains("boundary-level-control-RGB-contact") { return .rgbContact }
            if families.contains("boundary-level-control-GG-body") { return .ggBody }
            return .nativeBasis3
        }
        var requestsPositiveLoss424: Bool { enabled && (families.contains("source-cost424-positive-loss-select") || requestsSourceCost427MixedSelect || requestsSourceCost430DeepSelect) }
        var requestsSourceWitness436: Bool { enabled && families.contains("source-regression435-witness436") }
        var requestsMeanRegression435: Bool { enabled && (families.contains("source-regression435-mean-qualified425") || (requestsSourceUtility435 && !requestsSourceUtility435All8)) }
        var requestsFastMeanAudit435: Bool { requestsMeanRegression435 && !requestsSourceUtility435 }
        var requestsRawRegression435: Bool { enabled && (families.contains("source-regression435-qualified425") || requestsSourceWitness436 || requestsMeanRegression435 || requestsSourceUtility435All8) }
        var requestsNativeAdmission425: Bool { enabled && (families.contains("qualified-admission425") || families.contains("source-cost425-fast-select") || requestsPositiveLoss424 || requestsBoundaryLevels425 || requestsRawRegression435) }
        var requestsSourceCostFast422: Bool { enabled && (families.contains("source-cost422-fast-select") || families.contains("source-cost425-fast-select") || requestsPositiveLoss424) }
        var requestsSourceCost418: Bool { enabled && (families.contains("source-cost418-select") || (requestsSourceCostFast422 && !requestsSourceCost430DeepSelect) || requestsBoundaryLevelsCostSelect) }
        var requestsSourceCost416Stroke404: Bool { enabled && families.contains("source-cost416-stroke404-select") }
        var requestsSourceCost416Select: Bool { enabled && (families.contains("source-cost416-select") || requestsSourceCost416Stroke404 || requestsSourceCost418 || requestsSourceCost430DeepSelect) }
        var requestsVisualEnvelope410: Bool { enabled && families.contains("source-repair402-visual410") }
        var requestsModelEnvelope407: Bool { enabled && families.contains("source-repair402-model407") }
        var requestsQualifiedGeometry409: Bool { enabled && (families.contains("source-repair402-qualified409") || requestsModelEnvelope407 || requestsVisualEnvelope410 || requestsSourceCost416Select || requestsNativeAdmission425 || requestsBoundaryLevels) }
        var requestsFillEnvelope406: Bool { enabled && (families.contains("source-repair402-fill406") || requestsQualifiedGeometry409) }
        var requestsFillRim405: Bool { enabled && families.contains("source-repair402-role405") }
        var requestsRepair402Select: Bool { enabled && (families.contains("source-repair402-select") || requestsFillRim405) }
        var requestsRepair402Qualified401: Bool { enabled && (families.contains("source-repair402-qualified401") || requestsFillEnvelope406) }
        var requestsRepair402: Bool { enabled && (families.contains("source-repair402") || requestsRepair402Select || requestsRepair402Qualified401) }
        var requestsSharedBoundary400: Bool { enabled && families.contains("source-shared-boundary400") }
        var requestsOrientation392: Bool { enabled && (families.contains("source-axis-orientation392") || requestsOrientation394 || requestsBoundary397 || requestsSharedBoundary400 || requestsRepair402) }
        var requestsThisFamily: Bool { requestsJoint369 || requestsNonexclusive374 }
    }
    struct FinalGraph {
        let live: Set<Int>
        let suppressed: Set<Int>
        // Only ACTUALLY APPLIED coordinator candidates enter this dictionary.
        let applied: [Int: NativeOCRResidualCandidate]
        let polygons: [Int: [CGPoint]]
        let consumed: Set<Int>
        let associations: [[String: Any]]
        let groups: [Int: [Int]]

        func prior(_ root: Int) -> NativeOCRCurrentPrior351.Resolution? {
            guard live.contains(root), let polygon = polygons[root] else { return nil }
            let candidate = applied[root]
            if let candidate, candidate.polygon != polygon { return nil }
            let children = candidate?.consumedIndices ?? []
            guard !children.contains(root), Set(children).count == children.count,
                  Set(children).isSubset(of: consumed) else { return nil }
            if !children.isEmpty {
                guard let row = associations.first(where: { $0["parent"] as? Int == root }),
                      let members = row["members"] as? [Int], Set(members) == Set([root] + children),
                      let key = row["key"] as? String,
                      key == (candidate?.associationKey ?? candidate?.key) else { return nil }
            }
            let association: String? = children.isEmpty ? candidate?.associationKey :
                associations.first(where: { $0["parent"] as? Int == root })?["key"] as? String
            return .init(candidate: candidate, polygon: polygon, consumedIndices: children,
                         inheritedAssociationKey: association,
                         origin: candidate == nil ? .incoming : .preferred351)
        }
    }
    struct PeerResult {
        let evidence: Expansion.PeerEvidence?
        let record: [String: Any]
    }

    /// Same suppression closure as NativeOCRResidualRetention.State, evaluated only
    /// AFTER Bank's ordered conflict/claimed-parent coordinator has applied winners.
    /// Prepared group edges expand representation/suppression, not residual membership.
    static func finalGraph(indices: [Int], output: [[CGPoint]], consumed: Set<Int>,
                           associations: [[String: Any]], groups: [Int: [Int]],
                           applied: [Int: NativeOCRResidualCandidate]) -> FinalGraph? {
        guard indices.count == output.count, Set(indices).count == indices.count else { return nil }
        var edges = groups.mapValues(Set.init), roots = Set<Int>()
        for association in associations {
            guard let parent = association["parent"] as? Int, parent >= 0,
                  let members = association["members"] as? [Int], members.contains(parent),
                  let candidate = applied[parent], Set(members) == Set([parent] + candidate.consumedIndices) else { return nil }
            let children = Set(members.filter { $0 >= 0 && $0 != parent })
            guard !children.isEmpty, children.isSubset(of: consumed) else { return nil }
            edges[parent, default: []].formUnion(children); roots.insert(parent)
        }
        var suppressed = consumed, pending = Array(consumed)
        while let node = pending.popLast() {
            for child in edges[node] ?? [] where suppressed.insert(child).inserted { pending.append(child) }
        }
        suppressed.subtract(roots.subtracting(consumed))
        let polygons = Dictionary(uniqueKeysWithValues: zip(indices, output))
        return .init(live: Set(indices).subtracting(suppressed), suppressed: suppressed,
                     applied: applied, polygons: polygons, consumed: consumed,
                     associations: associations, groups: groups)
    }

    /// Certifies the requested local window, never the whole page. FAR missing
    /// measurements cannot veto; nearby unknown evidence is reported per offer.
    static func localPeerEvidence(root:Int,graph:FinalGraph,measurements:[Int:M],
                                  originals:[NativeCoreMLDetectionBox],frameSize:NativeOCRSourceAuthenticatedBodyEvidence.FrameSize,
                                  probeROI:CGRect,layout:NativeRFDETRLayoutResult?)->PeerResult{
        guard let prior=graph.prior(root), !probeROI.isNull, !probeROI.isEmpty,
              probeROI.width*probeROI.height<=600_000 else {
            return .init(evidence:nil,record:["localCertificationAvailable":false,"reason":"invalid-local-probe-or-final368"])
        }
        let sourceIndices=[root]+prior.consumedIndices
        func leaves(_ seeds:[Int])->Set<Int>{
            var found=Set<Int>(),pending=seeds,visited=Set<Int>()
            while let i=pending.popLast(){
                guard visited.insert(i).inserted else{continue}
                if let members=graph.groups[i],!members.isEmpty{
                    pending+=members.filter{$0 != i}
                    if members.contains(i),originals.indices.contains(i){found.insert(i)}
                }else if originals.indices.contains(i){found.insert(i)}
            }
            return found
        }
        let ownLeaves=leaves(sourceIndices)
        let externalLeaves=leaves(graph.live.filter{$0 != root}.flatMap { index in
            [index]+(graph.applied[index]?.consumedIndices ?? [])
        })
        let actual=sourceIndices.compactMap{measurements[$0]?.privateObservation?.footprint}
        var known:[Footprint]=[],uncertain:[Footprint]=[],peers:[Expansion.Peer]=[]
        var farMissing=0,nearMissing=0,localOwners=0,localCells=0,uncertainCount=0,rfRoles:[String:Int]=[:]
        var unknownByOriginal:[Int:[CGPoint]]=[:]
        func cells(_ components:[NativeOCRDetectorSeedEvidence.Component],_ e:NativeOCRDetectorSeedEvidence)->Set<Int>{
            let sx=CGFloat(e.sourceWidth)/CGFloat(e.mapFullWidth),sy=CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight)
            let gx0=max(0,Int(floor(probeROI.minX/sx))),gx1=min(e.mapFullWidth,Int(ceil(probeROI.maxX/sx)))
            let gy0=max(0,Int(floor(probeROI.minY/sy))),gy1=min(e.mapFullHeight,Int(ceil(probeROI.maxY/sy)))
            var result=Set<Int>()
            for c in components{for r in c.runs where r.y>=gy0 && r.y<gy1{
                let low=max(r.x,gx0),high=min(r.x+r.count,gx1)
                if high>low{for x in low..<high{result.insert(r.y*e.mapFullWidth+x)}}
            }}
            return result
        }
        func footprint(_ cells:Set<Int>,_ e:NativeOCRDetectorSeedEvidence)->Footprint{
            .init(width:e.mapFullWidth,height:e.mapFullHeight,
                  scaleX:CGFloat(e.sourceWidth)/CGFloat(e.mapFullWidth),scaleY:CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight),cells:cells)
        }
        for (index,box) in originals.enumerated(){
            let boxKnown=Expansion.valid(box.polygon),boxNear=boxKnown && Expansion.bounds(box.polygon).intersects(probeROI)
            guard let e=box.detectorSeedEvidence,e.isValid,e.parentBoxIndex==index,
                  e.sourceWidth==frameSize.width,e.sourceHeight==frameSize.height else{
                if !boxKnown{
                    // Unknown geometry cannot be certified far: local uncertainty is
                    // retained as a soft per-offer block, not a lost geometry proposal.
                    nearMissing+=1;unknownByOriginal[index]=quad(probeROI)
                }else if boxNear && !ownLeaves.contains(index){nearMissing+=1;unknownByOriginal[index]=box.polygon}
                else{farMissing+=1}
                continue
            }
            let owned=cells(e.components,e),ambiguous=cells(e.ambiguousComponents ?? [],e)
            let competing=cells((e.candidateComponents ?? []).map(\.component),e)
            if owned.isEmpty && ambiguous.isEmpty && competing.isEmpty && !boxNear{continue}
            localOwners+=1
            var external=owned
            if ownLeaves.contains(index) && !externalLeaves.contains(index){
                external=Set(owned.filter{cell in !actual.contains{f in
                    f.width==e.mapFullWidth && f.height==e.mapFullHeight &&
                    abs(f.scaleX-CGFloat(e.sourceWidth)/CGFloat(e.mapFullWidth))<1e-9 &&
                    abs(f.scaleY-CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight))<1e-9 && f.cells.contains(cell)
                }})
            }
            if !external.isEmpty{known.append(footprint(external,e));localCells+=external.count}
            let risk=ambiguous.union(competing)
            if !risk.isEmpty{uncertain.append(footprint(risk,e));uncertainCount+=risk.count}
            // Legacy v1 supplies authentic local owned cells but no complete CC scan.
            // Preserve that fact only for the relevant box; never abort a distant ROI.
            if e.ownershipVersion != 2 && boxNear && !ownLeaves.contains(index){unknownByOriginal[index]=box.polygon;nearMissing+=1}
        }
        for peer in graph.live.sorted() where peer != root{
            guard let polygon=graph.polygons[peer],Expansion.valid(polygon),
                  Expansion.bounds(polygon).intersects(probeROI) else{continue}
            let m=measurements[peer]
            let missing=m?.privateObservation?.footprint == nil && m?.status != "no-private-source"
            peers.append(.init(sourceIndex:peer,polygon:polygon,measurement:m,missingLocalEvidence:missing))
            unknownByOriginal.removeValue(forKey:peer)
            // Actual local native peer footprint can reinstate a nonexclusive owner
            // view without claiming that a bounding quad owns its interior.
            if let f=m?.privateObservation?.footprint,f.width>0,f.height>0,f.scaleX>0,f.scaleY>0{
                let local=Set(f.cells.filter{cell in
                    CGRect(x:CGFloat(cell%f.width)*f.scaleX,y:CGFloat(cell/f.width)*f.scaleY,
                           width:f.scaleX,height:f.scaleY).intersects(probeROI)
                })
                if !local.isEmpty{known.append(.init(width:f.width,height:f.height,scaleX:f.scaleX,scaleY:f.scaleY,cells:local))}
            }
        }
        for (index,polygon) in unknownByOriginal.sorted(by:{$0.key<$1.key}){
            peers.append(.init(sourceIndex:index,polygon:polygon,measurement:measurements[index],missingLocalEvidence:true))
        }
        if let layout,layout.sourceWidth==frameSize.width,layout.sourceHeight==frameSize.height{
            for scope in layout.primitives where scope.sourceBounds.intersects(probeROI){
                rfRoles[String(scope.semanticClass.rawValue),default:0]+=1
            }
        }
        let record:[String:Any]=["scope":"bbox-probe-ROI-only","probeROI":[Double(probeROI.minX),Double(probeROI.minY),
            Double(probeROI.maxX),Double(probeROI.maxY)],"farMissingEvidenceIgnored":farMissing,
            "nearMissingEvidenceRetainedAsSoft":nearMissing,"localOriginalOwnersObserved":localOwners,
            "localKnownExternalCells":localCells,"localAmbiguousCompetingCells":uncertainCount,
            "RFLocalRoles":rfRoles,"RFBoundsAreGlyphMasks":false,"quadOverlapAloneVeto":false,
            "fullPagePeerCompletenessRequired":false,"actualResidualSources":sourceIndices,"ownershipMutated":false]
        return .init(evidence:.init(probeROI:probeROI,frameSize:frameSize,peers:peers,
            knownForeignCells:known,uncertainCells:uncertain,diagnostics:record),record:record)
    }
    static func quad(_ r:CGRect)->[CGPoint]{
        [.init(x:r.minX,y:r.minY),.init(x:r.maxX,y:r.minY),.init(x:r.maxX,y:r.maxY),.init(x:r.minX,y:r.maxY)]
    }
}


import Foundation

/// Diagnostic serialization only: no geometry, masks, classification or admission.
/// Summary is O(role/palette/ROI groups) retained memory. Packed rows retain EVERY
/// old diagnostic value; full dictionaries are allocated only on explicit request.
enum NativeOCRComponentDiagnostics371 {
    enum Mode: String { case summary, packed, full }
    struct Row {
        let pixels: Int
        let privatePixels: Int
        let bodyContactPixels: Int
        let paletteOrdinal: Int
        let roiContact: Bool
        let role: String
        let normalLow: Double
        let alongLow: Double
        let normalHigh: Double
        let alongHigh: Double
    }
    private struct Group: Hashable {
        let role: Int
        let palette: Int
        let open: Bool
    }
    private struct Totals {
        var count = 0
        var pixels = 0
        var privatePixels = 0
        var contactPixels = 0
        var qualified = 0
        var open = 0
        var minimumPixels: Int?
        var maximumPixels: Int?
        mutating func append(_ row: Row) {
            count += 1; pixels += row.pixels; privatePixels += row.privatePixels
            contactPixels += row.bodyContactPixels
            if row.role != "unqualified" && !row.roiContact { qualified += 1 }
            if row.roiContact { open += 1 }
            minimumPixels = min(minimumPixels ?? row.pixels, row.pixels)
            maximumPixels = max(maximumPixels ?? row.pixels, row.pixels)
        }
        var json: [String: Any] {
            ["componentCount": count, "pixelCountSum": pixels, "privatePixelCountSum": privatePixels,
             "bodyContactPixelCountSum": contactPixels, "qualifiedComponentCount": qualified,
             "unqualifiedOrOpenComponentCount": count - qualified, "ROIContactComponentCount": open,
             "minimumComponentPixels": minimumPixels as Any? ?? NSNull(),
             "maximumComponentPixels": maximumPixels as Any? ?? NSNull()]
        }
    }
    static let rowColumns = ["pixels", "privatePixels", "bodyContactPixels", "paletteOrdinal", "ROIContact",
                             "roleID", "normalLow", "alongLow", "normalHigh", "alongHigh"]
    static let groupColumns = ["roleID", "paletteOrdinal", "ROIContact", "componentCount", "pixelCountSum",
                               "privatePixelCountSum", "bodyContactPixelCountSum", "qualifiedComponentCount"]

    /// One pass, no typed row array or per-component dictionary in default summary.
    /// Component iteration order is preserved in packed/full modes. Intern IDs are
    /// deterministic first-seen order and refer to the exact, unmodified role string.
    static func encode<C: Collection>(_ components: C, mode: Mode = .summary,
                                      row: (C.Element) -> Row) -> [String: Any] {
        var symbols: [String] = [], symbolIDs: [String: Int] = [:], groups: [Group: Totals] = [:]
        var totals = Totals(), packed: [[Any]] = [], full: [[String: Any]] = []
        if mode == .packed { packed.reserveCapacity(components.count) }
        if mode == .full { full.reserveCapacity(components.count) }
        var lowN = Double.infinity, lowA = Double.infinity, highN = -Double.infinity, highA = -Double.infinity
        var finiteBounds = 0
        for component in components {
            let r = row(component)
            let roleID: Int
            if let existing = symbolIDs[r.role] { roleID = existing }
            else { roleID = symbols.count; symbols.append(r.role); symbolIDs[r.role] = roleID }
            let key = Group(role: roleID, palette: r.paletteOrdinal, open: r.roiContact)
            totals.append(r)
            var bucket = groups[key] ?? Totals(); bucket.append(r); groups[key] = bucket
            if r.normalLow.isFinite && r.alongLow.isFinite && r.normalHigh.isFinite && r.alongHigh.isFinite {
                finiteBounds += 1
                lowN = min(lowN, r.normalLow); lowA = min(lowA, r.alongLow)
                highN = max(highN, r.normalHigh); highA = max(highA, r.alongHigh)
            }
            if mode == .packed {
                packed.append([r.pixels, r.privatePixels, r.bodyContactPixels, r.paletteOrdinal, r.roiContact,
                               roleID, r.normalLow, r.alongLow, r.normalHigh, r.alongHigh])
            } else if mode == .full {
                full.append(["pixels": r.pixels, "privatePixels": r.privatePixels,
                             "bodyContactPixels": r.bodyContactPixels, "paletteOrdinal": r.paletteOrdinal,
                             "ROIContact": r.roiContact, "role": r.role,
                             "projectedBounds": [r.normalLow, r.alongLow, r.normalHigh, r.alongHigh]])
            }
        }
        let keys = groups.keys.sorted {
            if $0.role != $1.role { return $0.role < $1.role }
            if $0.palette != $1.palette { return $0.palette < $1.palette }
            return !$0.open && $1.open
        }
        let groupRows: [[Any]] = keys.map { key in
            let t = groups[key]!
            return [key.role, key.palette, key.open, t.count, t.pixels, t.privatePixels, t.contactPixels, t.qualified]
        }
        var summary = totals.json
        summary["groupColumns"] = groupColumns; summary["groups"] = groupRows
        summary["roleSymbols"] = symbols; summary["finiteProjectedBoundsCount"] = finiteBounds
        summary["nonfiniteProjectedBoundsCount"] = totals.count - finiteBounds
        if finiteBounds == 0 { summary["observedProjectedEnvelope"] = NSNull() }
        else { summary["observedProjectedEnvelope"] = [lowN, lowA, highN, highA] }
        summary["sumSemantics"] = "Sum over palette-component observations; overlapping palettes can count the same source pixel repeatedly. Not unique pixel counts, ownership, or a glyph inventory."
        var output: [String: Any] = ["componentDiagnosticVersion": 371, "componentDiagnosticMode": mode.rawValue,
                                   "componentSummary371": summary,
                                   "componentRowsOmitted": mode == .summary ? totals.count : 0,
                                   "componentRowOrder": "exact-native-component-iteration-order",
                                   "geometryOrPixelAlgorithmChanged": false]
        if mode == .packed {
            output["componentSchema371"] = ["name": "palette-component-row-v1", "columns": rowColumns,
                "types": ["integer", "integer", "integer", "integer", "boolean", "role-symbol-index",
                          "Float64", "Float64", "Float64", "Float64"],
                "roleSymbols": symbols, "losslessRelativeTo": "369-full-component-diagnostic-dictionaries"]
            output["componentRows371"] = packed
        } else if mode == .full { output["components"] = full }
        return output
    }
}

import Foundation

/// Isolated proposal, parent owns integration/build. Necessary ONLY, no admission.
/// OR of the five frozen pilot leaves simplifies to these TWO broad source classes.
/// Must use immutable native pre-coordinator source22 snapshot, not final-box features.
enum NativeOCRSourceLocalJoint369Preflight {
    static func mayGenerate(_ source22: [Double]) -> Bool {
        guard source22.count >= 22, source22.prefix(22).allSatisfy(\.isFinite) else { return false }
        return source22[3] < 0.85 || (source22[1] > 10 && source22[1] <= 20)
    }
}

import Foundation
import CoreGraphics

/// Source-only PROPOSAL factory. No Measurement/private palette/mask is created.
/// Parent owns compilation, native capture, safe() and semantic/admission wiring.
@available(iOS 18.0, *)
enum NativeOCRNonexclusiveLane369 {
    typealias E = NativeOCRDetectorSeedEvidence
    struct RGBWindow {
        let origin: CGPoint
        let width: Int
        let height: Int
        let bytes: [UInt8] // tightly packed RGBA from ORIGINAL frame, never a palette substitute
    }
    struct Receipt {
        let status = "nonexclusive"
        let privateObservationCreated = false
        let ownershipMutated = false
        var seedRoleSamples: [String:Int] = [:]
        var anchorPixels = 0
        var selectedRGBComponents = 0
        var selectedRGBPixels = 0
        var alongClusters = 0
        var sameRFTextAndBubble = false
        var nonexclusivePaletteBins: [Int] = []
        var requestedROI: CGRect = .zero
        var rejection: String?
    }
    struct Offer {
        let candidate: NativeOCRResidualCandidate
        let wholePriorContained: Bool
        let observedRGBPixelContainment: Bool
        let mandatoryPointContainment: Bool
        let localGuardRejection: String?
        /// nil means pending actual native admission, not accepted.
        var nativeAdmission: Bool? = nil
        var nativeRejection: String? = nil
    }
    struct Result {
        var receipt: Receipt
        var offers: [Offer]
        /// These are actual raw sampled RGB pixel CENTERS, not hull-filled ownership.
        let observedRGBPoints: [CGPoint]
        let window: RGBWindow?
    }
    struct C { let pixels: [Int]; let n0: CGFloat; let n1: CGFloat; let a0: CGFloat; let a1: CGFloat; let hits: Int }
    static func inside(_ q: [CGPoint], _ p: CGPoint) -> Bool {
        guard q.count >= 3 else {return false}
        var positive = true, negative = true
        for i in q.indices {
            let a=q[i],b=q[(i+1)%q.count]
            let c=(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
            if c < -1e-7 {positive=false}; if c > 1e-7 {negative=false}
        }
        return positive || negative
    }
    static func bounds(_ q: [CGPoint]) -> CGRect {
        guard let x0=q.map(\.x).min(),let x1=q.map(\.x).max(),let y0=q.map(\.y).min(),let y1=q.map(\.y).max() else {return .null}
        return .init(x:x0,y:y0,width:x1-x0,height:y1-y0)
    }
    static func valid(_ q: [CGPoint]) -> Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        let o=q[0]
        let area=abs(q.indices.reduce(CGFloat(0)) { sum,i in
            let a=q[i],b=q[(i+1)%4]
            return sum+(a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x)
        })*0.5
        return area.isFinite && area>1e-6 && q.allSatisfy { p in inside(q,p) }
    }
    /// Lazy DEFAULT-OFF entry; disabled means no frame/evidence provider evaluation.
    static func capture(enabled: Bool, prior: [CGPoint],
                        consumedIndices: [Int], associationKey: String?,
                        mandatory: [CGPoint], peerOwnedPoints: [CGPoint],
                        rfText: [[CGPoint]], rfBubbles: [[CGPoint]],
                        evidence: () -> [E], frameProvider: () -> NativeOCRRGBAFrame?) -> Result? {
        guard enabled,valid(prior),mandatory.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              peerOwnedPoints.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return nil}
        let es=evidence()
        guard !es.isEmpty,es.count<=64,es.allSatisfy({$0.isValid}),let frame=frameProvider(),
              es.allSatisfy({$0.sourceWidth==frame.width && $0.sourceHeight==frame.height}),
              (prior+mandatory).allSatisfy({$0.x>=0 && $0.y>=0 && $0.x<=CGFloat(frame.width) && $0.y<=CGFloat(frame.height)}) else{return nil}
        let b=bounds(prior), roi=b.insetBy(dx:-b.width*0.15,dy:-b.height*0.15)
        let x0=max(0,Int(floor(roi.minX))),y0=max(0,Int(floor(roi.minY)))
        let x1=min(frame.width,Int(ceil(roi.maxX))),y1=min(frame.height,Int(ceil(roi.maxY)))
        guard x1>x0,y1>y0,(x1-x0)<=600000/(y1-y0) else{return nil}
        let w=x1-x0,h=y1-y0
        var bytes=[UInt8](repeating:0,count:w*h*4)
        for y in 0..<h {
            let start=(y+y0)*frame.bytesPerRow+x0*4
            bytes.replaceSubrange(y*w*4..<(y+1)*w*4,with:frame.bytes[start..<(start+w*4)])
        }
        let window=RGBWindow(origin:.init(x:x0,y:y0),width:w,height:h,bytes:bytes)
        return generate(prior:prior,consumedIndices:consumedIndices,associationKey:associationKey,
            mandatory:mandatory,peerOwnedPoints:peerOwnedPoints,rfText:rfText,rfBubbles:rfBubbles,evidence:es,window:window)
    }
    /// Accepts only bounded actual RGBA + original native evidence. No GT or image IDs.
    static func generate(prior: [CGPoint],consumedIndices: [Int],associationKey: String?,
                         mandatory: [CGPoint],peerOwnedPoints: [CGPoint],
                         rfText: [[CGPoint]],rfBubbles: [[CGPoint]],evidence: [E],window: RGBWindow) -> Result {
        var receipt=Receipt()
        func stopped(_ reason:String)->Result {
            receipt.rejection=reason
            return .init(receipt:receipt,offers:[],observedRGBPoints:[],window:window)
        }
        guard valid(prior),mandatory.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              !evidence.isEmpty,evidence.count<=64,evidence.allSatisfy({$0.isValid}),
              window.origin.x.isFinite,window.origin.y.isFinite,
              window.origin.x.rounded(.down)==window.origin.x,window.origin.y.rounded(.down)==window.origin.y,
              window.width>0,window.height>0,window.width<=600000/window.height,
              window.bytes.count==window.width*window.height*4,
              peerOwnedPoints.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              mandatory.count<=262144,peerOwnedPoints.count<=262144 else{return stopped("invalid-input")}
        let e1=CGPoint(x:prior[1].x-prior[0].x,y:prior[1].y-prior[0].y)
        let e3=CGPoint(x:prior[3].x-prior[0].x,y:prior[3].y-prior[0].y)
        let edge=hypot(e1.x,e1.y)>=hypot(e3.x,e3.y) ? e1:e3
        let len=hypot(edge.x,edge.y)
        let u=CGPoint(x:edge.x/len,y:edge.y/len),n=CGPoint(x:u.y,y:-u.x)
        let o=CGPoint(x:prior.map(\.x).reduce(0,+)/4,y:prior.map(\.y).reduce(0,+)/4)
        func project(_ p:CGPoint)->CGPoint {let x=p.x-o.x,y=p.y-o.y;return .init(x:x*n.x+y*n.y,y:x*u.x+y*u.y)}
        func restore(_ x:CGFloat,_ y:CGFloat)->CGPoint {.init(x:o.x+x*n.x+y*u.x,y:o.y+x*n.y+y*u.y)}
        let local=bounds(prior.map(project)),pw=local.width,ph=local.height
        let cols=window.width,rows=window.height,count=cols*rows
        let roi=CGRect(origin:window.origin,size:.init(width:cols,height:rows))
        receipt.requestedROI=roi
        guard pw>=5,ph>=5 else{return stopped("roi-or-size-budget")}
        func world(_ p:Int)->CGPoint {.init(x:window.origin.x+CGFloat(p%cols)+0.5,y:window.origin.y+CGFloat(p/cols)+0.5)}
        var anchors=Set<Int>(),scanned=0
        for e in evidence {
            let sx=CGFloat(e.sourceWidth)/CGFloat(e.mapFullWidth),sy=CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight)
            let inventories:[(String,[E.Component])]=[("owned",e.components),("candidate",(e.candidateComponents ?? []).map(\.component)),("ambiguous",e.ambiguousComponents ?? [])]
            for (role,cs) in inventories {for c in cs {for r in c.runs {
                let wy=(CGFloat(r.y)+0.5)*sy
                if wy<roi.minY || wy>=roi.maxY {continue}
                for x in r.x..<(r.x+r.count) {
                    scanned+=1;if scanned>500000{return stopped("DB-scan-budget")}
                    let p=CGPoint(x:(CGFloat(x)+0.5)*sx,y:wy),v=project(p)
                    if p.x>=roi.minX,p.x<roi.maxX,inside(prior,p),abs(v.x)<=pw*0.4 {
                        let ix=Int(floor(p.x-roi.minX)),iy=Int(floor(p.y-roi.minY))
                        anchors.insert(iy*cols+ix);receipt.seedRoleSamples[role,default:0]+=1
                    }
                }
            }}}
        }
        receipt.anchorPixels=anchors.count
        guard anchors.count>=8 else{return stopped("fewer-than8-real-DB-anchor-pixels")}
        var histogram:[Int:Int]=[:]
        for p in anchors.sorted() {
            let x=p%cols,y=p/cols
            for (dx,dy) in [(0,0),(-2,0),(2,0),(0,-2),(0,2)] {
                let xx=x+dx,yy=y+dy
                if xx>=0,xx<cols,yy>=0,yy<rows {
                    let b=(yy*cols+xx)*4
                    guard window.bytes[b+3]>0 else{continue}
                    let key=(Int(window.bytes[b])/32)*64+(Int(window.bytes[b+1])/32)*8+Int(window.bytes[b+2])/32
                    histogram[key,default:0]+=1
                }
            }
        }
        let bins=histogram.keys.sorted { a,b in histogram[a] != histogram[b] ? histogram[a]!>histogram[b]! : a<b }.prefix(4).filter {histogram[$0]!>=4}
        receipt.nonexclusivePaletteBins=Array(bins)
        let center=anchors.map {project(world($0)).x}.sorted()[anchors.count/2]
        var cc:[C]=[]
        for key in bins {
            let palette=[(key/64)*32+16,((key/8)%8)*32+16,(key%8)*32+16]
            var active=[UInt8](repeating:0,count:count),seen=active
            for p in 0..<count {
                let b=p*4
                if window.bytes[b+3]>0 && (0..<3).allSatisfy({abs(Int(window.bytes[b+$0])-palette[$0])<=32}) {active[p]=1}
            }
            for first in 0..<count where active[first] != 0 && seen[first]==0 {
                var queue=[first],head=0;seen[first]=1
                while head<queue.count {
                    let p=queue[head];head+=1;let x=p%cols,y=p/cols
                    for dy in -1...1 {for dx in -1...1 {
                        let xx=x+dx,yy=y+dy
                        if xx>=0,xx<cols,yy>=0,yy<rows {
                            let q=yy*cols+xx
                            if active[q] != 0 && seen[q]==0 {seen[q]=1;queue.append(q)}
                        }
                    }}
                }
                if queue.count<3 {continue}
                if queue.contains(where:{$0%cols==0 || $0%cols==cols-1 || $0/cols==0 || $0/cols==rows-1}) {continue}
                var n0=CGFloat.infinity,n1 = -CGFloat.infinity,a0=CGFloat.infinity,a1 = -CGFloat.infinity,hits=0
                for p in queue {
                    let v=project(world(p));n0=min(n0,v.x);n1=max(n1,v.x);a0=min(a0,v.y);a1=max(a1,v.y)
                    if anchors.contains(p){hits+=1}
                }
                if n1-n0>pw*1.25 || a1-a0>max(pw*3,ph*1.1) || abs((n0+n1)*0.5-center)>pw*0.4 {continue}
                cc.append(.init(pixels:queue,n0:n0,n1:n1,a0:a0,a1:a1,hits:hits))
            }
        }
        var selected=cc.indices.filter {cc[$0].hits>0},changed=true
        while changed {
            changed=false
            for i in cc.indices where !selected.contains(i) {
                let c=cc[i]
                if selected.contains(where:{ j in
                    let other=cc[j]
                    return max(c.a0-other.a1,other.a0-c.a1,0)<=pw && abs((c.n0+c.n1-other.n0-other.n1)*0.5)<=pw*0.35
                }) {selected.append(i);changed=true}
            }
        }
        let pixels=Set(selected.flatMap {cc[$0].pixels}).sorted(),body=pixels.map(world)
        receipt.selectedRGBComponents=selected.count;receipt.selectedRGBPixels=pixels.count
        let intervals=selected.map {(cc[$0].a0,cc[$0].a1)}.sorted { $0.0 != $1.0 ? $0.0<$1.0 : $0.1<$1.1 }
        var clusters:[(CGFloat,CGFloat)]=[]
        for (a,b) in intervals {
            if let last=clusters.last,a<=last.1+1 {clusters[clusters.count-1].1=max(last.1,b)}
            else {clusters.append((a,b))}
        }
        receipt.alongClusters=clusters.count
        let rfOK=rfText.contains {q in valid(q) && prior.allSatisfy {inside(q,$0)}} && rfBubbles.contains {q in valid(q) && prior.allSatisfy {inside(q,$0)}}
        receipt.sameRFTextAndBubble=rfOK
        guard pixels.count>=24,clusters.count>=2 || rfOK else{return stopped("insufficient-repeated-glyph-or-localRF-support")}
        var offers:[Offer]=[]
        for enclosing in [false,true] {
            let points=body+mandatory+(enclosing ? prior:[]),lb=bounds(points.map(project))
            for pad in [1,2,3] {
                let r=lb.insetBy(dx:-CGFloat(pad),dy:-CGFloat(pad))
                let q=[restore(r.minX,r.minY),restore(r.maxX,r.minY),restore(r.maxX,r.maxY),restore(r.minX,r.maxY)]
                var reason:String?
                if !q.allSatisfy({$0.x>=roi.minX && $0.x<=roi.maxX && $0.y>=roi.minY && $0.y<=roi.maxY}) {reason="proposal-outside-observedROI"}
                if peerOwnedPoints.contains(where:{inside(q,$0) && !inside(prior,$0)}) {reason="new-exclusive-peer-acquisition"}
                let candidate=NativeOCRResidualCandidate(key:"nonexclusive-lane-v1-"+(enclosing ? "enclose":"fit")+"-px"+String(pad),polygon:q,
                    consumedIndices:consumedIndices,supportPoints:mandatory,associationKey:associationKey)
                offers.append(.init(candidate:candidate,wholePriorContained:prior.allSatisfy {inside(q,$0)},
                    observedRGBPixelContainment:body.allSatisfy {inside(q,$0)},mandatoryPointContainment:mandatory.allSatisfy {inside(q,$0)},localGuardRejection:reason))
            }
        }
        return .init(receipt:receipt,offers:offers,observedRGBPoints:body,window:window)
    }
    /// Native safety callback is mandatory for admission. No missing-private bypass.
    /// Caller must run OLD safe+semantic+real full children/caps/peer keepouts and
    /// actual root/member RGB outline/body/terminal veto (nonexclusive role explicit).
    static func admit(_ result: Result,
                      nativeGuard: (NativeOCRResidualCandidate,Result)->String?) -> Result {
        var out=result
        for i in out.offers.indices {
            if let reason=out.offers[i].localGuardRejection {
                out.offers[i].nativeAdmission=false;out.offers[i].nativeRejection=reason
            } else {
                let reason=nativeGuard(out.offers[i].candidate,result)
                out.offers[i].nativeAdmission=reason==nil;out.offers[i].nativeRejection=reason
            }
        }
        return out
    }
}

import Foundation
import CoreGraphics

/// Export-only post-coordinator splice. NO private/measured precondition, no
/// selector/output/graph mutation. Parent compiles and enables capture explicitly.
@available(iOS 18.0, *)
enum NativeOCRNonexclusiveLane369BankSplice {
    typealias Factory = NativeOCRNonexclusiveLane369
    typealias Graph = NativeOCRSourceLocalJoint369Capture.FinalGraph
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    struct Output {
        let candidates: [NativeOCRResidualCandidate]
        let record: [String:Any]
        /// Same bounded ORIGINAL pixels may feed other nonexclusive factories.
        /// This is not a Body.Evidence/private palette/ownership mask.
        let rawWindow: Factory.RGBWindow?
    }
    static func quad(_ r: CGRect) -> [CGPoint] {
        [.init(x:r.minX,y:r.minY),.init(x:r.maxX,y:r.minY),
         .init(x:r.maxX,y:r.maxY),.init(x:r.minX,y:r.maxY)]
    }
    /// Diagnostic ONLY, zero frame reads. Routing below uses the ACTUAL
    /// captureLive result, not this metadata-only readiness test.
    static func privateBodyAvailability(root:Int,graph:Graph,measurements:[Int:M],
                                        frameSize:CGSize)->[String:Any] {
        guard let prior=graph.prior(root) else{return ["metadataPreparationAvailable":false,"reason":"missing-final-prior"]}
        var rows:[[String:Any]]=[]
        var available=true
        for index in [root]+prior.consumedIndices {
            guard let m=measurements[index] else {
                available=false;rows.append(["sourceIndex":index,"reason":"missing-measurement"]);continue
            }
            let p=m.privateObservation
            let prepared=NativeOCRSourceAuthenticatedBodyEvidence.prepare(m,inherited:prior.polygon,
                frameSize:.init(width:Int(frameSize.width),height:Int(frameSize.height)),enabled:true)
            if prepared.prepared==nil {available=false}
            rows.append(["sourceIndex":index,"measurementStatus":m.status,
                "observationPresent":p != nil,"footprintPresent":p?.footprint != nil,
                "footprintCells":p?.footprint?.cells.count as Any? ?? NSNull(),
                "privateRGBSamples":p?.privateRGBSamples as Any? ?? NSNull(),
                "missingPrivateRGBPixels":p?.missingPrivateRGBPixels as Any? ?? NSNull(),
                "nativeBodyPrepareStatus":prepared.status])
        }
        return ["metadataPreparationAvailable":available,"sources":rows,
            "metadataPreparationIsActualBodyProof":false,"frameReads":0]
    }
    static func capture(root: Int, graph: Graph,
                        originals: [NativeCoreMLDetectionBox], measurements: [Int:M],
                        originalFrame: NativeOCRRGBAFrame,
                        scopes: [NativeOCRSourceLocalJoint369.Scope],
                        capsForSource: (M)->[CGPoint]?, originalOwnedSupport: (Int)->[CGPoint],
                        accepts: (Int,[CGPoint])->Bool,
                        includeOriginalRGBA: Bool = false) -> Output {
        let family="nonexclusive-lane369"
        func failure(_ reason:String)->Output {
            .init(candidates:[],record:["sourceIndex":root,"family":family,"evidenceRole":"nonexclusive",
                "geometryProposed":false,"admitted":false,"hardRejections":[reason],
                "outputOrGraphMutated":false],rawWindow:nil)
        }
        guard let prior=graph.prior(root),let rootM=measurements[root],
              Factory.valid(prior.polygon) else{return failure("missing-actual-final-prior")}
        let bound=Factory.bounds(prior.polygon)
        let probe=bound.insetBy(dx:-bound.width*0.15,dy:-bound.height*0.15)
        let roi=CGRect(x:max(0,floor(probe.minX)),y:max(0,floor(probe.minY)),
            width:min(CGFloat(originalFrame.width),ceil(probe.maxX))-max(0,floor(probe.minX)),
            height:min(CGFloat(originalFrame.height),ceil(probe.maxY))-max(0,floor(probe.minY)))
        guard !roi.isEmpty,roi.width*roi.height<=600000 else{return failure("local-RGB-budget")}
        let sourceIndices=[root]+prior.consumedIndices
        // Expands original representation ONLY. These are not additional residual children.
        func leaves(_ seeds:[Int])->Set<Int>? {
            var found=Set<Int>(),pending=seeds,visited=Set<Int>()
            while let index=pending.popLast() {
                guard visited.count<=4096 else{return nil}
                if !visited.insert(index).inserted {continue}
                if let members=graph.groups[index],!members.isEmpty {
                    pending+=members.filter{$0 != index}
                    if members.contains(index),originals.indices.contains(index){found.insert(index)}
                } else if originals.indices.contains(index) {found.insert(index)}
            }
            return found
        }
        guard let ownLeaves=leaves(sourceIndices),
              let externalLeaves=leaves(graph.live.filter{$0 != root}.flatMap{[$0]+(graph.applied[$0]?.consumedIndices ?? [])}) else {
            return failure("original-representation-budget")
        }
        var mandatory=prior.candidate?.supportPoints ?? [],complete=true
        for source in sourceIndices {
            guard let m=measurements[source],let caps=capsForSource(m) else {complete=false;continue}
            mandatory+=caps+originalOwnedSupport(source)+m.guardPoints+m.privateHull.map(m.restore)
        }
        var direct:[NativeOCRDetectorSeedEvidence]=[],nearby:[NativeOCRDetectorSeedEvidence]=[]
        var peers:[CGPoint]=[],unresolved:[CGRect]=[],invalidLocal=0,legacyPeerInventories=0
        for (index,box) in originals.enumerated() {
            let near=Factory.valid(box.polygon) && Factory.bounds(box.polygon).intersects(roi)
            guard let e=box.detectorSeedEvidence,e.isValid,e.parentBoxIndex==index,
                  e.sourceWidth==originalFrame.width,e.sourceHeight==originalFrame.height else {
                if near && !ownLeaves.contains(index){unresolved.append(Factory.bounds(box.polygon));invalidLocal+=1}
                continue
            }
            if ownLeaves.contains(index){direct.append(e)}
            if near{nearby.append(e)}
            // V2 builder invariant (production NativeOCRDBOwnershipCandidates.swift):
            // touched.count == 1 && counts[offset] == queue.count -> independent;
            // only independent[index] becomes original e.components. Unique-full
            // but multiply touched goes to candidateComponents; all others ambiguous.
            // Component has NO ownerBoxIndex/candidateBoxIndices fields. e.isValid +
            // parentBoxIndex and ORIGINAL builder provenance bind this role to e.ownerID.
            // This is never a Context supportView/provisional measurement inventory.
            // Legacy v1 does not provide that v2 complete-scan proof: keep it as
            // observation/uncertainty, NOT a newly authenticated exclusive peer.
            let exclusiveV2 = e.ownershipVersion==2 && e.completeCCScan==true &&
                e.provenance=="db-complete-cc-candidates-v2"
            if !exclusiveV2 && near && (!ownLeaves.contains(index) || externalLeaves.contains(index)) {
                legacyPeerInventories+=1;unresolved.append(Factory.bounds(box.polygon))
            }
            // Actual exclusive V2 components ONLY. Never candidate/ambiguous arrays.
            if exclusiveV2 && (!ownLeaves.contains(index) || externalLeaves.contains(index)) {
                let sx=CGFloat(e.sourceWidth)/CGFloat(e.mapFullWidth),sy=CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight)
                for c in e.components {for r in c.runs {
                    let y=(CGFloat(r.y)+0.5)*sy
                    if y<roi.minY || y>=roi.maxY{continue}
                    let left=max(r.x,Int(floor(roi.minX/sx))),right=min(r.x+r.count,Int(ceil(roi.maxX/sx)))
                    if right>left {for x in left..<right {
                        peers.append(.init(x:(CGFloat(x)+0.5)*sx,y:y))
                        if peers.count>262144{return failure("local-peer-owned-budget")}
                    }}
                }}
            }
        }
        let es=direct.isEmpty ? nearby:direct
        guard !es.isEmpty,es.count<=64 else{return failure("no-valid-local-original-CC-inventory")}
        let texts=scopes.filter{$0.semanticClass==0 && $0.confidence>=0.8}.map{quad($0.rect)}
        let bubbles=scopes.filter{$0.semanticClass==2 && $0.confidence>=0.6}.map{quad($0.rect)}
        guard let generated=Factory.capture(enabled:true,prior:prior.polygon,
            consumedIndices:prior.consumedIndices,associationKey:prior.inheritedAssociationKey,
            mandatory:mandatory,peerOwnedPoints:peers,rfText:texts,rfBubbles:bubbles,
            evidence:{es},frameProvider:{originalFrame}) else{return failure("nonexclusive-capture-unavailable")}
        // First integrated menu has EXACTLY THREE enclosing keys. Fit remains separate.
        let enclosing=Factory.Result(receipt:generated.receipt,
            offers:generated.offers.filter{$0.candidate.key.hasPrefix("nonexclusive-lane-v1-enclose-")},
            observedRGBPoints:generated.observedRGBPoints,window:generated.window)
        var checks:[String:[[String:Any]]]=[:]
        let checked=Factory.admit(enclosing) { candidate, result in
            let q=candidate.polygon
            guard complete else{return "missing-actual-root-member-guards-or-caps"}
            guard candidate.consumedIndices==prior.consumedIndices,
                  candidate.associationKey==prior.inheritedAssociationKey,
                  prior.polygon.allSatisfy({Factory.inside(q,$0)}) else{return "changed-graph-or-not-prior-enclosing"}
            // Current entire quad preserved: ALL current body/outline/terminal pixels
            // inside that convex quad remain. This is a geometric proof, not a no-veto
            // result or fabricated private evidence. Mandatory points outside old also kept.
            for source in sourceIndices {
                guard let m=measurements[source],let caps=capsForSource(m) else{return "missing-current-source-caps"}
                guard NativeOCRResidualCandidateBank.safe(candidate,measurement:m,caps:caps,
                    width:originalFrame.width,height:originalFrame.height) else{return "actual-root-member-old-safe"}
                guard accepts(source,q) else{return "actual-root-member-semantic"}
            }
            // A nearby missing owner record blocks ONLY actual newly acquired area.
            for r in unresolved {
                let new=NativeOCRDirectionGeometry.intersectionArea(q,quad(r))
                let old=NativeOCRDirectionGeometry.intersectionArea(prior.polygon,quad(r))
                if new>old+1 {return "new-acquisition-near-unresolved-original"}
            }
            // Reject substantial NEW side-column pickup. Same-column continuation is
            // not reclassified as a foreign column by its source ID or reading text.
            let p0=prior.polygon[0],e1=CGPoint(x:prior.polygon[1].x-p0.x,y:prior.polygon[1].y-p0.y)
            let e3=CGPoint(x:prior.polygon[3].x-p0.x,y:prior.polygon[3].y-p0.y)
            let e=hypot(e1.x,e1.y)>=hypot(e3.x,e3.y) ? e1:e3,l=hypot(e.x,e.y)
            let n=CGPoint(x:e.y/l,y:-e.x/l),center=CGPoint(x:prior.polygon.map(\.x).reduce(0,+)/4,y:prior.polygon.map(\.y).reduce(0,+)/4)
            let normalValues: [CGFloat] = prior.polygon.map{($0.x-center.x)*n.x+($0.y-center.y)*n.y}
            let width=max(CGFloat(1),normalValues.max()!-normalValues.min()!)
            for peer in graph.live where peer != root {
                guard let pq=graph.polygons[peer],Factory.valid(pq),Factory.bounds(pq).intersects(roi) else{continue}
                let pc=CGPoint(x:pq.map(\.x).reduce(0,+)/4,y:pq.map(\.y).reduce(0,+)/4)
                let separation=abs((pc.x-center.x)*n.x+(pc.y-center.y)*n.y)
                if separation>width*0.5 {
                    let old=NativeOCRDirectionGeometry.intersectionArea(prior.polygon,pq),new=NativeOCRDirectionGeometry.intersectionArea(q,pq)
                    let scale=max(1,min(NativeOCRDirectionGeometry.area(pq),NativeOCRDirectionGeometry.area(q)))
                    if new-old>scale*0.1{return "substantial-new-side-peer-acquisition"}
                }
            }
            // Retain the same authentic RF bubble if it already encloses the old quad.
            let enclosingBubbles=bubbles.filter{b in prior.polygon.allSatisfy{Factory.inside(b,$0)}}
            if !enclosingBubbles.isEmpty && !enclosingBubbles.contains(where:{b in q.allSatisfy{Factory.inside(b,$0)}}) {
                return "new-acquisition-leaves-current-RF-bubble"
            }
            checks[candidate.key]=[["guard":"whole-actual-prior-quad-containment","passed":true,
                "protects":"all-inherited-body-outline-terminal-pixels-not-only-private"],
                ["guard":"actual-root-member-safe-semantic-caps","sourceCount":sourceIndices.count,"passed":true],
                ["guard":"new-exclusive-peer-cell-acquisition","testedPointCount":peers.count,"passed":true],
                ["guard":"actual-local-closed-RGB-CC-support","pixelCount":result.receipt.selectedRGBPixels,
                 "alongClusters":result.receipt.alongClusters,"evidenceRole":"nonexclusive","passed":true],
                ["guard":"new-side-peer-and-retained-RF-bubble","passed":true]]
            return nil
        }
        let records=checked.offers.map{offer -> [String:Any] in
            let c=offer.candidate
            return ["key":c.key,"polygon":c.polygon.map{[Double($0.x),Double($0.y)]},
                "consumedIndices":c.consumedIndices,"inheritedAssociationKey":c.associationKey as Any? ?? NSNull(),
                "supportPoints":c.supportPoints.map{[Double($0.x),Double($0.y)]},
                "evidenceRole":"nonexclusive","geometryProposed":true,"accepted":offer.nativeAdmission==true,
                "admitted":offer.nativeAdmission==true,"wholeCurrentPriorContained":offer.wholePriorContained,
                "rejection":offer.nativeRejection as Any? ?? NSNull(),"pixelChecks":checks[c.key] ?? []]
        }
        var window:[String:Any]=[:]
        if let w=checked.window {
            window=["origin":[Double(w.origin.x),Double(w.origin.y)],"width":w.width,"height":w.height,"stride":w.width*4,"format":"originalRGBA8"]
            if includeOriginalRGBA{window["base64"]=Data(w.bytes).base64EncodedString()}
        }
        return .init(candidates:checked.offers.filter{$0.nativeAdmission==true}.map(\.candidate),
            record:["sourceIndex":root,"family":family,"status":"nonexclusive","measurementStatus":rootM.status,
                "current368FinalPolygon":prior.polygon.map{[Double($0.x),Double($0.y)]},
                "actualResidualChildren":prior.consumedIndices,"actualAssociationKey":prior.inheritedAssociationKey as Any? ?? NSNull(),
                "actualRootMemberSupportComplete":complete,"sourceWindow":window,"candidates":records,
                "admittedCandidateCount":checked.offers.filter{$0.nativeAdmission==true}.count,
                "anchorPixels":checked.receipt.anchorPixels,"seedRoleSamples":checked.receipt.seedRoleSamples,
                "actualObservedRGBPixels":checked.receipt.selectedRGBPixels,"alongClusters":checked.receipt.alongClusters,
                "sourceRejection":checked.receipt.rejection as Any? ?? NSNull(),"unresolvedLocalOriginals":invalidLocal,"legacyPeerInventoriesUncertain":legacyPeerInventories,
                "peerOwnershipBasis":"original-v2-builder-components-only; no-perCC-owner-fields",
                "privateBodyAvailability":privateBodyAvailability(root:root,graph:graph,measurements:measurements,
                    frameSize:.init(width:originalFrame.width,height:originalFrame.height)),
                "actualSharedLiveSessionAvailable":false,"captureTrigger":"actual-shared-live-session-unavailable",
                "privateObservationCreated":false,"ownershipMutated":false,"outputOrGraphMutated":false,"automaticSelection":false],
            rawWindow:checked.window)
    }
}


/// Additional source-observation constraint for new proposals, not ownership.
/// Protects coherent contrast already included by the real prior. It never turns
/// a quad/hull into foreground and never adds observations outside that prior.
@available(iOS 18.0, *)
enum NativeOCRContrastSupport380 {
    typealias RGBA = NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA
    struct Basis {
        let origin: CGPoint
        let normal: CGPoint
        let along: CGPoint
        func project(_ p: CGPoint) -> CGPoint {
            let dx = p.x - origin.x, dy = p.y - origin.y
            return .init(x: dx * normal.x + dy * normal.y, y: dx * along.x + dy * along.y)
        }
        func restore(_ n: CGFloat, _ a: CGFloat) -> CGPoint {
            .init(x: origin.x + n * normal.x + a * along.x,
                  y: origin.y + n * normal.y + a * along.y)
        }
    }
    struct Edge {
        let index: Int
        let along: CGFloat
        let magnitude: Int
    }
    struct Observation {
        let rgba: RGBA
        let old: [CGPoint]
        let basis: Basis
        let oldLow: CGFloat
        let oldHigh: CGFloat
        let pixelRadius: CGFloat
        let threshold: Int
        let edges: [Edge]
        let qualifiedComponents: Int
        let referenceBodyPixels: Int
    }
    struct Proposal {
        let suffix: String
        let polygon: [CGPoint]
        let hard: [String]
        let soft: [String]
        let receipt: [String: Any]
    }
    static func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
        var positive = false, negative = false
        for i in q.indices {
            let a = q[i], b = q[(i + 1) % q.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            positive = positive || cross > 1e-7
            negative = negative || cross < -1e-7
        }
        return !(positive && negative)
    }
    static func observe(old: [CGPoint], rgba r: RGBA, bodyMask: [UInt8], sourceWidth: CGFloat) -> Observation? {
        let w = r.width, h = r.height
        guard old.count == 4, old.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              w > 2, h > 2, w <= 600_000 / h, r.bytesPerRow >= w * 4,
              h <= Int.max / r.bytesPerRow, r.bytes.count >= h * r.bytesPerRow, bodyMask.count == w * h,
              sourceWidth.isFinite, sourceWidth > 0 else { return nil }
        guard old.allSatisfy({ $0.x >= r.origin.x && $0.y >= r.origin.y &&
            $0.x <= r.origin.x + CGFloat(w) && $0.y <= r.origin.y + CGFloat(h) }) else { return nil }
        let e1 = CGPoint(x: old[1].x - old[0].x, y: old[1].y - old[0].y)
        let e3 = CGPoint(x: old[3].x - old[0].x, y: old[3].y - old[0].y)
        let e = hypot(e1.x, e1.y) >= hypot(e3.x, e3.y) ? e1 : e3
        let length = hypot(e.x, e.y)
        guard length.isFinite, length > 0 else { return nil }
        let along = CGPoint(x: e.x / length, y: e.y / length)
        let f = Basis(origin: .init(x: old.map(\.x).reduce(0, +) / 4,
                                  y: old.map(\.y).reduce(0, +) / 4),
                      normal: .init(x: along.y, y: -along.x), along: along)
        let oldAlong = old.map { f.project($0).y }
        var inside = [UInt8](repeating: 0, count: w * h)
        var gradients = [UInt16](repeating: 0, count: w * h)
        var bodyGradients: [Int] = []
        var referenceBodyPixels = 0
        func opaque(_ x: Int, _ y: Int) -> Bool { r.bytes[y * r.bytesPerRow + x * 4 + 3] == 255 }
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let p = CGPoint(x: r.origin.x + CGFloat(x) + 0.5, y: r.origin.y + CGFloat(y) + 0.5)
            guard contains(old, p), opaque(x, y) else { continue }
            inside[i] = 1
            let offset = y * r.bytesPerRow + x * 4
            var magnitude = 0
            // Original pixel differences in two dimensions also see the sides of
            // an inherited continuous stem; a closed colour component is unnecessary.
            for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard xx >= 0, yy >= 0, xx < w, yy < h, opaque(xx, yy) else { continue }
                let other = yy * r.bytesPerRow + xx * 4
                for c in 0..<3 { magnitude = max(magnitude, abs(Int(r.bytes[offset + c]) - Int(r.bytes[other + c]))) }
            }
            gradients[i] = UInt16(magnitude)
            if bodyMask[i] != 0 {
                referenceBodyPixels += 1
                if magnitude >= 6 { bodyGradients.append(magnitude) }
            }
        }}
        guard referenceBodyPixels > 0 else { return nil }
        bodyGradients.sort()
        let median = bodyGradients.isEmpty ? 60 : bodyGradients[bodyGradients.count / 2]
        let threshold = max(6, min(12, Int((Double(median) * 0.1).rounded())))
        let minimumComponent = max(3, min(8, Int((sourceWidth * 0.03).rounded())))
        var seen = [UInt8](repeating: 0, count: w * h), edges: [Edge] = []
        var qualifiedComponents = 0
        for seed in 0..<(w * h) where inside[seed] != 0 && seen[seed] == 0 && gradients[seed] >= threshold {
            var queue = [seed], cursor = 0
            seen[seed] = 1
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let x = i % w, y = i / w
                for yy in max(0, y - 1)...min(h - 1, y + 1) { for xx in max(0, x - 1)...min(w - 1, x + 1) {
                    let j = yy * w + xx
                    if inside[j] != 0 && seen[j] == 0 && gradients[j] >= threshold {
                        seen[j] = 1; queue.append(j)
                    }
                }}
            }
            guard queue.count >= minimumComponent else { continue }
            qualifiedComponents += 1
            for i in queue {
                let p = CGPoint(x: r.origin.x + CGFloat(i % w) + 0.5,
                                y: r.origin.y + CGFloat(i / w) + 0.5)
                edges.append(.init(index: i, along: f.project(p).y, magnitude: Int(gradients[i])))
            }
        }
        return .init(rgba: r, old: old, basis: f, oldLow: oldAlong.min()!, oldHigh: oldAlong.max()!,
                     pixelRadius: (abs(along.x) + abs(along.y)) * 0.5, threshold: threshold,
                     edges: edges, qualifiedComponents: qualifiedComponents, referenceBodyPixels: referenceBodyPixels)
    }
    static func proposals(core: [CGPoint], observation o: Observation) -> [Proposal] {
        guard core.count == 4, core.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let p = core.map(o.basis.project)
        let n0 = p.map(\.x).min()!, n1 = p.map(\.x).max()!
        let a0 = p.map(\.y).min()!, a1 = p.map(\.y).max()!
        let lost = o.edges.filter { $0.along < a0 - 1e-7 || $0.along > a1 + 1e-7 }
        let deep = lost.filter { $0.along < a0 - 1 || $0.along > a1 + 1 }
        guard lost.count >= 3, deep.count >= 2 else { return [] }
        let head = lost.min(by: { $0.along < $1.along })!, tail = lost.max(by: { $0.along < $1.along })!
        let low = min(a0, max(o.oldLow, head.along - o.pixelRadius))
        let high = max(a1, min(o.oldHigh, tail.along + o.pixelRadius))
        let raw = [o.basis.restore(n0, low), o.basis.restore(n1, low),
                   o.basis.restore(n1, high), o.basis.restore(n0, high)]
        var polygon = raw, best = CGFloat.infinity
        for reverse in [false, true] {
            let values = reverse ? Array(raw.reversed()) : raw
            for shift in 0..<4 {
                let q = (0..<4).map { values[($0 + shift) % 4] }
                let distance = zip(q, core).reduce(CGFloat(0)) { sum, pair in
                    sum + pow(pair.0.x - pair.1.x, 2) + pow(pair.0.y - pair.1.y, 2)
                }
                if distance < best { best = distance; polygon = q }
            }
        }
        let coreRetained = core.allSatisfy { contains(polygon, $0) }
        let oldContained = polygon.allSatisfy { contains(o.old, $0) }
        let residual = o.edges.filter { edge in
            let r = o.rgba
            let point = CGPoint(x: r.origin.x + CGFloat(edge.index % r.width) + 0.5,
                                y: r.origin.y + CGFloat(edge.index / r.width) + 0.5)
            return !contains(polygon, point)
        }.count
        func witness(_ edge: Edge) -> [String: Any] {
            let r = o.rgba, x = edge.index % r.width, y = edge.index / r.width
            let k = y * r.bytesPerRow + x * 4
            return ["localPixel": edge.index, "center": [Double(r.origin.x) + Double(x) + 0.5,
                Double(r.origin.y) + Double(y) + 0.5], "RGB": [Int(r.bytes[k]), Int(r.bytes[k + 1]), Int(r.bytes[k + 2])],
                "originalGradientMagnitude": edge.magnitude]
        }
        return [.init(suffix: "old-contrast-along-support", polygon: polygon,
            hard: coreRetained && residual == 0 ? [] : ["core-or-observed-contrast-not-retained"],
            soft: oldContained ? [] : ["new-corner-native-peer-readmission-required"],
            receipt: ["family": "original-contrast-support380", "threshold": o.threshold,
                "referenceBodyPixels": o.referenceBodyPixels, "qualifiedContrastComponents": o.qualifiedComponents,
                "actualOldContrastPixels": o.edges.count, "newlyExcludedContrastPixelsBefore": lost.count,
                "deeplyExcludedContrastPixelsBefore": deep.count, "newlyExcludedContrastPixelsAfter": residual,
                "sourceHeadWitness": witness(head), "sourceTailWitness": witness(tail),
                "actualPriorContainsNewQuad": oldContained, "coreRetained": coreRetained,
                "priorBoundsAreLimitsOnly": true, "foregroundOwnershipClaimed": false,
                "privateObservationCreated": false, "hullOrQuadRasterizedAsInk": false,
                "absoluteGlyphCompletenessClaimed": false, "blanketPriorSpanRetained": false])]
    }
}

@available(iOS 18.0, *)
extension NativeOCRContrastSupport380 {
    /// Conservative acquisition uncertainty, never a foreground/ownership mask.
    /// A real peer polygon alone is insufficient: require a coherent component
    /// of original RGB contrast in newly acquired pixels inside that peer region.
    static func acquiresCoherentPeerContrast382(old: [CGPoint], proposed: [CGPoint],
                                               peer: [CGPoint], rgba r: RGBA) -> Bool {
        guard old.count == 4, proposed.count == 4, peer.count == 4 else { return false }
        let left = max(0, Int(floor(max(proposed.map(\.x).min()!, peer.map(\.x).min()!) - r.origin.x)))
        let top = max(0, Int(floor(max(proposed.map(\.y).min()!, peer.map(\.y).min()!) - r.origin.y)))
        let right = min(r.width, Int(ceil(min(proposed.map(\.x).max()!, peer.map(\.x).max()!) - r.origin.x)))
        let bottom = min(r.height, Int(ceil(min(proposed.map(\.y).max()!, peer.map(\.y).max()!) - r.origin.y)))
        guard left < right, top < bottom else { return false }
        var eligible = Set<Int>()
        for y in top..<bottom { for x in left..<right {
            let p = CGPoint(x: r.origin.x + CGFloat(x) + 0.5, y: r.origin.y + CGFloat(y) + 0.5)
            let k = y * r.bytesPerRow + x * 4
            guard r.bytes[k + 3] == 255, contains(proposed, p), !contains(old, p), contains(peer, p) else { continue }
            var magnitude = 0
            for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard xx >= 0, yy >= 0, xx < r.width, yy < r.height else { continue }
                let j = yy * r.bytesPerRow + xx * 4
                for c in 0..<3 { magnitude = max(magnitude, abs(Int(r.bytes[k + c]) - Int(r.bytes[j + c]))) }
            }
            if magnitude >= 12 { eligible.insert(y * r.width + x) }
        }}
        while let seed = eligible.popFirst() {
            var queue = [seed], cursor = 0
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let x = i % r.width, y = i / r.width
                for yy in max(0, y - 1)...min(r.height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(r.width - 1, x + 1) {
                        let j = yy * r.width + xx
                        if eligible.remove(j) != nil { queue.append(j) }
                    }
                }
                if queue.count >= 3 { return true }
            }
        }
        return false
    }
}


/// ISOLATED PROPOSAL. Parent owns compilation/integration. NO GT/IDs/hash inputs.
/// Current pilot fit is provisional until new additional glyph veto is reflected
/// in actual admitted menus and every selected pair receives local physical review.
enum NativeOCRSourceLocalJoint369Ranker {
    struct RoleSummary {
        let pixelsByRole: [String: Int]
        let componentCount: Int
        let openComponents: Int
        // Source-derived CC aggregates, NEVER pixel ownership or complete-glyph truth.
    }
    struct Candidate {
        let key: String
        let polygon: [CGPoint]
        let normalMode: String
        let alongMode: String
        let qualifiedComponentCount: Int
        let observedSupportPixels: Int
        let minimumTerminalPairs: Int // minimum only among actually recorded pairs
        let priorEnclosureReceipt: Bool // actual native loss-check-skipped receipt
        let peerReceiptCount: Int
        // Caller supplies ONLY CURRENT native-admitted candidates with exact
        // generatedFromCurrent368 prior + actual applied children/association.
    }
    private static let sourceMedian: [Double] = [0.8834825770816445, 5.062012895372151, 0.9285714285714286, 0.934755131467346, 0.4369095670483487, 34.0, 0.23652886166491452, 0.06104182325267442, 0.0, 1.0, 0.009761487160640545, -0.0024590163934425997, 0.0, 0.0, 0.0, 0.0, 0.01652836861302976, 0.0033147563841946065, 0.06820690545802068, 0.07126902889923485, 0.0, 0.9148105806176985]
    private static let sourceScale: [Double] = [0.08433052159963239, 4.8138336464844045, 0.1713369438264336, 0.08833362743041107, 0.03356498943686115, 44.0, 0.7499997637452096, 98.9615993240245, 0.01, 1.0, 0.04806385954708406, 0.022391489927631843, 0.01, 0.01, 0.01, 0.01, 0.075, 0.05, 0.11014305477764404, 0.13174222157625043, 0.04550971136796134, 0.1648313552461218]
    private static let derivedMedian: [Double] = [-0.07719989684932677, -0.06972519111979425, 3.3306690738754696e-16, 0.0005682983276866027, 9.007111344826693e-06, 6.770847460736376e-36, -0.030824441742003217, 0.00014535112244438514, 0.9994830972810935, 0.9047206794570712, 0.7441554167859731, 0.7382506538256358, 0.9604011106019354, 0.0, 0.03320964749536178, 0.9380047101014629, 0.04710875649027382, 0.5129898714923073, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    private static let derivedScale: [Double] = [0.1923689311903112, 0.18878966344601256, 0.01227745605436964, 0.01, 0.01, 0.01, 0.09157429977320601, 0.01846856537732907, 0.012047509119249122, 0.16820146598370134, 0.3142427856940728, 0.16100160664849306, 0.11465202415959985, 0.01, 0.1055800883179446, 0.08490169780054568, 0.0890220413442821, 0.6089044875446846, 1.0, 0.01, 1.0, 0.01, 0.01, 0.01, 0.01, 1.0, 1.0, 0.01]
    private static let weights: [[Double]] = [
        [0.0, 0.0, 0.0, 0.0, 0.0, 0.1, -0.5, -0.1, 0.0, 0.0, 0.0, 0.0, -0.1, 0.0, 0.0, 0.0, -0.1, 0.0, 0.0, -0.5, 0.0, 0.0, 0.025, -0.125, 0.125, -1.5, -1.5, -2.5, 0.1, 0.0, 2.0, 0.25, -0.5, 0.0, 0.0, 0.0, 0.1, 0.0, 0.2, 0.0, 0.0, -0.1, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.2, 0.0],
        [0.0, 0.0, -0.5, 0.0, 0.0, 0.0, 0.0, -0.2, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0, 0.1, 0.1, 0.05, -0.125, 2.0, -3.0, -3.0, -5.0, 0.2, 0.0, 0.5, 2.0, 0.0, -0.5, 0.2, 0.2, 0.0, -0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 0.2, 0.0],
        [0.0, 0.0, -0.1, 0.0, 0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0, 0.0, -0.5, 0.5, 0.0, 0.0, 0.5, 0.1, -0.5, 2.0, -12.0, -0.75, -20.0, 0.2, 0.0, 2.0, 0.5, 0.0, -0.2, 0.0, 0.0, 0.2, -0.5, 0.0, -0.2, 0.0, -0.5, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.5, 0.0, 0.0, -0.5, 0.0, 0.5, -0.2, -0.2, 0.1, 0.0, 0.0, 0.05, -1.0, 0.25, -0.75, -6.0, -1.25, 0.025, 0.0, 0.5, 2.0, -0.5, 0.0, 0.0, 0.0, -0.5, 0.0, -0.1, 0.0, 0.0, 0.2, 0.0, 0.0, 0.0, -0.1, 0.0, 0.1, 0.0, 0.0],
        [-0.5, 0.0, 0.0, 0.0, 0.0, -0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.1, -0.1, 0.0, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, -0.5, 0.2, -0.25, 0.0625, -6.0, -3.0, -20.0, 0.025, 0.0, 1.0, 0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.2, 0.0, 0.0, -0.2, 0.0, 0.5, 0.1, 0.2, 0.0, 0.0, -0.5, 0.0],
        [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 0.0, 0.5, 0.0, 0.1, 0.0, -0.5, 0.0, -0.5, 0.05, -0.125, 2.0, -3.0, -1.5, -10.0, 0.2, 0.0, 0.5, 2.0, 0.1, 0.0, 0.0, 0.1, 0.5, 0.0, -0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.5, 0.0, 0.0, 0.0, -0.5],
        [-0.5, 0.0, 0.0, 0.0, 0.0, 0.0, -0.1, 0.0, -0.1, -0.1, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2, 0.0, 0.0, 0.025, -0.25, 4.0, -1.5, -0.75, -5.0, 0.4, 0.0, 0.25, 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.2, 0.0, -0.5, 0.0, -0.2, -0.5, 0.0, 0.0, 0.0, 0.0, 0.5, 0.0, -0.5],
        [0.0, 0.0, 0.0, 0.2, 0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, -0.5, 0.0, 0.2, 0.0, 0.0, -0.2, 0.0, 0.0, 0.4, -0.0625, 1.0, -0.75, -6.0, -5.0, 0.025, 0.0, 4.0, 0.5, 0.0, 0.0, 0.2, -0.5, 0.0, 0.0, 0.0, -0.5, 0.2, 0.0, 0.0, 0.0, 0.0, -0.2, 0.2, 0.0, 0.0, 0.0]
    ]
    private static let thresholds: [Double] = [-9.11039431, 1.35004981, 1.48649794, 1.66428963, 1.99480126, 4.45465652, 7.62333385, 1.39662266]
    static func mayGenerate(_ s: [Double]) -> Bool {
        s.count >= 22 && s.prefix(22).allSatisfy(\.isFinite) &&
        (s[3] < 0.85 || (s[1] > 10 && s[1] <= 20))
    }
    private static func gate(_ r: Int, _ s: [Double]) -> Bool {
        switch r {
        case 0: return (s[1] > 3.0 && s[1] <= 10.0)
        case 1: return (s[3] >= 0.85 && s[3] <= 1.05)
        case 2: return s[8] == 0.0 && s[2] < 0.85
        case 3: return s[5] > 64.0
        case 4: return s[8] == 0.0 && s[2] > 1.05
        case 5: return (s[2] >= 0.85 && s[2] <= 1.05)
        case 6: return s[5] > 64.0
        case 7: return s[2] > 1.05 && (s[3] >= 0.85 && s[3] <= 1.05)
        default: return false
        }
    }
    private static func classMatches(_ r: Int, _ c: Candidate, _ raw: [Double]?) -> Bool {
        switch r {
        case 0: return raw.map { $0[24] > 0.1 } ?? false
        case 1: return c.priorEnclosureReceipt
        case 2: return c.alongMode == "body"
        case 3: return c.normalMode != "keep" && c.alongMode == "keep"
        case 4: return c.alongMode == "head"
        case 5: return true
        case 6: return raw.map { $0[23] < -0.1 } ?? false
        case 7: return raw.map { $0[23] < -0.1 } ?? false
        default: return false
        }
    }
    static func preferredKey(source22 s: [Double], actual368Prior prior: [CGPoint],
                             roleSummary roles: RoleSummary, admitted: [Candidate]) -> String? {
        guard mayGenerate(s) else { return nil }
        let descriptors = admitted.map { descriptor(source22: s, prior: prior, candidate: $0, roles: roles) }
        var selected: String?
        for r in weights.indices where gate(r, s) {
            var bestScore = -Double.infinity
            var bestKey: String?
            for i in admitted.indices where classMatches(r, admitted[i], descriptors[i]) {
                guard let raw = descriptors[i], let f = normalized(raw), let value = score(f, rule: r) else { continue }
                // Strict > retains FIRST native producer order on tied scores.
                if value > bestScore { bestScore = value; bestKey = admitted[i].key }
            }
            if bestScore >= thresholds[r], let bestKey { selected = bestKey }
        }
        // Last matching rule wins, SAME actual368 context throughout, no recoord.
        return selected
    }
    static func score(_ f: [Double], rule: Int) -> Double? {
        guard f.count == 50, weights.indices.contains(rule), f.allSatisfy(\.isFinite) else { return nil }
        var total = 0.0
        // Contract: separate Double product then Double add, index order0..49.
        // Do not replace with SIMD/BLAS/FMA reductions before parity verification.
        for i in 0..<50 { let product = f[i] * weights[rule][i]; total = total + product }
        guard total.isFinite, (abs(total) * 1e8).isFinite else { return nil }
        return (floor(abs(total) * 1e8 + 0.5) / 1e8) * (total < 0 ? -1 : 1)
    }
    static func normalized(_ raw: [Double]) -> [Double]? {
        guard raw.count == 50, raw.allSatisfy(\.isFinite) else { return nil }
        var f = raw
        for i in 0..<22 { f[i] = max(-4, min(4, (raw[i] - sourceMedian[i]) / sourceScale[i])) }
        for i in 0..<28 { f[22+i] = max(-4, min(4, (raw[22+i] - derivedMedian[i]) / derivedScale[i])) }
        return f.allSatisfy(\.isFinite) ? f : nil
    }
    static func descriptor(source22 s: [Double], prior: [CGPoint], candidate c: Candidate,
                           roles: RoleSummary) -> [Double]? {
        guard s.count >= 22, s.prefix(22).allSatisfy(\.isFinite), prior.count == 4,
              c.polygon.count == 4, (prior+c.polygon).allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              ["keep","low","high","both"].contains(c.normalMode),
              ["keep","head","tail","body"].contains(c.alongMode),
              c.qualifiedComponentCount >= 0, c.observedSupportPixels >= 0,
              c.minimumTerminalPairs >= 0, c.peerReceiptCount >= 0,
              c.key == "source-local-joint369-normal-" + c.normalMode + "-along-" + c.alongMode,
              roles.componentCount >= 0, roles.openComponents >= 0,
              roles.pixelsByRole.values.allSatisfy({$0 >= 0}) else { return nil }
        let o = prior.map { (Double($0.x), Double($0.y)) }
        let q = c.polygon.map { (Double($0.x), Double($0.y)) }
        let e1 = (o[1].0-o[0].0, o[1].1-o[0].1), e2 = (o[3].0-o[0].0, o[3].1-o[0].1)
        let e = e1.0*e1.0+e1.1*e1.1 >= e2.0*e2.0+e2.1*e2.1 ? e1 : e2
        let length = sqrt(e.0*e.0+e.1*e.1)
        guard length > 0, length.isFinite else { return nil }
        let ax=e.0/length, ay=e.1/length, nx=ay, ny = -ax
        let ox=o.reduce(0.0){$0+$1.0}/4, oy=o.reduce(0.0){$0+$1.1}/4
        func bounds(_ points: [(Double,Double)]) -> (Double,Double,Double,Double) {
            var n0=Double.infinity, n1 = -Double.infinity, a0=Double.infinity, a1 = -Double.infinity
            for p in points {
                let x=p.0-ox, y=p.1-oy, n=x*nx+y*ny, a=x*ax+y*ay
                n0=min(n0,n); n1=max(n1,n); a0=min(a0,a); a1=max(a1,a)
            }
            return (n0,n1,a0,a1)
        }
        let old=bounds(o), new=bounds(q), w=old.1-old.0, h=old.3-old.2
        let pa=area(o), qa=area(q), inter=area(clip(q, to:o))
        guard w > 0, h > 0, pa > 0, qa > 0, pa+qa-inter > 0 else { return nil }
        let nr=(new.1-new.0)/w, ar=(new.3-new.2)/h
        let ns=((new.1+new.0)-(old.1+old.0))/(2*w)
        let als=((new.3+new.2)-(old.3+old.2))/(2*h)
        let qe1=(q[1].0-q[0].0,q[1].1-q[0].1), qe2=(q[3].0-q[0].0,q[3].1-q[0].1)
        let qe=qe1.0*qe1.0+qe1.1*qe1.1 >= qe2.0*qe2.0+qe2.1*qe2.1 ? qe1 : qe2
        let qlen=sqrt(qe.0*qe.0+qe.1*qe.1)
        guard qlen > 0 else { return nil }
        let cross=(qe.0/qlen)*ay-(qe.1/qlen)*ax
        let total=roles.pixelsByRole.values.reduce(0.0){$0+Double($1)}
        let qualified=roles.pixelsByRole.reduce(0.0){$0+($1.key == "unqualified" ? 0 : Double($1.value))}
        func part(_ role: String) -> Double { Double(roles.pixelsByRole[role] ?? 0)/max(1,qualified) }
        let pixels=Double(c.observedSupportPixels)
        var d: [Double] = [
            log(pa/qa), 1-nr, 1-ar, ns*ns, als*als, cross*cross,
            pixels/max(qa,1)-pixels/max(pa,1), (1-nr)*(1-s[2])+(1-ar)*(1-s[3]),
            inter/pa, inter/(pa+qa-inter), log1p(Double(c.qualifiedComponentCount))/8,
            log1p(pixels)/12, part("actual-private-attached-complete-RGB-component"),
            part("closed-source-body-outline-topology"), part("one-hop-same-palette-RF-text-sequence-support"),
            Double(roles.pixelsByRole["unqualified"] ?? 0)/max(1,total),
            Double(roles.openComponents)/Double(max(1,roles.componentCount)),
            log1p(Double(c.minimumTerminalPairs))/5, c.priorEnclosureReceipt ? 1 : 0,
            Double(c.peerReceiptCount)/16
        ]
        d += ["keep","low","high","both"].map { c.normalMode == $0 ? 1.0 : 0.0 }
        d += ["keep","head","tail","body"].map { c.alongMode == $0 ? 1.0 : 0.0 }
        let raw=Array(s.prefix(22))+d
        return raw.count == 50 && raw.allSatisfy(\.isFinite) ? raw : nil
    }
    // Stable shifted shoelace. GEOS reference uses Float64; compare all actual
    // fixture descriptors and selected keys before production selection activation.
    private static func signedArea(_ p: [(Double,Double)]) -> Double {
        guard p.count >= 3 else { return 0 }
        let x=p[0].0,y=p[0].1
        var total=0.0
        for i in p.indices { let j=(i+1)%p.count
            total += (p[i].0-x)*(p[j].1-y)-(p[j].0-x)*(p[i].1-y)
        }
        return total/2
    }
    private static func area(_ p: [(Double,Double)]) -> Double { abs(signedArea(p)) }
    private static func clip(_ subject: [(Double,Double)], to polygon: [(Double,Double)]) -> [(Double,Double)] {
        let sign=signedArea(polygon) >= 0 ? 1.0 : -1.0
        var out=subject
        for i in polygon.indices {
            let a=polygon[i],b=polygon[(i+1)%polygon.count],input=out
            out=[]
            guard var previous=input.last else { return [] }
            func distance(_ p:(Double,Double))->Double { sign*((b.0-a.0)*(p.1-a.1)-(b.1-a.1)*(p.0-a.0)) }
            var pd=distance(previous)
            for current in input {
                let cd=distance(current)
                if (cd >= 0) != (pd >= 0) {
                    let t=pd/(pd-cd)
                    out.append((previous.0+t*(current.0-previous.0),previous.1+t*(current.1-previous.1)))
                }
                if cd >= 0 { out.append(current) }
                previous=current;pd=cd
            }
        }
        return out
    }
}

/// Frozen source-only preference. Prior graph membership/associations never change.
@available(iOS 18.0, *)
enum NativeOCRSourceContrastPolicy384 {
    static func mayGenerate(_ source22: [Double]) -> Bool {
        NativeOCRSourceLocalJoint369Ranker.mayGenerate(source22)
    }
    static func current384(_ generated: NativeOCRSourceLocalJoint369.Output,
                          prior: NativeOCRCurrentPrior351.Resolution,
                          source22: [Double]) -> NativeOCRResidualCandidate? {
        let q = prior.polygon
        guard q.count == 4 else { return nil }
        let a = hypot(q[1].x-q[0].x,q[1].y-q[0].y)
        let b = hypot(q[3].x-q[0].x,q[3].y-q[0].y)
        guard min(a,b) > 0, max(a,b) >= 2 * min(a,b),
              let key = NativeOCRSourceLocalJoint369Ranker.preferredKey(source22: source22,
                  actual368Prior: q, roleSummary: generated.nominalRoles384,
                  admitted: generated.nominalMenu384) else { return nil }
        if let core = generated.candidates.first(where: { $0.key == key }) { return core }
        let repairedKey = key + "-contrast380-old-contrast-along-support"
        guard let repair = generated.candidates.first(where: { $0.key == repairedKey }),
              repair.polygon.allSatisfy({ NativeOCRContrastSupport380.contains(q,$0) }) else { return nil }
        return repair
    }

    static func longPrior385(_ q: [CGPoint]) -> Bool {
        guard q.count == 4 else { return false }
        let a = hypot(q[1].x-q[0].x,q[1].y-q[0].y), b = hypot(q[3].x-q[0].x,q[3].y-q[0].y)
        return min(a,b) > 0 && max(a,b) >= 2 * min(a,b)
    }
    /// Oriented edge distance tolerance in original source pixels; never rasterized as ink.
    static func covers386(_ q: [CGPoint], _ points: [CGPoint]) -> Bool {
        guard q.count == 4 else { return false }
        let anchor = q[0]
        let twiceArea = q.indices.reduce(0.0) { sum, i in
            let a = q[i], b = q[(i+1)%4]
            return sum + Double(a.x-anchor.x)*Double(b.y-anchor.y)-Double(a.y-anchor.y)*Double(b.x-anchor.x)
        }
        guard twiceArea != 0 else { return false }
        let sign = twiceArea > 0 ? 1.0 : -1.0
        for i in q.indices {
            let a = q[i], b = q[(i+1)%4], dx = Double(b.x-a.x), dy = Double(b.y-a.y)
            let tolerance = 1e-8 * hypot(dx,dy)
            for p in points where sign * (dx * Double(p.y-a.y)-dy * Double(p.x-a.x)) < -tolerance { return false }
        }
        return true
    }
    static func preferred(_ generated: NativeOCRSourceLocalJoint369.Output,
                          prior: NativeOCRCurrentPrior351.Resolution,
                          source22: [Double]) -> NativeOCRResidualCandidate? {
        guard let current = current384(generated, prior: prior, source22: source22) else { return nil }
        let nominalKey = current.key.components(separatedBy: "-contrast380-")[0]
        guard let core = generated.nominalMenu384.first(where: { $0.key == nominalKey }) else { return current }
        if covers386(prior.polygon,current.polygon) && covers386(prior.polygon,core.polygon) { return nil }
        var best: NativeOCRResidualCandidate?, bestArea = Double.infinity
        for candidate in generated.candidates where
            covers386(candidate.polygon,prior.polygon) && covers386(candidate.polygon,current.polygon) &&
            covers386(candidate.polygon,core.polygon) {
            let area = Nonexclusive377RFPolicy.area(candidate.polygon)
            // Strict comparison preserves actual native producer order on equal area.
            if area < bestArea { best = candidate; bestArea = area }
        }
        return best ?? current
    }
}

/// Calibrated on frozen ALL830 native menus + cached original RF observations.
/// RF support is auxiliary rectangular source evidence, NEVER pixel ownership.
/// No new RGB boundary support is inferred from aggregate CC pixel counts.
@available(iOS 18.0, *)
enum Nonexclusive377RFPolicy {
    typealias Scope = NativeOCRSourceLocalJoint369.Scope
    static let key="nonexclusive-lane-v1-enclose-px1"
    struct Features {
        let normalHighExpansionOverWidth: Double //28
        let rfTextOldCoverage: Double //30
        let rfTextConfidence: Double //31
        let rfTextAcquiredAreaSupport: Double //32 (AREA, not RGB pixels)
    }
    static func quant(_ x:Double)->Double {(x*100_000_000).rounded(.toNearestOrAwayFromZero)/100_000_000}
    static func area(_ q:[CGPoint])->Double {
        guard q.count>=3 else{return 0}
        let o=q[0];var s=0.0
        for i in q.indices {
            let a=q[i],b=q[(i+1)%q.count]
            s+=Double(a.x-o.x)*Double(b.y-o.y)-Double(a.y-o.y)*Double(b.x-o.x)
        }
        return abs(s)*0.5
    }
    /// Scalar convex-quad/axis-aligned RF rectangle clipping. No rasterization.
    static func clipped(_ q:[CGPoint],to r:CGRect)->[CGPoint] {
        var out=q
        let edges:[(Int,Double,Bool)]=[(0,Double(r.minX),true),(0,Double(r.maxX),false),
                                      (1,Double(r.minY),true),(1,Double(r.maxY),false)]
        func value(_ p:CGPoint,_ axis:Int)->Double {axis==0 ? Double(p.x):Double(p.y)}
        for (axis,bound,lower) in edges {
            let input=out;out=[]
            guard var a=input.last else{break}
            var ai=lower ? value(a,axis)>=bound:value(a,axis)<=bound
            for b in input {
                let bi=lower ? value(b,axis)>=bound:value(b,axis)<=bound
                if ai != bi {
                    let t=(bound-value(a,axis))/(value(b,axis)-value(a,axis))
                    out.append(.init(x:Double(a.x)+t*Double(b.x-a.x),y:Double(a.y)+t*Double(b.y-a.y)))
                }
                if bi {out.append(b)}
                a=b;ai=bi
            }
        }
        return out
    }
    /// Pass original RF scopes, preserving order; do not choose a primitive using
    /// NEW polygon coverage. Highest unquantized OLD coverage, then confidence,
    /// then first original primitive. Confidence reproduces native Float decoding.
    static func features(prior:[CGPoint],proposed:[CGPoint],rfScopes:[Scope])->Features? {
        guard prior.count==4,proposed.count==4,(prior+proposed).allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              prior.allSatisfy({NativeOCRNonexclusiveLane369.inside(proposed,$0)}) else{return nil}
        let oa=area(prior),na=area(proposed),acquired=na-oa
        guard oa.isFinite,na.isFinite,oa>0,acquired>1e-12 else{return nil}
        var selected:Scope?,bestCoverage = -Double.infinity,bestConfidence = -Double.infinity
        for scope in rfScopes where scope.semanticClass==0 {
            let r=scope.rect,confidence=Double(Float(scope.confidence))
            guard [r.minX,r.minY,r.maxX,r.maxY].allSatisfy(\.isFinite),r.width>0,r.height>0,
                  confidence.isFinite,confidence>=0,confidence<=1 else{continue}
            let coverage=area(clipped(prior,to:r))/oa
            if coverage>bestCoverage || (coverage==bestCoverage && confidence>bestConfidence) {
                selected=scope;bestCoverage=coverage;bestConfidence=confidence
            }
        }
        guard let text=selected else{return nil}
        let oldRF=area(clipped(prior,to:text.rect)),newRF=area(clipped(proposed,to:text.rect))
        let support=max(0,min(1,(newRF-oldRF)/acquired))
        let e1=CGPoint(x:prior[1].x-prior[0].x,y:prior[1].y-prior[0].y)
        let e3=CGPoint(x:prior[3].x-prior[0].x,y:prior[3].y-prior[0].y)
        let e=hypot(e1.x,e1.y)>=hypot(e3.x,e3.y) ? e1:e3,l=hypot(e.x,e.y)
        guard l.isFinite,l>0 else{return nil}
        let nx=Double(e.y/l),ny = -Double(e.x/l)
        let ox=prior.map{Double($0.x)}.reduce(0,+)/4,oy=prior.map{Double($0.y)}.reduce(0,+)/4
        func normal(_ q:[CGPoint])->[Double] {q.map{(Double($0.x)-ox)*nx+(Double($0.y)-oy)*ny}}
        let op=normal(prior),np=normal(proposed),ow=op.max()!-op.min()!
        guard ow.isFinite,ow>0 else{return nil}
        let high=quant((np.max()!-op.max()!)/ow),cov=quant(bestCoverage),conf=quant(bestConfidence),added=quant(support)
        guard [high,cov,conf,added].allSatisfy(\.isFinite) else{return nil}
        return .init(normalHighExpansionOverWidth:high,rfTextOldCoverage:cov,
            rfTextConfidence:conf,rfTextAcquiredAreaSupport:added)
    }
    /// Only native-admitted geometry, actual current whole-graph prior, source status.
    /// Offline same-old-GT prediction costs are NOT runtime inputs or predicates.
    static func preferred(admitted:[NativeOCRResidualCandidate],prior:NativeOCRCurrentPrior351.Resolution,
                          rootMeasurementStatus:String,rfScopes:[Scope])->NativeOCRResidualCandidate? {
        guard rootMeasurementStatus != "measured",let c=admitted.first(where:{$0.key==key}),
              c.consumedIndices==prior.consumedIndices,c.associationKey==prior.inheritedAssociationKey,
              let f=features(prior:prior.polygon,proposed:c.polygon,rfScopes:rfScopes),
              f.rfTextOldCoverage>0.93727958,
              f.rfTextConfidence>=0.8,
              f.rfTextAcquiredAreaSupport>=0.6,
              f.normalHighExpansionOverWidth<=0.04 else{return nil}
        return c
    }
}

@available(iOS 18.0, *)
extension Nonexclusive377RFPolicy {
    /// Necessary source-only RF preflight; no original RGB read or ownership claim.
    static func mayGenerate385(prior: [CGPoint], rfScopes: [Scope]) -> Bool {
        let oldArea = area(prior)
        guard oldArea > 0 else { return false }
        return rfScopes.contains { scope in
            scope.semanticClass == 0 && Double(Float(scope.confidence)) >= 0.8 &&
            quant(area(clipped(prior,to:scope.rect))/oldArea) > 0.93727958
        }
    }
}


// Audit392-only native metadata identity; no JSON/rounded-hull or role approximation.
@available(iOS 18.0, *)
extension NativeOCRSourceLocalJoint369Capture {
    static func metadataDifferences392(_ old: M, _ fresh: M) -> [String] {
        var different: [String] = []
        func check(_ name: String, _ same: Bool) { if !same { different.append(name) } }
        check("index", old.index == fresh.index)
        check("status", old.status == fresh.status)
        check("kind", old.kind == fresh.kind)
        check("polygon", old.polygon == fresh.polygon)
        check("origin", old.origin == fresh.origin)
        check("normal", old.normal == fresh.normal)
        check("along", old.along == fresh.along)
        check("rect", old.rect == fresh.rect)
        check("left", old.left == fresh.left)
        check("top", old.top == fresh.top)
        check("step", old.step == fresh.step)
        check("columns", old.columns == fresh.columns)
        check("rows", old.rows == fresh.rows)
        check("palettes", old.palettes == fresh.palettes)
        check("privateHull", old.privateHull == fresh.privateHull)
        check("guardPoints", old.guardPoints == fresh.guardPoints)
        check("privateSamples", old.privateSamples == fresh.privateSamples)
        check("associatedOwners", old.associatedOwners == fresh.associatedOwners)
        check("provisionalOwners", old.provisionalOwners == fresh.provisionalOwners)
        check("rejections", old.rejections == fresh.rejections)
        check("score", old.score == fresh.score)
        check("hasInk", old.hasInk == fresh.hasInk)
        check("scopes", old.scopes.count == fresh.scopes.count && zip(old.scopes, fresh.scopes).allSatisfy {
            $0.rect == $1.rect && $0.confidence == $1.confidence
        })
        check("components", old.components.count == fresh.components.count && zip(old.components, fresh.components).allSatisfy {
            $0.colour == $1.colour && $0.pixels == $1.pixels && $0.ownedPixels == $1.ownedPixels &&
            $0.foreignPixels == $1.foreignPixels && $0.insidePixels == $1.insidePixels &&
            $0.bounds == $1.bounds && $0.center == $1.center && $0.hull == $1.hull
        })
        if let previous = old.privateObservation {
            if let current = fresh.privateObservation {
                let a = previous.moments, b = current.moments
                check("existingPrivateMoments", a.count == b.count && a.meanX == b.meanX && a.meanY == b.meanY &&
                    a.xx == b.xx && a.xy == b.xy && a.yy == b.yy)
                check("existingPrivateRGBSamples", previous.privateRGBSamples == current.privateRGBSamples)
                check("existingMissingPrivateRGBPixels", previous.missingPrivateRGBPixels == current.missingPrivateRGBPixels)
                check("existingPrivatePalettes", previous.palettes.count == current.palettes.count &&
                    zip(previous.palettes, current.palettes).allSatisfy {
                        $0.rgb == $1.rgb && $0.bin == $1.bin && $0.sourceSeedBinCount == $1.sourceSeedBinCount
                    })
                if let oldSet = previous.footprint {
                    if let newSet = current.footprint {
                        check("existingNativeFootprint", oldSet.width == newSet.width && oldSet.height == newSet.height &&
                            oldSet.scaleX == newSet.scaleX && oldSet.scaleY == newSet.scaleY && oldSet.cells == newSet.cells)
                    } else { check("existingNativeFootprint", false) }
                }
            } else { check("existingPrivateObservation", false) }
        }
        // privateObservation is the ONLY optional enrichment, never an ordinary metadata override.
        return different
    }
    static func hasCompletePrivate392(_ m: M, width: Int, height: Int) -> Bool {
        guard m.status == "measured", let p = m.privateObservation,
              p.missingPrivateRGBPixels == 0, p.privateRGBSamples > 0,
              p.moments.count == m.privateSamples, p.palettes.count <= 16,
              p.palettes.allSatisfy({ $0.rgb.count == 3 && $0.rgb.allSatisfy { (0...255).contains($0) } }),
              let f = p.footprint, f.width > 0, f.height > 0, f.width <= Int.max / f.height,
              f.scaleX.isFinite, f.scaleY.isFinite, f.scaleX > 0, f.scaleY > 0,
              !f.cells.isEmpty, f.cells.allSatisfy({ $0 >= 0 && $0 < f.width * f.height }),
              width > 0, height > 0,
              abs(CGFloat(f.width) * f.scaleX - CGFloat(width)) <= 1e-6,
              abs(CGFloat(f.height) * f.scaleY - CGFloat(height)) <= 1e-6 else { return false }
        // f is the authentic Retained native set. No local runs, hull fill or ownership inference.
        return true
    }
}
