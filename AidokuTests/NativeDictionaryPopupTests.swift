import Testing
import UIKit
import SwiftUI
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct NativeDictionaryPopupTests {
    @Test func structuredDictionaryContentPreservesTextFormattingAndSafeLinks() throws {
        let input: [String: Any] = ["type": "structured-content", "content": [
            ["tag": "ruby", "content": [["tag": "span", "content": "日本語"], ["tag": "rt", "content": "にほんご"]]],
            ["tag": "strong", "content": "definition"],
            ["tag": "a", "href": "https://example.invalid/reference", "content": "reference"],
            ["tag": "table", "content": ["tag": "tr", "content": ["tag": "td", "content": "cell"]]],
            ["tag": "ScRiPt", "content": "unsafe dictionary script"],
            ["tag": "iframe", "content": "unsafe embedded document"]
        ]]
        let json = try #require(String(data: JSONSerialization.data(withJSONObject: input), encoding: .utf8))
        let output = NativeDictionaryContent.glossary(json, dictionary: "__proto__", scale: 1)
        #expect(output.string.contains("日本語"))
        #expect(!output.string.contains("にほんご"))
        #expect(output.string.contains("definition") && output.string.contains("cell"))
        #expect(!output.string.contains("unsafe"))
        let reference = (output.string as NSString).range(of: "reference")
        #expect(output.attribute(.link, at: reference.location, effectiveRange: nil) as? URL == URL(string: "https://example.invalid/reference"))
        let ruby = (output.string as NSString).range(of: "日本語")
        #expect(output.attribute(.nativeDictionaryRuby, at: ruby.location, effectiveRange: nil) as? String == "にほんご")
    }

    @Test func htmlGlossariesUseNativeParserAndPreserveDefinitions() {
        let output = NativeDictionaryContent.glossary("<p>첫 뜻 <b>강조</b></p><ul><li>다음 뜻</li></ul><script>bad()</script>",
                                                     dictionary: "constructor", scale: 1)
        #expect(output.string.contains("첫 뜻 강조"))
        #expect(output.string.contains("다음 뜻"))
        #expect(!output.string.contains("bad()"))
        let emphasis = (output.string as NSString).range(of: "강조")
        let font = output.attribute(.font, at: emphasis.location, effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    @Test func popupDisplaysAllResultsThroughNativeViewsAndHonorsMiningPreference() async throws {
        let entries: [[String: Any]] = ["constructor", "__proto__", "toString"].map { name in
            ["expression": "日本語", "reading": "にほんご", "glossaries": [
                ["dictionary": name, "content": "Definition for \(name)"]
            ]]
        }
        let view = NativeDictionaryPopupView(position: .zero, clearSelection: false, lookupEntries: entries, allowsMining: false,
                                             onMine: { _, _ in false })
        let host = UIHostingController(rootView: view)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host.view)
        #expect(!views.contains { NSStringFromClass(type(of: $0)).contains("WKWebView") })
        let texts = views.compactMap { ($0 as? UITextView)?.text }.joined(separator: "\n")
        #expect(texts.contains("Definition for constructor"))
        #expect(texts.contains("Definition for __proto__"))
        #expect(texts.contains("Definition for toString"))
        #expect(!views.contains { $0.accessibilityIdentifier == "dictionary.mine" })
        let disclosure = try #require(views.first { $0.accessibilityIdentifier == "dictionary.disclosure" } as? UIButton)
        disclosure.sendActions(for: .touchUpInside)
        #expect(disclosure.accessibilityValue == "collapsed")
        disclosure.sendActions(for: .touchUpInside)
        #expect(disclosure.accessibilityValue == "expanded")
    }

    /// Large dictionary images decode only display-sized pixels while keeping layout.
    @Test func largeRasterDecodesOnlyDisplayPixels() throws {
        let context = try #require(CGContext(data: nil, width: 1600, height: 800, bitsPerComponent: 8, bytesPerRow: 6400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        let cgImage = try #require(context.makeImage())
        let data = try #require(UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8))
        let result = NativeDictionaryMedia.attachment(["path": "fixture.jpg", "width": 100, "height": 50], dictionary: "fixture",
            attributes: [.font: UIFont.systemFont(ofSize: 15)], availableWidth: 260, load: { _, _ in data })
        let attachment = try #require(result.attribute(.attachment, at: 0, effectiveRange: nil) as? NativeDictionaryImageAttachment)
        let image = try #require(attachment.original.cgImage)
        let scale = min(3, UIScreen.main.scale)
        #expect(attachment.bounds.size == CGSize(width: 100, height: 50))
        #expect(image.width <= Int(ceil(100 * scale)) && image.height <= Int(ceil(50 * scale)))
    }
}
