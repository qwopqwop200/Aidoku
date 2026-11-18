import AidokuNativeCV
import Foundation
func checkNativeSourceImports(_ packet: [String: Any]) throws {
    _ = try ACVSourceFeatureBridge.coreSignals(forPacket: packet)
    var error: NSError?
    _ = AIDExtractAllSourceSignals(packet, &error)
}
