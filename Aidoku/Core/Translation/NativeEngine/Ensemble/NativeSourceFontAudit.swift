import Foundation

/// All sizes use the caller's logical viewport units. Unknown original style
/// remains null; requested display size is not an original-source estimate.
enum NativeSourceFontAudit {
    static func record(raw: [String: Any]?, requestedDisplay: Double, displayed: Double) -> [String: Any] {
        let source: Double?
        if let n = raw?["sourceFontSize"] as? NSNumber,
           CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue > 0 {
            source = n.doubleValue
        } else { source = nil }
        return ["sourceFontSize": source.map { $0 as Any } ?? NSNull(),
                "requestedDisplayFontSize": requestedDisplay,
                "legacySourceFontSize": requestedDisplay,
                "sourceFontSizeAuthority": source == nil ? "unmeasured" : "original-item-sourceFontSize-estimate;not-human-gold",
                "fontAuditVersion": 2,
                "legacySourceFontSizeAuthority": "v1-field-was-requested-display-size;kept-for-comparison",
                "displayToSourceFontRatio": source.map { displayed / $0 as Any } ?? NSNull()]
    }
}
