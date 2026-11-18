import CoreFoundation
import Foundation

/// Same-transaction inferred-em equality for fallback fit closure ONLY.
/// This does not define typography, shared pitch, weight, palette or placement
/// axes. The caller owns the page transaction; tokens intentionally contain no
/// page/owner identity and there is no cross-call registry or stored lookup.
enum NativeSourceFontFitGroups {
    static let authority = "same-call-inferred-source-em;exact-Double-bitPattern;fit-fallback-closure-only"

    static func annotate(_ items: [[String: Any]]) -> [[String: Any]] {
        var groups: [UInt64: [Int]] = [:]
        let reserved = Set(items.compactMap { $0["sourceFontFitGroupID"] as? String })
        for (index, item) in items.enumerated() {
            // Any explicit ID, including an invalid/empty/null one, belongs to
            // its producer and is never replaced or recruited into a new group.
            guard item["sourceFontFitGroupID"] == nil,
                  item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true,
                  let text = item["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let number = item["sourceRequestedDisplayFontSize"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let font = number.doubleValue
            guard font.isFinite, font > 0 else { continue }
            groups[font.bitPattern, default: []].append(index)
        }
        var output = items
        for (bits, members) in groups where members.count >= 2 {
            let token = "source-font-fit-em-v1-" + String(format: "%016llx", bits)
            // Do not accidentally join an unrelated explicit cohort that happens
            // to use this reserved token. Abstain instead of renaming its ID.
            guard !reserved.contains(token) else { continue }
            for index in members {
                output[index]["sourceFontFitGroupID"] = token
                if output[index]["sourceFontFitGroupAuthority"] == nil {
                    output[index]["sourceFontFitGroupAuthority"] = authority
                }
            }
        }
        return output
    }
}
