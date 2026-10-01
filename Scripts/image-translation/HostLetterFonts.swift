import Foundation
import CoreText

/// Register the reader's bundled face directly in Core Text for this CLI process.
/// No browser resource handler or separate host font asset is involved.
final class HostLetterFonts {
    private static let resources = ["serif": "AidokuSerifKR-Bold"]
    private let available: [String: Bool]

    static func resourceURL(name: String, extension suffix: String) -> URL? {
        guard let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] else { return nil }
        let url = URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation")
            .appendingPathComponent(name).appendingPathExtension(suffix)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    init(root: URL) {
        available = Self.resources.reduce(into: [:]) { result, entry in
            let url = root.appendingPathComponent("Aidoku/Resources/Translation")
                .appendingPathComponent(entry.value).appendingPathExtension("woff2")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) {
                result[entry.key] = true
            } else {
                let font = CTFontCreateWithName(entry.value as CFString, 12, nil)
                if CTFontCopyPostScriptName(font) as String == entry.value { result[entry.key] = true }
            }
        }
    }

    var appearanceValue: [String: Bool] { available }
    var availabilityKey: String { "native-letter-styles-v1:" + available.keys.sorted().joined(separator: ",") }
}

/// Decode and migrate the same persisted overlay type that the iPhone loads.
enum HostOverlayAppearance {
    static func settings(saved: [String: Any]) throws -> IPhoneOverlaySettings {
        let defaults = IPhoneOverlaySettings(
            visible: true, mode: .translateOnly, colorMode: .white, opacity: 0.84,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 2,
            subtitleContextSentences: 0
        )
        // CLI fixtures may specify only the preferences they override. Actual
        // phone snapshots contain the complete persisted settings dictionary.
        var values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
        values.merge(saved) { _, stored in stored }
        var settings = try JSONDecoder().decode(IPhoneOverlaySettings.self,
            from: JSONSerialization.data(withJSONObject: values))
        settings.enforceSourceReplacement()
        return settings
    }

    static func value(settings: IPhoneOverlaySettings, fonts: HostLetterFonts) -> [String: Any] {
        let letterFonts: Any = settings.preserveSourceColors ? fonts.appearanceValue : false
        return [
            "opacity": settings.renderedBackgroundOpacity,
            "sourceLetterFonts": letterFonts,
            "preserveSourceTextColor": settings.preserveSourceTextColor,
            "preserveSourceBackgroundColor": settings.preserveSourceBackgroundColor,
            "inpaintingEnabled": settings.usesSourceInpainting,
            "minimumReadableFontSize": 5
        ]
    }
}
