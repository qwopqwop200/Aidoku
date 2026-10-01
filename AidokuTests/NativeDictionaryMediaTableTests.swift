import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct NativeDictionaryMediaTableTests {
    @Test func structuredImageUsesPreferredDimensionsAndCSSUnits() {
        guard #available(iOS 18.0, *) else { return }
        let font = UIFont.systemFont(ofSize: 15)
        let natural = CGSize(width: 200, height: 100)
        let em = NativeDictionaryMedia.geometry(["preferredWidth": 2, "width": 200, "height": 100, "sizeUnits": "em"],
                                               naturalSize: natural, font: font, availableWidth: 320)
        #expect(em.size == CGSize(width: 30, height: 15))
        let pixels = NativeDictionaryMedia.geometry(["width": 200, "height": 100], naturalSize: natural,
                                                   font: font, availableWidth: 320)
        #expect(pixels.size == natural)
        let preferredHeight = NativeDictionaryMedia.geometry(["preferredHeight": 3, "width": 200, "height": 100, "sizeUnits": "em"],
                                                            naturalSize: natural, font: font, availableWidth: 320)
        #expect(preferredHeight.size == CGSize(width: 90, height: 45))
        let naturalWithoutMetadata = NativeDictionaryMedia.geometry([:], naturalSize: natural, font: font, availableWidth: 100)
        #expect(naturalWithoutMetadata.size == CGSize(width: 100, height: 50))
    }

    @Test func nativeSVGCreatesActualPixelsAndMonochromeRetainsAlpha() throws {
        guard #available(iOS 18.0, *) else { return }
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10"><path d="M2 2H8V8H2Z" fill="#00ff00"/></svg>"##
        let value = NativeDictionaryMedia.attachment(["path": "fixture.svg", "preferredWidth": 2, "sizeUnits": "em", "appearance": "monochrome"],
            dictionary: "fixture", attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.red],
            availableWidth: 320, load: { _, _ in Data(svg.utf8) })
        let attachment = try #require(value.attribute(.attachment, at: 0, effectiveRange: nil) as? NativeDictionaryImageAttachment)
        #expect(attachment.bounds.size == CGSize(width: 30, height: 30))
        for dark in [false, true] {
            var rendered: UIImage?
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
                rendered = attachment.image(forBounds: attachment.bounds, textContainer: nil, characterIndex: 0)
            }
            let image = try #require(rendered)
            let pixels = try #require(image.cgImage)
            let context = try #require(CGContext(data: nil, width: 30, height: 30, bitsPerComponent: 8, bytesPerRow: 120,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: 30, height: 30))
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let center = 15 * 120 + 15 * 4
            for channel in 0..<3 {
                #expect(dark ? bytes[center + channel] > 240 : bytes[center + channel] < 10,
                        "Monochrome SVG must match frozen black/light and white/dark rendering")
            }
            #expect(bytes[center + 3] > 240 && bytes[3] < 10, "Native SVG tinting must preserve opaque ink and transparent corners")
        }
    }

    @Test func structuredTableSpansAndStylesReachSelectableNativeCells() throws {
        guard #available(iOS 18.0, *) else { return }
        let value: [String: Any] = ["type": "structured-content", "content": ["tag": "table", "content": [
            ["tag": "tr", "content": [["tag": "th", "rowSpan": 2, "content": "語"],
                ["tag": "td", "colSpan": 2, "data": ["kind": "meaning"], "content": "日本語"]]],
            ["tag": "tr", "content": [["tag": "td", "content": "左"], ["tag": "td", "content": "右"]]]]]]
        let data = try JSONSerialization.data(withJSONObject: value)
        let blocks = NativeDictionaryContent.glossaryBlocks(String(decoding: data, as: UTF8.self), dictionary: "fixture", scale: 1,
            stylesheet: "[data-sc-kind=meaning] { color: #123456; font-size: 2em; }", availableWidth: 300)
        let table = try #require(blocks.compactMap { block -> NativeDictionaryTable.Model? in
            if case .table(let table) = block { return table }; return nil
        }.first)
        #expect(table.rows == 2 && table.columns == 3)
        #expect(table.cells[0].rowSpan == 2 && table.cells[1].columnSpan == 2)
        #expect(table.cells[2].column == 1 && table.cells[3].column == 2)
        #expect((table.cells[1].content.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize == 30)
        let view = NativeDictionaryTableView(model: table) { value in
            let text = UITextView(); text.attributedText = value; text.isEditable = false; text.isSelectable = true; return text
        }
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300); view.layoutIfNeeded()
        #expect(view.subviews.count == 4)
        #expect(view.intrinsicContentSize.height > 20)
        let texts = view.subviews.flatMap(\.subviews).compactMap { $0 as? UITextView }
        #expect(texts.count == 4 && texts.allSatisfy(\.isSelectable))
        #expect(texts.map(\.text).contains("日本語"))
    }

    @Test func stylesheetAppliesClassDataSelectorsHTMLMediaAndRecordsResidualCSS() throws {
        guard #available(iOS 18.0, *) else { return }
        let rendered = NativeDictionaryContent.glossary("<p class='definition' lang='ja' data-sc-kind='term'>日本語</p>",
            dictionary: "fixture", scale: 1, stylesheet: ".definition[data-sc-kind=term] { font-weight: bold; color: rgb(1, 2, 3); display: grid; gap: 4px; }")
        let font = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(rendered.attribute(.nativeDictionaryLanguage, at: 0, effectiveRange: nil) as? String == "ja")
        #expect((rendered.attribute(.nativeDictionaryCSSDiagnostics, at: 0, effectiveRange: nil) as? [String])?.contains("gap") == true)
    }
    @Test func themeImportantVariablesAndHiddenRubyFollowNativeCascade() throws {
        guard #available(iOS 18.0, *) else { return }
        let content = "<div style='--ink:#123456'><ruby class='hidden'>消える<rt>きえる</rt></ruby><span class='term'>語</span></div>"
        let stylesheet = ".hidden{display:none}.term{font-size:20px!important;color:var(--ink)!important;font-weight:bold!important}"
            + "@media(prefers-color-scheme:dark){.term{color:white}}"
        var light: NSAttributedString?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            light = NativeDictionaryContent.glossary(content, dictionary: "fixture", scale: 1, stylesheet: stylesheet)
        }
        let value = try #require(light)
        #expect(!value.string.contains("消える") && value.string.contains("語"))
        let offset = (value.string as NSString).range(of: "語").location
        let font = try #require(value.attribute(.font, at: offset, effectiveRange: nil) as? UIFont)
        #expect(font.pointSize == 20 && font.fontDescriptor.symbolicTraits.contains(.traitBold))
        let ink = try #require(value.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor)
        #expect(ink == UIColor(red: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0, alpha: 1))
        var dark: NSAttributedString?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            dark = NativeDictionaryContent.glossary("<span class='term'>語</span>", dictionary: "fixture", scale: 1,
                stylesheet: ".term{color:black}@media(prefers-color-scheme:dark){.term{color:white}}")
        }
        #expect(dark?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .white)
        let computed = NativeDictionaryCSS.length("calc(100% - 2 * 1em)", font: .systemFont(ofSize: 15), relativeTo: 300)
        #expect(computed == 270)
    }

    @Test func nestedTablesAndGridKeepNativeSelectableChildrenAndHiddenRows() throws {
        guard #available(iOS 18.0, *) else { return }
        let content = "<div style='display:grid;grid-template-columns:1fr 1fr;gap:8px'><span>左</span>"
            + "<table><tr style='display:none'><td>隠す</td></tr><tr style='color:#123456'>"
            + "<td>外<table><tr><td>内</td></tr></table></td></tr></table></div>"
        let blocks = NativeDictionaryContent.glossaryBlocks(content, dictionary: "fixture", scale: 1, availableWidth: 300)
        let box = try #require(blocks.compactMap { if case .box(let model) = $0 { return model }; return nil }.first)
        #expect(box.children.count == 2)
        let table = try #require(box.children.compactMap { if case .table(let model) = $0 { return model }; return nil }.first)
        #expect(table.rows == 1 && table.cells.count == 1)
        #expect(!table.plainText.string.contains("隠す") && table.plainText.string.contains("内"))
        #expect(table.cells[0].blocks.contains { if case .table = $0 { return true }; return false })
        let view = NativeDictionaryBoxView(model: box) { text in
            let view = UITextView(); view.attributedText = text; view.isEditable = false; view.isSelectable = true; return view
        }
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 200); view.layoutIfNeeded()
        #expect(view.subviews.count == 2)
        #expect(view.subviews[1].frame.minX - view.subviews[0].frame.maxX == 8)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(view)
        #expect(views.filter { $0.accessibilityIdentifier == "dictionary.glossary.nativeTable" }.count == 2)
        #expect(views.compactMap { $0 as? UITextView }.allSatisfy { $0.isSelectable && !$0.isEditable })
    }

    @Test func stylesheetBoxesRemainInteractiveInsideWrappersAndTableCells() throws {
        guard #available(iOS 18.0, *) else { return }
        let stylesheet = ".row{display:flex;gap:8px;color:var(--Ink)}"
        let content = "<div style='--Ink:#123456'><section class='row'><span>A</span><span>B</span></section></div>"
        let blocks = NativeDictionaryContent.glossaryBlocks(content, dictionary: "fixture", scale: 1, stylesheet: stylesheet)
        let box = try #require(blocks.compactMap { if case .box(let model) = $0 { return model }; return nil }.first)
        #expect(box.children.count == 2 && box.plainText.string == "AB")
        let text = try #require(box.children.compactMap { if case .text(let text) = $0 { return text }; return nil }.first)
        #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
            == UIColor(red: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0, alpha: 1))
        let tableBlocks = NativeDictionaryContent.glossaryBlocks("<table><tr><td>" + content + "</td></tr></table>",
            dictionary: "fixture", scale: 1, stylesheet: stylesheet)
        let table = try #require(tableBlocks.compactMap { if case .table(let model) = $0 { return model }; return nil }.first)
        #expect(table.cells[0].blocks.contains { if case .box = $0 { return true }; return false })
    }

    @Test func headerPreservesInheritedSizeAndExplicitBorderlessCells() throws {
        guard #available(iOS 18.0, *) else { return }
        let blocks = NativeDictionaryContent.glossaryBlocks("<table><tr style='font-size:2em'>"
            + "<th style='border:none'>語</th><td style='border-style:hidden'>訳</td></tr></table>", dictionary: "fixture", scale: 1)
        let table = try #require(blocks.compactMap { if case .table(let model) = $0 { return model }; return nil }.first)
        #expect((table.cells[0].content.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize == 30)
        #expect(table.cells.allSatisfy { $0.borderWidth == 0 })
    }

}
