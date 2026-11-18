import CoreGraphics
import Foundation

/// Standalone host test; compile only with NativeExplicitDisplayStrokePolicy.swift.
@main struct NativeExplicitDisplayStrokePolicySmoke {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ reason: String) {
            precondition(value, reason)
            checks += 1
        }
        let flag = "AIDOKU_SOURCE_AWARE_DISPLAY_GUARD"
        let previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag,"0",1)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let white = [254.0, 253, 249]
        let packet: [String: Any] = [
            "sourceOnly": true, "fill": ["rgb": white],
            "outline": ["present": false, "probability": 0.002, "widthPx": 0,
                        "measurementEvidence": ["reliable": true, "usableRays": 100]],
            "shadow": ["present": false, "probability": 0.0],
            "background": ["representation": "observed-context-palette",
                           "insufficientObservedContext": false,
                           "colors": [[130, 85, 127], [255, 255, 255]],
                           "observedContextWeights": [0.98, 0.02]]
        ]
        func ratio(_ p: [String: Any]?, fill: [Double] = white,
                   incumbent: CGFloat = 0.20, enabled: Bool = true) -> CGFloat {
            NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(
                chosenFillRGB: fill, sourceAppearance: p, incumbentRatio: incumbent, enabled: enabled)
        }
        check(ratio(packet) == 0.035, "supported plain source retains a thinner guard")
        check(ratio(packet, enabled: false) == 0.20, "rollback is exact")
        check(ratio(nil) == 0.20, "no source evidence falls back")
        check(ratio(packet, incumbent: 0.035) == 0.035, "never enlarge existing thin guard")
        check(ratio(packet, fill: [0, 0, 0]) == 0.20, "post-policy changed fill must not borrow source contrast")
        check(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(
            chosenFillRGB: white, sourceAppearance: packet) == 0.20, "explicit zero rollback is OFF")
        func changed(_ section: String, _ key: String, _ value: Any) -> [String: Any] {
            var result = packet
            var fields = result[section] as! [String: Any]
            fields[key] = value
            result[section] = fields
            return result
        }
        for (section, key, values) in [
            ("outline", "present", [true, NSNull()] as [Any]),
            ("outline", "probability", [0.122, -0.1, Double.nan, true, NSNull()] as [Any]),
            ("outline", "widthPx", [1, true, NSNull()] as [Any]),
            ("outline", "observedLayers", [[["widthPx": 1]], "malformed"] as [Any]),
            ("shadow", "present", [true, NSNull()] as [Any]),
            ("shadow", "probability", [0.2, Double.infinity, true] as [Any]),
            ("background", "representation", ["predicted-palette"] as [Any]),
            ("background", "insufficientObservedContext", [true, NSNull()] as [Any]),
            ("background", "colors", [[], [[255, 255, 255], [255, 255, 255]],
                                        [[130, 85], [255, 255, 255]]] as [Any]),
            ("background", "observedContextWeights", [[0.8, 0.2], [0.98], [0.98, -0.02],
                                                       [Double.nan, 0.02], [1.0, 1.0], [true, false]] as [Any])
        ] {
            for value in values {
                check(ratio(changed(section, key, value)) == 0.20, "uncertain \(section).\(key) must fall back")
            }
        }
        for evidence: [String: Any] in [["reliable": false, "usableRays": 100],
                                       ["reliable": true, "usableRays": 2], [:]] {
            check(ratio(changed("outline", "measurementEvidence", evidence)) == 0.20, "weak measurement")
        }
        // Genuine live absence packets omit present-outline measurement fields.
        var live = packet
        live["outline"] = ["present": false, "probability": 0.115, "widthPx": 0]
        let pixels: [String: Any] = ["GTAtInference": false, "samples": 1000,
            "roles": ["fill": ["confidentSamples": 266,
                "observedColours": [["rgb": white, "observedMass": 0.977]]],
                "outline": ["confidentSamples": 0, "meanProbability": 0.005]]]
        live["pixelRoleEvidence"] = pixels
        check(ratio(live) == 0.035, "live absence with independent pixel support")
        check(ratio(live, enabled: false) == 0.20, "live branch rollback")
        check(ratio(live, fill: [0, 0, 0]) == 0.20, "live branch does not replace source fill")
        for probability in [0.075, 0.15] {
            var p = live
            p["outline"] = ["present": false, "probability": probability, "widthPx": 0]
            check(ratio(p) == 0.035, "live absence threshold supported by pixels")
        }
        for probability in [0.15001, -0.001] {
            var p = live
            p["outline"] = ["present": false, "probability": probability, "widthPx": 0]
            check(ratio(p) == 0.20, "live absence probability bound")
        }
        var noPixels = live
        noPixels.removeValue(forKey: "pixelRoleEvidence")
        check(ratio(noPixels) == 0.20, "missing live pixel evidence is not absence proof")
        var measuredLive = live
        measuredLive["outline"] = ["present": false, "probability": 0.115, "widthPx": 0,
            "measurementEvidence": ["reliable": true, "usableRays": 100]]
        check(ratio(measuredLive) == 0.035, "ancillary rays do not suppress independent pixel absence proof")
        var measuredWithoutPixels = measuredLive
        measuredWithoutPixels.removeValue(forKey: "pixelRoleEvidence")
        check(ratio(measuredWithoutPixels) == 0.20, "measured-only probability gate remains strict")
        func liveChanged(_ path: [String], _ value: Any) -> [String: Any] {
            func replacing(_ d: [String: Any], _ keys: ArraySlice<String>) -> [String: Any] {
                var result = d
                let key = keys.first!
                result[key] = keys.count == 1 ? value : replacing(d[key] as! [String: Any], keys.dropFirst())
                return result
            }
            return replacing(live, path[...])
        }
        for (path, values) in [
            (["GTAtInference"], [true, NSNull()] as [Any]),
            (["samples"], [255, -1, true, Double.nan] as [Any]),
            (["roles", "fill", "confidentSamples"], [31, -1, true] as [Any]),
            (["roles", "outline", "confidentSamples"], [3, -1, true, Double.infinity] as [Any]),
            (["roles", "outline", "meanProbability"], [0.02001, -0.001, true] as [Any]),
            (["roles", "fill", "observedColours"], [[],
                [["rgb": white, "observedMass": 0.799]],
                [["rgb": white, "observedMass": 1.1]],
                [["rgb": [0, 0, 0], "observedMass": 0.99]]] as [Any])
        ] {
            for value in values {
                check(ratio(liveChanged(["pixelRoleEvidence"] + path, value)) == 0.20,
                    "live invalid/missing counter or colour \(path)")
            }
        }
        check(ratio(liveChanged(["pixelRoleEvidence", "roles", "outline", "confidentSamples"], 2.66)) == 0.035,
            "outline counter at one-percent bound")
        check(ratio(liveChanged(["pixelRoleEvidence", "roles", "outline", "meanProbability"], 0.02)) == 0.035,
            "outline mean probability bound")
        var noSource = packet
        noSource.removeValue(forKey: "sourceOnly")
        check(ratio(noSource) == 0.20, "source authority must be explicit")
        check(ratio(changed("background", "observedContextWeights", [0.95, 0.05])) == 0.035, "bounded clutter")
        check(ratio(changed("background", "observedContextWeights", [0.949, 0.051])) == 0.20, "clutter limit")
        // No original images: generated uniform geometry exercises adapter and
        // verifies fill, endpoint, 2px floor and unit conversion are unchanged.
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 130/255, green: 85/255, blue: 127/255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = context.makeImage()!
        let fill = CGColor(red: white[0]/255, green: white[1]/255, blue: white[2]/255, alpha: 1)
        func decide(_ font: CGFloat, owner: CGRect = CGRect(x: 4, y: 4, width: 40, height: 40),
                    source: [String: Any]? = packet) throws -> NativeExplicitDisplayStrokePolicy.Decision {
            try NativeExplicitDisplayStrokePolicy.decide(chosenFill: fill, restored: image,
                ownerOutputPixels: owner, fontOutputPixels: font, outputPixelsPerLayoutPoint: 2,
                sourceAppearance: source)
        }
        let off = try decide(60)
        setenv(flag, "1", 1)
        let on = try decide(60)
        check(off.outwardOutputPixels == 12, "legacy extent")
        check(abs(on.outwardOutputPixels - 2.1) < 0.00001, "bounded reduction")
        check(on.fullCoreTextLineWidth == on.outwardOutputPixels, "output to layout units")
        check(on.fill == off.fill && on.outline == off.outline, "preserve fill and BW endpoint")
        check(try decide(12).outwardOutputPixels == 2, "nonzero native floor")
        check(try decide(60, source: nil).outwardOutputPixels == 12, "old caller unchanged when flag ON")
        let empty = try decide(60, owner: CGRect(x: 100, y: 100, width: 10, height: 10))
        check(empty.backgroundSampleWasEmpty && empty.outwardOutputPixels == 12, "offpage uncertainty")
        // Optional saved REQUESTs are diagnostic metadata, not fresh inference
        // or proof of native rendering. IDs here are regression fixtures only.
        let nominated = ["0018": ["region-2": CGFloat(0.035), "region-3": CGFloat(0.035)],
                         "0210": ["region-0": CGFloat(0.20), "region-1": CGFloat(0.035),
                                  "region-3": CGFloat(0.035)]]
        for path in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let pages = request["pages"] as! [[String: Any]]
            for page in pages {
                guard let pageID = page["page"] as? String, let expected = nominated[pageID] else { continue }
                let items = page["items"] as! [[String: Any]]
                var matched = 0
                for item in items {
                    guard let id = item["id"] as? String, let expectedRatio = expected[id] else { continue }
                    let p = item["sourcePredictedStyle"] as! [String: Any]
                    let fill = (p["fill"] as! [String: Any])["rgb"] as! [Double]
                    let before = try JSONSerialization.data(withJSONObject: p, options: .sortedKeys)
                    check(ratio(p, fill: fill) == expectedRatio, "saved diagnostic \(pageID)/\(id)")
                    let after = try JSONSerialization.data(withJSONObject: p, options: .sortedKeys)
                    check(before == after, "source evidence unchanged")
                    matched += 1
                }
                check(matched == expected.count, "all nominated diagnostic owners covered")
            }
        }
        print("PASS \(checks) source-aware guard checks; no painter/layout/native parity claim")
    }
}
