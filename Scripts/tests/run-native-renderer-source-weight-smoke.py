#!/usr/bin/env python3
"""Compile actual main layout Codable types, Style and four style call sites.

Host-only boundary test: extracts current production declarations/call sites into
an isolated Swift probe. UIKit geometry/settings and expensive fitting are narrow
stubs; no app/shared cache, model, source image, OCR, API or renderer build.
Checks styles and actual uncached Core Text font resolution, not final pixels or
 device font metrics. The production font-selection predicates are extracted too.
"""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


layout = (OVERLAY / 'NativeTranslationLayout.swift').read_text()
typography = (OVERLAY / 'NativeTranslationTypography.swift').read_text()
renderer = (OVERLAY / 'NativeTranslationRenderer.swift').read_text()
boxes = (OVERLAY / 'NativeTranslationRenderer+TextBoxes.swift').read_text()
slanted = (OVERLAY / 'NativeTranslationRenderer+SlantedTrials.swift').read_text()
# Retain the complete real layout/item Codable declarations, including CodingKeys,
# validation and synthesized encoding. Only the unrelated planner/worker is omitted.
declarations = layout[:layout.index('private actor NativeTranslationLayoutWorker')].replace('import UIKit', '')
style = typography[typography.index('    enum HorizontalAlignment'):typography.index('    struct Layout {')]
planner_style = block(layout, '    private static func style(_ item:').replace('private static', 'static', 1)
initial_slanted = block(renderer, '    static func initialSlantedTypography(')
geometry = block(layout, '    static func validGeometry(')


def constructor(text):
    start = text.index('var style = NativeTranslationTypography.Style(')
    # All four initial styles must bind weight immediately after construction,
    # before any measurement, fitting, or speculative layout can consume it.
    end = text.index('if let bold = item.sourceRenderBold {', start)
    section = text[start:end]
    assert section.count('NativeTranslationTypography.Style(') == 1
    assert 'fitted(' not in section and 'Typography.layout(' not in section
    return text[start:end] + block(text[end:], 'if let bold = item.sourceRenderBold {')


program = r'''
import Foundation
import CoreGraphics
import AppKit
import CoreText
// Host compatibility for the actual UIKit item's inset computed properties.
typealias UIEdgeInsets = NSEdgeInsets
extension CGRect {
    func inset(by e: UIEdgeInsets) -> CGRect {
        CGRect(x: minX + e.left, y: minY + e.top,
               width: width - e.left - e.right, height: height - e.top - e.bottom)
    }
}
struct IPhoneOverlaySettings {
    var preserveSourceBackgroundColor = false
    var preserveSourceTextColor = false
    var preserveSourceColors = false
    var renderedBackgroundOpacity = 1.0
}
enum NativeTranslationRestoration {
    struct Appearance { var background: CGColor?; var foreground: CGColor?; var fontName: String? }
}
'''
program += declarations
program += '\nenum NativeTranslationTypography {\n' + style + r'''
    // Instrument the shaping boundary without building the graphics pipeline.
    struct Layout { let fits: Bool; let receivedBold: Bool; let receivedFontName: String? }
}
'''
# Exercise the current uncached resolver with real host Core Text. Registration
# and caching are boundary stubs; no production typography source is modified.
font_functions = '\n'.join(block(typography, marker).replace('private static', 'static', 1)
                           for marker in ('    private static func isHangulScript(',
                                          '    static func resolvedFontScript(',
                                          '    private static func script(for ',
                                          '    private static func uncachedFont('))
