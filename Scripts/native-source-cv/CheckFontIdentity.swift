import AidokuNativeCV
import CryptoKit
import Foundation
@main struct CheckResolver {
    static func main() throws {
        let training = String(repeating: "a", count: 64)
        let record: [String: Any] = ["path": "ctfont://HiraginoSans-W3", "SHA256": training]
        let spec: [String: Any] = ["fonts": [record], "extendedFonts": [record], "nativeFonts": [record]]
        let resolved = try NativeSourceFontResolver.resolveMeasurementSpec(spec)
        let font = (resolved["fonts"] as! [[String: Any]])[0]
        let data = try Data(contentsOf: URL(fileURLWithPath: font["path"] as! String))
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        precondition(font["trainingSHA256"] as? String == training)
        precondition(font["SHA256"] as? String == actual)
        precondition(font["actualNativeFontSHA256"] as? String == actual)
        precondition(font["postScriptName"] as? String == "HiraginoSans-W3")
        precondition(font["systemFontIdentity"] as? String == "cross-platform-system-font-variant")
        let twice = try NativeSourceFontResolver.resolveMeasurementSpec(resolved)
        let repeated = (twice["fonts"] as! [[String: Any]])[0]
        precondition(repeated["trainingSHA256"] as? String == training)
        let matchedRecord: [String: Any] = ["path": "ctfont://HiraginoSans-W3", "SHA256": actual]
        let matchedSpec: [String: Any] = ["fonts": [matchedRecord], "extendedFonts": [matchedRecord], "nativeFonts": [matchedRecord]]
        let matched = try NativeSourceFontResolver.resolveMeasurementSpec(matchedSpec)
        let same = (matched["fonts"] as! [[String: Any]])[0]
        precondition(same["SHA256"] as? String == actual)
        precondition(same["trainingSHA256"] as? String == actual)
        precondition(same["systemFontIdentity"] as? String == "training-file-match")
        let resourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Aidoku/Resources/Translation/SourceReferenceFonts.bundle")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: resourceRoot.appendingPathComponent("manifest.json"))) as! [String: Any]
        let publicFonts = manifest["publicFonts"] as! [[String: Any]]
        let publicSpec: [String: Any] = ["fonts": publicFonts, "extendedFonts": publicFonts, "nativeFonts": publicFonts]
        let publicResolved = try NativeSourceFontResolver.resolveMeasurementSpec(publicSpec, resourceRoot: resourceRoot)
        let actualPublic = publicResolved["fonts"] as! [[String: Any]]
        for (before, after) in zip(publicFonts, actualPublic) {
            precondition(before["SHA256"] as? String == after["SHA256"] as? String)
            precondition(after["trainingSHA256"] == nil)
            precondition(after["systemFontIdentity"] == nil)
        }
        var bad = publicFonts[0]; bad["SHA256"] = training
        do {
            _ = try NativeSourceFontResolver.resolveMeasurementSpec(["fonts": [bad], "extendedFonts": [bad], "nativeFonts": [bad]], resourceRoot: resourceRoot)
            fatalError("Corrupt public SHA accepted")
        } catch NativeSourceFontResolver.Failure.unavailableFile { }
        // Exercise the borrowed-buffer Swift sidecar including empty exclusions.
        let reference = [Float](repeating: 1, count: 16 * 198)
        let query = [Float](repeating: 1, count: 198)
        let neighbors = try reference.withUnsafeBufferPointer {
            try NativeCosineNeighbors.search(queries: query, queryCount: 1, references: $0, referenceCount: 16, dimension: 198)
        }
        precondition(neighbors.indices == Array(0..<8).map(Int32.init))
        print("PASS: system variant/matching provenance, idempotence, public8 SHA/rejection, borrowed Swift neighbors")
    }
}
