import CoreGraphics
import Foundation
import CryptoKit

/// Shared evidence-driven alternatives after the accepted source-component stage.
/// GT is used by the offline selector only; runtime routing reads these source features.
@available(iOS 18.0, *)
enum NativeOCRResidualCandidateBank {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    struct Node {
        let feature: Int
        let threshold: Double
        let left: Int
        let right: Int
        let key: String?
    }
    static let featureNames = ["sourceScore", "aspect", "normalInkRatio", "alongInkRatio", "privateNormalRatio",
                               "ownedComponents", "axisCorrection", "axisResidual", "sourceKind", "hasInkProof",
                               "normalInkOffset", "alongInkOffset", "supportKind", "observedHeadExtension", "observedTailExtension", "observedJoin",
                               "supportLeftClearanceWidths", "supportRightClearanceWidths", "supportHeadClearanceWidths", "supportTailClearanceWidths",
                               "supportMinimumRectangleAngleDegrees", "supportMinimumRectangleAreaRatio"]
    // No candidate is enabled until native all-page scoring and ingress checks pass.
    static let nodes: [Node] = []
    static let routingScheme = "angle-offset-override"
    static let rules: [String: String] = [
        "0|compact|fit|fit|straight|center|center": "terminal-head-side-joint-v1|side-envelope-v1-tail-grid|terminal-head-palette-gap065-reach3-v1 >> -",
        "0|compact|fit|fit|straight|center|head": "terminal-head-palette-gap065-reach3-v1",
        "0|compact|fit|fit|straight|center|tail": "side-envelope-v1-full-ink-quarter",
        "0|compact|fit|fit|straight|left|center": "-",
        "0|compact|fit|fit|straight|left|head": "terminal-trim-v1|tail|pad04",
        "0|compact|fit|fit|straight|left|tail": "-",
        "0|compact|fit|fit|straight|right|center": "-",
        "0|compact|fit|fit|straight|right|head": "-",
        "0|compact|fit|fit|straight|right|tail": "-",
        "0|compact|fit|long|fallback": "terminal-tail-palette-gap065-reach3-v1",
        "0|compact|fit|short|fallback": "side-envelope-v1-normal-ink-quarter",
        "0|compact|fit|short|straight|center|center": "normal.owned-shell.v1",
        "0|compact|fit|short|straight|center|head": "normal.owned-shell.v1",
        "0|compact|fit|short|straight|center|tail": "terminal-trim-v1|head|pad04",
        "0|compact|fit|short|straight|left|center": "-",
        "0|compact|fit|short|straight|right|center": "-",
        "0|compact|narrow|fit|fallback": "side-envelope-v1-head-ink-half >> -",
        "0|compact|narrow|fit|straight|center|center": "terminal-trim-v1|tail|pad10|enclose75",
        "0|compact|narrow|fit|straight|center|tail": "-",
        "0|compact|narrow|fit|straight|left|center": "-",
        "0|compact|narrow|fit|straight|right|center": "-",
        "0|compact|narrow|long|fallback": "-",
        "0|compact|narrow|short|straight|center|center": "normal.owned-shell.v1",
        "0|compact|narrow|short|straight|center|head": "terminal-trim-v1|tail|pad10",
        "0|compact|narrow|short|straight|center|tail": "side-envelope-v1-right-ink-half|enclose25",
        "0|compact|narrow|short|straight|left|center": "terminal-trim-v1|head|pad04|enclose50",
        "0|compact|narrow|short|straight|left|head": "-",
        "0|compact|narrow|short|straight|left|tail": "-",
        "0|compact|narrow|short|straight|right|center": "side-envelope-v1-normal-grid",
        "0|compact|narrow|short|straight|right|head": "side-envelope-v1-normal-ink-half",
        "0|compact|narrow|short|straight|right|tail": "-",
        "0|compact|wide|fit|fallback": "-",
        "0|compact|wide|fit|straight|center|center": "terminal-trim-v1|tail|pad04",
        "0|compact|wide|fit|straight|center|tail": "-",
        "0|compact|wide|long|fallback": "-",
        "0|compact|wide|long|straight|center|center": "-",
        "0|compact|wide|short|fallback": "-",
        "0|compact|wide|short|straight|center|center": "-",
        "0|compact|wide|short|straight|center|head": "-",
        "0|compact|wide|short|straight|center|tail": "-",
        "0|long|fit|fit|fallback": "terminal-head-side-joint-v1|side-envelope-v1-head-grid|terminal-head-palette-gap065-reach3-v1 >> terminal-trim-v1|tail|pad10|enclose50",
        "0|long|fit|fit|straight|center|center": "axis-bins-envelope-v1-half|enclose50 >> side-envelope-v1-full-ink-quarter|enclose75",
        "0|long|fit|fit|straight|center|head": "side-envelope-v1-normal-ink-half|enclose50 >> terminal-trim-v1|tail|pad04",
        "0|long|fit|fit|straight|center|tail": "terminal-trim-v1|head|pad10|enclose75",
        "0|long|fit|fit|straight|right|center": "terminal-trim-v1|tail|pad10|enclose75",
        "0|long|fit|fit|tilted|center|center": "side-envelope-v1-right-ink-half|enclose50",
        "0|long|fit|short|fallback": "side-envelope-v1-head-ink-half|enclose75 >> terminal-trim-v1|tail|pad04",
        "0|long|fit|short|straight|center|center": "terminal-trim-v1|head|pad04",
        "0|long|fit|short|straight|center|head": "terminal-trim-v1|head|pad10|enclose75",
        "0|long|narrow|fit|fallback": "-",
        "0|long|narrow|fit|straight|center|center": "terminal-head-side-joint-v1|side-envelope-v1-left-grid|terminal-head-palette-gap065-reach3-v1 >> normal.owned-shell.context25.v1",
        "0|long|narrow|short|fallback": "terminal-trim-v1|head|pad04",
        "0|long|wide|fit|fallback": "-",
        "0|long|wide|fit|straight|center|center": "terminal-trim-v1|tail|pad10|enclose25",
        "0|long|wide|fit|straight|center|head": "terminal-head-palette-gap065-reach3-v1",
        "0|long|wide|fit|straight|right|center": "terminal-head-side-joint-v1|side-envelope-v1-normal-grid|terminal-head-palette-gap065-reach3-v1 >> terminal-tail-palette-gap065-reach3-v1",
        "0|long|wide|fit|tilted|center|center": "terminal-trim-v1|head|pad04|enclose75",
        "0|long|wide|long|fallback": "terminal-head-palette-gap065-reach3-v1 >> -",
        "0|long|wide|short|fallback": "terminal-trim-v1|tail|pad04",
        "0|long|wide|short|straight|center|head": "terminal-trim-v1|head|pad10|enclose75",
        "0|medium|fit|fit|fallback": "terminal-trim-v1|tail|pad10",
        "0|medium|fit|fit|straight|center|center": "terminal-trim-v1|head|pad10|enclose75",
        "0|medium|fit|fit|straight|center|head": "terminal-head-palette-gap065-reach3-v1",
        "0|medium|fit|fit|straight|center|tail": "terminal-trim-v1|head|pad04",
        "0|medium|fit|fit|straight|right|center": "side-envelope-v1-left-ink-half|enclose25 >> terminal-trim-v1|tail|pad10",
        "0|medium|fit|fit|tilted|center|center": "terminal-head-side-joint-v1|side-envelope-v1-head-ink-half|terminal-head-palette-gap065-reach3-v1 >> side-envelope-v1-head-grid|enclose25",
        "0|medium|fit|fit|tilted|center|head": "terminal-head-side-joint-v1|side-envelope-v1-head-ink-half|terminal-head-palette-gap065-reach3-v1 >> side-envelope-v1-tail-ink-half|enclose75",
        "0|medium|fit|fit|tilted|center|tail": "normal.owned-shell.context25.v1",
        "0|medium|fit|fit|tilted|right|center": "-",
        "0|medium|fit|long|fallback": "terminal-trim-v1|tail|pad04|enclose75 >> -",
        "0|medium|fit|short|fallback": "normal-complete-v1-s100-w025|enclose75 >> terminal-trim-v1|head|pad10",
        "0|medium|fit|short|straight|center|center": "terminal-trim-v1|tail|pad10|enclose75",
        "0|medium|fit|short|straight|center|head": "-",
        "0|medium|fit|short|straight|center|tail": "terminal-trim-v1|head|pad04",
        "0|medium|fit|short|tilted|center|center": "terminal-head-side-joint-v1|side-envelope-v1-left-grid|terminal-head-palette-gap065-reach3-v1 >> side-envelope-v1-full-ink-half|enclose25",
        "0|medium|fit|short|tilted|center|head": "terminal-trim-v1|head|pad10|enclose25 >> terminal-trim-v1|tail|pad10",
        "0|medium|fit|short|tilted|center|tail": "terminal-head-side-joint-v1|side-envelope-v1-left-grid|terminal-head-palette-gap065-reach3-v1 >> terminal-trim-v1|head|pad10",
        "0|medium|narrow|fit|fallback": "side-envelope-v1-full-grid|enclose25",
        "0|medium|narrow|fit|straight|center|center": "terminal-tail-side-joint-v1|side-envelope-v1-head-grid|terminal-tail-palette-gap065-reach3-v1 >> terminal-trim-v1|tail|pad04|enclose50",
        "0|medium|narrow|fit|straight|center|head": "terminal-head-palette-gap065-reach3-v1",
        "0|medium|narrow|fit|straight|right|center": "side-envelope-v1-tail-grid|enclose75",
        "0|medium|narrow|fit|tilted|center|center": "terminal-head-palette-gap065-reach3-v1",
        "0|medium|narrow|fit|tilted|center|head": "terminal-head-side-joint-v1|side-envelope-v1-right-grid|terminal-head-palette-gap065-reach3-v1 >> terminal-trim-v1|tail|pad04",
        "0|medium|narrow|fit|tilted|right|center": "terminal-trim-v1|head|pad04|enclose25",
        "0|medium|narrow|long|fallback": "-",
        "0|medium|narrow|short|fallback": "terminal-tail-palette-gap065-reach3-v1",
        "0|medium|narrow|short|straight|center|center": "terminal-head-side-joint-v1|side-envelope-v1-head-ink-half|terminal-head-palette-gap065-reach3-v1 >> axis-bins-envelope-v1-half|enclose25",
        "0|medium|narrow|short|straight|center|head": "terminal-head-palette-gap065-reach3-v1",
        "0|medium|narrow|short|straight|center|tail": "side-envelope-v1-head-grid|enclose75",
        "0|medium|narrow|short|tilted|center|center": "side-envelope-v1-full-ink-half|enclose25",
        "0|medium|narrow|short|tilted|center|head": "terminal-head-side-joint-v1|side-envelope-v1-head-grid|terminal-head-palette-gap065-reach3-v1 >> side-envelope-v1-tail-ink-quarter|enclose75",
        "0|medium|narrow|short|tilted|center|tail": "terminal-trim-v1|head|pad10",
        "0|medium|wide|fit|fallback": "terminal-trim-v1|head|pad10|enclose25 >> terminal-trim-v1|tail|pad04",
        "0|medium|wide|fit|straight|center|center": "terminal-trim-v1|head|pad10|enclose75",
        "0|medium|wide|fit|straight|center|head": "terminal-trim-v1|tail|pad04",
        "0|medium|wide|fit|straight|center|tail": "terminal-head-palette-gap065-reach3-v1",
        "0|medium|wide|fit|tilted|center|center": "terminal-trim-v1|head|pad10|enclose75",
        "0|medium|wide|long|fallback": "terminal-tail-side-joint-v1|side-envelope-v1-full-ink-half|terminal-tail-palette-gap065-reach3-v1 >> -",
        "0|medium|wide|short|fallback": "terminal-trim-v1|head|pad04",
        "0|medium|wide|short|straight|center|head": "terminal-trim-v1|tail|pad04|enclose25 >> terminal-trim-v1|head|pad10|enclose50",
        "0|medium|wide|short|straight|center|tail": "side-envelope-v1-normal-grid",
        "0|medium|wide|short|tilted|center|center": "terminal-trim-v1|tail|pad04",
        "0|medium|wide|short|tilted|center|head": "terminal-trim-v1|head|pad10|enclose25 >> terminal-trim-v1|tail|pad04",
        "1|compact|fit|fit|fallback": "-",
        "1|compact|narrow|fit|fallback": "terminal-tail-side-joint-v1|side-envelope-v1-full-grid|terminal-tail-palette-gap065-reach3-v1 >> -",
        "1|long|fit|fit|fallback": "terminal-tail-side-joint-v1|side-envelope-v1-normal-head-grid|terminal-tail-palette-gap065-reach3-v1 >> side-envelope-v1-left-ink-half",
        "1|long|fit|fit|straight|center|center": "side-envelope-v1-normal-head-grid|enclose50 >> axis-bins-envelope-v1-half",
        "1|long|fit|short|fallback": "side-envelope-v1-tail-ink-quarter|enclose25 >> membership.group-envelope.owned.pad1",
        "1|long|narrow|fit|fallback": "terminal-trim-v1|tail|pad04|enclose75 >> -",
        "1|long|wide|fit|fallback": "side-envelope-v1-normal-tail-ink-half >> -",
        "1|long|wide|fit|straight|center|center": "terminal-tail-side-joint-v1|side-envelope-v1-normal-head-grid|terminal-tail-palette-gap065-reach3-provisional-member-v2 >> terminal-tail-palette-gap065-reach3-provisional-member-v2",
        "1|long|wide|short|fallback": "-",
        "1|medium|fit|fit|fallback": "normal.owned-shell.context25.v1",
        "1|medium|fit|fit|straight|center|center": "side-envelope-v1-normal-head-ink-quarter|enclose25 >> side-envelope-v1-normal-grid|enclose25",
        "1|medium|fit|fit|tilted|center|center": "side-envelope-v1-normal-ink-quarter|enclose25 >> evidence-verified-contour-a0-gap0-pad2",
        "1|medium|fit|short|fallback": "terminal-head-side-joint-v1|side-envelope-v1-head-grid|terminal-head-palette-gap065-reach3-v1 >> terminal-trim-v1|head|pad10|enclose75",
        "1|medium|narrow|fit|fallback": "-",
        "1|medium|narrow|short|fallback": "-",
        "1|medium|wide|fit|fallback": "terminal-head-palette-gap065-reach3-v1",
        "1|medium|wide|short|fallback": "-",
        "2|compact|narrow|short|fallback": "-",
        "2|long|fit|fit|fallback": "independent-envelope-source-p2|enclose75 >> normal.owned-shell.context35.v1",
        "2|long|fit|fit|straight|center|center": "independent-envelope-source-p2|enclose50 >> terminal-trim-v1|tail|pad04",
        "2|long|fit|long|fallback": "side-envelope-v1-full-grid >> -",
        "2|long|fit|short|fallback": "-",
        "2|long|narrow|fit|fallback": "normal-complete-v1-s050-w010 >> -",
        "2|long|narrow|short|fallback": "normal-complete-v1-s050-w010 >> -",
        "2|long|wide|fit|fallback": "side-envelope-v1-normal-tail-grid >> -",
        "2|long|wide|short|fallback": "axis-bins-center-v1-retain-span >> -",
        "2|medium|fit|fit|fallback": "independent-envelope-source-p2|enclose75 >> -",
        "2|medium|fit|fit|straight|center|center": "side-envelope-v1-tail-ink-half >> terminal-trim-v1|head|pad04",
        "2|medium|fit|short|fallback": "normal-complete-v1-s050-w010 >> -",
        "2|medium|narrow|fit|fallback": "-",
        "2|medium|narrow|short|fallback": "-",
        "2|medium|wide|fit|fallback": "axis-bins-envelope-v1-full >> -",
    ]

    static func features(_ m: Measurement) -> [Double] {
        let basic = NativeOCRSourceComponentBounds.proposal(m, gap: 0, axis: 0, padding: 2)
        let angled = NativeOCRSourceComponentBounds.proposal(m, gap: 0, axis: 1, padding: 2)
        let own = m.components.filter { $0.ownedPixels >= 2 && $0.insidePixels >= 2 && $0.foreignPixels == 0 }
        let ink = own.flatMap(\.hull)
        let inkRect = ink.isEmpty ? m.rect : NativeOCRSourceComponentBounds.bounds(ink)
        let privateWidth = m.privateHull.isEmpty ? 0 : NativeOCRSourceComponentBounds.bounds(m.privateHull).width
        return [m.score, Double(m.rect.height / max(1e-9, m.rect.width)),
                Double(basic?.1.normalRatio ?? 1), Double(basic?.1.alongRatio ?? 1),
                Double(privateWidth / max(1e-9, m.rect.width)), Double(basic?.1.owned ?? 0),
                Double(abs(angled?.1.angle ?? 0)), Double(angled?.1.residual ?? 99),
                m.kind == "group" ? 1 : m.kind == "independent" ? 2 : 0, m.hasInk ? 1 : 0,
                Double((inkRect.midX - m.rect.midX) / max(1e-9, m.rect.width)),
                Double((inkRect.midY - m.rect.midY) / max(1e-9, m.rect.height)),
                !m.provisionalOwners.isEmpty ? 2 : !m.associatedOwners.isEmpty ? 1 : 0]
    }

