#!/usr/bin/env python3
"""Compile production Core Text typography and verify script/font availability."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"
SOURCES = [
    "NativeTranslationTypography", "NativeParentheticalNameWrap", "NativeTextPaintGeometry", "NativeCollapsedRowIntrinsicWidth",
    "NativePreLineTextFlow", "NativeNormalTextFlow", "NativeNormalBreakOpportunities",
    "NativeRawTextBalance", "NativeKeepAllBreakOpportunities",
    "NativeKeepAllAutoLines", "NativeKeepAllTextBalance", "NativeCTFontStrokePainter",
    "NativeCTFontHorizontalFillPainter", "NativeCTFontVerticalPainter", "NativeVerticalGlyphOrigins",
    "NativePreformattedTabs", "NativeVerticalLetterSpacing", "NativeVisibleControlGlyphs",
]
FIXTURE = r'''
import Foundation
import CoreText

@main struct Check {
    static func primary(_ text: String, style: NativeTranslationTypography.Style) -> [String: Any] {
        let layout = NativeTranslationTypography.layout(text: text, in: CGSize(width: 300, height: 500), style: style)
        precondition(layout.fits && layout.visibleUTF16Range.length == text.utf16.count)
        return NativeTranslationTypography.diagnosticRuns(layout: layout)[0]["primaryFont"] as! [String: Any]
    }
    static func main() throws {
        // The CLI executable's Bundle.main has no app resources. A process
        // registration must still be reflected in availability/cache metadata.
        let resource = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(Bundle.main.url(forResource: "AidokuSerifKR-Bold", withExtension: "woff2") == nil)
        precondition(CTFontManagerRegisterFontsForURL(resource as CFURL, .process, nil))
        precondition(NativeTranslationTypography.isBundledSerifAvailable)
        precondition(NativeTranslationTypography.availabilityKey == "native-typography-v2:serif-available")
        let serif = primary("한글", style: .init(fontName: "AidokuSerifKR-Bold", fontSize: 20))
        precondition(serif["fontName"] as? String == "AidokuSerifKR-Bold")
        precondition(abs((serif["fontSize"] as! Double) - 18.2) < 0.0001)
        for text in ["한글", "가", "ㄱㄴ", "㉠", "ﾡ"] {
            let bold = primary(text, style: .init(fontSize: 20))
            precondition(bold["fontName"] as? String == "AppleSDGothicNeo-Bold", "Korean script: \(text)")
            let regular = primary(text, style: .init(fontSize: 20, bold: false))
            precondition(regular["fontName"] as? String == "AppleSDGothicNeo-Regular")
        }
        let vertical = primary("ㄱ", style: .init(fontSize: 20, vertical: true))
        precondition(vertical["fontName"] as? String == "AppleSDGothicNeo-ExtraBold")
        precondition(primary("カナ", style: .init(fontSize: 20))["fontName"] as? String == "HiraginoSans-W7")
        precondition(primary("漢字", style: .init(fontSize: 20))["fontName"] as? String == "PingFangSC-Semibold")
        let explicit = primary("ㄱ", style: .init(fontName: "Helvetica-Bold", fontSize: 20))
        precondition(explicit["fontName"] as? String == "Helvetica-Bold")
        let missing = primary("ㄱ", style: .init(fontName: "AidokuMissingFont", fontSize: 20))
        precondition(missing["fontName"] as? String == "AppleSDGothicNeo-Bold")
        let mixed = "이제 이해했어! 이건 너무 야해...っ"
        let translated: NativeTranslationTypography.Style = .init(fontScript: "japanese",
            prefersDominantKoreanScript: true, fontSize: 20)
        precondition(primary(mixed, style: translated)["fontName"] as? String == "AppleSDGothicNeo-Bold")
        precondition(primary("가あ", style: translated)["fontName"] as? String == "HiraginoSans-W7")
        precondition(primary("あいう가", style: translated)["fontName"] as? String == "HiraginoSans-W7")
        let sourceOnly: NativeTranslationTypography.Style = .init(fontScript: "japanese", fontSize: 20)
        precondition(primary(mixed, style: sourceOnly)["fontName"] as? String == "HiraginoSans-W7")
        let namedMixed: NativeTranslationTypography.Style = .init(fontName: "AidokuSerifKR-Bold", fontScript: "japanese",
            prefersDominantKoreanScript: true, fontSize: 20)
        precondition(primary(mixed, style: namedMixed)["fontName"] as? String == "AidokuSerifKR-Bold")
        let uprightMixed: NativeTranslationTypography.Style = .init(fontScript: "japanese",
            prefersDominantKoreanScript: true, fontSize: 20, vertical: true)
        precondition(primary("가나다っ", style: uprightMixed)["fontName"] as? String == "AppleSDGothicNeo-ExtraBold")
        if CommandLine.arguments.count > 2 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            var corrected = 0
            for test in cases {
                let text = test["text"] as! String
                let expected = test["expectedPrimary"] as! String
                precondition(primary(text, style: translated)["fontName"] as? String == expected)
                if expected == "AppleSDGothicNeo-Bold" { corrected += 1 }
            }
            print("PASS: \(cases.count) actual mixed-script corpus cards, \(corrected) corrected Korean primaries")
        }
        print("PASS: native registered serif, Hangul weights, translated dominant script and source-only/explicit controls")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="aidoku-native-font-choice-") as temporary:
    directory = Path(temporary)
    fixture = directory / "Check.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", *[str(OVERLAY / (name + ".swift")) for name in SOURCES],
                    str(fixture), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(ROOT / "Aidoku/Resources/Translation/AidokuSerifKR-Bold.woff2"), *sys.argv[1:]], check=True)
