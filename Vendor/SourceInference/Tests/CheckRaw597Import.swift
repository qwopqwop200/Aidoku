import AidokuNativeCV
import Foundation

/// Typecheck the actual public module declaration, not the fake replay module.
func checkRaw597PublicImport(_ packet: [String: Any]) throws -> [Double] {
    var error: NSError?
    guard let values = AIDExtractSourceWeightRaw597(packet, &error),
          let raw = values["raw597"] as? [Double], raw.count == 597 else {
        throw error ?? NSError(domain: "Aidoku.Raw597ImportCheck", code: 1)
    }
    return raw
}
