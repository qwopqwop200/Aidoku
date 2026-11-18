import Foundation

/// Resolve accepted public reference bytes by their packaged SHA256 paths.
/// Font names/weights describe reference rasters, never page or word classes.
enum NativeSourceWeightFontResources {
    enum Failure: Error { case invalidReferences }
    static func pairs(_ records: [[String: Any]], resourceRoot: URL? = nil) throws -> [[String: Any]] {
        guard !records.isEmpty, records.count <= 32 else { throw Failure.invalidReferences }
        var fonts: [[String: Any]] = []
        for pair in records {
            for key in ["regular", "heavy"] {
                guard var record = pair[key] as? [String: Any], let digest = record["SHA256"] as? String,
                      digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw Failure.invalidReferences }
                record["path"] = "fonts/" + digest.lowercased() + ".ttf"
                fonts.append(record)
            }
        }
        let specification: [String: Any] = ["fonts": fonts, "extendedFonts": [[String: Any]](), "nativeFonts": [[String: Any]]()]
        let resolved = try NativeSourceFontResolver.resolveMeasurementSpec(specification, resourceRoot: resourceRoot)
        guard let values = resolved["fonts"] as? [[String: Any]], values.count == records.count * 2 else {
            throw Failure.invalidReferences
        }
        return records.enumerated().map { index, pair in
            var value = pair; value["regular"] = values[index * 2]; value["heavy"] = values[index * 2 + 1]
            return value
        }
    }
}