    static func selectedKey(_ values: [Double]) -> String? {
        struct Node {
            let feature: Int
            let threshold: Double
            let left: Int
            let right: Int
            let keys: String?
        }
        let overrides: [String: [Node]] = [
            "0|compact|fit|fit|straight|center|head": [
                Node(feature: 5, threshold: 8, left: 1, right: 2, keys: nil),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-prepared-axis-normal-current-along >> terminal-head-palette-gap065-reach3-v1"),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-original-direct >> terminal-head-palette-gap065-reach3-v1"),
            ],
            "0|compact|fit|fit|straight|left|head": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "support-minrect-v1-incoming-axis-control-tight-p1 >> terminal-trim-v1|tail|pad04"),
            ],
            "0|compact|fit|fit|straight|right|center": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-original-axis-normal-current-along >> -"),
            ],
            "0|compact|fit|fit|straight|right|head": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-prepared-axis-normal-current-along >> -"),
            ],
            "0|compact|fit|short|fallback": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-prepared-axis-normal-current-along >> side-envelope-v1-normal-ink-quarter"),
            ],
            "0|compact|fit|short|straight|center|tail": [
                Node(feature: 4, threshold: 0.51430822559367229, left: 1, right: 2, keys: nil),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-prepared-direct >> terminal-trim-v1|head|pad04"),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: nil),
            ],
            "0|compact|narrow|short|straight|center|tail": [
                Node(feature: 2, threshold: 0.68000619315081956, left: 1, right: 2, keys: nil),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "side-envelope-v1-full-ink-half|enclose75 >> side-envelope-v1-right-ink-half|enclose25"),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: nil),
            ],
            "0|compact|narrow|short|straight|right|center": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-original-axis-normal-current-along >> side-envelope-v1-normal-grid"),
            ],
            "0|compact|wide|fit|straight|center|center": [
                Node(feature: 4, threshold: 0.48901657496174999, left: 1, right: 2, keys: nil),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: nil),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-prepared-axis-normal-current-along >> terminal-trim-v1|tail|pad04"),
            ],
            "0|long|fit|fit|straight|center|head": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "terminal-head-palette-gap065-reach3-v1 >> side-envelope-v1-normal-ink-half|enclose50 >> terminal-trim-v1|tail|pad04"),
            ],
            "0|long|fit|short|straight|center|head": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "terminal-trim-v1|tail|pad04 >> terminal-trim-v1|head|pad10|enclose75"),
            ],
            "0|medium|fit|fit|fallback": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "terminal-trim-v1|tail|pad04|enclose25 >> terminal-trim-v1|tail|pad10"),
            ],
            "0|medium|fit|short|fallback": [
                Node(feature: 18, threshold: 0.046114460000000003, left: 1, right: 2, keys: nil),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "normal.owned-shell.context25.v1 >> normal-complete-v1-s100-w025|enclose75 >> terminal-trim-v1|head|pad10"),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: nil),
            ],
            "0|medium|fit|short|straight|center|center": [
                Node(feature: 0, threshold: 0.89485648557906605, left: 1, right: 2, keys: nil),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "terminal-trim-v1|head|pad04 >> terminal-trim-v1|tail|pad10|enclose75"),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-original-axis-normal-current-along >> terminal-trim-v1|tail|pad10|enclose75"),
            ],
            "0|medium|fit|short|straight|center|tail": [
                Node(feature: 11, threshold: 0.08083094663127921, left: 1, right: 2, keys: nil),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "normal.owned-shell.context25.v1 >> terminal-trim-v1|head|pad04"),
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "terminal-tail-palette-gap065-reach3-v1 >> terminal-trim-v1|head|pad04"),
            ],
            "0|medium|fit|short|tilted|center|tail": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "terminal-head-palette-gap065-reach3-v1 >> terminal-head-side-joint-v1|side-envelope-v1-left-grid|terminal-head-palette-gap065-reach3-v1 >> terminal-trim-v1|head|pad10"),
            ],
            "0|medium|narrow|short|fallback": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "terminal-tail-side-joint-v1|side-envelope-v1-normal-tail-grid|terminal-tail-palette-gap065-reach3-v1 >> terminal-tail-palette-gap065-reach3-v1"),
            ],
            "0|medium|narrow|short|tilted|center|head": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "terminal-trim-v1|head|pad04|enclose25 >> terminal-head-side-joint-v1|side-envelope-v1-head-grid|terminal-head-palette-gap065-reach3-v1 >> side-envelope-v1-tail-ink-quarter|enclose75"),
            ],
            "1|long|fit|fit|straight|center|center": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-prepared-rf-text-c050-r1-normal-current-along >> side-envelope-v1-normal-head-grid|enclose50 >> axis-bins-envelope-v1-half"),
            ],
            "1|long|wide|fit|straight|center|center": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "input-footprint-v1-prepared-direct >> terminal-tail-side-joint-v1|side-envelope-v1-normal-head-grid|terminal-tail-palette-gap065-reach3-provisional-member-v2 >> terminal-tail-palette-gap065-reach3-provisional-member-v2"),
            ],
            "2|long|fit|fit|fallback": [
                Node(feature: -1, threshold: 0, left: 0, right: 0, keys: "terminal-trim-v1|head|pad04 >> independent-envelope-source-p2|enclose75 >> normal.owned-shell.context35.v1"),
            ],
        ]
        guard values.count >= 13, values.prefix(13).allSatisfy({ $0.isFinite }) else { return nil }
        let exact = classKey(values)
        let fallback = exact.split(separator: "|").prefix(4).joined(separator: "|") + "|fallback"
        let resolvedClass = rules[exact] != nil ? exact : fallback
        guard let encodedDefault = rules[resolvedClass] else { return nil }
        let defaultValue: String? = encodedDefault == "-" ? nil : encodedDefault
        guard let tree = overrides[resolvedClass] else { return defaultValue }
        // Unknown override routing token forces full native collection before this call.
        guard values.count == 22, values.allSatisfy({ $0.isFinite }) else { return defaultValue }
        var routingValues = values
        for feature in 16..<22 {
            let scaled = values[feature] * 100000000.0
            guard scaled.isFinite else { return defaultValue }
            let rounded = scaled.rounded(.toNearestOrAwayFromZero) / 100000000.0
            guard rounded.isFinite else { return defaultValue }
            routingValues[feature] = rounded == 0 ? 0 : rounded
        }
        var index = 0
        for _ in 0...tree.count {
            guard tree.indices.contains(index) else { return defaultValue }
            let node = tree[index]
            if node.feature < 0 { return node.keys ?? defaultValue }
            index = routingValues[node.feature] <= node.threshold ? node.left : node.right
        }
        return defaultValue
    }

    static func classKey(_ v: [Double]) -> String {
        guard v.count >= 13 else { return "identity" }
        var parts = [String(Int(v[8])), v[1] < 3 ? "compact" : v[1] < 8 ? "medium" : "long",
                     v[2] < 0.8 ? "narrow" : v[2] < 1.05 ? "fit" : "wide",
                     v[3] < 0.85 ? "short" : v[3] < 1.05 ? "fit" : "long"]
        if routingScheme.contains("confidence") { parts.append(v[0] < 0.8 ? "weak" : v[0] < 0.9 ? "mid" : "strong") }
        if routingScheme.contains("angle") { parts.append(v[6] > 1 ? "tilted" : "straight") }
        if routingScheme.contains("offset") {
            parts.append(v[10] < -0.08 ? "left" : v[10] > 0.08 ? "right" : "center")
            parts.append(v[11] < -0.04 ? "head" : v[11] > 0.04 ? "tail" : "center")
        }
        if routingScheme.contains("support") { parts.append(String(Int(v[12]))) }
        if routingScheme.contains("caps"), v.count >= 16 {
            parts.append(v[13] <= 0.05 ? "head0" : v[13] <= 0.5 ? "headSmall" : "headLarge")
            parts.append(v[14] <= 0.05 ? "tail0" : v[14] <= 0.5 ? "tailSmall" : "tailLarge")
        }
        return parts.joined(separator: "|")
    }

    /// Observed-feature, node and unknown future routers retain complete collection.
    static func canRouteBeforeCollect(exporting: Bool) -> Bool {
        let known = Set(["base", "confidence", "angle", "offset", "support"])
        return !exporting && !rules.isEmpty && nodes.isEmpty &&
            !routingScheme.contains("caps") && !routingScheme.isEmpty &&
            routingScheme.split(separator: "-").allSatisfy { known.contains(String($0)) }
    }

    /// Collect the union of ALL ranked base families, plus every completion
    /// dependency. Unknown keys/strengths or invalid lists use the legacy bank.
    static func collectRankedFamilies(_ encoded: String, measurement m: Measurement,
                                     context: NativeOCRResidualSourceContext)
        -> (items: [NativeOCRResidualCandidate], strengths: [String: [CGFloat]])? {
        let keys = encoded.components(separatedBy: " >> ")
        guard keys.count <= 3, keys.allSatisfy({ !$0.isEmpty }) else { return nil }
        var families: Set<Int> = [2, 4]
        var baseKeys = Set<String>()
        var strengths: [String: [CGFloat]] = [:]
        for key in keys {
            // No producer emits the reserved no-op policy token.
            if key == "-" { continue }
            var baseKey = key
            if let marker = key.range(of: "|enclose", options: .backwards) {
                let suffix = String(key[marker.lowerBound...])
                guard let fraction: CGFloat = ["|enclose25": 0.25, "|enclose50": 0.5, "|enclose75": 0.75][suffix] else { return nil }
                baseKey = String(key[..<marker.lowerBound])
                guard !baseKey.hasPrefix("terminal-head-"), !baseKey.hasPrefix("terminal-tail-") else { return nil }
                if !(strengths[baseKey] ?? []).contains(fraction) { strengths[baseKey, default: []].append(fraction) }
            }
            let family: Int
            if baseKey.hasPrefix("normal.") { family = 0 }
            else if baseKey.hasPrefix("normal-complete-v1-") { family = 1 }
            else if baseKey.hasPrefix("terminal-head-") || baseKey.hasPrefix("terminal-tail-") { family = 2 }
            else if baseKey.hasPrefix("terminal-trim-v1|") { family = 3 }
            else if baseKey.hasPrefix("side-envelope-v1-") { family = 4 }
            else if baseKey.hasPrefix("axis-bins-") { family = 5 }
            else if baseKey.hasPrefix("independent-envelope-") || baseKey.hasPrefix("independent-normal-") { family = 6 }
            else if baseKey.hasPrefix("membership.") { family = 7 }
            else if baseKey.hasPrefix("evidence-verified-contour-") { family = 8 }
            else { return nil }
            baseKeys.insert(baseKey)
            families.insert(family)
        }
        // Keep legacy strength ordering, independent of ranked preference order.
        for key in Array(strengths.keys) { strengths[key]?.sort() }
        var items: [NativeOCRResidualCandidate] = []
        for family in families.sorted() {
            switch family {
            case 0: items += NativeOCRResidualNormalExpansion.candidates(m, context: context)
            case 1: items += NativeOCRResidualNormalContraction.candidates(m)
            case 2: items += NativeOCRResidualTerminalExtension.candidates(m, context: context)
            case 3: items += NativeOCRResidualTerminalTrim.candidates(m)
            case 4: items += NativeOCRResidualSideEnvelope.candidates(m)
            case 5: items += NativeOCRResidualAxisOffset.candidates(m)
            case 6: items += NativeOCRResidualIndependentColumns.candidates(m, context: context)
            case 7: items += NativeOCRResidualMembership.candidates(m, context: context)
            case 8: items += NativeOCRResidualEvidence.candidates(m, context: context)
            default: break
            }
        }
        var seen = Set<String>()
        let selected = items.filter {
            !$0.key.isEmpty && $0.key.utf8.count <= 160 && seen.insert($0.key).inserted &&
                (baseKeys.contains($0.key) || $0.key.hasPrefix("side-envelope-v1-") ||
                 $0.key.hasPrefix("terminal-head-") || $0.key.hasPrefix("terminal-tail-"))
        }
        return (selected, strengths)
    }

    static func collect(_ m: Measurement, context: NativeOCRResidualSourceContext, caps: [CGPoint],
                        supportAssessment: NativeOCRResidualSupportMinimumRectangle.Assessment? = nil)
        -> [NativeOCRResidualCandidate] {
        var result = NativeOCRResidualNormalExpansion.candidates(m, context: context)
        result += NativeOCRResidualNormalContraction.candidates(m)
        result += NativeOCRResidualTerminalExtension.candidates(m, context: context)
        result += NativeOCRResidualTerminalTrim.candidates(m)
        result += NativeOCRResidualSideEnvelope.candidates(m)
        result += NativeOCRResidualAxisOffset.candidates(m)
        result += NativeOCRResidualIndependentColumns.candidates(m, context: context)
        result += NativeOCRResidualMembership.candidates(m, context: context)
        result += NativeOCRResidualEvidence.candidates(m, context: context)
        result += NativeOCRResidualInputFootprints.candidates(m, context: context)
        result += NativeOCRResidualTerminalScopeSupport.candidates(m, context: context)
        result += (supportAssessment ?? NativeOCRResidualSupportMinimumRectangle.assess(m, caps: caps)).candidates
        var seen = Set<String>()
        return result.filter { !$0.key.isEmpty && $0.key.utf8.count <= 160 && seen.insert($0.key).inserted }
    }

    static func enclosing(_ originals: [NativeOCRResidualCandidate], measurement m: Measurement,
                          strengths: [String: [CGFloat]]? = nil) -> [NativeOCRResidualCandidate] {
        // Enclosing blends provide shared correction strengths without ever
        // partially admitting a newly recovered terminal or a consumed peer.
        var result: [NativeOCRResidualCandidate] = []
        for candidate in originals where candidate.consumedIndices.isEmpty &&
            !candidate.key.hasPrefix("terminal-head-") && !candidate.key.hasPrefix("terminal-tail-") &&
            !candidate.key.hasPrefix("scope-terminal-") {
            let fractions: [CGFloat] = strengths.map { $0[candidate.key] ?? [] } ?? [0.25, 0.5, 0.75]
            guard !fractions.isEmpty else { continue }
            let aligned = NativeOCRSourceComponentBounds.interpolate(m.polygon, proposal: candidate.polygon, fraction: 1)
            guard zip(aligned, m.polygon).contains(where: { hypot($0.x - $1.x, $0.y - $1.y) > 1e-7 }) else { continue }
            for fraction in fractions {
                let polygon = NativeOCRSourceComponentBounds.interpolate(m.polygon, proposal: candidate.polygon, fraction: fraction)
                guard candidate.polygon.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 1e-7) }) else { continue }
                result.append(.init(key: candidate.key + "|enclose" + String(Int(fraction * 100)), polygon: polygon,
                    supportPoints: candidate.supportPoints))
            }
        }
        return result
    }

    struct Result {
        let polygons: [[CGPoint]]
        let consumed: Set<Int>
        let records: [[String: Any]]
        var associations: [[String: Any]] = []
    }
    static func evaluate(_ polygons: [[CGPoint]], indices: [Int], hasInk: [Bool],
                         baselines: [[CGPoint]?], terminalProofs: [[CGPoint]?], pointProofs: [[CGPoint]?],
                         originals: [NativeCoreMLDetectionBox], prepared: [NativeCoreMLDetectionBox], groups: [Int: [Int]],
                         layout: NativeRFDETRLayoutResult?, scopes: [NativeOCRSourceComponentMeasurements.Scope],
                         frameProvider: @escaping () -> NativeOCRRGBAFrame?, exporting: Bool = false,
                         auditCandidatePrefix: String? = nil,
                         liveCandidateAudit369: NativeOCRSourceLocalJoint369Capture.ExportConfiguration = .init(),
                         privateObservationAuditRequests: [NativeOCRPrivateObservationAudit.Request] = [],
                         accepts: (Int, [CGPoint]) -> Bool) -> Result {
        var liveCandidateAudit369 = liveCandidateAudit369
        if !exporting && !liveCandidateAudit369.enabled && SourceChoice402CommonGuardV3.runtimeEnabled {
            liveCandidateAudit369.enabled = true
            liveCandidateAudit369.families = ["source-repair402-select"]
        }
        guard polygons.count == indices.count, exporting || !rules.isEmpty || !nodes.isEmpty else {
            return .init(polygons: polygons, consumed: [], records: [])
        }
        let rows = zip(indices.indices, indices).map { offset, index in
            NativeOCRResidualSourceContext.Region(index: index, polygon: polygons[offset],
                independent: index >= prepared.count, hasInk: hasInk.indices.contains(offset) ? hasInk[offset] : false)
        }
        let byIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0) })
        // Body selection stays OFF until a reviewed policy lists a reachable key.
        // Export collection remains an explicit prefix-only observation request.
        let needsSourceNormal = (exporting && auditCandidatePrefix?.hasPrefix("source-normal-private-v1-") == true) ||
            (!exporting && NativeOCRResidualPrioritySelection.reachableLateKeys.contains {
                $0.hasPrefix("source-normal-private-v1-")
            })
        let needsSourceBodies = (exporting && (auditCandidatePrefix?.hasPrefix("source-body-cc-v3-") == true || needsSourceNormal)) ||
            (!exporting && NativeOCRResidualPrioritySelection.reachableLateKeys.contains {
                $0.hasPrefix("source-body-cc-v3-")
            })
        let needsGeometryEnvelope = exporting || NativeOCRResidualPrioritySelection.reachableLateKeys.contains {
            $0.hasPrefix("prior-envelope-v2-")
        }
        let needsPriorEnvelope = exporting || NativeOCRResidualPrioritySelection.reachableLateKeys.contains {
            $0.hasPrefix("prior-envelope-v1-")
        }
        let needsStrongPrimary = exporting || NativeOCRResidualPrioritySelection.reachableLateKeys.contains {
            $0.hasPrefix("strong-primary-twoaxis-v1-")
        }
        let needsNormalFootprint = liveCandidateAudit369.requestsThisFamily || needsSourceNormal || needsSourceBodies || needsStrongPrimary || exporting || NativeOCRResidualPrioritySelection.reachableLateKeys.contains {
            $0.hasPrefix("private-pca-normal-footprint-v1-")
        }
        let needsPrivatePCA = needsSourceBodies || needsNormalFootprint || exporting || NativeOCRResidualPrioritySelection.reachableLateKeys.contains {
            $0.hasPrefix("private-pca-normal1-")
        }
        // DEFAULT OFF, export-only. Audit requests must be bounded/validated by host.
        // No frame load, observation call or audit object when request list is empty.
        let privateObservationAudit = exporting && !privateObservationAuditRequests.isEmpty ?
            NativeOCRPrivateObservationAudit.Session(enabled: true) : nil
        let base = NativeOCRSourceComponentMeasurements.Context(originals: originals, prepared: prepared,
            groups: groups, scopes: scopes, frameProvider: frameProvider)
        var overrides: [Int: NativeOCRSourceComponentMeasurements.Context] = [:]
        var probeCache: [String: Measurement] = [:]
        func observe(_ index: Int, _ polygon: [CGPoint]) -> Measurement? {
            let key = String(index) + ":" + polygon.map { String(Double($0.x).bitPattern) + "," + String(Double($0.y).bitPattern) }.joined(separator: ";")
            if let cached = probeCache[key] { return cached }
            let sourceContext = overrides[index] ?? base
            let capturePrivate = needsPrivatePCA && byIndex[index]?.polygon == polygon
            guard let m = sourceContext.measure(index: index, polygon: polygon, hasInk: byIndex[index]?.hasInk ?? false, capturePrivateObservation: capturePrivate,
                captureDensePrivateFootprint: needsNormalFootprint && capturePrivate) else { return nil }
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
            guard let sampled = special.measure(index: index, polygon: polygon, hasInk: m.hasInk, capturePrivateObservation: capturePrivate,
                captureDensePrivateFootprint: needsNormalFootprint && capturePrivate), sampled.status == "measured" else { return m }
            overrides[index] = special
            probeCache[key] = sampled
            return sampled
        }
        let context = NativeOCRResidualSourceContext(originals: originals, prepared: prepared, groups: groups,
            regions: rows, layout: layout, frameProvider: frameProvider, measure: observe)
        var measurements: [Int: Measurement] = [:]
        for row in rows { measurements[row.index] = observe(row.index, row.polygon) }
        func originalGuard(_ index: Int) -> [CGPoint] {
            guard let row = byIndex[index] else { return [] }
            var result: [CGPoint] = []
            for member in groups[index] ?? [index] where originals.indices.contains(member) {
                guard let e = originals[member].detectorSeedEvidence, e.isValid else { continue }
                let sx = CGFloat(e.sourceWidth) / CGFloat(e.mapFullWidth), sy = CGFloat(e.sourceHeight) / CGFloat(e.mapFullHeight)
                for c in e.components { for run in c.runs { for x in run.x..<(run.x + run.count) {
                    let p = CGPoint(x: (CGFloat(x) + 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy)
                    if NativeOCRSourceComponentMeasurements.contains(row.polygon, p) { result.append(p) }
                }}}
            }
            return result
        }
        // ADD ONLY support inventory for peer-chain. No baseline measurement/feature replacement.
        // Cache is page-local; every scope-terminal point passes the ORIGINAL child safe+semantic gates.
        var chainObserver: NativeOCRResidualPeerChainObservation?
        func chainIsolatedContext() -> NativeOCRResidualSourceContext {
            if chainObserver == nil {
                chainObserver = NativeOCRResidualPeerChainObservation(originals: originals, prepared: prepared,
                    groups: groups, regions: rows, layout: layout, scopes: scopes, frameProvider: frameProvider)
            }
            return chainObserver!.context
        }
        let chainOffsets = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.index, $0.offset) })
        var chainSupportCache: [Int: [CGPoint]] = [:]
        func chainMandatorySupport(_ index: Int) -> [CGPoint]? {
            if let cached = chainSupportCache[index] { return cached }
            guard let child = measurements[index], child.status == "measured",
                  let offset = chainOffsets[index] else { return nil }
            var childCaps = NativeOCRSourceComponentBounds.protectedCaps(child,
                baseline: baselines.indices.contains(offset) ? baselines[offset] : nil,
                terminal: terminalProofs.indices.contains(offset) ? terminalProofs[offset] : nil,
                point: pointProofs.indices.contains(offset) ? pointProofs[offset] : nil)
            if !child.provisionalOwners.isEmpty || child.status != "measured" { childCaps += originalGuard(index) }
            var points = child.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(child) +
                child.privateHull.map(child.restore) + originalGuard(index) + childCaps
            for terminal in NativeOCRResidualTerminalScopeSupport.candidates(child, context: chainIsolatedContext())
                where terminal.consumedIndices.isEmpty && terminal.key.hasPrefix("scope-terminal-") {
                guard safe(terminal, measurement: child, caps: childCaps, width: width, height: height),
                      accepts(index, terminal.polygon) else { continue }
                points += terminal.supportPoints
            }
            guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let complete = NativeOCRSourceComponentMeasurements.convexHull(points)
            chainSupportCache[index] = complete
            return complete
        }
        var proposals: [Int: NativeOCRResidualCandidate] = [:], records: [[String: Any]] = []
        // Source-only admitted offers are applied after the complete old coordinator.
        // The frozen old output and graph, not a reconstructed earlier prior, bind them.
        var normalRoutingContexts: [Int: (source22: [Double], prior: [CGPoint],
            candidates: [NativeOCRResidualCandidate])] = [:]
        let dimensions = originals.compactMap(\.detectorSeedEvidence).first
        let width = layout?.sourceWidth ?? dimensions?.sourceWidth ?? 0
        let height = layout?.sourceHeight ?? dimensions?.sourceHeight ?? 0
        let routeBeforeCollect = canRouteBeforeCollect(exporting: exporting)
        let runtimeContrast384 = !exporting && !liveCandidateAudit369.requestsThisFamily
        var liveSource22: [Int: [Double]] = [:]
        for (offset, row) in rows.enumerated() {
            guard let m = measurements[row.index] else { continue }
            var values = features(m)
            let earlyEncoded = routeBeforeCollect ? selectedKey(values + [0, 0, 0]) : nil
            if routeBeforeCollect && earlyEncoded == nil && !liveCandidateAudit369.requestsThisFamily && !runtimeContrast384 { continue }
            var caps = NativeOCRSourceComponentBounds.protectedCaps(m,
                baseline: baselines.indices.contains(offset) ? baselines[offset] : nil,
                terminal: terminalProofs.indices.contains(offset) ? terminalProofs[offset] : nil,
                point: pointProofs.indices.contains(offset) ? pointProofs[offset] : nil)
            if !m.provisionalOwners.isEmpty || m.status != "measured" { caps += originalGuard(row.index) }
            let supportAssessment = NativeOCRResidualSupportMinimumRectangle.assess(m, caps: caps)
            if routeBeforeCollect && earlyEncoded == nil {
                // This old route has no terminal alternatives; its actual prefix is zero.
                // Audit-only snapshot, before any coordinator or new pixel acquisition.
                liveSource22[row.index] = values + [0, 0, 0] + supportAssessment.features
                continue
            }
            let targeted = earlyEncoded.flatMap { collectRankedFamilies($0, measurement: m, context: context) }
            let generated = targeted?.items ?? collect(m, context: context, caps: caps, supportAssessment: supportAssessment)
            var validCandidates: [NativeOCRResidualCandidate] = []
            var items: [[String: Any]] = []
            var candidateGeometryEvidence: [String: [Double]] = [:]
            for candidate in generated {
                var reason: String?
                if !safe(candidate, measurement: m, caps: caps, width: width, height: height) { reason = "source-or-frame-containment" }
                if reason == nil && !accepts(row.index, candidate.polygon) { reason = "semantic-admission" }
                if reason == nil {
                    for child in candidate.consumedIndices {
                        guard child != row.index, let childM = measurements[child], childM.status == "measured" else {
                            reason = "unobserved-consumed-source"; break
                        }
                        let support = childM.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(childM) + originalGuard(child)
                        if support.isEmpty || !support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 0.75) }) {
                            reason = "consumed-source-containment"; break
                        }
                    }
                }
                if exporting {
                    items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                        "consumedIndices": candidate.consumedIndices, "accepted": reason == nil, "rejection": reason as Any? ?? NSNull()])
                }
                if reason == nil { validCandidates.append(candidate) }
            }
            // Compose only accepted native parents; recheck the whole joint.
            var acceptedJoints: [NativeOCRResidualCandidate] = []
            for candidate in NativeOCRResidualTerminalExtension.composedCandidates(m, accepted: validCandidates) {
                let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) && accepts(row.index, candidate.polygon)
                if exporting {
                    items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                        "consumedIndices": [], "accepted": admitted,
                        "rejection": admitted ? NSNull() : "joint-semantic-or-source-containment" as Any])
                }
                if admitted { acceptedJoints.append(candidate) }
            }
            let beforeCompletion = validCandidates
            validCandidates = NativeOCRResidualTerminalExtension.completionMenu(validCandidates, acceptedCompositions: acceptedJoints)
            let retainedKeys = Set(validCandidates.map(\.key))
            let prunedKeys = Set((beforeCompletion + acceptedJoints).map(\.key)).subtracting(retainedKeys)
            if exporting {
                // Offline search must use the same eligibility as runtime selection.
                for i in items.indices where (items[i]["key"] as? String).map(prunedKeys.contains) == true {
                    items[i]["accepted"] = false
                    items[i]["rejection"] = "complete-terminal-support-dominated"
                }
            }
            // Strength alternatives inherit a fully accepted native target. A
            // blend must enclose that target and pass semantic admission again.
            for candidate in enclosing(validCandidates, measurement: m, strengths: targeted?.strengths) {
                let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) && accepts(row.index, candidate.polygon)
                if exporting {
                    items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                        "consumedIndices": [], "accepted": admitted,
                        "rejection": admitted ? NSNull() : "enclosing-semantic-or-source-containment" as Any])
                }
                if admitted { validCandidates.append(candidate) }
            }
            if routeBeforeCollect {
                values += [0, 0, 0]
            } else {
                var head: CGFloat = 0, tail: CGFloat = 0
                for candidate in validCandidates {
                    let extent = NativeOCRSourceComponentBounds.bounds(candidate.polygon.map(m.project))
                    if candidate.key.hasPrefix("terminal-head-") { head = max(head, (m.rect.minY - extent.minY) / max(1e-9, m.rect.width)) }
                    if candidate.key.hasPrefix("terminal-tail-") { tail = max(tail, (extent.maxY - m.rect.maxY) / max(1e-9, m.rect.width)) }
                }
                values += [Double(head), Double(tail), validCandidates.contains(where: { !$0.consumedIndices.isEmpty }) ? 1 : 0]
            }
            // Preserve actual support while allowing unused padded parent corners to move.
            // Append after the original sixteen features; legacy admission stays unchanged.
            let supportBlends = NativeOCRResidualSupportMinimumRectangle.supportBlends(m, caps: caps + validCandidates.filter { $0.key.hasPrefix("scope-terminal-") }.flatMap(\.supportPoints), parents: validCandidates)
            for candidate in supportBlends {
                let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                    accepts(row.index, candidate.polygon)
                if exporting {
                    items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                        "consumedIndices": [], "accepted": admitted,
                        "rejection": admitted ? NSNull() : "support-blend-semantic-or-source-containment" as Any])
                }
                if admitted { validCandidates.append(candidate) }
            }
            // Export retains the complete menu; runtime uses audited immutable selector references.
            let lateKeys: Set<String>? = exporting ? nil : NativeOCRResidualPrioritySelection.reachableLateKeys
            let marginKeys = lateKeys.map { Set($0.filter { $0.hasPrefix("support-margin-v1-") }) }
            let asymmetricKeys = lateKeys.map { Set($0.filter { $0.hasPrefix("asymmetric-support-v1-") }) }
            let needsMargins = exporting || !(marginKeys?.isEmpty ?? true)
            let needsAsymmetric = exporting || !(asymmetricKeys?.isEmpty ?? true)
            let lateCaps = needsMargins || needsAsymmetric ? caps + originalGuard(row.index) : []
            // Source-width margins are independent in the two local directions.
            // New candidates must also retain every newly observed full terminal.
            let marginTerminalSupport = validCandidates.filter { $0.key.hasPrefix("scope-terminal-") }.flatMap(\.supportPoints)
            if needsMargins {
                for candidate in NativeOCRResidualSupportMargins.assess(m, caps: lateCaps, allowedKeys: marginKeys) {
                    let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                        accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                            NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                        }
                    if exporting {
                        items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "consumedIndices": [], "accepted": admitted,
                            "rejection": admitted ? NSNull() : "support-margin-semantic-or-full-support-containment" as Any])
                    }
                    if admitted { validCandidates.append(candidate) }
                }
            }
            // Independent source-frame margins retain the same complete mandatory support.
            if needsAsymmetric {
                for candidate in NativeOCRResidualAsymmetricSupport.candidates(m, caps: lateCaps, allowedKeys: asymmetricKeys) {
                    let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                        accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                            NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                        }
                    if exporting {
                        items.append(["key": candidate.key,
                            "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "consumedIndices": [], "accepted": admitted,
                            "rejection": admitted ? NSNull() : "asymmetric-support-semantic-or-full-support-containment" as Any])
                    }
                    if admitted { validCandidates.append(candidate) }
                }
            }
            // The original sixteen features keep their indices and semantics.
            values += supportAssessment.features
            if liveCandidateAudit369.requestsThisFamily || runtimeContrast384 { liveSource22[row.index] = values }
            // Proposed insertion AFTER values += supportAssessment.features (all22), BEFORE selector calls.
            // Runtime remains off while no immutable selector can reference evidence-forward-v1- keys.
            // Parent must derive/pin the final late-key set including this prefix if runtime activation is reviewed.
            let needsForwarded = exporting || NativeOCRResidualPrioritySelection.reachableLateKeys.contains {
                $0.hasPrefix("evidence-forward-v1-")
            }
            if needsForwarded, m.status == "no-private-source" || m.status == "insufficient-private-cells" {
                let forwardedCaps = caps + originalGuard(row.index) + marginTerminalSupport
                for candidate in NativeOCRResidualForwardedCandidateProducer.candidates(m, context: context, caps: forwardedCaps) {
                    var reason: String?
                    if !safe(candidate, measurement: m, caps: caps, width: width, height: height) {
                        reason = "evidence-forward-source-frame-or-support"
                    }
                    if reason == nil && !accepts(row.index, candidate.polygon) {
                        reason = "evidence-forward-semantic-admission"
                    }
                    if reason == nil && !marginTerminalSupport.allSatisfy({
                        NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                    }) { reason = "evidence-forward-complete-terminal-support" }
                    let admitted = reason == nil
                    if exporting {
                        items.append(["key": candidate.key,
                            "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "consumedIndices": [], "accepted": admitted,
                            "rejection": reason as Any? ?? NSNull()])
                    }
                    if admitted { validCandidates.append(candidate) }
                }
            }
            // ADD ONLY after existing feature computation and before existing selector calls.
            let needsPeerChain = exporting || NativeOCRResidualPrioritySelection.reachableLateKeys.contains {
                $0.hasPrefix("peer-chain-v1-")
            }
            if needsPeerChain {
                for candidate in NativeOCRResidualCollinearPeerChainProducer.candidates(m, context: chainIsolatedContext(),
                    mandatorySupport: chainMandatorySupport) {
                    var reason: String?
                    if !safe(candidate, measurement: m, caps: caps, width: width, height: height) {
                        reason = "peer-chain-source-frame-or-support"
                    }
                    if reason == nil && !accepts(row.index, candidate.polygon) {
                        reason = "peer-chain-semantic-admission"
                    }
                    if reason == nil {
                        for index in [row.index] + candidate.consumedIndices {
                            guard let support = chainMandatorySupport(index), !support.isEmpty,
                                  support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 0.75) }) else {
                                reason = "peer-chain-full-child-fresh-terminal-support"; break
                            }
                        }
                    }
                    if exporting {
                        items.append(["key": candidate.key,
                            "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "consumedIndices": candidate.consumedIndices, "accepted": reason == nil,
                            "rejection": reason as Any? ?? NSNull()])
                    }
                    if reason == nil { validCandidates.append(candidate) }
                }
            }
            // Additive intermediate-angle context; all existing metadata and gates remain unchanged.
            let angleKeys = exporting ? nil : Set(NativeOCRResidualPrioritySelection.reachableLateKeys.filter {
                $0.hasPrefix("angle-envelope-v1-")
            })
            if exporting || angleKeys?.isEmpty == false {
                let angleCaps = caps + originalGuard(row.index) + marginTerminalSupport
                for candidate in NativeOCRResidualAngleEnvelope.candidates(m, caps: angleCaps, allowedKeys: angleKeys) {
                    let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                        accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                            NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                        }
                    if exporting {
                        items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "consumedIndices": [], "accepted": admitted,
                            "rejection": admitted ? NSNull() : "angle-envelope-semantic-or-complete-support" as Any])
                    }
                    if admitted { validCandidates.append(candidate) }
                }
            }
            // Complete-support one-sided padding uses the same native geometry and semantic gates.
            let anglePaddingKeys = exporting ? nil : Set(NativeOCRResidualPrioritySelection.reachableLateKeys.filter {
                $0.hasPrefix("angle-padding-v1-")
            })
            if exporting || anglePaddingKeys?.isEmpty == false {
                let paddingCaps = caps + originalGuard(row.index) + marginTerminalSupport
                for candidate in NativeOCRResidualAnglePadding.candidates(m, caps: paddingCaps, allowedKeys: anglePaddingKeys) {
                    let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                        accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                            NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                        }
                    if exporting {
                        items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "consumedIndices": [], "accepted": admitted,
                            "rejection": admitted ? NSNull() : "angle-padding-semantic-or-complete-support" as Any])
                    }
                    if admitted { validCandidates.append(candidate) }
                }
            }
            // RF text bounds propose along-span geometry; mandatory source evidence still gates admission.
            let rfAlongKeys = exporting ? nil : Set(NativeOCRResidualPrioritySelection.reachableLateKeys.filter {
                $0.hasPrefix("rf-text-along-v1-")
            })
            if exporting || rfAlongKeys?.isEmpty == false {
                let rfScopes = (layout?.primitives ?? []).map {
                    NativeOCRResidualRFTextFeatures.Scope(rect: $0.sourceBounds,
                        confidence: Double($0.confidence), semanticClass: $0.semanticClass.rawValue)
                }
                for candidate in NativeOCRResidualRFTextAlong.candidates(m, scopes: rfScopes,
                    frameWidth: width, frameHeight: height, allowedKeys: rfAlongKeys) {
                    let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                        accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                            NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                        }
                    if exporting {
                        items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "consumedIndices": [], "accepted": admitted,
                            "rejection": admitted ? NSNull() : "rf-text-along-semantic-or-complete-support" as Any])
                    }
                    if admitted { validCandidates.append(candidate) }
                }
            }
            // New-only observed geometry: actual old preference is resolved without this family.
            if needsPrivatePCA, let observation = m.privateObservation {
                let rfScopes = (layout?.primitives ?? []).map {
                    NativeOCRResidualRFTextFeatures.Scope(rect: $0.sourceBounds,
                        confidence: Double($0.confidence), semanticClass: $0.semanticClass.rawValue)
                }
                // Export contains every late key; resolve prior from the exact lazy default menu.
                let priorLatePrefixes = ["support-margin-v1-", "asymmetric-support-v1-", "evidence-forward-v1-",
                    "peer-chain-v1-", "angle-envelope-v1-", "angle-padding-v1-", "rf-text-along-v1-"]
                let priorCandidates = validCandidates.filter { candidate in
                    !priorLatePrefixes.contains(where: { candidate.key.hasPrefix($0) }) ||
                        NativeOCRResidualPrioritySelection.reachableLateKeys.contains(candidate.key)
                }
                let prior = NativeOCRResidualPrioritySelection.preferredWithRF(
                    priorCandidates, features: values, incoming: m.polygon, rfScopes: rfScopes)
                var priorQuad = prior?.polygon
                var effectivePrior = prior
                if prior == nil, let encoded = selectedKey(values) {
                    let ranked = encoded.components(separatedBy: " >> ")
                    if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                        for key in ranked {
                            guard let q = priorCandidates.first(where: { $0.key == key }) else { continue }
                            if ranked.count > 1 {
                                guard q.consumedIndices.isEmpty,
                                      !NativeOCRResidualPrivatePCANative.sameQuad(q.polygon, m.polygon) else { continue }
                            }
                            priorQuad = q.polygon; effectivePrior = q; break
                        }
                    }
                }
                let inheritedMembers = effectivePrior?.consumedIndices ?? []
                var inheritedSupport = effectivePrior?.supportPoints ?? []
                var completeRelation = true
                for child in inheritedMembers {
                    guard let childM = measurements[child],
                          let support = chainMandatorySupport(child), !support.isEmpty else {
                        completeRelation = false; break
                    }
                    inheritedSupport += support
                    inheritedSupport += NativeOCRCompleteVisibleGeometry.support(childM,
                        inherited: priorQuad ?? m.polygon)
                }
                if completeRelation, let frame = frameProvider(),
                   let evaluation = NativeOCRResidualPrivatePCANative.evaluate(m,
                    observation: observation, inherited: priorQuad ?? m.polygon,
                    originalGuard: originalGuard(row.index), visible: NativeOCRSourceComponentBounds.visibleForeground(m),
                    protectedCaps: caps + marginTerminalSupport + inheritedSupport, frame: frame) {
                    var candidate = evaluation.candidate
                    candidate.consumedIndices = inheritedMembers
                    candidate.associationKey = effectivePrior?.associationKey ?? effectivePrior?.key
                    let admitted = evaluation.accepted &&
                        safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                        accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                            NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                        }
                    if exporting {
                        items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "consumedIndices": candidate.consumedIndices, "accepted": admitted,
                            "inheritedAssociationKey": candidate.associationKey as Any? ?? NSNull(),
                            "inheritedPriorKey": effectivePrior?.key as Any? ?? NSNull(),
                            "inheritedPriorPolygon": (priorQuad ?? m.polygon).map { ["x": Double($0.x), "y": Double($0.y)] },
                            "inheritedConsumedIndices": inheritedMembers,
                            "rejection": admitted ? NSNull() : (evaluation.accepted ?
                                "private-pca-semantic-or-complete-support" : evaluation.reason) as Any])
                    }
                    if admitted { validCandidates.append(candidate) }
                }
            }
            // Additional geometry only; resolve the complete actual prior after PCA1 exists.
            if needsNormalFootprint, let observation = m.privateObservation,
               let pca = validCandidates.first(where: {
                   $0.key == "private-pca-normal1-retain-prior-along-turning-component-veto-v1"
               }) {
                let rfScopes = (layout?.primitives ?? []).map {
                    NativeOCRResidualRFTextFeatures.Scope(rect: $0.sourceBounds,
                        confidence: Double($0.confidence), semanticClass: $0.semanticClass.rawValue)
                }
                let oldLatePrefixes = ["support-margin-v1-", "asymmetric-support-v1-", "evidence-forward-v1-",
                    "peer-chain-v1-", "angle-envelope-v1-", "angle-padding-v1-", "rf-text-along-v1-"]
                let priorCandidates = validCandidates.filter { candidate in
                    !oldLatePrefixes.contains(where: { candidate.key.hasPrefix($0) }) ||
                        NativeOCRResidualPrioritySelection.reachableLateKeys.contains(candidate.key)
                }
                var prior = NativeOCRResidualPrioritySelection.preferredWithRF(
                    priorCandidates, features: values, incoming: m.polygon, rfScopes: rfScopes)
                if prior == nil, let encoded = selectedKey(values) {
                    let ranked = encoded.components(separatedBy: " >> ")
                    if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                        for key in ranked {
                            guard let q = priorCandidates.first(where: { $0.key == key }) else { continue }
                            if ranked.count > 1 {
                                guard q.consumedIndices.isEmpty,
                                      !NativeOCRResidualPrivatePCANative.sameQuad(q.polygon, m.polygon) else { continue }
                            }
                            prior = q; break
                        }
                    }
                }
                let inherited = prior?.polygon ?? m.polygon
                let children = prior?.consumedIndices ?? []
                var footprints = observation.footprint.map { [$0] } ?? []
                var complete = observation.footprint != nil && pca.consumedIndices == children
                for child in children {
                    guard let footprint = measurements[child]?.privateObservation?.footprint else {
                        complete = false; break
                    }
                    footprints.append(footprint)
                }
                if complete, let frame = frameProvider(),
                   let evaluation = NativeOCRResidualPrivatePCANative.evaluateFootprint(m,
                    observation: observation, pca: pca, inherited: inherited,
                    mandatory: prior?.supportPoints ?? [], footprints: footprints, frame: frame) {
                    var candidate = evaluation.candidate
                    candidate.consumedIndices = children
                    candidate.associationKey = prior?.associationKey ?? prior?.key
                    let admitted = evaluation.accepted &&
                        safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                        accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                            NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                        }
                    if exporting {
                        items.append(["key": candidate.key, "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "consumedIndices": candidate.consumedIndices, "accepted": admitted,
                            "inheritedAssociationKey": candidate.associationKey as Any? ?? NSNull(),
                            "inheritedPriorKey": prior?.key as Any? ?? NSNull(),
                            "inheritedPriorPolygon": inherited.map { ["x": Double($0.x), "y": Double($0.y)] },
                            "inheritedConsumedIndices": children,
                            "rejection": admitted ? NSNull() : (evaluation.accepted ?
                                "normal-footprint-semantic-or-complete-support" : evaluation.reason) as Any])
                    }
                    if admitted { validCandidates.append(candidate) }
                }
            }
            // Source-qualified two-axis offers inherit the actual complete previous selection.
            // Fresh guards and both RGB vetoes remain mandatory; no ownership is created here.
            if needsStrongPrimary, let observation = m.privateObservation {
                let rfScopes = (layout?.primitives ?? []).map {
                    NativeOCRResidualRFTextFeatures.Scope(rect: $0.sourceBounds,
                        confidence: Double($0.confidence), semanticClass: $0.semanticClass.rawValue)
                }
                let available = Set(NativeOCRCurrentAxisStrongPrimaryCapsKeep.minimalCurrentTwo.map(\.key))
                let rf = NativeOCRResidualRFTextFeatures.features(m.polygon, scopes: rfScopes)
                if let requested = NativeOCRCurrentAxisSupportRouting.preferredKey(
                    source22: values, rf8: rf, admittedKeys: available) {
                    let late = ["support-margin-v1-", "asymmetric-support-v1-", "evidence-forward-v1-",
                        "peer-chain-v1-", "angle-envelope-v1-", "angle-padding-v1-", "rf-text-along-v1-"]
                    let priorCandidates = validCandidates.filter { candidate in
                        !late.contains(where: { candidate.key.hasPrefix($0) }) ||
                            NativeOCRResidualPrioritySelection.reachableLateKeys.contains(candidate.key)
                    }
                    var prior = NativeOCRResidualPrioritySelection.preferredWithRF(
                        priorCandidates, features: values, incoming: m.polygon, rfScopes: rfScopes)
                    if prior == nil, let encoded = selectedKey(values) {
                        let ranked = encoded.components(separatedBy: " >> ")
                        if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                            for key in ranked {
                                guard let candidate = priorCandidates.first(where: { $0.key == key }) else { continue }
                                if ranked.count > 1 {
                                    guard candidate.consumedIndices.isEmpty,
                                          !NativeOCRResidualPrivatePCANative.sameQuad(candidate.polygon, m.polygon) else { continue }
                                }
                                prior = candidate; break
                            }
                        }
                    }
                    let inherited = prior?.polygon ?? m.polygon
                    let children = prior?.consumedIndices ?? []
                    var members: [NativeOCRCurrentAxisStrongPrimaryCapsKeep.Member] = []
                    var footprints: [NativeOCRDensePrivateFootprintGuard.Footprint] = []
                    var mandatory = prior?.supportPoints ?? []
                    var complete = true
                    for index in [row.index] + children {
                        guard let member = measurements[index], let observed = member.privateObservation,
                              observed.missingPrivateRGBPixels == 0, let footprint = observed.footprint,
                              let protected = chainMandatorySupport(index), !protected.isEmpty else {
                            complete = false; break
                        }
                        members.append(.init(measurement: member, originalGuard: originalGuard(index),
                                             protectedCaps: protected))
                        footprints.append(footprint)
                        mandatory += protected + NativeOCRCompleteVisibleGeometry.support(member, inherited: inherited)
                    }
                    if complete, let frame = frameProvider() {
                        let configs = NativeOCRCurrentAxisStrongPrimaryCapsKeep.minimalCurrentTwo.filter { $0.key == requested }
                        for offer in NativeOCRCurrentAxisStrongPrimaryCapsKeep.offers(root: m, inherited: inherited,
                            members: members, consumedIndices: children,
                            associationKey: prior?.associationKey ?? prior?.key,
                            sourceFrameSize: .init(width: width, height: height), configurations: configs) {
                            var candidate = offer.candidate
                            candidate.supportPoints += mandatory
                            let evaluation = NativeOCRResidualPrivatePCANative.evaluateStrongPrimary(m,
                                observation: observation, candidate: candidate, inherited: inherited,
                                footprints: footprints, frame: frame)
                            let admitted = evaluation.accepted &&
                                safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                                accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                                    NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                                }
                            if exporting {
                                items.append(["key": candidate.key,
                                    "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                                    "consumedIndices": children, "accepted": admitted,
                                    "inheritedPriorKey": prior?.key as Any? ?? NSNull(),
                                    "inheritedPriorPolygon": inherited.map { ["x": Double($0.x), "y": Double($0.y)] },
                                    "inheritedAssociationKey": candidate.associationKey as Any? ?? NSNull(),
                                    "rejection": admitted ? NSNull() : (evaluation.accepted ?
                                        "strong-primary-twoaxis-original-safe-or-semantic" : evaluation.reason) as Any])
                            }
                            if admitted { validCandidates.append(candidate) }
                        }
                    }
                }
            }
            // Complete prior inclusion makes these source-supported expansion offers non-destructive.
            // Fresh native seed admission and the original semantic/child gates still apply.
            if needsPriorEnvelope {
                let rfScopes = (layout?.primitives ?? []).map {
                    NativeOCRResidualRFTextFeatures.Scope(rect: $0.sourceBounds,
                        confidence: Double($0.confidence), semanticClass: $0.semanticClass.rawValue)
                }
                let late = ["support-margin-v1-", "asymmetric-support-v1-", "evidence-forward-v1-",
                    "peer-chain-v1-", "angle-envelope-v1-", "angle-padding-v1-", "rf-text-along-v1-",
                    "strong-primary-twoaxis-v1-"]
                let priorCandidates = validCandidates.filter { candidate in
                    !late.contains(where: { candidate.key.hasPrefix($0) }) ||
                        NativeOCRResidualPrioritySelection.reachableLateKeys.contains(candidate.key)
                }
                var prior = NativeOCRResidualPrioritySelection.preferredWithRF(
                    priorCandidates, features: values, incoming: m.polygon, rfScopes: rfScopes)
                if prior == nil, let encoded = selectedKey(values) {
                    let ranked = encoded.components(separatedBy: " >> ")
                    if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                        for key in ranked {
                            guard let candidate = priorCandidates.first(where: { $0.key == key }) else { continue }
                            if ranked.count > 1 {
                                guard candidate.consumedIndices.isEmpty,
                                      !NativeOCRResidualPrivatePCANative.sameQuad(candidate.polygon, m.polygon) else { continue }
                            }
                            prior = candidate; break
                        }
                    }
                }
                let inherited = prior?.polygon ?? m.polygon
                let children = prior?.consumedIndices ?? []
                var mandatory = (prior?.supportPoints ?? []) + m.privateHull.map(m.restore)
                var complete = true
                for child in children {
                    guard let childM = measurements[child], let support = chainMandatorySupport(child),
                          !support.isEmpty else { complete = false; break }
                    mandatory += support + NativeOCRCompleteVisibleGeometry.support(childM, inherited: inherited)
                }
                let seedKeys: Set<String> = ["support-margin-v1-n15-a20", "support-margin-v1-n15-a15",
                    "support-margin-v1-n15-a10", "support-margin-v1-n20-a15",
                    "support-margin-v1-n20-a10", "support-margin-v1-n25-a20"]
                let allowed = exporting ? seedKeys : Set(seedKeys.filter {
                    NativeOCRResidualPrioritySelection.reachableLateKeys.contains(
                        $0.replacingOccurrences(of: "support-margin-v1-", with: "prior-envelope-v1-"))
                })
                let seedCaps = caps + originalGuard(row.index) + marginTerminalSupport
                if complete {
                    for seed in NativeOCRResidualSupportMargins.assess(m, caps: seedCaps, allowedKeys: allowed) {
                        let seedAdmitted = safe(seed, measurement: m, caps: caps, width: width, height: height) &&
                            accepts(row.index, seed.polygon) && marginTerminalSupport.allSatisfy {
                                NativeOCRSourceComponentMeasurements.contains(seed.polygon, $0, tolerance: 1e-6)
                            }
                        guard seedAdmitted,
                              let candidate = NativeOCRPriorEnclosingSeed.enclose(seed: seed, inherited: inherited,
                                consumedIndices: children, associationKey: prior?.associationKey ?? prior?.key,
                                mandatory: mandatory, frameSize: .init(width: width, height: height)) else { continue }
                        let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                            accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                                NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                            }
                        if exporting {
                            items.append(["key": candidate.key,
                                "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                                "consumedIndices": children, "accepted": admitted,
                                "inheritedPriorKey": prior?.key as Any? ?? NSNull(),
                                "inheritedPriorPolygon": inherited.map { ["x": Double($0.x), "y": Double($0.y)] },
                                "inheritedAssociationKey": candidate.associationKey as Any? ?? NSNull(),
                                "nativeSeedKey": seed.key,
                                "nativeSeedPolygon": seed.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                                "wholePriorAndSeedContained": true,
                                "rejection": admitted ? NSNull() : "prior-envelope-original-safe-or-semantic" as Any])
                        }
                        if admitted { validCandidates.append(candidate) }
                    }
                }
            }
            // A second family observes the complete current preference, including prior-envelope-v1.
            // Fresh native seed admission and the original semantic/child gates still apply.
            if needsGeometryEnvelope {
                let rfScopes = (layout?.primitives ?? []).map {
                    NativeOCRResidualRFTextFeatures.Scope(rect: $0.sourceBounds,
                        confidence: Double($0.confidence), semanticClass: $0.semanticClass.rawValue)
                }
                let late = ["support-margin-v1-", "asymmetric-support-v1-", "evidence-forward-v1-",
                    "peer-chain-v1-", "angle-envelope-v1-", "angle-padding-v1-", "rf-text-along-v1-",
                    "strong-primary-twoaxis-v1-", "prior-envelope-v1-"]
                let priorCandidates = validCandidates.filter { candidate in
                    !late.contains(where: { candidate.key.hasPrefix($0) }) ||
                        NativeOCRResidualPrioritySelection.reachableLateKeys.contains(candidate.key)
                }
                var prior = NativeOCRResidualPrioritySelection.preferredWithRF(
                    priorCandidates, features: values, incoming: m.polygon, rfScopes: rfScopes)
                if prior == nil, let encoded = selectedKey(values) {
                    let ranked = encoded.components(separatedBy: " >> ")
                    if ranked.count <= 3 && ranked.allSatisfy({ !$0.isEmpty }) {
                        for key in ranked {
                            guard let candidate = priorCandidates.first(where: { $0.key == key }) else { continue }
                            if ranked.count > 1 {
                                guard candidate.consumedIndices.isEmpty,
                                      !NativeOCRResidualPrivatePCANative.sameQuad(candidate.polygon, m.polygon) else { continue }
                            }
                            prior = candidate; break
                        }
                    }
                }
                let inherited = prior?.polygon ?? m.polygon
                let children = prior?.consumedIndices ?? []
                var mandatory = (prior?.supportPoints ?? []) + m.privateHull.map(m.restore)
                var complete = true
                for child in children {
                    guard let childM = measurements[child], let support = chainMandatorySupport(child),
                          !support.isEmpty else { complete = false; break }
                    mandatory += support + NativeOCRCompleteVisibleGeometry.support(childM, inherited: inherited)
                }
                let seedKeys: Set<String> = ["support-margin-v1-n15-a20", "support-margin-v1-n15-a15",
                    "support-margin-v1-n15-a10", "support-margin-v1-n20-a15",
                    "support-margin-v1-n20-a10", "support-margin-v1-n25-a20"]
                let allowed = exporting ? seedKeys : Set(seedKeys.filter {
                    NativeOCRResidualPrioritySelection.reachableLateKeys.contains(
                        $0.replacingOccurrences(of: "support-margin-v1-", with: "prior-envelope-v2-"))
                })
                let seedCaps = caps + originalGuard(row.index) + marginTerminalSupport
                if complete {
                    for seed in NativeOCRResidualSupportMargins.assess(m, caps: seedCaps, allowedKeys: allowed) {
                        let seedAdmitted = safe(seed, measurement: m, caps: caps, width: width, height: height) &&
                            accepts(row.index, seed.polygon) && marginTerminalSupport.allSatisfy {
                                NativeOCRSourceComponentMeasurements.contains(seed.polygon, $0, tolerance: 1e-6)
                            }
                        guard seedAdmitted,
                              let baseCandidate = NativeOCRPriorEnclosingSeed.enclose(seed: seed, inherited: inherited,
                                consumedIndices: children, associationKey: prior?.associationKey ?? prior?.key,
                                mandatory: mandatory, frameSize: .init(width: width, height: height)) else { continue }
                        let candidate = NativeOCRResidualCandidate(
                            key: baseCandidate.key.replacingOccurrences(of: "prior-envelope-v1-", with: "prior-envelope-v2-"),
                            polygon: baseCandidate.polygon, consumedIndices: baseCandidate.consumedIndices,
                            supportPoints: baseCandidate.supportPoints, associationKey: baseCandidate.associationKey)
                        guard let derivedFeatures = NativeOCRPriorEnvelopeGeometryFeatures.routing(
                            prior: inherited, seed: seed.polygon, envelope: candidate.polygon) else { continue }
                        let admitted = safe(candidate, measurement: m, caps: caps, width: width, height: height) &&
                            accepts(row.index, candidate.polygon) && marginTerminalSupport.allSatisfy {
                                NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6)
                            }
                        if exporting {
                            items.append(["key": candidate.key,
                                "polygon": candidate.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                                "consumedIndices": children, "accepted": admitted,
                                "inheritedPriorKey": prior?.key as Any? ?? NSNull(),
                                "inheritedPriorPolygon": inherited.map { ["x": Double($0.x), "y": Double($0.y)] },
                                "inheritedAssociationKey": candidate.associationKey as Any? ?? NSNull(),
                                "nativeSeedKey": seed.key,
                                "nativeSeedPolygon": seed.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                                "wholePriorAndSeedContained": true,
                                "geometryFeatures": derivedFeatures,
                                "rejection": admitted ? NSNull() : "prior-envelope-v2-original-safe-or-semantic" as Any])
                        }
                        if admitted {
                            validCandidates.append(candidate)
                            candidateGeometryEvidence[candidate.key] = derivedFeatures
                        }
                    }
                }
            }
            let old351Candidates = validCandidates
            var admittedSourceBodies: [NativeOCRResidualCandidate] = []
            let explicitBodyExport = exporting && auditCandidatePrefix?.hasPrefix("source-body-cc-v3-") == true
            if needsSourceBodies && (explicitBodyExport || NativeOCRResidualPrioritySelection.sourceBodyMayGenerate(values)) {
                let rfScopes = (layout?.primitives ?? []).map {
                    NativeOCRResidualRFTextFeatures.Scope(rect: $0.sourceBounds,
                        confidence: Double($0.confidence), semanticClass: $0.semanticClass.rawValue)
                }
                // Snapshot ALL old producers. Generator always resolves the immutable
                // old351 API, including the Bank's encoded fallback, never itself.
                let prior = NativeOCRCurrentPrior351.resolveFromOld351API(
                    oldCandidates: validCandidates, features: values, incoming: m.polygon,
                    rfScopes: rfScopes, geometryFeatures: candidateGeometryEvidence)
                let body = NativeOCRSourceBodyCandidate357.generate(parent: m, prior: prior,
                    measurements: measurements, frameSize: .init(width: width, height: height),
                    capsForSource: { source in
                        guard let sourceOffset = chainOffsets[source.index] else { return nil }
                        var actual = NativeOCRSourceComponentBounds.protectedCaps(source,
                            baseline: baselines.indices.contains(sourceOffset) ? baselines[sourceOffset] : nil,
                            terminal: terminalProofs.indices.contains(sourceOffset) ? terminalProofs[sourceOffset] : nil,
                            point: pointProofs.indices.contains(sourceOffset) ? pointProofs[sourceOffset] : nil)
                        if !source.provisionalOwners.isEmpty || source.status != "measured" {
                            actual += originalGuard(source.index)
                        }
                        return actual
                    }, originalOwnedSupport: originalGuard, frameProvider: frameProvider,
                    accepts: accepts)
                items += body.records
                validCandidates += body.candidates
                admittedSourceBodies = body.candidates
            }
            // Immutable v361 menu snapshot. A new normal producer NEVER resolves
            // its prior through its own future selector or changes body membership.
            let sourceBody361Candidates = validCandidates
            func sourceBody361Preference() -> NativeOCRResidualCandidate? {
                let rfScopes = (layout?.primitives ?? []).map {
                    NativeOCRResidualRFTextFeatures.Scope(rect: $0.sourceBounds,
                        confidence: Double($0.confidence), semanticClass: $0.semanticClass.rawValue)
                }
                return NativeOCRResidualPrioritySelection.preferredWithSourceBodies(
                    sourceBody361Candidates, old351Candidates: old351Candidates,
                    features: values, incoming: m.polygon, rfScopes: rfScopes,
                    geometryFeatures: candidateGeometryEvidence, bodySelectionEnabled: needsSourceBodies,
                    preferredBodyKey: { prior in
                        NativeOCRResidualPrioritySelection.sourceBodyPreferredKey(
                            admittedSourceBodies, source22: values, prior: prior.polygon)
                    }, validateBody: { candidate, _ in
                        admittedSourceBodies.contains {
                            $0.key == candidate.key && $0.polygon == candidate.polygon &&
                                $0.consumedIndices == candidate.consumedIndices &&
                                $0.associationKey == candidate.associationKey
                        }
                    })
            }
            var admittedSourceNormals: [NativeOCRResidualCandidate] = []
            var sourceNormalPrior: NativeOCRCurrentPrior351.Resolution?
            if needsSourceNormal && (exporting || NativeOCRResidualPrioritySelection.sourceNormalMayGenerate(values)) {
                let prior = NativeOCRCurrentPrior351.resolve(oldCandidates: sourceBody361Candidates,
                    features: values, incoming: m.polygon,
                    oldPreferred351: { _, _, _ in sourceBody361Preference() }, encoded351: selectedKey)
                sourceNormalPrior = prior
                let normal = NativeOCRSourceNormalSupport363.generate(parent: m, prior: prior,
                    measurements: measurements, frameSize: .init(width: width, height: height),
                    capsForSource: { source in
                        guard let sourceOffset = chainOffsets[source.index] else { return nil }
                        var actual = NativeOCRSourceComponentBounds.protectedCaps(source,
                            baseline: baselines.indices.contains(sourceOffset) ? baselines[sourceOffset] : nil,
                            terminal: terminalProofs.indices.contains(sourceOffset) ? terminalProofs[sourceOffset] : nil,
                            point: pointProofs.indices.contains(sourceOffset) ? pointProofs[sourceOffset] : nil)
                        if !source.provisionalOwners.isEmpty || source.status != "measured" {
                            actual += originalGuard(source.index)
                        }
                        return actual
                    }, originalOwnedSupport: originalGuard,
                    allowsGeometry: exporting ? nil : { candidate in
                        NativeOCRResidualPrioritySelection.sourceNormalAllowsGeometry(candidate,
                            source22: values, prior: prior.polygon)
                    }, frameProvider: frameProvider, accepts: accepts)
                admittedSourceNormals = normal.candidates
                if !exporting && NativeOCRSourceNormalRouting367.mayGenerate(values) {
                    normalRoutingContexts[row.index] = (values, prior.polygon, normal.candidates)
                }
                items += normal.records
                validCandidates += normal.candidates
            }
            if !exporting {
                var preferred = sourceBody361Preference()
                if let prior = sourceNormalPrior,
                   let key = NativeOCRResidualPrioritySelection.sourceNormalPreferredKey(
                    admittedSourceNormals, source22: values, prior: prior.polygon),
                   let normal = admittedSourceNormals.first(where: { $0.key == key }),
                   normal.consumedIndices == prior.consumedIndices,
                   normal.associationKey == prior.inheritedAssociationKey {
                    preferred = normal
                }
                if let preferred { proposals[row.index] = preferred }
            }
            if !exporting, proposals[row.index] == nil, let encoded = selectedKey(values) {
                let rankedKeys = encoded.components(separatedBy: " >> ")
                if rankedKeys.count <= 3 && rankedKeys.allSatisfy({ !$0.isEmpty }) {
                    for key in rankedKeys {
                        guard let selected = validCandidates.first(where: { $0.key == key }) else { continue }
                        if rankedKeys.count > 1 {
                            // Ranked source-evidence fallbacks never consume peers,
                            // and a geometric no-op must not hide a later correction.
                            guard selected.consumedIndices.isEmpty else { continue }
                            var unchanged = false
                            if selected.polygon.count == 4 && m.polygon.count == 4 {
                                for reversed in [false, true] {
                                    let q = reversed ? Array(selected.polygon.reversed()) : selected.polygon
                                    for shift in 0..<4 where !unchanged {
                                        unchanged = (0..<4).allSatisfy { i in
                                            let a = q[(i + shift) % 4], b = m.polygon[i]
                                            return hypot(a.x - b.x, a.y - b.y) <= 1e-8
                                        }
                                    }
                                }
                            }
                            if unchanged { continue }
                        }
                        proposals[row.index] = selected
                        break
                    }
                }
            }
            if exporting {
                // Filter serialized audit records only; all collection/admission above is unchanged.
                let serializedItems = auditCandidatePrefix.map { prefix in
                    items.filter { ($0["key"] as? String)?.hasPrefix(prefix) == true }
                } ?? items
                var record: [String: Any] = ["sourceIndex": row.index, "features": values, "status": m.status,
                    "provisionalOwners": m.provisionalOwners, "associatedOwners": m.associatedOwners,
                    "guardPoints": m.guardPoints.count,
                    "guardHull": NativeOCRSourceComponentMeasurements.convexHull(m.guardPoints + originalGuard(row.index)).map { [Double($0.x),Double($0.y)] },
                    "visibleHull": NativeOCRSourceComponentMeasurements.convexHull(NativeOCRSourceComponentBounds.visibleForeground(m)).map { [Double($0.x),Double($0.y)] },
                    "terminalCaps": caps.map { [Double($0.x),Double($0.y)] }, "candidates": serializedItems]
                if let privateObservationAudit,
                   let request = privateObservationAuditRequests.first(where: { $0.sourceIndex == row.index }),
                   let payload = privateObservationAudit.capture(load: {
                       guard let frame = frameProvider() else { return nil }
                       return .init(identity: request.identity, measurement: m,
                           inherited: request.inherited, proposed: request.proposed,
                           memberIndices: groups[row.index] ?? [row.index],
                           hasContextOverride: overrides[row.index] != nil, terminalCaps: caps, frame: frame)
                   }) {
                    record["privateObservationTerminalAudit"] = payload
                }
                if let auditCandidatePrefix {
                    let reusedItems = items.filter { ($0["key"] as? String)?.hasPrefix(auditCandidatePrefix) != true }
                    record["reusedCandidateCount"] = reusedItems.count
                    record["reusedCandidateDigest"] = NativeOCRResidualCandidateAuditDigest.digest(reusedItems) as Any? ?? NSNull()
                    record["reusedCandidateDigestSchema"] = NativeOCRResidualCandidateAuditDigest.schema
                }
                records.append(record)
            }
        }
        var output = polygons, consumed = Set<Int>(), claimedParents = Set<Int>(), associations: [[String: Any]] = []
        let offsets = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        let ordered = proposals.keys.sorted {
            let a = NativeOCRSourceComponentBounds.bounds(polygons[offsets[$0]!])
            let b = NativeOCRSourceComponentBounds.bounds(polygons[offsets[$1]!])
            return a.width * a.height == b.width * b.height ? $0 < $1 : a.width * a.height > b.width * b.height
        }
        var appliedProposals: [Int: NativeOCRResidualCandidate] = [:]
        for index in ordered where !consumed.contains(index) {
            guard let candidate = proposals[index], candidate.consumedIndices.allSatisfy({ !consumed.contains($0) && !claimedParents.contains($0) }),
                  let offset = offsets[index] else { continue }
            output[offset] = candidate.polygon
            appliedProposals[index] = candidate
            consumed.formUnion(candidate.consumedIndices)
            if !candidate.consumedIndices.isEmpty {
                claimedParents.insert(index)
                associations.append(["parent": index, "members": [index] + candidate.consumedIndices.sorted(),
                    "key": candidate.associationKey ?? candidate.key])
            }
        }
        let auditOrientation392 = liveCandidateAudit369.requestsOrientation392
        let runtimePolicy403 = !exporting && NativeOCRSourcePolicyRuntime403.enabled
        let trackFinalPolicy403 = auditOrientation392 || runtimePolicy403
        var joint369Applied368 = appliedProposals
        // Polygon-only refinement of the actual old retained outputs. Never rerun
        // area ordering or alter membership after this source-only preference.
        if !exporting {
            for index in indices where !consumed.contains(index) {
                guard let offset = offsets[index], let context = normalRoutingContexts[index],
                      let candidate = context.candidates.first(where: {
                          $0.key == NativeOCRSourceNormalRouting367.key
                      }),
                      candidate.consumedIndices.sorted() == (appliedProposals[index]?.consumedIndices ?? []).sorted(),
                      (candidate.consumedIndices.isEmpty || candidate.associationKey ==
                          (appliedProposals[index]?.associationKey ?? appliedProposals[index]?.key)),
                      NativeOCRSourceNormalRouting367.preferredKey([
                          .init(key: candidate.key, polygon: candidate.polygon,
                              supportPoints: candidate.supportPoints, generatedFromPrior: context.prior)
                      ], source22: context.source22, current366Prior: output[offset]) != nil else { continue }
                output[offset] = candidate.polygon
                if liveCandidateAudit369.requestsThisFamily || runtimeContrast384 {
                    let applied = appliedProposals[index]
                    let children = applied?.consumedIndices ?? []
                    let association = children.isEmpty ? applied?.associationKey : (applied?.associationKey ?? applied?.key)
                    joint369Applied368[index] = .init(key: candidate.key, polygon: candidate.polygon,
                        consumedIndices: children,
                        supportPoints: (applied?.supportPoints ?? []) + candidate.supportPoints,
                        associationKey: association)
                }
            }
        }
        // Requested audit ONLY: retain ACTUAL constructor candidates, not geometry-only copies.
        // Initialize after367; update for every actually selected386/385 below.
        var applied392: [Int: NativeOCRResidualCandidate]? = trackFinalPolicy403 ? joint369Applied368 : nil
        // EXPORT ONLY after actual368's final coordinator AND routing. This code
        // never assigns output, proposals, consumed, associations or recognition metadata.
        if liveCandidateAudit369.requestsThisFamily || runtimeContrast384 {
            if exporting {
                records.append(["family": NativeOCRSourceLocalJoint369.family, "admitted": false,
                    "hardRejections": ["live-export-requires-actual368-exporting-false"]])
            } else if let graph = NativeOCRSourceLocalJoint369Capture.finalGraph(indices: indices,
                output: output, consumed: consumed, associations: associations, groups: groups,
                applied: joint369Applied368) {
                var capturedRoots = 0
                for row in rows where graph.live.contains(row.index) {
                    guard let source22 = liveSource22[row.index] else {
                        records.append(["sourceIndex": row.index, "family": NativeOCRSourceLocalJoint369.family,
                            "geometryProposed": false, "admitted": false, "softRejections": ["source22-snapshot-unavailable"]])
                        continue
                    }
                    guard let m = measurements[row.index], let prior = graph.prior(row.index) else { continue }
                    let allRF385 = (layout?.primitives ?? []).map {
                        NativeOCRSourceLocalJoint369.Scope(rect: $0.sourceBounds,
                            semanticClass: $0.semanticClass.rawValue, confidence: Double($0.confidence))
                    }
                    let wantsRF385 = runtimeContrast384 && m.status != "measured" &&
                        Nonexclusive377RFPolicy.mayGenerate385(prior: prior.polygon, rfScopes: allRF385)
                    if runtimeContrast384 && !wantsRF385 &&
                        (!NativeOCRSourceContrastPolicy384.mayGenerate(source22) ||
                         !NativeOCRSourceContrastPolicy384.longPrior385(prior.polygon) || m.status != "measured") { continue }
                    if liveCandidateAudit369.necessarySourceGate371 &&
                        !NativeOCRSourceLocalJoint369Preflight.mayGenerate(source22) { continue }
                    // This explicit family restores sources without a measured native body.
                    // Successful measured sources stay on their existing producer. No RGB read.
                    if liveCandidateAudit369.requestsNonexclusive374 && !liveCandidateAudit369.requestsJoint369 &&
                        m.status == "measured" { continue }
                    guard runtimeContrast384 || capturedRoots < liveCandidateAudit369.maximumRoots else {
                        records.append(["sourceIndex": row.index, "family": NativeOCRSourceLocalJoint369.family,
                            "geometryProposed": false, "admitted": false, "softRejections": ["explicit-host-root-budget"]])
                        continue
                    }
                    capturedRoots += 1
                    guard let search = NativeOCRSourceLocalJoint369.probe(prior: prior.polygon,
                            sourceWidth: m.rect.width, frameSize: .init(width: width, height: height)) else {
                        records.append(["sourceIndex": row.index, "family": NativeOCRSourceLocalJoint369.family,
                            "geometryProposed": false, "admitted": false, "softRejections": ["no-local-search-metadata"]])
                        continue
                    }
                    let roi = CGRect(x: CGFloat(search.window.left), y: CGFloat(search.window.top),
                                     width: CGFloat(search.window.width), height: CGFloat(search.window.height))
                    let certification = NativeOCRSourceLocalJoint369Capture.localPeerEvidence(root: row.index,
                        graph: graph, measurements: measurements, originals: originals,
                        frameSize: .init(width: width, height: height), probeROI: roi, layout: layout)
                    guard let peers = certification.evidence, let originalFrame = frameProvider() else {
                        records.append(["sourceIndex": row.index, "family": NativeOCRSourceLocalJoint369.family,
                            "geometryProposed": false, "admitted": false, "softRejections": ["no-local-source-session"],
                            "localPeerEvidence": certification.record])
                        continue
                    }
                    let roles = (layout?.primitives ?? []).filter { $0.sourceBounds.intersects(roi) }.map {
                        NativeOCRSourceLocalJoint369.Scope(rect: $0.sourceBounds,
                            semanticClass: $0.semanticClass.rawValue, confidence: Double($0.confidence))
                    }
                    // ONE original-RGB copy + authentic body session for this root.
                    // Parent may pass this same immutable `live` to other369 factories.
                    let live = NativeOCRSourceLocalJoint369.captureLive(currentPrior: prior,
                        actualGraph: graph, measurement: m, originalFrame: originalFrame,
                        localPeerEvidence: peers, measurements: measurements,
                        capsForSource: { source in
                            guard let offset = chainOffsets[source.index] else { return nil }
                            var points = NativeOCRSourceComponentBounds.protectedCaps(source,
                                baseline: baselines.indices.contains(offset) ? baselines[offset] : nil,
                                terminal: terminalProofs.indices.contains(offset) ? terminalProofs[offset] : nil,
                                point: pointProofs.indices.contains(offset) ? pointProofs[offset] : nil)
                            if !source.provisionalOwners.isEmpty || source.status != "measured" { points += originalGuard(source.index) }
                            return points
                        }, originalOwnedSupport: originalGuard, scopes: roles, sharedWindow: search.window)
                    // Nonexclusive fallback is triggered by ACTUAL live-session
                    // unavailability, not merely privateObservation == nil. Covers
                    // nonnil footprintless/empty/malformed footprints, missing RGB,
                    // and fresh authenticated body observation failure as well.
                    if live == nil && (liveCandidateAudit369.requestsNonexclusive374 || wantsRF385) {
                        let nonexclusive = NativeOCRNonexclusiveLane369BankSplice.capture(
                            root: row.index, graph: graph, originals: originals,
                            measurements: measurements, originalFrame: originalFrame,
                            scopes: roles,
                            capsForSource: { source in
                                guard let sourceOffset = chainOffsets[source.index] else { return nil }
                                var actual = NativeOCRSourceComponentBounds.protectedCaps(source,
                                    baseline: baselines.indices.contains(sourceOffset) ? baselines[sourceOffset] : nil,
                                    terminal: terminalProofs.indices.contains(sourceOffset) ? terminalProofs[sourceOffset] : nil,
                                    point: pointProofs.indices.contains(sourceOffset) ? pointProofs[sourceOffset] : nil)
                                if !source.provisionalOwners.isEmpty || source.status != "measured" {
                                    actual += originalGuard(source.index)
                                }
                                return actual
                            }, originalOwnedSupport: originalGuard, accepts: accepts)
                        var nonexclusiveRecord = nonexclusive.record
                        nonexclusiveRecord["source22Prefix"] = source22
                        if wantsRF385 {
                            if let candidate = Nonexclusive377RFPolicy.preferred(admitted: nonexclusive.candidates,
                                    prior: prior, rootMeasurementStatus: m.status, rfScopes: roles),
                               let offset = offsets[row.index] {
                                output[offset] = candidate.polygon
                                if trackFinalPolicy403 { applied392?[row.index] = candidate }
                                records.append(["sourceIndex":row.index,"family":"nonexclusive-rf-policy385",
                                    "selectedKey":candidate.key,"polygon":candidate.polygon.map { [Double($0.x),Double($0.y)] },
                                    "ownershipOrGraphChanged":false,"sourceOnlySelection":true])
                            }
                            continue
                        }
                        records.append(nonexclusiveRecord)
                        // rawWindow is shareable ORIGINAL RGBA, never private Body.Evidence.
                    }
                    guard let live else {
                        records.append(["sourceIndex": row.index, "family": NativeOCRSourceLocalJoint369.family,
                            "geometryProposed": false, "admitted": false, "softRejections": ["actual-local-source-observation-unavailable"],
                            "localPeerEvidence": certification.record])
                        continue
                    }
                    if !liveCandidateAudit369.requestsJoint369 && !runtimeContrast384 { continue }
                    let generated = NativeOCRSourceLocalJoint369.generateFromLive(currentPrior: prior,
                        actualGraph: graph, measurement: m, originalFrame: originalFrame,
                        localPeerEvidence: peers, liveObservation: live,
                        componentDiagnostics371: liveCandidateAudit369.componentDiagnostics371,
                        protectObservedContrast380: liveCandidateAudit369.requestsContrast380 || runtimeContrast384,
                        preserveEndpoints380: true, accepts: accepts)
                    if runtimeContrast384 {
                        if let candidate = NativeOCRSourceContrastPolicy384.preferred(generated, prior: prior, source22: source22),
                           candidate.consumedIndices == prior.consumedIndices,
                           candidate.associationKey == prior.inheritedAssociationKey,
                           let offset = offsets[row.index] {
                            output[offset] = candidate.polygon
                            if trackFinalPolicy403 { applied392?[row.index] = candidate }
                            records.append(["sourceIndex":row.index,"family":"source-enclosing-union386",
                                "selectedKey":candidate.key,"polygon":candidate.polygon.map { [Double($0.x),Double($0.y)] },
                                "nominalMenuCount":generated.nominalMenu384.count,
                                "ownershipOrGraphChanged":false,"sourceOnlySelection":true])
                        }
                        continue
                    }
                    records.append(["sourceIndex": row.index, "family": NativeOCRSourceLocalJoint369.family,
                        "source22Prefix": source22,
                        "current368FinalPolygon": prior.polygon.map { [Double($0.x), Double($0.y)] },
                        "actualResidualChildren": prior.consumedIndices,
                        "actualAssociationKey": prior.inheritedAssociationKey as Any? ?? NSNull(),
                        "sourceWindow": [search.window.left, search.window.top, search.window.width, search.window.height],
                        "candidates": generated.records, "admittedCandidateCount": generated.candidates.count,
                        "sharedOriginalRGBSession": true, "outputOrGraphMutated": false, "automaticSelection": false])
                }
                records.append(["family": NativeOCRSourceLocalJoint369.family,
                    "source22Prefixes": rows.compactMap { row -> [String: Any]? in
                        guard let values = liveSource22[row.index] else { return nil }
                        return ["sourceIndex": row.index, "values": values]
                    }, "sourceRowCount": rows.count, "snapshotCount": liveSource22.count,
                    "liveRootCount": graph.live.count, "capturedRoots": capturedRoots,
                    "necessarySourceGate371": liveCandidateAudit369.necessarySourceGate371,
                    "outputOrGraphMutated": false])
            }
        }
        var postPolicyMeasurements403: [Int: Measurement]?
        if runtimePolicy403, let actualApplied = applied392,
           let actualGraph = NativeOCRSourceLocalJoint369Capture.finalGraph(indices: indices,
                output: output, consumed: consumed, associations: associations, groups: groups,
                applied: actualApplied) {
            let correction = NativeOCRSourcePolicyRuntime403.apply(graph: actualGraph,
                order: rows.map(\.index), measurements: measurements, sourcePrefixes: liveSource22,
                originals: originals, layout: layout, width: width, height: height,
                frameProvider: frameProvider,
                freshMeasurement: { index, old in
                    guard let row = byIndex[index] else { return nil }
                    return (overrides[index] ?? base).measure(index: index, polygon: row.polygon,
                        hasInk: old.hasInk, capturePrivateObservation: true, captureDensePrivateFootprint: true)
                }, capsForSource: { source in
                    guard let offset = chainOffsets[source.index] else { return nil }
                    var caps = NativeOCRSourceComponentBounds.protectedCaps(source,
                        baseline: baselines.indices.contains(offset) ? baselines[offset] : nil,
                        terminal: terminalProofs.indices.contains(offset) ? terminalProofs[offset] : nil,
                        point: pointProofs.indices.contains(offset) ? pointProofs[offset] : nil)
                    if !source.provisionalOwners.isEmpty || source.status != "measured" {
                        caps += originalGuard(source.index)
                    }
                    return caps
                }, originalOwnedSupport: originalGuard, accepts: accepts)
            for (index, polygon) in correction.polygons {
                if let offset = offsets[index] { output[offset] = polygon }
            }
            for (index, candidate) in correction.applied { applied392?[index] = candidate }
            records += correction.records
            postPolicyMeasurements403 = correction.measurements
        }
        // DEFAULT-OFF generic audit, AFTER actual386 output. No coordinator or selection rerun.
        // Existing requestsThisFamily remains unchanged: only392 still runs runtimeContrast384.
        // The selector's immutable source preconditions are necessary, so a page with
        // no eligible retained root needs no passive dense observation or RGB menu.
        let anyEligibleSource402 = !liveCandidateAudit369.requestsRepair402Select || rows.contains { row in
            guard !consumed.contains(row.index) else { return false }
            let source = liveSource22[row.index] ?? []
            return source.count >= 10 && source.prefix(10).allSatisfy(\.isFinite) &&
                source[9] == 1 && source[7] >= 0 &&
                source[7] <= 0.03
        }
        if auditOrientation392 && anyEligibleSource402 {
            let family392 = liveCandidateAudit369.requestsRepair402 ? "source-repair402" :
                liveCandidateAudit369.requestsSharedBoundary400 ? "source-shared-boundary400" :
                liveCandidateAudit369.requestsBoundaryPrior399 ? "source-boundary-prior399" :
                (liveCandidateAudit369.requestsBoundaryPrior397 ? "source-boundary-prior397" :
                (liveCandidateAudit369.requestsBoundaryOrientation397 ? "source-boundary-orientation397" : "source-axis-orientation392"))
            func absent392(_ index: Int?, _ reason: String) {
                var record: [String: Any] = ["family": family392, "geometryProposed": false,
                    "admitted": false, "unavailableReason": reason,
                    "automaticSelection": false, "outputOrGraphMutated": false]
                if let index { record["sourceIndex"] = index }
                records.append(record)
            }
            if exporting {
                absent392(nil, "actual386-live-audit-requires-exporting-false")
            } else if let capturedApplied392 = applied392,
                let graph392 = NativeOCRSourceLocalJoint369Capture.finalGraph(indices: indices,
                    output: output, consumed: consumed, associations: associations, groups: groups,
                    applied: capturedApplied392) {
                // STRICT PASSIVE: enrichment begins only after386 output AND final graph.
                // Never call observe(): it writes legacy probeCache/overrides. Retain canonical
                // old metadata and add ONLY a fresh native privateObservation to this local copy.
                var measurements392 = postPolicyMeasurements403 ?? measurements
                var measurementUnavailable392: [Int: String] = [:]
                var measurementRecords392: [[String: Any]] = []
                for sourceRow in rows {
                    guard let old = measurements392[sourceRow.index] ?? measurements[sourceRow.index] else {
                        measurementUnavailable392[sourceRow.index] = "canonical-measurement-absent"
                        measurementRecords392.append(["sourceIndex": sourceRow.index,
                            "status": "canonical-measurement-absent"]); continue
                    }
                    if NativeOCRSourceLocalJoint369Capture.hasCompletePrivate392(old, width: width, height: height) {
                        measurementRecords392.append(["sourceIndex": sourceRow.index,
                            "status": "reused-existing-native-complete-observation", "ordinaryMetadataExact": true])
                        continue
                    }
                    let auditContext392 = overrides[sourceRow.index] ?? base
                    guard let fresh = auditContext392.measure(index: sourceRow.index,
                        polygon: sourceRow.polygon, hasInk: old.hasInk,
                        capturePrivateObservation: true, captureDensePrivateFootprint: true) else {
                        measurementUnavailable392[sourceRow.index] = "post386-context-measure-returned-nil"
                        measurementRecords392.append(["sourceIndex": sourceRow.index,
                            "status": "post386-context-measure-returned-nil"]); continue
                    }
                    let different = NativeOCRSourceLocalJoint369Capture.metadataDifferences392(old, fresh)
                    guard different.isEmpty else {
                        measurementUnavailable392[sourceRow.index] = "post386-ordinary-metadata-mismatch"
                        measurementRecords392.append(["sourceIndex": sourceRow.index,
                            "status": "post386-ordinary-metadata-mismatch", "differentFields": different,
                            "canonicalStatus": old.status, "freshStatus": fresh.status,
                            "ordinaryMetadataExact": false]); continue
                    }
                    guard NativeOCRSourceLocalJoint369Capture.hasCompletePrivate392(fresh, width: width, height: height) else {
                        measurementUnavailable392[sourceRow.index] = "post386-private-dense-observation-unavailable"
                        measurementRecords392.append(["sourceIndex": sourceRow.index,
                            "status": "post386-private-dense-observation-unavailable",
                            "nativeMeasurementStatus": fresh.status, "ordinaryMetadataExact": true]); continue
                    }
                    var enhanced392 = old
                    enhanced392.privateObservation = fresh.privateObservation
                    measurements392[sourceRow.index] = enhanced392
                    measurementRecords392.append(["sourceIndex": sourceRow.index,
                        "status": "post386-private-observation-enriched-only", "ordinaryMetadataExact": true,
                        "legacyMeasurementOrProbeCacheWritten": false])
                }
                // Unavailable postphase measurements are absent ONLY from the audit view;
                // peer capture therefore cannot mistake stale/incomplete private data for fresh evidence.
                for index in measurementUnavailable392.keys { measurements392.removeValue(forKey: index) }
                var attempted392 = 0
                let limit392 = min(256, max(0, liveCandidateAudit369.maximumRoots))
                // Generic all-live inventory: no target IDs, page tables, hashes or source feature filter.
                for row in rows.sorted(by: { $0.index < $1.index }) where graph392.live.contains(row.index) {
                    guard attempted392 < limit392 else {
                        absent392(row.index, "explicit-host-root-budget-max256"); continue
                    }
                    attempted392 += 1
                    guard let prior = graph392.prior(row.index) else {
                        absent392(row.index, "actual386-current-prior-or-measurement-unavailable"); continue
                    }
                    let actualSources392 = [row.index] + prior.consumedIndices
                    let unavailableSources392 = actualSources392.filter {
                        measurementUnavailable392[$0] != nil || measurements392[$0] == nil
                    }
                    guard unavailableSources392.isEmpty, let m = measurements392[row.index] else {
                        records.append(["family": family392, "sourceIndex": row.index, "admitted": false,
                            "unavailableReason": "actual-root-member-audit-measurement-unavailable",
                            "unavailableSourceIndices": unavailableSources392,
                            "automaticSelection": false, "outputOrGraphMutated": false]); continue
                    }
                    // Necessary source-only conditions of CommonGuard, before expensive RGB operators.
                    if liveCandidateAudit369.requestsRepair402Select {
                        let source = liveSource22[row.index] ?? []
                        let limit = 0.03
                        guard source.count >= 10, source.prefix(10).allSatisfy(\.isFinite),
                              source[9] == 1, source[7] >= 0, source[7] <= limit else {
                            absent392(row.index, "source402-common-guard-necessary-axis-or-ink-condition"); continue
                        }
                    }
                    guard let search = NativeOCRSourceLocalJoint369.probe(prior: prior.polygon,
                        sourceWidth: m.rect.width, frameSize: .init(width: width, height: height)) else {
                        absent392(row.index, "actual386-source-width-probe-unavailable"); continue
                    }
                    let roi = CGRect(x: CGFloat(search.window.left), y: CGFloat(search.window.top),
                        width: CGFloat(search.window.width), height: CGFloat(search.window.height))
                    let certification = NativeOCRSourceLocalJoint369Capture.localPeerEvidence(root: row.index,
                        graph: graph392, measurements: measurements392, originals: originals,
                        frameSize: .init(width: width, height: height), probeROI: roi, layout: layout)
                    guard let peers = certification.evidence else {
                        records.append(["family": family392, "sourceIndex": row.index, "admitted": false,
                            "unavailableReason": "actual-current-peer-evidence-unavailable",
                            "localPeerEvidence": certification.record, "automaticSelection": false,
                            "outputOrGraphMutated": false]); continue
                    }
                    guard let originalFrame = frameProvider() else {
                        absent392(row.index, "actual-original-frame-unavailable"); continue
                    }
                    let roles = (layout?.primitives ?? []).filter { $0.sourceBounds.intersects(roi) }.map {
                        NativeOCRSourceLocalJoint369.Scope(rect: $0.sourceBounds,
                            semanticClass: $0.semanticClass.rawValue, confidence: Double($0.confidence))
                    }
                    guard let live = NativeOCRSourceLocalJoint369.captureLive(currentPrior: prior,
                        actualGraph: graph392, measurement: m, originalFrame: originalFrame,
                        localPeerEvidence: peers, measurements: measurements392,
                        capsForSource: { source in
                            guard let offset = chainOffsets[source.index] else { return nil }
                            var caps = NativeOCRSourceComponentBounds.protectedCaps(source,
                                baseline: baselines.indices.contains(offset) ? baselines[offset] : nil,
                                terminal: terminalProofs.indices.contains(offset) ? terminalProofs[offset] : nil,
                                point: pointProofs.indices.contains(offset) ? pointProofs[offset] : nil)
                            if !source.provisionalOwners.isEmpty || source.status != "measured" {
                                caps += originalGuard(source.index)
                            }
                            return caps
                        }, originalOwnedSupport: originalGuard, scopes: roles, sharedWindow: search.window) else {
                        records.append(["family": family392, "sourceIndex": row.index, "admitted": false,
                            "unavailableReason": "actual-current-local-source-live-unavailable",
                            "localPeerEvidence": certification.record, "automaticSelection": false,
                            "outputOrGraphMutated": false]); continue
                    }
                    // SOURCE392_FACTORY_SPLICE: actual391 Live bridge currently matches this API exactly.
                    var actualShapeContext435: NativeOCRSourceShapeFeatures406.Context?
                    let sourceBox436 = liveCandidateAudit369.requestsSourceWitness436 && NativeOCRSourceAdmissionWitness436.sink != nil ? NativeOCRSourceAdmissionWitness436.SourceBox() : nil
                    let generated: NativeOCRSourceOrientation391.Result
                    if liveCandidateAudit369.requestsRepair402 {
                        generated = NativeOCRSourceLiveRepair402.generateFromLive(prior: prior,
                            graph: graph392, measurement: m, live: live,
                            actualOriginalSeedEvidence: originals, sourceRF: layout,
                            qualifiedAdmission401: liveCandidateAudit369.requestsRepair402Qualified401,
                            recordFillRimRoles405: liveCandidateAudit369.requestsFillRim405,
                            produceFillEnvelope406: liveCandidateAudit369.requestsFillEnvelope406,
                                produceModelEnvelope407: liveCandidateAudit369.requestsModelEnvelope407,
                                produceVisualEnvelope410: liveCandidateAudit369.requestsVisualEnvelope410,
                                produceIndependentBoundaryLevels: liveCandidateAudit369.requestsBoundaryLevels,
                                independentBoundaryControl: liveCandidateAudit369.boundaryLevelsControl,
                                captureShapeContext406: liveCandidateAudit369.requestsRawRegression435 ?
                                    { actualShapeContext435 = $0 } : nil,
                                captureActualSource436: liveCandidateAudit369.requestsSourceWitness436 ?
                                    { evidence, basis, roles in
                                        sourceBox436?.evidence=evidence;sourceBox436?.basis=basis;sourceBox436?.roles405=roles
                                    } : nil)
                    } else if liveCandidateAudit369.requestsSharedBoundary400 {
                        generated = NativeOCRSourceLiveSharedBoundary400.generateFromLive(prior: prior,
                            graph: graph392, measurement: m, live: live,
                            actualOriginalSeedEvidence: originals, sourceRF: layout)
                    } else if liveCandidateAudit369.requestsBoundary397 {
                        let priorOnly397 = liveCandidateAudit369.requestsBoundaryPrior397
                        let cores397: NativeOCRSourceOrientation391.Result = priorOnly397 ?
                            .init(offers: [], receipt: ["status": "orientation391-not-run-actual-prior-only"]) :
                            NativeOCRSourceOrientation391.generateFromLive(prior: prior,
                                graph: graph392, measurement: m, live: live)
                        generated = NativeOCRSourceLiveBoundary397.generateFromLive(prior: prior,
                            graph: graph392, measurement: m, live: live, cores: cores397,
                            actualPriorOnly: priorOnly397, nativeAnchoredSeeds: liveCandidateAudit369.requestsBoundaryPrior399)
                    } else {
                        generated = NativeOCRSourceOrientation391.generateFromLive(prior: prior,
                            graph: graph392, measurement: m, live: live)
                    }
                    // Batch all valid UNIQUE actual keys before evaluating. One helper call per root
                    // shares any current/future root-scoped source-body caches across the whole menu.
                    var keyCounts392: [String: Int] = [:]
                    for raw in generated.offers {
                        if let key = raw["key"] as? String, !key.isEmpty {
                            keyCounts392[key, default: 0] += 1
                        }
                    }
                    var proposals392: [NativeOCRResidualCandidate] = []
                    var notNominated394 = Set<Int>()
                    var invalid392: [Int: String] = [:]
                    for (ordinal, raw) in generated.offers.enumerated() {
                        guard let key = raw["key"] as? String, !key.isEmpty,
                              let values = raw["polygon"] as? [[Double]], values.count == 4,
                              values.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
                            invalid392[ordinal] = "malformed-source-factory-offer"; continue
                        }
                        guard keyCounts392[key] == 1 else {
                            invalid392[ordinal] = "duplicate-actual-source-offer-key"; continue
                        }
                        if liveCandidateAudit369.requestsRepair402Select {
                            let preferred = (raw["sourceReceipt"] as? [String: Any])?["sourcePolicyPreferred"] as? Bool == true
                            let sourceGuard = preferred && SourceChoice402CommonGuardV3.allows(rawOffer: raw,
                                actualPrior: prior.polygon, sourceFeaturePrefix: liveSource22[row.index] ?? [],
                                nativeW: m.rect.width)
                            if !sourceGuard {
                                notNominated394.insert(ordinal)
                                continue
                            }
                        }
                        if !liveCandidateAudit369.requestsRepair402 && !liveCandidateAudit369.requestsSharedBoundary400 && !liveCandidateAudit369.requestsBoundary397 && liveCandidateAudit369.requestsOrientation394 &&
                            !SourceOrientation394Policy.mayNominate(raw: raw, actualPrior: prior.polygon,
                                factoryReceipt: generated.receipt) {
                            notNominated394.insert(ordinal)
                            continue
                        }
                        proposals392.append(NativeOCRResidualCandidate(key: key,
                            polygon: values.map { CGPoint(x: $0[0], y: $0[1]) },
                            consumedIndices: prior.consumedIndices,
                            supportPoints: prior.candidate?.supportPoints ?? [],
                            associationKey: prior.inheritedAssociationKey))
                    }
                    var fallback406: [String: Any] = [:]
                    if liveCandidateAudit369.requestsFillEnvelope406 {
                        var fallbackPolygon = prior.polygon
                        var fallbackKey: String? = nil
                        if let raw = generated.offers.first(where: {
                            ($0["sourceReceipt"] as? [String: Any])?["sourcePolicyPreferred"] as? Bool == true
                        }), SourceChoice402CommonGuardV3.allows(rawOffer: raw,
                            actualPrior: prior.polygon, sourceFeaturePrefix: liveSource22[row.index] ?? [], nativeW: m.rect.width),
                           let key = raw["key"] as? String,
                           let candidate = proposals392.first(where: { $0.key == key }) {
                            let original392 = NativeOCRSourceLiveAdmission392.assess(prior: prior, graph: graph392,
                                measurement: m, frame: originalFrame, peerEvidence: peers, live: live,
                                proposals: [candidate], accepts: accepts)
                            if original392.candidates.contains(where: { $0.key == key }) {
                                fallbackPolygon = candidate.polygon; fallbackKey = key
                            }
                        }
                        let rawFeatures: [Double]?
                        if let key = fallbackKey,
                           let raw = generated.offers.first(where: { $0["key"] as? String == key }) {
                            rawFeatures = (raw["sourceReceipt"] as? [String: Any])?["sourceShapeFeatures406"] as? [Double]
                        } else { rawFeatures = generated.receipt["actualOldShapeFeatures406"] as? [Double] }
                        let features = rawFeatures.flatMap { NativeOCRSourceShapeFeatures406.rebased($0,
                            polygon: fallbackPolygon, fallback: fallbackPolygon, nativeW: m.rect.width) }
                        fallback406 = ["family": "current-default-v3-source-fallback", "sourceIndex": row.index,
                            "polygon": fallbackPolygon.map { [Double($0.x), Double($0.y)] },
                            "key": fallbackKey as Any? ?? NSNull(), "features": features as Any? ?? NSNull(),
                            "actualOriginal392Readmitted": fallbackKey != nil,
                            "unchangedActualOldWhenNoDefaultNominee": fallbackKey == nil,
                            "GTCoordinatesUsed": false]
                    }
                    //435 predictor consumes the actual independent V3 fallback, not prior.
                    // Keep original offers/proposals untouched and assess new<=8 separately.
                    var raw435: NativeOCRSourceLiveRegression435.Output?
                    if liveCandidateAudit369.requestsRawRegression435 {
                        let sourceOffset = offsets[row.index]
                        let offsetBound = sourceOffset.map { indices.indices.contains($0) && indices[$0] == row.index } ?? false
                        let baseline: [CGPoint]? = sourceOffset.flatMap { baselines.indices.contains($0) ? baselines[$0] : nil }
                        let baselineBinding: [String: Any] = ["indicesOffsetBound": offsetBound,
                            "sourceIndex": row.index, "alignedInputOffset": sourceOffset as Any? ?? NSNull(),
                            "canonicalBaselineProvided": baseline != nil,
                            "provenance": "evaluate.baselines aligned to evaluate.indices; same host region.baseline",
                            "preparedIndexAssumedOriginalOrdinal": false,
                            "originalPacketBindings": generated.receipt["detectors"] as Any? ?? NSNull()]
                        raw435 = NativeOCRSourceLiveRegression435.generate(prior: prior,
                            graph: graph392, measurement: m, live: live, frame: originalFrame,
                            actualFallback: SourceBoundary400Policy.points(fallback406["polygon"]),
                            actualFallback8: fallback406["features"] as? [Double],
                            canonicalBaseline: baseline, baselineBinding: baselineBinding,
                            sourcePrefix22: liveSource22[row.index] ?? [], sourceFactoryReceipt: generated.receipt,
                            context: actualShapeContext435,
                            sourceRF: layout, meanOnly: liveCandidateAudit369.requestsMeanRegression435,
                            geometryOnlyForUtility: liveCandidateAudit369.requestsSourceUtility435)
                    }
                    // Exact nomination prefilter. A nonfallback score <= margin cannot win
                    // the unchanged selector, so it needs no extra native assessment.
                    // Baseline V3 was independently readmitted above before feature rebasing.
                    // DIRECT430 uses its own frozen model for BOTH acquisition and selection.
                    // Legacy strict/mixed callbacks remain unchanged when430 is not requested.
                    let directDeep430 = liveCandidateAudit369.requestsSourceCost430DeepSelect
                    let primaryCostMargin430: Double? = directDeep430 ?
                        SourceCost430Calibration.model?.margin : SourceCost416Calibration.model?.margin
                    func primaryCostScore430(_ features:[Double]) -> Double? {
                        if directDeep430 { return SourceCost430Calibration.score(sourceFeatures:features) }
                        guard let model=SourceCost416Calibration.model else { return nil }
                        return SourceBoxCost416Predictor.score(model:model,sourceFeatures:features,
                            fallback:false,experimentEnabled:true)
                    }
                    var sourceCost422NativeKeys = Set<String>()
                    if liveCandidateAudit369.requestsSourceCostFast422 {
                        if let primaryMargin430 = primaryCostMargin430,
                           let baseline = SourceBoundary400Policy.points(fallback406["polygon"]),
                           let fallbackFeatures = fallback406["features"] as? [Double] {
                            for (ordinal, raw) in generated.offers.enumerated() {
                                guard let key = raw["key"] as? String,
                                      (raw["hardRejections"] as? [String])?.isEmpty == true,
                                      let q = SourceBoundary400Policy.points(raw["polygon"]),
                                      let receipt = raw["sourceReceipt"] as? [String: Any],
                                      let original = receipt["sourceShapeFeatures406"] as? [Double],
                                      let rebased = NativeOCRSourceShapeFeatures406.rebased(original,
                                        polygon: q, fallback: baseline, nativeW: m.rect.width),
                                      let features = SourceCost416FeatureAdapter.features(candidatePolygon: q,
                                        fallbackPolygon: baseline, candidate8features406: rebased,
                                        fallback8features406: fallbackFeatures,
                                        sourceFeaturePrefix22: liveSource22[row.index] ?? [],
                                        sourceMode406: generated.receipt["sourceShapeFeatureSupportMode406"] as? String ?? "",
                                        sourceSupportConfidence406: generated.receipt["sourceShapeFeatureSupportConfidence406"] as? Double ?? 0,
                                        sourceSupportPointCount406: generated.receipt["sourceShapeFeatureSupportPointCount406"] as? Int ?? 0,
                                        actualNativeCellCenterCount: generated.receipt["actualNativeCellCenterCount"] as? Int ?? 0),
                                      let score = primaryCostScore430(features),
                                      score.isFinite else { notNominated394.insert(ordinal); continue }
                                // Shared raw union: never enclosure-filter GLOBAL before argmax.
                                let globalNomination427 = !directDeep430 && liveCandidateAudit369.requestsSourceCost427MixedSelect &&
                                    SourceCost427MixedCalibration.model.flatMap { globalModel in
                                        SourceBoxCost416Predictor.score(model:globalModel, sourceFeatures:features,
                                            fallback:false, experimentEnabled:true).map { $0 > globalModel.margin }
                                    } == true
                                guard score > primaryMargin430 || globalNomination427 else {
                                    notNominated394.insert(ordinal); continue
                                }
                                sourceCost422NativeKeys.insert(key)
                            }
                        } else {
                            for ordinal in generated.offers.indices { notNominated394.insert(ordinal) }
                        }
                        proposals392.removeAll { !sourceCost422NativeKeys.contains($0.key) }
                    }
                    func qualifiedReadmission409425(_ candidates: [NativeOCRResidualCandidate]) -> NativeOCRSourceLiveAdmission392.Output {
                        if liveCandidateAudit369.requestsNativeAdmission425 {
                            return NativeOCRSourceQualifiedAdmission425.assess(prior: prior,
                            graph: graph392, measurement: m, frame: originalFrame, peerEvidence: peers,
                            live: live, proposals: candidates,
                            derivedEndpointGeometryForSource: { source in
                                guard let offset = chainOffsets[source.index] else { return nil }
                                return NativeOCRSourceComponentBounds.protectedCaps(source,
                                    baseline: baselines.indices.contains(offset) ? baselines[offset] : nil,
                                    terminal: terminalProofs.indices.contains(offset) ? terminalProofs[offset] : nil,
                                    point: pointProofs.indices.contains(offset) ? pointProofs[offset] : nil)
                            }, originalOwnedSupport: originalGuard, accepts: accepts)
                        }
                        return NativeOCRSourceQualifiedGeometryAdmission409.assess(prior: prior,
                            graph: graph392, measurement: m, frame: originalFrame, peerEvidence: peers,
                            live: live, proposals: candidates,
                            derivedEndpointGeometryForSource: { source in
                                guard let offset = chainOffsets[source.index] else { return nil }
                                return NativeOCRSourceComponentBounds.protectedCaps(source,
                                    baseline: baselines.indices.contains(offset) ? baselines[offset] : nil,
                                    terminal: terminalProofs.indices.contains(offset) ? terminalProofs[offset] : nil,
                                    point: pointProofs.indices.contains(offset) ? pointProofs[offset] : nil)
                            }, originalOwnedSupport: originalGuard, accepts: accepts)
                    }
                    let assessed392: NativeOCRSourceLiveAdmission392.Output?
                    if liveCandidateAudit369.requestsFastMeanAudit435 {
                        // New audit-only fastmean family: retain actual V3 input/readmission
                        // above, but never rerun the legacy<=128 candidate admission bank.
                        // The mean below still runs the UNMODIFIED actual425 and424/426.
                        assessed392 = nil
                    } else if proposals392.isEmpty {
                        assessed392 = nil
                    } else if liveCandidateAudit369.requestsBoundaryLevels {
                        // The original menu is retained (<=128) plus <=48 new source quads.
                        // EACH unchanged409/425 helper invocation retains its <=128 limit.
                        var batches: [NativeOCRSourceLiveAdmission392.Output] = []
                        var sizes: [Int] = []
                        for start in stride(from: 0, to: proposals392.count, by: 128) {
                            let batch = Array(proposals392[start..<min(start + 128, proposals392.count)])
                            sizes.append(batch.count)
                            batches.append(qualifiedReadmission409425(batch))
                        }
                        var combined = NativeOCRSourceLiveAdmission392.Output(
                            candidates: batches.flatMap { $0.candidates }, records: batches.flatMap { $0.records })
                        combined.performance = ["independentBoundaryNativeBatchSizes": sizes,
                            "independentBoundaryNativeBatchCount": batches.count,
                            "unmodified409425BatchPerformance": batches.map { $0.performance },
                            "originalNativePerCallMaximum": 128]
                        assessed392 = combined
                    } else if liveCandidateAudit369.requestsQualifiedGeometry409 {
                        assessed392 = qualifiedReadmission409425(proposals392)
                    } else if liveCandidateAudit369.requestsRepair402Qualified401 {
                        assessed392 = NativeOCRSourceQualifiedAdmission401.assess(prior: prior,
                            graph: graph392, measurement: m, frame: originalFrame, peerEvidence: peers,
                            live: live, proposals: proposals392,
                            actualExplicitCapsForSource: { source in
                                guard let offset = chainOffsets[source.index] else { return nil }
                                return NativeOCRSourceComponentBounds.protectedCaps(source,
                                    baseline: baselines.indices.contains(offset) ? baselines[offset] : nil,
                                    terminal: terminalProofs.indices.contains(offset) ? terminalProofs[offset] : nil,
                                    point: pointProofs.indices.contains(offset) ? pointProofs[offset] : nil)
                            }, originalOwnedSupport: originalGuard, accepts: accepts)
                    } else {
                        assessed392 = NativeOCRSourceLiveAdmission392.assess(prior: prior, graph: graph392,
                            measurement: m, frame: originalFrame, peerEvidence: peers, live: live,
                            proposals: proposals392, accepts: accepts)
                    }
                    if let raw = raw435 {
                        // Separate batch preserves original128 exactly; no deep-cost prefilter.
                        let pointsBox436 = NativeOCRSourceAdmissionWitness436.PointsBox()
                        let extraNative: NativeOCRSourceLiveAdmission392.Output?
                        if raw.proposals.isEmpty { extraNative=nil }
                        else if liveCandidateAudit369.requestsSourceWitness436,
                                NativeOCRSourceAdmissionWitness436.sink != nil {
                            extraNative=NativeOCRSourceAdmissionWitness436.withPointObserver({ pointsBox436.observation=$0 }) {
                                qualifiedReadmission409425(raw.proposals)
                            }
                        } else { extraNative=qualifiedReadmission409425(raw.proposals) }
                        var newRecords = raw.records
                        for i in newRecords.indices {
                            guard let key = newRecords[i]["key"] as? String,
                                  let candidate = raw.proposals.first(where: { $0.key == key }) else { continue }
                            let outcomes = extraNative?.records.filter { $0["key"] as? String == key } ?? []
                            let passed = extraNative?.candidates.contains(where: { $0.key == key && $0.polygon == candidate.polygon }) == true
                            newRecords[i]["nativeAssessmentRun"] = true
                            newRecords[i]["nativeAdmissionPassed"] = passed
                            newRecords[i]["nativeOutcome"] = outcomes
                            if passed {
                                let r = live.rgba
                                let first = NativeOCRSupplementalBodyLoss424.assess(actualOld: prior.polygon,
                                    proposed: candidate.polygon,
                                    basis: .init(origin: m.origin, normal: m.normal, along: m.along), nativeW: m.rect.width,
                                    rgba: .init(bytes: r.bytes, width: r.width, height: r.height,
                                        bytesPerRow: r.bytesPerRow, origin: r.origin), maximumQueries: 512,
                                    stopAfterFirstPositive: true)
                                var feasibility: [String: Any] = ["actual424": first.receipt,
                                    "actual426Run": false, "unknownMeansBackground": false,
                                    "automaticSelection": false]
                                var positive = first.decision == .rejectObservedLoss
                                var unavailable = first.receipt["status"] as? String == "invalid-actual-capture-or-basis"
                                if first.decision == .unresolved && !unavailable {
                                    let second = NativeOCRSupplementalBodyLoss426.assess(actualOld: prior.polygon,
                                        proposed: candidate.polygon,
                                        basis: .init(origin: m.origin, normal: m.normal, along: m.along), nativeW: m.rect.width,
                                        rgba: .init(bytes: r.bytes, width: r.width, height: r.height,
                                            bytesPerRow: r.bytesPerRow, origin: r.origin), maximumQueries: 512,
                                        stopAfterFirstPositive: true)
                                    feasibility["actual426"] = second.receipt
                                    feasibility["actual426Run"] = true
                                    positive = second.decision == .rejectObservedLoss
                                    unavailable = second.receipt["status"] as? String == "invalid-actual-capture-or-basis"
                                }
                                feasibility["positiveExtraLossObserved"] = positive
                                feasibility["sourceUnavailable"] = unavailable
                                feasibility["noPositiveExtraLossObserved"] = !positive && !unavailable
                                feasibility["noPositiveDoesNotProveGlyphCompleteness"] = true
                                newRecords[i]["actual424426Feasibility"] = feasibility
                            }
                        }
                        var capture436: [String: Any]?
                        if liveCandidateAudit369.requestsSourceWitness436,
                           let sink=NativeOCRSourceAdmissionWitness436.sink {
                            let blocked=newRecords.filter { NativeOCRSourceAdmissionWitness436.wants($0) }
                            if !blocked.isEmpty {
                                capture436=sink(.init(prior:prior,graph:graph392,measurement:m,live:live,
                                    frame:originalFrame,originals:originals,prepared:prepared,groups:groups,
                                    rfScopes:scopes,proposals:raw.proposals,candidateRecords:blocked,
                                    points:pointsBox436.observation,source:sourceBox436))
                            }
                        }
                        // The Host retains only small manifests; release heavy capture-only
                        // point dictionaries/evidence immediately after synchronous export.
                        pointsBox436.observation=nil
                        sourceBox436?.evidence=nil;sourceBox436?.basis=nil;sourceBox436?.roles405=nil
                        records.append(["family": liveCandidateAudit369.requestsSourceUtility435 ?
                            "source-utility435-geometry-proposals" : (liveCandidateAudit369.requestsMeanRegression435 ?
                            "source-regression435-mean-qualified425" : "source-regression435-qualified425"), "sourceIndex": row.index,
                            "actualCurrent386Prior": prior.polygon.map { [Double($0.x), Double($0.y)] },
                            "currentDefaultV3Fallback406": fallback406, "sourceFactoryReceipt": raw.receipt,
                            "actualSourceIndices": live.sources.map(\.index),
                            "actualRGBA_SHA256": generated.receipt["actualRGBA_SHA256"] as Any? ?? NSNull(),
                            "candidates": newRecords, "newNativeBatchProposalCount": raw.proposals.count,
                            "separateNativeBatchFromOriginal128": true,
                            "nativeBatchPerformance": extraNative?.performance as Any? ?? NSNull(),
                            "rawOfferCount": newRecords.count,
                            "automaticSelection": false, "outputOrGraphMutated": false,
                            "GTCoordinatesUsed": false])
                        if let capture436, let last=records.indices.last { records[last]["sourceWitness436"]=capture436 }
                    }
                    var outcomes392: [String: [[String: Any]]] = [:]
                    var unkeyed392: [[String: Any]] = []
                    for outcome in assessed392?.records ?? [] {
                        if let key = outcome["key"] as? String { outcomes392[key, default: []].append(outcome) }
                        else { unkeyed392.append(outcome) }
                    }
                    let passedKeys392 = Set((assessed392?.candidates ?? []).map(\.key))
                    var offerRecords392: [[String: Any]] = []
                    for (ordinal, raw) in generated.offers.enumerated() {
                        // Preserve every legacy raw geometry/obligation without falsely
                        // claiming admission; omit only duplicated heavy pixel traces.
                        if liveCandidateAudit369.requestsFastMeanAudit435 {
                            let raw8=(raw["sourceReceipt"] as? [String:Any])?["sourceShapeFeatures406"] as? [Double]
                            let q=SourceBoundary400Policy.points(raw["polygon"])
                            let baseline=SourceBoundary400Policy.points(fallback406["polygon"])
                            let rebased8: [Double]?
                            if let raw8,let q,let baseline {
                                rebased8=NativeOCRSourceShapeFeatures406.rebased(raw8,
                                    polygon:q,fallback:baseline,nativeW:m.rect.width)
                            } else {rebased8=nil}
                            let compactRaw: [String:Any] = ["key":raw["key"] as Any? ?? NSNull(),
                                "family":raw["family"] as Any? ?? NSNull(),
                                "polygon":raw["polygon"] as Any? ?? NSNull(),
                                "hardRejections":raw["hardRejections"] as Any? ?? NSNull(),
                                "softRejections":raw["softRejections"] as Any? ?? NSNull(),
                                "obligations":raw["obligations"] as Any? ?? NSNull(),
                                "sourceReceipt":["sourceShapeFeatures406":rebased8 as Any? ?? NSNull()],
                                "heavyPixelTraceOmitted":true]
                            offerRecords392.append(["rawOffer":compactRaw,
                                "sourceHardRejections":raw["hardRejections"] as Any? ?? NSNull(),
                                "sourceSoftRejections":raw["softRejections"] as Any? ?? NSNull(),
                                "sourceObligations":raw["obligations"] as Any? ?? NSNull(),
                                "sourceObligationsUnresolved":true,
                                "sourceShapeFeatures406":rebased8 as Any? ?? NSNull(),
                                "nativeAssessmentRun":false,"nativeAdmissionPassed":false,
                                "nativeOutcome":[[String:Any]](),"notNativeRejection":true,
                                "unavailableReason":"legacy-menu-native-assessment-intentionally-skipped-fastmean435",
                                "retainedGeometryOnlyWithoutNativePermission":true,
                                "automaticSelection":false,"finalAdmissionGranted":false])
                            continue
                        }
                        if liveCandidateAudit369.requestsRepair402Select && notNominated394.contains(ordinal) { continue }
                        // Preserve every raw source-loss/capture/association obligation verbatim.
                        // A native guard pass does NOT silently discharge these proposal-side obligations.
                        let sourceHard = raw["hardRejections"] as? [String]
                        let sourceSoft = raw["softRejections"] as? [String]
                        var offerRecord392: [String: Any] = ["rawOffer": raw,
                            "sourceHardRejections": sourceHard as Any? ?? NSNull(),
                            "sourceSoftRejections": sourceSoft as Any? ?? NSNull(),
                            "sourceObligations": raw["obligations"] as Any? ?? NSNull(),
                            "sourceObligationsUnresolved": sourceHard == nil || sourceSoft == nil ||
                                sourceHard?.isEmpty == false || sourceSoft?.isEmpty == false,
                            "finalAdmissionGranted": false, "automaticSelection": false]
                        if let reason = invalid392[ordinal] {
                            offerRecord392["nativeAssessmentRun"] = false
                            offerRecord392["nativeAdmissionPassed"] = false
                            offerRecord392["unavailableReason"] = reason
                        } else if notNominated394.contains(ordinal) {
                            offerRecord392["sourcePolicyNominated"] = false
                            offerRecord392["nativeAssessmentRun"] = false
                            offerRecord392["nativeAdmissionPassed"] = false
                            offerRecord392["nativeChecksSkippedBySharedSourceFeaturePolicy"] = true
                        } else if let key = raw["key"] as? String {
                            let outcomes = outcomes392[key] ?? []
                            offerRecord392["nativeAssessmentRun"] = assessed392 != nil
                            offerRecord392["nativeOutcome"] = outcomes
                            // Missing/ambiguous native key results stay unavailable; no ordinal/no-veto fallback.
                            if outcomes.count == 1 {
                                offerRecord392["nativeAdmissionPassed"] = passedKeys392.contains(key)
                            } else {
                                offerRecord392["nativeAdmissionPassed"] = false
                                offerRecord392["unavailableReason"] = "native-batch-key-outcome-missing-or-ambiguous"
                            }
                        }
                        if liveCandidateAudit369.requestsFillEnvelope406,
                           let sourceReceipt = raw["sourceReceipt"] as? [String: Any],
                           let features = sourceReceipt["sourceShapeFeatures406"] as? [Double],
                           let q = SourceBoundary400Policy.points(raw["polygon"]),
                           let baseline = SourceBoundary400Policy.points(fallback406["polygon"]) {
                            offerRecord392["sourceShapeFeatures406"] = NativeOCRSourceShapeFeatures406.rebased(features,
                                polygon: q, fallback: baseline, nativeW: m.rect.width) as Any? ?? NSNull()
                        }
                        offerRecords392.append(offerRecord392)
                    }
                    var policyChoice394: [String: Any] = [:]
                    if !liveCandidateAudit369.requestsRepair402 && !liveCandidateAudit369.requestsSharedBoundary400 && !liveCandidateAudit369.requestsBoundary397 && liveCandidateAudit369.requestsOrientation394 {
                        let nativeOrdered394 = offerRecords392.compactMap { record -> SourceOrientation394Policy.NativeCandidate? in
                            guard let raw = record["rawOffer"] as? [String: Any],
                                  let hard = record["sourceHardRejections"] as? [String] else { return nil }
                            return .init(rawOffer: raw,
                                nativeAdmissionPassed: record["nativeAdmissionPassed"] as? Bool ?? false,
                                sourceHardRejections: hard, originalRecord: record)
                        }
                        if let choice = SourceOrientation394Policy.choose(nativeOrdered: nativeOrdered394,
                            actualPrior: prior.polygon, factoryReceipt: generated.receipt) {
                            policyChoice394 = ["rawOffer": choice.candidate.rawOffer,
                                "nativeIndex": choice.nativeIndex,
                                "originalRecord": choice.candidate.originalRecord,
                                "sourceFeatures": ["areaRatio": choice.features.areaRatio,
                                    "widthRatio": choice.features.widthRatio,
                                    "centerCorrection": choice.features.centerCorrection,
                                    "normalPadding": choice.features.normalPadding,
                                    "fitImprovement": choice.features.fitImprovement],
                                "finalAdmissionGranted": false, "outputOrGraphMutated": false]
                        }
                    }
                    // Explicit host experiment: exact source nominee plus the unchanged native suite.
                    // No GT, source identity rules, graph membership edits, or native veto relaxation.
                    if liveCandidateAudit369.requestsRepair402Select,
                       let selected = generated.offers.first(where: { raw in
                           (raw["sourceReceipt"] as? [String: Any])?["sourcePolicyPreferred"] as? Bool == true
                       }), let selectedKey = selected["key"] as? String,
                       (selected["hardRejections"] as? [String])?.isEmpty == true,
                       passedKeys392.contains(selectedKey),
                       let candidate = assessed392?.candidates.first(where: { $0.key == selectedKey }),
                       let offset = offsets[row.index] {
                        output[offset] = candidate.polygon
                        applied392?[row.index] = candidate
                        records.append(["family": "source-repair402-selected", "sourceIndex": row.index,
                            "selectedKey": selectedKey, "nativeAdmissionPassed": true,
                            "sourceOnlySelection": true, "outputOrGraphMutated": true,
                            "polygon": candidate.polygon.map { [Double($0.x), Double($0.y)] },
                            "actualPreviousPrior": prior.polygon.map { [Double($0.x), Double($0.y)] }])
                    }
                    // Explicit experiment: source-only compact model over actual native-passed geometry.
                    // Current V3 fallback remains the baseline even when model features are unavailable.
                    if liveCandidateAudit369.requestsSourceCost416Select,
                       let fallbackPolygon = SourceBoundary400Policy.points(fallback406["polygon"]),
                       let offset = offsets[row.index] {
                        var chosenPolygon = fallbackPolygon
                        var chosenKey = fallback406["key"] as? String
                        var chosenScore = 0.0
                        var feasibleNominees433: [SourceFeasibleDeep433.Nominee] = []
                        var globalBest427: (polygon:[CGPoint], key:String, score:Double)?
                        var mixed427Receipt: [String:Any] = ["enabled":liveCandidateAudit369.requestsSourceCost427MixedSelect]
                        if let primaryMargin430 = primaryCostMargin430,
                           let fallbackFeatures = fallback406["features"] as? [Double] {
                            for record in offerRecords392 {
                                guard record["nativeAdmissionPassed"] as? Bool == true,
                                      (record["sourceHardRejections"] as? [String])?.isEmpty == true,
                                      let raw = record["rawOffer"] as? [String: Any],
                                      let key = raw["key"] as? String,
                                      let q = SourceBoundary400Policy.points(raw["polygon"]),
                                      let candidateFeatures = record["sourceShapeFeatures406"] as? [Double],
                                      let features = SourceCost416FeatureAdapter.features(candidatePolygon: q,
                                        fallbackPolygon: fallbackPolygon, candidate8features406: candidateFeatures,
                                        fallback8features406: fallbackFeatures,
                                        sourceFeaturePrefix22: liveSource22[row.index] ?? [],
                                        sourceMode406: generated.receipt["sourceShapeFeatureSupportMode406"] as? String ?? "",
                                        sourceSupportConfidence406: generated.receipt["sourceShapeFeatureSupportConfidence406"] as? Double ?? 0,
                                        sourceSupportPointCount406: generated.receipt["sourceShapeFeatureSupportPointCount406"] as? Int ?? 0,
                                        actualNativeCellCenterCount: generated.receipt["actualNativeCellCenterCount"] as? Int ?? 0),
                                      let score = primaryCostScore430(features),
                                      score.isFinite else { continue }
                                if !directDeep430 && liveCandidateAudit369.requestsSourceCost427MixedSelect,
                                   let globalModel=SourceCost427MixedCalibration.model,
                                   let globalScore=SourceBoxCost416Predictor.score(model:globalModel,
                                        sourceFeatures:features,fallback:false,experimentEnabled:true),
                                   globalScore > globalModel.margin,
                                   globalScore > (globalBest427?.score ?? 0) {
                                    globalBest427=(q,key,globalScore)
                                }
                                if liveCandidateAudit369.requestsSourceCost433FeasibleSelect,
                                   score > primaryMargin430,
                                   let actualCandidate = assessed392?.candidates.first(where: { $0.key == key }),
                                   actualCandidate.polygon == q {
                                    feasibleNominees433.append(.init(key: key, polygon: q, score: score,
                                        ordinal: feasibleNominees433.count, actualNativePassed: true, sourceHardEmpty: true))
                                }
                                if score > primaryMargin430 && score > chosenScore {
                                    chosenPolygon = q; chosenKey = key; chosenScore = score
                                }
                            }
                        }
                        if !directDeep430 && liveCandidateAudit369.requestsSourceCost427MixedSelect {
                            mixed427Receipt["strictBestKey"] = chosenKey as Any? ?? NSNull()
                            mixed427Receipt["globalBestKey"] = globalBest427?.key as Any? ?? NSNull()
                            mixed427Receipt["globalBestScore"] = globalBest427?.score as Any? ?? NSNull()
                            let enclosed=globalBest427.map {
                                SourceCost427MixedCalibration.encloses($0.polygon,actualV3:fallbackPolygon)
                            } ?? false
                            mixed427Receipt["globalBestEnclosesActualV3"] = enclosed
                            mixed427Receipt["argmaxBeforeEnclosure"] = true
                            mixed427Receipt["sharedRawUnionNomination"] = true
                            mixed427Receipt["selectedLane"] = enclosed ? "global427" : "strict417"
                            if enclosed,let global=globalBest427 {
                                chosenPolygon=global.polygon;chosenKey=global.key;chosenScore=global.score
                            }
                        }
                        var stroke404Receipt: [String: Any] = [:]
                        var repairedCandidate416: NativeOCRResidualCandidate?
                        if !directDeep430 && liveCandidateAudit369.requestsSourceCost418 && chosenScore > 0 {
                            let observation = NativeOCRSourceLiveClosedContrast418.prepareFromLive(prior: prior,
                                graph: graph392, measurement: m, live: live,
                                actualOriginalSeedEvidence: originals, sourceRF: layout, experimentEnabled: true)
                            let associated = NativeOCRSourceLiveStroke404.prepareFromLive(prior: prior,
                                graph: graph392, measurement: m, live: live,
                                actualOriginalSeedEvidence: originals, sourceRF: layout)
                            stroke404Receipt = ["family": "source-positive-contrast418-supplement",
                                "closedContrastPreparation": observation.receipt,
                                "associationPreparation": associated.receipt,
                                "existingNative409GuardsPreserved": true,
                                "unknownPromotedToForegroundOrBackground": false,
                                "noExtraClampFromUnqualifiedNNGeometry": true]
                            if let session = observation.session, let source = associated.session {
                                let unresolved = source.unresolvedLostPositions(proposed: chosenPolygon)
                                let protected = source.protectedAssociatedCellCenters()
                                var queried = Set<String>(), positive: [CGPoint] = []
                                var states: [String: Int] = [:], witnesses: [[String: Any]] = []
                                for point in (unresolved ?? []) + (protected ?? []) where !NativeOCRSourceLocalJoint369.contains(chosenPolygon, point) {
                                    let key = String(Double(point.x)) + ":" + String(Double(point.y))
                                    guard queried.insert(key).inserted else { continue }
                                    let proof = session.assess(actualQueryPoint: point)
                                    states[proof.state, default: 0] += 1
                                    if proof.positive { positive.append(point) }
                                    if witnesses.count < 6 { witnesses.append(proof.receipt) }
                                }
                                stroke404Receipt["actualQueryStates"] = states
                                stroke404Receipt["actualQueryCount"] = queried.count
                                stroke404Receipt["positiveClosedContrastPixels"] = positive.count
                                stroke404Receipt["actualWitnesses"] = witnesses
                                stroke404Receipt["unresolvedListAvailable"] = unresolved != nil
                                stroke404Receipt["associatedListAvailable"] = protected != nil
                                if !positive.isEmpty, let q = NativeOCRSourceAssociatedStroke404.enclosingMeasuredCells(
                                    proposed: chosenPolygon, actualOld: prior.polygon, centers: positive), q != chosenPolygon {
                                    let candidate = NativeOCRResidualCandidate(key: "source-cost418-" + (chosenKey ?? "nominee"),
                                        polygon: q, consumedIndices: prior.consumedIndices,
                                        supportPoints: prior.candidate?.supportPoints ?? [], associationKey: prior.inheritedAssociationKey)
                                    let check = qualifiedReadmission409425([candidate])
                                    stroke404Receipt["actualModifiedNativeReadmission"] = check.records
                                    if check.candidates.contains(where: { $0.key == candidate.key }) {
                                        chosenPolygon = q; chosenKey = candidate.key; repairedCandidate416 = candidate
                                    } else {
                                        chosenPolygon = fallbackPolygon; chosenKey = fallback406["key"] as? String; chosenScore = 0
                                        stroke404Receipt["fallbackOnNativeReadmissionRejection"] = true
                                    }
                                }
                            }
                        }
                        if !directDeep430 && liveCandidateAudit369.requestsSourceCost416Stroke404 && chosenScore > 0 {
                            let prepared = NativeOCRSourceLiveStroke404.prepareFromLive(prior: prior,
                                graph: graph392, measurement: m, live: live,
                                actualOriginalSeedEvidence: originals, sourceRF: layout)
                            stroke404Receipt = prepared.receipt
                            var admittedRepair = false
                            if let session = prepared.session {
                                let repaired = session.repair(proposed: chosenPolygon)
                                stroke404Receipt["repair"] = repaired.receipt
                                if let q = repaired.polygon {
                                    if q == chosenPolygon { admittedRepair = true }
                                    else {
                                        let candidate = NativeOCRResidualCandidate(key: "source-cost416-stroke404-" + (chosenKey ?? "nominee"),
                                            polygon: q, consumedIndices: prior.consumedIndices,
                                            supportPoints: prior.candidate?.supportPoints ?? [],
                                            associationKey: prior.inheritedAssociationKey)
                                        let check = qualifiedReadmission409425([candidate])
                                        stroke404Receipt["actualModifiedNativeReadmission"] = check.records
                                        if check.candidates.contains(where: { $0.key == candidate.key }) {
                                            chosenPolygon = q; chosenKey = candidate.key
                                            repairedCandidate416 = candidate; admittedRepair = true
                                        }
                                    }
                                }
                            }
                            if !admittedRepair {
                                chosenPolygon = fallbackPolygon; chosenKey = fallback406["key"] as? String
                                chosenScore = 0
                                stroke404Receipt["fallbackBecauseRepairUnavailableOrNativeRejected"] = true
                            }
                        }
                        var feasible433Receipt: [String: Any] = ["enabled": liveCandidateAudit369.requestsSourceCost433FeasibleSelect]
                        if liveCandidateAudit369.requestsSourceCost433FeasibleSelect {
                            let r = live.rgba
                            let rootBound = live.sources.first?.index == m.index &&
                                live.sources.map(\.index) == [m.index] + prior.consumedIndices &&
                                r.width > 2 && r.height > 2 && r.width <= 600_000 / r.height &&
                                r.bytesPerRow >= r.width * 4 && r.bytes.count == r.height * r.bytesPerRow &&
                                r.origin.x >= 0 && r.origin.y >= 0 &&
                                r.origin.x.rounded() == r.origin.x && r.origin.y.rounded() == r.origin.y &&
                                r.origin.x + CGFloat(r.width) <= CGFloat(originalFrame.width) &&
                                r.origin.y + CGFloat(r.height) <= CGFloat(originalFrame.height) &&
                                prior.polygon.allSatisfy({ $0.x >= r.origin.x && $0.y >= r.origin.y &&
                                    $0.x <= r.origin.x + CGFloat(r.width) && $0.y <= r.origin.y + CGFloat(r.height) })
                            var actualFrameRowsBound = rootBound && !feasibleNominees433.isEmpty
                            if actualFrameRowsBound {
                                for y in 0..<r.height {
                                    let frameOffset = (Int(r.origin.y) + y) * originalFrame.bytesPerRow + Int(r.origin.x) * 4
                                    let localOffset = y * r.bytesPerRow
                                    if !originalFrame.bytes[frameOffset..<(frameOffset + r.width * 4)]
                                        .elementsEqual(r.bytes[localOffset..<(localOffset + r.width * 4)]) {
                                        actualFrameRowsBound = false; break
                                    }
                                }
                            }
                            let binding: [String: Any] = ["actualFrameRowsAndRootBound": actualFrameRowsBound,
                                "rootSourceIndex": m.index, "sourceIndices": live.sources.map(\.index),
                                "actualOld": prior.polygon.map { [Double($0.x), Double($0.y)] },
                                "rgbaOrigin": [Double(r.origin.x), Double(r.origin.y)],
                                "rgbaWidth": r.width, "rgbaHeight": r.height,
                                "actualRGBA_SHA256": generated.receipt["actualRGBA_SHA256"] as Any? ?? NSNull()]
                            let decision = SourceFeasibleDeep433.choose(feasibleNominees433,
                                actualMargin: primaryCostMargin430, rootBindingVerified: actualFrameRowsBound,
                                rootBindingReceipt: binding, maximumCandidates: 16) { nominee in
                                let first = NativeOCRSupplementalBodyLoss424.assess(actualOld: prior.polygon,
                                    proposed: nominee.polygon,
                                    basis: .init(origin: m.origin, normal: m.normal, along: m.along),
                                    nativeW: m.rect.width,
                                    rgba: .init(bytes: r.bytes, width: r.width, height: r.height,
                                        bytesPerRow: r.bytesPerRow, origin: r.origin), maximumQueries: 512,
                                    stopAfterFirstPositive: true)
                                var evaluation: [String: Any] = ["actual424": first.receipt,
                                    "sameRootBinding": true, "actual426Run": false,
                                    "unknownMeansBackground": false, "completeForegroundPreserved": false]
                                if first.receipt["status"] as? String == "invalid-actual-capture-or-basis" {
                                    return .init(verdict: .unavailable, receipt: evaluation)
                                }
                                if first.decision == .rejectObservedLoss {
                                    return .init(verdict: .positiveExtraLoss, receipt: evaluation)
                                }
                                if first.decision == .unresolved {
                                    let second = NativeOCRSupplementalBodyLoss426.assess(actualOld: prior.polygon,
                                        proposed: nominee.polygon,
                                        basis: .init(origin: m.origin, normal: m.normal, along: m.along),
                                        nativeW: m.rect.width,
                                        rgba: .init(bytes: r.bytes, width: r.width, height: r.height,
                                            bytesPerRow: r.bytesPerRow, origin: r.origin), maximumQueries: 512,
                                        stopAfterFirstPositive: true)
                                    evaluation["actual426"] = second.receipt
                                    evaluation["actual426Run"] = true
                                    if second.receipt["status"] as? String == "invalid-actual-capture-or-basis" {
                                        return .init(verdict: .unavailable, receipt: evaluation)
                                    }
                                    if second.decision == .rejectObservedLoss {
                                        return .init(verdict: .positiveExtraLoss, receipt: evaluation)
                                    }
                                }
                                return .init(verdict: .noPositiveExtraLoss, receipt: evaluation)
                            }
                            feasible433Receipt = decision.receipt
                            feasible433Receipt["enabled"] = true
                            // Reuse only the exact typed candidate whose geometry and key were
                            // checked in this root's immutable capture. Never synthesize one.
                            if let selected = decision.selected,
                               let native = assessed392?.candidates.first(where: {
                                   $0.key == selected.key && $0.polygon == selected.polygon
                               }) {
                                chosenPolygon = native.polygon; chosenKey = native.key
                                chosenScore = selected.score; repairedCandidate416 = native
                            } else {
                                chosenPolygon = fallbackPolygon; chosenKey = fallback406["key"] as? String
                                chosenScore = 0; repairedCandidate416 = nil
                                feasible433Receipt["independentOriginal392V3FallbackUsed"] = true
                            }
                        }
                        // Supplemental424 is nominee-only and positive-only. It never
                        // turns unknown into background or applies its proposed repair.
                        var supplemental426: [String: Any] = ["enabled": liveCandidateAudit369.requestsPositiveLoss426,
                            "executed": false, "unknownMeansBackground": false, "repairApplied": false,
                            "executionPolicy": "only-after424-unresolved-with-same-actual-frame-basis"]
                        var supplemental424: [String: Any] = ["enabled": liveCandidateAudit369.requestsPositiveLoss424,
                            "executed": false, "unknownMeansBackground": false, "repairApplied": false]
                        if !liveCandidateAudit369.requestsSourceCost433FeasibleSelect &&
                            liveCandidateAudit369.requestsPositiveLoss424 && chosenScore > 0 &&
                            !prior.polygon.allSatisfy({ NativeOCRSharedBoundary396.contains(chosenPolygon, $0) }) {
                            let r = live.rgba
                            let rootBound = live.sources.first?.index == m.index &&
                                live.sources.map(\.index) == [m.index] + prior.consumedIndices &&
                                r.width > 2 && r.height > 2 && r.width <= 600_000 / r.height &&
                                r.bytesPerRow >= r.width * 4 && r.bytes.count == r.height * r.bytesPerRow &&
                                r.origin.x >= 0 && r.origin.y >= 0 &&
                                r.origin.x.rounded() == r.origin.x && r.origin.y.rounded() == r.origin.y &&
                                r.origin.x + CGFloat(r.width) <= CGFloat(originalFrame.width) &&
                                r.origin.y + CGFloat(r.height) <= CGFloat(originalFrame.height) &&
                                prior.polygon.allSatisfy({ $0.x >= r.origin.x && $0.y >= r.origin.y &&
                                    $0.x <= r.origin.x + CGFloat(r.width) && $0.y <= r.origin.y + CGFloat(r.height) })
                            var actualFrameRowsBound = rootBound
                            if rootBound {
                                for y in 0..<r.height {
                                    let frameOffset = (Int(r.origin.y) + y) * originalFrame.bytesPerRow + Int(r.origin.x) * 4
                                    let localOffset = y * r.bytesPerRow
                                    if !originalFrame.bytes[frameOffset..<(frameOffset + r.width * 4)]
                                        .elementsEqual(r.bytes[localOffset..<(localOffset + r.width * 4)]) {
                                        actualFrameRowsBound = false; break
                                    }
                                }
                            }
                            supplemental424["actualFrameRowsAndRootBound"] = actualFrameRowsBound
                            if actualFrameRowsBound {
                                let observed = NativeOCRSupplementalBodyLoss424.assess(actualOld: prior.polygon,
                                    proposed: chosenPolygon,
                                    basis: .init(origin: m.origin, normal: m.normal, along: m.along),
                                    nativeW: m.rect.width,
                                    rgba: .init(bytes: r.bytes, width: r.width, height: r.height,
                                        bytesPerRow: r.bytesPerRow, origin: r.origin), maximumQueries: 512)
                                supplemental424["executed"] = true
                                supplemental424["sourceObservation"] = observed.receipt
                                supplemental424["decision"] = observed.decision.rawValue
                                supplemental424["actualNominee"] = chosenPolygon.map { [Double($0.x), Double($0.y)] }
                                supplemental424["actualNomineeKey"] = chosenKey as Any? ?? NSNull()
                                supplemental424["positiveVetoApplied"] = observed.decision == .rejectObservedLoss
                                if observed.decision == .rejectObservedLoss {
                                    chosenPolygon = fallbackPolygon
                                    chosenKey = fallback406["key"] as? String
                                    chosenScore = 0
                                    repairedCandidate416 = nil
                                    supplemental424["independentOriginal392V3FallbackUsed"] = true
                                } else if observed.decision == .unresolved && liveCandidateAudit369.requestsPositiveLoss426 {
                                    // Same bound source bytes, actual native basis and unchanged nominee.
                                    //424-positive is never replaced; no repair or ownership promotion.
                                    let additional = NativeOCRSupplementalBodyLoss426.assess(actualOld: prior.polygon,
                                        proposed: chosenPolygon,
                                        basis: .init(origin: m.origin, normal: m.normal, along: m.along),
                                        nativeW: m.rect.width,
                                        rgba: .init(bytes: r.bytes, width: r.width, height: r.height,
                                            bytesPerRow: r.bytesPerRow, origin: r.origin), maximumQueries: 512)
                                    supplemental426["executed"] = true
                                    supplemental426["ranOnlyAfter424Unresolved"] = true
                                    supplemental426["actualFrameRowsAndRootBound"] = actualFrameRowsBound
                                    supplemental426["sourceObservation"] = additional.receipt
                                    supplemental426["decision"] = additional.decision.rawValue
                                    supplemental426["actualNominee"] = chosenPolygon.map { [Double($0.x), Double($0.y)] }
                                    supplemental426["actualNomineeKey"] = chosenKey as Any? ?? NSNull()
                                    supplemental426["positiveVetoApplied"] = additional.decision == .rejectObservedLoss
                                    if additional.decision == .rejectObservedLoss {
                                        chosenPolygon = fallbackPolygon
                                        chosenKey = fallback406["key"] as? String
                                        chosenScore = 0
                                        repairedCandidate416 = nil
                                        supplemental426["independentOriginal392V3FallbackUsed"] = true
                                    }
                                }
                            } else {
                                supplemental424["decision"] = "unresolved-current-capture-binding"
                            }
                        }
                        var utility435Receipt: [String: Any] = ["enabled": liveCandidateAudit369.requestsSourceUtility435]
                        if liveCandidateAudit369.requestsSourceUtility435 {
                            let actual433 = chosenPolygon
                            utility435Receipt["baseline433Polygon"] = actual433.map { [Double($0.x), Double($0.y)] }
                            utility435Receipt["modelSHA256"] = SourceUtility435Calibration.modelSHA256
                            utility435Receipt["GTRead"] = false
                            utility435Receipt["legacy425ChecksDescribeBaselineOrDiagnosticsOnly"] = true
                            utility435Receipt["nativeOrErasureOwnershipPermissionClaimed"] = false
                            utility435Receipt["mergeRelationsChanged"] = false
                            if let raw = raw435, let source = raw.source435,
                               let mean = raw.records.first(where: { $0["key"] as? String == "source-regression435-mean" }),
                               let q = SourceBoundary400Policy.points(mean["polygon"]),
                               let rawOffer = mean["rawOffer"] as? [String: Any],
                               let sourceReceipt = rawOffer["sourceReceipt"] as? [String: Any],
                               let predicted5 = sourceReceipt["predictedRelativeTargets"] as? [Double],
                               let model = SourceUtility435Calibration.model,
                               let decision = SourceBoundary435UtilityHerschel.preferred(model: model,
                                sourceFeatures50: source.features, predictedRelative5: predicted5,
                                candidate: q, baseline: actual433, rootW: CGFloat(source.rootW),
                                frame: CGSize(width: originalFrame.width, height: originalFrame.height)) {
                                utility435Receipt["available"] = true
                                utility435Receipt["sourceOnlyDecision"] = decision.receipt
                                utility435Receipt["score"] = decision.score
                                utility435Receipt["nominated"] = decision.nominate
                                utility435Receipt["legacyMean425PassedDiagnostic"] = mean["nativeAdmissionPassed"] as Any? ?? NSNull()
                                utility435Receipt["legacyMean425Executed"] = mean["nativeAssessmentRun"] as? Bool == true
                                if decision.nominate {
                                    chosenPolygon = q; chosenKey = "source-utility435-direct-mean"
                                    chosenScore = decision.score; repairedCandidate416 = nil
                                }
                            } else {
                                utility435Receipt["available"] = false
                                utility435Receipt["nominated"] = false
                                utility435Receipt["fallback433Used"] = true
                            }
                            if liveCandidateAudit369.requestsSourceUtility435All8,
                               let raw = raw435, let source = raw.source435,
                               let model = SourceUtility435All8Calibration.model {
                                typealias Alternative = SourceBoundary435All8CurrentUUtilityHerschel
                                let offers: [Alternative.Offer] = raw.records.compactMap { record in
                                    guard let q = SourceBoundary400Policy.points(record["polygon"]),
                                          let rawOffer = record["rawOffer"] as? [String: Any],
                                          let receipt = rawOffer["sourceReceipt"] as? [String: Any],
                                          let targets = receipt["predictedRelativeTargets"] as? [Double] else { return nil }
                                    return Alternative.Offer(polygon: q, relativeTargets: targets)
                                }
                                utility435Receipt["all8ModelSHA256"] = SourceUtility435All8Calibration.modelSHA256
                                utility435Receipt["all8BaselineCurrentU"] = chosenPolygon.map { [Double($0.x), Double($0.y)] }
                                if let alternative = Alternative.preferred(model: model,
                                    sourceFeatures50: source.features, offers: offers, currentU: chosenPolygon,
                                    rootW: CGFloat(source.rootW), frame: CGSize(width: originalFrame.width, height: originalFrame.height)) {
                                    chosenPolygon = offers[alternative.index].polygon
                                    chosenKey = "source-utility435-all8"
                                    chosenScore = alternative.score; repairedCandidate416 = nil
                                    utility435Receipt["all8Decision"] = alternative.receipt
                                    utility435Receipt["all8SelectedIndex"] = alternative.index
                                    utility435Receipt["all8Score"] = alternative.score
                                } else {
                                    utility435Receipt["all8KeptCurrentU"] = true
                                }
                            }
                        }
                        output[offset] = chosenPolygon
                        if let candidate = repairedCandidate416 {
                            applied392?[row.index] = candidate
                        } else if let key = chosenKey {
                            applied392?[row.index] = NativeOCRResidualCandidate(key: key, polygon: chosenPolygon,
                                consumedIndices: prior.consumedIndices,
                                supportPoints: prior.candidate?.supportPoints ?? [],
                                associationKey: prior.inheritedAssociationKey)
                        }
                        records.append(["family": "source-cost416-selected", "sourceIndex": row.index,
                            "selectedKey": chosenKey as Any? ?? NSNull(), "selectedScore": chosenScore,
                            "fallbackChosen": chosenScore == 0, "sourceOnlySelection": true,
                            "GTCoordinatesUsed": false, "outputOrGraphMutated": chosenPolygon != prior.polygon,
                            "polygon": chosenPolygon.map { [Double($0.x), Double($0.y)] },
                            "actualPreviousPrior": prior.polygon.map { [Double($0.x), Double($0.y)] },
                            "preservedCurrentDefaultV3Fallback": true, "associatedStroke404": stroke404Receipt,
                            "supplementalPositiveLoss424": supplemental424,
                            "supplementalPositiveLoss426": supplemental426, "mixed427": mixed427Receipt,
                            "deep430": ["enabled":directDeep430,"directSourceArgmax":true,
                                "modelSHA256":SourceCost430Calibration.frozenModelSHA256,
                                "margin":primaryCostMargin430 as Any? ?? NSNull(),
                                "enclosureRouting":false,"sourceOnly52":true,
                                "actualNative425StillRequired":true]])
                        if liveCandidateAudit369.requestsSourceCost433FeasibleSelect,
                           let last = records.indices.last {
                            records[last]["feasibleDeep433"] = feasible433Receipt
                            if liveCandidateAudit369.requestsSourceUtility435 {
                                records[last]["family"] = "source-utility435-selected"
                                records[last]["sourceUtility435"] = utility435Receipt
                                records[last]["finalCropPolicy"] = liveCandidateAudit369.requestsSourceUtility435All8 ?
                                    "source-utility435-all8-select" : "source-utility435-direct-mean-select"
                                records[last]["legacyNative425PermissionClaimedForFinalCrop"] = false
                                records[last]["supplementalChecksDescribeBaseline433Only"] = true
                            }
                        }
                    }
                    var loggedFactory392 = generated.receipt
                    if liveCandidateAudit369.requestsFastMeanAudit435 {
                        loggedFactory392["legacy128ReadmissionSkippedForMean435"] = true
                        loggedFactory392["legacyHeavyPixelTraceOmittedForMean435"] = true
                        loggedFactory392["legacyGeometryMenuRetainedUnassessedForMean435"] = true
                        loggedFactory392["legacyGeneratedOfferCountForInputContext"] = generated.offers.count
                        loggedFactory392["independentOriginal392V3InputReadmissionRetained"] = true
                        loggedFactory392["original433FallbackIsOfflineAssemblyNotGTBasedRuntimeInput"] = true
                    }
                    if liveCandidateAudit369.requestsRepair402 {
                        loggedFactory392.removeValue(forKey: "operatorReceipts")
                        if var sourceObservation = loggedFactory392["sourceObservation"] as? [String: Any] {
                            sourceObservation.removeValue(forKey: "operatorReceipts")
                            loggedFactory392["sourceObservation"] = sourceObservation
                        }
                        loggedFactory392["operatorDiagnosticPayloadOmittedFromSelectTrace"] = true
                        loggedFactory392["completeMenusRetainedBySeparateAuditFamily"] = true
                    }
                    records.append(["family": family392, "sourceIndex": row.index,
                        "actualCurrent386Prior": prior.polygon.map { [Double($0.x), Double($0.y)] },
                        "actualResidualChildren": prior.consumedIndices,
                        "actualAssociationKey": prior.inheritedAssociationKey as Any? ?? NSNull(),
                        "actualSelectedConstructorKey": prior.candidate?.key as Any? ?? NSNull(),
                        "inheritedConstructorSupportPointCount": prior.candidate?.supportPoints.count ?? 0,
                        "sourceWindow": [search.window.left, search.window.top, search.window.width, search.window.height],
                        "sourceWidth": Double(m.rect.width), "actualSourceIndices": live.sources.map(\.index),
                        "localPeerEvidence": certification.record, "sourceFactoryReceipt": loggedFactory392,
                        "currentDefaultV3Fallback406": fallback406,
                        "rawOfferCount": generated.offers.count, "candidates": offerRecords392,
                        "exactSourceThresholdPrefilter422": liveCandidateAudit369.requestsSourceCostFast422,
                        "threshold422NativeNomineeKeys": sourceCost422NativeKeys.sorted(),
                        "nativeBatchPerformance":assessed392?.performance ?? [:],
                        "sourcePolicy394Enabled": !liveCandidateAudit369.requestsRepair402 && !liveCandidateAudit369.requestsSharedBoundary400 && !liveCandidateAudit369.requestsBoundary397 && liveCandidateAudit369.requestsOrientation394,
                        "sourcePolicy394Choice": policyChoice394,
                        "sourcePolicyNominatedCount": proposals392.count,
                        "sourceFeaturePrefix": liveSource22[row.index] ?? [],
                        "nativeMeasurementKind": m.kind, "nativeMeasurementScore": m.score,
                        "nativeBatchProposalCount": liveCandidateAudit369.requestsFastMeanAudit435 ? 0 : proposals392.count,
                        "nativeAssessmentInvocations": assessed392 == nil ? 0 :
                            (assessed392?.performance["independentBoundaryNativeBatchCount"] as? Int ?? 1),
                        "independentBoundaryEnabled": liveCandidateAudit369.requestsBoundaryLevels,
                        "independentBoundaryControl": liveCandidateAudit369.boundaryLevelsControl.rawValue,
                        "nativeBatchUnkeyedRecords": unkeyed392,
                        "nativeAdmissionPassCount": offerRecords392.filter { $0["nativeAdmissionPassed"] as? Bool == true }.count,
                        "finalAdmissionGranted": false, "automaticSelection": false,
                        "outputOrGraphMutated": false, "ownershipChanged": false])
                }
                records.append(["family": family392, "summary": true,
                    "actualCurrentLiveRootCount": graph392.live.count, "attemptedRoots": attempted392,
                    "auditMeasurementRecords": measurementRecords392,
                    "legacyMeasurementsOrProbeCacheWritten": false,
                    "maximumRoots": limit392, "finalAdmissionGranted": false,
                    "automaticSelection": false, "outputOrGraphMutated": false])
            } else {
                absent392(nil, "actual386-final-graph-constructor-binding-unavailable")
            }
        }
        return .init(polygons: output, consumed: consumed, records: records, associations: associations)
    }

    static func safe(_ candidate: NativeOCRResidualCandidate, measurement m: Measurement,
                     caps: [CGPoint], width: Int, height: Int) -> Bool {
        let q = candidate.polygon
        guard !candidate.key.isEmpty, q.count == 4,
              q.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                  $0.x <= CGFloat(width) && $0.y <= CGFloat(height) }) else { return false }
        var area: CGFloat = 0, turns: [CGFloat] = []
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            area += a.x * b.y - b.x * a.y
            turns.append((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
        }
        guard abs(area) > 2, turns.allSatisfy({ $0 >= -1e-7 }) || turns.allSatisfy({ $0 <= 1e-7 }) else { return false }
        let support = m.guardPoints + caps + NativeOCRSourceComponentBounds.visibleForeground(m) + candidate.supportPoints
        return support.allSatisfy { NativeOCRSourceComponentMeasurements.contains(q, $0, tolerance: 0.75) }
    }
}


