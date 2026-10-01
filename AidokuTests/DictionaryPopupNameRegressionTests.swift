import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct DictionaryPopupNameRegressionTests {
    @Test func prototypeDictionaryNamesPreserveNativeGlossariesAndIndependentGroups() throws {
        let names = ["Ordinary Dictionary", "constructor", "__proto__", "toString"]
        for content in ["definition", "<b>definition</b><br>normal markup"] {
            let entry: [String: Any] = ["expression": "日本", "reading": "", "glossaries": names.map { name in
                ["dictionary": name, "content": content, "definitionTags": "", "termTags": ""]
            }]
            let popup = NativeDictionaryPopupView(position: .zero, clearSelection: false,
                lookupEntries: [entry], allowsMining: false)
            let coordinator = popup.makeCoordinator()
            defer { NativeDictionaryPopupView.dismantleUIView(UIScrollView(), coordinator: coordinator) }
            coordinator.history = [[entry]]
            coordinator.render([entry])
            let views = descendants(of: coordinator.stack)
            let disclosures = views.compactMap { $0 as? UIButton }.filter {
                $0.accessibilityIdentifier == "dictionary.disclosure"
            }
            try #require(disclosures.count == names.count)
            #expect(disclosures.map { $0.title(for: .normal) } == names.map(Optional.some))
            let definitions = views.compactMap { $0 as? UITextView }.filter { $0.text.contains("definition") }
            try #require(definitions.count == names.count)
            let ordinary = try #require(definitions.first?.attributedText)
            for definition in definitions {
                #expect(definition.isSelectable && !definition.isEditable)
                #expect(definition.attributedText.isEqual(to: ordinary),
                        "A dictionary name must not alter or discard its definition markup")
                #expect(definition.text == (content == "definition" ? "definition" : "definition\nnormal markup"))
                if content != "definition" {
                    let font = definition.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
                    #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
                }
            }
            #expect(!views.contains { NSStringFromClass(type(of: $0)).contains("WKWebView") })
            // Names which were JavaScript object properties must remain separate,
            // usable native sections, including after rebuilding the popup.
            for index in names.indices {
                let current = descendants(of: coordinator.stack).compactMap { $0 as? UIButton }.filter {
                    $0.accessibilityIdentifier == "dictionary.disclosure"
                }
                try #require(current.count == names.count)
                current[index].sendActions(for: .touchUpInside)
                #expect(current.enumerated().allSatisfy {
                    $0.element.accessibilityValue == ($0.offset == index ? "collapsed" : "expanded")
                })
                coordinator.render([entry])
                let refreshed = descendants(of: coordinator.stack).compactMap { $0 as? UIButton }.filter {
                    $0.accessibilityIdentifier == "dictionary.disclosure"
                }
                try #require(refreshed.count == names.count)
                #expect(refreshed[index].accessibilityValue == "collapsed")
                refreshed[index].sendActions(for: .touchUpInside)
                #expect(refreshed.allSatisfy { $0.accessibilityValue == "expanded" })
            }
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
