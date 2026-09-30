import Foundation
import WebKit

/// The production BrowserOverlayLetterFonts reply contract, with repository
/// resources replacing Bundle.main because the Swift host is not an app bundle.
final class HostLetterFonts: NSObject, WKScriptMessageHandlerWithReply, @unchecked Sendable {
    static let messageName = "aidokuLetterFont"
    private static let resources: [String: String] = ["serif": "AidokuSerifKR-Bold"]
    private let files: [String: URL]

    init(root: URL) {
        var found: [String: URL] = [:]
        let directory = root.appendingPathComponent("Aidoku/Resources/Translation")
        for (key, name) in Self.resources {
            let url = directory.appendingPathComponent(name).appendingPathExtension("woff2")
            if FileManager.default.fileExists(atPath: url.path) { found[key] = url }
        }
        files = found
        super.init()
    }

    var appearanceValue: [String: Bool] { files.mapValues { _ in true } }

    var availabilityKey: String {
        "letter-styles-v1:" + files.keys.sorted().joined(separator: ",")
    }

    func register(in configuration: WKWebViewConfiguration, contentWorld: WKContentWorld) {
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: contentWorld, name: Self.messageName)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let key = message.body as? String, let file = files[key],
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return (nil, "unavailable")
        }
        return (data.base64EncodedString(), nil)
    }
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