font_body = block(typography, '    private static func uncachedFont(')
selection = font_body[font_body.index('        let inferredScript'):font_body.index('        if let named {')]
# Keep a direct predicate check as well: missing named fonts may fall back on a
# host, hiding an explicit-bold override if only final CTFont traits are checked.
resolver = '\nextension NativeTranslationTypography {\n' + font_functions + r'''
    static let bundledSerifRegistered = false
    static func font(text: String, style: Style) -> CTFont { uncachedFont(text: text, style: style) }
    static func requestedFamily(text: String, style: Style) -> String? {
''' + selection + '\nreturn named\n}\n}\n'
program += resolver
program += '\nenum NativeTranslationLayoutPlanner {\n' + geometry + '\n' + planner_style + '\n}\n'
program += r'''
enum NativeTranslationRenderer {
    static func valid(_ rect: CGRect) -> Bool { rect.width > 0 && rect.height > 0 }
    static func color(_ rgb: [CGFloat]) -> CGColor { CGColor(gray: rgb[0] / 255, alpha: 1) }
    static func panelForeground(_ background: CGColor, opacity: CGFloat) -> CGColor { CGColor(gray: 0, alpha: 1) }
    static func fitted(text: String, size: CGSize, style: inout NativeTranslationTypography.Style)
        -> NativeTranslationTypography.Layout {
        .init(fits: true, receivedBold: style.bold, receivedFontName: style.fontName)
    }
'''
program += initial_slanted + '\n}\n'
program += '''
func boxStyle(_ item: NativeTranslationLayoutItem) -> NativeTranslationTypography.Style {
    let foreground = CGColor(gray: 0, alpha: 1)
''' + constructor(boxes) + '\nreturn style\n}\n'
program += '''
func trialStyle(_ item: NativeTranslationLayoutItem, preserve: Bool = false,
                fontName: String? = nil) -> NativeTranslationTypography.Style {
    let candidate = (font: item.fontSize, pitch: item.lineHeight, condense: CGFloat(1))
    var settings = IPhoneOverlaySettings()
    settings.preserveSourceColors = preserve
    let appearance = NativeTranslationRestoration.Appearance(background: nil, foreground: nil, fontName: fontName)
    let light = item.lightSurface
    let panelInk: CGColor? = nil
''' + constructor(slanted) + '\nreturn style\n}\n'
# Source guard: all actual renderer initial Style construction sites are covered.
assert renderer.count('= NativeTranslationTypography.Style(') == 1
assert boxes.count('= NativeTranslationTypography.Style(') == 1
assert slanted.count('= NativeTranslationTypography.Style(') == 1
constructor(renderer)
constructor(layout[layout.index('    private static func style(_ item:'):])
program += r'''
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message); checks += 1
}
let base: [String: Any] = ["id": "synthetic", "text": "가나다 translated", "width": 100, "height": 80,
    "fontSize": 16, "lineHeight": 19, "sourceBounds": [0.1, 0.1, 0.2, 0.3], "sourceFrame": [0, 0, 640, 480]]
func decodeItem(_ fields: [String: Any]) throws -> NativeTranslationLayoutItem {
    try JSONDecoder().decode(NativeTranslationLayoutItem.self,
        from: JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new }))
}
func decodeMain(_ fields: [String: Any]) throws -> NativeTranslationLayout {
    // The actual full main layout decoder, not the review compositor's Item.
    let raw: [String: Any] = ["version": 1, "imageSize": [640, 480],
        "sourceRect": [[0, 0], [640, 480]], "viewport": [640, 480],
        "items": [base.merging(fields) { _, new in new }]]
    return try JSONDecoder().decode(NativeTranslationLayout.self,
        from: JSONSerialization.data(withJSONObject: raw))
}
let cases: [([String: Any], Bool?, Bool)] = [
    ([:], nil, true),
    (["sourceFontWeight": NSNull(), "renderBold": NSNull()], nil, true),
    (["sourceFontWeight": "regular"], false, false),
    (["sourceFontWeight": "mixed"], false, false),
    (["sourceFontWeight": "bold"], true, true),
    (["renderBold": false], false, false),
    (["renderBold": true], true, true),
    (["sourceFontWeight": "regular", "renderBold": false], false, false),
    (["sourceFontWeight": "mixed", "renderBold": false], false, false),
    (["sourceFontWeight": "bold", "renderBold": true], true, true),
    (["sourceFontWeight": "regular", "renderBold": NSNull()], false, false),
    (["sourceFontWeight": NSNull(), "renderBold": false], false, false)
]
for (fields, override, expected) in cases {
    let item = try decodeItem(fields)
    check(item.sourceRenderBold == override, "Optional override")
    let main = try decodeMain(fields)
    check(main.items[0] == item, "Main item decode retains weight")
    let persisted = try JSONDecoder().decode(NativeTranslationLayout.self, from: JSONEncoder().encode(main))
    check(persisted == main, "Main layout encode/decode retains both fields")
    let payload = item.payload
    check(payload["sourceFontWeight"] as? String == item.sourceFontWeight, "Descriptor retains source weight")
    check(payload["renderBold"] as? Bool == item.renderBold, "Descriptor retains render decision")
    for script in ["latin", "korean", "japanese"] {
        for vertical in [false, true] {
            var variant = fields
            variant["fontScript"] = script; variant["vertical"] = vertical
            let actual = try decodeItem(variant)
            check(boxStyle(actual).bold == expected && boxStyle(actual).fontName == nil,
                  "Main text box style and effective font name before shape")
            check(trialStyle(actual).bold == expected, "Slanted trial style before shape")
            check(NativeTranslationLayoutPlanner.style(actual, appearance: nil).bold == expected, "Planner style before fit")
            for preserve in [false, true] {
                var settings = IPhoneOverlaySettings()
                settings.preserveSourceColors = preserve
                settings.preserveSourceTextColor = preserve
                settings.preserveSourceBackgroundColor = preserve
                let appearance = NativeTranslationRestoration.Appearance(background: CGColor(gray: 1, alpha: 1),
                    foreground: CGColor(gray: 0, alpha: 1), fontName: "AidokuSerifKR-Bold")
                let result = NativeTranslationRenderer.initialSlantedTypography(item: actual, appearance: appearance, settings: settings)!
                check(result.0.receivedBold == expected && result.1.bold == expected,
                      "Initial slant receives source weight before fitting regardless of colour setting")
                let hasNamedRequest = preserve && script == "korean" && override != false
                let expectedName: String? = hasNamedRequest ? "AidokuSerifKR-Bold" : nil
                check(result.0.receivedFontName == expectedName && result.1.fontName == expectedName,
                      "Initial slant supplies effective font name before fitting")
                let trial = trialStyle(actual, preserve: preserve, fontName: "AidokuSerifKR-Bold")
                check(trial.bold == expected && trial.fontName == expectedName,
                      "Trial preserves absent/bold face but clears supplied nonbold face")
                let planned = NativeTranslationLayoutPlanner.style(actual, appearance: appearance)
                let plannedName: String? = script == "korean" && override != false ? "AidokuSerifKR-Bold" : nil
                check(planned.bold == expected && planned.fontName == plannedName,
                      "Planner preserves absent/bold face but clears supplied nonbold face")
                for style in [result.1, trial, planned, boxStyle(actual)] {
                    let requested = NativeTranslationTypography.requestedFamily(text: actual.text, style: style)
                    if override == false {
                        let family: String? = script == "korean" ? "AppleSDGothicNeo-Regular"
                            : script == "japanese" ? "HiraginoSans-W3" : nil
                        check(style.fontName == nil && requested == family,
                              "Source nonbold reaches actual regular-family predicate")
                        let font = NativeTranslationTypography.uncachedFont(text: actual.text, style: style)
                        check(!CTFontGetSymbolicTraits(font).contains(.traitBold),
                              "Actual resolved host face is nonbold")
                        let requestedName = requested ?? ""
                        if !requestedName.isEmpty {
                            check(CTFontCopyPostScriptName(font) as String == requestedName,
                                  "Actual host font matches regular script family")
                        }
                    } else if let name = style.fontName {
                        check(requested == name, "Absent/bold keeps explicit named-font priority")
                    }
                }
            }
        }
    }
}
for fields: [String: Any] in [
    ["sourceFontWeight": "regular", "renderBold": true],
    ["sourceFontWeight": "mixed", "renderBold": true],
    ["sourceFontWeight": "bold", "renderBold": false],
    ["sourceFontWeight": "heavy"], ["sourceFontWeight": "Bold"], ["sourceFontWeight": ""],
    ["sourceFontWeight": 1], ["sourceFontWeight": true],
    ["renderBold": 1], ["renderBold": "true"], ["renderBold": []]
] {
    do { _ = try decodeMain(fields); fatalError("Invalid main weight accepted: \(fields)") }
    catch { checks += 1 }
}
let absent = try decodeItem([:]).payload
check(absent["sourceFontWeight"] == nil && absent["renderBold"] == nil, "Old payload does not acquire fields")
let mixed = try decodeItem(["sourceFontWeight": "mixed", "translatedStyleRuns": [["start": 0, "end": 2, "bold": true]]])
check(boxStyle(mixed).bold == false, "Unvalidated source runs cannot bold a whole mixed translation")
print("PASS \(checks) main decode/persistence and pre-shaping style checks; host-only, no pixel/device claim")
'''
with tempfile.TemporaryDirectory(prefix='native-renderer-source-weight-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(program)
    before = time.monotonic()
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(work / 'modules'),
                    str(OVERLAY / 'NativeTranslationParagraphID.swift'), str(work / 'main.swift'),
                    '-o', str(work / 'probe')], check=True)
    compiled = time.monotonic() - before
    before = time.monotonic()
    subprocess.run([str(work / 'probe')], check=True)
    print(f'Isolated compile: {compiled:.3f}s; execution: {time.monotonic()-before:.3f}s')
