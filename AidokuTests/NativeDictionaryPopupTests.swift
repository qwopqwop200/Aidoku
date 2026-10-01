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

    @Test func nativeScanningKeepsSentenceAndJapaneseRanges() {
        let text = "前文。 「日本語です！」次の文。"
        let offset = (text as NSString).range(of: "日本語").location
        #expect(NativeDictionarySelection.scan(text, offset: offset, length: 16, includeNonJapanese: false) == "日本語です")
        let sentence = NativeDictionarySelection.sentence(text, offset: offset)
        #expect(sentence.text == "「日本語です！」")
        #expect(sentence.offset == 1)
        #expect(NativeDictionarySelection.isJapanese("ｶ"))
        #expect(NativeDictionarySelection.isJapanese("𠮷"))
        #expect(!NativeDictionarySelection.isJapanese("a"))
        let unmatched = "「前文。日本語」"
        let context = NativeDictionarySelection.sentence(unmatched, offset: (unmatched as NSString).range(of: "日本語").location)
        #expect(context.text == "日本語")
        #expect(context.offset == 0)
    }

    @Test func furiganaAlignsKanaAndCompatibilityKanji() {
        let word = NativeDictionaryContent.expression("食べる", reading: "たべる", scale: 1)
        #expect(word.attribute(.nativeDictionaryRuby, at: 0, effectiveRange: nil) as? String == "た")
        #expect(word.attribute(.nativeDictionaryRuby, at: 1, effectiveRange: nil) == nil)
        let characters = NativeDictionaryContent.expression("﨑々", scale: 1)
        #expect(characters.attribute(.link, at: 0, effectiveRange: nil) != nil)
        #expect(characters.attribute(.link, at: 1, effectiveRange: nil) != nil)
    }

    @Test func nativePitchGroupsSmallKanaIntoMorae() {
        #expect(NativeDictionaryContent.morae("きょう") == ["きょ", "う"])
        let pitch = NativeDictionaryContent.pitch(reading: "きょう", accent: ["position": "LHL", "nasal": [1], "devoice": [2]], scale: 1)
        #expect(pitch.string.contains("[2]"))
        #expect(pitch.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
    }

    @Test func supplementaryCharactersKeepCorrectKanjiLinkRanges() {
        let output = NativeDictionaryContent.expression("🙂日本", scale: 1)
        #expect(output.length == 4)
        #expect(output.attribute(.link, at: 0, effectiveRange: nil) == nil)
        let url = output.attribute(.link, at: 2, effectiveRange: nil) as? URL
        #expect(URLComponents(url: url ?? URL(string: "about:blank")!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "日")
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

    @Test func deinflectionTapExplainsConjugationAndRerenderRetainsCollapsedGroups() throws {
        let entry: [String: Any] = ["expression": "食べた", "deinflectionTrace": [
            ["name": "past", "description": "Past tense of the verb"]
        ], "glossaries": [["dictionary": "example", "content": "eat"]]]
        let view = NativeDictionaryPopupView(position: .zero, clearSelection: false, lookupEntries: [entry], allowsMining: false)
        let coordinator = view.makeCoordinator()
        coordinator.history = [[entry]]
        coordinator.render([entry])
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(coordinator.stack)
        let tag = try #require(views.first { $0.accessibilityIdentifier == "dictionary.deinflection.tag" } as? UIButton)
        let explanation = try #require(views.first { $0.accessibilityIdentifier == "dictionary.deinflection.description" } as? UILabel)
        #expect(explanation.isHidden)
        tag.sendActions(for: .touchUpInside)
        #expect(!explanation.isHidden && explanation.text == "Past tense of the verb")
        tag.sendActions(for: .touchUpInside)
        #expect(explanation.isHidden)
        let disclosure = try #require(views.first { $0.accessibilityIdentifier == "dictionary.disclosure" } as? UIButton)
        disclosure.sendActions(for: .touchUpInside)
        coordinator.render([entry])
        let refreshed = try #require(descendants(coordinator.stack).first { $0.accessibilityIdentifier == "dictionary.disclosure" } as? UIButton)
        #expect(refreshed.accessibilityValue == "collapsed")
        coordinator.redirect([entry])
        let next = try #require(descendants(coordinator.stack).first { $0.accessibilityIdentifier == "dictionary.disclosure" } as? UIButton)
        #expect(next.accessibilityValue == "expanded")
        coordinator.navigate(-1)
        let previous = try #require(descendants(coordinator.stack).first { $0.accessibilityIdentifier == "dictionary.disclosure" } as? UIButton)
        #expect(previous.accessibilityValue == "collapsed")
    }
}
