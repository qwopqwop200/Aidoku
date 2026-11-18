import Foundation

/// One paragraph convention per explicit typography cohort, scoped to one page.
/// This changes row alignment only; source anchors, membership and font stay intact.
enum NativeTextAlignmentPolicy {
    static func annotate(_ items: [[String: Any]]) -> [[String: Any]] {
        let valid = ["left", "center", "right"]
        func alignment(_ item: [String: Any]) -> String {
            if let value = item["textAlignment"] as? String, valid.contains(value) { return value }
            let role = item["role"] as? String ?? item["semanticRole"] as? String ?? "dialogue"
            return ["narration", "story_text", "caption"].contains(role) ? "left" : "center"
        }
        var groups: [String: [Int]] = [:]
        for index in items.indices {
            let item = items[index]
            guard item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true,
                  item["vertical"] as? Bool != true, item["writingMode"] as? String != "vertical-rl",
                  let group = item["typographyGroupID"] as? String, !group.isEmpty else { continue }
            groups[group, default: []].append(index)
        }
        var result = items
        for indices in groups.values where indices.count > 1 {
            var counts: [String: Int] = [:]
            for index in indices { counts[alignment(items[index]), default: 0] += 1 }
            // Center is the ordinary dialogue convention and the deterministic
            // tie break. Uniform narration cohorts retain their left edge.
            var selected = "center"
            for candidate in ["left", "right"] where counts[candidate, default: 0] > counts[selected, default: 0] {
                selected = candidate
            }
            for index in indices where alignment(items[index]) != selected {
                result[index]["textAlignment"] = selected
                if var guide = result[index]["textPlacementGuide"] as? [String: Any] {
                    guide["horizontal"] = selected
                    result[index]["textPlacementGuide"] = guide
                }
                result[index]["textAlignmentAuthority"] = "shared-typography-majority; center-on-tie"
            }
        }
        return result
    }
}
