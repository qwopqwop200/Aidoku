import CoreFoundation
import Foundation

/// Compact detector observations for source-style/axis consumers. No probability
/// raster, erasure permission, inferred glyph/font, labels or peer data survives.
enum NativeSourceOwnedComponentProjection {
    static func project(_ value: Any?, width: Int, height: Int) -> [String: Any]? {
        guard width > 0, height > 0, let seeds = value as? [[String: Any]],
              !seeds.isEmpty, seeds.count <= 64 else { return nil }
        func integer(_ raw: Any?) -> Int? {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, abs(n.doubleValue) <= 1_073_741_824,
                  n.doubleValue.rounded() == n.doubleValue else { return nil }
            return n.intValue
        }
        var components: [[String: Any]] = [], omitted = 0, totalRuns = 0
        var seen = Set<String>()
        for seed in seeds {
            guard seed["provenance"] as? String == "db-complete-cc-candidates-v2",
                  integer(seed["ownershipVersion"]) == 2, seed["completeCCScan"] as? Bool == true,
                  integer(seed["sourceWidth"]) == width, integer(seed["sourceHeight"]) == height,
                  let threshold = seed["threshold"] as? Double, threshold == 0.9,
                  let mw = integer(seed["mapFullWidth"]), let mh = integer(seed["mapFullHeight"]),
                  (1...32768).contains(mw), (1...32768).contains(mh),
                  let ox = integer(seed["mapOriginX"]), let oy = integer(seed["mapOriginY"]),
                  ox >= 0, ox < mw, oy >= 0, oy < mh,
                  let parent = integer(seed["parentBoxIndex"]), (0..<4096).contains(parent),
                  let owner = seed["ownerID"] as? String, !owner.isEmpty, owner.utf8.count <= 160,
                  let ambiguous = seed["ambiguousComponents"] as? [Any], ambiguous.isEmpty,
                  let candidates = seed["candidateComponents"] as? [Any], candidates.isEmpty,
                  let owned = seed["components"] as? [[String: Any]], !owned.isEmpty,
                  owned.count <= 16, components.count + owned.count <= 16 else { omitted += 1; continue }
            var measured: [[String: Any]] = [], valid = true
            var identities = Set<String>()
            for component in owned {
                guard let id = integer(component["seed"]), id >= 0, id < mw * mh,
                      let count = integer(component["pixelCount"]), (1...262144).contains(count),
                      let mean = component["meanProbability"] as? Double, mean.isFinite, (0.9...1).contains(mean),
                      let runs = component["runs"] as? [[String: Any]], !runs.isEmpty,
                      runs.count <= 4096, totalRuns + runs.count <= 8192 else { valid = false; break }
                totalRuns += runs.count
                var left = mw, right = 0, top = mh, bottom = 0, pixels = 0, previousY = -1, previousEnd = -1
                for (index, run) in runs.enumerated() {
                    guard let x = integer(run["x"]), let y = integer(run["y"]), let length = integer(run["count"]),
                          x >= ox, x < mw, y >= oy, y < mh, length > 0, length <= mw - x,
                          y > previousY || (y == previousY && x >= previousEnd),
                          index != 0 || id == y * mw + x else { valid = false; break }
                    pixels += length
                    guard pixels <= count else { valid = false; break }
                    left = min(left, x); right = max(right, x + length)
                    top = min(top, y); bottom = max(bottom, y + 1)
                    previousY = y; previousEnd = x + length
                }
                let identity = "\(mw):\(mh):\(parent):\(id)"
                guard valid, pixels == count, right > left, bottom > top,
                      !seen.contains(identity), identities.insert(identity).inserted else { valid = false; break }
                measured.append(["bounds": [Double(left) / Double(mw), Double(top) / Double(mh),
                    Double(right - left) / Double(mw), Double(bottom - top) / Double(mh)],
                    "pixels": count, "meanProbability": mean, "parentBoxIndex": parent, "componentSeed": id,
                    "ownerID": owner, "detectorGridSize": [mw, mh], "detectorGridOrigin": [ox, oy]])
            }
            if valid { components += measured; seen.formUnion(identities) } else { omitted += 1 }
        }
        guard !components.isEmpty else { return nil }
        return ["version": 1, "originalSourceSize": [width, height], "coordinateSpace": "normalized-top-left",
            "status": omitted == 0 ? "complete-exclusive-components" : "partial-exclusive-components",
            "complete": omitted == 0, "omittedComponentCount": omitted == 0 ? 0 : NSNull(),
            "components": components, "omittedSeedCount": omitted,
            "authority": "validated exclusive original DB cells; component envelopes, NOT glyph/font truth or erasure authority"]
    }
}