/// Audit-only semantic fingerprint; never used to select or admit geometry.
enum NativeOCRResidualCandidateAuditDigest {
    static let schema = "key-accepted-children-quad-rounded1e-8-rejection-v1"
    static func digest(_ items: [[String: Any]]) -> String? {
        var data = Data()
        func appendInteger(_ value: Int64) {
            var bytes = value.littleEndian
            withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
        }
        func appendString(_ value: String) {
            let bytes = Array(value.utf8)
            appendInteger(Int64(bytes.count))
            data.append(contentsOf: bytes)
        }
        appendString(schema)
        appendInteger(Int64(items.count))
        let ordered = items.sorted { ($0["key"] as? String ?? "") < ($1["key"] as? String ?? "") }
        for item in ordered {
            guard let key = item["key"] as? String, let accepted = item["accepted"] as? Bool,
                  let children = item["consumedIndices"] as? [Int],
                  let polygon = item["polygon"] as? [[String: Any]] else { return nil }
            appendString(key)
            appendInteger(accepted ? 1 : 0)
            appendInteger(Int64(children.count))
            for child in children.sorted() { appendInteger(Int64(child)) }
            appendInteger(Int64(polygon.count))
            for point in polygon {
                for axis in ["x", "y"] {
                    guard let value = point[axis] as? Double else { return nil }
                    let scaled = value * 100_000_000
                    guard scaled.isFinite, abs(scaled) < 9e18 else { return nil }
                    appendInteger(Int64(scaled.rounded(.toNearestOrAwayFromZero)))
                }
            }
            appendString(item["rejection"] as? String ?? "")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
