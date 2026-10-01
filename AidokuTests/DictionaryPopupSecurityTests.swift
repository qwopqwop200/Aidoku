import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct DictionaryPopupSecurityTests {
    @Test func structuredGlossaryRejectsExecutableContentAndPreservesNormalMarkup() throws {
        let normal: [[String: Any]] = [
            ["tag": "ruby", "content": [["tag": "span", "content": "日本語"], ["tag": "rt", "content": "にほんご"]]],
            ["tag": "table", "content": ["tag": "tr", "content": ["tag": "td", "colSpan": 2, "content": "definition"]]],
            ["tag": "span", "lang": "ja", "title": "title", "data": ["testValue": "one"],
             "style": ["fontWeight": "bold"], "content": "entry"],
            ["tag": "a", "href": "https://example.invalid/definition", "content": "reference"]
        ]
        let executable: [[String: Any]] = ["script", "ScRiPt", "style", "iframe"].map {
            ["tag": $0, "content": "window.__auditMarker = 71;"]
        }
        func render(_ content: [[String: Any]]) throws -> NSAttributedString {
            let data = try JSONSerialization.data(withJSONObject: ["type": "structured-content", "content": content])
            return NativeDictionaryContent.glossary(String(decoding: data, as: UTF8.self), dictionary: "security", scale: 1)
        }
        let baseline = try render(normal)
        let actual = try render(executable + normal)
        #expect(actual.isEqual(to: baseline), "Rejected nodes must not alter safe native text or its attributes")
        #expect(!actual.string.contains("__auditMarker"))
        #expect(actual.string.contains("日本語") && actual.string.contains("definition"))
        let ruby = try #require(range(of: "日本語", in: actual))
        #expect(actual.attribute(.nativeDictionaryRuby, at: ruby.location, effectiveRange: nil) as? String == "にほんご")
        let entry = try #require(range(of: "entry", in: actual))
        #expect(actual.attribute(.nativeDictionaryLanguage, at: entry.location, effectiveRange: nil) as? String == "ja")
        let font = try #require(actual.attribute(.font, at: entry.location, effectiveRange: nil) as? UIFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        let reference = try #require(range(of: "reference", in: actual))
        #expect(actual.attribute(.link, at: reference.location, effectiveRange: nil) as? URL
            == URL(string: "https://example.invalid/definition"))
    }

    @Test func htmlGlossaryLinksCannotInvokeBrowserActions() throws {
        let html = "<script>window.__auditMarker = 71;</script><iframe>unsafe embedded document</iframe>"
            + "<p><b>definition</b> <a href='javascript:window.__auditMarker=71'>script link</a>"
            + " <a href='data:text/html,unsafe'>data link</a> <a href='file:///private/fixture'>file link</a></p>"
        let value = NativeDictionaryContent.glossary(html, dictionary: "security", scale: 1)
        #expect(!value.string.contains("__auditMarker") && !value.string.contains("unsafe embedded document"))
        #expect(value.string.contains("definition"))
        var redirects: [String] = []
        var kanjiRedirects: [String] = []
        let popup = NativeDictionaryPopupView(position: .zero, clearSelection: false, allowsMining: false,
            onRedirect: { redirects.append($0); return [] },
            onKanjiRedirect: { kanjiRedirects.append($0); return nil })
        let coordinator = popup.makeCoordinator()
        defer { NativeDictionaryPopupView.dismantleUIView(UIScrollView(), coordinator: coordinator) }
        let view = UITextView()
        view.attributedText = value
        for label in ["script link", "data link", "file link"] {
            let linkRange = try #require(self.range(of: label, in: value))
            let link = try #require(value.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)
            #expect(!coordinator.textView(view, shouldInteractWith: link, in: linkRange, interaction: .invokeDefaultAction),
                    "The native popup must handle untrusted links without forwarding them to a browser")
        }
        #expect(redirects.isEmpty && kanjiRedirects.isEmpty)
        #expect(coordinator.history.isEmpty)
    }

    private func range(of text: String, in value: NSAttributedString) -> NSRange? {
        let range = (value.string as NSString).range(of: text)
        return range.location == NSNotFound ? nil : range
    }
}
