import AidokuNativeCV
import CoreText
import CryptoKit
import Foundation

/// Resolve the real installed font file; never substitute CoreText raster output.
enum NativeSourceFontResolver {
    struct Face: Sendable {
        let fileURL: URL
        let index: Int32
        let postScriptName: String
        var packetDescriptor: [String: Any] {
            ["path": fileURL.path, "faceIndex": Int(index), "postScriptName": postScriptName]
        }
    }
    enum Failure: Error { case unavailableFont(String); case unavailableFile(String) }

    static func systemFace(postScriptName: String) throws -> Face {
        let font = CTFontCreateWithName(postScriptName as CFString, 256, nil)
        let actual = CTFontCopyPostScriptName(font) as String
        guard actual == postScriptName else { throw Failure.unavailableFont(postScriptName) }
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL, url.isFileURL,
              FileManager.default.isReadableFile(atPath: url.path) else { throw Failure.unavailableFile(postScriptName) }
        var index: Int32 = 0
        try url.path.withCString { path in
            try postScriptName.withCString { name in
                try NativeOpenCV.check(acv_font_face_index(path, name, &index))
            }
        }
        return Face(fileURL: url, index: index, postScriptName: actual)
    }

    static func publicFace(fileURL: URL, faceIndex: Int32 = 0, postScriptName: String? = nil) throws -> Face {
        guard fileURL.isFileURL, FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw Failure.unavailableFile(fileURL.absoluteString)
        }
        guard faceIndex >= 0 else { throw Failure.unavailableFile(fileURL.path) }
        var index = faceIndex
        if let postScriptName {
            try fileURL.path.withCString { path in
                try postScriptName.withCString { name in
                    try NativeOpenCV.check(acv_font_face_index(path, name, &index))
                }
            }
        }
        return Face(fileURL: fileURL, index: index, postScriptName: postScriptName ?? "")
    }
    /// Rebase exported public font paths and replace pinned system references by
    /// actual CoreText file URLs. Public files retain their accepted SHA256.
    static func resolveMeasurementSpec(_ spec: [String: Any], resourceRoot: URL? = nil) throws -> [String: Any] {
        try resolveFontGroups(spec, groups: ["fonts", "extendedFonts", "nativeFonts"], resourceRoot: resourceRoot)
    }

    /// Dedicated numeric BODY ABI. No empty or fabricated legacy font banks
    /// are created; callers must supply exactly the ordered four BASE fonts.
    /// File resolution, system identity and public-file SHA checks are shared
    /// with the unchanged legacy 4/8/4 resolver below.
    static func resolveBodyBase4MeasurementSpec(_ spec: [String: Any], resourceRoot: URL? = nil) throws -> [String: Any] {
        guard Set(spec.keys) == ["fonts"], let fonts = spec["fonts"] as? [[String: Any]], fonts.count == 4 else {
            throw Failure.unavailableFile("BASE4-only measurement specification")
        }
        for font in fonts {
            guard let path = font["path"] as? String, !path.isEmpty,
                  let sha = font["SHA256"] as? String, sha.count == 64,
                  sha.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
                throw Failure.unavailableFile("BASE4 pinned font descriptor")
            }
        }
        return try resolveFontGroups(spec, groups: ["fonts"], resourceRoot: resourceRoot)
    }

    private static func resolveFontGroups(_ spec: [String: Any], groups: [String], resourceRoot: URL?) throws -> [String: Any] {
        let root = resourceRoot ?? Bundle.main.url(forResource: "SourceReferenceFonts", withExtension: "bundle")
        var result = spec
        var hashesByPath: [String: String] = [:]
        func fileHash(_ url: URL) throws -> String {
            if let cached = hashesByPath[url.path] { return cached }
            let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            hashesByPath[url.path] = digest
            return digest
        }
        for key in groups {
            guard let records = spec[key] as? [[String: Any]] else { throw Failure.unavailableFile(key) }
            result[key] = try records.map { record -> [String: Any] in
                guard let path = record["path"] as? String else { throw Failure.unavailableFile(key) }
                var updated = record
                let requestedIndex: Double
                if let value = record["faceIndex"], !(value is NSNull) {
                    guard let number = value as? NSNumber else { throw Failure.unavailableFile("Font faceIndex: " + path) }
                    requestedIndex = number.doubleValue
                } else { requestedIndex = 0 }
                guard requestedIndex.isFinite, requestedIndex >= 0, requestedIndex <= Double(Int32.max),
                      requestedIndex.rounded() == requestedIndex else {
                    throw Failure.unavailableFile("Font faceIndex: " + path)
                }
                let face: Face
                var isSystemFont = false
                if path.hasPrefix("ctfont://") || path.hasPrefix("systemfont://") || record["systemFontIdentity"] != nil {
                    let name = (record["postScriptName"] as? String) ?? URL(string: path)?.host ?? ""
                    guard !name.isEmpty else { throw Failure.unavailableFont(path) }
                    face = try systemFace(postScriptName: name)
                    isSystemFont = true
                } else if path.hasPrefix("/System/Library/Fonts/") {
                    let name: String
                    let normalized = path.precomposedStringWithCanonicalMapping
                    if normalized.contains("角ゴシック W3") { name = "HiraginoSans-W3" }
                    else if normalized.contains("角ゴシック W6") { name = "HiraginoSans-W6" }
                    else if normalized.contains("角ゴシック W9") { name = "HiraginoSans-W9" }
                    else if normalized.contains("丸ゴ ProN W4") { name = "HiraMaruPro-W4" }
                    else if normalized.contains("明朝 ProN") {
                        // Accepted TTC face2 is ProN W6; face0 is ProN W3.
                        let index = Int32(requestedIndex)
                        guard index == 0 || index == 2 else { throw Failure.unavailableFont(path) }
                        name = index == 2 ? "HiraMinProN-W6" : "HiraMinProN-W3"
                    }
                    else { throw Failure.unavailableFont(path) }
                    face = try systemFace(postScriptName: name)
                    isSystemFont = true
                } else {
                    let url: URL
                    if path.hasPrefix("file://"), let file = URL(string: path) { url = file }
                    else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
                    else if let root { url = root.appendingPathComponent(path) }
                    else { throw Failure.unavailableFile(path) }
                    face = try publicFace(fileURL: url, faceIndex: Int32(requestedIndex))
                    if let expected = record["SHA256"] as? String {
                        let actual = try fileHash(url)
                        guard actual == expected.lowercased() else { throw Failure.unavailableFile("Font SHA256: " + path) }
                    }
                }
                if isSystemFont {
                    let training = (record["trainingSHA256"] ?? record["SHA256"]) as? String
                    let actual = try fileHash(face.fileURL)
                    if let training { updated["trainingSHA256"] = training }
                    updated["actualNativeFontSHA256"] = actual
                    updated["SHA256"] = actual
                    updated["systemFontIdentity"] = training?.lowercased() == actual
                        ? "training-file-match" : "cross-platform-system-font-variant"
                }
                updated["path"] = face.fileURL.path
                updated["faceIndex"] = Int(face.index)
                updated["postScriptName"] = face.postScriptName
                return updated
            }
        }
        return result
    }

}
