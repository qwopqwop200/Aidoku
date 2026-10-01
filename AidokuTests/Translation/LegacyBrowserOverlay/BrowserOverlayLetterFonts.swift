@testable import Aidoku

// Test-only legacy browser reference.
import Foundation
import WebKit

/// Korean faces for source lettering styles, handed to the overlay's WebKit
/// document on request.
///
/// iOS ships one Hangul design (Apple SD Gothic Neo, Thin...Bold). Serif source
/// lettering (Mincho narration, serif visual-novel text) is set in a bundled
/// Myeongjo face instead: `AidokuSerifKR-Bold.woff2`, a renamed subset of Nanum
/// Myeongjo Bold (SIL OFL 1.1, see OCR-TRANSLATION-NOTICES.txt). The overlay
/// script asks for the face (a script message with reply) only when a document
/// contains a serif caption and keeps it for that document's lifetime. A
/// message handler is used rather than a URL scheme handler: registering a
/// scheme handler raised the app's footprint by about 10-20 MiB over a session.
final class BrowserOverlayLetterFonts: NSObject, WKScriptMessageHandlerWithReply, @unchecked Sendable {
    static let messageName = "aidokuLetterFont"
    static let shared = BrowserOverlayLetterFonts()

    /// Style key -> bundled WOFF2 face.
    private static let resources: [String: String] = ["serif": "AidokuSerifKR-Bold"]

    private let files: [String: URL]

    override private init() {
        var found: [String: URL] = [:]
        for (key, name) in Self.resources {
            if let url = Bundle.main.url(forResource: name, withExtension: "woff2") {
                found[key] = url
            }
        }
        files = found
        super.init()
    }

    /// Keys whose faces the overlay can request, for the appearance argument
    /// (`false` from the caller disables source lettering styles entirely).
    var appearanceValue: [String: Bool] {
        files.mapValues { _ in true }
    }

    /// Part of render cache identity: bundled faces change the painted pixels.
    var availabilityKey: String {
        "letter-styles-v1:" + files.keys.sorted().joined(separator: ",")
    }

    func register(in configuration: WKWebViewConfiguration, contentWorld: WKContentWorld) {
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: contentWorld, name: Self.messageName)
    }

    /// Replies with the face as base64 (about 0.5 MB of text, once per document).
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let key = message.body as? String, let file = files[key],
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return (nil, "unavailable")
        }
        return (data.base64EncodedString(), nil)
    }
}
